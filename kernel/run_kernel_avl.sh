#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../results"; mkdir -p "$RES"
msg(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }
ts(){ date +%Y%m%d-%H%M%S; }
is_block(){ [ -b "$1" ]; }
is_dev(){ [ -b "$1" ] || [ -c "$1" ]; }
mounted(){ findmnt -n "$1" >/dev/null 2>&1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }
need nvme; need smartctl; need fio
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

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

get_ctrl() {
  local d="$1" b p name i=0
  b="$(basename -- "$d")" || return 1
  p="$(readlink -f "/sys/class/block/$b" 2>/dev/null)" || return 1
  if [[ "$b" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then p="$(dirname "$p")"; fi
  while [ $i -lt 8 ] && [ -n "$p" ] && [ "$p" != "/" ]; do
    name="$(basename -- "$p")"
    if [[ "$name" =~ ^nvme[0-9]+$ ]]; then echo "/dev/$name"; return 0; fi
    p="$(dirname -- "$p")"; i=$((i+1))
  done
  return 1
}
require_block_ns() { local dev="$1"; [ -n "$dev" ] || die "--dev required"; [ -b "$dev" ] || die "Not a block device: $dev"; [[ "$(basename "$dev")" =~ ^nvme[0-9]+n[0-9]+ ]] || die "Pass a namespace node (e.g., /dev/nvme2n1)"; }
csv_header() { local f="$1"; shift; [ -f "$f" ] || printf "%s\n" "$*" > "$f"; }
csv_row()    { printf "%s\n" "$*" >> "$1"; }
fio_txt_to_csv() {
  awk -v job="$2" -v rw="$3" -v bs="$4" -v iodepth="$5" -v nj="$6" -v csv="$7" '
    BEGIN{bwMB=""; iops=""; lat=""; lp99=""; scale=1; OFS=","}
    /READ:|WRITE:/ {
      if (match($0, /BW=([0-9.]+)([KMG]?i?B)\/s/, m)) {
        val=m[1]+0; unit=m[2];
        if (unit ~ /^KiB/) bwMB=val/1024; else if (unit ~ /^MiB/) bwMB=val; else if (unit ~ /^GiB/) bwMB=val*1024;
        else if (unit ~ /^KB/)  bwMB=val/1024; else if (unit ~ /^MB/)  bwMB=val; else if (unit ~ /^GB/)  bwMB=val*1024;
      }
      if (match($0, /IOPS=([0-9.]+)/, m)) iops=m[1]+0;
    }
    /clat \(/ { if ($3 ~ /nsec/) scale=1e6; else if ($3 ~ /usec/) scale=1e3; else scale=1; }
    /avg=/     { if (match($0, /avg= *([0-9.]+)/, m)) { val=m[1]+0; lat=(scale>0)?(val/scale):val; } }
    / 99.00th=/ { if (match($0, /99.00th= *([0-9.]+)/, m)) { v=m[1]+0; lp99=(scale>0)?(v/scale):v; } }
    END{ print job,rw,bs,iodepth,nj,bwMB,iops,lat,lp99 >> csv }
  ' "$1"
}

ctrl_of_ns(){
  local dev="$1"; local base; base="$(basename "$dev")"
  if [[ "$base" =~ ^nvme([0-9]+)n[0-9]+$ ]]; then echo "/dev/nvme${BASH_REMATCH[1]}"; return 0; fi
  local sysdev="/sys/class/block/$base/device"
  if [ -e "$sysdev" ]; then
    local ctrl_dir; ctrl_dir="$(readlink -f "$sysdev"/../ 2>/dev/null || true)"
    local ctrl_base; ctrl_base="$(basename "$ctrl_dir")"
    if [ -b "/dev/$ctrl_base" ] || [ -c "/dev/$ctrl_base" ]; then echo "/dev/$ctrl_base"; return 0; fi
  fi
  echo "$dev"
}

smart_txt_to_csv() {
  awk -v ctrl="$2" '
    BEGIN{FS=":"; OFS=","; cw=t=spare=me=ne=poh=pc=us=dur=duw=""}
    /^critical_warning/        {cw=$2+0}
    /^temperature/             {
      if (match($0, /([0-9]+)[[:space:]]*C/, m)) t=m[1]+0;
      else { gsub(/[^0-9]/,"",$2); if ($2!="") t=int($2/1000)+0; }
    }
    /^available_spare[[:space:]]/ {spare=$2+0}
    /^media_errors/            {me=$2+0}
    /^num_err_log_entries/     {ne=$2+0}
    /^power_on_hours/          {poh=$2+0}
    /^power_cycles/            {pc=$2+0}
    /^unsafe_shutdowns/        {us=$2+0}
    /^data_units_read/         {gsub(/[^0-9]/,"",$2); dur=$2+0}
    /^data_units_written/      {gsub(/[^0-9]/,"",$2); duw=$2+0}
    END{ print ctrl,cw,t,spare,me,ne,poh,pc,us,dur,duw >> "'"$3"'" }
  ' "$1"
}
lsblk_slice(){ lsblk -o NAME,MAJ:MIN,SIZE,ROTA,MODEL,SERIAL,MOUNTPOINT | egrep '(^NAME|^nvme|^└─nvme|^├─nvme)'; }

nvme_safe(){
  local out="$1" errf="$2"; shift 2
  : >"$out" 2>/dev/null || true; : >"$errf" 2>/dev/null || true
  local rc=0
  if [ -n "$SUDO" ]; then
    set +e; $SUDO "$@" >"$out" 2>"$errf"; rc=$?; set -e
    if [ $rc -ne 0 ]; then set +e; "$@" >>"$out" 2>>"$errf"; rc=$?; set -e; fi
  else
    set +e; "$@" >"$out" 2>"$errf"; rc=$?; set -e
  fi
  if [ $rc -ne 0 ]; then warn "nvme command failed (rc=$rc): $*"; return 1; fi
  return 0
}

dump_sysfs_ident(){
  local dev="$1" outdir="$2"
  local nsbase ctrl ctrlname sys_ctrl sys_ns
  nsbase="$(basename "$dev")"; ctrl="$(ctrl_of_ns "$dev")"; ctrlname="$(basename "$ctrl")"
  sys_ctrl="/sys/class/nvme/${ctrlname}"; sys_ns="/sys/class/nvme/${ctrlname}/${nsbase}"
  {
    echo "# Fallback identify from sysfs"
    echo "# controller: $sys_ctrl"
    [ -d "$sys_ctrl" ] && find "$sys_ctrl" -maxdepth 1 -type f -printf "%f: " -exec cat {} \; 2>/dev/null
    echo; echo "# namespace: $sys_ns"
    [ -d "$sys_ns" ] && find "$sys_ns" -maxdepth 1 -type f -printf "%f: " -exec cat {} \; 2>/dev/null
  } > "$outdir/sysfs-ident.txt" 2>/dev/null || true
}

sub_list(){ local out="$RES/list-$(ts)"; mkdir -p "$out"
  msg "lspci:"
  lspci -nn | egrep -i 'non-volatile|nvme' 
  msg "lsblk:"
  lsblk_slice
  msg "nvme list:"
  nvme list
  lspci -nn | egrep -i 'non-volatile|nvme' || true > "$out/lspci.txt"
  lsblk_slice > "$out/lsblk.txt"
  nvme list > "$out/nvme_list.txt" 2>&1 || true
  msg "Results -> $out"; }

sub_identify(){ local dev="" out=""
  while [[ $# -gt 0 ]]; do case "$1" in --dev) dev="$2"; shift 2;; --out) out="$2"; shift 2;; *) die "Unknown option: $1";; esac; done
  [ -n "$dev" ] || die "--dev required"; is_block "$dev" || die "Not a block device: $dev"
  out="${out:-$RES/identify-$(basename "$dev")-$(ts)}"; mkdir -p "$out"
  local ctrl; ctrl="$(ctrl_of_ns "$dev")"
  if ! is_dev "$ctrl"; then warn "Derived controller '$ctrl' is not a controller device; attempting sysfs fallback"; dump_sysfs_ident "$dev" "$out"
  else nvme_safe "$out/id-ctrl.txt" "$out/id-ctrl.err" nvme id-ctrl "$ctrl" || dump_sysfs_ident "$dev" "$out"
       nvme_safe "$out/id-ns.txt"   "$out/id-ns.err"   nvme id-ns "$dev"    || true; fi
  nvme_safe "$out/nvme-list.txt" "$out/nvme-list.err" nvme list -v || true
  msg "Results -> $out"; }

_sub_health(){ local dev="" out=""
  while [[ $# -gt 0 ]]; do case "$1" in --dev) dev="$2"; shift 2;; --out) out="$2"; shift 2;; *) die "Unknown option: $1";; esac; done
  [ -n "$dev" ] || die "--dev required"; is_block "$dev" || die "Not a block device: $dev"
  out="${out:-$RES/health-$(basename "$dev")-$(ts)}"; mkdir -p "$out"
  local ctrl; ctrl="$(ctrl_of_ns "$dev")"
  if is_dev "$ctrl"; then
    nvme_safe "$out/smart.txt"      "$out/smart.txt.err"      nvme smart-log "$ctrl"     || true
    nvme_safe "$out/smart-add.txt"  "$out/smart-add.txt.err"  nvme smart-log-add "$ctrl" || true
    nvme_safe "$out/error-log.txt"  "$out/error-log.txt.err"  nvme error-log "$ctrl"     || true
    nvme_safe "$out/fw-log.txt"     "$out/fw-log.txt.err"     nvme fw-log "$ctrl"        || true
  else warn "Derived controller '$ctrl' is not a controller device; skipping nvme logs"; fi
  $SUDO smartctl -a "$dev" > "$out/smartctl.txt" 2> "$out/smartctl.txt.err" || true
  msg "Results -> $out"; }

sub_health() {
  local dev="" out=""
  while [[ $# -gt 0 ]]; do case "$1" in --dev) dev="$2"; shift 2;; --out) out="$2"; shift 2;; *) die "Unknown: $1";; esac; done
  require_block_ns "$dev"
  local ctrl; ctrl="$(get_ctrl "$dev")" || die "Cannot derive controller from $dev"
#  local dir="${out:-results/$(basename "$dev")-health-$(timestamp)}"; ensure_outdir "$dir"
  out="${out:-$RES/health-$(basename "$dev")-$(ts)}"; mkdir -p "$out"
  run_text_safely "$out/nvme-list.txt"   /usr/sbin/nvme list || true
  run_text_safely "$out/id-ctrl.txt"     /usr/sbin/nvme id-ctrl   "$ctrl" || true
  run_text_safely "$out/id-ns.txt"       /usr/sbin/nvme id-ns     "$dev"  || true
  run_text_safely "$out/smart.txt"       /usr/sbin/nvme smart-log "$ctrl" || true
  run_text_safely "$out/error-log.txt"   /usr/sbin/nvme error-log "$ctrl" || true
  run_text_safely "$out/fw-log.txt"      /usr/sbin/nvme fw-log    "$ctrl" || true
  run_text_safely "$out/smart-add.txt"   /usr/sbin/nvme smart-log-add "$ctrl"     || { warn "smart-log-add not supported"; echo "NOT SUPPORTED" > "$out/smart-add.txt"; }
  local csv="$out/smart_summary.csv"
  csv_header "$csv" "ctrl,critical_warning,temperature_C,available_spare,media_errors,num_err_log_entries,power_on_hours,power_cycles,unsafe_shutdowns,data_units_read,data_units_written"
  smart_txt_to_csv "$out/smart.txt" "$ctrl" "$csv"
  if have smartctl; then smartctl -a -d nvme "$ctrl" > "$out/smartctl.txt" 2>&1 || true; fi
  msg "health -> $out"
}

sub_selftest(){ local ctrl="" mode="" wait=0 out=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --ctrl) ctrl="$2"; shift 2;; --short) mode="1"; shift;; --long)  mode="2"; shift;;
    --vendor) mode="14"; shift;; --abort)  mode="15"; shift;; --wait) wait=1; shift;;
    --out) out="$2"; shift 2;; *) die "Unknown option: $1";; esac; done
  [ -n "$ctrl" ] || die "--ctrl /dev/nvmeX required"; is_dev "$ctrl" || die "Not a controller device: $ctrl"
  out="${out:-$RES/selftest-$(basename "$ctrl")-$(ts)}"; mkdir -p "$out"
  [ -n "$mode" ] && nvme_safe "$out/start.txt" "$out/start.txt.err" nvme device-self-test "$ctrl" --self-test-code="$mode" || true
  if [ $wait -eq 1 ]; then echo "Polling..." > "$out/poll.txt"; for _ in $(seq 1 180); do $SUDO nvme device-self-test "$ctrl" --self-test-code=0 >> "$out/poll.txt" 2>>"$out/poll.txt.err" || true; grep -qi "no self test running" "$out/poll.txt" && break; sleep 10; done
  else $SUDO nvme device-self-test "$ctrl" --self-test-code=0 > "$out/status.txt" 2> "$out/status.txt.err" || true; fi
  msg "Results -> $out"; }

run_fio_fs() {
  local dev="$1" rw="$2" bs="$3" iodepth="$4" nj="$5" secs="$6" size="$7" outdir="$8"
  local mnt="/mnt/avl"; sudo umount "$mnt" 2>/dev/null || true
  sudo mkfs.ext4 -F "$dev" > "$outdir/mkfs.txt" 2>&1 || die "mkfs failed on $dev"
  sudo mkdir -p "$mnt"; sudo mount -o noatime "$dev" "$mnt" || die "mount failed on $dev"
  local fiolog="$outdir/fio.txt" fiofile="$mnt/fiofile"
  fio --name=avl --filename="$fiofile" --rw="$rw" --bs="$bs"       --iodepth="$iodepth" --numjobs="$nj" --runtime="$secs" --time_based       --size="$size" --direct=1 --ioengine=libaio --group_reporting > "$fiolog" 2>&1 || true
  sudo umount "$mnt" || true
}
run_fio_raw() {
  local dev="$1" rw="$2" bs="$3" iodepth="$4" nj="$5" secs="$6" size="$7" outdir="$8"
  if lsblk -no MOUNTPOINT "$dev" | grep -q .; then die "$dev appears mounted; unmount for RAW test"; fi
  [ "$size" = "16G" ] && size="100%"
  fio --name=avl --filename="$dev" --rw="$rw" --bs="$bs"       --iodepth="$iodepth" --numjobs="$nj" --runtime="$secs" --time_based       --size="$size" --direct=1 --ioengine=libaio --group_reporting > "$outdir/fio.txt" 2>&1 || true
}
sub_fio() {
  local dev="" rw="randread" bs="4k" iodepth=64 nj=4 secs=60 size="16G" out="" raw=0 allow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dev) dev="$2"; shift 2;;
      --rw) rw="$2"; shift 2;;
      --bs) bs="$2"; shift 2;;
      --iodepth) iodepth="$2"; shift 2;;
      --numjobs) nj="$2"; shift 2;;
      --time) secs="$2"; shift 2;;
      --size) size="$2"; shift 2;;
      --raw) raw=1; shift;;
      --allow-destructive) allow=1; shift;;
      --out) out="$2"; shift 2;;
      *) die "Unknown: $1";;
    esac
  done
  require_block_ns "$dev"
  #local dir="${out:-results/$(basename "$dev")-fio-$(timestamp)}"; ensure_outdir "$dir"
  out="${out:-$RES/$(basename "$dev")-fio-$(ts)}"; mkdir -p "$out"
  if [ "$raw" -eq 1 ]; then
    [ "$allow" -eq 1 ] || die "Refusing RAW destructive test without --allow-destructive"
    run_fio_raw "$dev" "$rw" "$bs" "$iodepth" "$nj" "$secs" "$size" "$out"
  else
    run_fio_fs  "$dev" "$rw" "$bs" "$iodepth" "$nj" "$secs" "$size" "$out"
  fi
  csv_header "$out/summary.csv" "job,rw,bs,iodepth,numjobs,bw_MBps,iops,lat_avg_ms,lat_p99_ms"
  fio_txt_to_csv "$out/fio.txt" "avl" "$rw" "$bs" "$iodepth" "$nj" "$out/summary.csv"
  msg "fio -> $out"
}

