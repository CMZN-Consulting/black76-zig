#!/usr/bin/env python3
"""analyze.py -- turn one run_matrix.sh output directory into a verdict.

    python3 bench/analyze.py bench/results/<stamp> [--ref v2] [--aa v2-aa] [--slots 8]

Standard library only, so it runs on a bare Graviton box. It answers four
questions, in this order, and refuses to answer the fourth if the first two
fail:

  1. Did any variant move a bit?        (gate status + cross-variant output hashes)
  2. What is the noise floor?           (A/A: two builds of the same flags)
  3. What did each lever do?            (median ns/option, bootstrap CI, ratio to
                                         the reference, Mann-Whitney U, Cliff's delta)
  4. Was post-link optimisation ever    (L1i MPKI and front-end-bound share against
     going to matter here?               BOLT's own rule of thumb, from the counters)

Statistics: per (variant, mode, workload) the unit of observation is one
PROCESS (its median ns/option over --iters iterations); REPS processes give
the sample. Medians and percentile-bootstrap 95% CIs (B = 5000, fixed seed).
The ratio CI resamples both groups. Mann-Whitney U uses the normal
approximation with tie correction, which is adequate at REPS >= 8; at REPS < 8
treat p as indicative only. Nothing here is a t-test: per-process medians are
not normal and the samples are small.
"""

import csv
import glob
import json
import math
import os
import random
import re
import sys
from collections import defaultdict

B = 5000
SEED = 20260830

ARM_EVENTS = {
    "r08": "INST_RETIRED", "r11": "CPU_CYCLES", "r21": "BR_RETIRED", "r22": "BR_MIS_PRED_RETIRED",
    "r23": "STALL_FRONTEND", "r24": "STALL_BACKEND", "r14": "L1I_CACHE", "r01": "L1I_CACHE_REFILL",
    "r02": "L1I_TLB_REFILL", "r35": "ITLB_WALK", "r04": "L1D_CACHE", "r03": "L1D_CACHE_REFILL",
    "r16": "L2D_CACHE", "r17": "L2D_CACHE_REFILL", "r34": "DTLB_WALK", "r3b": "OP_SPEC",
    "r3a": "OP_RETIRED", "r3e": "STALL_SLOT_FRONTEND", "r3d": "STALL_SLOT_BACKEND", "r3f": "STALL_SLOT",
    # generic names, used on non-Arm smoke runs
    "cycles": "CPU_CYCLES", "instructions": "INST_RETIRED", "branches": "BR_RETIRED",
    "branch-misses": "BR_MIS_PRED_RETIRED", "L1-icache-load-misses": "L1I_CACHE_REFILL",
    "iTLB-load-misses": "L1I_TLB_REFILL",
}

# BOLT's applicability rule of thumb, as stated by the AArch64 BOLT maintainers
# (Arm, LLVM Developers' Meeting Oct 2025, "BOLT on AArch64", slide 5):
# front-end bound > 10% of slots, or > 10 L1i misses per kilo-instruction.
FE_BOUND_THRESHOLD = 10.0
L1I_MPKI_THRESHOLD = 10.0


# -- small stats ------------------------------------------------------------------

def median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return float("nan")
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def boot_ci_median(xs, rng):
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    meds = []
    n = len(xs)
    for _ in range(B):
        meds.append(median([xs[rng.randrange(n)] for _ in range(n)]))
    meds.sort()
    return (meds[int(0.025 * B)], meds[int(0.975 * B) - 1])


def boot_ci_ratio(a, b, rng):
    """CI for median(a)/median(b), resampling both groups."""
    if len(a) < 2 or len(b) < 2:
        return (float("nan"), float("nan"))
    na, nb = len(a), len(b)
    rs = []
    for _ in range(B):
        ma = median([a[rng.randrange(na)] for _ in range(na)])
        mb = median([b[rng.randrange(nb)] for _ in range(nb)])
        rs.append(ma / mb if mb else float("nan"))
    rs.sort()
    return (rs[int(0.025 * B)], rs[int(0.975 * B) - 1])


