# Whole-binary optimisation of a Zig C-ABI pricing kernel on AWS Graviton4

*A literature review with priors, and the instrument that tests them. 30 August 2026.*

---

## 0. The answer, before the evidence

The question was: what does the academic and industrial compiler literature say about optimising an ARM64 binary — specifically `libblack76.so`, a Zig library with a flat C ABI — for AWS Graviton4, and which of it transfers?

Almost none of it transfers, and the literature itself says why. Every post-link and layout technique with a published number — Pettis–Hansen (1990), HFSort (2017), ext-TSP (2020), BOLT (2019), Propeller (2023), the Machine Function Splitter (2020) — earns its gain by fixing instruction-cache and iTLB misses in binaries with tens to hundreds of megabytes of hot text. The ext-TSP authors state the boundary condition in their own paper: *"for small binaries that are not front-end bound, both TSP and ExtTSP are not accurate models."* BOLT's AArch64 maintainers state the same thing as a rule of thumb: BOLT is for workloads with more than 10 L1i misses per thousand instructions or more than 10% front-end-bound slots. This library's entire `.text` is **2,836 bytes** (706 instructions in five functions). Neoverse V2 has a 64 KB L1 instruction cache and a 1,536-entry macro-op cache. The front-end condition cannot be met.

What the measurements made here show instead is where the time actually goes. On the main pricing path, exact instruction accounting (callgrind, x86-64 build, same source) puts **~59% of dynamic instructions in `exp`, `log` and `ldexp`** and ~41% in the kernel's own arithmetic, which contains twelve static `fdiv` and one `fsqrt` — instructions with a 7–16 cycle latency that only two of Neoverse V2's four FP pipes can execute. The kernel is a back-end, latency-bound numerical loop. Nothing that rearranges code layout changes that.

Three findings are practical rather than negative. First, **bit identity survives every whole-binary lever**: ten build variants (CPU tuning, LTO full/thin, sections+GC, frame-pointer omission, ReleaseSmall, ReleaseSafe, relocations) and a BOLT rewrite all reproduce the 3,516 golden vectors bit-for-bit as aarch64 machine code (run under qemu-user emulation; the Graviton4 run confirms it on silicon), and the aarch64 output hashes equal the x86-64 ones — the README's "sixteen for sixteen" result now extends across architectures. Second, the one whole-binary lever with a measurable cost is **ReleaseSmall, 7–11% slower** on the x86-64 reference machine, which is the expected sign for a core whose L1I holds the kernel twenty times over. Third, the upside, if any is wanted, lives at the source level in the transcendental functions and in lane-parallel evaluation — and part of that can be done without moving a bit, because LLVM scalarises `@exp` on vectors, so lane-wise arithmetic in the same order is bit-identical by construction.

The harness in `bench/` turns each of these into a measurement on the real machine with a bit-identity gate, an A/A noise floor, bootstrap confidence intervals, PMU counters, and BOLT's own applicability test. It has been validated end-to-end on x86-64 (including the BOLT instrument→train→optimise flow) and on aarch64 machine code under emulation; the Graviton4 run is the step that remains.

Evidence grades used below: **A** = peer-reviewed primary source or measured in this work; **B** = vendor primary documentation (Arm, AWS, LLVM, Zig source); **C** = conference talk slides, blog, or a chart read by eye.

---

## 1. The target: Graviton4 as a compiler sees it

