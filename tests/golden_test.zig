// golden_test.zig -- replay the committed fixture against the live kernel.
//
// The fixture is embedded at compile time, so this test is hermetic: it has no
// working directory, opens no files, and means the same thing wherever it runs.
//
// It reads the INPUTS from the fixture rather than regenerating them from the
// generator's case list. That is deliberate: the file is the contract, and a
// test that re-derived its own inputs could drift with the generator and still
// pass.

const std = @import("std");
const b76 = @import("black76");
const builtin = @import("builtin");
const fx = @import("fixture");
const fixture = @embedFile("golden_fixture");

// The parser is the shipped reference reader, not a test-local copy: if it
// drifts from what a consumer would use, the test stops testing the format.
const isHeader = fx.isHeader;
const hexField = fx.hexField;
const boolField = fx.boolField;
const strField = fx.strField;
const intField = fx.intField;
const Vector = fx.Vector;
const bits = fx.bits;
const bitEq = fx.bitEq;

fn parseAll(gpa: std.mem.Allocator) !std.ArrayList(Vector) {
    return fx.parseAll(gpa, fixture);
}

/// Printed only when something has already gone wrong. A passing run says
/// nothing: a green test that chatters trains you to skip reading it.
fn printProvenance() void {
    var it = std.mem.tokenizeScalar(u8, fixture, '\n');
    const first = it.next() orelse return;
    std.debug.print(
        \\
        \\  fixture captured by : zig {s} / {s} / cpu {s} / {s}
        \\  replaying on        : zig {s} / {s}-{s}-{s} / cpu {s} / {s}
        \\
    , .{
        strField(first, "zig_version") catch "?",
        strField(first, "target") catch "?",
        strField(first, "cpu") catch "?",
        strField(first, "optimize") catch "?",
        builtin.zig_version_string,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.cpu.model.name,
        @tagName(builtin.mode),
    });
}

test "fixture header is present and structurally sound" {
    var it = std.mem.tokenizeScalar(u8, fixture, '\n');
    const first = it.next() orelse return error.EmptyFixture;
    try std.testing.expect(isHeader(first));
    try std.testing.expectEqualStrings("black76-golden/1", try strField(first, "schema"));

    const declared = try intField(first, "vector_count");

    var counted: usize = 0;
    var it2 = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (it2.next()) |l| {
        if (!isHeader(l)) counted += 1;
    }
    try std.testing.expectEqual(declared, counted);
}

test "every golden vector reproduces bit-for-bit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const vs = try parseAll(gpa);
    try std.testing.expect(vs.items.len > 0);

    var failed: usize = 0;
    for (vs.items) |v| {
        var delta: f64 = undefined;
        var gamma: f64 = undefined;
        var theta: f64 = undefined;
        var vega: f64 = undefined;
        var price: f64 = undefined;
        b76.black76_greeks(v.f, v.k, v.s, v.t, v.c, &delta, &gamma, &theta, &vega, &price);

        const ok = bitEq(delta, v.delta) and bitEq(gamma, v.gamma) and
            bitEq(theta, v.theta) and bitEq(vega, v.vega) and bitEq(price, v.price);
        if (!ok) {
            failed += 1;
            if (failed == 1) printProvenance();
            if (failed <= 10) {
                std.debug.print(
                    \\
                    \\  MISMATCH line {d} [{s}] F={d} K={d} sigma={d} T={d} {s}
                    \\    delta  want 0x{X:0>16}  got 0x{X:0>16}
                    \\    gamma  want 0x{X:0>16}  got 0x{X:0>16}
                    \\    theta  want 0x{X:0>16}  got 0x{X:0>16}
                    \\    vega   want 0x{X:0>16}  got 0x{X:0>16}
                    \\    price  want 0x{X:0>16}  got 0x{X:0>16}
                    \\
                , .{
                    v.line_no,                  v.g,           v.f,         v.k,           v.s,         v.t,
                    if (v.c) "call" else "put", bits(v.delta), bits(delta), bits(v.gamma), bits(gamma), bits(v.theta),
                    bits(theta),                bits(v.vega),  bits(vega),  bits(v.price), bits(price),
                });
            }
        }
    }
    if (failed != 0) {
        std.debug.print("\n  {d} of {d} vectors differ. Not a tolerance question -- see README.\n", .{ failed, vs.items.len });
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "batch is bit-identical to the single-vector path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const vs = try parseAll(gpa);
    const n = vs.items.len;

    const fs = try gpa.alloc(f64, n);
    const ks = try gpa.alloc(f64, n);
    const ss = try gpa.alloc(f64, n);
    const ts = try gpa.alloc(f64, n);
    const cs = try gpa.alloc(bool, n);
    for (vs.items, 0..) |v, i| {
        fs[i] = v.f;
        ks[i] = v.k;
        ss[i] = v.s;
        ts[i] = v.t;
        cs[i] = v.c;
    }

    const bd = try gpa.alloc(f64, n);
    const bg = try gpa.alloc(f64, n);
    const bt = try gpa.alloc(f64, n);
    const bv = try gpa.alloc(f64, n);
    const bp = try gpa.alloc(f64, n);
    b76.black76_greeks_batch(fs.ptr, ks.ptr, ss.ptr, ts.ptr, cs.ptr, n, bd.ptr, bg.ptr, bt.ptr, bv.ptr, bp.ptr);

    // Compare the two LIVE paths against each other, not each against the
    // fixture. Comparing both to the file would pass transitively while the
    // golden test passes, and would point at the wrong thing when it failed.
    for (vs.items, 0..) |v, i| {
        var d: f64 = undefined;
        var g: f64 = undefined;
        var th: f64 = undefined;
        var ve: f64 = undefined;
        var pr: f64 = undefined;
        b76.black76_greeks(v.f, v.k, v.s, v.t, v.c, &d, &g, &th, &ve, &pr);
        try std.testing.expectEqual(bits(d), bits(bd[i]));
        try std.testing.expectEqual(bits(g), bits(bg[i]));
        try std.testing.expectEqual(bits(th), bits(bt[i]));
        try std.testing.expectEqual(bits(ve), bits(bv[i]));
        try std.testing.expectEqual(bits(pr), bits(bp[i]));
    }
}

