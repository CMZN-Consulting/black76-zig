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

This one has **five early exits**, checked in a fixed order:

| Order | Guard                    | Meaning                                    |
| ----- | ------------------------ | ------------------------------------------ |
| 1     | `forward <= 0 or strike <= 0` | nonsense input                        |
| 2     | `ttm <= 0`               | already expired                            |
| 3     | `sigma <= 0`             | no volatility                              |
| 4     | `sigma * sqrt(ttm) < 1e-10` | volatility so small the maths breaks down |
| 5     | `sigma * sqrt(ttm) > 1e10`  | volatility so large the arithmetic leaves the representable range |

Guard 5 is the newer one and it is the reason the band is two-sided; the section on the large end
below says what it returns and why the threshold is where it is.

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
twelve, that reorder is invisible. Other permutations of the guards break other counts; the
point is not the number, it is that a whole class of change is otherwise unobservable.

In the source, the three intrinsic branches share one helper that takes the at-the-money convention
as an argument. The disagreement is not duplicated three times; it is a named parameter, and the
guard order is five `if`s in a row that nobody has to reconstruct.

---

## Try it

Needs [Zig 0.16.0](https://ziglang.org/download/). Nothing else — no package registry, no network,
no C library, and since v2 not even the compiler's own `exp` and `log`.

```sh
zig build test                            # replay all 3,516 vectors, bit-for-bit (24 tests)
zig build reproduce                       # re-capture from scratch, diff against the file
zig build cdf-delta                       # what the v1 -> v2 model change did to prices
zig build assoc-delta                     # what the v2 -> v3' re-association moved
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

### v2 → v3′: the same discipline, applied to arithmetic instead of a model

The second deliberate move, and a smaller one. Nothing about the *model* changed — same CDF, same
`exp`, same `log`, same formulas. What changed is the **order the arithmetic is assembled in**, to
take three overflow channels out of `d1`:

```
v2   d1 = [ln(F/K) + 0.5*sigma^2*T] / s
v3′  d1 = A/s + s/2,   A = ln(F/K), falling back to ln(F) − ln(K) only where
                           the ratio is not a normal double
```

v2 **squared** a quantity before halving it, so `0.5*sigma*sigma*T` overflowed on its own for
`sigma > 1.9e154` *whatever T was*. v3′ halves one that is already computed, and halving cannot
overflow. `zig build assoc-delta` is the tool that priced it, on the same template as `cdf-delta`:
**747 of 3,516 vectors move**, zero of them changing which branch produced them, worst price move
**3.5e-10 bps** on an economically real option and **1.6e-5 bps** unrestricted. `delta`'s largest
move is `2.22e-16` — one ulp of 1.0.

**The conditional logarithm is the part worth reading**, because the obvious "more precise" form is
measurably worse. Splitting `ln(F/K)` into `ln(F) − ln(K)` unconditionally subtracts two nearly
equal numbers whenever `F ≈ K`, which is a catastrophic cancellation exactly where the book is:
against a 60-digit reference it is **8.8× less accurate in `d1` overall and 8.6× at the money**.
`ln(F/K)` forms the ratio in one rounding and takes a logarithm near 1, where a logarithm is most
accurate. So each form is used only in the regime where it is the accurate one, and the fallback
predicate tests `>= floatMin` rather than `> 0` — a **subnormal** ratio passes a nonzero test having
already thrown away most of its mantissa.

What it bought, over 11,829,248 adversarial inputs: **negative prices 596,275 → 0, NaN prices
852,730 → 0, materially wrong outputs 3,298,778 → 0**, no regressions, and put-call parity holding
to 1.77e-16 over 5.9 million checks. The v2 numbers are kept in
`vectors/black76-golden.v2.ndjson`, so this diff is a file you can open too.

---

## What the numbers depend on

An honest golden-vector file has to say what it is a golden vector *of*. This one is captured by a
specific compiler, and the header line of the fixture records exactly which:

```json
{"header":1,"schema":"black76-golden/3","zig_version":"0.16.0",
 "target":"x86_64-linux-gnu","cpu":"raptorlake","optimize":"ReleaseFast", ...}
```

We measured how much of that actually matters. Regenerating across **four optimisation modes ×
four CPU targets** — Debug, ReleaseSafe, ReleaseFast, ReleaseSmall, against `baseline`,
`x86_64_v2`, `x86_64_v3` and `native` — gives **sixteen for sixteen bit-identical** results, as it
did for v1 and v2. No fused-multiply-add contraction, no fast-math reassociation, nothing. The
kernel states `@setFloatMode(.strict)` at module scope so that this stays true even if a parent
scope someday switches to `.optimized`.

**One narrowing, measured rather than assumed: that claim is about non-NaN results.** The *sign* of
a NaN output is not stable across optimisation level or vector width, and we can show it — the
scalar path returns `0xFFF8…` for a NaN forward's delta in Debug and `0x7FF8…` in ReleaseFast, and
the SIMD batch path disagrees with the scalar path's NaN sign on 31 of 477 NaN outputs in one
configuration and none in another. **The payload never moves**, in any configuration we can build.
IEEE-754 does not fix the sign of a NaN result and neither LLVM nor the hardware is obliged to be
consistent about it, so the fixture carries **no NaN vectors at all** — deliberately, since
committing one would make the file a hardware test — and the batch-versus-scalar test compares NaN
payloads while excluding the sign bit, with a second test pinning that any divergence really is
sign-only.

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
for each of `exp` and `log`, NaN payloads included — **501,252,140 NaN results, every one of them
bit-identical**.

"NaN payloads included" used to be a sentence in this file computed by a counter nobody asserted.
It is a test now: a NaN result whose bits differ from compiler_rt's fails its own named expectation,
separately from a numeric mismatch, so a divergence on some future target arrives as *the NaN
handling* rather than as *the polynomial*.

The upshot is a library that links **nothing**: no libc, and no compiler_rt math either. At
`-Doptimize=ReleaseFast` the finished `.so` is **76 KB** with zero undefined symbols and `ldd`
reports it statically linked. (A `Debug` build leaves two symbols — `getauxval` and
`__tls_get_addr`, from Zig's own runtime scaffolding — and weighs 10 MB, so build the library with
an optimisation mode.)

**That file got 11× smaller than v1's and the code in it got 5× bigger, and both are true.** It is
worth stating both ways, because the file-size number on its own is the flattering one and it is
mostly not about code:

| `-Doptimize=ReleaseFast` | v1 (`6b8b450`) | now | |
| --- | ---: | ---: | --- |
| `.so` on disk | 858,432 B | 76,296 B | 11.25× **smaller** |
| stripped | 9,512 B | 21,528 B | 2.26× **bigger** |
| `.text` | 2,665 B | 14,414 B | 5.41× **bigger** |

98.9 % of v1's file was debug information. The shrink is real but it is a *packaging* fact; the
kernel itself grew, which is what you would expect from putting `exp`, `log` and a 1e-15 CDF in the
tree. Quoting the 11× without the 5× would be quoting a ratio without asking what was in the file.

**And ReleaseSafe goes the other way, which is worth explaining rather than hiding.** The checked
build is about **3.3 MB**, roughly **3.9×** v1's. Almost none of that is the pricer: **86 % is
DWARF** — stripping leaves 467 KB with every safety check still live — and most of what remains is
Zig's default panic handler, which symbolises its own stack traces and therefore links an ELF
reader, a DWARF parser and a flate decompressor. The kernel's own contribution is measurable
separately, on stripped ReleaseFast artifacts where none of that machinery is linked: **9,512 B →
21,528 B, about +12 KB**. So the mode that grew 3.9× is the one whose entire job is to tell you what
went wrong, and the mode you deploy is the one that got 11× smaller.

No build knob ships for this, and the two obvious candidates are why. Turning off unwind tables
makes the artifact **21,392 bytes LARGER**, not smaller. Turning off stack-check saves **960 bytes**,
0.03 %. Everything that does move the number meaningfully — stripping, or disabling the panic
handler — buys bytes by removing diagnostics from the diagnostic build, which is backwards. If a
host genuinely needs a small checked artifact, `strip` the ReleaseSafe library yourself: the checks
survive it intact and only the symbolised backtrace is lost. That is a decision for the host to make
explicitly, not a default for this repository to make quietly.

A different CPU architecture used to be the thing this file would not claim, because nothing had
checked it. It has been checked: **aarch64 replays the fixture bit-for-bit**, so CI's ARM job is
**gating** rather than informational, and cross-architecture bit-identity is now a promise this
repository makes rather than a note in it. A promise that does not gate is a note.

With `exp` and `log` in the tree the remaining architecture-dependent inputs are `sqrt`, the four
arithmetic operations, and the sign of a default NaN — which is why NaN bit patterns are never in
the fixture, and why the claim above is about the fixture's contents rather than about every
conceivable output. See "Where the guards stop" for what is measured about NaN and what is not.

---

## Speed, since it is now a number

`zig build bench -Doptimize=ReleaseFast` prices 2^20 synthetic options drawn from the fixture's
own ranges and reports the best of seven runs.

The table below is measured differently, and on purpose: both libraries are loaded with `dlopen`
into one process and timed **interleaved**, on the same input population, pinned to one core. That
is the surface an FFI host actually loads, and it is the only way to put v1 and the current kernel
on one axis — v1 has no bench step to run. It also costs a fixed per-call overhead that both arms
pay, so the *ratios* here are compressed relative to what `zig build bench` reports in-tree; use
this table for v1-versus-now and the in-tree bench for tracking the kernel against itself.

Intel i7-1355U, six interleaved rounds of best-of-five, ns/option:

| build                 | lanes | batch | vs v1 | single | vs v1 |
| --------------------- | ----- | ----: | ----: | -----: | ----: |
| v1 kernel (`6b8b450`) | —     | 57.29 | —     | 56.59  | —     |
| now, `baseline`       | 2     | 32.73 | 1.75× | 58.91  | +4.1% |
| now, `x86_64_v3`      | 4     | 19.40 | 2.95× | 57.81  | +2.2% |
| now, `native`         | 4     | 19.31 | 2.97× | 57.82  | +2.2% |

This machine has no AVX-512, so the 8-lane row cannot be measured here; the earlier Cascade Lake
figures for it are in this file's git history rather than reproduced as if they were current.

The batch path runs `batch_lanes` options through the scalar formulas written over vectors — same
operations, same order — and hands any lane that trips a guard back to the scalar kernel, which
stays the only authority on what the guards return and in which order. The test compares batch
against single element by element, over the fixture and over random inputs with NaN, infinities and
degenerate values mixed in. At every lane width the compiler can pick, it agrees to the bit.

**The scalar path is still slower than v1, and that is a trade rather than a regression.** Hart's
form is twelve multiply-adds and a division more than the 1964 one, bought for seven more decimal
digits and a lower tail that does not collapse to zero. On the surface above the remaining penalty
is 2.2%; in-tree, where the per-call overhead is not diluting it, it is larger. It is not zero and
this file will not pretend it is.

Some of it *was* recovered. The lane-generic rewrite made `exp`'s internals branchless, which is
right for a vector and wrong for the scalar path — it turned free, well-predicted branches into
serial `@select` dependency chains: 30 fewer instructions than v1 at an IPC of 1.89 against 2.13,
with the branch-miss rate flat. Wrapping those chains in a uniform `if (@reduce(.Or, mask))`, the
idiom already used in the CDF's tail, gets it back without moving a bit. Note the shape of that
gain: it is **distribution-dependent**, because the skip only fires when no lane needs argument
reduction, and `exp` is called here with `−0.5·d²`, so a deep-out-of-the-money book takes the slow
path more often. The bit-identity is not distribution-dependent.

Two other measured lessons are written into the source rather than left in a benchmark log. The
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

Four of the five early exits catch nonsense of one specific kind: values that are `<= 0`.
**Negative** infinity is caught by that test like any other negative number. NaN and **positive**
infinity are not, because `NaN <= 0.0` and `+inf <= 0.0` are both false and the check falls straight
through.

### The large end, which is guard 5

`sigma * sqrt(ttm)` is the one intermediate that can still leave the representable range: at
σ=1e300 and T=1e100 it overflows to `+inf`, and then `d2 = inf − inf` is NaN. Guard 5 catches it and
returns the exact `s → ∞` limit — call `→ df·F`, put `→ df·K`, delta `1.0` / `−0.0`, gamma and vega
`+0.0`, theta `−0.0`.

**It is a continuation of the main path, not a cliff.** `N(d2)` is exactly 0 once `d2 < −37` and
`N(d1)` exactly 1 once `d1 > ~8.3`, so the worst case over all F and K puts the main path on that
plateau from about `s = 110` upward. The threshold sits at `1e10`, eight decades inside a plateau
306 decades wide, and the values it returns were checked against what the main path itself produces
at the worst possible moneyness (`F = floatMax`, `K = floatTrueMin`) rather than assumed. Nothing
real reaches it: it needs a volatility of 1e11 percent at a hundred years.

### One thing it does not fix, named rather than hidden

`theta = −(F·σ·n(d1)) / (2·√T)` can still return **NaN** — 42,024 of 11,829,248 adversarial sweep
inputs — because `F·σ` overflows to `+inf` and `inf · 0` is NaN once the density has underflowed.
That is a third re-association, in theta's own expression, orthogonal to the `d1` question that was
ruled on. It never produces a negative or out-of-bounds price, so every safety property still holds
at zero violations. It is left alone on purpose: an authorization for two re-associations is not an
authorization for three. It is a candidate for its own decision, not a thing to smuggle in.

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
quietly become a hardware test.

The tests are more specific than that exclusion suggests, and the line moved after it was measured.
Finite and infinite results are asserted as exact bit patterns. NaN results used to be checked with
`isNan` and nothing else — which asserts only that both sides *failed*, and would pass two NaNs with
different payloads. They are now compared by **payload**, with the sign bit excluded where and only
where the sign was measured to move: between this repository's scalar and batch paths it does, on 31
of 477 NaN outputs in one build configuration and none in another, while the payload never moves in
any of them. Against `compiler_rt`'s `exp` and `log` even the sign is stable, over half a billion
NaN results, so there the comparison is all 64 bits. Two different rules, because two different
measurements — not because one file is stricter by temperament.

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
tools/assoc_delta.zig             the v2 -> v3' re-association impact measurement
tools/bench.zig                   ns/option
tests/golden_test.zig             replays the fixture; 16 tests
tests/libm_test.zig               exp/log vs compiler_rt; 4M samples under test, 1e9 under soak
vectors/black76-golden.ndjson     3,516 vectors, schema 3, 1.5 MB
vectors/black76-golden.v2.ndjson  the v2 numbers, on record
vectors/black76-golden.v1.ndjson  the v1 numbers, on record
bench/                            whole-binary optimisation harness for Graviton4 (bench/README.md)
docs/research/                    the literature review the harness was built from
.github/workflows/ci.yml          the gate, run on itself
```

`zig build bench-driver` builds the benchmark driver; it is not part of the default
install. The driver replays the fixture before it times anything, so a build
flag or a post-link rewrite that moves a bit is reported as a gate failure,
not as a faster number. It is a separate tool from `tools/bench.zig` above
(that one is the everyday `zig build bench` timer this README's own speed
table uses); the driver targets AWS Graviton4 build-variant comparisons, not
a single number.

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
