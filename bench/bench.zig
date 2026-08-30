// bench.zig -- whole-binary optimisation benchmark driver for the pricer.
//
// This is the measuring instrument for the build-variant matrix in
// bench/run_matrix.sh. It does three things, in this order, every run:
//
//   1. GATE.   Replays the 3,516 golden vectors through the kernel and counts
//              bit-level mismatches. A build variant, a post-link rewrite, a
//              CPU flag -- none of them are allowed to move a bit. If one does,
//              the run reports it, exits non-zero, and the number is still
//              printed so the failure is a data point rather than a mystery.
//   2. HASH.   Hashes every output bit of every workload (FNV-1a over the raw
//              f64 patterns). analyze.py checks that all variants agree; that
//              extends the README's "sixteen for sixteen" measurement to
//              aarch64, LTO and BOLT without needing a fixture for each input.
//   3. TIME.   Runs each workload for `--iters` timed iterations after
//              `--warmup` untimed ones and reports ns per option as a
//              distribution (min / p10 / median / p90 / mean), one JSON line
//              per (workload, mode). Run-to-run variance is captured OUTSIDE
//              this process: run_matrix.sh launches it `REPS` times.
//
// Two ways to reach the kernel, because they answer different questions:
//   --mode static   the kernel is compiled into this binary (direct calls).
//                   This is the mode LTO, inlining and BOLT can act on.
//   --mode so       dlopen(3)-style loading of libblack76.so and calls through
//                   function pointers, which is how an FFI host uses it.
//
// Timing uses the monotonic clock (CLOCK_MONOTONIC on Linux). Counters come
// from `perf stat` around the whole process, so `--iters` is also the knob
// that makes the timed region dominate the parse-and-gate preamble.

const std = @import("std");
const builtin = @import("builtin");
const b76 = @import("black76");
const fx = @import("fixture");
const fixture = @embedFile("golden_fixture");

const GreeksFn = *const fn (f64, f64, f64, f64, bool, *f64, *f64, *f64, *f64, *f64) callconv(.c) void;
// v2's black76_greeks_batch marks its five output pointers `noalias`; that is
// part of the function-pointer TYPE for Zig's cast-compatibility check, not
// just a codegen hint, so the driver's typedef has to carry it too.
const BatchFn = *const fn ([*]const f64, [*]const f64, [*]const f64, [*]const f64, [*]const bool, usize, noalias [*]f64, noalias [*]f64, noalias [*]f64, noalias [*]f64, noalias [*]f64) callconv(.c) void;

const Mode = enum { static, so };
const Workload = enum { fixture, grid, scalar };

// BOLT's instrumentation runtime writes its profile from a DT_FINI /
// DT_FINI_ARRAY hook and refuses a dynamic executable that has neither.
// Zig's aarch64 glibc link emits neither (the x86_64 one gets .init/.fini
// from crti/crtn), so the libc build of this driver carries one empty
// .fini_array entry for BOLT to patch. It does nothing on its own.
fn boltFiniAnchor() callconv(.c) void {}
export const bolt_fini_anchor: *const fn () callconv(.c) void linksection(".fini_array") = &boltFiniAnchor;

const Options = struct {
    name: []const u8 = "unnamed",
    mode: Mode = .static,
    so_path: ?[]const u8 = null,
    workloads: [3]bool = .{ true, true, true },
    iters: u32 = 200,
    warmup: u32 = 20,
    grid_n: usize = 16384,
    seed: u64 = 0x9E3779B97F4A7C15,
    skip_gate: bool = false,
};

const Kernel = struct {
    greeks: GreeksFn,
    batch: BatchFn,
};

/// Structure-of-arrays inputs and outputs for one workload.
const Set = struct {
    n: usize,
    f: []f64,
    k: []f64,
    s: []f64,
    t: []f64,
    c: []bool,
    delta: []f64,
    gamma: []f64,
    theta: []f64,
    vega: []f64,
    price: []f64,

    fn init(gpa: std.mem.Allocator, n: usize) !Set {
        return .{
            .n = n,
            .f = try gpa.alloc(f64, n),
            .k = try gpa.alloc(f64, n),
            .s = try gpa.alloc(f64, n),
            .t = try gpa.alloc(f64, n),
            .c = try gpa.alloc(bool, n),
            .delta = try gpa.alloc(f64, n),
            .gamma = try gpa.alloc(f64, n),
            .theta = try gpa.alloc(f64, n),
            .vega = try gpa.alloc(f64, n),
            .price = try gpa.alloc(f64, n),
        };
    }

    fn clearOutputs(self: *Set) void {
        @memset(self.delta, 0.0);
        @memset(self.gamma, 0.0);
        @memset(self.theta, 0.0);
        @memset(self.vega, 0.0);
        @memset(self.price, 0.0);
    }

    /// FNV-1a over the raw bit patterns of all five output arrays. -0.0 and
    /// +0.0 hash differently, as they must: the sign of a zero theta tells
    /// you which branch produced it (README).
    fn hashOutputs(self: *const Set) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for ([_][]const f64{ self.delta, self.gamma, self.theta, self.vega, self.price }) |arr| {
            for (arr) |x| {
                const bits: u64 = @bitCast(x);
                inline for (0..8) |i| {
                    h ^= @as(u8, @truncate(bits >> (8 * i)));
                    h *%= 0x100000001b3;
                }
            }
        }
        return h;
    }
};

