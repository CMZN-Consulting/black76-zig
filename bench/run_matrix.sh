#!/usr/bin/env bash
# run_matrix.sh -- build every whole-binary-optimisation variant of the pricer,
# run the bench driver against each, collect PMU counters, and analyse.
#
#   bench/run_matrix.sh                 # everything, defaults below
#   VARIANTS="v2 v2-lto-full" REPS=5 bench/run_matrix.sh
#
# Designed to be run ON the target (an AWS Graviton4 instance: c8g/m8g/r8g).
# It also works as a cross-compiled smoke test from an x86_64 box with
# TARGET=aarch64-linux-gnu RUNNER=qemu-aarch64 (timings are then meaningless;
# the gate and the hashes are not).
#
# Every knob is an environment variable so a run is reproducible from its
# meta.json. Nothing here needs root except `perf` on a locked-down box.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"

# -- Knobs --------------------------------------------------------------------
ZIG=${ZIG:-zig}
CPU=${CPU:-neoverse_v2}            # -Dcpu for every non-baseline variant
TARGET=${TARGET:-}                 # empty = native. e.g. aarch64-linux-gnu when cross-compiling
RUNNER=${RUNNER:-}                 # e.g. "qemu-aarch64 -L /usr/aarch64-linux-gnu" for cross smoke tests
REPS=${REPS:-10}                   # independent processes per (variant, mode)
ITERS=${ITERS:-300}                # timed iterations per workload per process
WARMUP=${WARMUP:-30}
GRID_N=${GRID_N:-16384}            # 16384 options ~ 1.2 MB of arrays: L2-resident on Neoverse V2 (2 MB)
PIN=${PIN-auto}                    # core to pin to; "auto" = a core away from 0 when there are >= 4; "" = no pinning
MODES=${MODES:-"static so"}
PERF=${PERF:-auto}                 # auto | off
PERF_ITERS=${PERF_ITERS:-1000}     # iterations for the counter runs (preamble becomes < 1%)
PERF_REPS=${PERF_REPS:-3}          # perf stat -r
BOLT_MODE=${BOLT_MODE:-instr}      # instr | perf | spe | off
OUT=${OUT:-"$repo/bench/results/$(date -u +%Y%m%dT%H%M%SZ)"}
ANALYZE=${ANALYZE:-1}

# The matrix. name|optimize|cpu|extra -D flags. One thing changes per row.
#   base          what you get by cross-compiling without thinking: generic aarch64
#   v2            the reference: ReleaseFast, tuned for Neoverse V2
#   v2-aa         identical to v2 (A/A control). The measured "difference"
#                 between v2 and v2-aa is the noise floor of this machine.
#   v2-lto-*      link-time optimisation across the driver/kernel boundary
#   v2-sections   function/data sections + gc-sections (layout / dead code)
#   v2-nofp       omit frame pointers (x29 becomes a general register)
#   v2-small      ReleaseSmall: what does size-first codegen cost on a core
#                 whose L1I already holds the whole kernel ten times over?
#   v2-safe       ReleaseSafe: the price of runtime safety checks (informational)
#   v2-relocs     v2 + --emit-relocs. Should be identical in speed to v2; it
#                 exists to feed BOLT and to prove relocations cost nothing.
#   v2-bolt       v2-relocs after llvm-bolt (built by bench/bolt.sh)
DEFAULT_VARIANTS="base v2 v2-aa v2-lto-full v2-lto-thin v2-sections v2-nofp v2-small v2-safe v2-relocs"
VARIANTS=${VARIANTS:-$DEFAULT_VARIANTS}