| fact | value | source |
| --- | --- | --- |
| core / architecture | Arm Neoverse V2, Armv9.0-A | AWS getting-started README; Arm SWOG (B) |
| clock | 2.8 GHz fixed, no turbo (2.7 GHz on 48xlarge) | AWS (B) |
| L1I / L1D / L2 / LLC | 64 KB (4-way, 64 B lines) / 64 KB / 2 MB per core / 36 MB | Arm TRM; AWS (B) |
| macro-op cache | 1,536 entries, 4-way skewed | Arm TRM (B) |
| L1 iTLB / L1 dTLB / L2 TLB | 48 / 48 fully associative / 2,048 8-way | Arm TRM (B) |
| dispatch | up to 8 MOPs and 16 µops per cycle, 17 issue pipes, 4 FP/ASIMD | Arm SWOG §4.1 (B) |
| FP64 latencies | FMUL 3, FMADD 4, **FDIV 7–15 and FSQRT 7–16 on pipes V0/V2 only** | Arm SWOG (B) |
| SIMD | 4 × 128-bit NEON/SVE2; SVE vector length is 128 bits — the same width as NEON, narrower than Graviton3's 256 | AWS; Arm SWOG (B) |
| branch guidance | "avoid placing more than four branch instructions within an aligned 32-byte instruction memory region" | Arm SWOG §4.8 (B) |
| instruction fusion | CMP/CMN/TST+B.cond, CMP+CSEL/CSET, AES pairs, MOVPRFX+SVE; **ADRP+ADD and MOVZ/MOVK are not fused** | Arm SWOG §4.11 (B) |
| profiling hardware | SPE present; **no BRBE** (Armv9.1 feature; the V2 TRM does not mention it) | Arm TRM (B) |
| SPE exposure | "SPE is enabled on Graviton 2, 3, 4, and 5 **metal** instances" | AWS perfrunbook (B) |
| PMU exposure | full event set on `*8g.24xlarge` / `48xlarge`; basic set at smaller sizes | AWS perfrunbook (B) |
| page size | 4 KB on Amazon Linux 2023 and Ubuntu; 64 KB on RHEL-family | AWS os.md (B) |
| compiler flag | `-mcpu=neoverse-v2` (GCC 13+, Clang 16+; back-ported into AL2023's GCC 11) | AWS c-c++.md (B) |
| memory tagging | implemented in the core, **not exposed** to EC2 guests (HWCAP2_MTE blank) | Arm TRM vs AWS HWCAP table (B) |

Two consequences drive everything below. There is no LBR-equivalent branch stack on a virtualised Graviton4 (no BRBE, SPE metal-only), so any sample-based profile for BOLT or AutoFDO is either PC-sample inference or instrumentation. And SVE on Graviton4 buys no width over NEON; per the Arm SWOG, SVE `FSQRT` on F64 is confined to a single pipe (V0) where the NEON Q-form uses two, so for this kernel NEON is the correct SIMD target and SVE2 is only interesting for instructions NEON lacks.

---

## 2. The artifact, measured

The numbers in this section were measured in this work from the Zig 0.16.0 build of `src/black76.zig` for `aarch64-linux-gnu` at `-Dcpu=neoverse_v2 -Doptimize=ReleaseFast` (grade A).

The shared library exports exactly two symbols, `black76_greeks` and `black76_greeks_batch`, and contains **no relocations at all**: `exp` and `log` resolve to `compiler_rt.exp.exp` and `compiler_rt.log.log`, present as `LOCAL` symbols, so there is no PLT and no symbol-interposition path by which a host's libm could substitute its own `exp`. This also holds when the benchmark driver is linked against glibc: `exp` and `log` remain `LOCAL HIDDEN` compiler_rt definitions, not glibc imports. The README's fixture precondition — same transcendental implementations — is therefore structurally enforced for any consumer of the `.so`.

| section | bytes | contents |
| --- | --- | --- |
| `.text` | 2,836 | 706 instructions in five functions |
| `.rodata` | 4,384 | the two 2,048-byte exp/log tables plus constants |

| function | instructions | calls |
| --- | --- | --- |
| `black76_greeks` | 281 | `exp`, `log` |
| `exp` (compiler_rt) | 125 | `ldexp` |
| `log` (compiler_rt) | 168 | — |
| `ldexp` | 84 | — |
| `black76_greeks_batch` | 48 | `black76_greeks` |

Static instruction mix: `fmul` 95, `fadd` 59, `fsub` 27, `fmov` 45, `fcmp` 19, `fcsel` 17, **`fdiv` 12, `fsqrt` 1**, and **no `fmadd`/`fmsub` at all** — Zig's default strict float mode emits no contraction, which is why optimisation level and CPU feature set have never moved a bit. Frame pointers are kept in ReleaseFast (`stp x29, x30` / `add x29, sp` prologues are present), so `-fomit-frame-pointer` is a real, if small, lever. The batch function receives eleven integer-class arguments, three of which travel on the stack under AAPCS64; the per-position function's four doubles and six integer-class arguments all travel in registers.

Dynamic accounting (callgrind on the x86-64 build of the same source, 204,800 main-path options from the harness's grid workload; the proportions carry to aarch64 because the algorithms are identical):

| function | instructions per option | share |
| --- | --- | --- |
| `black76_greeks` | 125 | 33% |
| `exp` | 130 | 35% |
| `ldexp` | 35 | 9% |
| `log` | 55 | 15% |
| batch loop (inlined into the caller) | 29 | 8% |
| **total** | **~374** | |

Two `exp` evaluations survive per option (LLVM common-subexpression-eliminates `exp(−½x²)` across `N(d1)`, `n(d1)` and `N(−d1)` because it depends only on |x|), plus one `log`. The transcendental share is 59%. On the x86-64 reference machine (Cascade Lake, `-Dcpu=x86_64_v3`) the kernel prices one option in **79–80 ns** on the grid workload and **92–94 ns** on the fixture workload (whose degenerate branches and extreme tails cost more); those figures are the harness's own output and the yardstick the Graviton4 run will be read against.

---

## 3. The literature, lever by lever

### 3.1 CPU targeting

AWS recommends `-mcpu=neoverse-v2` for Graviton4 and notes that `-mcpu` "acts as both specifying the appropriate architecture and tuning" (B). Zig exposes it as `-Dcpu=neoverse_v2` / `-mcpu=neoverse_v2`; the model exists in `lib/std/Target/aarch64.zig` and expands to 70 features including `sve2`, `lse`, `bf16`, `i8mm`, `pauth` and `fuse_adrp_add`, with `crypto` and `sve2_aes` off (B, verified against the 0.16.0 source). Because the kernel is scalar and uses no atomics, the only expected effect is instruction scheduling; the harness's x86-64 dry run found tuned-versus-baseline differences of 2–4%, partly within the A/A floor. AWS's only published compiler-delta number on Graviton is unrelated to this flag ("15% better performance on Graviton2 when using gcc-10 instead of gcc-7") (B). **Prior for Graviton4: 0–3%, bit-identical.**

### 3.2 Link-time optimisation

Zig 0.16.0 makes LTO strictly opt-in (`-flto=full|thin`; `Step.Compile.lto`), requires LLD, and links Zig and C objects together under it (B, verified). The literature's LTO gains come from cross-translation-unit inlining and dead-code elimination in large programs; this library is a single module in which the batch loop is already inlined into its caller and the 281-instruction kernel is not inlined either way. **Prior: no measurable effect.** The harness keeps both LTO modes in the matrix precisely so that "no effect" is a number with a confidence interval rather than a belief.

### 3.3 Profile-guided optimisation

Instrumented PGO is the strongest lever in the literature for large, branchy programs: the Arm team's Neoverse V2 measurements put context-sensitive IR PGO plus LTO at +31% on MariaDB, +40% on Clang, +29% on PostgreSQL and +10% on NGINX, with BOLT adding a further 2–4 points on top (C, read from the stacked-bar chart in the LLVM Developers' Meeting 2025 tutorial "BOLT on AArch64", slide 53). AutoFDO recovers about 85% of instrumented FDO's gain from samples (10.5% geomean on Google's benchmarks) (A). Profiles go stale fast — 70% stale samples between weekly releases, over 92% after three weeks — and stale-profile matching recovers ~0.78 of the benefit (A).

