//! Black-76 option pricing and Greeks.
//!
//! One option in, five numbers out. The kernel is a pure function of its
//! arguments: no allocator, no global state, no I/O, and every floating-point
//! operation is evaluated in strict IEEE-754 mode so that the same source
//! produces the same bits on every optimisation level (see `vectors/`).
//! exp, log and the normal distribution live in this repository (src/libm.zig,
//! src/normal.zig), so those bits depend on nothing outside it either.
//!
//! Model, with the discount factor written out. Writing s for sigma*sqrt(T),
//! d1 is evaluated as `A/s + s/2` and NOT as the algebraically equal
//! `[A + 0.5*sigma^2*T]/s`, and A as `ln(F/K)` with a fallback to
//! `ln(F) - ln(K)` only where the ratio itself over- or underflows. Those are
//! the v2 -> v3 model change: they keep every intermediate finite without
//! giving up a digit at the money. `zig build assoc-delta` prices the
//! difference; see `logMoneyness` for why the fallback is conditional.
//!
//!   A     = ln(F/K)
//!   d1    = A/(sigma*sqrt(T)) + sigma*sqrt(T)/2
//!   d2    = d1 - sigma*sqrt(T)
//!   Call  = e^{-rT} * [F*N(d1) - K*N(d2)]
//!   Put   = e^{-rT} * [K*N(-d2) - F*N(-d1)]
//!   Gamma = e^{-rT} * n(d1) / (F * sigma * sqrt(T))
//!   Theta = -[F * sigma * e^{-rT} * n(d1)] / (2*sqrt(T))
//!   Vega  = F * e^{-rT} * n(d1) * sqrt(T)
//!
//! Two ABI facts that are easy to get wrong, so they are stated here:
//!
//!   1. r = 0 is hardcoded, so e^{-rT} is the literal 1.0. There is no rate
//!      parameter and there is no rate axis. This is a deliberate modelling
//!      choice for a zero-carry setting, not an omission.
//!   2. `ttm` is a fraction of a YEAR, and `theta` comes back PER YEAR. There
//!      is no /365 anywhere below. Any per-day convention belongs above this
//!      boundary, in the caller.
//!
//! Degenerate inputs (T<=0, sigma<=0, F<=0, K<=0, and sigma*sqrt(T) either
//! vanishing or unbounded) are handled by five separate early-return branches,
//! checked in a fixed order. The three intrinsic ones do NOT all agree with
//! each other at F == K -- see the README. That disagreement is observable,
//! pinned by the golden vectors, and must be preserved by any reimplementation.
//!
//! Two surfaces are exported:
//!
//!   * A Zig-native API (`Input`, `Greeks`, `greeks`, `greeksBatch`) that works
//!     on structs and caller-owned slices.
//!   * A flat C ABI (`black76_greeks`, `black76_greeks_batch`) with five
//!     out-pointers, for dlopen/FFI hosts. It is a thin wrapper over the Zig
//!     API and is required to stay bit-identical to it.

const std = @import("std");
const assert = std.debug.assert;
const libm = @import("libm");
const normal = @import("normal");

/// Scalar exp/log and normal distribution from this repository, so the
/// kernel's bits depend on nothing outside it -- not on whichever compiler_rt
/// or libc happens to be linked.
const L1 = libm.Lanes(1);
const N1 = normal.Lanes(1);

inline fn log(x: f64) f64 {
    return L1.log(L1.splat(x))[0];
}

comptime {
    // The golden vectors are a contract on bits. `.strict` is already the
    // default; it is set here so that the contract is visible in the source
    // and survives anyone adding `.optimized` to a parent scope.
    @setFloatMode(.strict);
}

// -- Types --------------------------------------------------------------------

/// Call or put. Represented as a byte with put = 0 and call = 1 so that a C
/// `bool is_call` array can be viewed as a `[]const Kind` without a copy.
pub const Kind = enum(u8) {
    put = 0,
    call = 1,

    pub fn fromIsCall(is_call: bool) Kind {
        return @enumFromInt(@intFromBool(is_call));
    }
};