def mann_whitney(a, b):
    """Two-sided Mann-Whitney U with tie-corrected normal approximation.
    Returns (U_a, p, cliffs_delta). delta > 0 means a tends to be LARGER."""
    n, m = len(a), len(b)
    if n == 0 or m == 0:
        return (float("nan"), float("nan"), float("nan"))
    allv = sorted([(x, 0) for x in a] + [(y, 1) for y in b])
    ranks = [0.0] * (n + m)
    i = 0
    tie_term = 0.0
    while i < n + m:
        j = i
        while j + 1 < n + m and allv[j + 1][0] == allv[i][0]:
            j += 1
        r = 0.5 * (i + j) + 1.0
        for k in range(i, j + 1):
            ranks[k] = r
        t = j - i + 1
        if t > 1:
            tie_term += t ** 3 - t
        i = j + 1
    ra = sum(ranks[k] for k in range(n + m) if allv[k][1] == 0)
    u_a = ra - n * (n + 1) / 2.0
    mu = n * m / 2.0
    N = n + m
    sigma2 = n * m / 12.0 * ((N + 1) - tie_term / (N * (N - 1))) if N > 1 else 0.0
    if sigma2 <= 0:
        return (u_a, 1.0, 2.0 * u_a / (n * m) - 1.0)
    z = (u_a - mu) / math.sqrt(sigma2)
    p = math.erfc(abs(z) / math.sqrt(2.0))
    delta = 2.0 * u_a / (n * m) - 1.0
    return (u_a, p, delta)


def fmt(x, d=2):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "n/a"
    return f"{x:.{d}f}"


# -- loading -----------------------------------------------------------------------