None of this is reachable for Zig code. Issue #237 (Profile Guided Optimization) is open with no implementation; `zig build-lib` rejects `-fprofile-generate`, `-fprofile-sample-use` and `-mllvm`, while `zig cc` accepts them for C sources only (B, verified). Neoverse V2 lacks BRBE, so even AutoFDO on the C side would rely on SPE (metal instances) or PC samples. **Status: not applicable to the Zig kernel in 2026.**

### 3.4 Code layout and post-link optimisation

This is the body of work the question was really about, and its numbers are unambiguous about their preconditions.

| technique | venue | headline result | hardware / text size | grade |
| --- | --- | --- | --- | --- |
| Pettis & Hansen | PLDI 1990 | 2–26% speedup, average 8–10% | HP-PA, 16–128 KB caches | A |
| HFSort / C3 | CGO 2017 | +5.46% IPC (C3) vs +2.64% (PH); iTLB misses −44%; huge pages raise i-cache misses 3–4% | Ivy Bridge; 70–199 MB text | A |
| ext-TSP | IEEE TC 2020 | Clang +7.86% vs +7.11% (PH), baseline BOLT with original block order; **"for small binaries that are not front-end bound, both TSP and ExtTSP are not accurate models"** | Broadwell; Clang .text 48 MB; smallest SPEC hot text 117 KB | A |
| BOLT | CGO 2019 | HHVM +8.0% over PGO-reordered+LTO, data-center average +5.4%; Clang +15.0% over PGO+LTO; up to 20.4% over FDO+LTO and 52.1% without; **non-LBR profiles cost up to 5% vs LBR, tunable to <1%** | Ivy Bridge | A |
| Lightning BOLT | CC 2021 | BOLT processing 4.71× faster, memory −70.5%, same output quality | — | A |
| Machine Function Splitter | LLVM 2020 | Clang +2.33%, iTLB misses −31.7%, L1i misses −9.56%; SPECint +1.6% where it helped, −0.6% where it did not | Skylake | A |
| Propeller | ASPLOS 2023 | +1.1% to +8% beyond PGO+ThinLTO; Clang +7.3% (same as BOLT); memory −30–70%; BOLT crashed on all but one warehouse-scale app | Skylake; 26–598 MB text; **x86 only**, Arm profile conversion not upstream | A |
| BOLT on Neoverse V2 | LLVM DevMtg 2025 | BOLT alone: MariaDB +14%, Clang +26%, PostgreSQL +5%, NGINX +5%; on top of CS-PGO+LTO: +2–4 | Neoverse V2 | C |
| BOLT applicability rule | same talk, slide 5 | ">10% front-end bound" or ">10 L1i MPKI" | — | C |