comptime {
    // The zero-copy view in `black76_greeks_batch` depends on these.
    assert(@sizeOf(Kind) == @sizeOf(bool));
    assert(@intFromEnum(Kind.call) == @intFromBool(true));
    assert(@intFromEnum(Kind.put) == @intFromBool(false));
}

/// One option to price. `ttm` is in years.
pub const Input = struct {
    forward: f64,
    strike: f64,
    sigma: f64,
    ttm: f64,
    kind: Kind,
};

/// The five outputs. `extern` so the layout is fixed and FFI hosts can take it
/// by pointer if they prefer a struct to five out-pointers.
pub const Greeks = extern struct {
    delta: f64,
    gamma: f64,
    theta: f64,
    vega: f64,
    price: f64,

    pub const zero: Greeks = .{ .delta = 0.0, .gamma = 0.0, .theta = 0.0, .vega = 0.0, .price = 0.0 };
};

comptime {
    assert(@sizeOf(Greeks) == 5 * @sizeOf(f64));
}

/// Structure-of-arrays batch input. All slices must have equal length; the
/// kernel asserts it and never allocates.
pub const BatchInputs = struct {
    forwards: []const f64,
    strikes: []const f64,
    sigmas: []const f64,
    ttms: []const f64,
    kinds: []const Kind,

    pub fn len(inputs: BatchInputs) usize {
        assert(inputs.strikes.len == inputs.forwards.len);
        assert(inputs.sigmas.len == inputs.forwards.len);
        assert(inputs.ttms.len == inputs.forwards.len);
        assert(inputs.kinds.len == inputs.forwards.len);
        return inputs.forwards.len;
    }
};

/// Structure-of-arrays batch output. Caller-owned; the kernel writes every
/// element of every slice exactly once and reads none of them.
pub const BatchOutputs = struct {
    deltas: []f64,
    gammas: []f64,
    thetas: []f64,
    vegas: []f64,
    prices: []f64,

    pub fn len(outputs: BatchOutputs) usize {
        assert(outputs.gammas.len == outputs.deltas.len);
        assert(outputs.thetas.len == outputs.deltas.len);
        assert(outputs.vegas.len == outputs.deltas.len);
        assert(outputs.prices.len == outputs.deltas.len);
        return outputs.deltas.len;
    }
};

/// Below this, sigma*sqrt(T) is treated as zero: d1 would otherwise run off to
/// +/-inf and the arithmetic stops meaning anything.
pub const sigma_sqrt_t_min: f64 = 1e-10;

/// Above this, sigma*sqrt(T) is treated as unbounded. The other end of exactly
/// the same problem `sigma_sqrt_t_min` guards, on exactly the same quantity:
/// there the denominator of A/s vanished, here s itself runs away.
///
/// Model v3 writes d1 as `A/s + s/2` rather than `(A + 0.5*sigma^2*T)/s`, which
/// leaves `s = sigma*sqrt(T)` as the ONE quantity in the whole kernel that can
/// still overflow (see the note on `priceOne`). So a bound on s is now not just
/// sufficient, it is the only bound there is anything to state. Under v2's
/// association a bound on s was provably NOT enough -- `0.5*sigma*sigma`
/// overflowed on its own at sigma > sqrt(2*floatMax) = 1.8964e154 while s
/// stayed small -- and that is precisely what the re-association removed.
///
/// The value is bounded on one side only, and loosely:
///
///   * There is no upper constraint. Every finite s produces a finite,
///     correctly-signed d1 and d2, so the guard exists to catch s = +inf and
///     nothing else. Any finite threshold is safe.
///   * The lower constraint is the plateau. N(d2) is exactly 0 once d2 < -37
///     and N(d1) exactly 1 once d1 > ~8.3; with |A| < 1455 the worst case is
///     `0.5*s - 1455/s > 37`, satisfied from s = 110 upward. So from s ~ 110 to
///     floatMax -- about 306 decades -- the main path already returns df*F for
///     a call and df*K for a put, to the bit, for every F and K.
///
/// 1e10 sits eight decades inside that plateau, so the guard is a continuation
/// of the main path and not a cliff, and it cannot fire on anything real: it
/// needs sigma > 1e9 at T = 100 years, a volatility of 1e11 percent. It is
/// written as the mirror of `sigma_sqrt_t_min` because that reads well and the
/// margin is enormous either way -- not because 1e-10 derives it.
pub const sigma_sqrt_t_max: f64 = 1e10;

