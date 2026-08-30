# bench — does whole-binary optimisation do anything for this pricer on Graviton4?

This directory is a measuring instrument, not a benchmark suite. It exists to
answer one question with numbers instead of opinions:

> On an AWS Graviton4 (Arm Neoverse V2), which of the whole-binary levers —
> CPU tuning, LTO, sections/GC, frame pointers, size-first codegen, and
> post-link optimisation with LLVM BOLT — changes the throughput of
> `black76_greeks_batch`, by how much, and does any of them move a bit?

The literature says the answer for a ~3 KB kernel should be "almost none of
them, and none should move a bit". The instrument is built so that either
answer is a finding: every run replays the 3,516 golden vectors first, and a
variant that changes a bit fails loudly before any timing is reported.

The companion write-up (`docs/research/2026-08-graviton4-whole-binary-optimization.md`)
has the literature and the priors; this file is the operating manual.

---

## Quick start on a Graviton4 instance

```sh
git clone https://github.com/CMZN-Consulting/black76-zig && cd black76-zig
git checkout research/graviton4-whole-binary-optimization
bash bench/setup_graviton.sh          # zig 0.16.0, perf, python3, taskset, llvm-bolt (Ubuntu)
sudo sysctl kernel.perf_event_paranoid=1
bench/run_matrix.sh                    # ~10-15 min at the defaults; prints the report
```

Results land in `bench/results/<UTC stamp>/`:

| file | what |
| --- | --- |
| `report.md` / `report.txt` | the analysis: bit identity, A/A noise floor, per-lever effect with CIs, counters, BOLT gate |
| `runs.jsonl` | one JSON line per (variant, mode, workload, process) — the raw timings |
| `perf/*.csv` | `perf stat -x,` counter files, one per (variant, mode, event group) |
| `builds.tsv` | flags, sha256 and `.text` size of every variant |
| `meta.json` | machine, instance type, kernel, THP, page size, perf version, every knob |
| `build/<variant>/` | the binaries themselves, so anything can be re-run or disassembled |
| `build/v2-bolt/bin/bench-driver.bolt/` | BOLT's profile, log and dyno-stats |

Instance guidance, from the AWS Graviton getting-started perfrunbook:

- **Any c8g/m8g/r8g size** runs the timings and the BOLT instrumentation flow.
  PMU counters are available at every size, but the **full** event set is
  only exposed on `*8g.24xlarge` and `48xlarge`; smaller sizes get a basic set
  and some rows in the counter table will read `n/a`.
- **Arm SPE** (`BOLT_MODE=spe`) is exposed on **metal** instances only.
- Graviton4 has no turbo: 2.8 GHz fixed (2.7 GHz on 48xlarge). Frequency is
  not a confound here, which is unusual and worth having.

## What gets built

One row per lever. Everything not named in the row is Zig's default.

| variant | flags | question it answers |
| --- | --- | --- |
| `base` | `ReleaseFast -Dcpu=baseline` | what a generic aarch64 cross-build costs |
| `v2` | `ReleaseFast -Dcpu=neoverse_v2` | **the reference** |
| `v2-aa` | identical to `v2` | the noise floor (A/A). The binaries are byte-identical; any "difference" is the machine, not the code |
| `v2-lto-full` / `v2-lto-thin` | `-Dlto=full` / `thin` | does LTO across the driver/kernel boundary buy anything |
| `v2-sections` | `-Dsections=true` | function/data sections + `--gc-sections` |
| `v2-nofp` | `-Domit-frame-pointer=true` | Zig keeps frame pointers in ReleaseFast; what do they cost |
| `v2-small` | `ReleaseSmall -Dcpu=neoverse_v2` | what size-first codegen costs on a core whose L1I holds the kernel 20× over |
| `v2-safe` | `ReleaseSafe` | the price of runtime safety (informational) |
| `v2-relocs` | `-Demit-relocs=true -Dbench-libc=true` | the BOLT input; should time identically to `v2` |
| `v2-bolt` | `bench/bolt.sh` on `v2-relocs` | post-link layout optimisation (ext-TSP, hfsort, hot/cold split) |

Each variant is exercised two ways, because they answer different questions:

- `--mode static`: the kernel is compiled into the driver and called
  directly. LTO, inlining and BOLT can act on this. It is also the only mode
  in which the driver's loop could ever be fused with the kernel.
- `--mode so`: the driver `dlopen`s the variant's `libblack76.so` and calls
  through function pointers — how an FFI host (Bun, Python, anything) uses it.

and on three workloads:

- `fixture`: the 3,516 golden inputs, batch call. Realistic mix including
  every degenerate branch. Output is compared to the fixture bit-for-bit.
- `grid`: 16,384 main-path options from a fixed-seed generator (log-uniform
  forward 1–1e5, moneyness 0.6–1.6, vol 5–150%, 1 day–2 years). ~1.2 MB of
  arrays: L2-resident on Neoverse V2, so this measures the kernel, not DRAM.
- `scalar`: the same 16,384 options, one `black76_greeks` call each from the
  driver's loop — the per-position FFI shape.