Read against Section 2, the pattern is a gradient: the gains scale with hot-text size and front-end pressure, from HHVM's hundreds of megabytes down to NGINX's +5%, and every author who examined small binaries found noise or regression (ext-TSP reports omnetpp and x264 regressing 0.5–1.5% from worsened loop alignment despite fewer i-cache misses). A 2.8 KB kernel with two loop-free call chains sits far below the smallest binary any of these papers measured. **Prior for Graviton4: BOLT within the A/A floor; predicted L1i MPKI far below 1 and front-end-bound share far below 10%.**

The AArch64 tooling state matters for the harness, not the prior. Upstream BOLT supports AArch64 ELF (constant islands, veneer elimination, BTI patching; pointer-authentication passes relanded in late 2025) (B). Arm SPE profiles landed in LLVM 21 (`perf2bolt --spe`, June 2025) (B). Without BRBE, the routes on a virtualised Graviton4 are instrumentation (exact edge counts, no PMU needed) or `perf2bolt -nl` PC-sample inference, with the BOLT paper's up-to-5% penalty for the latter; SPE needs a metal instance. Two Zig-specific facts were established empirically: `--emit-relocs` produces the `R_AARCH64_CALL26`/`JUMP26` relocations BOLT needs only under LLD and is silently ignored by the self-hosted linker, and BOLT's instrumentation refuses a dynamic executable without `DT_FINI`/`DT_FINI_ARRAY`, which Zig's aarch64 glibc link lacks — the harness's driver carries an empty `.fini_array` entry for BOLT to patch (A). LLVM 18's BOLT rewrote the aarch64 driver (333 functions, all processed) and the result reproduced every golden vector under emulation (A).

### 3.5 Huge pages and the instruction TLB

The strongest published huge-page result for code is Meta's: iTLB miss rate roughly halved, CPU −5%, of which "approximately half from hot-text, half from huge page" across 50+ services (ICWS 2019) (A). HFSort found the same iTLB benefit and a 3–4% *increase* in i-cache misses from 2 MB pages (A). An AArch64 kernel patch from March 2026 (contiguous-PTE executable folios) reports iTLB misses −92% and 2.6% wall-time on a Cortex-A53 building Linux (C). Neoverse V2's L1 iTLB holds 48 fully-associative entries at 4 KB, and the pricer's code fits in one page. **Not applicable**; the harness records THP state in `meta.json` only so that it is on the record.

