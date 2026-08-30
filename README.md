# black76-zig

[![ci](https://github.com/CMZN-Consulting/black76-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/CMZN-Consulting/black76-zig/actions/workflows/ci.yml)

A Black-76 option pricer in Zig, and — the actual point — **3,516 golden vectors that pin every
bit of its output.** Version 2: the normal distribution, `exp` and `log` now live in this
repository, the batch path prices eight options per instruction on AVX-512, and the numbers depend
on nothing outside the tree.

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

That is the whole idea. Everything below is detail — including the part where we did, on purpose,
exactly the swap described above, and the file said so.

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

In the source, the three intrinsic branches share one helper that takes the at-the-money convention
as an argument. The disagreement is not duplicated three times; it is a named parameter, and the
guard order is four `if`s in a row that nobody has to reconstruct.

---

## Try it

Needs [Zig 0.16.0](https://ziglang.org/download/). Nothing else — no package registry, no network,
no C library, and since v2 not even the compiler's own `exp` and `log`.

```sh
zig build test                            # replay all 3,516 vectors, bit-for-bit (19 tests)
zig build reproduce                       # re-capture from scratch, diff against the file
zig build cdf-delta                       # what the v1 -> v2 model change did to prices
zig build bench -Doptimize=ReleaseFast    # ns/option, batch and single
zig build libm-soak -Doptimize=ReleaseFast # in-repo exp/log vs compiler_rt, 1e9 samples, minutes
zig build generate                        # rewrite the fixture (only if you meant to)
zig build -Doptimize=ReleaseFast          # libblack76.so and libblack76.a into zig-out/lib
```

`zig build test` prints nothing when it passes. A green run that chatters teaches you to stop
reading it.

### Using it from Zig

```zig
const b76 = @import("black76");

const out = b76.greeks(.{ .forward = 500.0, .strike = 520.0, .sigma = 0.6, .ttm = 30.0 / 365.0, .kind = .put });
// out.delta, out.gamma, out.theta, out.vega, out.price

// Batch: caller-owned structure-of-arrays slices, all the same length.
b76.greeksBatch(
    .{ .forwards = fs, .strikes = ks, .sigmas = ss, .ttms = ts, .kinds = kinds },
    .{ .deltas = ds, .gammas = gs, .thetas = ths, .vegas = vs, .prices = ps },
);
```

The kernel never allocates. Not "rarely", not "only in the batch path": there is no allocator
parameter because there is nothing to allocate. `greeks` is a pure function of five values;
`greeksBatch` reads five slices and writes five slices you own, every element exactly once. The
tools and tests that do need memory take an explicit allocator, size their one allocation from the
fixture header, and free it; the test allocator fails the build on a leak.

### Using it from C, or anything with an FFI

Flat C ABI, five out-pointers, no structs and no allocator — unchanged from v1:

```c
void black76_greeks(double forward, double strike, double sigma, double ttm, bool is_call,
                    double *delta, double *gamma, double *theta, double *vega, double *price);

void black76_greeks_batch(const double *forwards, const double *strikes,
                          const double *sigmas,   const double *ttms,
                          const bool   *is_calls, size_t count,
                          double *deltas, double *gammas, double *thetas,
                          double *vegas,  double *prices);
```

The output arrays of the batch call must not overlap each other or the inputs. The `is_calls`
array is viewed as the Zig `Kind` enum without a copy (`put = 0`, `call = 1`, the same byte layout
as `bool`; a compile-time assertion guards that). A test pins the C ABI bit-identical to the Zig
API over the whole fixture.

Two things that are easy to get wrong, so they are stated rather than implied:

- **There is no interest rate.** `r = 0` is hardcoded and the discount factor is exactly 1.
  This is a modelling choice for a zero-carry setting, not an omission. There is no rate argument
  and no rate axis in the vectors.
- **`ttm` is in years and `theta` comes back per year.** There is no division by 365 anywhere in
  the kernel. If you want theta per day, that is your caller's job, above this boundary.

---

## The rule: identical, or it's a finding

**There is no tolerance band. There will not be one.** Not out of machismo — because of what this
particular pricer is.

The normal CDF is an approximation, chosen deliberately. Two things follow.

A port that keeps the same approximation with the same constants in the same order **can** be
bit-identical, because IEEE-754 arithmetic is deterministic — for `+ - * /` and `sqrt`. It says
nothing about `exp` and `log`, which are library code, and that turned out to matter enough to get
its own section below.

A port that substitutes something better is **a different model**, and it deserves a decision by
someone who owns the P&L — not a silent side effect of a language change. A tolerance band wide
enough to admit that swap is a tolerance band wide enough to hide it.

### v1 → v2: the swap, made on purpose

v1 used Abramowitz & Stegun 26.2.17: a rational polynomial with five hardcoded constants and a
maximum error of 7.5e-8, which computes the lower tail as `1 − N(|x|)` and therefore returns
exactly 0 for any option more than about 8.3 standard deviations out. v2 uses Hart's rational
approximation in the form given by West (Wilmott, 2005): accurate to about 1e-15, and it computes
the small tail directly — `N(−30)` is `4.9e-198`, not 0.

`zig build cdf-delta` is the tool that priced the decision. It replays every input in the fixture
through both CDFs and reports what actually moves:

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
Small, but not zero — and it was accepted, knowingly, by the person whose P&L it is.

Note the middle row. 9,634 bps is 96%, and it is arithmetically correct — but the option it is 96%
of is worth five ten-thousandths of a unit. That is why the tool prints the price beside every
ratio, and why the third row exists.

What the swap did to the file: **2,511 of 3,516 vectors changed**, every one of them in `delta`
and/or `price`. Gamma, theta and vega did not move by a bit, because the density is the same
function of the same exponential. 219 options that v1 priced at exactly zero now carry a small
positive price. The v1 numbers are kept in `vectors/black76-golden.v1.ndjson`, so the diff is a
file you can open, not a sentence in a commit message.

---

## What the numbers depend on

An honest golden-vector file has to say what it is a golden vector *of*. This one is captured by a
specific compiler, and the header line of the fixture records exactly which:

```json
{"header":1,"schema":"black76-golden/2","zig_version":"0.16.0",
 "target":"x86_64-linux-gnu","cpu":"x86_64","optimize":"ReleaseFast", ...}
```

We measured how much of that actually matters. Regenerating across **four optimisation modes ×
four CPU targets** — Debug, ReleaseSafe, ReleaseFast, ReleaseSmall, against `baseline`,
`x86_64_v2`, `x86_64_v3` and `native` — gives **sixteen for sixteen bit-identical** results, for v2
as it did for v1. No fused-multiply-add contraction, no fast-math reassociation, nothing. The kernel
states `@setFloatMode(.strict)` at module scope so that this stays true even if a parent scope
someday switches to `.optimized`.

### exp and log are in the tree

v1 said a faithful port "can be bit-identical, because IEEE-754 arithmetic is deterministic". That is
true of the arithmetic and false of the libraries. IEEE-754 does not require `exp` or `log` to be
correctly rounded, and two implementations that are both "accurate to 1 ulp" still disagree on the
last bit for some arguments. We measured it: on this kernel's own grid, Zig's bundled `exp` and
glibc 2.39's differ on **102 of 1,270** distinct arguments (`log` on 0 of 14), and that alone moved
**230 of the 3,516** v1 vectors in a line-for-line Python port. A fixture whose bits depend on the
toolchain's libm is a fixture on the toolchain.

So v2 carries its own. `src/libm.zig` is a port of the two algorithms Zig's compiler_rt uses —
musl's `exp` (FreeBSD `e_exp.c`) and musl's table-driven `log` (ARM optimized-routines), tables
copied verbatim — written once over `@Vector(n, f64)`, so the same source serves the scalar path
(`n = 1`) and the SIMD batch path. `zig build test` holds both functions to bit-identity with
compiler_rt over four million structured random samples per function at lane widths 1, 2, 4 and 8,
plus every special value and both sides of every internal threshold. `zig build libm-soak` does the
same with a billion samples; the result on x86-64 is **4,000,055,552 comparisons, 0 mismatched**,
for each of `exp` and `log`, NaN payloads included.

The upshot is a library that links **nothing**: no libc, and no compiler_rt math either. At
`-Doptimize=ReleaseFast` the finished `.so` is 65 KB with zero undefined symbols and `ldd` reports
it statically linked. (A `Debug` build leaves two symbols — `getauxval` and `__tls_get_addr`, from
Zig's own runtime scaffolding — and weighs 10 MB, so build the library with an optimisation mode.)

What we have **not** verified is a different CPU architecture, so we don't claim it. The mechanism is
in place — the fixture header records the target, and a mismatch prints captured-versus-replaying
before it prints a single hex string — and with `exp` and `log` in the tree the remaining
architecture-dependent inputs are `sqrt`, the four arithmetic operations, and the sign of a default
NaN, which is why NaN bit patterns are never in the fixture. But the claim itself is untested, and an
untested claim stated as a fact is the thing this whole repository is against.

CI runs the fixture on an aarch64 runner for exactly that reason, marked informational and
non-gating: if it ever goes red, that is a finding about the kernel rather than a broken build, and
it should be read as one.

---

## Speed, since it is now a number

`zig build bench -Doptimize=ReleaseFast` prices 2^20 synthetic options drawn from the fixture's
own ranges and reports the best of seven runs. On a Cascade Lake Xeon:

| build           | lanes | batch, ns/option | single, ns/option |
| --------------- | ----- | ---------------- | ----------------- |
| v1 kernel       | —     | 90               | 90                |
| v2, `baseline`  | 2     | 75               | ~98               |
| v2, `x86_64_v3` | 4     | 49               | ~98               |
| v2, `native`    | 8     | 34               | ~98               |

The batch path runs `batch_lanes` options through the scalar formulas written over vectors — same
operations, same order — and hands any lane that trips a guard back to the scalar kernel, which
stays the only authority on what the guards return and in which order. The test compares batch
against single element by element, over the fixture and over random inputs with NaN, infinities and
degenerate values mixed in. At every lane width the compiler can pick, it agrees to the bit.

The scalar path is about 10% slower than v1, which is the price of seven more decimal digits in
the CDF: Hart's form is twelve multiply-adds and a division more than the 1964 one. Two measured
lessons from getting here are written into the source rather than left in a benchmark log. The
kernel body is an explicit `inline fn`, because the moment it gained a second call site LLVM stopped
inlining it into the batch loop and the 40-byte result went through memory: +30%. And the normal
distribution returns `N(x)`, `N(−x)` and `n(x)` together from one exponential, because once `exp`
was inlined the optimiser no longer noticed the three separate calls were the same number: +30%
again, for the same reason.

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

**Negative zero.** In the v2 fixture, 141 deltas and 558 thetas are negative zero. Every zero gamma
and every zero vega is positive zero. Most decimal formatters will print several of those the same
way, and every one of them compares equal under `==`.

And it is not cosmetic. In this pricer the sign bit of a zero theta tells you *which branch
produced it*, with no exceptions across all 3,516 vectors:

- `theta = −0.0` — the full formula ran and the density underflowed. 558 vectors, all on the main
  path.
- `theta = +0.0` — an early exit fired and wrote a literal zero. 210 vectors, all in degenerate
  groups, zero of them from the grid.

A decimal fixture erases that distinction; a hex one turns a branch change into a one-character
diff. (The delta count fell from 252 in v1 to 141 because v2 computes the lower tail directly, so
fewer deep-wing put deltas underflow to zero.)

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
| any input NaN | NaN in all five outputs |
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

The kernel's own assertions — preconditions after the guards, postconditions on every output — are
written in the NaN-transparent form (`assert(!(gamma < 0))`, never `assert(gamma >= 0)`), so a
Debug build cannot trap on an input that a release build would let through. Assertions here
document invariants; they are not allowed to change behaviour between modes.

Validate your inputs above this boundary. The kernel will not do it for you.

---

## What's in here

```
src/black76.zig                   the pricer: Zig API, C ABI, scalar and SIMD paths
src/normal.zig                    N(x), N(-x), n(x) from one exp; lane-generic (model v2)
src/libm.zig                      exp and log, lane-generic, bit-identical to compiler_rt
src/fixture.zig                   reference reader for the vector format; never allocates
tools/generate_vectors.zig        the capture (owns the case list; case count is comptime)
tools/diff_vectors.zig            vector-line diff, ignoring provenance headers
tools/cdf_delta.zig               the v1 -> v2 price-impact measurement
tools/bench.zig                   ns/option
tests/golden_test.zig             replays the fixture; 12 tests
tests/libm_test.zig               exp/log vs compiler_rt; 4M samples under test, 1e9 under soak
vectors/black76-golden.ndjson     3,516 vectors, schema 2, 1.5 MB
vectors/black76-golden.v1.ndjson  the v1 numbers, on record
.github/workflows/ci.yml          the gate, run on itself
```

The fixture format is one JSON object per line and needs no JSON library to read: find the key,
take the next sixteen hex digits. `src/fixture.zig` is the reference implementation of that, and
it is shipped as part of the library rather than hidden in the test, because anyone porting this
has to read the file before they can port anything. It fills a buffer you own, or allocates exactly
the header's `vector_count` with an allocator you pass; there is no third way.

The generator owns the case list. The **test does not** — it replays the inputs stored in the
fixture itself. A test that regenerated its own inputs could drift alongside the generator and still
pass. The number of cases is a compile-time constant derived from the axes, and a compile-time
assertion holds it at 3,516, so this README and the generator cannot disagree without a build error.

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

It is *predictable*, which was the requirement. It is also now reasonably fast, which was not, and
the number is in the table above rather than in this sentence.

---

## Licence

MIT. See [LICENSE](LICENSE).

---

The interesting pieces stay closed. What we can strip of alpha, we publish.

*Receipts, not support.* This is published as evidence of how we work, not as a product. There is
no roadmap and no SLA, and issues may sit unanswered. Fork it freely — that is what the licence
is for.