variant_flags() {
  case "$1" in
    base)         echo "-Doptimize=ReleaseFast -Dcpu=baseline" ;;
    v2|v2-aa)     echo "-Doptimize=ReleaseFast -Dcpu=$CPU" ;;
    v2-lto-full)  echo "-Doptimize=ReleaseFast -Dcpu=$CPU -Dlto=full" ;;
    v2-lto-thin)  echo "-Doptimize=ReleaseFast -Dcpu=$CPU -Dlto=thin" ;;
    v2-sections)  echo "-Doptimize=ReleaseFast -Dcpu=$CPU -Dsections=true" ;;
    v2-nofp)      echo "-Doptimize=ReleaseFast -Dcpu=$CPU -Domit-frame-pointer=true" ;;
    v2-small)     echo "-Doptimize=ReleaseSmall -Dcpu=$CPU" ;;
    v2-safe)      echo "-Doptimize=ReleaseSafe -Dcpu=$CPU" ;;
    v2-relocs)    echo "-Doptimize=ReleaseFast -Dcpu=$CPU -Demit-relocs=true -Dbench-libc=true" ;;
    *)            echo "run_matrix.sh: unknown variant '$1'" >&2; return 1 ;;
  esac
}

# -- Preflight ------------------------------------------------------------------
mkdir -p "$OUT/build" "$OUT/perf"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/run.log"; }

zig_version=$("$ZIG" version)
if [ "$zig_version" != "0.16.0" ]; then
  log "WARNING: zig $zig_version is not the pinned 0.16.0; the fixture is captured by 0.16.0 and a different compiler is allowed to disagree"
fi

arch=$(uname -m)
if [ -z "$TARGET" ] && [ "$arch" != "aarch64" ]; then
  log "WARNING: native arch is $arch, not aarch64 -- this is a smoke run, not a Graviton measurement"
fi

if [ "$PIN" = "auto" ]; then
  if [ "$(nproc)" -ge 4 ]; then PIN=2; else PIN=""; fi
fi
pin_cmd=()
if [ -n "$PIN" ] && [ -z "$RUNNER" ]; then
  if command -v taskset >/dev/null 2>&1 && taskset -c "$PIN" true 2>/dev/null; then
    pin_cmd=(taskset -c "$PIN")
  else
    log "cannot pin to core $PIN (taskset missing or core absent); running unpinned"
    PIN=""
  fi
fi

perf_ok=0
if [ "$PERF" != "off" ] && [ -z "$RUNNER" ] && command -v perf >/dev/null 2>&1; then
  if perf stat -e cycles -x, -- true >/dev/null 2>"$OUT/perf/probe.err"; then
    perf_ok=1
  else
    log "perf stat is not usable here ($(head -c 200 "$OUT/perf/probe.err" | tr '\n' ' ')); counters skipped. Try: sudo sysctl kernel.perf_event_paranoid=1"
  fi
fi