### 3.6 Binary rewriting and lifting

If the question had been "optimise a third-party ARM64 binary", this is the literature: ARMore (USENIX Security 2023) rewrites stripped, non-PIC and Go AArch64 binaries with a layout-preserving rebound table at **0.99% average overhead** on SPEC CPU2017 (10.74% with call emulation for C++), passing 97.5% of Debian test suites on an APM X-Gene (A); Egalito (ASPLOS 2020) lifts to a machine-level IR and is the one rewriter that demonstrated layout optimisation — profile-guided function reordering gave **+1.0% geomean** on SPEC CPU2006 with dealII at +11.8%, and collapsing PLT calls +1.7% (A); Ddisasm's Datalog symbolisation reaches 99.9% test pass rates but was x86-64 at publication and its ARM64 backend is unmeasured (A); RetroWrite's AArch64 port exists only in a thesis; BinRec's dynamic lifting recovered −O0 binaries to 0.98× but is 32-bit x86 only; the CSET 2022 head-to-head found LLVM-IR lifting "infeasible given the current state of binary type analysis" (A); and the only verified rewriting (Verbeek et al., CCS 2024) is x86-64 PIE, C only. No peer-reviewed comparison of a general rewriter against BOLT on AArch64 exists, and no rewriter has been validated against pointer authentication, BTI landing pads or `.gnu.property` notes. For source-available Zig code none of this is a route to speed: the same layout transforms are available from the compiler and BOLT with the source in hand, and Egalito's +1.0% is the ceiling the field has shown for rewriting-based reordering.

### 3.7 Where the time is: transcendental functions and lanes

Because 59% of instructions are `exp`/`log`/`ldexp`, the levers with real leverage are the transcendental implementation and evaluating several options per instruction. The literature and vendor data here (all B unless marked):

| item | fact |
| --- | --- |
| AArch64 vector function ABI | `_ZGV<isa><mask><len><params>_<name>`; `n` = NEON, `s` = SVE; e.g. `_ZGVnN2v_exp`, `_ZGVsMxv_exp` |
| glibc libmvec on AArch64 | added in 2.38; auto-vectorisable `exp`/`log`/`sin`/`cos` from 2.39 with `-ffast-math`; `erf`, `erfc`, `pow` from **2.40**; codegen work in 2.41 |
| Arm Optimized Routines accuracy | NEON `exp` 1.9 + 0.5 ULP, SVE `exp` 0.51 + 0.5 ULP; `log` 1.67 (NEON) / 2.64 (SVE); `erf` 2.29; `erfc` 1.71 — none correctly rounded |
| FEXPA (SVE) | single-precision `expf` 5.95× over scalar in Arm's worked example (core unstated) (C) |
| SVE vs NEON on Graviton4 | VL = 128 bits; SVE F64 `FSQRT` on one pipe vs two for NEON; SVE2 pays off only for instructions NEON lacks |
| divide/sqrt guidance | "prefer FRECPE/FRSQRTE + Newton–Raphson" over FDIV/FSQRT, which block their pipe until complete |

Two of these interact with the bit-identity contract in opposite ways. Replacing `exp`/`log` with a vector library changes the last ulp — the README already prices what a better CDF costs, and a different `exp` is the same class of decision, for the P&L owner rather than the compiler. Evaluating the kernel's *own* arithmetic two options at a time on NEON does **not** change bits: IEEE-754 `+ − × ÷ √` are correctly rounded per lane, and LLVM lowers `@exp` on a `@Vector(2, f64)` to two scalar calls of the same `compiler_rt.exp` (verified: `-Dcpu=neoverse_v2` output uses `fmul v0.2d` NEON forms and no `z` registers, and Zig cannot reach fixed-length SVE codegen because `-msve-vector-bits` is Clang-only). An Amdahl estimate with the Section 2 split — 41% of instructions vectorised two-wide, 59% unchanged — bounds the bit-identical SIMD gain at roughly **1.26×** (≈20% less time) before pipe and latency effects, which the harness's `grid` workload is designed to measure against. That is a source-level change and outside this report's whole-binary scope; it is recorded here because it is where the measured evidence points.