// -- Standard normal distribution ---------------------------------------------

/// N(x), N(-x) and n(x) from ONE exponential (see src/normal.zig). The kernel
/// needs all three for d1 and two of them for d2, and asking for them together
/// states the sharing in the source instead of hoping the optimiser notices
/// that exp(-x^2/2) is the same number every time. Measured: a kernel that
/// called three separate functions ran ~30% slower once the exp was inlined,
/// because common-subexpression elimination stopped seeing through the
/// branches.
pub const Phi = struct {
    /// N(x)
    pos: f64,
    /// N(-x)
    neg: f64,
    /// n(x)
    pdf: f64,
};

/// Model v2: Hart's rational approximation (West 2005), ~1e-15, lower tail
/// computed directly. v1 was Abramowitz & Stegun 26.2.17 (|err| < 7.5e-8,
/// lower tail as 1 - N(|x|)); `zig build cdf-delta` prices the difference.
pub fn phi(x: f64) Phi {
    const p = N1.phi(N1.splat(x));
    return .{ .pos = p.pos[0], .neg = p.neg[0], .pdf = p.pdf[0] };
}

/// Standard normal CDF, N(x). See `phi`.
pub fn normalCDF(x: f64) f64 {
    return phi(x).pos;
}

/// Standard normal PDF, n(x) = exp(-x^2/2) / sqrt(2*pi). See `phi`.
pub fn normalPDF(x: f64) f64 {
    return phi(x).pdf;
}

// -- Black-76 core ------------------------------------------------------------

/// Price and Greeks for one option. Pure; never allocates; never traps.
///
/// Guard order is part of the contract: invalid -> expired -> zero vol ->
/// vanishing sigma*sqrt(T) -> unbounded sigma*sqrt(T). NaN is NOT caught by any
/// of them and propagates; +inf in sigma or ttm reaches guard 5, +inf in
/// forward or strike does not. Validate inputs above this boundary.
pub fn greeks(in: Input) Greeks {
    return priceOne(in);
}

