
## Configuration & Usage

### Services (Processes)
*   **`-P NUM`**: Number of services to simulate. Each service is a separate process (via `fork()`). This is critical because:
    *   `LimitMEMLOCK` / `RLIMIT_MEMLOCK` is enforced per-process.
    *   `vm.max_map_count` is enforced per-process.
    *   Host pinned RAM is the aggregate sum across all processes.
    *   *Example:* `-P 6` simulates 6 independent systemd services.

### Ring Count Model
Choose how many `io_uring` rings are created per service.

*   **`-m MODE`**: Computation mode for rings per service:
    *   `0`: Direct count (uses `-n`).
    *   `1`: One ring per thread (uses `-T`).
    *   `2`: One ring per NIC queue (uses `-Q`).
    *   `3`: Threads × NIC queues (uses `-T` * `-Q`).
*   **`-n NUM`**: Number of rings per service (used when `-m 0`).
*   **`-T NUM`**: Threads per service (used when `-m 1` or `-m 3`). The simulator does not spawn actual threads; it uses this value to compute the ring count.
*   **`-Q NUM`**: NIC queues (used when `-m 2` or `-m 3`). This models ring counts based on network interface queues.

**Examples:**
- `-m 0 -n 8` → 8 rings per service.
- `-m 2 -Q 8` → 8 rings per service (models one ring per RX/TX queue).
- `-m 3 -T 4 -Q 8` → 32 rings per service.

### Per-Ring Configuration
Defines the resources allocated to each individual ring.

*   **`-q DEPTH`**: `io_uring` queue depth (SQ entries). Larger depths increase ring metadata memory.
*   **`-b NUM`**: Number of buffers per ring.
*   **`-s BYTES`**: Buffer size in bytes. Each buffer is rounded up to 4096 bytes internally.
    *   *Note:* Pinned bytes per ring ≈ `buffers_per_ring * round_up(buffer_size, 4096)` + ring overhead.
*   **`-f NUM`**: Registers this many "fixed file descriptors" per ring (simulates dummy sockets).

### Pinned Memory Controls (MEMLOCK)
*   **`-L`**: Disable `mlock()` on user buffers.
    *   `VmLck` will stay near 0, but `io_uring_register_buffers()` will still pin pages. You may see `VmPin` grow depending on your kernel version.
*   **`-k SIZE`**: Calls `setrlimit(RLIMIT_MEMLOCK)` inside each process to simulate `LimitMEMLOCK=`.
    *   Accepts suffixes: `K`, `M`, `G` (e.g., `-k 512M`, `-k 1G`).
    *   **Note:** `setrlimit` may fail if the process lacks permission to raise its hard limit. The output table will show `setrlim ok` or `setrlim err:<errno>`.

### VMA / vm.max_map_count Stress Mode
Used to test the limits of Virtual Memory Areas.

*   **`-M`**: "mmap-per-buffer". Allocates each buffer with its own `mmap()` call rather than one large pool. This increases VMA pressure.
*   **`-G`**: Adds a `PROT_NONE` guard page after each buffer mapping. This prevents the kernel from merging adjacent VMAs, ensuring a predictable increase in VMA count.

### Reporting & Output
*   **`-p N`**: Progress update frequency. Sends an update every `N` rings created. (`-p 1` for most detail).
*   **`-I`**: Interactive redraw mode. Clears the screen and updates a live results table.
*   **`-S FACTOR`**: Safety factor for recommendations (default: `1.5`).
*   **`-v`**: Extra verbosity.
*   **`-h`**: Display help.

---

## Quick Recipes

**Model: 6 services, 8 NIC queues, heavy pinned buffers**
```bash
./uring_mem_sim -P 6 -m 2 -Q 8 -b 1024 -s 65536 -k 512M -p 1 -I
```

**Force MEMLOCK failure quickly**
```bash
./uring_mem_sim -P 1 -m 0 -n 16 -b 1024 -s 65536 -k 128M -p 1 -I
```

**Force VMA pressure (vm.max_map_count)**
*Recommended: temporarily lower `vm.max_map_count` on a test box first.*
```bash
./uring_mem_sim -P 1 -m 0 -n 1 -M -G -b 12000 -s 4096 -p 1 -I
```
```