### 3.8 The C-ABI boundary, briefly

The library's two signatures are ABI-benign: `black76_greeks` passes four doubles in `d0–d3` and six integer-class arguments in `x0–x5`; `black76_greeks_batch` has eleven integer-class arguments, so three are spilled to the caller's stack — a few loads per batch, not per option. Zig 0.16.0 renamed `callconv(.C)` to `callconv(.c)` (the old spelling is now an error); the AArch64 C-ABI issues #10402 and #12185 are closed, the C-ABI test suite covers `aarch64-linux-musl` and big-endian, and one in-tree caveat remains — mixed `u8`/`f32` small aggregates are skipped on aarch64 in release modes — which this flat, struct-free ABI never touches (B). Apple's ARM64 divergences (variadic arguments on the stack, packed small arguments) do not apply to Linux/Graviton. For an FFI host, the per-call cost of `black76_greeks` is dominated by the ~375-instruction body, not by the call; the batch entry point exists so that hosts amortise the FFI trampoline, and the harness's `scalar` workload measures the difference.

---

## 4. Toolchain facts that constrain the experiment (Zig 0.16.0, verified)

| lever | availability | detail |
| --- | --- | --- |
| release | 0.16.0 (13 Apr 2026), LLVM/LLD 21.1.0; repository now on Codeberg | ziglang.org (B) |
| aarch64 backend | LLVM for every optimise mode; the self-hosted aarch64 backend is not default in any mode and crashes on the behaviour tests | 0.16.0 release notes; `src/target.zig` (B) |
| `-Dcpu=neoverse_v2` | yes; `+feature`/`-feature` syntax works | (B) |
| LTO | `-flto=full|thin`, opt-in, LLD only, cross-language | (B) |
| PGO for Zig code | no (issue #237 open); `zig cc` only for C | (B) |
| relocations for BOLT | `--emit-relocs` / `link_emit_relocs`, LLD only; conflicts with `-fstrip` | (B, A) |
| layout/size controls | `-ffunction-sections`, `-fdata-sections`, `--gc-sections`, `-fomit-frame-pointer`, `-fstrip`, `-fno-unwind-tables`, `ReleaseSmall` | (B) |
| fast math | `@setFloatMode(.optimized)` only; no `-ffast-math`; out of scope here because it moves bits | (B) |
| vectors | `@Vector` fixed-width, lowered to NEON; `std.simd.suggestVectorLength(f64)` returns 4 on neoverse_v2 and is split into two NEON ops; fixed-length SVE unreachable | (B, A) |
| timing | `std.time.Timer` removed; `std.Io.Clock.awake` (CLOCK_MONOTONIC) used by the harness | (B) |

---

## 5. Hypotheses the harness decides

Each row states the prior from Sections 1–4, the measurement that decides it, and what would falsify it. Effects are on ns/option for the `grid` workload, `static` mode, relative to `v2`; "floor" is the A/A confidence-interval half-width the run itself measures.

| # | lever | prior effect | decided by | falsified if |
| --- | --- | --- | --- | --- |
| H1 | `-Dcpu=neoverse_v2` vs `baseline` | 0–3% faster | `base` vs `v2` | > 5% either way |
| H2 | LTO full / thin | none | `v2-lto-*` | outside the floor |
| H3 | sections + gc | none | `v2-sections` | outside the floor |
| H4 | omit frame pointer | ≤ 1% faster (≈ 4 of ~375 instructions per call) | `v2-nofp` | > 3% |
| H5 | ReleaseSmall | 5–15% slower | `v2-small` | not slower |
| H6 | ReleaseSafe | 0–10% slower | `v2-safe` | faster |
| H7 | `--emit-relocs` | none | `v2-relocs` | outside the floor |
| H8 | BOLT | within floor; L1i MPKI ≪ 1; FE-bound ≪ 10% | `v2-bolt` and the counter table | BOLT gate passes or effect > floor |
| H9 | bit identity | every variant and BOLT identical to the fixture and to each other | gate + hashes | any mismatch |
| H10 | instruction economy | ≈ 370–380 instructions per option; IPC 1.5–3 | `instr/option`, IPC | far outside |
| H11 | `so` vs `static` | ≤ 2% (one indirect call per batch; per-call in `scalar`) | mode comparison | > 5% |

H9 is already established on aarch64 machine code under emulation (60 of 60 runs, ten variants, identical hashes) and for a BOLT-rewritten aarch64 binary; hardware confirms or refutes it in seconds. H8 is the report's central claim and the one the counters settle independently of timing noise.

---

## 6. The instrument

`bench/` adds a `zig build bench-driver` target [integration note, 2026-08-30: landed as `bench-driver`; `bench` was already taken by the kernel timer], a driver, and four scripts; the main `README.md` gains a pointer and nothing else. The driver (`bench/bench.zig`) replays the golden vectors and counts bit mismatches before it times anything, hashes every output bit of every workload so `analyze.py` can prove cross-variant identity without a fixture per input, and reports ns/option as a distribution per process. `run_matrix.sh` builds the ten variants with one flag changed per row, interleaves their runs so drift is spread evenly, collects raw Arm PMU events in four non-multiplexed groups, and calls `bolt.sh` to produce the eleventh variant by instrumentation (default), PC sampling, or SPE. `analyze.py` (standard library only) prints the verdicts in the order that matters: bit identity, A/A floor, per-lever ratios with percentile-bootstrap CIs and Mann–Whitney tests, counters, and the BOLT gate. `setup_graviton.sh` installs the pinned Zig, perf and BOLT on Ubuntu or Amazon Linux 2023.

Validation performed here: the full pipeline on x86-64 (ten variants, BOLT instrument→train→optimise, 168 of 168 gate passes, identical hashes, A/A floor 1.5–6% on a shared 2-vCPU sandbox, ReleaseSmall 7–11% slower, everything else within the floor); every variant cross-compiled for `aarch64-linux-gnu -Dcpu=neoverse_v2` and run under qemu-user (60 of 60 gate passes, identical hashes, A/A binaries byte-identical); a BOLT 18 rewrite of the aarch64 driver passing the gate; and confirmation that BOLT instrumentation needs the `.fini_array` anchor. What has not been run is the thing the harness is for: the Graviton4 timings and counters. `bench/README.md` gives the instance guidance (any `c8g` size for timings and instrumentation; `24xlarge`+ for the full PMU set; metal for SPE) and the exact commands.

---

## 7. Gaps in the evidence

No paper measures code-layout gains for binaries in the tens-of-kilobyte range; the smallest hot-text figure in any surveyed primary source is 117 KB (ext-TSP, cactuBSSN), and no study reports the size threshold at which gains vanish — Section 3.4's prior is an extrapolation of a consistent gradient, which is why H8 is measured rather than asserted. No published BOLT or PGO number was measured on an AWS Graviton4 instance as such; the Neoverse V2 numbers come from Arm's talk and do not name the machine. No quantified comparison of SPE-derived edge weights against LBR exists; the "under 5% overhead, >99% hotspot identification" figures are secondhand (a 2025 survey citing Miksits et al.) and hotspot identification is a weaker property than the edge-weight fidelity layout needs. Published FP64 `exp`/`log`/`erf` throughput on Neoverse V2 for Arm Optimized Routines, libmvec or SLEEF was not found; the only vector-math timing found is single-precision `expf` on an unstated core. Zig's `std.Io.Clock` resolution on aarch64 Linux is undocumented; the harness sidesteps it by timing batches of thousands of options, not single calls. Finally, the AArch64 rewriting literature has not been validated against PAC/BTI-hardened binaries, which is irrelevant to this library (Zig emits neither by default) but would matter for any third-party binary.

---

## 8. Sources

Peer-reviewed and primary: Panchenko, Auler, Nell, Ottoni, "BOLT: A Practical Binary Optimizer for Data Centers and Beyond", CGO 2019, https://arxiv.org/abs/1807.06735 · Panchenko, Auler, Sakka, Ottoni, "Lightning BOLT", CC 2021, https://dl.acm.org/doi/10.1145/3446804.3446843 · Shen et al., "Propeller: A Profile Guided, Relinking Optimizer for Warehouse-Scale Applications", ASPLOS 2023, https://dl.acm.org/doi/10.1145/3575693.3575727 · Newell, Pupyrev, "Improved Basic Block Reordering", IEEE TC 2020, https://arxiv.org/abs/1809.04676 · Ottoni, Maher, "Optimizing Function Placement for Large-Scale Data-Center Applications", CGO 2017, https://research.facebook.com/file/239900718045884/cgo2017-hfsort-final1.pdf · Pettis, Hansen, "Profile Guided Code Positioning", PLDI 1990, https://pages.cs.wisc.edu/~fischer/cs701.f05/code.positioning.pdf · Kumar et al., "Machine Function Splitter", llvm-dev Aug 2020, https://lists.llvm.org/pipermail/llvm-dev/2020-August/144012.html · Chen, Li, Moseley, "AutoFDO", CGO 2016, https://research.google/pubs/autofdo-automatic-feedback-directed-optimization-for-warehouse-scale-applications/ · Ayupov, Panchenko, Pupyrev, "Stale Profile Matching", CC 2024, https://arxiv.org/abs/2401.17168 · He et al., "Profile Inference Revisited", POPL 2022 · Zhuang et al., "Automated Hot_Text and Huge_Pages", ICWS 2019, https://link.springer.com/chapter/10.1007/978-3-030-23499-7_10 · Di Bartolomeo, Moghaddas, Payer, "ARMore: Pushing Love Back Into Binaries", USENIX Security 2023, https://www.usenix.org/conference/usenixsecurity23/presentation/di-bartolomeo · Williams-King et al., "Egalito: Layout-Agnostic Binary Recompilation", ASPLOS 2020, https://cs.brown.edu/people/vpk/papers/egalito.asplos20.pdf · Flores-Montoya, Schulte, "Datalog Disassembly", USENIX Security 2020 · Dinesh et al., "RetroWrite", IEEE S&P 2020 · Altinay et al., "BinRec", EuroSys 2020 · Schulte, Brown, Folts, "A Broad Comparative Evaluation of x86-64 Binary Rewriters", CSET 2022, https://arxiv.org/abs/2203.13231 · Verbeek, Naus, Ravindran, "Verifiably Correct Lifting of Position-Independent x86-64 Binaries", CCS 2024 · Liu et al., "From Profiling to Optimization: Unveiling the Profile Guided Optimization", arXiv 2507.16649, 2025.

Vendor and toolchain: Arm Neoverse V2 Software Optimization Guide, https://documentation-service.arm.com/static/668bc0a369e89f01e39c4668 · Arm Neoverse V2 Technical Reference Manual · AWS aws-graviton-getting-started (README, c-c++.md, os.md, runtime-feature-detection.md, perfrunbook/debug_hw_perf.md), https://github.com/aws/aws-graviton-getting-started · Mpeis, "Tutorial: BOLT on AArch64 and how it compares with other PGOs", LLVM Developers' Meeting, Oct 2025, https://llvm.org/devmtg/2025-10/slides/tutorials/mpeis.pdf · LLVM BOLT README and PR #129231 (SPE), https://github.com/llvm/llvm-project/pull/129231 · Discourse: "Enabling AutoFDO & Propeller optimizations on Arm with SPE", https://discourse.llvm.org/t/enabling-autofdo-propeller-optimizations-on-arm-with-spe/78980 · AArch64 Vector Function ABI, https://github.com/ARM-software/abi-aa/blob/main/vfabia64/vfabia64.rst · Arm Optimized Routines, https://github.com/ARM-software/optimized-routines · glibc NEWS, https://github.com/bminor/glibc/blob/master/NEWS · Zig 0.16.0 release notes, https://ziglang.org/download/0.16.0/release-notes.html · ziglang/zig issue #237, PR #24536; Zig 0.16.0 source (`src/target.zig`, `src/Compilation/Config.zig`, `src/link/Lld.zig`, `lib/std/Build/Step/Compile.zig`, `lib/std/Target/aarch64.zig`).
