#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config / defaults
# =========================
MNT="/mnt/nvme_test"        # target mountpoint
DEV=""                      # --dev /dev/nvmeXnY
MKFS=""                     # --mkfs ext4|xfs
REINIT=0                    # --reinit (wipe PGDATA before initdb)
SCALE=50                    # --scale (pgbench init)
CLIENTS=16                  # --clients
THREADS=16                  # --threads
TIME=60                     # --time seconds
DBNAME="bench"              # database name
PORT=5543                   # private TCP port (avoid 5432 conflicts)
KEEP_RUNNING=0              # --keep-running (don't stop PG at the end)

# Derived paths
PGDATA=""                   # set after mount
LOGFILE=""                  # set after mount
OUTDIR=""                   # set after mount
OUTFILE=""                  # set after mount
SUMMARY=""                  # set after mount

# =========================
# Helpers
# =========================
msg(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--dev /dev/nvmeXnY] [--mkfs ext4|xfs] [--mount DIR]
          [--reinit] [--scale N] [--clients C] [--threads T] [--time SEC]
          [--port P] [--keep-running]

Examples:
  # Fresh device -> format ext4 -> mount -> init db -> run 120s
  $0 --dev /dev/nvme0n1 --mkfs ext4 --reinit --scale 100 --clients 32 --threads 32 --time 120

  # Already mounted volume (no mkfs), reuse existing cluster:
  $0 --scale 200 --clients 64 --threads 64 --time 180
EOF
}

# =========================
# Parse args
# =========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)          DEV="$2"; shift 2 ;;
    --mkfs)         MKFS="$2"; shift 2 ;;
    --mount)        MNT="$2"; shift 2 ;;
    --reinit)       REINIT=1; shift ;;
    --scale)        SCALE="$2"; shift 2 ;;
    --clients)      CLIENTS="$2"; shift 2 ;;
    --threads)      THREADS="$2"; shift 2 ;;
    --time|-T)      TIME="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# =========================
# Concurrency lock (avoid double-runs that clobber PGDATA)
# =========================
LOCK=/var/lock/app_pgbench.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  die "Another app_pgbench run is active. Try again later."
fi

# =========================
# Find PostgreSQL binaries
# =========================
if command -v initdb >/dev/null 2>&1; then
  PG_BIN_DIR="$(dirname "$(command -v initdb)")"
else
  PG_BIN_DIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -n "${PG_BIN_DIR:-}" ] || die "PostgreSQL not found. Install: sudo apt-get install -y postgresql postgresql-contrib pgbench"

INITDB="$PG_BIN_DIR/initdb"
PG_CTL="$PG_BIN_DIR/pg_ctl"
CREATEDB="$(command -v createdb || echo "$PG_BIN_DIR/createdb")"
PGBENCH="$(command -v pgbench  || echo "$PG_BIN_DIR/pgbench")"
PSQL="$(command -v psql || echo "$PG_BIN_DIR/psql")"

# =========================
# Mounting / formatting
# =========================
ensure_mount() {
  if [[ -n "$DEV" ]] && ! mountpoint -q "$MNT"; then
    # Safety: refuse to mkfs a system disk (mounted as /)
    if findmnt -no SOURCE / | grep -qxF "$DEV"; then
      die "Refusing to format the root filesystem device '$DEV'. Pick a data disk."
    fi
    sudo mkdir -p "$MNT"
    if [[ -n "$MKFS" ]]; then
      case "$MKFS" in
        ext4) sudo mkfs.ext4 -F "$DEV" ;;
        xfs)  sudo mkfs.xfs  -f "$DEV" ;;
        *)    die "--mkfs expects ext4 or xfs" ;;
      esac
    fi
    sudo mount "$DEV" "$MNT"
  fi
  mountpoint -q "$MNT" || die "Mountpoint $MNT not found. Use --dev /dev/nvmeXnY or mount it first."
  # Traversable mount for postgres user
  sudo chmod 755 "$MNT"
}

ensure_mount

PGDATA="$MNT/pgdata"
LOGFILE="$MNT/pg.log"
OUTDIR="$MNT/pg_results"
OUTFILE="$OUTDIR/pgbench_${SCALE}s_${CLIENTS}c_${THREADS}t_${TIME}s.txt"
SUMMARY="$OUTDIR/summary.csv"
sudo mkdir -p "$OUTDIR"
sudo chown -R "$USER":"$USER" "$OUTDIR"

# =========================
# PG helpers
# =========================
pg_running() { sudo -u postgres "$PG_CTL" -D "$PGDATA" status >/dev/null 2>&1; }

