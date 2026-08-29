// black76.zig
//
// Black-76 option pricing and Greeks, exposed over a flat C ABI so it can be
// loaded from any FFI-capable host (dlopen + five out-pointers, no structs, no
// allocator, no global state).
//
// Model, with the discount factor written out:
//   d1    = [ln(F/K) + 0.5*sigma^2*T] / (sigma*sqrt(T))
//   d2    = d1 - sigma*sqrt(T)
//   Call  = e^{-rT} * [F*N(d1) - K*N(d2)]
//   Put   = e^{-rT} * [K*N(-d2) - F*N(-d1)]
//   Gamma = e^{-rT} * n(d1) / (F * sigma * sqrt(T))
//   Theta = -[F * sigma * e^{-rT} * n(d1)] / (2*sqrt(T))
//   Vega  = F * e^{-rT} * n(d1) * sqrt(T)
//
// TWO ABI FACTS THAT ARE EASY TO GET WRONG, SO THEY ARE STATED HERE:
//
//   1. r = 0 is hardcoded, so e^{-rT} is the literal 1.0. There is no rate
//      parameter and there is no rate axis. This is a deliberate modelling
//      choice for a zero-carry setting, not an omission.
//   2. `ttm` is a fraction of a YEAR, and `theta` comes back PER YEAR. There
//      is no /365 anywhere below. Any per-day convention belongs above this
//      boundary, in the caller.
//
// Degenerate inputs (T<=0, sigma<=0, F<=0, K<=0, and sigma*sqrt(T) underflow)
// are handled by four separate early-return branches. They do NOT all agree
// with each other -- see the README. That disagreement is observable, pinned by
// the golden vectors, and must be preserved by any reimplementation.

const std = @import("std");

// -- Standard normal distribution --------------------------------

/// Abramowitz & Stegun 26.2.17 -- rational polynomial approximation.
/// Maximum absolute error < 7.5e-8.
///
/// This is an APPROXIMATION, chosen on purpose. Swapping it for an erf-based or
/// correctly-rounded CDF changes prices in the 8th decimal and is a different
/// model, not a cleanup. The golden vectors exist to make that swap loud.
pub fn normalCDF(x: f64) f64 {
    // Abramowitz & Stegun 26.2.17 -- normal CDF, |err| < 7.5e-8.
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

/// Standard normal PDF: n(x) = (1/sqrt(2*pi)) * exp(-x^2/2)
pub fn normalPDF(x: f64) f64 {
    const inv_sqrt_2pi: f64 = 0.3989422804014327; // 1 / sqrt(2*pi)
    return inv_sqrt_2pi * @exp(-0.5 * x * x);
}

// -- Black-76 core -----------------------------------------------

/// Single-position price and Greeks. C ABI, five out-pointers.
/// r = 0.0 (hardcoded).
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
    // Edge: invalid inputs
    if (forward <= 0.0 or strike <= 0.0) {
        out_delta.* = 0.0;
        out_gamma.* = 0.0;
        out_theta.* = 0.0;
        out_vega.* = 0.0;
        out_price.* = 0.0;
        return;
    }

    // Edge: expired option — return intrinsic value
    if (ttm <= 0.0) {
        if (is_call) {
            const intrinsic = @max(forward - strike, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward > strike) 1.0 else if (forward < strike) 0.0 else 0.5;
        } else {
            const intrinsic = @max(strike - forward, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward < strike) -1.0 else if (forward > strike) 0.0 else -0.5;
        }
        out_gamma.* = 0.0;
        out_theta.* = 0.0;
        out_vega.* = 0.0;
        return;
    }

    // Edge: zero or negative vol — return intrinsic
    if (sigma <= 0.0) {
        if (is_call) {
            const intrinsic = @max(forward - strike, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward > strike) 1.0 else 0.0;
        } else {
            const intrinsic = @max(strike - forward, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward < strike) -1.0 else 0.0;
        }
        out_gamma.* = 0.0;
        out_theta.* = 0.0;
        out_vega.* = 0.0;
        return;
    }

    const sqrt_t = @sqrt(ttm);
    const sigma_sqrt_t = sigma * sqrt_t;

    // Asymptotic guard: if sigma*sqrt(T) is extremely small, d1 approaches ±inf
    if (sigma_sqrt_t < 1e-10) {
        if (is_call) {
            const intrinsic = @max(forward - strike, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward > strike) 1.0 else 0.0;
        } else {
            const intrinsic = @max(strike - forward, 0.0);
            out_price.* = intrinsic;
            out_delta.* = if (forward < strike) -1.0 else 0.0;
        }
        out_gamma.* = 0.0;
        out_theta.* = 0.0;
        out_vega.* = 0.0;
        return;
    }

    // r = 0, so e^{-rT} = 1.0
    const disc: f64 = 1.0;

    const d1 = (@log(forward / strike) + 0.5 * sigma * sigma * ttm) / sigma_sqrt_t;
    const d2 = d1 - sigma_sqrt_t;

    const nd1 = normalCDF(d1);
    const nd2 = normalCDF(d2);
    const pdf_d1 = normalPDF(d1);

    // Price
    if (is_call) {
        out_price.* = disc * (forward * nd1 - strike * nd2);
    } else {
        out_price.* = disc * (strike * normalCDF(-d2) - forward * normalCDF(-d1));
    }

    // Delta
    if (is_call) {
        out_delta.* = disc * nd1;
    } else {
        out_delta.* = -disc * normalCDF(-d1);
    }

    // Gamma (same for call and put)
    out_gamma.* = disc * pdf_d1 / (forward * sigma_sqrt_t);

    // Theta (simplified with r=0)
    // Theta = -[F * sigma * disc * n(d1)] / (2*sqrt(T))
    out_theta.* = -(forward * sigma * disc * pdf_d1) / (2.0 * sqrt_t);

    // Vega
    // Vega = F * disc * n(d1) * sqrt(T)
    out_vega.* = forward * disc * pdf_d1 * sqrt_t;
}

/// Batch computation for arrays of positions.
///
/// This is a plain loop over `black76_greeks` and is REQUIRED to stay one: the
/// golden test asserts batch output is bit-identical to per-vector output, so
/// any future vectorisation that changes association order fails loudly.
pub export fn black76_greeks_batch(
    forwards: [*]const f64,
    strikes: [*]const f64,
    sigmas: [*]const f64,
    ttms: [*]const f64,
    is_calls: [*]const bool,
    count: usize,
    out_deltas: [*]f64,
    out_gammas: [*]f64,
    out_thetas: [*]f64,
    out_vegas: [*]f64,
    out_prices: [*]f64,
) void {
    for (0..count) |i| {
        black76_greeks(
            forwards[i],
            strikes[i],
            sigmas[i],
            ttms[i],
            is_calls[i],
            &out_deltas[i],
            &out_gammas[i],
            &out_thetas[i],
            &out_vegas[i],
            &out_prices[i],
        );
    }
}
