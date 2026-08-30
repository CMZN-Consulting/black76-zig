//! golden_test.zig -- replay the committed fixture against the live kernel.
//!
//! The fixture is embedded at compile time, so this test is hermetic: it has no
//! working directory, opens no files, and means the same thing wherever it runs.
//!
//! It reads the INPUTS from the fixture rather than regenerating them from the
//! generator's case list. That is deliberate: the file is the contract, and a
//! test that re-derived its own inputs could drift with the generator and still
//! pass.
//!
//! Memory: every test that needs the parsed vectors takes them from
//! `std.testing.allocator`, sized exactly from the header, and frees them. The
//! testing allocator fails the test on a leak, so "the reader does not leak" is
//! itself under test.

const std = @import("std");
const b76 = @import("black76");
const builtin = @import("builtin");
const fx = @import("fixture");
const fixture = @embedFile("golden_fixture");

const bits = fx.bits;

/// Printed only when something has already gone wrong. A passing run says
/// nothing: a green test that chatters trains you to skip reading it.
fn printProvenance() void {
    const header = fx.parseHeader(fixture) catch return;
    std.debug.print(
        \\
        \\  fixture captured by : zig {s} / {s} / cpu {s} / {s}
        \\  replaying on        : zig {s} / {s}-{s}-{s} / cpu {s} / {s}
        \\
    , .{
        header.zig_version,
        header.target,
        header.cpu,
        header.optimize,
        builtin.zig_version_string,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.cpu.model.name,
        @tagName(builtin.mode),
    });
}

fn greeksVia(comptime path: enum { zig, c_abi }, in: b76.Input) b76.Greeks {
    switch (path) {
        .zig => return b76.greeks(in),
        .c_abi => {
            var out: b76.Greeks = undefined;
            b76.black76_greeks(in.forward, in.strike, in.sigma, in.ttm, in.kind == .call, &out.delta, &out.gamma, &out.theta, &out.vega, &out.price);
            return out;
        },
    }
}

test "fixture header is present and structurally sound" {
    const header = try fx.parseHeader(fixture);
    try std.testing.expectEqualStrings("black76-golden/2", header.schema);

    var counted: usize = 0;
    var it = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (it.next()) |line| {
        if (!fx.isHeader(line)) counted += 1;
    }
    try std.testing.expectEqual(header.vector_count, counted);
}