// -- Deterministic inputs for the synthetic grid ---------------------------
//
// xorshift64*: cheap, stateless across platforms, and the same sequence on
// every architecture, so the grid hash is comparable across machines.
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Uniform in [0, 1) with 53 random bits.
    fn unit(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * (1.0 / 9007199254740992.0);
    }

    fn uniform(self: *Rng, lo: f64, hi: f64) f64 {
        return lo + (hi - lo) * self.unit();
    }

    fn logUniform(self: *Rng, lo: f64, hi: f64) f64 {
        return @exp(self.uniform(@log(lo), @log(hi)));
    }
};

/// Main-path-only inputs: every option is live, priced, and away from the
/// guards, so this measures the kernel's hot path and nothing else. Ranges
/// are a plausible listed-options book, not a stress test -- the fixture
/// workload already covers the degenerate branches.
fn fillGrid(set: *Set, seed: u64) void {
    var rng = Rng{ .state = seed | 1 };
    for (0..set.n) |i| {
        const f = rng.logUniform(1.0, 100000.0);
        const m = rng.logUniform(0.6, 1.6); // moneyness F/K
        set.f[i] = f;
        set.k[i] = f / m;
        set.s[i] = rng.uniform(0.05, 1.50);
        set.t[i] = rng.uniform(1.0 / 365.0, 2.0);
        set.c[i] = (rng.next() & 1) == 1;
    }
}

fn fillFromFixture(gpa: std.mem.Allocator) !struct { set: Set, expected: Set } {
    // v2's fixture.zig replaced parseAll(gpa, text) -> !ArrayList(Vector) with
    // parseAlloc(gpa, text) -> ![]Vector (schema-2: an explicit header, read
    // internally by parseAlloc), and Vector.c: bool with Vector.kind: b76.Kind.
    const vs = try fx.parseAlloc(gpa, fixture);
    const n = vs.len;
    var set = try Set.init(gpa, n);
    var expected = try Set.init(gpa, n);
    for (vs, 0..) |v, i| {
        set.f[i] = v.f;
        set.k[i] = v.k;
        set.s[i] = v.s;
        set.t[i] = v.t;
        set.c[i] = (v.kind == .call);
        expected.delta[i] = v.delta;
        expected.gamma[i] = v.gamma;
        expected.theta[i] = v.theta;
        expected.vega[i] = v.vega;
        expected.price[i] = v.price;
    }
    return .{ .set = set, .expected = expected };
}

// -- The two call shapes ---------------------------------------------------

inline fn runBatch(kernel: Kernel, set: *Set) void {
    kernel.batch(set.f.ptr, set.k.ptr, set.s.ptr, set.t.ptr, set.c.ptr, set.n, set.delta.ptr, set.gamma.ptr, set.theta.ptr, set.vega.ptr, set.price.ptr);
}

/// One call per option from the driver's own loop -- the shape an FFI host
/// takes when it prices positions one at a time instead of in a batch.
inline fn runScalar(kernel: Kernel, set: *Set) void {
    for (0..set.n) |i| {
        kernel.greeks(set.f[i], set.k[i], set.s[i], set.t[i], set.c[i], &set.delta[i], &set.gamma[i], &set.theta[i], &set.vega[i], &set.price[i]);
    }
}

/// Static mode calls the kernel DIRECTLY so that LTO and inlining have
/// something to act on. Going through the function pointers here would quietly
/// turn the "static" measurement into the "so" measurement.
inline fn runStaticBatch(set: *Set) void {
    b76.black76_greeks_batch(set.f.ptr, set.k.ptr, set.s.ptr, set.t.ptr, set.c.ptr, set.n, set.delta.ptr, set.gamma.ptr, set.theta.ptr, set.vega.ptr, set.price.ptr);
}

inline fn runStaticScalar(set: *Set) void {
    for (0..set.n) |i| {
        b76.black76_greeks(set.f[i], set.k[i], set.s[i], set.t[i], set.c[i], &set.delta[i], &set.gamma[i], &set.theta[i], &set.vega[i], &set.price[i]);
    }
}