# Instance metadata (IMDSv2), best effort, 1 s budget.
instance_type="unknown"
if command -v curl >/dev/null 2>&1; then
  tok=$(curl -s -m 1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
  if [ -n "$tok" ]; then
    instance_type=$(curl -s -m 1 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo unknown)
  fi
  # Anything that is not shaped like "c8g.4xlarge" is a proxy/error page, not an instance type.
  [[ "$instance_type" =~ ^[a-z0-9-]+\.[a-z0-9]+$ ]] || instance_type="unknown"
fi

cat > "$OUT/meta.json" <<EOF
{
  "date_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_rev": "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "git_dirty": $(if [ -n "$(git status --porcelain 2>/dev/null)" ]; then echo true; else echo false; fi),
  "zig": "$zig_version",
  "uname": "$(uname -srm)",
  "arch": "$arch",
  "instance_type": "$instance_type",
  "cpu_model": "$(grep -m1 -E 'model name|CPU implementer' /proc/cpuinfo | sed 's/.*: //' || echo unknown)",
  "cpu_part": "$(grep -m1 'CPU part' /proc/cpuinfo | sed 's/.*: //' || echo unknown)",
  "nproc": $(nproc),
  "thp": "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tr -d '\n' || echo unknown)",
  "page_size": $(getconf PAGESIZE),
  "perf": "$(perf --version 2>/dev/null | head -1 || echo none)",
  "perf_event_paranoid": "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)",
  "perf_usable": $perf_ok,
  "target": "${TARGET:-native}",
  "cpu_flag": "$CPU",
  "runner": "$RUNNER",
  "pin": "$PIN",
  "reps": $REPS,
  "iters": $ITERS,
  "warmup": $WARMUP,
  "grid_n": $GRID_N,
  "perf_iters": $PERF_ITERS,
  "perf_reps": $PERF_REPS,
  "modes": "$MODES",
  "variants": "$VARIANTS",
  "bolt_mode": "$BOLT_MODE"
}
EOF
log "results -> $OUT"
log "zig $zig_version | $(uname -srm) | instance $instance_type | perf usable: $perf_ok"

# -- Build ----------------------------------------------------------------------
text_size() { # $1 = ELF path -> bytes in .text (readelf is target-agnostic; size/objdump are not)
  readelf -S -W "$1" 2>/dev/null | python3 -c '
import re, sys
for line in sys.stdin:
    m = re.search(r"\]\s+\.text\s+\S+\s+[0-9a-f]+\s+[0-9a-f]+\s+([0-9a-f]+)", line)
    if m:
        print(int(m.group(1), 16)); break
else:
    print(0)'
}

: > "$OUT/builds.tsv"
echo -e "variant\tflags\tbench_sha256\tso_sha256\tbench_text_bytes\tso_text_bytes\tbuild_seconds" >> "$OUT/builds.tsv"

build_variant() {
  local v=$1 flags prefix t0 t1
  flags=$(variant_flags "$v")
  prefix="$OUT/build/$v"
  t0=$(date +%s%N)
  # shellcheck disable=SC2086
  "$ZIG" build bench-driver $flags ${TARGET:+-Dtarget=$TARGET} --prefix "$prefix" 2>&1 | tee -a "$OUT/run.log" >/dev/null
  t1=$(date +%s%N)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$flags" \
    "$(sha256sum "$prefix/bin/bench-driver" | cut -c1-16)" "$(sha256sum "$prefix/lib/libblack76.so" | cut -c1-16)" \
    "$(text_size "$prefix/bin/bench-driver")" "$(text_size "$prefix/lib/libblack76.so")" \
    "$(awk "BEGIN{printf \"%.1f\", ($t1-$t0)/1e9}")" >> "$OUT/builds.tsv"
  log "built $v  ($flags)"
}

for v in $VARIANTS; do build_variant "$v"; done

# -- BOLT -----------------------------------------------------------------------
run_list="$VARIANTS"
if [ "$BOLT_MODE" != "off" ] && [[ " $VARIANTS " == *" v2-relocs "* ]]; then
  if [ -n "$RUNNER" ]; then
    log "BOLT skipped: cannot instrument/train under an emulator runner"
  elif bash bench/bolt.sh "$OUT/build/v2-relocs/bin/bench-driver" "$OUT/build/v2-bolt/bin/bench-driver" "$BOLT_MODE" \
        --workload all --iters 60 --warmup 5 --grid-n "$GRID_N" >> "$OUT/run.log" 2>&1; then
    run_list="$run_list v2-bolt"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "v2-bolt" "bolt.sh $BOLT_MODE on v2-relocs" \
      "$(sha256sum "$OUT/build/v2-bolt/bin/bench-driver" | cut -c1-16)" "$(sha256sum "$OUT/build/v2-bolt/lib/libblack76.so" | cut -c1-16)" \
      "$(text_size "$OUT/build/v2-bolt/bin/bench-driver")" "$(text_size "$OUT/build/v2-bolt/lib/libblack76.so")" "0" >> "$OUT/builds.tsv"
    log "built v2-bolt (mode $BOLT_MODE)"
  else
    log "BOLT step failed -- see $OUT/run.log (llvm-bolt missing? no aarch64 runtime? no PMU?)"
  fi
fi

# -- Timed runs ------------------------------------------------------------------
# Interleaved: rep-major order with a rotating start, so slow drift (thermal,
# a neighbour tenant, a cron job) is spread across variants instead of
# landing on whichever one happened to run last.
runs="$OUT/runs.jsonl"
: > "$runs"
read -r -a vlist <<< "$run_list"
nv=${#vlist[@]}
for rep in $(seq 1 "$REPS"); do
  for ((j = 0; j < nv; j++)); do
    v=${vlist[$(( (j + rep) % nv ))]}
    for mode in $MODES; do
      so_args=()
      [ "$mode" = "so" ] && so_args=(--so "$OUT/build/$v/lib/libblack76.so")
      # shellcheck disable=SC2086
      ${RUNNER} "${pin_cmd[@]}" "$OUT/build/$v/bin/bench-driver" --name "$v" --mode "$mode" "${so_args[@]}" \
        --iters "$ITERS" --warmup "$WARMUP" --grid-n "$GRID_N" >> "$runs" \
        || log "GATE/RUN FAILURE: variant=$v mode=$mode rep=$rep (exit $?) -- see runs.jsonl"
    done
  done
  log "rep $rep/$REPS done"
done

# -- Counters ----------------------------------------------------------------------
# Raw Arm PMU common-event numbers (Arm ARM, Neoverse V2 PMU guide), grouped
# five-plus-cycles per pass so nothing is multiplexed. Names via perf's
# vendor JSON are not relied on: raw codes work on any perf build.
#   0x08 INST_RETIRED  0x11 CPU_CYCLES  0x21 BR_RETIRED  0x22 BR_MIS_PRED_RETIRED
#   0x23 STALL_FRONTEND  0x24 STALL_BACKEND  0x14 L1I_CACHE  0x01 L1I_CACHE_REFILL
#   0x02 L1I_TLB_REFILL  0x35 ITLB_WALK  0x04 L1D_CACHE  0x03 L1D_CACHE_REFILL
#   0x16 L2D_CACHE  0x17 L2D_CACHE_REFILL  0x34 DTLB_WALK  0x3b OP_SPEC
#   0x3a OP_RETIRED  0x3e STALL_SLOT_FRONTEND  0x3d STALL_SLOT_BACKEND  0x3f STALL_SLOT
if [ "$perf_ok" = 1 ]; then
  if [ "$arch" = "aarch64" ]; then
    groups=(
      "core:r08,r11,r21,r22,r23,r24"
      "ifetch:r08,r14,r01,r02,r35,r03"
      "slots:r11,r3b,r3a,r3e,r3d,r3f"
      "mem:r08,r04,r03,r16,r17,r34"
    )
  else
    groups=("generic:cycles,instructions,branches,branch-misses,L1-icache-load-misses,iTLB-load-misses")
  fi
  for v in $run_list; do
    for mode in $MODES; do
      so_args=()
      [ "$mode" = "so" ] && so_args=(--so "$OUT/build/$v/lib/libblack76.so")
      for g in "${groups[@]}"; do
        gname=${g%%:*}; events=${g#*:}
        perf stat -x, -r "$PERF_REPS" -e "$events" -o "$OUT/perf/${v}_${mode}_${gname}.csv" -- \
          "${pin_cmd[@]}" "$OUT/build/$v/bin/bench-driver" --name "$v" --mode "$mode" "${so_args[@]}" \
          --workload grid --iters "$PERF_ITERS" --warmup "$WARMUP" --grid-n "$GRID_N" > /dev/null \
          || log "perf stat failed for $v/$mode/$gname"
      done
    done
    log "counters $v done"
  done
fi

# -- Analyse ---------------------------------------------------------------------------
if [ "$ANALYZE" = 1 ]; then
  python3 bench/analyze.py "$OUT" | tee "$OUT/report.txt"
fi
log "done: $OUT"
