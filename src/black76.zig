//! Black-76 option pricing and Greeks.
//!
//! One option in, five numbers out. The kernel is a pure function of its
//! arguments: no allocator, no global state, no I/O, and every floating-point
//! operation is evaluated in strict IEEE-754 mode so that the same source
//! produces the same bits on every optimisation level (see `vectors/`).
//!
//! Model, with the discount factor written out:
//!
//!   d1    = [ln(F/K) + 0.5*sigma^2*T] / (sigma*sqrt(T))
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
//! Degenerate inputs (T<=0, sigma<=0, F<=0, K<=0, and sigma*sqrt(T) underflow)
//! are handled by four separate early-return branches, checked in a fixed
//! order. They do NOT all agree with each other at F == K -- see the README.
//! That disagreement is observable, pinned by the golden vectors, and must be
//! preserved by any reimplementation.
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

/// Scalar exp/log from src/libm.zig, so the kernel's bits depend on this
/// repository and not on whichever compiler_rt or libc happens to be linked.
const L1 = libm.Lanes(1);

inline fn exp(x: f64) f64 {
    return L1.exp(L1.splat(x))[0];
}

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

// -- Standard normal distribution ---------------------------------------------

/// N(x), N(-x) and n(x) from ONE exponential. The kernel needs all three for
/// d1 (both tails for the put, the density for the Greeks), and asking for them
/// together states the sharing in the source instead of hoping the optimiser
/// notices that exp(-x^2/2) is the same number every time. It is: measured, a
/// kernel that calls the three functions separately runs ~30% slower once the
/// exp is inlined, because common-subexpression elimination stops seeing
/// through the branches.
pub const Phi = struct {
    /// N(x)
    pos: f64,
    /// N(-x)
    neg: f64,
    /// n(x)
    pdf: f64,
};

/// Abramowitz & Stegun 26.2.17 -- rational polynomial approximation.
/// Maximum absolute error < 7.5e-8.
///
/// This is an APPROXIMATION, chosen on purpose. Swapping it for an erf-based or
/// correctly-rounded CDF changes prices in the 8th decimal and is a different
/// model, not a cleanup. The golden vectors exist to make that swap loud.
///
/// N(-x) is computed literally as `1 - N(|x|)`, so the reflection identity is
/// exact by construction and not merely approximate. (At x == +/-0 both
/// branches see `x >= 0` and return the positive form.)
pub fn phi(x: f64) Phi {
    const b1: f64 = 0.319381530;
    const b2: f64 = -0.356563782;
    const b3: f64 = 1.781477937;
    const b4: f64 = -1.821255978;
    const b5: f64 = 1.330274429;
    const p: f64 = 0.2316419;
    const ax = @abs(x);
    const k = 1.0 / (1.0 + p * ax);
    const pdf = normalPDF(ax);
    const n_pos = 1.0 - pdf * (((((b5 * k + b4) * k + b3) * k + b2) * k + b1) * k);
    return .{
        .pos = if (x >= 0.0) n_pos else 1.0 - n_pos,
        .neg = if (-x >= 0.0) n_pos else 1.0 - n_pos,
        .pdf = pdf,
    };
}

/// Standard normal CDF, N(x). See `phi`.
pub fn normalCDF(x: f64) f64 {
    return phi(x).pos;
}

/// Standard normal PDF: n(x) = (1/sqrt(2*pi)) * exp(-x^2/2). Sign-symmetric in
/// x to the bit, since x*x is.
pub fn normalPDF(x: f64) f64 {
    const inv_sqrt_2pi: f64 = 0.3989422804014327; // 1 / sqrt(2*pi)
    return inv_sqrt_2pi * exp(-0.5 * x * x);
}

// -- Black-76 core ------------------------------------------------------------

/// Price and Greeks for one option. Pure; never allocates; never traps.
///
/// Guard order is part of the contract: invalid -> expired -> zero vol ->
/// asymptotic. NaN and +inf are NOT caught by the `<= 0` tests and propagate;
/// validate inputs above this boundary.
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

    // Main path. The assertions restate the guards in NaN-transparent form:
    // a NaN input must fall through and propagate, never trap.
    assert(!(in.forward <= 0.0));
    assert(!(in.strike <= 0.0));
    assert(!(in.ttm <= 0.0));
    assert(!(in.sigma <= 0.0));
    assert(!(sigma_sqrt_t < sigma_sqrt_t_min));

    // r = 0, so the discount factor e^{-rT} is exactly 1 and is not written.
    const d1 = (log(in.forward / in.strike) + 0.5 * in.sigma * in.sigma * in.ttm) / sigma_sqrt_t;
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

/// Batch over caller-owned structure-of-arrays slices.
///
/// This is a plain loop over `greeks` and is REQUIRED to stay bit-identical to
/// it: the golden test compares the two live paths element by element, so any
/// future vectorisation that changes association order fails loudly.
pub fn greeksBatch(inputs: BatchInputs, outputs: BatchOutputs) void {
    const n = inputs.len();
    assert(outputs.len() == n);

    for (0..n) |i| {
        const out = priceOne(.{
            .forward = inputs.forwards[i],
            .strike = inputs.strikes[i],
            .sigma = inputs.sigmas[i],
            .ttm = inputs.ttms[i],
            .kind = inputs.kinds[i],
        });
        outputs.deltas[i] = out.delta;
        outputs.gammas[i] = out.gamma;
        outputs.thetas[i] = out.theta;
        outputs.vegas[i] = out.vega;
        outputs.prices[i] = out.price;
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