assert_pg_stopped_before_mutation() {
  if pg_running; then
    die "Refusing to mkfs/reinit/init while Postgres is running on $PGDATA. Stop it first."
  fi
}

init_cluster_if_needed() {
  if [[ $REINIT -eq 1 ]]; then
    assert_pg_stopped_before_mutation
    msg "Reinitializing cluster at $PGDATA"
    sudo rm -rf "$PGDATA"
  fi
  if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    msg "Initializing cluster in $PGDATA"
    sudo install -d -o postgres -g postgres -m 700 "$PGDATA"
    sudo -u postgres "$INITDB" -D "$PGDATA"
    # Enable local TCP trust for this private instance
    echo "host all all 127.0.0.1/32 trust" | sudo tee -a "$PGDATA/pg_hba.conf" >/dev/null
  else
    # Ensure proper modes (in case user tinkered)
    sudo chown -R postgres:postgres "$PGDATA"
    sudo chmod 700 "$PGDATA"
    msg "Cluster present at $PGDATA (use --reinit to recreate)."
  fi
}

start_pg_tcp() {
  # Clean stale PID if not running
  if ! pg_running; then
    sudo rm -f "$PGDATA"/postmaster.pid "$PGDATA"/postmaster.opts 2>/dev/null || true
  fi
  msg "Starting postgres TCP (log: $LOGFILE; 127.0.0.1:$PORT)"
  if ! sudo -u postgres "$PG_CTL" -D "$PGDATA" -l "$LOGFILE" \
        -o "-c listen_addresses='127.0.0.1' -c unix_socket_directories='' -c port=$PORT" \
        -w start
  then
    echo "---- start failed; tail of $LOGFILE ----"
    sudo tail -n 200 "$LOGFILE" || true
    die "Postgres failed to start; see $LOGFILE"
  fi
  # Quick reachability check
  if ! sudo -u postgres "$PSQL" -h 127.0.0.1 -p "$PORT" -d postgres -tAc "select 1" >/dev/null 2>&1; then
    sudo tail -n 200 "$LOGFILE" || true
    die "Postgres started but not reachable on 127.0.0.1:$PORT"
  fi
}

stop_pg_if_needed() {
  if pg_running; then
    msg "Stopping postgres"
    sudo -u postgres "$PG_CTL" -D "$PGDATA" stop
  fi
}

# Ensure we stop PG if the script aborts mid-run (unless KEEP_RUNNING=1)
cleanup() {
  if [[ $KEEP_RUNNING -eq 0 ]]; then
    stop_pg_if_needed || true
  fi
}
trap cleanup EXIT

# =========================
# Flow
# =========================
init_cluster_if_needed
start_pg_tcp

# Ensure DB exists and initialized
if ! sudo -u postgres "$PSQL" -h 127.0.0.1 -p "$PORT" -d postgres -tAc \
     "select 1 from pg_database where datname='${DBNAME}'" | grep -qx 1; then
  msg "Creating DB '$DBNAME'"
  sudo -u postgres "$CREATEDB" -h 127.0.0.1 -p "$PORT" "$DBNAME"
  msg "Initializing pgbench scale=$SCALE"
  sudo -u postgres "$PGBENCH" -h 127.0.0.1 -p "$PORT" -i -s "$SCALE" "$DBNAME"
fi

# Run workload
msg "Running pgbench: clients=$CLIENTS threads=$THREADS time=${TIME}s"
sudo -u postgres "$PGBENCH" -h 127.0.0.1 -p "$PORT" \
  -c "$CLIENTS" -j "$THREADS" -T "$TIME" "$DBNAME" | tee "$OUTFILE"

# Summarize to CSV
[ -f "$SUMMARY" ] || echo "ts,scale,clients,threads,time_s,tps,lat_ms" > "$SUMMARY"
TPS=$(grep -E '^tps =' "$OUTFILE" | awk '{print $3}' || echo "")
LAT=$(grep -E '^latency average' "$OUTFILE" | awk '{print $4}' || echo "")
echo "$(date +%F\ %T),$SCALE,$CLIENTS,$THREADS,$TIME,${TPS:-},${LAT:-}" >> "$SUMMARY"
msg "Summary -> $SUMMARY"

if [[ $KEEP_RUNNING -eq 1 ]]; then
  msg "Leaving Postgres running on 127.0.0.1:$PORT (use pg_ctl stop to stop)"
else
  stop_pg_if_needed
fi

msg "Done. Results: $OUTFILE  (log: $LOGFILE)"