sub_perf() {
  local dev="" out="" safe=0
  while [[ $# -gt 0 ]]; do case "$1" in --dev) dev="$2"; shift 2;; --out) out="$2"; shift 2;; --safe) safe=1; shift;; *) die "Unknown: $1";; esac; done
  require_block_ns "$dev"
  #local dir="${out:-results/$(basename "$dev")-perf-$(timestamp)}"; ensure_outdir "$dir"
  out="${out:-$RES/$(basename "$dev")-perf-$(ts)}"; mkdir -p "$out"
  if [ "$safe" -eq 1 ]; then
    msg "Using SAFE (read-only) profile"
    sub_fio --dev "$dev" --rw read     --bs 128k --iodepth 32 --numjobs 4 --time 90  --out "$out"
    sub_fio --dev "$dev" --rw randread --bs 4k   --iodepth 64 --numjobs 4 --time 120 --out "$out"
  else
    msg "Using FULL profile"
    sub_fio --dev "$dev" --rw read      --bs 128k --iodepth 32 --numjobs 4 --time 120 --out "$out"
    sub_fio --dev "$dev" --rw write     --bs 128k --iodepth 32 --numjobs 4 --time 120 --out "$out"
    sub_fio --dev "$dev" --rw randread  --bs 4k   --iodepth 64 --numjobs 4 --time 120 --out "$out"
    sub_fio --dev "$dev" --rw randwrite --bs 4k   --iodepth 64 --numjobs 4 --time 120 --out "$out"
    sub_fio --dev "$dev" --rw randrw    --bs 4k   --iodepth 64 --numjobs 4 --time 120 --out "$out"
  fi
  local ctrl; ctrl="$(get_ctrl "$dev")" || true
  [ -n "${ctrl:-}" ] && run_text_safely "$out/post-smart.txt"     /usr/sbin/nvme smart-log "$ctrl" || true
  [ -n "${ctrl:-}" ] && run_text_safely "$out/post-error-log.txt" /usr/sbin/nvme error-log "$ctrl" || true
  [ -n "${ctrl:-}" ] && run_text_safely "$out/post-fw-log.txt"    /usr/sbin/nvme fw-log    "$ctrl" || true
  msg "perf -> $out"
}

sub_integrity(){ local dev="" start="0" size="" out=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --dev) dev="$2"; shift 2;; --start) start="$2"; shift 2;; --size) size="$2"; shift 2;;
    --out) out="$2"; shift 2;; *) die "Unknown option: $1";; esac; done
  [ -n "$dev" ] || die "--dev required"; [ -n "$size" ] || die "--size required (e.g. 8G)"; is_block "$dev" || die "Not a block device: $dev"
  mounted "$dev" && die "Refusing integrity on mounted device $dev"
  out="${out:-$RES/integrity-$(basename "$dev")-$(ts)}"; mkdir -p "$out"
  fio --name=verify --filename="$dev" --rw=write --bs=128k --ioengine=libaio       --iodepth=64 --direct=1 --offset="$start" --size="$size"       --verify=sha256 --do_verify=1 --verify_pattern=0xDeadBeef       --group_reporting=1 > "$out/verify.txt" 2> "$out/verify.txt.err" || true
  msg "Results -> $out"; }

