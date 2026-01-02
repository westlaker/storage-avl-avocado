#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
msg()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[1;31m[ERR]\033[0m %s\n"  "$*" >&2; exit 1; }
timestamp() { date +%Y%m%d-%H%M%S; }
have() { command -v "$1" >/dev/null 2>&1; }
ensure_outdir() { mkdir -p "$1"; }
ensure_hugepages() { local num="${1:-1024}"; sudo sysctl -w vm.nr_hugepages="$num" >/dev/null; sudo mkdir -p /dev/hugepages; mount | grep -q hugetlbfs || sudo mount -t hugetlbfs nodev /dev/hugepages; }
has_iommu() { [ -d /sys/kernel/iommu_groups ] && [ "$(ls /sys/kernel/iommu_groups | wc -l)" -gt 0 ]; }
passthrough_on() { grep -qw 'iommu.passthrough=1' /proc/cmdline; }
run_text_safely() { local out="$1"; shift; : >"$out.err" 2>/dev/null || true; { set +e; "$@" >"$out" 2>>"$out.err"; local rc=$?; set -e; } 2>>"$out.err"; return "$rc"; }
DPDK_MODE="system"
SPDK_DIR="$ROOT/tools/spdk"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dpdk) DPDK_MODE="$2"; shift 2;;
    --spdk-dir) SPDK_DIR="$2"; shift 2;;
    *) die "Unknown option: $1";;
  esac
done
sudo apt-get update
sudo apt-get install -y git build-essential meson ninja-build pkg-config   python3 python3-pip python3-pyelftools libnuma-dev libaio-dev liburing-dev   libibverbs-dev librdmacm-dev libssl-dev libjansson-dev
if [ ! -d "$SPDK_DIR" ]; then
  ensure_outdir "$(dirname "$SPDK_DIR")"
  git clone https://github.com/spdk/spdk.git "$SPDK_DIR"
fi
( cd "$SPDK_DIR" && git submodule update --init --recursive )
if [ "$DPDK_MODE" = "system" ]; then
  msg "Using system DPDK"
  sudo apt-get install -y libdpdk-dev dpdk
  ( cd "$SPDK_DIR"; ./configure; make -j"$(nproc)" )
else
  msg "Building bundled DPDK (minimal)"
  DPDK_SRC="$SPDK_DIR/dpdk"
  INSTALL_PREFIX="$(cd "$DPDK_SRC" && pwd)/_install"
  ( cd "$DPDK_SRC"
    rm -rf build "$INSTALL_PREFIX"
    meson setup build --prefix="$INSTALL_PREFIX" --buildtype=release       -Dtests=false -Denable_docs=false -Dplatform=generic       -Ddisable_drivers='baseband/*,power/*,crypto/*,compress/*,event/*,regex/*,raw/*,vdpa/*,vhost/*,net/*'
    ninja -C build
    ninja -C build install
  )
  ( cd "$SPDK_DIR"; ./configure --with-dpdk="$INSTALL_PREFIX"; make -j"$(nproc)" )
fi
[ -x "$SPDK_DIR/build/bin/spdk_nvme_perf" ] || die "SPDK build failed (spdk_nvme_perf missing)"
msg "SPDK ready: $SPDK_DIR/build/bin/spdk_nvme_perf"
