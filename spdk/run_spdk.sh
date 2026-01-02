#!/usr/bin/env bash
set -euo pipefail

SPDK_DIR="${SPDK_DIR:-$(pwd)//tools/spdk}"
SPDK_BIN="$SPDK_DIR/build/bin/spdk_nvme_perf"

HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../results"; mkdir -p "$RES"

msg(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
die(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }
ts(){ date +%Y%m%d-%H%M%S; }

# ---------- helpers ----------
ensure_hugepages(){
  sudo sysctl -w vm.nr_hugepages="${1:-1024}" >/dev/null
  sudo mkdir -p /dev/hugepages
  mount | grep -q hugetlbfs || sudo mount -t hugetlbfs nodev /dev/hugepages
}
has_iommu(){ [ -d /sys/kernel/iommu_groups ] && [ "$(ls /sys/kernel/iommu_groups | wc -l)" -gt 0 ]; }
passthrough_on(){ grep -qw 'iommu.passthrough=1' /proc/cmdline; }

bdf_from_dev(){
  local dev="$1" base link
  base="$(basename "$dev")" || return 1
  link="$(readlink -f "/sys/class/block/$base/device/device" 2>/dev/null || true)" || true
  [ -n "$link" ] || return 1
  basename "$link"
}

# minimal safety: system controllers (/, /boot, /boot/efi, swap)
system_bdfs(){
  {
    findmnt -nro SOURCE /;
    findmnt -nro SOURCE /boot 2>/dev/null || true;
    findmnt -nro SOURCE /boot/efi 2>/dev/null || true;
    awk '$1 ~ /^\/dev\//{print $1}' /proc/swaps 2>/dev/null || true;
  } | awk '/^\/dev\//{print $1}' | while read -r src; do
       name="$(basename "$(lsblk -no PKNAME "$src" 2>/dev/null || echo "$src")")"
       link="$(readlink -f "/sys/class/block/$name/device/device" 2>/dev/null || true)"
       [ -n "$link" ] && basename "$link"
     done | sort -u
}
is_system_bdf(){ local b="$1"; system_bdfs | grep -Fxq "$b"; }

dev_has_mounts(){
  local dev="$1"
  [ -b "$dev" ] || return 1
  lsblk -rno NAME,MOUNTPOINT "$dev" 2>/dev/null | awk 'NR>1 && $2!="" {print; exit 0}' | grep -q .
}

# reliable bind using driver_override
_bind_to(){
  local bdf="$1" drv="$2"
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/nvme/unbind            >/dev/null 2>&1 || true
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/uio_pci_generic/unbind  >/dev/null 2>&1 || true
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind         >/dev/null 2>&1 || true

  case "$drv" in
    uio)
      sudo modprobe uio_pci_generic
      echo uio_pci_generic | sudo tee /sys/bus/pci/devices/$bdf/driver_override >/dev/null
      echo "$bdf" | sudo tee /sys/bus/pci/drivers/uio_pci_generic/bind >/dev/null
      ;;
    nvme)
      sudo modprobe nvme
      echo "" | sudo tee /sys/bus/pci/devices/$bdf/driver_override >/dev/null
      echo "$bdf" | sudo tee /sys/bus/pci/drivers/nvme/bind >/dev/null
      ;;
    *) die "bind_to: driver must be uio or nvme";;
  esac

  # verify
  local drvlink
  drvlink="$(readlink -f /sys/bus/pci/devices/$bdf/driver 2>/dev/null || true)"
  [[ "$drvlink" == *"/$drv" ]] || die "Failed to bind $bdf to $drv"
}

