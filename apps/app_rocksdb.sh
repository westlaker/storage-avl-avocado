#!/usr/bin/env bash
set -euo pipefail

# ---------- defaults ----------
MNT="/mnt/nvme_test"
DEV=""
MKFS=""                 # ext4|xfs
REINIT=0                # wipe/reinit RocksDB dir before run
DBDIR="$MNT/rocks"
WALDIR="$MNT/rocks_wal"
OUTDIR="$MNT/rocks_results"

BENCH="fillrandom,readrandom"
NUM=10000000
KEY_SIZE=16
VALUE_SIZE=400
THREADS=16
DURATION=60
CACHE_SIZE_MB=1024
COMPRESSION="none"      # none|lz4|zstd
TARGET_FILE_SIZE_BASE_MB=64
MAX_BG_JOBS=8

msg(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--dev /dev/nvmeXnY] [--mkfs ext4|xfs] [--mount DIR] [--reinit]
          [--bench fillrandom,readrandom,...] [--num N] [--threads N]
          [--duration SEC] [--value_size BYTES] [--key_size BYTES]
          [--compression none|lz4|zstd] [--cache_mb N] [--bg_jobs N]
Examples:
  $0 --dev /dev/nvme0n1 --mkfs ext4 --reinit --bench fillrandom,readrandom --num 10000000 --threads 16 --duration 60
EOF
}

ensure_mount() {
  if [[ -n "$DEV" ]] && ! mountpoint -q "$MNT"; then
    sudo mkdir -p "$MNT"
    if [[ -n "$MKFS" ]]; then
      case "$MKFS" in
        ext4) sudo mkfs.ext4 -F "$DEV" ;;
        xfs)  sudo mkfs.xfs  -f "$DEV" ;;
        *) die "--mkfs expects ext4 or xfs";;
      esac
    fi
    sudo mount "$DEV" "$MNT"
  fi
  mountpoint -q "$MNT" || die "Mountpoint $MNT not found. Use --dev /dev/nvmeXnY or mount first."
  sudo chmod 755 "$MNT"
}

find_db_bench() {
  if command -v db_bench >/dev/null 2>&1; then
    DB_BENCH="$(command -v db_bench)"; return
  fi
  for p in "$HOME/rocksdb/db_bench" "/usr/local/bin/db_bench" "/usr/bin/db_bench" "$HOME/rocksdb/build/db_bench"; do
    [[ -x "$p" ]] && { DB_BENCH="$p"; return; }
  done
  die "db_bench not found. Install either:
  - Package:   sudo apt-get install -y rocksdb-tools
  - Or build:  sudo apt-get install -y build-essential cmake git libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev libgflags-dev
               git clone --depth=1 https://github.com/facebook/rocksdb.git && cd rocksdb
               PORTABLE=1 USE_RTTI=1 DISABLE_WARNING_AS_ERROR=1 make -j4 db_bench && sudo cp db_bench /usr/local/bin/"
}

prep_dirs() {
  sudo mkdir -p "$DBDIR" "$WALDIR" "$OUTDIR"
  if [[ $REINIT -eq 1 ]]; then
    msg "Reinitializing RocksDB dirs"
    sudo rm -rf "$DBDIR" "$WALDIR"
    sudo mkdir -p "$DBDIR" "$WALDIR"
  fi
  sudo chown -R "$USER":"$USER" "$OUTDIR" "$DBDIR" "$WALDIR"
}

check_gflags() {
  # If db_bench prints the gflags error on --help, tell user to install runtime
  if ! "$DB_BENCH" --help >/dev/null 2>&1; then
    warn "db_bench failed on --help; ensuring gflags is installed..."
    if ! dpkg -s libgflags2.2 >/dev/null 2>&1 && ! dpkg -s libgflags2.2.2 >/dev/null 2>&1; then
      echo "Please install gflags runtime:"
      echo "  sudo apt-get install -y libgflags2.2 libgflags-dev"
      exit 1
    fi
  fi
}

