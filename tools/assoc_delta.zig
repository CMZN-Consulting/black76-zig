//! assoc_delta.zig -- what the v2 -> v3 model change did to the numbers.
//!
//!   zig build assoc-delta
//!
//! v2 evaluated d1 as `[ln(F/K) + 0.5*sigma^2*T] / s`. v3 evaluates the
//! algebraically identical `A/s + s/2`, with A still `ln(F/K)` except where
//! that ratio over- or underflows. Nothing else moved: the
//! Hart/West CDF, the in-tree exp and log, and every other formula are the same
//! source they were. So this is a pure ASSOCIATION change, and the only thing
//! it can move is the last bits of d1 and d2 -- everything downstream inherits
//! that and nothing else.
//!
//! Why it was adopted, in one line each: `A/s + s/2` never forms 0.5*sigma^2*T,
//! which could overflow on its own and collapse d1 and d2 onto the same +inf,
//! pricing an out-of-the-money call at a NEGATIVE number; and the conditional
//! fallback to `ln(F) - ln(K)` removes the last place an infinity could enter
//! d1, without paying the at-the-money cancellation that making it
//! unconditional would have cost (measured: 8.8x worse in d1, 8.6x at the
//! money -- see the memo).
//!
//! This tool replays every input in the RETAINED v2 fixture through the live v3
//! kernel and reports, per output, how many vectors moved and by how much. It
//! embeds `vectors/black76-golden.v2.ndjson`, not the current fixture, so it
//! keeps measuring the same change after the fixture is regenerated -- exactly
//! as `cdf-delta` keeps measuring v1 -> v2.
//!
//! The answer is not "within tolerance". There is no tolerance. The answer is a
//! set of numbers, and someone with P&L responsibility decides.

const std = @import("std");
const b76 = @import("black76");
const fx = @import("fixture");
const v2_fixture = @embedFile("golden_fixture_v2");

fn bits(x: f64) u64 {
    return @bitCast(x);
}

/// Distance in representable doubles. Maps the sign-magnitude bit pattern onto
/// a monotone integer first, so the count is meaningful across zero.
fn ulpGap(a: f64, b: f64) u64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return 0;
    const ia = monotone(a);
    const ib = monotone(b);
    return if (ia > ib) ia - ib else ib - ia;
}

fn monotone(x: f64) u64 {
    const u = bits(x);
    return if (u & (1 << 63) != 0) ~u else u | (1 << 63);
}

const Field = enum { price, delta, gamma, theta, vega };

const Stat = struct {
    moved: usize = 0,
    max_abs: f64 = 0.0,
    max_abs_at: ?fx.Vector = null,
    max_ulp: u64 = 0,
    /// Worst relative move, restricted to outputs worth something.
    worst_bps: f64 = 0.0,
    worst_bps_at: ?fx.Vector = null,
    worst_bps_value: f64 = 0.0,
    /// Same measure with no economic filter, so the two can be read together.
    worst_bps_any: f64 = 0.0,
    worst_bps_any_value: f64 = 0.0,

    fn observe(st: *Stat, old: f64, new: f64, v: fx.Vector, priced: bool) void {
        if (bits(old) == bits(new)) return;
        st.moved += 1;
        const gap = @abs(old - new);
        if (gap > st.max_abs) {
            st.max_abs = gap;
            st.max_abs_at = v;
        }
        const u = ulpGap(old, new);
        if (u > st.max_ulp) st.max_ulp = u;
        if (@abs(old) > 0.0) {
            const bps = gap / @abs(old) * 10000.0;
            if (bps > st.worst_bps_any) {
                st.worst_bps_any = bps;
                st.worst_bps_any_value = old;
            }
            if (priced and bps > st.worst_bps) {
                st.worst_bps = bps;
                st.worst_bps_at = v;
                st.worst_bps_value = old;
            }
        }
    }
};

