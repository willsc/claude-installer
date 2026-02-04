uring_mem_sim
A simulation tool designed to force io_uring memory allocation failures in predictable ways. This tool helps identify bottlenecks related to MEMLOCK (pinning), Virtual Memory Areas (VMAs), and aggregate host memory pressure.
Build
Ensure you have the necessary dependencies installed before compiling.
code
Bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y build-essential liburing-dev

# Compile
gcc -O2 -Wall -Wextra -std=gnu11 uring_mem_sim.c -luring -o uring_mem_sim
Testing Strategy: Ramp Load Until Failure
These test cases are designed to push the system until it fails. Each section includes a one-liner command and an optional sweep script to find the exact point of failure.
0) Sanity Check
Run a basic configuration that should always succeed to verify the environment.
code
Bash
./uring_mem_sim -P 1 -m 0 -n 2 -q 256 -b 64 -s 4096 -p 1
1) Force MEMLOCK/Pin Failure (Per-Process)
This test sets a small per-service memlock limit and increases the number of rings. Each ring pins ~64MiB (-b 1024 -s 65536), so a -k 128M limit should allow a maximum of approximately 2 rings.
One-liner:
code
Bash
./uring_mem_sim -P 1 -m 0 -n 16 -q 512 -b 1024 -s 65536 -k 128M -p 1 -I
Sweep rings until failure:
code
Bash
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
Note: If you see setrlim err:* or memlock_curKB does not match -k, your process hard limit is preventing the raising of RLIMIT_MEMLOCK.
2) Confirm Failure Type: mlock (VmLck) vs Pin (VmPin)
Compare behavior with and without explicit mlock.
code
Bash
# With mlock: VmLck should rise (if allowed)
./uring_mem_sim -P 1 -m 0 -n 4 -b 512 -s 65536 -k 512M -p 1

# Without mlock: VmLck ~0, VmPin should rise (if kernel exposes VmPin)
./uring_mem_sim -P 1 -m 0 -n 4 -b 512 -s 65536 -k 512M -L -p 1
3) Aggregate Host Pinned Pressure
Tests host capacity by running many services with moderate per-service requirements. This can fail due to total host pinning pressure even if individual services fit their limits.
One-liner:
code
Bash
./uring_mem_sim -P 24 -m 0 -n 4 -b 1024 -s 65536 -k 512M -L -p 2
Sweep services:
code
Bash
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
4) VMA / vm.max_map_count Failure
This test pushes the Virtual Memory Area count.
[!WARNING]
Lowering vm.max_map_count can negatively impact other software (e.g., Elasticsearch). Perform this on a test host.
code
Bash
# Save current limit
ORIG=$(sysctl -n vm.max_map_count)
echo "orig vm.max_map_count=$ORIG"

# Lower limit for testing
sudo sysctl -w vm.max_map_count=16384

# Push VMAs: mmap-per-buffer + guard pages (-M -G)
./uring_mem_sim -P 1 -m 0 -n 1 -M -G -b 12000 -s 4096 -p 1

# Restore original limit
sudo sysctl -w vm.max_map_count="$ORIG"
Sweep buffers until VMA failure:
code
Bash
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
5) Queue Depth + Ring Overhead Pressure
This pushes ring memory overhead in addition to registered buffers.
code
Bash
./uring_mem_sim -P 1 -m 0 -n 32 -q 4096 -b 64 -s 4096 -k 256M -p 4
6) Simulated Production Scenario (6 Services / 8 NIC Queues)
Simulates a specific production layout to verify if LimitMEMLOCK is correctly applied.
code
Bash
./uring_mem_sim -P 6 -m 2 -Q 8 -b 1024 -s 65536 -k 512M -L -p 1 -I
Troubleshooting
Review the FINAL RESULTS table produced by the tool. Pay close attention to:
memlock_curKB: If this is lower than your -k setting, the process hard limit or systemd LimitMEMLOCK is likely restricting the application.
setrlim err: Indicates the application failed to raise its own limits.
First Failure: Identifies whether you hit a hard cap, pinned memory accounting limits, or host-wide pressure.