test "the three degenerate branches disagree at F == K, and that is on purpose" {
    // If a refactor ever "tidies" the branches together, this is the test that
    // says so in one screen instead of leaving you to diff 3,500 hex strings.
    const F: f64 = 500.0;
    var d: f64 = undefined;
    var g: f64 = undefined;
    var th: f64 = undefined;
    var v: f64 = undefined;
    var p: f64 = undefined;

    // expired (ttm <= 0): the only branch that splits the difference at the money
    b76.black76_greeks(F, F, 0.5, 0.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.5), d);
    b76.black76_greeks(F, F, 0.5, 0.0, false, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, -0.5), d);

    // zero vol (sigma <= 0): no half-delta here
    b76.black76_greeks(F, F, 0.0, 1.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d);
    b76.black76_greeks(F, F, 0.0, 1.0, false, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d);

    // asymptotic (sigma*sqrt(ttm) < 1e-10): agrees with zero vol, not with expired
    b76.black76_greeks(F, F, 1e-11, 1.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d);
    b76.black76_greeks(F, F, 1e-11, 1.0, false, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d);
}

test "guard precedence is observable and fixed" {
    // The guards are checked invalid -> expired -> zero-vol -> asymptotic, and
    // they disagree, so the ORDER is part of the contract. These two lines are
    // the same volatility and differ only in whether ttm is zero or merely
    // tiny; the answers are 0.5 and 0.0.
    const F: f64 = 500.0;
    var d: f64 = undefined;
    var g: f64 = undefined;
    var th: f64 = undefined;
    var v: f64 = undefined;
    var p: f64 = undefined;

    b76.black76_greeks(F, F, 0.0, 0.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.5), d); // expired wins over zero-vol
    b76.black76_greeks(F, F, 0.0, 1e-30, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d); // zero-vol wins, ttm > 0

    b76.black76_greeks(F, F, 1e-11, 0.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.5), d); // expired wins over asymptotic

    // invalid outranks all three: no half-delta here even though ttm <= 0
    b76.black76_greeks(-0.0, F, 0.0, 0.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.0), d);
}

test "invalid inputs return five zeros, not NaN" {
    var d: f64 = undefined;
    var g: f64 = undefined;
    var th: f64 = undefined;
    var v: f64 = undefined;
    var p: f64 = undefined;
    for ([_]f64{ -1.0, -0.0, 0.0 }) |bad| {
        b76.black76_greeks(bad, 500.0, 0.5, 1.0, true, &d, &g, &th, &v, &p);
        try std.testing.expectEqual(@as(u64, 0), bits(d) | bits(g) | bits(th) | bits(v) | bits(p));
        b76.black76_greeks(500.0, bad, 0.5, 1.0, false, &d, &g, &th, &v, &p);
        try std.testing.expectEqual(@as(u64, 0), bits(d) | bits(g) | bits(th) | bits(v) | bits(p));
    }
}

test "normalCDF reflects exactly: N(-x) == 1 - N(x) for x != 0" {
    // Documented in the README, so it is pinned here. A&S 26.2.17 as written
    // computes the negative branch AS `1 - n_pos`, so the reflection is not
    // approximate -- it is the same expression. Anyone porting this should know
    // that, because it means the "well-conditioned separate evaluation" the put
    // path looks like it is doing is not actually doing it.
    var x: f64 = 1e-8;
    while (x < 40.0) : (x *= 1.7) {
        try std.testing.expectEqual(bits(1.0 - b76.normalCDF(x)), bits(b76.normalCDF(-x)));
        try std.testing.expectEqual(bits(1.0 - b76.normalCDF(-x)), bits(b76.normalCDF(x)));
    }
}