test "every golden vector reproduces bit-for-bit" {
    const vs = try fx.parseAlloc(std.testing.allocator, fixture);
    defer std.testing.allocator.free(vs);
    try std.testing.expect(vs.len > 0);

    var failed: usize = 0;
    for (vs) |v| {
        const got = b76.greeks(v.input());
        const want = v.expected();
        if (fx.greeksBitEq(got, want)) continue;

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
                v.line_no,        v.g,              v.f,             v.k,              v.s,             v.t,
                @tagName(v.kind), bits(want.delta), bits(got.delta), bits(want.gamma), bits(got.gamma), bits(want.theta),
                bits(got.theta),  bits(want.vega),  bits(got.vega),  bits(want.price), bits(got.price),
            });
        }
    }
    if (failed != 0) {
        std.debug.print("\n  {d} of {d} vectors differ. Not a tolerance question -- see README.\n", .{ failed, vs.len });
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "the C ABI is a bit-identical wrapper over the Zig API" {
    const vs = try fx.parseAlloc(std.testing.allocator, fixture);
    defer std.testing.allocator.free(vs);

    for (vs) |v| {
        const via_zig = greeksVia(.zig, v.input());
        const via_c = greeksVia(.c_abi, v.input());
        try std.testing.expect(fx.greeksBitEq(via_zig, via_c));
    }
}

test "batch is bit-identical to the single-vector path" {
    const gpa = std.testing.allocator;
    const vs = try fx.parseAlloc(gpa, fixture);
    defer gpa.free(vs);
    const n = vs.len;

    // Caller-owned structure-of-arrays, sized exactly.
    const fs = try gpa.alloc(f64, n);
    defer gpa.free(fs);
    const ks = try gpa.alloc(f64, n);
    defer gpa.free(ks);
    const ss = try gpa.alloc(f64, n);
    defer gpa.free(ss);
    const ts = try gpa.alloc(f64, n);
    defer gpa.free(ts);
    const kinds = try gpa.alloc(b76.Kind, n);
    defer gpa.free(kinds);
    for (vs, 0..) |v, i| {
        fs[i] = v.f;
        ks[i] = v.k;
        ss[i] = v.s;
        ts[i] = v.t;
        kinds[i] = v.kind;
    }

    const out = try gpa.alloc(f64, 5 * n);
    defer gpa.free(out);
    const outputs: b76.BatchOutputs = .{
        .deltas = out[0 * n ..][0..n],
        .gammas = out[1 * n ..][0..n],
        .thetas = out[2 * n ..][0..n],
        .vegas = out[3 * n ..][0..n],
        .prices = out[4 * n ..][0..n],
    };
    b76.greeksBatch(.{ .forwards = fs, .strikes = ks, .sigmas = ss, .ttms = ts, .kinds = kinds }, outputs);

    // Compare the two LIVE paths against each other, not each against the
    // fixture. Comparing both to the file would pass transitively while the
    // golden test passes, and would point at the wrong thing when it failed.
    for (vs, 0..) |v, i| {
        const single = b76.greeks(v.input());
        try std.testing.expectEqual(bits(single.delta), bits(outputs.deltas[i]));
        try std.testing.expectEqual(bits(single.gamma), bits(outputs.gammas[i]));
        try std.testing.expectEqual(bits(single.theta), bits(outputs.thetas[i]));
        try std.testing.expectEqual(bits(single.vega), bits(outputs.vegas[i]));
        try std.testing.expectEqual(bits(single.price), bits(outputs.prices[i]));
    }

    // And the C ABI batch, which views the bool array as kinds without a copy.
    const is_calls = try gpa.alloc(bool, n);
    defer gpa.free(is_calls);
    for (kinds, 0..) |kind, i| is_calls[i] = kind == .call;
    const out_c = try gpa.alloc(f64, 5 * n);
    defer gpa.free(out_c);
    b76.black76_greeks_batch(fs.ptr, ks.ptr, ss.ptr, ts.ptr, is_calls.ptr, n, out_c[0 * n ..].ptr, out_c[1 * n ..].ptr, out_c[2 * n ..].ptr, out_c[3 * n ..].ptr, out_c[4 * n ..].ptr);
    try std.testing.expectEqualSlices(u64, @ptrCast(out), @ptrCast(out_c));
}

test "the three degenerate branches disagree at F == K, and that is on purpose" {
    // If a refactor ever "tidies" the branches together, this is the test that
    // says so in one screen instead of leaving you to diff 3,500 hex strings.
    const F: f64 = 500.0;

    // expired (ttm <= 0): the only branch that splits the difference at the money
    try std.testing.expectEqual(@as(f64, 0.5), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.5, .ttm = 0.0, .kind = .call }).delta);
    try std.testing.expectEqual(@as(f64, -0.5), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.5, .ttm = 0.0, .kind = .put }).delta);

    // zero vol (sigma <= 0): no half-delta here
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.0, .ttm = 1.0, .kind = .call }).delta);
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.0, .ttm = 1.0, .kind = .put }).delta);

    // asymptotic (sigma*sqrt(ttm) < 1e-10): agrees with zero vol, not with expired
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = F, .strike = F, .sigma = 1e-11, .ttm = 1.0, .kind = .call }).delta);
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = F, .strike = F, .sigma = 1e-11, .ttm = 1.0, .kind = .put }).delta);
}

