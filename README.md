# AVL Storage Suite (Kernel + SPDK + Apps)

File Structure:

```text
.
├── apps
│   ├── app_pgbench.sh
│   ├── app_rocksdb.sh
│   ├── cleanup.sh
│   ├── fixit.sh
│   ├── prep_db_bench.sh
│   ├── README
│   ├── recovery.sh
├── avlrun
├── avocado
│   ├── README.md
│   └── tests
│       ├── avl_script_test.py
│       ├── __init__.py
├── kernel
│   └── run_kernel_avl.sh
├── README.md
├── results
├── spdk
│   ├── prep_spdk.sh
│   ├── run_spdk.sh
│   ├── run_spdk_stress_latency.sh
│   └── spdk_charts.py
```

Setup avocado env:

```text
 $ python3 -m venv ~/venv-avocado
 $ . ~/venv-avocado/bin/activate
```

Kernel Test:

```text
 $ sudo -E ./avlrun ./kernel/run_kernel_avl.sh` — list / identify / health / selftest / fio / integrity / thermal
 ./avlrun kernel/run_kernel_avl.sh list
 ./avlrun kernel/run_kernel_avl.sh info
 ./avlrun kernel/run_kernel_avl.sh identify --dev /dev/nvme0n1
 ./avlrun kernel/run_kernel_avl.sh health --dev /dev/nvme0n1
 ./avlrun kernel/run_kernel_avl.sh perf --dev /dev/nvme0n1
 ./avlrun kernel/run_kernel_avl.sh fio --dev /dev/nvme0n1 --rw randrw --bs 4k --iodepth 64 --numjobs 4 --time 60 --raw --allow-destructive
 ./avlrun kernel/run_kernel_avl.sh integrity --dev /dev/nvme0n1 --size 100G
 ./avlrun kernel/run_kernel_avl.sh thermal --dev /dev/nvme0n1
```

SPDK Test

```text
 One-Time Setup:

 $ ./spdk/pref_spdk.sh
 $ sudo sh -c 'echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages'
 $ sudo mkdir -p /dev/hugepages
 $ mount | grep -q "/dev/hugepages" || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages

 single perf run (bind→run→rebind, uio/vfio auto):

 $ ./avlrun spdk/run_spdk.sh list
 $ ./avlrun spdk/run_spdk.sh info
 $ sudo -E ./avlrun spdk/run_spdk.sh perf --dev /dev/nvme0n1 --rw read --qd 32 --iosize 131072 --time 30

 matrix sweep (parallel capable), summary.csv + charts:

 $ sudo -E ./avlrun spdk/run_spdk_stress_latency.sh --dev /dev/nvme0n1 --rw read,randread --qd 1,4,16,32,64 --iosize 4k,128k --time 60 --loops 2
```

Apps Test
```text
 simple PostgreSQL pgbench on a mounted test FS:

 $ sudo -E ./avlrun apps/app_pgbench.sh --dev /dev/nvme0n1 --mkfs ext4 --reinit --scale 100 --clients 32 --threads 32 --time 120

 RocksDB db_bench fillrandom+readrandom on a mounted test FS:

 $ sudo -E ./avlrun apps//app_rocksdb.sh --dev /dev/nvme0n1 --mkfs ext4 --reinit   --bench fillrandom,readrandom --num 10000000 --threads 16 --duration 60
```

Outputs:
```text
kernel & spdk -> `./results/...` ; 
apps -> your mount (default `/mnt/nvme_test`).
```


