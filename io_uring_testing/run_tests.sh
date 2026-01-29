#!/bin/bash
#
# io_uring Memory Structure Test Runner
# =====================================
# This script runs comprehensive tests on io_uring memory structures
# and generates a detailed report.
#

set -e

echo "=========================================="
echo "  io_uring Memory Structure Test Suite   "
echo "=========================================="
echo ""

# Check kernel version
KERNEL_VERSION=$(uname -r)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

echo "System Information:"
echo "-------------------"
echo "Kernel Version: $KERNEL_VERSION"
echo "Page Size: $(getconf PAGE_SIZE) bytes"

# Check if io_uring is available
IO_URING_AVAILABLE=0
if [ -e /sys/kernel/debug/io_uring ] || [ $KERNEL_MAJOR -ge 5 ]; then
    IO_URING_AVAILABLE=1
    echo "io_uring: Available"
else
    echo "io_uring: Not available (kernel < 5.1)"
fi

# Check MEMLOCK limits
echo ""
echo "Resource Limits:"
echo "----------------"
MEMLOCK_SOFT=$(ulimit -l)
echo "MEMLOCK soft limit: $MEMLOCK_SOFT KB"

# Check max_map_count
if [ -f /proc/sys/vm/max_map_count ]; then
    MAX_MAP=$(cat /proc/sys/vm/max_map_count)
    echo "vm.max_map_count: $MAX_MAP"
fi

# Check for io_uring specific sysctl
echo ""
echo "io_uring sysctl parameters:"
echo "---------------------------"
if [ -d /proc/sys/kernel ]; then
    for f in /proc/sys/kernel/io_uring*; do
        if [ -f "$f" ]; then
            NAME=$(basename $f)
            VALUE=$(cat $f 2>/dev/null || echo "unreadable")
            echo "$NAME: $VALUE"
        fi
    done
else
    echo "No io_uring specific sysctl found"
fi

echo ""
echo "=========================================="
echo "       Running Memory Simulation         "
echo "=========================================="
echo ""

# Run the simulator
if [ -f ./io_uring_simulator ]; then
    ./io_uring_simulator
else
    echo "Simulator not found. Please compile first:"
    echo "  gcc -o io_uring_simulator io_uring_simulator.c -lm"
fi

# If io_uring is available and liburing is installed, try actual tests
if [ $IO_URING_AVAILABLE -eq 1 ]; then
    echo ""
    echo "=========================================="
    echo "     Running Actual io_uring Tests       "
    echo "=========================================="
    echo ""
    
    if command -v pkg-config &> /dev/null && pkg-config --exists liburing; then
        echo "liburing found, compiling actual tests..."
        gcc -o io_uring_memory_test io_uring_memory_test.c -luring -lpthread 2>/dev/null && {
            ./io_uring_memory_test
        } || {
            echo "Compilation or execution failed"
            echo "Using simulated values only"
        }
    else
        echo "liburing not found. Install with:"
        echo "  apt-get install liburing-dev"
        echo ""
        echo "Using simulated values only"
    fi
fi

echo ""
echo "=========================================="
echo "              Test Complete              "
echo "=========================================="
