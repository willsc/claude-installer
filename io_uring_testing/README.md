# io_uring Memory Structures, Tunables, and Capacity Planning

> Comprehensive Technical Analysis with Sliding Scale Reference

## Table of Contents

1. [Introduction to io_uring](#1-introduction-to-io_uring)
2. [Memory Structure Layout](#2-memory-structure-layout)
3. [Per-Ring Memory Consumption](#3-per-ring-memory-consumption)
4. [Understanding RLIMIT_MEMLOCK](#4-understanding-rlimit_memlock)
5. [Sliding Scale: RLIMIT_MEMLOCK vs Ring Capacity](#5-sliding-scale-rlimit_memlock-vs-ring-capacity)
6. [Configuring RLIMIT_MEMLOCK in Linux](#6-configuring-rlimit_memlock-in-linux)
7. [Tuning Recommendations by Use Case](#7-tuning-recommendations-by-use-case)
8. [Testing Methodology and Conclusions](#8-testing-methodology-and-conclusions)
9. [Memory Calculation Formula](#9-memory-calculation-formula)
10. [Test Programs](#10-test-programs)

---

## 1. Introduction to io_uring

io_uring is a high-performance asynchronous I/O interface introduced in Linux kernel 5.1, designed by Jens Axboe to address the limitations of traditional async I/O mechanisms like aio and epoll. Unlike its predecessors, io_uring uses a shared memory ring buffer architecture that minimizes system call overhead by allowing the kernel and user space to communicate through memory-mapped regions rather than repeated system calls.

The io_uring subsystem operates through two primary ring buffers:

- **Submission Queue (SQ)**: Where applications place I/O requests
- **Completion Queue (CQ)**: Where the kernel places completion notifications

This design enables applications to submit thousands of I/O operations with a single system call, dramatically reducing CPU overhead for I/O-intensive workloads.

---

## 2. Memory Structure Layout

Each io_uring instance consists of three memory regions:

1. **SQ Ring**: Contains indices and metadata
2. **CQ Ring**: Contains completion entries
3. **SQE Array**: Contains submission entries

### Structure Sizes

| Structure | Standard Size | Extended Size | Notes |
|-----------|---------------|---------------|-------|
| `io_uring_sqe` | 64 bytes | 128 bytes | `IORING_SETUP_SQE128` |
| `io_uring_cqe` | 16 bytes | 32 bytes | `IORING_SETUP_CQE32` |
| SQ Ring Header | ~128 bytes | - | Plus index array |
| CQ Ring Header | ~128 bytes | - | Plus CQE array |

---

## 3. Per-Ring Memory Consumption

The following table shows memory consumption for various ring sizes. All sizes are page-aligned (4096 bytes) because io_uring uses memory mapping. Requested entries are rounded up to the nearest power of two, and CQ size defaults to twice the SQ size.

| Configuration | SQ Entries | CQ Entries | Per Ring | Use Case |
|---------------|------------|------------|----------|----------|
| Tiny | 32 | 64 | 12 KB | Minimal testing |
| Small | 128 | 256 | 20 KB | Desktop apps |
| Medium | 512 | 1024 | 56 KB | General purpose |
| **Standard** | **1024** | **2048** | **108 KB** | **Server workloads** |
| Large | 4096 | 8192 | 408 KB | High throughput |
| XLarge | 8192 | 16384 | 808 KB | Database servers |
| Huge | 16384 | 32768 | 1.6 MB | Storage arrays |
| Maximum | 32768 | 65536 | 3.2 MB | Extreme workloads |

---

## 4. Understanding RLIMIT_MEMLOCK

`RLIMIT_MEMLOCK` is a Linux resource limit that controls the maximum amount of memory a process can lock into RAM (preventing it from being swapped out). io_uring rings are allocated as locked memory, making this the primary constraint for io_uring capacity.

**⚠️ The default value on most distributions is just 64 KB, which is insufficient for most io_uring use cases.**

### 4.1 Why io_uring Requires Locked Memory

The io_uring submission and completion queues must remain in physical memory at all times because the kernel needs to access them asynchronously without triggering page faults. If these buffers were swapped out during an I/O operation, the kernel would be unable to complete the operation, leading to system instability.

Additionally, registered buffers (used with `IORING_REGISTER_BUFFERS` for zero-copy I/O) require `FOLL_LONGTERM` memory pinning, which also counts against `RLIMIT_MEMLOCK`.

### 4.2 Kernel Version Considerations

Starting with Linux kernel 5.11, the kernel introduced memory cgroup (memcg) accounting for some BPF and io_uring operations. This means that on newer kernels, some io_uring memory may be tracked through cgroup limits rather than `RLIMIT_MEMLOCK`.

However, `RLIMIT_MEMLOCK` remains relevant for:
- Registered buffers
- Systems running older kernels
- Maximum compatibility

**Recommendation:** Configure both `RLIMIT_MEMLOCK` and appropriate cgroup limits.

---

## 5. Sliding Scale: RLIMIT_MEMLOCK vs Ring Capacity

The following matrix shows how many io_uring rings of each size can be created at various `RLIMIT_MEMLOCK` settings. Use this table to determine the minimum limit required for your workload.

### Maximum Rings per RLIMIT_MEMLOCK Setting

| Ring Size | 64 KB | 256 KB | 1 MB | 8 MB | 64 MB | 256 MB | 1 GB |
|-----------|-------|--------|------|------|-------|--------|------|
| 32 entries | 5 | 21 | 85 | 682 | 5,461 | 21,845 | 87,381 |
| 128 entries | 3 | 12 | 51 | 409 | 3,276 | 13,107 | 52,428 |
| 512 entries | 1 | 4 | 18 | 146 | 1,170 | 4,681 | 18,724 |
| **1024 entries** | **0** | **2** | **9** | **75** | **606** | **2,427** | **9,709** |
| 4096 entries | 0 | 0 | 2 | 20 | 160 | 642 | 2,570 |
| 8192 entries | 0 | 0 | 1 | 10 | 81 | 324 | 1,297 |
| 16384 entries | 0 | 0 | 0 | 5 | 40 | 163 | 652 |
| 32768 entries | 0 | 0 | 0 | 2 | 20 | 81 | 326 |

### Key Observations

- With the **default 64 KB limit**, you cannot create even a single 1024-entry ring
- **8 MB** is the minimum practical limit for server applications
- **256 MB** provides comfortable headroom for most high-performance workloads
- **1 GB or unlimited** is recommended for storage arrays and network appliances

---

## 6. Configuring RLIMIT_MEMLOCK in Linux

### 6.1 Temporary Configuration (ulimit)

```bash
# Check current limit (in KB)
ulimit -l

# Set to 256 MB (value in KB)
ulimit -l 262144

# Set to unlimited
ulimit -l unlimited
```

> **Note:** Non-root users can only decrease, not increase, limits without `CAP_SYS_RESOURCE`.

### 6.2 Permanent Configuration (limits.conf)

Edit `/etc/security/limits.conf`:

```bash
# Format: <domain> <type> <item> <value>
# domain: username, @groupname, or * for all
# type: soft (warning) or hard (enforced) or - (both)

# Set 256 MB limit for all users
*  soft  memlock  262144
*  hard  memlock  262144

# Set unlimited for specific user
dbuser  soft  memlock  unlimited
dbuser  hard  memlock  unlimited

# Set unlimited for a group
@iouring  soft  memlock  unlimited
@iouring  hard  memlock  unlimited
```

**Requires re-login to take effect.**

### 6.3 Per-Service Configuration (systemd)

Add to service unit file under `[Service]`:

```ini
[Service]
LimitMEMLOCK=infinity

# Or specific value in bytes:
LimitMEMLOCK=268435456  # 256 MB
```

Then reload and restart:

```bash
systemctl daemon-reload
systemctl restart myservice
```

### 6.4 Docker/Container Configuration

**Docker Compose:**

```yaml
services:
  myapp:
    image: myimage
    ulimits:
      memlock:
        soft: 262144
        hard: 262144
```

**Docker CLI:**

```bash
docker run --ulimit memlock=262144:262144 myimage
```

**Kubernetes:**

```yaml
securityContext:
  capabilities:
    add: ["IPC_LOCK"]
```

### 6.5 Related Kernel Parameters

```bash
# Maximum number of memory mappings (affects large rings)
sysctl -w vm.max_map_count=262144

# Make persistent in /etc/sysctl.conf:
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
```

### 6.6 Verification Commands

```bash
# Check current limits
ulimit -l                    # Current shell limit (KB)
ulimit -a                    # All limits
cat /proc/self/limits        # Detailed view
cat /proc/<pid>/limits       # For specific process

# Check system-wide locked memory
cat /proc/meminfo | grep -i lock

# Check capabilities
capsh --print
# CAP_IPC_LOCK: bypass memlock limit
# CAP_SYS_RESOURCE: raise limits beyond hard limit
```

---

## 7. Tuning Recommendations by Use Case

| Use Case | Ring Config | Typical Rings | Min Limit | Recommended |
|----------|-------------|---------------|-----------|-------------|
| Desktop/CLI apps | 256-512 entries | 1-4 rings | 256 KB | **8 MB** |
| Web servers | 1024 entries | 8-16 rings | 8 MB | **64 MB** |
| Databases | 4096 entries | 16-64 rings | 64 MB | **256 MB** |
| Storage servers | 8192+ entries | 64+ rings | 256 MB | **1 GB+** |
| Network appliances | 16384+ entries | Per-CPU rings | 1 GB | **Unlimited** |

### Quick Configuration Examples

**Desktop/Development:**
```bash
# In /etc/security/limits.conf
* soft memlock 8192
* hard memlock 8192
```

**Web Server (nginx, Apache with io_uring):**
```bash
# In /etc/security/limits.conf
www-data soft memlock 65536
www-data hard memlock 65536
```

**Database Server (PostgreSQL, MySQL with io_uring):**
```bash
# In /etc/security/limits.conf
postgres soft memlock 262144
postgres hard memlock 262144
mysql soft memlock 262144
mysql hard memlock 262144
```

**High-Performance Storage:**
```bash
# In /etc/security/limits.conf
* soft memlock unlimited
* hard memlock unlimited
```

---

## 8. Testing Methodology and Conclusions

### 8.1 Testing Approach

Our testing suite employs two complementary approaches:

1. **Simulation-based tool**: Calculates expected memory usage based on known structure sizes and kernel allocation patterns, allowing capacity planning without actual kernel support.

2. **Native test program**: Creates actual io_uring instances and measures real memory consumption through `/proc/self/statm` and ring structure introspection.

This dual approach validates theoretical calculations against real-world behavior.

### 8.2 Key Findings

1. **Memory consumption scales linearly** with entry count once page alignment overhead is amortized.

2. **SQE array dominates memory usage** for rings with 256+ entries at 64 bytes per entry.

3. **Minimum footprint is ~12 KB** per ring due to page alignment, regardless of entry count.

4. **RLIMIT_MEMLOCK is the primary constraint**, not kernel limits. With the default 64 KB limit, applications cannot create a single 1024-entry ring.

5. **Page alignment overhead** is significant for small rings but becomes negligible for large rings.

### 8.3 Recommendations

1. **Start with 256-1024 SQ entries** for general-purpose applications.

2. **Use smaller rings (32-128 entries)** for low-latency applications to minimize cache pressure.

3. **Use larger rings (4096-8192 entries)** for high-throughput batch processing to amortize system call overhead.

4. **Prefer per-CPU rings** over a single large ring for multi-core scaling.

5. **Always configure RLIMIT_MEMLOCK** before deploying io_uring applications.

---

## 9. Memory Calculation Formula

```
Per-Ring Memory = SQ_Ring + CQ_Ring + SQE_Array
```

Where:

```
SQ_Ring   = page_align(128 + 4 × SQ_entries)
CQ_Ring   = page_align(128 + 16 × CQ_entries)
SQE_Array = page_align(64 × SQ_entries)

page_align(x) = ceil(x / 4096) × 4096

CQ_entries = SQ_entries × 2 (default)
```

**Required RLIMIT_MEMLOCK = Per_Ring_Memory × Number_of_Rings**

### Quick Reference

| Entries | Per Ring Memory |
|---------|-----------------|
| 32 | ~12 KB |
| 256 | ~32 KB |
| 1024 | ~108 KB |
| 4096 | ~408 KB |
| 32768 | ~3.2 MB |

---

## 10. Test Programs

This repository includes several test programs:

### `rlimit_scale_test.c`

Generates a comprehensive sliding scale analysis showing how many rings fit at each RLIMIT_MEMLOCK setting.

```bash
gcc -o rlimit_scale_test rlimit_scale_test.c -lm
./rlimit_scale_test
```

### `io_uring_simulator.c`

Simulates io_uring memory usage without requiring kernel support. Useful for capacity planning on any system.

```bash
gcc -o io_uring_simulator io_uring_simulator.c -lm
./io_uring_simulator
```

### `io_uring_memory_test.c`

Creates actual io_uring instances and measures real memory consumption. Requires liburing and kernel 5.1+.

```bash
# Install liburing
apt-get install liburing-dev  # Debian/Ubuntu
dnf install liburing-devel    # Fedora/RHEL

# Compile and run
gcc -o io_uring_memory_test io_uring_memory_test.c -luring -lpthread
./io_uring_memory_test
```

### `run_tests.sh`

Orchestrates all tests and reports system configuration.

```bash
chmod +x run_tests.sh
./run_tests.sh
```

---

## License

This documentation and test code is provided for educational and operational purposes.

## References

- [io_uring documentation](https://kernel.dk/io_uring.pdf)
- [liburing GitHub](https://github.com/axboe/liburing)
- [LWN: In search of an appropriate RLIMIT_MEMLOCK default](https://lwn.net/Articles/876288/)
- [getrlimit(2) man page](https://man7.org/linux/man-pages/man2/getrlimit.2.html)