fn get(g: b76.Greeks, f: Field) f64 {
    return switch (f) {
        .price => g.price,
        .delta => g.delta,
        .gamma => g.gamma,
        .theta => g.theta,
        .vega => g.vega,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const vs = try fx.parseAlloc(gpa, v2_fixture);
    defer gpa.free(vs);

    var stats: [5]Stat = @splat(.{});
    var any_moved: usize = 0;
    var toward_zero_sign: usize = 0;

    for (vs) |v| {
        const old = v.expected();
        const new = b76.greeks(v.input());

        // "Priced" = the option is worth at least 0.1% of the forward. A bps
        // move on a near-worthless option is arithmetically true and
        // economically empty; both are reported so neither can be quoted alone.
        const priced = @abs(old.price) >= 0.001 * v.f;

        var moved_here = false;
        inline for (@typeInfo(Field).@"enum".fields, 0..) |field, i| {
            const f: Field = @enumFromInt(field.value);
            const a = get(old, f);
            const bb = get(new, f);
            stats[i].observe(a, bb, v, priced);
            if (bits(a) != bits(bb)) moved_here = true;
        }
        if (moved_here) any_moved += 1;
        // A sign-of-zero flip is a branch change, not a numeric one. None is
        // expected; counted so that "none" is a measurement.
        if (bits(old.theta) != bits(new.theta) and old.theta == 0.0 and new.theta == 0.0) toward_zero_sign += 1;
    }

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    try w.print(
        \\v2  d1 = [ln(F/K) + 0.5*sigma^2*T] / s
        \\v3  d1 = A/s + s/2, A = ln(F/K) w/ conditional fallback  (shipped)
        \\  the CDF, exp, log and every other formula are unchanged; this is a pure
        \\  re-association, so only the last bits of d1 and d2 can move.
        \\
        \\  vectors in the retained v2 fixture : {d}
        \\  vectors moving in >= 1 output      : {d}
        \\  sign-of-zero flips (branch change) : {d}
        \\
        \\  per output:
        \\  {s:<8} {s:>7}  {s:>14}  {s:>10}  {s:>14}  {s:>14}
        \\
    , .{ vs.len, any_moved, toward_zero_sign, "output", "moved", "max |delta|", "max ulps", "bps priced", "bps any" });

    inline for (@typeInfo(Field).@"enum".fields, 0..) |field, i| {
        try w.print("  {s:<8} {d:>7}  {e:>14.6}  {d:>10}  {e:>14.4}  {e:>14.4}\n", .{
            field.name, stats[i].moved, stats[i].max_abs, stats[i].max_ulp, stats[i].worst_bps, stats[i].worst_bps_any,
        });
    }

    inline for (@typeInfo(Field).@"enum".fields, 0..) |field, i| {
        if (stats[i].max_abs_at) |v| {
            try w.print(
                \\
                \\  {s}: worst absolute move {e:.6}
                \\      at F={d} K={d} sigma={d} T={d}y {s}  [{s}]
                \\
            , .{ field.name, stats[i].max_abs, v.f, v.k, v.s, v.t, @tagName(v.kind), v.g });
        }
        if (stats[i].worst_bps_at) |v| {
            try w.print(
                \\  {s}: worst relative move {e:.4} bps on a value of {e:.6}
                \\      at F={d} K={d} sigma={d} T={d}y {s}  [{s}]
                \\      -- restricted to options worth >= 0.1% of the forward
                \\
            , .{ field.name, stats[i].worst_bps, stats[i].worst_bps_value, v.f, v.k, v.s, v.t, @tagName(v.kind), v.g });
        }
    }

    try w.print(
        \\
        \\Every move above is a last-bits move in an ordinary option, and it is the
        \\price of removing three overflow channels that produced NEGATIVE prices,
        \\NaNs and silently wrong deltas at extreme magnitudes. The v2 numbers are
        \\kept in vectors/black76-golden.v2.ndjson so the diff stays on record.
        \\
    , .{});
    try w.flush();
}
