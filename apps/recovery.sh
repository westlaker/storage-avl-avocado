MNT=/mnt/nvme_test
PGDATA=$MNT/pgdata
PORT=5543
PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)

# 0) Stop anything still running on this data dir (ignore errors)
sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop || true

# 1) Ensure the mount is present (and not being reformatted concurrently)
mountpoint -q "$MNT" || { echo "[ERR] $MNT not mounted"; exit 1; }

# 2) Recreate a clean cluster (the previous one was corrupted by deletion)
sudo rm -rf "$PGDATA"
sudo install -d -o postgres -g postgres -m 700 "$PGDATA"

# 3) Initialize and allow localhost TCP trust just for this private instance
sudo -u postgres "$PGBIN/initdb" -D "$PGDATA"
echo "host all all 127.0.0.1/32 trust" | sudo tee -a "$PGDATA/pg_hba.conf" >/dev/null

# 4) Start on TCP only (avoid socket-dir quirks), wait until ready
sudo -u postgres "$PGBIN/pg_ctl" -D "$PGDATA" -l "$MNT/pg.log" \
  -o "-c listen_addresses='127.0.0.1' -c unix_socket_directories='' -c port=$PORT" \
  -w start

# 5) Sanity
sudo -u postgres "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -d postgres \
  -c "show data_directory; show port;"

