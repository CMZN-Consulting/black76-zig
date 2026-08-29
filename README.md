# black76-zig

[![ci](https://github.com/CMZN-Consulting/black76-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/CMZN-Consulting/black76-zig/actions/workflows/ci.yml)

A Black-76 option pricer in about 200 lines of Zig, and — the actual point — **3,516 golden
vectors that pin every bit of its output.**

---

## Why we bothered

Here is the bug we are afraid of.

Someone opens the pricer to make a small improvement. The normal distribution function in it is
an old approximation from a 1964 handbook, accurate to about seven decimal places. Their language
has a better one built in. They swap it. Every test passes, because the tests check that a call
option costs roughly what a call option should cost, and it does — to four decimals, to six
decimals, to any number of decimals a human wrote into an assertion.

Nothing looks wrong. Prices shift in the eighth decimal place, and everything downstream quietly
moves with them.

Nobody finds this by reading the diff. The diff looks like a cleanup.

That is the entire reason this repository exists. Not because the eighth decimal is important —
usually it isn't — but because **whether it moved should be a fact you can look up, not an
argument you have in a review.** So we captured the output of this pricer, every bit of it, across
3,516 inputs, and committed the file. Now any change to the pricer is either identical to what
came before, or it isn't, and you find out in under a second.

That is the whole idea. Everything below is detail.

---

## The guards, which are the good part

A pricer has to answer awkward questions. What is an option worth when it has already expired?
When volatility is zero? When volatility is so small the arithmetic starts dividing by nothing?

This one has **four early exits**, checked in a fixed order:

| Order | Guard                    | Meaning                                    |
| ----- | ------------------------ | ------------------------------------------ |
| 1     | `forward <= 0 or strike <= 0` | nonsense input                        |
| 2     | `ttm <= 0`               | already expired                            |
| 3     | `sigma <= 0`             | no volatility                              |
| 4     | `sigma * sqrt(ttm) < 1e-10` | volatility so small the maths breaks down |

Three of those return "the intrinsic value" — what the option is worth right now, ignoring any
future. And on the single most important input in options — **exactly at the money, where the
forward equals the strike** — those three branches *disagree with each other* about delta, which is
how much the option's price moves when the forward moves:

| Branch     | delta at `F == K`, call | put      |
| ---------- | ----------------------- | -------- |
| expired    | **+0.5**                | **−0.5** |
| zero vol   | **0.0**                 | **0.0**  |
| asymptotic | **0.0**                 | **0.0**  |

An expired at-the-money option splits the difference: half a delta, because it is a coin flip.
The other two say zero.

You can argue about which is right. That is not what this repo is for. What it is for is that
**the disagreement is now written down**. We built the tidied-up version to check: collapsing the
three branches into one breaks **48 of the 3,516 vectors** — the test names the first ten and counts
the rest.

And because the guards are ordered and can overlap, the order is observable too. These two calls
have the same volatility:

```
sigma = 0,  ttm = 0      ->  delta =  0.5     (expired wins)
sigma = 0,  ttm = 1e-30  ->  delta =  0.0     (zero-vol wins)
```

Nothing in a conventional test suite would catch a reordering, and almost nothing in this file would
either. We built that port too — moving the zero-vol check ahead of the expired check — and it breaks
**exactly 12 of 3,516 vectors, all 12 of them in the group that exists for this**. Without those
twelve, that reorder is invisible. Other permutations of the four guards break other counts; the
point is not the number, it is that a whole class of change is otherwise unobservable.

---

## Try it

Needs [Zig 0.16.0](https://ziglang.org/download/). Nothing else — no package registry, no network,
no C library.

```sh
zig build test        # replay all 3,516 vectors, bit-for-bit
zig build reproduce   # re-capture from scratch, diff against the file
zig build cdf-delta   # measure what a "better" normal CDF would cost
zig build generate    # rewrite the fixture (only if you meant to)
zig build             # build libblack76.so and libblack76.a into zig-out/lib
```

`zig build test` prints nothing when it passes. A green run that chatters teaches you to stop
reading it.

### Using it

Flat C ABI, five out-pointers, no structs and no allocator:

```c
void black76_greeks(double forward, double strike, double sigma, double ttm, bool is_call,
                    double *delta, double *gamma, double *theta, double *vega, double *price);

void black76_greeks_batch(const double *forwards, const double *strikes,
                          const double *sigmas,   const double *ttms,
                          const bool   *is_calls, size_t count,
                          double *deltas, double *gammas, double *thetas,
                          double *vegas,  double *prices);
```

Two things that are easy to get wrong, so they are stated rather than implied:

- **There is no interest rate.** `r = 0` is hardcoded and the discount factor is a literal `1.0`.
  This is a modelling choice for a zero-carry setting, not an omission. There is no rate argument
  and no rate axis in the vectors.
- **`ttm` is in years and `theta` comes back per year.** There is no division by 365 anywhere in
  the kernel. If you want theta per day, that is your caller's job, above this boundary.

`black76_greeks_batch` is a plain loop over the single-vector function and is required to stay one.
The test asserts batch output is bit-identical to per-vector output across the whole fixture, so
any future vectorisation that changes association order fails immediately.

---

## The rule: identical, or it's a finding

**There is no tolerance band. There will not be one.** Not out of machismo — because of what this
particular pricer is.

The normal CDF here is Abramowitz & Stegun 26.2.17: a rational polynomial with five hardcoded
constants and a maximum error of 7.5e-8. It is *an approximation, chosen deliberately.* Two things
follow.

A port that keeps the same approximation with the same constants in the same order **can** be
bit-identical, because IEEE-754 arithmetic is deterministic. Byte-identity is an achievable bar
here, not an aspiration.

A port that substitutes something better is **a different model**, and it deserves a decision by
someone who owns the P&L — not a silent side effect of a language change. A tolerance band wide
enough to admit that swap is a tolerance band wide enough to hide it.

So `zig build cdf-delta` exists to make that decision an informed one. It replays every input
through both the shipped CDF and Hart's high-precision one, and reports what actually moves:

```
  worst ABSOLUTE price gap  : 0.094049
      at F=500000 K=1000000 sigma=1.5 T=1y put
  worst RELATIVE gap        : 9633.8331 bps on a price of 0.000545
      at F=500000 K=500000 sigma=0.0000000001 T=1y call
      -- near-worthless option; the ratio is true and economically empty
  worst RELATIVE gap, priced: 0.1688 bps on a price of 0.004533
      at F=0.5 K=1 sigma=0.8 T=0.2465753424657534y call
      -- restricted to options worth >= 0.1% of forward
```

That is the honest shape of it: about a fifth of a basis point on anything you'd really hold, and
about nine cents per contract in absolute terms at a forward of 500,000. The relative figure is the
scale-free one and holds at every magnitude in the file; the absolute one grows with the forward.
Small, but not zero — and **whether that is acceptable is a judgement call somebody can now actually
make** instead of guess at.

Note the middle row. 9,634 bps is 96%, and it is arithmetically correct — but the option it is 96%
of is worth five ten-thousandths of a unit. That is why the tool prints the price beside every
ratio, and why the third row exists.

---

## What the fixture is actually pinned to

An honest golden-vector file has to say what it is a golden vector *of*. This one is captured by a
specific compiler, and the header line of the fixture records exactly which:

```json
{"header":1,"schema":"black76-golden/1","zig_version":"0.16.0",
 "target":"x86_64-linux-gnu","cpu":"x86_64","optimize":"ReleaseFast", ...}
```

We measured how much of that actually matters. Regenerating across **four optimisation modes ×
four CPU targets** — Debug, ReleaseSafe, ReleaseFast, ReleaseSmall, against `baseline`,
`x86_64_v2`, `x86_64_v3` and `native` — gives **sixteen for sixteen bit-identical** results. No
fused-multiply-add contraction, no fast-math reassociation, nothing. Optimisation level and CPU
feature set are not part of the contract on this platform, and that is now a measurement rather
than a hope.

The library also links **no libc at all**: `exp` and `log` resolve to Zig's own bundled
implementations, `ldd` reports it statically linked, and at `-Doptimize=ReleaseFast` the finished
`.so` has zero undefined symbols. (A `Debug` build leaves two — `getauxval` and `__tls_get_addr`,
from Zig's own runtime scaffolding — and weighs 10 MB against 859 KB, so build the library with an
optimisation mode.) The numbers depend on the compiler, not on which distribution you built on.

What we have **not** verified is a different CPU architecture, so we don't claim it. The mechanism is
in place — the fixture header records the target, and a mismatch prints captured-versus-replaying
before it prints a single hex string — but the claim itself is untested, and an untested claim
stated as a fact is the thing this whole repository is against.

CI runs the fixture on an aarch64 runner for exactly that reason, marked informational and
non-gating: if it ever goes red, that is a finding about the kernel rather than a broken build, and
it should be read as one.

---

## Why every number is stored in hexadecimal

The fixture holds each `f64` as its 64-bit pattern — `"0x3FE0000000000000"` — inputs included.
Decimal is where byte-identity quietly dies: `0.1` does not survive a print-and-parse round trip
identically across languages, and a fixture compared as decimal strings is a fixture testing its
own formatter.

Each line also carries a trailing `"_"` field with a decimal rendering, for human eyes. It is never
the compared value — but it *is* re-derived from the hex and required to agree, so it cannot drift
into saying something the numbers do not. (It could, once. That was a real gap, and closing it is
what the `"_"` test is for.)

There is a sharper reason for hex, and the data shows it. Look at the second line of the file:

```
gamma = 0x0000000000000000     (+0.0)
theta = 0x8000000000000000     (−0.0)
```

**Negative zero.** In the fixture, 252 deltas and 558 thetas are negative zero. Every zero gamma
and every zero vega is positive zero. Most decimal formatters will print several of those the
same way, and every one of them compares equal under `==`.

And it is not cosmetic. In this pricer the sign bit of a zero theta tells you *which branch
produced it*, with no exceptions across all 3,516 vectors:

- `theta = −0.0` — the full formula ran and the density underflowed. 558 vectors, all on the main
  path.
- `theta = +0.0` — an early exit fired and wrote a literal zero. 210 vectors, all in degenerate
  groups, zero of them from the grid.

A decimal fixture erases that distinction; a hex one turns a branch change into a one-character
diff.

For what it's worth, no vector in the file produces a NaN or an infinity. Invalid inputs return
five zeros, deliberately, and that is pinned too.

---

## Where the guards stop

The four early exits catch nonsense of one specific kind: values that are `<= 0`. **Negative**
infinity is caught by that test like any other negative number. NaN and **positive** infinity are
not, because `NaN <= 0.0` and `+inf <= 0.0` are both false and the check falls straight through.

Measured at the ABI, for calls and puts, and pinned by a test so it cannot rot:

| input | what comes back |
| --- | --- |
| `forward`, `strike` or `sigma` = −inf | five clean zeros — caught |
| `ttm` = −inf | the **expired** branch fires: delta ±0.5, everything else zero |
| any input NaN | NaN in all five outputs (theta comes back a *negative* NaN, from the minus sign in its formula) |
| `forward` = +inf, call | `delta = 1.0`, `gamma = +0.0`, `price = +inf`, `theta` and `vega` NaN |
| `strike` = +inf, put | `delta = −1.0`, `gamma = +0.0`, `theta = −0.0`, `vega = +0.0`, `price = +inf` |

That last row is the one to sit with. Every number in it is finite, ordinary, and exactly what a
deep in-the-money put should look like. Nothing about the output suggests the input was garbage, and
a caller that sanity-checks one field and trusts the rest has no way to tell.

The NaN cases are deliberately **not** in the fixture. NaN sign and payload propagation is not
guaranteed identical across processor architectures, so committing NaN vectors would make the file
fail on a different CPU for reasons that have nothing to do with the model — the fixture would
quietly become a hardware test. The test therefore asserts exact bit patterns for the finite and
infinite results, and only `isNan` for the rest.

Validate your inputs above this boundary. The kernel will not do it for you.

---

## What's in here

```
src/black76.zig                 the pricer
src/fixture.zig                 reference reader for the vector format
tools/generate_vectors.zig      the capture (owns the case list)
tools/diff_vectors.zig          vector-line diff, ignoring provenance headers
tools/cdf_delta.zig             the "what would a better CDF cost" measurement
tests/golden_test.zig           replays the fixture; 9 tests
vectors/black76-golden.ndjson   3,516 vectors, 1.5 MB
.github/workflows/ci.yml        the gate, run on itself
```

The fixture format is one JSON object per line and needs no JSON library to read: find the key,
take the next sixteen hex digits. `src/fixture.zig` is the reference implementation of that, and
it is shipped as part of the library rather than hidden in the test, because anyone porting this
has to read the file before they can port anything.

The generator owns the case list. The **test does not** — it replays the inputs stored in the
fixture itself. A test that regenerated its own inputs could drift alongside the generator and still
pass.

Coverage, if you want the shape of it. A 3,168-point grid over moneyness × volatility × maturity ×
call/put, at three forward magnitudes six decades apart — 0.5, 500 and 500,000, chosen synthetically
for spread and nothing else. Scale is a real axis rather than padding, because gamma divides by the
forward.

The other 348 exist to break a careless port: the three degenerate branches at the money, both sides
of every guard including exactly on it, guard precedence, invalid inputs, deep wings, and saturated
tails.

---

## What this is not

It prices one option from parameters you already have and returns five numbers. That is the whole
scope.

It is also not fast in an interesting way, and we make no claim that it is. It is *predictable*,
which was the requirement.

---

## Licence

MIT. See [LICENSE](LICENSE).

---

The interesting pieces stay closed. What we can strip of alpha, we publish.

*Receipts, not support.* This is published as evidence of how we work, not as a product. There is
no roadmap and no SLA, and issues may sit unanswered. Fork it freely — that is what the licence
is for.
