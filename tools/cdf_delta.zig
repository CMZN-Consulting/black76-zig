//! cdf_delta.zig -- what the v1 -> v2 model change did to prices.
//!
//!   zig build cdf-delta
//!
//! v1 used Abramowitz & Stegun 26.2.17, a rational polynomial with
//! |err| < 7.5e-8. v2 ships Hart's approximation (West 2005), ~1e-15, with
//! the lower tail computed directly. The swap was proposed as a cleanup and
//! adopted as a model change, by the owner of the P&L, on the strength of the
//! numbers this tool prints.
//!
//! It replays every input in the golden fixture through both CDFs and reports
//! the largest disagreement in PRICE, absolute and relative. The answer is not
//! "within tolerance" or "outside tolerance". There is no tolerance. The answer
//! is a number, and someone with P&L responsibility decides whether they want
//! it -- which, for v2, they did.

const std = @import("std");
const b76 = @import("black76");
const fx = @import("fixture");
const fixture_text = @embedFile("golden_fixture");

/// The v1 model: Abramowitz & Stegun 26.2.17, kept here verbatim as the
/// historical reference. Note the lower tail as `1 - n_pos`: once n_pos rounds
/// to 1, the tail is exactly 0.
fn v1CDF(x: f64) f64 {
    const b1: f64 = 0.319381530;
    const b2: f64 = -0.356563782;
    const b3: f64 = 1.781477937;
    const b4: f64 = -1.821255978;
    const b5: f64 = 1.330274429;
    const p: f64 = 0.2316419;
    const inv_sqrt_2pi: f64 = 0.3989422804014327;
    const ax = @abs(x);
    const k = 1.0 / (1.0 + p * ax);
    const pdf = inv_sqrt_2pi * @exp(-0.5 * ax * ax);
    const n_pos = 1.0 - pdf * (((((b5 * k + b4) * k + b3) * k + b2) * k + b1) * k);
    return if (x >= 0.0) n_pos else 1.0 - n_pos;
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
        const a = priceWith(v1CDF, v.input()) orelse continue;
        const b = priceWith(b76.normalCDF, v.input()) orelse continue;
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
        \\v1 Abramowitz & Stegun 26.2.17  vs  v2 (shipped) Hart / West normal CDF
        \\  vectors compared          : {d} (degenerate branches skipped -- they never call the CDF)
        \\  gaps are |v1 price - v2 price|; ratios are relative to the v1 price
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
        \\Each of those is a real difference in a real price. This is why the
        \\fixture has no tolerance band: a band wide enough to admit this swap
        \\would hide it, and hiding it is the failure mode. v2 adopted the swap
        \\knowingly; the v1 fixture is kept in vectors/ so the diff is on record.
        \\
    , .{});
    try w.flush();
}