bind_to(){
  local bdf="$1" drv="$2"
  local want="$drv"
  [ "$drv" = "uio" ] && want="uio_pci_generic"

  # If already bound as desired, do nothing
  local cur
  cur="$(readlink -f /sys/bus/pci/devices/$bdf/driver 2>/dev/null || true)"
  if [[ "$cur" == */"$want" ]]; then
    msg "Already bound: $bdf -> $want"
    return 0
  fi

  # Best-effort unbind from anything else
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/nvme/unbind            >/dev/null 2>&1 || true
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/uio_pci_generic/unbind  >/dev/null 2>&1 || true
  echo "$bdf" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind         >/dev/null 2>&1 || true

  # Ensure sysfs node exists; rescan if needed
  if [ ! -e "/sys/bus/pci/devices/$bdf" ]; then
    warn "$bdf not in sysfs; rescanning PCI"
    echo 1 | sudo tee /sys/bus/pci/rescan >/dev/null || true
    sleep 1
  fi

  # Use driver_override + drivers_probe (more reliable)
  case "$drv" in
    uio)
      sudo modprobe uio_pci_generic
      echo uio_pci_generic | sudo tee /sys/bus/pci/devices/$bdf/driver_override >/dev/null
      echo "$bdf" | sudo tee /sys/bus/pci/drivers_probe >/dev/null 2>&1 || true
      ;;
    nvme)
      sudo modprobe nvme
      echo "" | sudo tee /sys/bus/pci/devices/$bdf/driver_override >/dev/null
      echo "$bdf" | sudo tee /sys/bus/pci/drivers_probe >/dev/null 2>&1 || true
      ;;
    *) die "bind_to: driver must be uio or nvme";;
  esac

  # Verify final state (accept “already bound” too)
  cur="$(readlink -f /sys/bus/pci/devices/$bdf/driver 2>/dev/null || true)"
  if [[ "$cur" != */"$want" ]]; then
    warn "Bind $bdf -> $want failed; current driver: ${cur:-<none>}"
    dmesg | tail -n 40 >&2
    die "Failed to bind $bdf to $want"
  fi
}

usage(){
cat <<'EOF'
Usage:
  run_sdpk.sh info
  run_sdpk.sh list
  run_sdpk.sh perf [--bdf 0000:BB:DD.F | --dev /dev/nvmeXnY]
                      [--rw read|write|randread|randwrite|randrw]
                      [--qd 32] [--iosize 131072] [--time 60] [--loops 1]
                      [--out DIR]
                      [--force-system]      # allow OS controller (not recommended)
                      [--allow-mounted]     # allow mounted namespace (not recommended)

Notes:
  - Requires SPDK built at $SPDK_DIR (binary: $SPDK_BIN).
  - perf temporarily binds controller to uio_pci_generic, runs, then binds back to nvme.
EOF
}

cmd="${1:-}"; shift || true
[ -n "$cmd" ] || { usage; exit 0; }