fn dispatch(mode: Mode, kernel: Kernel, workload: Workload, set: *Set) void {
    switch (mode) {
        .static => switch (workload) {
            .fixture, .grid => runStaticBatch(set),
            .scalar => runStaticScalar(set),
        },
        .so => switch (workload) {
            .fixture, .grid => runBatch(kernel, set),
            .scalar => runScalar(kernel, set),
        },
    }
}

// -- Statistics -------------------------------------------------------------

const Summary = struct {
    min: f64,
    p10: f64,
    median: f64,
    p90: f64,
    mean: f64,
    max: f64,
};

fn summarize(samples: []u64, n_opts: usize) Summary {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const per = @as(f64, @floatFromInt(n_opts));
    var total: f64 = 0;
    for (samples) |s| total += @as(f64, @floatFromInt(s));
    const at = struct {
        fn q(sorted: []const u64, frac: f64, per_opt: f64) f64 {
            const idx_f = frac * @as(f64, @floatFromInt(sorted.len - 1));
            const idx: usize = @intFromFloat(@floor(idx_f));
            return @as(f64, @floatFromInt(sorted[idx])) / per_opt;
        }
    };
    return .{
        .min = @as(f64, @floatFromInt(samples[0])) / per,
        .p10 = at.q(samples, 0.10, per),
        .median = at.q(samples, 0.50, per),
        .p90 = at.q(samples, 0.90, per),
        .mean = total / @as(f64, @floatFromInt(samples.len)) / per,
        .max = @as(f64, @floatFromInt(samples[samples.len - 1])) / per,
    };
}

fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Clock.awake.now(io);
    return @intCast(ts.toNanoseconds());
}

// -- Gate -------------------------------------------------------------------

fn gateMismatches(got: *const Set, want: *const Set) usize {
    var bad: usize = 0;
    for (0..got.n) |i| {
        const ok = fx.bitEq(got.delta[i], want.delta[i]) and fx.bitEq(got.gamma[i], want.gamma[i]) and
            fx.bitEq(got.theta[i], want.theta[i]) and fx.bitEq(got.vega[i], want.vega[i]) and
            fx.bitEq(got.price[i], want.price[i]);
        if (!ok) bad += 1;
    }
    return bad;
}

/// Batch and per-call paths must agree bit-for-bit on the synthetic grid too.
/// The golden test pins this on the fixture; the grid is a different input
/// distribution and a different array size, so it is pinned again here.
fn batchVsScalarMismatches(mode: Mode, kernel: Kernel, gpa: std.mem.Allocator, grid: *Set) !usize {
    var single = try Set.init(gpa, grid.n);
    @memcpy(single.f, grid.f);
    @memcpy(single.k, grid.k);
    @memcpy(single.s, grid.s);
    @memcpy(single.t, grid.t);
    @memcpy(single.c, grid.c);
    dispatch(mode, kernel, .grid, grid);
    dispatch(mode, kernel, .scalar, &single);
    return gateMismatches(&single, grid);
}

// -- CLI --------------------------------------------------------------------

const usage =
    \\usage: bench-driver [options]
    \\  --name <label>        variant label written into every JSON line (default: unnamed)
    \\  --mode static|so      call the compiled-in kernel, or dlopen a shared library (default: static)
    \\  --so <path>           path to libblack76.so (required for --mode so)
    \\  --workload <w>        fixture | grid | scalar | all  (repeatable; default: all)
    \\  --iters <n>           timed iterations per workload (default: 200)
    \\  --warmup <n>          untimed iterations before timing (default: 20)
    \\  --grid-n <n>          options in the synthetic grid (default: 16384)
    \\  --seed <u64>          grid RNG seed (default: fixed)
    \\  --skip-gate           do not replay the golden fixture first (never in a real run)
    \\  --help
    \\
    \\exit status: 0 ok, 2 usage, 3 gate failure (bits moved), 4 could not load --so
    \\
