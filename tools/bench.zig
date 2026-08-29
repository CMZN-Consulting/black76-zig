//! bench.zig -- nanoseconds per option, so that "optimised" is a measurement.
//!
//!   zig build bench -Doptimize=ReleaseFast
//!   zig build bench -Doptimize=ReleaseFast -Dcpu=native
//!
//! Prices 2^20 synthetic options drawn from the same magnitudes and ranges as
//! the fixture grid, through the batch path and through the single-option
//! path, and reports the best of several runs. Best-of, not mean: the question
//! is what the kernel costs, not what the machine was doing meanwhile.
//!
//! Memory: five input and five output arrays, allocated once with an explicit
//! allocator, freed at the end. The kernel itself allocates nothing.

const std = @import("std");
const assert = std.debug.assert;
const b76 = @import("black76");

const option_count: usize = 1 << 20;
const reps: usize = 7;

const Arrays = struct {
    forwards: []f64,
    strikes: []f64,
    sigmas: []f64,
    ttms: []f64,
    kinds: []b76.Kind,
    deltas: []f64,
    gammas: []f64,
    thetas: []f64,
    vegas: []f64,
    prices: []f64,

    fn alloc(gpa: std.mem.Allocator, n: usize) !Arrays {
        var a: Arrays = undefined;
        inline for (@typeInfo(Arrays).@"struct".fields) |field| {
            @field(a, field.name) = try gpa.alloc(std.meta.Child(field.type), n);
        }
        return a;
    }

    fn free(a: Arrays, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(Arrays).@"struct".fields) |field| {
            gpa.free(@field(a, field.name));
        }
    }

    fn inputs(a: Arrays) b76.BatchInputs {
        return .{ .forwards = a.forwards, .strikes = a.strikes, .sigmas = a.sigmas, .ttms = a.ttms, .kinds = a.kinds };
    }

    fn outputs(a: Arrays) b76.BatchOutputs {
        return .{ .deltas = a.deltas, .gammas = a.gammas, .thetas = a.thetas, .vegas = a.vegas, .prices = a.prices };
    }
};

fn fill(a: Arrays, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const magnitudes = [_]f64{ 0.5, 500.0, 500000.0 };
    for (0..a.forwards.len) |i| {
        const f = magnitudes[r.uintLessThan(usize, magnitudes.len)];
        const m = 0.5 + 1.5 * r.float(f64); // moneyness 0.5 .. 2.0
        a.forwards[i] = f;
        a.strikes[i] = f / m;
        a.sigmas[i] = 0.05 + 2.95 * r.float(f64); // 5% .. 300%
        a.ttms[i] = (5.0 / 1440.0 + 365.0 * r.float(f64)) / 365.0; // 5 minutes .. 1 year
        a.kinds[i] = if (r.boolean()) .call else .put;
    }
}

fn nsPerOption(io: std.Io, a: Arrays, comptime path: enum { batch, single }) f64 {
    var best: i96 = std.math.maxInt(i96);
    for (0..reps) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        switch (path) {
            .batch => b76.greeksBatch(a.inputs(), a.outputs()),
            .single => for (0..a.forwards.len) |i| {
                const g = b76.greeks(.{
                    .forward = a.forwards[i],
                    .strike = a.strikes[i],
                    .sigma = a.sigmas[i],
                    .ttm = a.ttms[i],
                    .kind = a.kinds[i],
                });
                // All five stored, or the optimiser drops the Greeks it can
                // see are unused and the number stops meaning "one option".
                a.deltas[i] = g.delta;
                a.gammas[i] = g.gamma;
                a.thetas[i] = g.theta;
                a.vegas[i] = g.vega;
                a.prices[i] = g.price;
            },
        }
        const t1 = std.Io.Timestamp.now(io, .awake);
        std.mem.doNotOptimizeAway(a.prices[a.prices.len - 1]);
        best = @min(best, t0.durationTo(t1).nanoseconds);
    }
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(a.forwards.len));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const a = try Arrays.alloc(gpa, option_count);
    defer a.free(gpa);
    fill(a, 42);

    // Warm the caches and the branch predictor once, outside the clock.
    b76.greeksBatch(a.inputs(), a.outputs());

    const batch_mixed = nsPerOption(io, a, .batch);
    const single_mixed = nsPerOption(io, a, .single);
    @memset(a.kinds, .call);
    const batch_calls = nsPerOption(io, a, .batch);
    @memset(a.kinds, .put);
    const batch_puts = nsPerOption(io, a, .batch);

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    try w.print(
        \\black76 bench: {d} options, best of {d}, {s}, cpu {s}
        \\  batch, calls and puts : {d:.1} ns/option
        \\  single, calls and puts: {d:.1} ns/option
        \\  batch, calls only     : {d:.1} ns/option
        \\  batch, puts only      : {d:.1} ns/option
        \\
    , .{ option_count, reps, @tagName(@import("builtin").mode), @import("builtin").cpu.model.name, batch_mixed, single_mixed, batch_calls, batch_puts });
    try w.flush();
}