/// The kernel body. `inline` is not a hint here, it is the point: the batch
/// loop and the C ABI must get this body inlined REGARDLESS of how many other
/// call sites exist, or the 40-byte `Greeks` is returned through memory and
/// the batch path is measurably slower (about +30% on x86_64; see bench).
/// Being explicit about it beats depending on the optimiser's cost model.
inline fn priceOne(in: Input) Greeks {
    // Guard 1: nonsense input. -inf, -0.0 and 0.0 all land here.
    if (in.forward <= 0.0 or in.strike <= 0.0) {
        @branchHint(.unlikely);
        return Greeks.zero;
    }

    // Guard 2: expired -- intrinsic value, and the one branch that splits the
    // difference at the money.
    if (in.ttm <= 0.0) {
        @branchHint(.unlikely);
        return intrinsic(in, .half_delta_at_the_money);
    }

    // Guard 3: zero or negative vol -- intrinsic value, no half delta.
    if (in.sigma <= 0.0) {
        @branchHint(.unlikely);
        return intrinsic(in, .zero_delta_at_the_money);
    }

    const sqrt_t = @sqrt(in.ttm);
    const sigma_sqrt_t = in.sigma * sqrt_t;

    // Guard 4: sigma*sqrt(T) so small the maths breaks down -- as guard 3.
    if (sigma_sqrt_t < sigma_sqrt_t_min) {
        @branchHint(.unlikely);
        return intrinsic(in, .zero_delta_at_the_money);
    }

    // Guard 5: sigma*sqrt(T) so large the maths breaks down the other way. The
    // only quantity left that can overflow is s itself, and once it is +inf,
    // d2 = d1 - s is inf - inf = NaN. Spelled `> max` and not `!(<= max)` so
    // that a NaN falls through and propagates, exactly as guards 1-4 let it.
    if (sigma_sqrt_t > sigma_sqrt_t_max) {
        @branchHint(.unlikely);
        return asymptote(in);
    }

    // Main path. The assertions restate the guards in NaN-transparent form:
    // a NaN input must fall through and propagate, never trap.
    assert(!(in.forward <= 0.0));
    assert(!(in.strike <= 0.0));
    assert(!(in.ttm <= 0.0));
    assert(!(in.sigma <= 0.0));
    assert(!(sigma_sqrt_t < sigma_sqrt_t_min));
    assert(!(sigma_sqrt_t > sigma_sqrt_t_max));

    // r = 0, so the discount factor e^{-rT} is exactly 1 and is not written.
    //
    // Model v3 association. `logMoneyness` keeps |A| < 1455 for every finite
    // positive F and K, where v2's bare `log(F/K)` could inherit an infinity
    // from a ratio that had already over- or underflowed. `A/s + s/2` never
    // forms 0.5*sigma^2*T, which under v2 could overflow on its own and
    // collapse d1 and d2 onto the same +inf -- the negative-price defect.
    //
    // Bounded by the two guards above, every intermediate here is finite by
    // construction: |A/s| <= 1455e10, `0.5*s` cannot overflow because halving
    // cannot, and their sum and difference are bounded by the larger of them.
    // That is the whole reason guard 5 can be a bound on s and nothing else.
    const a = logMoneyness(in.forward, in.strike);
    const d1 = a / sigma_sqrt_t + 0.5 * sigma_sqrt_t;
    const d2 = d1 - sigma_sqrt_t;

    // Two exponentials per option, and that is all: N(d1), N(-d1) and n(d1)
    // come from the first, N(d2) and N(-d2) from the second.
    const p1 = phi(d1);
    const p2 = phi(d2);

    var out: Greeks = undefined;
    switch (in.kind) {
        .call => {
            out.price = in.forward * p1.pos - in.strike * p2.pos;
            out.delta = p1.pos;
        },
        .put => {
            out.price = in.strike * p2.neg - in.forward * p1.neg;
            out.delta = -p1.neg;
        },
    }
    out.gamma = p1.pdf / (in.forward * sigma_sqrt_t);
    out.theta = -(in.forward * in.sigma * p1.pdf) / (2.0 * sqrt_t);
    out.vega = in.forward * p1.pdf * sqrt_t;

    // Postconditions, NaN-transparent. Gamma and vega are densities and cannot
    // be negative; theta is minus a density; |delta| is a probability.
    assert(!(out.gamma < 0.0));
    assert(!(out.vega < 0.0));
    assert(!(out.theta > 0.0));
    assert(!(@abs(out.delta) > 1.0));
    assert(!(out.price < 0.0));
    return out;
}

/// ln(F/K), by whichever of the two forms is trustworthy for these arguments.
///
/// `log(F/K)` is the accurate one and is what runs for every option anyone has
/// ever quoted: near the money F and K agree to many digits, and `log(F) -
/// log(K)` is then a subtraction of two nearly equal numbers that throws away
/// most of them. Measured on the golden grid, the difference-of-logs form is
/// 8.8x worse in d1 on average and 8.6x worse at the money (`zig build
/// assoc-delta`, and the 50-digit cross-check behind it).
///
/// But `F/K` is itself a rounding, and for finite F and K hundreds of decades
/// apart it can overflow to +inf or underflow to 0 before `log` ever sees it --
/// and then d1 inherits an infinity, N(d1) saturates, and a deep-out-of-the-
/// money put reports delta = -1.0 when the truth is -0.0. So the ratio is used
/// where it survives and the difference of logs only where it does not, which
/// is exactly the regime where F and K are so far apart that the subtraction
/// has nothing left to cancel. Each form is used only where it is the good one.
///
/// The lower test is against the smallest NORMAL double, not against zero. A
/// ratio that lands in the subnormal range has not vanished, but it has already
/// thrown away most of its mantissa, and `log` of it is wrong in the digits
/// that matter -- measured: 15 inputs in an 11.8M sweep, all with F and K some
/// 300 decades apart. Written so that a NaN fails both tests and takes the
/// second branch, propagating as everything else here does.
inline fn logMoneyness(forward: f64, strike: f64) f64 {
    const ratio = forward / strike;
    if (ratio >= std.math.floatMin(f64) and ratio < std.math.inf(f64)) {
        return log(ratio);
    } else {
        @branchHint(.unlikely);
        return log(forward) - log(strike);
    }
}