;

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    var any_workload = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const takes = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return error.Help;
        if (std.mem.eql(u8, a, "--skip-gate")) {
            o.skip_gate = true;
            continue;
        }
        if (!takes) return error.MissingValue;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--name")) {
            o.name = v;
        } else if (std.mem.eql(u8, a, "--mode")) {
            o.mode = std.meta.stringToEnum(Mode, v) orelse return error.BadMode;
        } else if (std.mem.eql(u8, a, "--so")) {
            o.so_path = v;
        } else if (std.mem.eql(u8, a, "--workload")) {
            if (!any_workload) {
                o.workloads = .{ false, false, false };
                any_workload = true;
            }
            if (std.mem.eql(u8, v, "all")) {
                o.workloads = .{ true, true, true };
            } else {
                const w = std.meta.stringToEnum(Workload, v) orelse return error.BadWorkload;
                o.workloads[@intFromEnum(w)] = true;
            }
        } else if (std.mem.eql(u8, a, "--iters")) {
            o.iters = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            o.warmup = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, a, "--grid-n")) {
            o.grid_n = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            o.seed = try std.fmt.parseInt(u64, v, 0);
        } else {
            return error.UnknownFlag;
        }
    }
    if (o.iters == 0) return error.BadIters;
    if (o.mode == .so and o.so_path == null) return error.MissingSoPath;
    return o;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    var stderr_buf: [1024]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr_w.interface;
    defer err.flush() catch {};

    const args = try init.minimal.args.toSlice(gpa);
    const opts = parseArgs(args) catch |e| {
        try err.print("bench-driver: {s}\n{s}", .{ @errorName(e), usage });
        return 2;
    };

    // -- Resolve the kernel ------------------------------------------------
    var lib: ?std.DynLib = null;
    defer if (lib) |*l| l.close();
    const kernel: Kernel = switch (opts.mode) {
        .static => .{ .greeks = &b76.black76_greeks, .batch = &b76.black76_greeks_batch },
        .so => blk: {
            lib = std.DynLib.open(opts.so_path.?) catch |e| {
                try err.print("bench-driver: cannot load {s}: {s}\n", .{ opts.so_path.?, @errorName(e) });
                return 4;
            };
            const g = lib.?.lookup(GreeksFn, "black76_greeks") orelse {
                try err.print("bench-driver: {s} does not export black76_greeks\n", .{opts.so_path.?});
                return 4;
            };
            const bt = lib.?.lookup(BatchFn, "black76_greeks_batch") orelse {
                try err.print("bench-driver: {s} does not export black76_greeks_batch\n", .{opts.so_path.?});
                return 4;
            };
            break :blk .{ .greeks = g, .batch = bt };
        },
    };

    // -- Inputs ------------------------------------------------------------
    const fixed = try fillFromFixture(gpa);
    var fixture_set = fixed.set;
    var grid = try Set.init(gpa, opts.grid_n);
    fillGrid(&grid, opts.seed);

    // -- Gate --------------------------------------------------------------
    var gate_mismatches: usize = 0;
    var gate_status: []const u8 = "skipped";
    if (!opts.skip_gate) {
        fixture_set.clearOutputs();
        dispatch(opts.mode, kernel, .fixture, &fixture_set);
        gate_mismatches = gateMismatches(&fixture_set, &fixed.expected);
        gate_mismatches += try batchVsScalarMismatches(opts.mode, kernel, gpa, &grid);
        gate_status = if (gate_mismatches == 0) "pass" else "FAIL";
    }

    // -- Timing ------------------------------------------------------------
    const samples = try gpa.alloc(u64, opts.iters);
    inline for (.{ Workload.fixture, Workload.grid, Workload.scalar }) |w| {
        if (opts.workloads[@intFromEnum(w)]) {
            const set: *Set = if (w == .fixture) &fixture_set else &grid;
            set.clearOutputs();
            for (0..opts.warmup) |_| dispatch(opts.mode, kernel, w, set);
            const t_start = nowNs(io);
            for (samples) |*s| {
                const t0 = nowNs(io);
                dispatch(opts.mode, kernel, w, set);
                const t1 = nowNs(io);
                s.* = t1 - t0;
            }
            const t_end = nowNs(io);
            const hash = set.hashOutputs();
            const sum = summarize(samples, set.n);
            try out.print(
                \\{{"variant":"{s}","mode":"{s}","workload":"{s}","n":{d},"iters":{d},"warmup":{d},"ns_per_opt":{{"min":{d:.3},"p10":{d:.3},"median":{d:.3},"p90":{d:.3},"mean":{d:.3},"max":{d:.3}}},"timed_region_ns":{d},"hash":"0x{X:0>16}","gate":"{s}","gate_mismatches":{d},"zig":"{s}","target":"{s}-{s}-{s}","cpu":"{s}","optimize":"{s}"}}
                \\
            , .{
                opts.name,              @tagName(opts.mode),        @tagName(w),                       set.n,                           opts.iters,
                opts.warmup,            sum.min,                    sum.p10,                           sum.median,                      sum.p90,
                sum.mean,               sum.max,                    t_end - t_start,                   hash,                            gate_status,
                gate_mismatches,        builtin.zig_version_string, @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag), @tagName(builtin.target.abi),
                builtin.cpu.model.name, @tagName(builtin.mode),
            });
        }
    }

    if (gate_mismatches != 0) {
        try err.print("bench-driver: GATE FAILED -- {d} vectors differ from the golden fixture / per-call path. Not a tolerance question.\n", .{gate_mismatches});
        return 3;
    }
    return 0;
}