test "the human-readable decimal field matches the hex it sits beside" {
    // 43% of the fixture is the trailing "_" rendering, and the README points
    // readers at it. Without this test it is the one part of the file that can
    // say anything at all: a falsified "_" used to pass every other check.
    // It is still never the COMPARED value -- it is re-derived from the hex
    // and required to agree, which is the opposite relationship.
    var it = std.mem.splitScalar(u8, fixture, '\n');
    var line_no: usize = 0;
    var checked: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 or isHeader(line)) continue;
        const v = try fx.parseLine(line, line_no);
        const stored = try strField(line, "_");

        var buf: [1024]u8 = undefined;
        const rebuilt = try std.fmt.bufPrint(&buf, "F={d} K={d} sigma={d} T={e}y {s} -> price={e} delta={e} gamma={e} theta={e} vega={e}", .{
            v.f,                        v.k,     v.s,     v.t,
            if (v.c) "call" else "put", v.price, v.delta, v.gamma,
            v.theta,                    v.vega,
        });
        if (!std.mem.eql(u8, stored, rebuilt)) {
            std.debug.print("\n  line {d}: decimal field disagrees with its own hex\n    stored:  {s}\n    rebuilt: {s}\n", .{ line_no, stored, rebuilt });
            return error.DecimalFieldMismatch;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "guards catch <= 0, and what they do not catch is pinned too" {
    // The README makes specific claims about NaN and infinity. Claims in a
    // README rot; this is here so they cannot.
    //
    // Bit patterns are asserted only where they are portable. NaN sign and
    // payload are NOT guaranteed identical across architectures, so NaN is
    // checked with isNan() and nothing more -- which is also why no NaN vector
    // appears in the fixture itself.
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    var d: f64 = undefined;
    var g: f64 = undefined;
    var th: f64 = undefined;
    var v: f64 = undefined;
    var p: f64 = undefined;

    // NEGATIVE infinity IS caught: -inf <= 0.0 is true, so these take the
    // ordinary invalid / zero-vol exits and return five clean zeros.
    for ([_]bool{ true, false }) |call| {
        b76.black76_greeks(-inf, 500.0, 0.5, 1.0, call, &d, &g, &th, &v, &p);
        try std.testing.expectEqual(@as(u64, 0), bits(d) | bits(g) | bits(th) | bits(v) | bits(p));
        b76.black76_greeks(500.0, -inf, 0.5, 1.0, call, &d, &g, &th, &v, &p);
        try std.testing.expectEqual(@as(u64, 0), bits(d) | bits(g) | bits(th) | bits(v) | bits(p));
        b76.black76_greeks(500.0, 500.0, -inf, 1.0, call, &d, &g, &th, &v, &p);
        try std.testing.expectEqual(@as(u64, 0), bits(d) | bits(g) | bits(th) | bits(v) | bits(p));
    }

    // A maturity of -inf lands in the EXPIRED branch and comes back with the
    // at-the-money coin-flip delta. Surprising, and therefore worth pinning.
    b76.black76_greeks(500.0, 500.0, 0.5, -inf, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 0.5), d);
    b76.black76_greeks(500.0, 500.0, 0.5, -inf, false, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, -0.5), d);

    // POSITIVE infinity is not caught, and the result is partially finite --
    // the dangerous shape. A caller that checks one output and trusts the rest
    // gets an entirely ordinary-looking number out of a garbage input.
    b76.black76_greeks(inf, 500.0, 0.5, 1.0, true, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, 1.0), d); // looks like a normal deep-ITM call delta
    try std.testing.expectEqual(@as(u64, 0), bits(g));
    try std.testing.expect(std.math.isPositiveInf(p));
    try std.testing.expect(std.math.isNan(th));
    try std.testing.expect(std.math.isNan(v));

    // An infinite STRIKE on a put is the sharpest case: four perfectly
    // ordinary outputs and a plausible price. Nothing here looks wrong.
    b76.black76_greeks(500.0, inf, 0.5, 1.0, false, &d, &g, &th, &v, &p);
    try std.testing.expectEqual(@as(f64, -1.0), d);
    try std.testing.expectEqual(@as(u64, 0), bits(g));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(th)); // -0.0
    try std.testing.expectEqual(@as(u64, 0), bits(v));
    try std.testing.expect(std.math.isPositiveInf(p));

    // Every NaN input propagates NaN through all five outputs.
    for ([_]bool{ true, false }) |call| {
        for ([_]usize{ 0, 1, 2, 3 }) |which| {
            const F: f64 = if (which == 0) nan else 500.0;
            const K: f64 = if (which == 1) nan else 500.0;
            const S: f64 = if (which == 2) nan else 0.5;
            const T: f64 = if (which == 3) nan else 1.0;
            b76.black76_greeks(F, K, S, T, call, &d, &g, &th, &v, &p);
            try std.testing.expect(std.math.isNan(d) and std.math.isNan(g) and
                std.math.isNan(th) and std.math.isNan(v) and std.math.isNan(p));
        }
    }
}
