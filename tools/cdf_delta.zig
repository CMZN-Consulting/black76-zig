// cdf_delta.zig -- measure what swapping the normal CDF actually costs.
//
//   zig build cdf-delta
//
// The kernel uses Abramowitz & Stegun 26.2.17, a rational polynomial with
// |err| < 7.5e-8. Sooner or later someone proposes replacing it with erf(),
// which is more accurate, and the proposal sounds like a cleanup.
//
// This tool answers the only question that matters: how far does the PRICE
// move. It replays every input in the golden fixture through both CDFs and
// reports the largest disagreement, absolute and relative.
//
// The answer is not "within tolerance" or "outside tolerance". There is no
// tolerance. The answer is a number, and someone with P&L responsibility
// decides whether they want it.

const std = @import("std");
const b76 = @import("black76");
const fx = @import("fixture");
const fixture_text = @embedFile("golden_fixture");

/// A high-precision cumulative normal, accurate to roughly 1e-15 -- Hart's
/// rational approximation (Hart, "Computer Approximations", 1968; the form used
/// here is the one popularised by Graeme West, "Better approximations to
/// cumulative normal functions", Wilmott, 2005).
///
/// This is the realistic upgrade candidate. It is genuinely better than
/// Abramowitz & Stegun 26.2.17 by about seven decimal digits. The question this
/// tool answers is not whether it is better -- it is -- but what adopting it
/// would DO to prices already on the books.
fn hartCDF(x: f64) f64 {
    const y = @abs(x);
    var c: f64 = 0.0;
    if (y <= 37.0) {
        const e = @exp(-y * y / 2.0);
        if (y < 7.07106781186547) {
            var n: f64 = 3.52624965998911e-02 * y + 0.700383064443688;
            n = n * y + 6.37396220353165;
            n = n * y + 33.912866078383;
            n = n * y + 112.079291497871;
            n = n * y + 221.213596169931;
            n = n * y + 220.206867912376;
            var d: f64 = 8.83883476483184e-02 * y + 1.75566716318264;
            d = d * y + 16.064177579207;
            d = d * y + 86.7807322029461;
            d = d * y + 296.564248779674;
            d = d * y + 637.333633378831;
            d = d * y + 793.826512519948;
            d = d * y + 440.413735824752;
            c = e * n / d;
        } else {
            const f = y + 1.0 / (y + 2.0 / (y + 3.0 / (y + 4.0 / (y + 0.65))));
            c = e / (f * 2.506628274631);
        }
    }
    return if (x > 0.0) 1.0 - c else c;
}

fn priceWith(comptime cdf: fn (f64) f64, forward: f64, strike: f64, sigma: f64, ttm: f64, is_call: bool) ?f64 {
    // Degenerate branches do not touch the CDF at all, so they cannot differ.
    // Skip them rather than pretend to measure them.
    if (forward <= 0.0 or strike <= 0.0) return null;
    if (ttm <= 0.0) return null;
    if (sigma <= 0.0) return null;
    const sqrt_t = @sqrt(ttm);
    const sigma_sqrt_t = sigma * sqrt_t;
    if (sigma_sqrt_t < 1e-10) return null;

    const d1 = (@log(forward / strike) + 0.5 * sigma * sigma * ttm) / sigma_sqrt_t;
    const d2 = d1 - sigma_sqrt_t;
    if (is_call) return forward * cdf(d1) - strike * cdf(d2);
    return strike * cdf(-d2) - forward * cdf(-d1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const vs = try fx.parseAll(gpa, fixture_text);

    var worst_abs: f64 = 0.0;
    var worst_abs_at: ?fx.Vector = null;
    var worst_rel: f64 = 0.0;
    var worst_rel_at: ?fx.Vector = null;
    var worst_rel_price: f64 = 0.0;
    // Same measure, restricted to options actually worth something (>= 0.1% of
    // forward). A ratio taken on a near-worthless option is arithmetically true
    // and economically meaningless; both are reported so neither can be quoted
    // alone.
    var worst_rel_mat: f64 = 0.0;
    var worst_rel_mat_at: ?fx.Vector = null;
    var worst_rel_mat_price: f64 = 0.0;
    var compared: usize = 0;

    for (vs.items) |v| {
        const a = priceWith(b76.normalCDF, v.f, v.k, v.s, v.t, v.c) orelse continue;
        const b = priceWith(hartCDF, v.f, v.k, v.s, v.t, v.c) orelse continue;
        compared += 1;
        const abs = @abs(a - b);
        if (abs > worst_abs) {
            worst_abs = abs;
            worst_abs_at = v;
        }
        // Relative only where there is a price to be relative to; a 1e-9
        // absolute move on a 1e-30 price is a meaningless ratio.
        if (@abs(a) > 1e-6) {
            const rel = abs / @abs(a);
            if (rel > worst_rel) {
                worst_rel = rel;
                worst_rel_at = v;
                worst_rel_price = a;
            }
            if (@abs(a) >= 0.001 * v.f and rel > worst_rel_mat) {
                worst_rel_mat = rel;
                worst_rel_mat_at = v;
                worst_rel_mat_price = a;
            }
        }
    }

    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    try w.print(
        \\Abramowitz & Stegun 26.2.17  vs  Hart high-precision normal CDF
        \\  vectors compared          : {d} (degenerate branches skipped -- they never call the CDF)
        \\
    , .{compared});
    if (worst_abs_at) |v| {
        try w.print(
            \\  worst ABSOLUTE price gap  : {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\
        , .{ worst_abs, v.f, v.k, v.s, v.t, if (v.c) "call" else "put" });
    }
    if (worst_rel_at) |v| {
        try w.print(
            \\  worst RELATIVE gap        : {d:.4} bps on a price of {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\      -- near-worthless option; the ratio is true and economically empty
            \\
        , .{ worst_rel * 10000.0, worst_rel_price, v.f, v.k, v.s, v.t, if (v.c) "call" else "put" });
    }
    if (worst_rel_mat_at) |v| {
        try w.print(
            \\  worst RELATIVE gap, priced: {d:.4} bps on a price of {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\      -- restricted to options worth >= 0.1% of forward
            \\
        , .{ worst_rel_mat * 10000.0, worst_rel_mat_price, v.f, v.k, v.s, v.t, if (v.c) "call" else "put" });
    }
    try w.print(
        \\
        \\Each of those is a real difference in a real price. This is
        \\why the fixture has no tolerance band: a band wide enough to admit this
        \\swap would hide it, and hiding it is the failure mode.
        \\
    , .{});
    try w.flush();
}