test "guard precedence is observable and fixed" {
    // The guards are checked invalid -> expired -> zero-vol -> asymptotic, and
    // they disagree, so the ORDER is part of the contract. These two lines are
    // the same volatility and differ only in whether ttm is zero or merely
    // tiny; the answers are 0.5 and 0.0.
    const F: f64 = 500.0;

    try std.testing.expectEqual(@as(f64, 0.5), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.0, .ttm = 0.0, .kind = .call }).delta); // expired wins over zero-vol
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = F, .strike = F, .sigma = 0.0, .ttm = 1e-30, .kind = .call }).delta); // zero-vol wins, ttm > 0
    try std.testing.expectEqual(@as(f64, 0.5), b76.greeks(.{ .forward = F, .strike = F, .sigma = 1e-11, .ttm = 0.0, .kind = .call }).delta); // expired wins over asymptotic

    // invalid outranks all three: no half-delta here even though ttm <= 0
    try std.testing.expectEqual(@as(f64, 0.0), b76.greeks(.{ .forward = -0.0, .strike = F, .sigma = 0.0, .ttm = 0.0, .kind = .call }).delta);
}

fn allZeroBits(g: b76.Greeks) bool {
    return (bits(g.delta) | bits(g.gamma) | bits(g.theta) | bits(g.vega) | bits(g.price)) == 0;
}

test "invalid inputs return five zeros, not NaN" {
    for ([_]f64{ -1.0, -0.0, 0.0 }) |bad| {
        try std.testing.expect(allZeroBits(b76.greeks(.{ .forward = bad, .strike = 500.0, .sigma = 0.5, .ttm = 1.0, .kind = .call })));
        try std.testing.expect(allZeroBits(b76.greeks(.{ .forward = 500.0, .strike = bad, .sigma = 0.5, .ttm = 1.0, .kind = .put })));
    }
}

test "the lower tail is computed directly, not as 1 - N(|x|)" {
    // Model v2 (Hart / West). The v1 approximation returned exactly 0 for
    // N(-x) once N(x) rounded to 1, at x > ~8.3. Pinned here because it is the
    // visible difference between the models on deep wings, and because a
    // "cleanup" back to the reflection form would pass every other test.
    try std.testing.expect(b76.normalCDF(-10.0) > 0.0);
    try std.testing.expect(b76.normalCDF(-30.0) > 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), b76.normalCDF(-38.0));
    try std.testing.expectEqual(@as(f64, 1.0), b76.normalCDF(38.0));
    // And N(-x) from phi is N(x) with the sign flipped, to the bit.
    var x: f64 = 1e-8;
    while (x < 40.0) : (x *= 1.7) {
        try std.testing.expectEqual(bits(b76.phi(x).neg), bits(b76.phi(-x).pos));
        try std.testing.expectEqual(bits(b76.phi(x).pos), bits(b76.phi(-x).neg));
    }
}