case "$cmd" in
  info)
    [ -x "$SPDK_BIN" ] || warn "SPDK binary not found: $SPDK_BIN"
    msg "SPDK bin: ${SPDK_BIN:-<missing>}"
    if has_iommu; then msg "IOMMU groups: present"; else warn "IOMMU groups: not present"; fi
    if passthrough_on; then warn "iommu.passthrough=1 is set"; else msg "iommu.passthrough=1 not set"; fi
    grep -E 'HugePages_Total|HugePages_Free' /proc/meminfo || true
    echo "Controllers:"
    for d in /sys/class/nvme/nvme*; do
      [ -e "$d" ] || continue
      ctrl="$(basename "$d")"
      bdf="$(basename "$(readlink -f "$d/device")")"
      drv="$(readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || echo "<none>")"
      printf "  %-10s %-12s driver=%s\n" "$ctrl" "$bdf" "$(basename "$drv")"
    done
    ;;

  list)
    printf "%-14s %-12s %s\n" "BDF" "CTRL" "Namespaces"
    # gather ns into array for lsblk
    ns_all=()
    for d in /sys/class/nvme/nvme*; do
      [ -e "$d" ] || continue
      ctrl="$(basename "$d")"
      bdf="$(basename "$(readlink -f "$d/device")")"
      nslist="$(ls "$d" 2>/dev/null | grep -E '^nvme[0-9]+n[0-9]+$' | xargs -r printf "/dev/%s ")"
      printf "%-14s %-12s %s\n" "$bdf" "/dev/$ctrl" "$nslist"
      if [ -n "$nslist" ]; then
        # shellcheck disable=SC2206
        ns_all+=($nslist)
      fi
    done
    if [ "${#ns_all[@]}" -gt 0 ]; then
      echo
      echo "lsblk (filtered to discovered namespaces):"
      lsblk --paths -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL "${ns_all[@]}" 2>/dev/null || true
    fi
    ;;

  perf)
    local_bdf=""; local_dev=""
    rw="read"; qd=32; ios=131072; secs=60; loops=1; out=""
    force_system=0; allow_mounted=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --bdf) local_bdf="$2"; shift 2;;
        --dev) local_dev="$2"; shift 2;;
        --rw) rw="$2"; shift 2;;
        --qd) qd="$2"; shift 2;;
        --iosize) ios="$2"; shift 2;;
        --time) secs="$2"; shift 2;;
        --loops) loops="$2"; shift 2;;
        --out) out="$2"; shift 2;;
        --force-system) force_system=1; shift;;
        --allow-mounted) allow_mounted=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1";;
      esac
    done
    [ -x "$SPDK_BIN" ] || die "SPDK binary not found: $SPDK_BIN"

    # resolve BDF
    if [ -z "$local_bdf" ]; then
      [ -n "$local_dev" ] || die "Provide --bdf or --dev"
      if [ -b "$local_dev" ]; then
        local_bdf="$(bdf_from_dev "$local_dev")" || die "Cannot resolve BDF from $local_dev"
      else
        # try derive via controller name (nvmeXnY -> nvmeX), still works if node missing
        ctrl="$(basename "$local_dev" | sed -n 's/^\(nvme[0-9]\+\)n[0-9]\+$/\1/p')"
        [ -n "$ctrl" ] || die "Not a block device: $local_dev (and cannot derive controller)"
        [ -e "/sys/class/nvme/$ctrl/device" ] || die "Controller sysfs missing; pass --bdf"
        local_bdf="$(basename "$(readlink -f "/sys/class/nvme/$ctrl/device")")"
      fi
    fi

    # safety
    if [ "$force_system" -ne 1 ] && is_system_bdf "$local_bdf"; then
      die "Refusing to run on system controller $local_bdf (use --force-system to override)"
    fi
    if [ -n "${local_dev:-}" ] && [ -b "${local_dev:-/nope}" ] && dev_has_mounts "$local_dev" && [ "$allow_mounted" -ne 1 ]; then
      die "Refusing to run on mounted device $local_dev (use --allow-mounted to override)"
    fi

    ensure_hugepages 1024

    tag="${local_bdf//[:.]/_}"
    dir="${out:-$RES/spdk-perf-${tag}-rw${rw}-qd${qd}-o${ios}-$(ts)}"
    mkdir -p "$dir"

    msg "Binding $local_bdf -> uio_pci_generic"
    bind_to "$local_bdf" uio

    # Detect a latency flag supported by this spdk_nvme_perf
    LAT_FLAG=""
    if "$SPDK_BIN" -h 2>&1 | grep -qE '(^| )-l( |,|$).*latency'; then
      LAT_FLAG="-l"                               # common
    elif "$SPDK_BIN" -h 2>&1 | grep -q -- '--latency-stats'; then
      LAT_FLAG="--latency-stats"                  # some versions
    elif "$SPDK_BIN" -h 2>&1 | grep -q -- '--latency'; then
      LAT_FLAG="--latency"                        # older alt
    elif "$SPDK_BIN" -h 2>&1 | grep -qE '(^| )-H( |,|$).*latency'; then
      LAT_FLAG="-H"                               # sometimes prints histogram
    fi
    [ -n "$LAT_FLAG" ] || warn "Latency percentiles not supported by this spdk_nvme_perf (no -l/--latency* flag found)"

    for i in $(seq 1 "$loops"); do
      msg "Run $i/$loops: $SPDK_BIN $LAT_FLAG -q $qd -o $ios -w $rw -t $secs -r 'trtype=PCIe traddr=$local_bdf'"
      "$SPDK_BIN" --iova-mode=pa $LAT_FLAG -q "$qd" -o "$ios" -w "$rw" -t "$secs" \
        -r "trtype=PCIe traddr=${local_bdf}" >> "$dir/spdk-perf.txt" 2>&1 || true
    done

    msg "Binding $local_bdf -> nvme (restore)"
    bind_to "$local_bdf" nvme
    for c in /dev/nvme*; do [ -e "$c" ] && /usr/sbin/nvme ns-rescan "$c" >/dev/null 2>&1 || true; done

    msg "Done -> $dir"
    ;;

  ""|-h|--help) usage ;;
  *) die "Unknown command: $cmd (use --help)" ;;
esac