const AtTheMoney = enum { half_delta_at_the_money, zero_delta_at_the_money };

/// Intrinsic value with zero gamma, theta and vega. Shared by three guards,
/// which differ only in what they say about delta exactly at the money.
inline fn intrinsic(in: Input, atm: AtTheMoney) Greeks {
    var out: Greeks = Greeks.zero;
    switch (in.kind) {
        .call => {
            out.price = @max(in.forward - in.strike, 0.0);
            out.delta = if (in.forward > in.strike) 1.0 else if (in.forward < in.strike) 0.0 else switch (atm) {
                .half_delta_at_the_money => 0.5,
                .zero_delta_at_the_money => 0.0,
            };
        },
        .put => {
            out.price = @max(in.strike - in.forward, 0.0);
            out.delta = if (in.forward < in.strike) -1.0 else if (in.forward > in.strike) 0.0 else switch (atm) {
                .half_delta_at_the_money => -0.5,
                .zero_delta_at_the_money => 0.0,
            };
        },
    }
    assert(!(out.price < 0.0));
    return out;
}

/// The large-variance asymptote, with zero gamma and vega. Used by guard 5.
///
/// d1 = log(F/K)/s + s/2 and d2 = d1 - s, so as s = sigma*sqrt(T) grows the two
/// run apart without limit: d1 -> +inf and d2 -> -inf, hence N(d1) -> 1 and
/// N(d2) -> 0. A call is then worth df*[F*1 - K*0] = df*F and a put
/// df*[K*1 - F*0] = df*K, and with r = 0 the discount factor is the literal 1.
/// Delta follows the same limit: N(d1) -> 1 for a call and -N(-d1) -> -0 for a
/// put. The densities go the other way -- n(d1) ~ exp(-s^2/8) beats every
/// polynomial in front of it -- so gamma and vega vanish, and theta, which is
/// minus a density, vanishes from below.
///
/// Every one of those values is what the main path ALREADY returns throughout
/// the plateau below the guard, down to the sign of each zero; see the note on
/// `sigma_sqrt_t_max`. This branch exists to carry them across the point where
/// the arithmetic can no longer produce them, not to introduce them.
inline fn asymptote(in: Input) Greeks {
    var out: Greeks = Greeks.zero;
    switch (in.kind) {
        .call => {
            out.price = in.forward;
            out.delta = 1.0;
        },
        .put => {
            out.price = in.strike;
            out.delta = negative_zero;
        },
    }
    // Minus a vanishing density, so negative zero -- as on the main path, where
    // the sign bit of a zero theta says which branch produced it. This is the
    // one degenerate branch that is a limit of the formula rather than a
    // replacement for it, so it keeps the formula's sign.
    out.theta = negative_zero;
    assert(!(out.price < 0.0));
    return out;
}

/// -0.0 as a value, not as a literal: `-0.0` written inline is a comptime float
/// and can be folded to +0.0 before it ever reaches an f64.
const negative_zero: f64 = @bitCast(@as(u64, 1) << 63);

/// Lanes in the SIMD batch path: the widest f64 vector the target does in one
/// register (8 on AVX-512, 4 on AVX2, 2 on SSE2/NEON), or 1 where there is no
/// SIMD at all. The choice affects speed only: every lane runs the scalar
/// path's operations in the scalar path's order, so the bits do not move with
/// the width, and the test suite checks batch against single at whatever width
/// the build picked.
pub const batch_lanes: comptime_int = @min(8, std.simd.suggestVectorLength(f64) orelse 1);