test "the human-readable decimal field matches the hex it sits beside" {
    // 43% of the fixture is the trailing "_" rendering, and the README points
    // readers at it. Without this test it is the one part of the file that can
    // say anything at all: a falsified "_" used to pass every other check.
    // It is still never the COMPARED value -- it is re-derived from the hex
    // and required to agree, which is the opposite relationship.
    var it = std.mem.splitScalar(u8, fixture, '\n');
    var line_no: u32 = 0;
    var checked: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 or fx.isHeader(line)) continue;
        const v = try fx.parseLine(line, line_no);
        const stored = try fx.strField(line, "_");

        var buf: [1024]u8 = undefined;
        const rebuilt = try std.fmt.bufPrint(&buf, "F={d} K={d} sigma={d} T={e}y {s} -> price={e} delta={e} gamma={e} theta={e} vega={e}", .{
            v.f,              v.k,     v.s,     v.t,
            @tagName(v.kind), v.price, v.delta, v.gamma,
            v.theta,          v.vega,
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

    // NEGATIVE infinity IS caught: -inf <= 0.0 is true, so these take the
    // ordinary invalid / zero-vol exits and return five clean zeros.
    for ([_]b76.Kind{ .call, .put }) |kind| {
        try std.testing.expect(allZeroBits(b76.greeks(.{ .forward = -inf, .strike = 500.0, .sigma = 0.5, .ttm = 1.0, .kind = kind })));
        try std.testing.expect(allZeroBits(b76.greeks(.{ .forward = 500.0, .strike = -inf, .sigma = 0.5, .ttm = 1.0, .kind = kind })));
        try std.testing.expect(allZeroBits(b76.greeks(.{ .forward = 500.0, .strike = 500.0, .sigma = -inf, .ttm = 1.0, .kind = kind })));
    }

    // A maturity of -inf lands in the EXPIRED branch and comes back with the
    // at-the-money coin-flip delta. Surprising, and therefore worth pinning.
    try std.testing.expectEqual(@as(f64, 0.5), b76.greeks(.{ .forward = 500.0, .strike = 500.0, .sigma = 0.5, .ttm = -inf, .kind = .call }).delta);
    try std.testing.expectEqual(@as(f64, -0.5), b76.greeks(.{ .forward = 500.0, .strike = 500.0, .sigma = 0.5, .ttm = -inf, .kind = .put }).delta);

    // POSITIVE infinity is not caught, and the result is partially finite --
    // the dangerous shape. A caller that checks one output and trusts the rest
    // gets an entirely ordinary-looking number out of a garbage input.
    const inf_forward = b76.greeks(.{ .forward = inf, .strike = 500.0, .sigma = 0.5, .ttm = 1.0, .kind = .call });
    try std.testing.expectEqual(@as(f64, 1.0), inf_forward.delta); // looks like a normal deep-ITM call delta
    try std.testing.expectEqual(@as(u64, 0), bits(inf_forward.gamma));
    try std.testing.expect(std.math.isPositiveInf(inf_forward.price));
    try std.testing.expect(std.math.isNan(inf_forward.theta));
    try std.testing.expect(std.math.isNan(inf_forward.vega));

    // An infinite STRIKE on a put is the sharpest case: four perfectly
    // ordinary outputs and a plausible price. Nothing here looks wrong.
    const inf_strike = b76.greeks(.{ .forward = 500.0, .strike = inf, .sigma = 0.5, .ttm = 1.0, .kind = .put });
    try std.testing.expectEqual(@as(f64, -1.0), inf_strike.delta);
    try std.testing.expectEqual(@as(u64, 0), bits(inf_strike.gamma));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(inf_strike.theta)); // -0.0
    try std.testing.expectEqual(@as(u64, 0), bits(inf_strike.vega));
    try std.testing.expect(std.math.isPositiveInf(inf_strike.price));

    // Every NaN input propagates NaN through all five outputs.
    for ([_]b76.Kind{ .call, .put }) |kind| {
        for ([_]usize{ 0, 1, 2, 3 }) |which| {
            const g = b76.greeks(.{
                .forward = if (which == 0) nan else 500.0,
                .strike = if (which == 1) nan else 500.0,
                .sigma = if (which == 2) nan else 0.5,
                .ttm = if (which == 3) nan else 1.0,
                .kind = kind,
            });
            try std.testing.expect(std.math.isNan(g.delta) and std.math.isNan(g.gamma) and
                std.math.isNan(g.theta) and std.math.isNan(g.vega) and std.math.isNan(g.price));
        }
    }
}

test "postconditions hold across the whole fixture" {
    // Positive space: what every finite output must satisfy. The kernel asserts
    // these in Debug; this makes them true in every optimisation mode.
    const vs = try fx.parseAlloc(std.testing.allocator, fixture);
    defer std.testing.allocator.free(vs);

    for (vs) |v| {
        const g = v.expected();
        try std.testing.expect(g.gamma >= 0.0);
        try std.testing.expect(g.vega >= 0.0);
        try std.testing.expect(g.theta <= 0.0);
        try std.testing.expect(g.price >= 0.0);
        try std.testing.expect(@abs(g.delta) <= 1.0);
        switch (v.kind) {
            .call => try std.testing.expect(g.delta >= 0.0),
            .put => try std.testing.expect(g.delta <= 0.0),
        }
    }
}