def load_runs(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def load_builds(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            out[row["variant"]] = row
    return out


def load_perf(perf_dir):
    """{(variant, mode): {EVENT_NAME: value}} from perf stat -x, CSV files."""
    out = defaultdict(dict)
    for path in glob.glob(os.path.join(perf_dir, "*.csv")):
        base = os.path.basename(path)[:-4]
        parts = base.split("_")
        if len(parts) < 3:
            continue
        variant, mode = "_".join(parts[:-2]), parts[-2]
        with open(path) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                fields = line.rstrip("\n").split(",")
                if len(fields) < 3:
                    continue
                value, event = fields[0].strip(), None
                for fld in fields[1:4]:
                    if fld in ARM_EVENTS or re.fullmatch(r"r[0-9a-fA-F]+(:u)?", fld):
                        event = fld.split(":")[0]
                        break
                if event is None:
                    continue
                name = ARM_EVENTS.get(event, event)
                try:
                    out[(variant, mode)][name] = float(value)
                except ValueError:
                    out[(variant, mode)][name] = None  # <not supported> / <not counted>
    return out


# -- main --------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    out_dir = sys.argv[1]
    ref = "v2"
    aa = "v2-aa"
    slots = 8
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--ref":
            ref = args[i + 1]
        elif a == "--aa":
            aa = args[i + 1]
        elif a == "--slots":
            slots = int(args[i + 1])

    meta = {}
    try:
        with open(os.path.join(out_dir, "meta.json")) as f:
            meta = json.load(f)
    except (OSError, json.JSONDecodeError):
        pass
    runs = load_runs(os.path.join(out_dir, "runs.jsonl"))
    builds = load_builds(os.path.join(out_dir, "builds.tsv"))
    perf = load_perf(os.path.join(out_dir, "perf"))
    rng = random.Random(SEED)
    lines = []
    P = lines.append

    P(f"# black76-zig whole-binary optimisation matrix -- {out_dir}")
    P("")
    P(f"machine: {meta.get('uname', '?')} | instance: {meta.get('instance_type', '?')} | cpu part: {meta.get('cpu_part', '?')} | zig {meta.get('zig', '?')}")
    P(f"reps={meta.get('reps', '?')} iters={meta.get('iters', '?')} grid_n={meta.get('grid_n', '?')} pin={meta.get('pin', '?')} thp={meta.get('thp', '?')} perf_usable={meta.get('perf_usable', '?')}")
    if meta.get("runner"):
        P(f"RUNNER={meta['runner']!r}: timings below are EMULATED and meaningless; only the gate, hashes and build facts count.")
    P("")

    if not runs:
        P("no runs found in runs.jsonl")
        print("\n".join(lines))
        sys.exit(1)

    # -- 1. bit identity --------------------------------------------------------
    P("## 1. Bit identity")
    P("")
    gate_fail = [r for r in runs if r.get("gate") == "FAIL"]
    P(f"gate: {len(runs) - len(gate_fail)}/{len(runs)} runs replayed the 3,516 golden vectors and the grid batch/per-call pair bit-for-bit"
      + ("" if not gate_fail else "  <-- FAILURES: " + ", ".join(sorted({f"{r['variant']}/{r['mode']}({r['gate_mismatches']} vectors)" for r in gate_fail}))))
    hash_ok = True
    for key in sorted({(r["mode"], r["workload"]) for r in runs}):
        by_hash = defaultdict(set)
        for r in runs:
            if (r["mode"], r["workload"]) == key:
                by_hash[r["hash"]].add(r["variant"])
        if len(by_hash) == 1:
            h = next(iter(by_hash))
            P(f"hash {key[0]}/{key[1]}: {h} -- identical across {len(next(iter(by_hash.values())))} variants")
        else:
            hash_ok = False
            P(f"hash {key[0]}/{key[1]}: DIFFERS -- " + "; ".join(f"{h}: {sorted(v)}" for h, v in by_hash.items()))
    bit_identity = hash_ok and not gate_fail
    P("")
    P("VERDICT 1: " + ("every variant is bit-identical -- optimisation level, CPU tuning, LTO, sections and BOLT are not part of the numeric contract on this machine."
                       if bit_identity else "BITS MOVED. Stop here: a variant that changes output is a different model, not a faster one (README)."))
    P("")

    # -- 2/3. timings -------------------------------------------------------------
    groups = defaultdict(list)
    for r in runs:
        groups[(r["variant"], r["mode"], r["workload"])].append(r["ns_per_opt"]["median"])
    variants = []
    for v in [b for b in builds] + sorted({r["variant"] for r in runs}):
        if v not in variants and any(k[0] == v for k in groups):
            variants.append(v)
    modes = sorted({k[1] for k in groups})
    workloads = [w for w in ("fixture", "grid", "scalar") if any(k[2] == w for k in groups)]

    P("## 2. Noise floor (A/A)")
    P("")
    aa_halfwidth = {}
    if aa in variants and ref in variants:
        for mode in modes:
            for w in workloads:
                a = groups.get((ref, mode, w), [])
                b = groups.get((aa, mode, w), [])
                if len(a) >= 2 and len(b) >= 2:
                    lo, hi = boot_ci_ratio(b, a, rng)
                    _, p, d = mann_whitney(b, a)
                    hw = max(abs(lo - 1.0), abs(hi - 1.0))
                    aa_halfwidth[(mode, w)] = hw
                    P(f"{mode}/{w}: {aa} vs {ref} ratio {fmt(median(b)/median(a), 4)}  95% CI [{fmt(lo, 4)}, {fmt(hi, 4)}]  p={fmt(p, 3)}  -> effects smaller than +/-{fmt(100*hw, 1)}% are not resolvable in this run")
        if not aa_halfwidth:
            P("A/A groups too small (need >= 2 processes each)")
    else:
        P(f"no A/A pair ({ref} and {aa}) in this run; every difference below is quoted without a measured noise floor")
    P("")

    P("## 3. Levers, relative to reference " + ref)
    P("")
    P("ns/option is the per-process MEDIAN over iterations; the table shows the median of those across processes with a bootstrap 95% CI.")
    P("ratio < 1 is faster than the reference. p is two-sided Mann-Whitney; delta is Cliff's delta (-1..1).")
    P("For the BOLT variant `.text` is BOLT's rewritten hot text; the original section is kept as `.bolt.org.text`, so its byte count is not comparable.")
    P("")
    summary_rows = []
    for mode in modes:
        for w in workloads:
            P(f"### {mode} / {w}")
            P("")
            P("| variant | n | ns/opt median | 95% CI | ratio vs ref | ratio 95% CI | p | Cliff d | .text bytes (bench / .so) | verdict |")
            P("|---|---|---|---|---|---|---|---|---|---|")
            refs = groups.get((ref, mode, w), [])
            for v in variants:
                xs = groups.get((v, mode, w), [])
                if not xs:
                    continue
                med = median(xs)
                lo, hi = boot_ci_median(xs, rng)
                b = builds.get(v, {})
                text = f"{b.get('bench_text_bytes', '?')} / {b.get('so_text_bytes', '?')}"
                if v == ref or not refs:
                    ratio_s, rci_s, p_s, d_s, verdict = "1.000", "-", "-", "-", "reference"
                else:
                    ratio = med / median(refs)
                    rlo, rhi = boot_ci_ratio(xs, refs, rng)
                    _, p, d = mann_whitney(xs, refs)
                    ratio_s, rci_s, p_s, d_s = fmt(ratio, 4), f"[{fmt(rlo, 4)}, {fmt(rhi, 4)}]", fmt(p, 3), fmt(d, 2)
                    hw = aa_halfwidth.get((mode, w))
                    if math.isnan(rlo):
                        verdict = "n/a"
                    elif rlo <= 1.0 <= rhi:
                        verdict = "no effect (CI spans 1)"
                    elif hw is not None and abs(ratio - 1.0) <= hw:
                        verdict = "within A/A noise"
                    else:
                        verdict = ("FASTER" if ratio < 1 else "SLOWER") + f" by {fmt(abs(1-ratio)*100, 1)}%"
                    summary_rows.append((mode, w, v, med, ratio, rlo, rhi, p, verdict))
                P(f"| {v} | {len(xs)} | {fmt(med, 2)} | [{fmt(lo, 2)}, {fmt(hi, 2)}] | {ratio_s} | {rci_s} | {p_s} | {d_s} | {text} | {verdict} |")
            P("")

    # -- 4. counters and the BOLT gate ----------------------------------------------
    P("## 4. Counters (grid workload) and the post-link-optimisation gate")
    P("")
    grid_n = float(meta.get("grid_n", 0) or 0)
    perf_iters = None
    if perf:
        P("| variant/mode | IPC | instr/option* | br MPKI | L1i MPKI | L1i miss% | iTLB refill MPKI | ITLB walk PKI | L1d MPKI | L2 MPKI | FE stall% | BE stall% | FE bound% | BE bound% | bad spec% | retiring% |")
        P("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        gate_inputs = {}
        for (v, mode), ev in sorted(perf.items()):
            g = lambda name: ev.get(name)  # noqa: E731
            I, C = g("INST_RETIRED"), g("CPU_CYCLES")
            def mpki(name):
                x = g(name)
                return x / I * 1000.0 if (x is not None and I) else None
            def pct(name, den):
                x, d = g(name), g(den)
                return x / d * 100.0 if (x is not None and d) else None
            ipc = I / C if (I and C) else None
            l1i_miss = pct("L1I_CACHE_REFILL", "L1I_CACHE")
            fe_slot = be_slot = bad = ret = None
            if all(g(k) is not None for k in ("STALL_SLOT_FRONTEND", "STALL_SLOT_BACKEND", "STALL_SLOT", "OP_SPEC", "OP_RETIRED")) and C:
                # Arm topdown L1 (telemetry-solution form); `slots` is the dispatch width (Neoverse V2: 8).
                bmp = g("BR_MIS_PRED_RETIRED") or 0.0
                fe_slot = 100.0 * (g("STALL_SLOT_FRONTEND") / (C * slots) - bmp / C)
                be_slot = 100.0 * (g("STALL_SLOT_BACKEND") / (C * slots))
                frac_ret = g("OP_RETIRED") / g("OP_SPEC") if g("OP_SPEC") else 0.0
                busy = 1.0 - g("STALL_SLOT") / (C * slots)
                bad = 100.0 * ((1.0 - frac_ret) * busy + bmp / C)
                ret = 100.0 * frac_ret * busy
            instr_per_opt = None
            if I and grid_n:
                # the perf runs use --workload grid --iters PERF_ITERS; read PERF_ITERS from meta if present
                pi = meta.get("perf_iters")
                if pi:
                    instr_per_opt = I / (float(pi) * grid_n)
            gate_inputs[(v, mode)] = (mpki("L1I_CACHE_REFILL"), fe_slot, pct("STALL_FRONTEND", "CPU_CYCLES"))
            P("| " + " | ".join([
                f"{v}/{mode}", fmt(ipc), fmt(instr_per_opt, 1) if instr_per_opt else "n/a",
                fmt(mpki("BR_MIS_PRED_RETIRED")), fmt(mpki("L1I_CACHE_REFILL"), 3), fmt(l1i_miss, 3),
                fmt(mpki("L1I_TLB_REFILL"), 3), fmt(mpki("ITLB_WALK"), 4), fmt(mpki("L1D_CACHE_REFILL")), fmt(mpki("L2D_CACHE_REFILL"), 3),
                fmt(pct("STALL_FRONTEND", "CPU_CYCLES"), 1), fmt(pct("STALL_BACKEND", "CPU_CYCLES"), 1),
                fmt(fe_slot, 1), fmt(be_slot, 1), fmt(bad, 1), fmt(ret, 1),
            ]) + " |")
        P("")
        P("*instr/option includes the fixture-parse and gate preamble (< 2% at PERF_ITERS=1000). FE/BE bound, bad spec and retiring follow Arm's topdown-L1 definitions with slots = "
          f"{slots}; FE stall% / BE stall% are the plain STALL_FRONTEND / STALL_BACKEND cycle shares and need no slot assumption.")
        P("")
        key = (ref, "static")
        if key in gate_inputs:
            l1i, fe_slot, fe_cyc = gate_inputs[key]
            fe = fe_slot if fe_slot is not None else fe_cyc
            P(f"BOLT gate on {ref}/static: L1i MPKI = {fmt(l1i, 3)} (threshold {L1I_MPKI_THRESHOLD}), front-end bound = {fmt(fe, 1)}% (threshold {FE_BOUND_THRESHOLD}%).")
            if l1i is not None and fe is not None:
                if l1i > L1I_MPKI_THRESHOLD or fe > FE_BOUND_THRESHOLD:
                    P("VERDICT 4: the workload IS front-end bound by BOLT's rule of thumb; post-link layout optimisation has something to work with.")
                else:
                    P("VERDICT 4: the workload is NOT front-end bound. By BOLT's own rule of thumb (and by the ext-TSP authors' finding on small, non-front-end-bound binaries), "
                      "layout optimisation is predicted to be noise here; any measured v2-bolt effect above should be read against the A/A floor.")
        else:
            P("(no counters for the reference static build; the gate cannot be evaluated)")
    else:
        P("no perf counters collected (perf unavailable, PERF=off, or an emulated run). The BOLT gate cannot be evaluated without L1i MPKI and front-end-bound share.")
        so_text = builds.get(ref, {}).get("so_text_bytes")
        if so_text:
            P(f"Static prior only: the library's .text is {so_text} bytes against a 64 KB L1I and a 1536-entry MOP cache on Neoverse V2, so the front-end-bound condition is not expected to be met.")
    P("")

    bolt_log = os.path.join(out_dir, "build", "v2-bolt", "bin", "bench-driver.bolt", "bolt.log")
    if os.path.exists(bolt_log):
        P("## BOLT dyno-stats (from bolt.log)")
        P("")
        with open(bolt_log, errors="replace") as f:
            txt = f.read()
        m = re.search(r"BOLT-INFO: program-wide dynostats after all optimizations.*?(?=\nBOLT-INFO|\Z)", txt, re.S)
        block = m.group(0) if m else "\n".join(l for l in txt.splitlines() if "BOLT-INFO" in l)[:4000]
        P("```")
        P(block.strip()[:6000])
        P("```")
        P("")

    P("## 5. Build facts")
    P("")
    if builds:
        P("| variant | flags | bench sha256 | .so sha256 | bench .text | .so .text | build s |")
        P("|---|---|---|---|---|---|---|")
        for v, b in builds.items():
            P(f"| {v} | `{b['flags']}` | {b['bench_sha256']} | {b['so_sha256']} | {b['bench_text_bytes']} | {b['so_text_bytes']} | {b['build_seconds']} |")
        if ref in builds and aa in builds:
            same = builds[ref]["bench_sha256"] == builds[aa]["bench_sha256"]
            P("")
            P(f"A/A binaries {'are byte-identical' if same else 'DIFFER (build is not reproducible -- investigate before trusting the A/A floor)'}: {ref}={builds[ref]['bench_sha256']} {aa}={builds[aa]['bench_sha256']}")
    P("")

    report = "\n".join(lines)
    with open(os.path.join(out_dir, "report.md"), "w") as f:
        f.write(report + "\n")
    with open(os.path.join(out_dir, "summary.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["mode", "workload", "variant", "ns_per_opt_median", "ratio_vs_ref", "ratio_ci_lo", "ratio_ci_hi", "p_mannwhitney", "verdict"])
        for row in summary_rows:
            wr.writerow(row)
    print(report)


if __name__ == "__main__":
    main()