const V = @Vector(batch_lanes, f64);
const VB = @Vector(batch_lanes, bool);
const LN = libm.Lanes(batch_lanes);
const NN = normal.Lanes(batch_lanes);

inline fn vsplat(x: f64) V {
    return @splat(x);
}

/// Batch over caller-owned structure-of-arrays slices, `batch_lanes` options
/// at a time. Bit-identical to `greeks` on every element, by construction: the
/// main path is the scalar main path written over vectors (same operations,
/// same order, strict float mode, no contraction), and every lane that any of
/// the four guards would catch is handed back to the scalar kernel, whose
/// answer overwrites the lane. The golden test compares the two live paths
/// element by element, so a vectorisation that changed association order
/// would fail loudly.
pub fn greeksBatch(inputs: BatchInputs, outputs: BatchOutputs) void {
    const n = inputs.len();
    assert(outputs.len() == n);

    var i: usize = 0;
    if (batch_lanes > 1) {
        while (i + batch_lanes <= n) : (i += batch_lanes) {
            priceLanes(inputs, outputs, i);
        }
    }
    while (i < n) : (i += 1) {
        storeOne(outputs, i, priceOne(inputAt(inputs, i)));
    }
}

inline fn inputAt(inputs: BatchInputs, i: usize) Input {
    return .{
        .forward = inputs.forwards[i],
        .strike = inputs.strikes[i],
        .sigma = inputs.sigmas[i],
        .ttm = inputs.ttms[i],
        .kind = inputs.kinds[i],
    };
}

inline fn storeOne(outputs: BatchOutputs, i: usize, out: Greeks) void {
    outputs.deltas[i] = out.delta;
    outputs.gammas[i] = out.gamma;
    outputs.thetas[i] = out.theta;
    outputs.vegas[i] = out.vega;
    outputs.prices[i] = out.price;
}

