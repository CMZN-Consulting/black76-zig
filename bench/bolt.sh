#!/usr/bin/env bash
# bolt.sh -- post-link optimise a bench binary with LLVM BOLT.
#
#   bench/bolt.sh <input-binary> <output-binary> [instr|perf|spe] [training args...]
#
# The input must have been linked with relocations (`-Demit-relocs=true`) and
# must not be stripped. Three ways to get a profile, in order of preference on
# a Graviton4 box:
#
#   instr   BOLT instruments the binary, the training run writes an .fdata
#           file at exit, BOLT re-optimises from it. Works on any instance
#           size, needs no PMU access, and is the only mode that yields
#           branch-level edge counts on a core without BRBE/LBR. Needs the
#           AArch64 BOLT runtime (libbolt_rt_instr.a) from an aarch64 LLVM.
#   perf    `perf record -e cycles:u` then `perf2bolt -nl` (no branch stack):
#           BOLT infers edge counts from PC samples. The BOLT paper puts the
#           cost of this mode at up to 5% of the LBR result. Needs PMU access
#           (full event set only on *8g.24xlarge and larger).
#   spe     Arm SPE branch records via `perf2bolt --spe` (LLVM >= 21).
#           Graviton4 exposes SPE on METAL instances only.
#
# Output: the optimised binary at <output-binary>, plus <output-binary>.bolt/
# holding the profile, the BOLT log and dyno-stats, which analyze.py reads.

set -euo pipefail

if [ $# -lt 2 ]; then
  sed -n '2,25p' "$0"
  exit 2
fi

in_bin=$(readlink -f "$1")
out_bin="$2"
mode="${3:-instr}"
shift 3 2>/dev/null || shift $#
train_args=("$@")
if [ ${#train_args[@]} -eq 0 ]; then
  train_args=(--workload all --iters 60 --warmup 5 --grid-n 16384)
fi

work="${out_bin}.bolt"
mkdir -p "$work" "$(dirname "$out_bin")"
out_bin=$(readlink -f "$out_bin")

find_tool() {
  # $1 = tool name. Honour $BOLT_BIN_DIR, then PATH, then versioned LLVM dirs.
  if [ -n "${BOLT_BIN_DIR:-}" ] && [ -x "$BOLT_BIN_DIR/$1" ]; then echo "$BOLT_BIN_DIR/$1"; return; fi
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
  for v in 23 22 21 20 19 18; do
    for d in "/usr/lib/llvm-$v/bin" "/usr/local/opt/llvm@$v/bin"; do
      if [ -x "$d/$1" ]; then echo "$d/$1"; return; fi
    done
    if command -v "$1-$v" >/dev/null 2>&1; then command -v "$1-$v"; return; fi
  done
  return 1
}

BOLT=$(find_tool llvm-bolt) || { echo "bolt.sh: llvm-bolt not found (set BOLT_BIN_DIR)"; exit 1; }
BOLT_DIR=$(dirname "$BOLT")
MERGE=$(find_tool merge-fdata) || MERGE="$BOLT_DIR/merge-fdata"
PERF2BOLT=$(find_tool perf2bolt) || PERF2BOLT="$BOLT_DIR/perf2bolt"

echo "bolt.sh: using $BOLT"
"$BOLT" --version 2>/dev/null | head -3 | sed 's/^/  /' || true

# Relocations are not optional: without them BOLT cannot move functions.
if ! readelf -S -W "$in_bin" | grep -q '\.rela\.text'; then
  echo "bolt.sh: $in_bin has no .rela.text -- rebuild with -Demit-relocs=true" >&2
  exit 1
fi

# BOLT's own recommended pass set for layout (the same flags Arm used in its
# AArch64 BOLT write-up), plus dyno-stats so the log carries the before/after
# dynamic instruction and branch counts.
OPT_FLAGS=(
  -reorder-blocks=ext-tsp
  -reorder-functions=hfsort
  -split-functions
  -split-all-cold
  -split-eh
  -dyno-stats
)
if [ -n "${BOLT_EXTRA_FLAGS:-}" ]; then
  # shellcheck disable=SC2206
  OPT_FLAGS+=( $BOLT_EXTRA_FLAGS )
fi

profile="$work/prof.fdata"

case "$mode" in
  instr)
    inst="$work/bench.instrumented"
    rm -f "$work"/prof.fdata*
    echo "bolt.sh: instrumenting -> $inst"
    "$BOLT" "$in_bin" -instrument -o "$inst" \
      --instrumentation-file="$work/prof.fdata" \
      --instrumentation-file-append-pid 2>&1 | tee "$work/instrument.log"
    echo "bolt.sh: training run: $inst ${train_args[*]}"
    "$inst" "${train_args[@]}" > "$work/training.jsonl"
    # One file per pid; merge whatever the training run produced.
    "$MERGE" "$work"/prof.fdata.* > "$profile"
    ;;
  perf)
    echo "bolt.sh: perf record (PC samples, no branch stack)"
    perf record -e cycles:u -F 5000 -o "$work/perf.data" -- "$in_bin" "${train_args[@]}" > "$work/training.jsonl"
    "$PERF2BOLT" -p "$work/perf.data" -o "$profile" -nl "$in_bin" 2>&1 | tee "$work/perf2bolt.log"
    ;;
  spe)
    [ -d /sys/devices/arm_spe_0 ] || { echo "bolt.sh: no arm_spe_0 PMU on this instance (SPE is exposed on Graviton metal instances only)" >&2; exit 1; }
    echo "bolt.sh: perf record via Arm SPE branch records"
    perf record -e 'arm_spe_0/branch_filter=1/u' -o "$work/perf.data" -- "$in_bin" "${train_args[@]}" > "$work/training.jsonl"
    "$PERF2BOLT" --spe -p "$work/perf.data" -o "$profile" "$in_bin" 2>&1 | tee "$work/perf2bolt.log"
    ;;
  *)
    echo "bolt.sh: unknown mode '$mode' (instr|perf|spe)" >&2
    exit 2
    ;;
esac

echo "bolt.sh: profile has $(wc -l < "$profile") lines"
echo "bolt.sh: optimising -> $out_bin"
"$BOLT" "$in_bin" -o "$out_bin" -data="$profile" "${OPT_FLAGS[@]}" 2>&1 | tee "$work/bolt.log"

# Carry the .so next to the binary so `--mode so` still works from the
# variant directory. The library itself is left as built; a BOLT pass over
# the .so is a separate experiment (see bench/README.md).
src_lib="$(dirname "$in_bin")/../lib/libblack76.so"
if [ -f "$src_lib" ]; then
  mkdir -p "$(dirname "$out_bin")/../lib"
  cp -f "$src_lib" "$(dirname "$out_bin")/../lib/libblack76.so"
fi

echo "bolt.sh: done. Log: $work/bolt.log"
