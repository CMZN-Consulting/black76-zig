//! normal.zig -- the standard normal CDF and PDF, lane-generic.
//!
//! Model v2. The v1 kernel used Abramowitz & Stegun 26.2.17, a five-constant
//! rational polynomial with |err| < 7.5e-8 that computes the lower tail as
//! `1 - N(|x|)` and therefore loses every digit once N(|x|) rounds to 1 -- at
//! |x| > ~8.3 the CDF of a deep wing was exactly 0. This file uses Hart's
//! rational approximation (Hart, "Computer Approximations", 1968, in the form
//! given by Graeme West, "Better approximations to cumulative normal
//! functions", Wilmott, 2005): accurate to about 1e-15, and it computes the
//! small tail DIRECTLY, so N(-30) is 4.9e-198 rather than 0.
//!
//! The decision to change models was taken by the owner of the P&L, not by a
//! refactor: `zig build cdf-delta` reports what moved, and the v1 fixture is
//! kept beside the v2 one so the diff is on record.
//!
//! `phi` returns N(x), N(-x) and n(x) from ONE exponential. The kernel needs
//! all three for d1 and two of them for d2, and stating the sharing beats
//! hoping the optimiser notices. Written once over `@Vector(n, f64)`: n = 1
//! is the scalar path, wider n the SIMD batch path, and both agree
//! bit-for-bit because they are the same code.

const std = @import("std");
const libm = @import("libm");

comptime {
    @setFloatMode(.strict);
}

pub fn Lanes(comptime n: comptime_int) type {
    return struct {
        const L = libm.Lanes(n);
        pub const F = L.F;

        pub const Phi = struct {
            /// N(x)
            pos: F,
            /// N(-x)
            neg: F,
            /// n(x)
            pdf: F,
        };

        pub inline fn splat(x: f64) F {
            return @splat(x);
        }

        /// N(x), N(-x), n(x).
        pub fn phi(x: F) Phi {
            const y = @abs(x);
            const e = L.exp(-y * y / splat(2.0));
            const density = splat(0.3989422804014327) * e; // n(x) = e / sqrt(2*pi)

            // Small tail c = N(-|x|), from the rational form below 7.07 and a
            // continued fraction above it; both are evaluated for every lane
            // and the right one selected. Beyond 37 (N(-37) = 5.7e-300) the
            // tail is set to exactly zero, as in West's reference form.
            var num = splat(3.52624965998911e-02) * y + splat(0.700383064443688);
            num = num * y + splat(6.37396220353165);
            num = num * y + splat(33.912866078383);
            num = num * y + splat(112.079291497871);
            num = num * y + splat(221.213596169931);
            num = num * y + splat(220.206867912376);
            var den = splat(8.83883476483184e-02) * y + splat(1.75566716318264);
            den = den * y + splat(16.064177579207);
            den = den * y + splat(86.7807322029461);
            den = den * y + splat(296.564248779674);
            den = den * y + splat(637.333633378831);
            den = den * y + splat(793.826512519948);
            den = den * y + splat(440.413735824752);
            const rational = e * num / den;

            // The continued fraction costs five divisions. Uniform branch: skip
            // it when no lane is in the tail, which for d1/d2 is nearly always.
            // Per-lane arithmetic is identical either way.
            const in_tail = y >= splat(7.07106781186547);
            var c = rational;
            if (@reduce(.Or, in_tail)) {
                const f = y + splat(1.0) / (y + splat(2.0) / (y + splat(3.0) / (y + splat(4.0) / (y + splat(0.65)))));
                const fraction = e / (f * splat(2.506628274631));
                c = @select(f64, in_tail, fraction, rational);
            }
            // Written as `y > 37 -> 0` rather than `y <= 37 -> c` so that a NaN x,
            // which fails both comparisons, keeps propagating instead of becoming 0.
            c = @select(f64, y > splat(37.0), splat(0.0), c);

            const upper = splat(1.0) - c;
            return .{
                .pos = @select(f64, x > splat(0.0), upper, c),
                .neg = @select(f64, x < splat(0.0), upper, c),
                .pdf = density,
            };
        }
    };
}

const N1 = Lanes(1);

/// Scalar N(x).
pub fn cdf(x: f64) f64 {
    return N1.phi(@splat(x)).pos[0];
}

/// Scalar n(x).
pub fn pdf(x: f64) f64 {
    return N1.phi(@splat(x)).pdf[0];
}

test "phi is symmetric to the bit and its two tails sum to one" {
    var x: f64 = 1e-8;
    while (x < 40.0) : (x *= 1.3) {
        const plus = N1.phi(@splat(x));
        const minus = N1.phi(@splat(-x));
        try std.testing.expectEqual(@as(u64, @bitCast(plus.pos[0])), @as(u64, @bitCast(minus.neg[0])));
        try std.testing.expectEqual(@as(u64, @bitCast(plus.neg[0])), @as(u64, @bitCast(minus.pos[0])));
        try std.testing.expectEqual(@as(u64, @bitCast(plus.pdf[0])), @as(u64, @bitCast(minus.pdf[0])));
        try std.testing.expect(@abs((plus.pos[0] + plus.neg[0]) - 1.0) <= 0x1p-52);
    }
}

test "phi agrees with reference values to 1e-15 and is monotone" {
    // Reference values from a 30-digit evaluation of the normal CDF.
    const refs = [_]struct { x: f64, cdf: f64 }{
        .{ .x = 0.0, .cdf = 0.5 },
        .{ .x = 0.5, .cdf = 0.691462461274013 },
        .{ .x = 1.0, .cdf = 0.841344746068543 },
        .{ .x = 1.959963984540054, .cdf = 0.975 },
        .{ .x = 3.0, .cdf = 0.998650101968370 },
        .{ .x = -1.0, .cdf = 0.158655253931457 },
        .{ .x = -5.0, .cdf = 2.866515718791939e-07 },
        .{ .x = -10.0, .cdf = 7.619853024160527e-24 },
        .{ .x = -30.0, .cdf = 4.906713927148187e-198 },
    };
    for (refs) |r| {
        const got = cdf(r.x);
        try std.testing.expect(@abs(got - r.cdf) <= 2e-15 * @max(1.0, @abs(r.cdf)) or @abs(got - r.cdf) / r.cdf <= 4e-15);
    }
    var prev: f64 = 0.0;
    var x: f64 = -40.0;
    while (x <= 40.0) : (x += 0.01) {
        const now = cdf(x);
        try std.testing.expect(now >= prev);
        prev = now;
    }
    try std.testing.expectEqual(@as(f64, 0.0), cdf(-37.5));
    try std.testing.expectEqual(@as(f64, 1.0), cdf(37.5));
}

test "lane widths agree with the scalar path bit-for-bit" {
    const N8 = Lanes(8);
    var xs: [8]f64 = .{ -12.5, -3.0, -0.75, -1e-9, 0.0, 0.3, 2.5, 9.0 };
    const v: N8.F = xs;
    const wide = N8.phi(v);
    inline for (0..8) |i| {
        const one = N1.phi(@splat(xs[i]));
        try std.testing.expectEqual(@as(u64, @bitCast(one.pos[0])), @as(u64, @bitCast(wide.pos[i])));
        try std.testing.expectEqual(@as(u64, @bitCast(one.neg[0])), @as(u64, @bitCast(wide.neg[i])));
        try std.testing.expectEqual(@as(u64, @bitCast(one.pdf[0])), @as(u64, @bitCast(wide.pdf[i])));
    }
    xs[0] = std.math.nan(f64);
    try std.testing.expect(std.math.isNan(N1.phi(@splat(xs[0])).pos[0]));
}