/// One vector's worth of options, starting at `i`.
inline fn priceLanes(inputs: BatchInputs, outputs: BatchOutputs, i: usize) void {
    const forward: V = inputs.forwards[i..][0..batch_lanes].*;
    const strike: V = inputs.strikes[i..][0..batch_lanes].*;
    const sigma: V = inputs.sigmas[i..][0..batch_lanes].*;
    const ttm: V = inputs.ttms[i..][0..batch_lanes].*;
    const kind_bytes: @Vector(batch_lanes, u8) = @as([batch_lanes]u8, @bitCast(inputs.kinds[i..][0..batch_lanes].*));
    const is_call = kind_bytes == @as(@Vector(batch_lanes, u8), @splat(@intFromEnum(Kind.call)));

    // The five guards, as lane masks. Any lane that trips one is recomputed
    // below by the scalar kernel, which is the authority on what they return
    // and in which order they apply. The main path still runs on those lanes
    // (garbage in, garbage out, nothing traps); their results are discarded.
    const sqrt_t = @sqrt(ttm);
    const sigma_sqrt_t = sigma * sqrt_t;
    const invalid = @select(bool, forward <= vsplat(0.0), forward <= vsplat(0.0), strike <= vsplat(0.0));
    const expired = ttm <= vsplat(0.0);
    const zero_vol = sigma <= vsplat(0.0);
    const vanishing = sigma_sqrt_t < vsplat(sigma_sqrt_t_min);
    const unbounded = sigma_sqrt_t > vsplat(sigma_sqrt_t_max);
    // A sixth mask, and the reason it is a mask and not a `@select` over two
    // logarithms: `logMoneyness` falls back to log(F) - log(K) when the ratio
    // over- or underflows, and evaluating BOTH forms on every lane would cost a
    // second and third log per option in the hot path for a case that never
    // happens. Handing the lane to the scalar kernel costs nothing and reuses
    // the mechanism already here, which is also the one that keeps the scalar
    // kernel the single authority on what these branches return.
    const ratio = forward / strike;
    const ratio_blown = @select(bool, ratio >= vsplat(std.math.floatMin(f64)), ratio >= vsplat(std.math.inf(f64)), @as(VB, @splat(true)));
    const degenerate = @select(bool, invalid, invalid, @select(bool, expired, expired, @select(bool, zero_vol, zero_vol, @select(bool, vanishing, vanishing, @select(bool, unbounded, unbounded, ratio_blown)))));

    // Main path: the scalar formulas, verbatim, over lanes. One log, as before:
    // the lanes that would need the other form were masked out above.
    const a = LN.log(ratio);
    const d1 = a / sigma_sqrt_t + vsplat(0.5) * sigma_sqrt_t;
    const d2 = d1 - sigma_sqrt_t;
    const p1 = NN.phi(d1);
    const p2 = NN.phi(d2);

    const price_call = forward * p1.pos - strike * p2.pos;
    const price_put = strike * p2.neg - forward * p1.neg;
    const delta = @select(f64, is_call, p1.pos, -p1.neg);
    const price = @select(f64, is_call, price_call, price_put);
    const gamma = p1.pdf / (forward * sigma_sqrt_t);
    const theta = -(forward * sigma * p1.pdf) / (vsplat(2.0) * sqrt_t);
    const vega = forward * p1.pdf * sqrt_t;

    outputs.deltas[i..][0..batch_lanes].* = delta;
    outputs.gammas[i..][0..batch_lanes].* = gamma;
    outputs.thetas[i..][0..batch_lanes].* = theta;
    outputs.vegas[i..][0..batch_lanes].* = vega;
    outputs.prices[i..][0..batch_lanes].* = price;

    if (@reduce(.Or, degenerate)) {
        @branchHint(.unlikely);
        inline for (0..batch_lanes) |j| {
            if (degenerate[j]) storeOne(outputs, i + j, priceOne(inputAt(inputs, i + j)));
        }
    }
}

// -- C ABI --------------------------------------------------------------------

/// Single-position price and Greeks. C ABI, five out-pointers, r = 0.0.
pub export fn black76_greeks(
    forward: f64,
    strike: f64,
    sigma: f64,
    ttm: f64,
    is_call: bool,
    out_delta: *f64,
    out_gamma: *f64,
    out_theta: *f64,
    out_vega: *f64,
    out_price: *f64,
) void {
    const out = priceOne(.{
        .forward = forward,
        .strike = strike,
        .sigma = sigma,
        .ttm = ttm,
        .kind = Kind.fromIsCall(is_call),
    });
    out_delta.* = out.delta;
    out_gamma.* = out.gamma;
    out_theta.* = out.theta;
    out_vega.* = out.vega;
    out_price.* = out.price;
}

/// Batch computation over parallel arrays of `count` positions. Output arrays
/// must not overlap each other or the inputs (`noalias`).
pub export fn black76_greeks_batch(
    forwards: [*]const f64,
    strikes: [*]const f64,
    sigmas: [*]const f64,
    ttms: [*]const f64,
    is_calls: [*]const bool,
    count: usize,
    noalias out_deltas: [*]f64,
    noalias out_gammas: [*]f64,
    noalias out_thetas: [*]f64,
    noalias out_vegas: [*]f64,
    noalias out_prices: [*]f64,
) void {
    // `bool` and `Kind` share a byte layout (asserted at comptime above), so
    // the is_call array is viewed, not copied.
    const kinds: [*]const Kind = @ptrCast(is_calls);
    greeksBatch(.{
        .forwards = forwards[0..count],
        .strikes = strikes[0..count],
        .sigmas = sigmas[0..count],
        .ttms = ttms[0..count],
        .kinds = kinds[0..count],
    }, .{
        .deltas = out_deltas[0..count],
        .gammas = out_gammas[0..count],
        .thetas = out_thetas[0..count],
        .vegas = out_vegas[0..count],
        .prices = out_prices[0..count],
    });
}
