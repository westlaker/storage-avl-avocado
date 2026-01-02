# make sure postgres user exists (it does if postgresql is installed)
id postgres

# ensure directory exists
sudo mkdir -p /mnt/nvme_test

# give postgres ownership (best for pgdata/logs)
sudo chown -R postgres:postgres /mnt/nvme_test

# recommended permissions
sudo chmod 700 /mnt/nvme_test
uid=120(postgres) gid=127(postgres) groups=127(postgres),126(ssl-cert)
sudo rm -f /mnt/nvme_test/pg.log