sub_thermal(){ local dev="" secs=120 interval=2 out=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --dev) dev="$2"; shift 2;; 
    --time) secs="$2"; shift 2;; 
    --interval) interval="$2"; shift 2;;
    --out) out="$2"; shift 2;; 
    *) die "Unknown option: $1";; esac; 
  done
  [ -n "$dev" ] || die "--dev required"; is_block "$dev" || die "Not a block device: $dev"
  local ctrl; ctrl="$(ctrl_of_ns "$dev")"; out="${out:-$RES/thermal-$(basename "$dev")-$(ts)}"; mkdir -p "$out"
  echo "ts,temp_c" > "$out/temps.csv"
  for ((i=0; i<secs; i+=interval)); do
    local temp; temp="$($SUDO nvme smart-log "$ctrl" 2>/dev/null | awk '/^temperature/ {print $2; exit}')"
    echo "$(date +%s),${temp:-}" >> "$out/temps.csv"; sleep "$interval"
  done; msg "Results -> $out"; }

usage(){ cat <<'EOF'
Usage: run_kernel_avl.sh <subcmd> [options]
Subcommands:
  list
  identify   --dev /dev/nvmeXnY
  health     --dev /dev/nvmeXnY
  selftest   --ctrl /dev/nvmeX [--short|--long|--vendor|--abort] [--wait]
  fio 	     --dev /dev/nvmeXnY [--rw randrw] [--bs 4k] [--iodepth 64] [--numjobs 4] [--time 120] [--size 16G] [--raw --allow-destructive]
  perf 	     --dev /dev/nvmeXnY [--safe]
  integrity  --dev /dev/nvmeXnY --start 0 --size 8G
  thermal    --dev /dev/nvmeXnY [--time 120] [--interval 2]
EOF
}
cmd="${1:-}"; shift || true
case "${cmd:-}" in
  list) sub_list "$@";;
  identify) sub_identify "$@";;
  health) sub_health "$@";;
  selftest) sub_selftest "$@";;
  fio) sub_fio "$@";;
  perf) sub_perf "$@" ;;
  integrity) sub_integrity "$@";;
  thermal) sub_thermal "$@";;
  *) usage; exit 1;;
esac
