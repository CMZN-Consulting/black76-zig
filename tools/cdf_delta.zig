//! cdf_delta.zig -- measure what swapping the normal CDF actually costs.
//!
//!   zig build cdf-delta
//!
//! The kernel uses Abramowitz & Stegun 26.2.17, a rational polynomial with
//! |err| < 7.5e-8. Sooner or later someone proposes replacing it with erf(),
//! which is more accurate, and the proposal sounds like a cleanup.
//!
//! This tool answers the only question that matters: how far does the PRICE
//! move. It replays every input in the golden fixture through both CDFs and
//! reports the largest disagreement, absolute and relative.
//!
//! The answer is not "within tolerance" or "outside tolerance". There is no
//! tolerance. The answer is a number, and someone with P&L responsibility
//! decides whether they want it.

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

fn priceWith(comptime cdf: fn (f64) f64, in: b76.Input) ?f64 {
    // Degenerate branches do not touch the CDF at all, so they cannot differ.
    // Skip them rather than pretend to measure them.
    if (in.forward <= 0.0 or in.strike <= 0.0) return null;
    if (in.ttm <= 0.0) return null;
    if (in.sigma <= 0.0) return null;
    const sqrt_t = @sqrt(in.ttm);
    const sigma_sqrt_t = in.sigma * sqrt_t;
    if (sigma_sqrt_t < b76.sigma_sqrt_t_min) return null;

    const d1 = (@log(in.forward / in.strike) + 0.5 * in.sigma * in.sigma * in.ttm) / sigma_sqrt_t;
    const d2 = d1 - sigma_sqrt_t;
    return switch (in.kind) {
        .call => in.forward * cdf(d1) - in.strike * cdf(d2),
        .put => in.strike * cdf(-d2) - in.forward * cdf(-d1),
    };
}

const Worst = struct {
    gap: f64 = 0.0,
    price: f64 = 0.0,
    at: ?fx.Vector = null,

    fn update(worst: *Worst, gap: f64, price: f64, v: fx.Vector) void {
        if (gap > worst.gap) {
            worst.gap = gap;
            worst.price = price;
            worst.at = v;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const vs = try fx.parseAlloc(gpa, fixture_text);
    defer gpa.free(vs);

    var abs: Worst = .{};
    var rel: Worst = .{};
    // Same measure, restricted to options actually worth something (>= 0.1% of
    // forward). A ratio taken on a near-worthless option is arithmetically true
    // and economically meaningless; both are reported so neither can be quoted
    // alone.
    var rel_priced: Worst = .{};
    var compared: usize = 0;

    for (vs) |v| {
        const a = priceWith(b76.normalCDF, v.input()) orelse continue;
        const b = priceWith(hartCDF, v.input()) orelse continue;
        compared += 1;
        const gap = @abs(a - b);
        abs.update(gap, a, v);
        // Relative only where there is a price to be relative to; a 1e-9
        // absolute move on a 1e-30 price is a meaningless ratio.
        if (@abs(a) > 1e-6) {
            const ratio = gap / @abs(a);
            rel.update(ratio, a, v);
            if (@abs(a) >= 0.001 * v.f) rel_priced.update(ratio, a, v);
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
    if (abs.at) |v| {
        try w.print(
            \\  worst ABSOLUTE price gap  : {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\
        , .{ abs.gap, v.f, v.k, v.s, v.t, @tagName(v.kind) });
    }
    if (rel.at) |v| {
        try w.print(
            \\  worst RELATIVE gap        : {d:.4} bps on a price of {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\      -- near-worthless option; the ratio is true and economically empty
            \\
        , .{ rel.gap * 10000.0, rel.price, v.f, v.k, v.s, v.t, @tagName(v.kind) });
    }
    if (rel_priced.at) |v| {
        try w.print(
            \\  worst RELATIVE gap, priced: {d:.4} bps on a price of {d:.6}
            \\      at F={d} K={d} sigma={d} T={d}y {s}
            \\      -- restricted to options worth >= 0.1% of forward
            \\
        , .{ rel_priced.gap * 10000.0, rel_priced.price, v.f, v.k, v.s, v.t, @tagName(v.kind) });
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
