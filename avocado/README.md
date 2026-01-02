# AVL Storage – Avocado (simple)

This integration is intentionally minimal: it **does not modify** your existing scripts.
It only adds a small Avocado test wrapper and a helper script (`./avlrun`) so you can
run the existing scripts under Avocado without YAML/mux/injection.

## Prerequisites

Activate your existing venv where `avocado` is installed, e.g.

```bash
source ~/venv-avocado/bin/activate
avocado --version
```

## Run

From the repo root:

```bash
./avlrun kernel/run_kernel_avl.sh list
```

Run any other command by changing arguments:

```bash
./avlrun kernel/run_kernel_avl.sh "health --dev /dev/nvme0n1"
./avlrun spdk/run_spdk.sh "perf --dev /dev/nvme1n1 --rw randread --qd 32"
```

## If root is required

```bash
sudo -E ./avlrun kernel/run_kernel_avl.sh "health --dev /dev/nvme0n1"
```

## Logs

Avocado prints a JOB LOG path after each run. That log will include the full stdout/stderr
from the script.
