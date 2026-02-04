Here is the raw markdown for the `README.md` file. You can copy the content of the code block below directly into a file named `README.md`.


# uring_mem_sim

A utility to simulate and debug `io_uring` memory constraints, specifically targeting failures related to `MEMLOCK` (pinned memory), Virtual Memory Areas (VMAs), and aggregate host pressure.

## Build

Ensure you have the development libraries for `liburing` installed.

```
sudo apt-get update
sudo apt-get install -y build-essential liburing-dev
gcc -O2 -Wall -Wextra -std=gnu11 uring_mem_sim.c -luring -o uring_mem_sim
```

## Test Cases: Ramp Load Until Failure

These tests are designed to force failures in predictable ways. Each section includes a one-liner and a sweep script to find the exact failure threshold.

### 0) Sanity (Should Succeed)
Basic verification that the tool and environment are working.
```
./uring_mem_sim -P 1 -m 0 -n 2 -q 256 -b 64 -s 4096 -p 1
```

### 1) Force MEMLOCK/Pin Failure (Per-Process)
Set a small per-service memlock with `-k` and increase rings. Each ring pins ~64MiB (`-b 1024 -s 65536`), so `-k 128M` should allow ~2 rings max.

**One-liner:**
```
./uring_mem_sim -P 1 -m 0 -n 16 -q 512 -b 1024 -s 65536 -k 128M -p 1 -I
```

**Sweep rings until failure:**
```
cat > sweep_rings_until_fail.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BIN=${1:-./uring_mem_sim}

BASE_ARGS=(-P 1 -m 0 -q 512 -b 1024 -s 65536 -k 128M -p 1)

for n in 1 2 3 4 5 6 7 8 10 12 16 20 24 32; do
  echo "=== rings/service=$n ==="
  if $BIN "${BASE_ARGS[@]}" -n "$n" ; then
    echo "OK"
  else
    echo "FAILED at rings/service=$n"
    exit 0
  fi
done
EOF
chmod +x sweep_rings_until_fail.sh
./sweep_rings_until_fail.sh ./uring_mem_sim
```
*Note: If you see `setrlim err:*` or `memlock_curKB` not matching `-k`, your process hard limit is preventing raising `RLIMIT_MEMLOCK`.*

### 2) Confirm failure type: mlock (VmLck) vs pin (VmPin)
Run once with mlock enabled (default), then with `-L` (no mlock). Compare `VmLck` vs `VmPin` in system monitors.

```bash
# With mlock: VmLck should rise (if allowed)
./uring_mem_sim -P 1 -m 0 -n 4 -b 512 -s 65536 -k 512M -p 1

# Without mlock: VmLck ~0, VmPin should rise (if kernel exposes VmPin)
./uring_mem_sim -P 1 -m 0 -n 4 -b 512 -s 65536 -k 512M -L -p 1
```

### 3) Aggregate Host Pinned Pressure
Tests host capacity rather than per-service memlock by running many services.

**One-liner:**
```bash
./uring_mem_sim -P 24 -m 0 -n 4 -b 1024 -s 65536 -k 512M -L -p 2
```

**Sweep services until failure:**
```bash
cat > sweep_services_until_fail.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BIN=${1:-./uring_mem_sim}

BASE_ARGS=(-m 0 -n 4 -q 512 -b 1024 -s 65536 -k 512M -L -p 4)

for p in 1 2 4 6 8 12 16 24 32 48; do
  echo "=== services=$p ==="
  if $BIN -P "$p" "${BASE_ARGS[@]}" ; then
    echo "OK"
  else
    echo "FAILED at services=$p"
    exit 0
  fi
done
EOF
chmod +x sweep_services_until_fail.sh
./sweep_services_until_fail.sh ./uring_mem_sim
```

### 4) VMA / vm.max_map_count Failure
Pushes the VMA count limit. This requires lowering the system limit to hit reliably without massive memory usage.

**Warning:** Lowering `vm.max_map_count` can affect other services (e.g., Elasticsearch).

```bash
# Save current
ORIG=$(sysctl -n vm.max_map_count)
echo "orig vm.max_map_count=$ORIG"

# Lower for test
sudo sysctl -w vm.max_map_count=16384

# Push VMAs: mmap-per-buffer + guard pages (-M -G)
./uring_mem_sim -P 1 -m 0 -n 1 -M -G -b 12000 -s 4096 -p 1

# Restore
sudo sysctl -w vm.max_map_count="$ORIG"
```

**Sweep buffers until failure:**
```bash
cat > sweep_vmas_until_fail.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BIN=${1:-./uring_mem_sim}

echo "Lower vm.max_map_count first (e.g. sudo sysctl -w vm.max_map_count=16384) then run this."
BASE_ARGS=(-P 1 -m 0 -n 1 -M -G -s 4096 -p 1)

for b in 2000 4000 6000 8000 10000 12000 14000 16000 18000; do
  echo "=== buffers=$b ==="
  if $BIN "${BASE_ARGS[@]}" -b "$b" ; then
    echo "OK"
  else
    echo "FAILED at buffers=$b"
    exit 0
  fi
done
EOF
chmod +x sweep_vmas_until_fail.sh
./sweep_vmas_until_fail.sh ./uring_mem_sim
```

### 5) Queue Depth + Ring Overhead Pressure
Pushes ring memory overhead as well as buffers.
```bash
./uring_mem_sim -P 1 -m 0 -n 32 -q 4096 -b 64 -s 4096 -k 256M -p 4
```

### 6) Production Scenario Simulation (6 services / 8 NIC queues)
Use this to see if your production environment constraints are applied correctly.
```bash
./uring_mem_sim -P 6 -m 2 -Q 8 -b 1024 -s 65536 -k 512M -L -p 1 -I
```

## Interpreting Results
If the tool fails, check the **FINAL RESULTS** table:
- **setrlim err**: Your process hard limit is preventing the tool from requesting more `MEMLOCK` memory.
- **memlock_curKB vs -k**: If they don't match, `systemd` or a global limit is capping your process.
- **io_uring_register_buffers: Cannot allocate memory**: You have hit the kernel's pinned memory accounting limit or physical memory pressure.
```
```