## What the report says, and in what order

1. **Bit identity.** Gate pass count and the FNV-1a hash of every output bit
   per (mode, workload), across all variants. If this section is not clean,
   nothing below it matters — the README's rule.
2. **Noise floor.** `v2-aa` vs `v2`: the ratio, its bootstrap CI and the
   Mann–Whitney p. The CI half-width is the minimum effect this run can
   resolve. Every lever is judged against it, not against zero.
3. **Levers.** Median ns/option per variant with a bootstrap 95% CI; ratio to
   `v2` with its own CI; Mann–Whitney U; Cliff's delta; `.text` bytes. A
   verdict per row: `no effect (CI spans 1)`, `within A/A noise`, or
   `FASTER/SLOWER by x%`.
4. **Counters and the BOLT gate.** IPC, instructions/option, branch MPKI,
   L1i MPKI, iTLB, L1d/L2 MPKI, front-/back-end stall shares and Arm's
   topdown-L1 split. Then BOLT's own rule of thumb, as stated by its AArch64
   maintainers (>10 L1i MPKI or >10% front-end bound): if the reference build
   does not clear it, layout optimisation was never going to matter and any
   `v2-bolt` delta is read against the A/A floor.
5. **Build facts**, including that the A/A binaries are byte-identical.

The statistics are deliberately non-parametric and small-sample-honest:
the unit of observation is one process (its median over `ITERS`
iterations), `REPS` processes give the sample, CIs are percentile bootstraps
(B = 5000), and the test is Mann–Whitney with tie correction. Raise `REPS`
before trusting a p-value below 0.05 at REPS < 8.

## Knobs

All environment variables; every value is recorded in `meta.json`.

| knob | default | meaning |
| --- | --- | --- |
| `VARIANTS` | all ten | space-separated subset to build and run |
| `REPS` | 10 | processes per (variant, mode); the sample size |
| `ITERS` / `WARMUP` | 300 / 30 | timed / untimed iterations per workload per process |
| `GRID_N` | 16384 | options in the synthetic grid |
| `MODES` | `static so` | |
| `PIN` | `auto` | core to pin to (`auto` = core 2 on ≥ 4 cores; `""` = none) |
| `PERF` | `auto` | `off` to skip counters |
| `PERF_ITERS` / `PERF_REPS` | 1000 / 3 | counter runs use more iterations so the parse-and-gate preamble is < 2% |
| `BOLT_MODE` | `instr` | `instr` (any instance), `perf` (PC samples, needs PMU), `spe` (metal only), `off` |
| `BOLT_BIN_DIR` | auto | directory holding `llvm-bolt`, `merge-fdata`, `perf2bolt` |
| `CPU` | `neoverse_v2` | `-Dcpu` for every non-baseline variant |
| `TARGET` / `RUNNER` | native / none | cross-compile smoke test, e.g. `TARGET=aarch64-linux-gnu RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu"` |
| `OUT` | `bench/results/<stamp>` | |

## BOLT specifics that cost an afternoon each

- BOLT needs relocations: `-Demit-relocs=true` passes `--emit-relocs` to LLD.
  This is silently ignored by Zig's self-hosted linker (`-fno-lld`), and
  `-fstrip` conflicts with it; the matrix uses neither.
- BOLT's instrumentation runtime writes its profile from a `DT_FINI` /
  `DT_FINI_ARRAY` hook and refuses a dynamic executable with neither. Zig's
  aarch64 glibc link has neither, so `bench.zig` carries one empty
  `.fini_array` entry for BOLT to patch (`bolt_fini_anchor`). Static, no-libc
  executables are exempt from the check, which is why `v2-relocs` is built
  with `-Dbench-libc=true` only for the driver — the library never links libc
  and its `exp`/`log` stay Zig's (verified: with libc linked, `exp` and `log`
  are still `LOCAL HIDDEN` symbols from compiler_rt, not glibc imports).
- Graviton4 has **no BRBE** (Neoverse V2 is Armv9.0; BRBE is 9.1+), so there
  is no LBR-equivalent branch stack. That leaves instrumentation (exact edge
  counts), `perf2bolt -nl` (PC samples; the BOLT paper measured up to 5%
  lost versus LBR on HHVM, tunable to under 1%), or SPE on metal.
- `-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions
  -split-all-cold -split-eh` is BOLT's own recommended set and the one Arm
  used in its AArch64 write-up. Add flags with `BOLT_EXTRA_FLAGS`.
- BOLT on the `.so` itself is a separate experiment: `llvm-bolt libblack76.so
  -instrument ...` works in recent LLVM but the library has ~700 instructions
  and 7 calls; run it if you want the number, but read section 4 first.

## Emulated smoke test (no Graviton at hand)

```sh
apt install qemu-user-static libc6-arm64-cross
TARGET=aarch64-linux-gnu RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" \
  REPS=1 ITERS=5 GRID_N=2048 BOLT_MODE=off bench/run_matrix.sh
```

This validates the builds, the gate and the cross-variant hashes on real
aarch64 machine code. The timings it prints are qemu's and mean nothing;
the report says so at the top.
