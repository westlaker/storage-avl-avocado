# Stop any leftover instance (ignore errors if not running)
PG_BIN_DIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
sudo -u postgres "$PG_BIN_DIR/pg_ctl" -D /mnt/nvme_test/pgdata stop 2>/dev/null || true

# Remove & recreate pgdata with the right owner
sudo rm -rf /mnt/nvme_test/pgdata
sudo mkdir -p /mnt/nvme_test/pgdata
sudo chown -R postgres:postgres /mnt/nvme_test/pgdata