summarize_run() {
  local f="$1" bench_name="$2" thr="$3" dur="$4"
  local ops="" mb="" p50="" p95="" p99="" p999=""
  ops=$(grep -Eo '([0-9]+\.[0-9]+) ops/sec|ops/sec; ([0-9]+\.[0-9]+)' "$f" | tail -1 | awk '{print $1}' | tr -d ';')
  [[ -z "$ops" ]] && ops=$(grep -E 'ops/sec' "$f" | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /ops\/sec/) {print $(i-1); exit}}' | tr -d ';')
  mb=$(grep -Eo '([0-9]+\.[0-9]+) MB\/sec' "$f" | tail -1 | awk '{print $1}')
  p50=$(grep -E 'Percentiles:.*P50' "$f" | tail -1 | sed -E 's/.*P50: *([0-9\.]+).*/\1/' || true)
  p95=$(grep -E 'Percentiles:.*P95' "$f" | tail -1 | sed -E 's/.*P95: *([0-9\.]+).*/\1/' || true)
  p99=$(grep -E 'Percentiles:.*P99[^0-9]' "$f" | tail -1 | sed -E 's/.*P99: *([0-9\.]+).*/\1/' || true)
  p999=$(grep -E 'Percentiles:.*P99\.9' "$f" | tail -1 | sed -E 's/.*P99\.9: *([0-9\.]+).*/\1/' || true)
  echo "$(date +%F\ %T),$bench_name,$thr,$dur,${ops:-},${mb:-},${p50:-},${p95:-},${p99:-},${p999:-}"
}

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)       DEV="$2"; shift 2;;
    --mkfs)      MKFS="$2"; shift 2;;
    --mount)     MNT="$2"; shift 2;;
    --reinit)    REINIT=1; shift;;
    --bench)     BENCH="$2"; shift 2;;
    --num)       NUM="$2"; shift 2;;
    --threads)   THREADS="$2"; shift 2;;
    --duration)  DURATION="$2"; shift 2;;
    --value_size) VALUE_SIZE="$2"; shift 2;;
    --key_size)  KEY_SIZE="$2"; shift 2;;
    --compression) COMPRESSION="$2"; shift 2;;
    --cache_mb)  CACHE_SIZE_MB="$2"; shift 2;;
    --bg_jobs)   MAX_BG_JOBS="$2"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

# ---------- flow ----------
ensure_mount
find_db_bench
check_gflags
prep_dirs
ulimit -n 100000 || warn "Could not raise ulimit -n; continuing."

DB_ARGS=(
  --db="$DBDIR"
  --wal_dir="$WALDIR"
  --key_size="$KEY_SIZE"
  --value_size="$VALUE_SIZE"
  --cache_size="$(($CACHE_SIZE_MB*1024*1024))"
  --compression_type="$COMPRESSION"
  --target_file_size_base="$(($TARGET_FILE_SIZE_BASE_MB*1024*1024))"
  --max_background_jobs="$MAX_BG_JOBS"
  --use_direct_reads=1
  --use_direct_io_for_flush_and_compaction=1
  --statistics=1
)
RUN_ARGS=( --benchmarks="$BENCH" --num="$NUM" --duration="$DURATION" --threads="$THREADS" )

RUN_TAG="$(echo "$BENCH" | tr ',' '+')-t${THREADS}-d${DURATION}-n${NUM}"
OUT_TXT="$OUTDIR/${RUN_TAG}.txt"
msg "Running RocksDB db_bench: $RUN_TAG"
"$DB_BENCH" "${DB_ARGS[@]}" "${RUN_ARGS[@]}" | tee "$OUT_TXT"

SUMMARY="$OUTDIR/summary.csv"
[ -f "$SUMMARY" ] || echo "ts,bench,threads,duration_s,ops_per_sec,mb_per_sec,p50_ms,p95_ms,p99_ms,p999_ms" > "$SUMMARY"

IFS=',' read -ra BENCH_LIST <<< "$BENCH"
for b in "${BENCH_LIST[@]}"; do
  sec_file="$OUTDIR/${RUN_TAG}_${b}.part"
  awk -v b="^$b *:" '
    BEGIN{found=0}
    $0 ~ b {found=1}
    found {print}
  ' "$OUT_TXT" > "$sec_file" || true
  [[ -s "$sec_file" ]] || sec_file="$OUT_TXT"
  summarize_run "$sec_file" "$b" "$THREADS" "$DURATION" >> "$SUMMARY"
done

msg "Done. Results:"
echo "  Text log:    $OUT_TXT"
echo "  CSV summary: $SUMMARY"

