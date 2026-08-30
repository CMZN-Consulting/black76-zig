#!/usr/bin/env bash
# setup_graviton.sh -- install what run_matrix.sh needs on a fresh Graviton box.
#
#   bash bench/setup_graviton.sh            # Ubuntu 22.04/24.04 or Amazon Linux 2023, aarch64
#
# Installs: Zig 0.16.0 (the pinned toolchain, into ~/zig), perf, python3,
# util-linux (taskset), binutils (readelf), and LLVM BOLT 21 where a package
# exists (Ubuntu via apt.llvm.org). Nothing is installed system-wide except
# distro packages; Zig lives in $HOME/zig and is added to PATH via ~/.profile.
#
# LLVM >= 21 matters only for `perf2bolt --spe` (SPE profiles, metal instances).
# Instrumentation mode (the default) works with any BOLT that ships the
# AArch64 runtime, libbolt_rt_instr.a, which the distro bolt packages do.

set -euo pipefail

ZIG_VERSION=0.16.0
arch=$(uname -m)
if [ "$arch" != "aarch64" ]; then
  echo "setup_graviton.sh: this is $arch, not aarch64. Nothing to do (cross builds only need Zig)." >&2
fi

# -- Zig -------------------------------------------------------------------------
if ! command -v zig >/dev/null 2>&1 || [ "$(zig version)" != "$ZIG_VERSION" ]; then
  echo "installing zig $ZIG_VERSION into $HOME/zig"
  url="https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/zig.tar.xz"
  rm -rf "$HOME/zig" && mkdir -p "$HOME/zig"
  tar -xJf "$tmp/zig.tar.xz" -C "$HOME/zig" --strip-components=1
  rm -rf "$tmp"
  grep -q 'HOME/zig' "$HOME/.profile" 2>/dev/null || echo 'export PATH="$HOME/zig:$PATH"' >> "$HOME/.profile"
  export PATH="$HOME/zig:$PATH"
fi
echo "zig: $(zig version)"

# -- Distro packages ---------------------------------------------------------------------
if [ -f /etc/os-release ]; then . /etc/os-release; fi
case "${ID:-}" in
  ubuntu|debian)
    sudo apt-get update -q
    sudo apt-get install -y -q python3 util-linux binutils curl gnupg lsb-release "linux-tools-$(uname -r)" linux-tools-common || \
      sudo apt-get install -y -q python3 util-linux binutils curl gnupg lsb-release linux-tools-generic
    # LLVM BOLT from apt.llvm.org (has arm64 packages). 21 for --spe; fall back to whatever exists.
    if ! command -v llvm-bolt >/dev/null 2>&1 && [ ! -x /usr/lib/llvm-21/bin/llvm-bolt ]; then
      tmp=$(mktemp -d)
      curl -fsSL https://apt.llvm.org/llvm.sh -o "$tmp/llvm.sh"
      if sudo bash "$tmp/llvm.sh" 21 >/dev/null 2>&1 && sudo apt-get install -y -q bolt-21; then
        echo "bolt: $(/usr/lib/llvm-21/bin/llvm-bolt --version | head -1)"
      else
        echo "apt.llvm.org install of bolt-21 failed; trying the distro's bolt package"
        sudo apt-get install -y -q bolt-18 || sudo apt-get install -y -q bolt-19 || echo "no bolt package; BOLT_MODE=off or build LLVM with -DLLVM_ENABLE_PROJECTS=bolt"
      fi
      rm -rf "$tmp"
    fi
    ;;
  amzn)
    sudo dnf install -y -q python3 util-linux binutils perf curl
    echo "Amazon Linux 2023 ships no BOLT package. Either run with BOLT_MODE=off, or build LLVM with"
    echo "  cmake -S llvm -B build -G Ninja -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_TARGETS_TO_BUILD=AArch64 -DCMAKE_BUILD_TYPE=Release"
    echo "and point BOLT_BIN_DIR at build/bin."
    ;;
  *)
    echo "unknown distro '${ID:-}': install perf, python3, taskset, readelf and llvm-bolt by hand"
    ;;
esac

# -- PMU access --------------------------------------------------------------------------------
para=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)
echo "perf_event_paranoid=$para (needs <= 1 for perf stat/record as a user; 'sudo sysctl kernel.perf_event_paranoid=1')"
if [ -d /sys/devices/arm_spe_0 ]; then
  echo "Arm SPE PMU present (metal instance): BOLT_MODE=spe is available"
else
  echo "no arm_spe_0 PMU: this is a virtualised instance; use BOLT_MODE=instr (default) or perf"
fi
if ls /sys/bus/event_source/devices/ 2>/dev/null | grep -q armv8_pmuv3; then
  echo "armv8 PMU present"
else
  echo "WARNING: no armv8 PMU device visible; perf counters will be <not supported>"
fi
echo "done. Now: bench/run_matrix.sh"
