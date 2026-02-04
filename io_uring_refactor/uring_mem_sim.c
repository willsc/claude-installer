// uring_mem_sim.c
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/*
 * MULTI-SERVICE IO_URING MEMLOCK + VMA SIMULATOR
 *
 * -P  => number of services (processes)
 * -m  => rings/service model
 *     0: direct (-n rings per service)
 *     1: threads (-T)
 *     2: NIC queues (-Q)
 *     3: threads * NIC queues (-T * -Q)
 *
 * Per ring:
 *  - allocate buffers (either pooled or mmap-per-buffer)
 *  - optional mlock() (VmLck)
 *  - io_uring_register_buffers (VmPin on many kernels)
 *
 * Realtime:
 *  - child processes stream progress/final stats to parent via one pipe
 *  - parent prints tidy tabulation (interactive redraw with -I, or log rows without -I)
 *
 * Recommendation tables:
 *  A) scale rings/service (services fixed)
 *  B) scale services count (rings/service fixed)
 *
 * Diagnostics:
 *  - per-service RLIMIT_MEMLOCK cur/max
 *  - setrlimit() result/errno if -k used (very common root cause of “Cannot allocate memory”)
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -std=gnu11 uring_mem_sim.c -luring -o uring_mem_sim
 */

#define MAX_RINGS_PER_SERVICE 1000
#define SIMMSG_MAGIC 0x53494D55u /* 'SIMU' */

typedef struct {
    long vmlck_kb; // VmLck
    long vmpin_kb; // VmPin (if present)
    long vmrss_kb; // VmRSS
    long vmas;     // /proc/self/maps line count
    long rlim_cur_kb;
    long rlim_max_kb;
} ProcStats;

typedef struct {
    struct io_uring ring;
    int ring_fd;

    // pooled buffers
    void *buffer_pool;
    size_t buffer_pool_size;

    // mmap-per-buffer
    void **buffers;
    size_t *buffer_sizes;

    // optional guard pages (VMA stress)
    void **guards;
    size_t *guard_sizes;

    struct iovec *iovecs;
    int num_buffers;

    int buffers_registered;
    int buffers_locked;

    int *registered_fds;
    int num_registered_fds;
    int fds_registered;

    int ring_id;
    int creation_failed;
    int failure_errno;
    char failure_reason[256];

    size_t ring_mem;
    size_t buffer_mem;
    size_t total_mem;
} BigUringInstance;

typedef struct {
    int num_services;

    int ring_model;           // 0,1,2,3
    int rings_per_service;    // -n when model 0
    int threads_per_service;  // -T
    int nic_queues;           // -Q

    int queue_depth;          // -q
    int num_buffers;          // -b
    size_t buffer_size;       // -s
    int num_registered_fds;   // -f

    int lock_memory;          // mlock buffers (VmLck)
    int vma_per_buffer;       // -M mmap-per-buffer
    int guard_pages;          // -G add 1 PROT_NONE guard VMA after each buffer

    int set_memlock_limit;      // -k
    size_t memlock_limit_bytes; // -k SIZE

    double safety_factor;     // -S
    int progress_every;       // -p N (per child)
    int interactive;          // -I (parent redraw)
    int verbose;              // -v
} SimConfig;

static SimConfig config;

typedef enum { MSG_PROGRESS = 1, MSG_FINAL = 2 } MsgType;

typedef struct {
    uint32_t magic;
    uint16_t type;
    uint16_t service_id;

    int rings_requested;
    int ring_index;
    int created;
    int failed;

    long vmlck_kb;
    long vmpin_kb;
    long vmrss_kb;
    long vmas;
    long rlim_cur_kb;
    long rlim_max_kb;

    int setrlimit_rc;
    int setrlimit_errno;

    int first_errno;
    char first_failure[160];
} SimMsg;

// ---------------- helpers ----------------
static size_t round_up(size_t x, size_t a) { return (x + a - 1) / a * a; }

static size_t parse_size(const char *s) {
    // supports: 123, 123K, 123M, 123G
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno != 0 || end == s) return 0;

    size_t mult = 1;
    if (end && *end) {
        char c = *end;
        if (c >= 'a' && c <= 'z') c -= 32;
        if (c == 'K') mult = 1024ULL;
        else if (c == 'M') mult = 1024ULL * 1024ULL;
        else if (c == 'G') mult = 1024ULL * 1024ULL * 1024ULL;
        else return 0;
    }
    return (size_t)(v * mult);
}

static const char *tier_memlock(size_t bytes) {
    static char buf[32];
    const size_t M = 1024ULL * 1024ULL;
    const size_t G = 1024ULL * 1024ULL * 1024ULL;

    size_t tiers[] = {16*M, 32*M, 64*M, 128*M, 256*M, 512*M, 1*G, 2*G, 4*G, 8*G};
    const char *names[] = {"16M","32M","64M","128M","256M","512M","1G","2G","4G","8G"};
    for (int i = 0; i < (int)(sizeof(tiers)/sizeof(tiers[0])); i++) {
        if (bytes <= tiers[i]) return names[i];
    }
    snprintf(buf, sizeof(buf), "%zuG+", (bytes + G - 1)/G);
    return buf;
}

static long tier_mapcount(long need) {
    long tiers[] = {65536, 131072, 262144, 524288, 1048576, 2097152, 4194304};
    for (int i = 0; i < (int)(sizeof(tiers)/sizeof(tiers[0])); i++) {
        if (need <= tiers[i]) return tiers[i];
    }
    return 8388608;
}

static int compute_rings_per_service(void) {
    switch (config.ring_model) {
        case 1: return config.threads_per_service > 0 ? config.threads_per_service : 1;
        case 2: return config.nic_queues > 0 ? config.nic_queues : 1;
        case 3: {
            long long t = (config.threads_per_service > 0) ? config.threads_per_service : 1;
            long long q = (config.nic_queues > 0) ? config.nic_queues : 1;
            long long prod = t * q;
            if (prod < 1) prod = 1;
            if (prod > MAX_RINGS_PER_SERVICE) prod = MAX_RINGS_PER_SERVICE;
            return (int)prod;
        }
        case 0:
        default:
            return config.rings_per_service > 0 ? config.rings_per_service : 1;
    }
}

// ------------- proc stats -------------
static void get_proc_stats(ProcStats *st) {
    memset(st, 0, sizeof(*st));

    struct rlimit r;
    if (getrlimit(RLIMIT_MEMLOCK, &r) == 0) {
        st->rlim_cur_kb = (r.rlim_cur == RLIM_INFINITY) ? -1 : (long)(r.rlim_cur / 1024);
        st->rlim_max_kb = (r.rlim_max == RLIM_INFINITY) ? -1 : (long)(r.rlim_max / 1024);
    }

    FILE *f = fopen("/proc/self/status", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "VmLck:", 6) == 0) sscanf(line + 6, "%ld", &st->vmlck_kb);
            else if (strncmp(line, "VmPin:", 6) == 0) sscanf(line + 6, "%ld", &st->vmpin_kb);
            else if (strncmp(line, "VmRSS:", 6) == 0) sscanf(line + 6, "%ld", &st->vmrss_kb);
        }
        fclose(f);
    }

    f = fopen("/proc/self/maps", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) st->vmas++;
        fclose(f);
    }
}

// ------------- centralized cleanup (prevents double free) -------------
static void destroy_instance(BigUringInstance *inst) {
    if (!inst) return;

    if (inst->fds_registered) {
        io_uring_unregister_files(&inst->ring);
        inst->fds_registered = 0;
    }

    if (inst->registered_fds) {
        for (int i = 0; i < inst->num_registered_fds; i++) {
            if (inst->registered_fds[i] >= 0) close(inst->registered_fds[i]);
        }
        free(inst->registered_fds);
        inst->registered_fds = NULL;
        inst->num_registered_fds = 0;
    }

    if (inst->buffers_registered) {
        io_uring_unregister_buffers(&inst->ring);
        inst->buffers_registered = 0;
    }

    if (inst->iovecs) {
        free(inst->iovecs);
        inst->iovecs = NULL;
    }

    // guards first
    if (inst->guards && inst->guard_sizes) {
        for (int i = 0; i < inst->num_buffers; i++) {
            if (inst->guards[i] && inst->guard_sizes[i] > 0) {
                munmap(inst->guards[i], inst->guard_sizes[i]);
                inst->guards[i] = NULL;
                inst->guard_sizes[i] = 0;
            }
        }
    }
    free(inst->guards);
    free(inst->guard_sizes);
    inst->guards = NULL;
    inst->guard_sizes = NULL;

    if (!config.vma_per_buffer) {
        if (inst->buffer_pool) {
            if (inst->buffers_locked) munlock(inst->buffer_pool, inst->buffer_pool_size);
            free(inst->buffer_pool);
            inst->buffer_pool = NULL;
            inst->buffer_pool_size = 0;
        }
    } else {
        if (inst->buffers && inst->buffer_sizes) {
            for (int i = 0; i < inst->num_buffers; i++) {
                if (inst->buffers[i] && inst->buffer_sizes[i] > 0) {
                    if (inst->buffers_locked) munlock(inst->buffers[i], inst->buffer_sizes[i]);
                    munmap(inst->buffers[i], inst->buffer_sizes[i]);
                    inst->buffers[i] = NULL;
                    inst->buffer_sizes[i] = 0;
                }
            }
        }
        free(inst->buffers);
        free(inst->buffer_sizes);
        inst->buffers = NULL;
        inst->buffer_sizes = NULL;
    }

    if (inst->ring_fd >= 0) {
        io_uring_queue_exit(&inst->ring);
        inst->ring_fd = -1;
    }
}

// ------------- create ring instance -------------
static int create_big_instance(BigUringInstance *inst, int ring_id) {
    memset(inst, 0, sizeof(*inst));
    inst->ring_id = ring_id;
    inst->ring_fd = -1;
    inst->num_buffers = config.num_buffers;

    struct io_uring_params params = {0};
    int ret = io_uring_queue_init_params(config.queue_depth, &inst->ring, &params);
    if (ret < 0) {
        inst->creation_failed = 1;
        inst->failure_errno = -ret;
        snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                 "io_uring_queue_init failed: %s", strerror(-ret));
        goto fail;
    }
    inst->ring_fd = inst->ring.ring_fd;

    inst->ring_mem =
        (config.queue_depth * 4) +
        (config.queue_depth * 2 * 16) +
        (config.queue_depth * 64) +
        (4096 * 3);

    inst->iovecs = calloc((size_t)config.num_buffers, sizeof(struct iovec));
    if (!inst->iovecs) {
        inst->creation_failed = 1;
        inst->failure_errno = errno;
        snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                 "calloc iovecs failed: %s", strerror(errno));
        goto fail;
    }

    const size_t page = 4096;
    const size_t buf_len = round_up(config.buffer_size, page);

    if (config.vma_per_buffer && config.guard_pages) {
        inst->guards = calloc((size_t)config.num_buffers, sizeof(void*));
        inst->guard_sizes = calloc((size_t)config.num_buffers, sizeof(size_t));
        if (!inst->guards || !inst->guard_sizes) {
            inst->creation_failed = 1;
            inst->failure_errno = errno;
            snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                     "calloc guard arrays failed: %s", strerror(errno));
            goto fail;
        }
    }

    if (!config.vma_per_buffer) {
        // pooled
        inst->buffer_pool_size = (size_t)config.num_buffers * buf_len;
        void *p = NULL;
        if (posix_memalign(&p, page, inst->buffer_pool_size) != 0) p = NULL;
        inst->buffer_pool = p;

        if (!inst->buffer_pool) {
            inst->creation_failed = 1;
            inst->failure_errno = errno;
            snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                     "posix_memalign failed for %zu bytes", inst->buffer_pool_size);
            goto fail;
        }
        memset(inst->buffer_pool, 0xAA, inst->buffer_pool_size);

        if (config.lock_memory) {
            if (mlock(inst->buffer_pool, inst->buffer_pool_size) < 0) {
                inst->creation_failed = 1;
                inst->failure_errno = errno;
                snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                         "mlock(pool %zu) failed: %s", inst->buffer_pool_size, strerror(errno));
                goto fail;
            }
            inst->buffers_locked = 1;
        }

        for (int i = 0; i < config.num_buffers; i++) {
            inst->iovecs[i].iov_base = (char*)inst->buffer_pool + ((size_t)i * buf_len);
            inst->iovecs[i].iov_len  = buf_len;
        }
        inst->buffer_mem = inst->buffer_pool_size;

    } else {
        // mmap-per-buffer
        inst->buffers = calloc((size_t)config.num_buffers, sizeof(void*));
        inst->buffer_sizes = calloc((size_t)config.num_buffers, sizeof(size_t));
        if (!inst->buffers || !inst->buffer_sizes) {
            inst->creation_failed = 1;
            inst->failure_errno = errno;
            snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                     "calloc buffer arrays failed: %s", strerror(errno));
            goto fail;
        }

        for (int i = 0; i < config.num_buffers; i++) {
            void *b = mmap(NULL, buf_len, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
            if (b == MAP_FAILED) {
                inst->creation_failed = 1;
                inst->failure_errno = errno;
                snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                         "mmap buffer %d (%zu) failed: %s", i, buf_len, strerror(errno));
                goto fail;
            }
            memset(b, 0xAA, buf_len);

            if (config.lock_memory) {
                if (mlock(b, buf_len) < 0) {
                    munmap(b, buf_len);
                    inst->creation_failed = 1;
                    inst->failure_errno = errno;
                    snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                             "mlock buffer %d (%zu) failed: %s", i, buf_len, strerror(errno));
                    goto fail;
                }
                inst->buffers_locked = 1;
            }

            inst->buffers[i] = b;
            inst->buffer_sizes[i] = buf_len;
            inst->iovecs[i].iov_base = b;
            inst->iovecs[i].iov_len  = buf_len;
            inst->buffer_mem += buf_len;

            // Optional guard page to raise VMA pressure
            if (config.guard_pages) {
                void *g = mmap(NULL, page, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
                if (g != MAP_FAILED) {
                    inst->guards[i] = g;
                    inst->guard_sizes[i] = page;
                } else {
                    // not fatal; still proceed (we’ll just have fewer VMAs)
                }
            }
        }
    }

    // register buffers (can fail due to MEMLOCK/pin accounting)
    ret = io_uring_register_buffers(&inst->ring, inst->iovecs, config.num_buffers);
    if (ret < 0) {
        inst->creation_failed = 1;
        inst->failure_errno = -ret;
        snprintf(inst->failure_reason, sizeof(inst->failure_reason),
                 "io_uring_register_buffers failed: %s", strerror(-ret));
        goto fail;
    }
    inst->buffers_registered = 1;

    // optional fixed FDs
    if (config.num_registered_fds > 0) {
        inst->registered_fds = calloc((size_t)config.num_registered_fds, sizeof(int));
        inst->num_registered_fds = config.num_registered_fds;
        if (inst->registered_fds) {
            for (int i = 0; i < config.num_registered_fds; i++) {
                inst->registered_fds[i] = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
                if (inst->registered_fds[i] < 0) inst->registered_fds[i] = -1;
            }
            ret = io_uring_register_files(&inst->ring, inst->registered_fds, config.num_registered_fds);
            if (ret == 0) inst->fds_registered = 1;
        }
    }

    inst->total_mem = inst->ring_mem + inst->buffer_mem;
    return 0;

fail:
    destroy_instance(inst);
    return -1;
}

// ------------- recommendations -------------
static void print_recommendations_tables(void) {
    const int rings_base = compute_rings_per_service();
    const size_t page = 4096;
    const size_t buf_len = round_up(config.buffer_size, page);

    const size_t pinned_per_ring_buffers = (size_t)config.num_buffers * buf_len;
    const size_t ring_overhead =
        (config.queue_depth * 4) +
        (config.queue_depth * 2 * 16) +
        (config.queue_depth * 64) +
        (4096 * 3);
    const size_t pinned_per_ring_total = pinned_per_ring_buffers + ring_overhead;

    // VMA estimate is only a planning number; kernel may merge VMAs.
    const int vmas_per_ring_est =
        4 + (config.vma_per_buffer ? config.num_buffers : 1) + (config.guard_pages ? config.num_buffers : 0);
    const long base_vmas = 65536;

    printf("\nRECOMMENDATIONS (TABULATED)\n");

    // A) scaling rings/service
    printf("\nA) Scale rings per service (services fixed at %d)\n", config.num_services);
    printf("┌───────────────┬───────────────┬───────────────┬─────────────────┬──────────────────┐\n");
    printf("│ Rings/service  │ Pinned/service │ Host pinned    │ LimitMEMLOCK     │ vm.max_map_count │\n");
    printf("├───────────────┼───────────────┼───────────────┼─────────────────┼──────────────────┤\n");

    const int ring_targets[] = {1, 2, 4, 8, 16, 32};
    for (int i = 0; i < (int)(sizeof(ring_targets)/sizeof(ring_targets[0])); i++) {
        const int r = ring_targets[i];
        const size_t pinned_service = (size_t)r * pinned_per_ring_total;
        const size_t pinned_service_margin = (size_t)(pinned_service * config.safety_factor);
        const size_t pinned_host = (size_t)config.num_services * pinned_service;

        const long need_vmas = base_vmas + (long)r * (long)vmas_per_ring_est;
        const long rec_map = tier_mapcount((long)(need_vmas * 1.25));

        printf("│ %12d  │ %12.1f MiB │ %11.2f GiB │ %-15s │ %16ld │\n",
               r,
               pinned_service / (1024.0 * 1024.0),
               pinned_host / (1024.0 * 1024.0 * 1024.0),
               tier_memlock(pinned_service_margin),
               rec_map);
    }
    printf("└───────────────┴───────────────┴───────────────┴─────────────────┴──────────────────┘\n");

    // B) scaling services count
    printf("\nB) Scale services count (rings/service fixed at %d)\n", rings_base);
    printf("┌───────────┬───────────────┬─────────────────┬──────────────────┐\n");
    printf("│ Services  │ Host pinned    │ LimitMEMLOCK     │ vm.max_map_count │\n");
    printf("├───────────┼───────────────┼─────────────────┼──────────────────┤\n");

    const size_t pinned_service = (size_t)rings_base * pinned_per_ring_total;
    const size_t pinned_service_margin = (size_t)(pinned_service * config.safety_factor);
    const long need_vmas = base_vmas + (long)rings_base * (long)vmas_per_ring_est;
    const long rec_map = tier_mapcount((long)(need_vmas * 1.25));

    const int svc_targets[] = {1, 2, 4, 6, 8, 12, 16, 24};
    for (int i = 0; i < (int)(sizeof(svc_targets)/sizeof(svc_targets[0])); i++) {
        const int s = svc_targets[i];
        const size_t pinned_host = (size_t)s * pinned_service;

        printf("│ %8d  │ %11.2f GiB │ %-15s │ %16ld │\n",
               s,
               pinned_host / (1024.0 * 1024.0 * 1024.0),
               tier_memlock(pinned_service_margin),
               rec_map);
    }
    printf("└───────────┴───────────────┴─────────────────┴──────────────────┘\n");
}

// ------------- child: run one service -------------
static int run_one_service(int service_id, int write_fd) {
    int setrc = 0, seterr = 0;

    if (config.set_memlock_limit) {
        struct rlimit r;
        r.rlim_cur = config.memlock_limit_bytes;
        r.rlim_max = config.memlock_limit_bytes;
        setrc = setrlimit(RLIMIT_MEMLOCK, &r);
        if (setrc != 0) seterr = errno;
    }

    const int rings = compute_rings_per_service();
    BigUringInstance *arr = calloc((size_t)rings, sizeof(BigUringInstance));
    if (!arr) {
        ProcStats st; get_proc_stats(&st);
        SimMsg msg = {0};
        msg.magic = SIMMSG_MAGIC;
        msg.type = MSG_FINAL;
        msg.service_id = (uint16_t)service_id;
        msg.rings_requested = rings;
        msg.ring_index = -1;
        msg.created = 0;
        msg.failed = rings;
        msg.vmlck_kb = st.vmlck_kb;
        msg.vmpin_kb = st.vmpin_kb;
        msg.vmrss_kb = st.vmrss_kb;
        msg.vmas = st.vmas;
        msg.rlim_cur_kb = st.rlim_cur_kb;
        msg.rlim_max_kb = st.rlim_max_kb;
        msg.setrlimit_rc = setrc;
        msg.setrlimit_errno = seterr;
        msg.first_errno = errno;
        snprintf(msg.first_failure, sizeof(msg.first_failure), "calloc rings failed: %s", strerror(errno));
        (void)write(write_fd, &msg, sizeof(msg));
        return 1;
    }

    int created = 0, failed = 0;
    int first_errno = 0;
    char first_failure[160] = {0};

    for (int i = 0; i < rings; i++) {
        int rc = create_big_instance(&arr[i], i);
        if (rc == 0) {
            created++;
        } else {
            failed++;
            if (first_failure[0] == '\0') {
                first_errno = arr[i].failure_errno ? arr[i].failure_errno : errno;
                snprintf(first_failure, sizeof(first_failure), "%s", arr[i].failure_reason);
            }
            if (failed >= 3 && created < failed) break;
        }

        if (config.progress_every > 0 && ((i + 1) % config.progress_every == 0)) {
            ProcStats st; get_proc_stats(&st);
            SimMsg msg = {0};
            msg.magic = SIMMSG_MAGIC;
            msg.type = MSG_PROGRESS;
            msg.service_id = (uint16_t)service_id;
            msg.rings_requested = rings;
            msg.ring_index = i;
            msg.created = created;
            msg.failed = failed;
            msg.vmlck_kb = st.vmlck_kb;
            msg.vmpin_kb = st.vmpin_kb;
            msg.vmrss_kb = st.vmrss_kb;
            msg.vmas = st.vmas;
            msg.rlim_cur_kb = st.rlim_cur_kb;
            msg.rlim_max_kb = st.rlim_max_kb;
            msg.setrlimit_rc = setrc;
            msg.setrlimit_errno = seterr;
            msg.first_errno = first_errno;
            if (first_failure[0]) snprintf(msg.first_failure, sizeof(msg.first_failure), "%s", first_failure);
            (void)write(write_fd, &msg, sizeof(msg));
        }
    }

    ProcStats st; get_proc_stats(&st);
    SimMsg final = {0};
    final.magic = SIMMSG_MAGIC;
    final.type = MSG_FINAL;
    final.service_id = (uint16_t)service_id;
    final.rings_requested = rings;
    final.ring_index = -1;
    final.created = created;
    final.failed = failed;
    final.vmlck_kb = st.vmlck_kb;
    final.vmpin_kb = st.vmpin_kb;
    final.vmrss_kb = st.vmrss_kb;
    final.vmas = st.vmas;
    final.rlim_cur_kb = st.rlim_cur_kb;
    final.rlim_max_kb = st.rlim_max_kb;
    final.setrlimit_rc = setrc;
    final.setrlimit_errno = seterr;
    final.first_errno = first_errno;
    if (first_failure[0]) snprintf(final.first_failure, sizeof(final.first_failure), "%s", first_failure);
    (void)write(write_fd, &final, sizeof(final));

    for (int i = 0; i < rings; i++) destroy_instance(&arr[i]);
    free(arr);

    return (failed > 0) ? 1 : 0;
}

// ------------- parent printing -------------
static void print_interactive_table(
    int finished, int total,
    const int *req, const int *created, const int *failed,
    const long *vmlck, const long *vmpin, const long *rss, const long *vmas,
    const long *rlim_cur, const long *rlim_max,
    const int *setrc, const int *seterr,
    char (*first_fail)[160]
) {
    printf("\033[H\033[J");
    printf("=== REALTIME PROGRESS (%d/%d services finished) ===\n\n", finished, total);

    printf("┌────┬──────────┬────────┬────────┬──────────┬──────────┬──────────┬──────┬───────────────┬───────────────┬──────────┐\n");
    printf("│svc │ rings_req │created │ failed │ VmLck MiB│ VmPin MiB│ VmRSS MiB│ VMAs │ memlock_curKB │ memlock_maxKB │ setrlim  │\n");
    printf("├────┼──────────┼────────┼────────┼──────────┼──────────┼──────────┼──────┼───────────────┼───────────────┼──────────┤\n");

    for (int i = 0; i < total; i++) {
        char sr[12];
        if (setrc[i] == 0) snprintf(sr, sizeof(sr), "ok");
        else snprintf(sr, sizeof(sr), "err:%d", seterr[i]);

        printf("│%3d │%9d │%7d │%7d │%9.1f │%9.1f │%9.1f │%5ld │%14ld │%14ld │ %-8s│\n",
               i, req[i], created[i], failed[i],
               vmlck[i]/1024.0, vmpin[i]/1024.0, rss[i]/1024.0, vmas[i],
               rlim_cur[i], rlim_max[i], sr);
        if (first_fail[i][0]) {
            printf("│    └─ first failure: %s\n", first_fail[i]);
        }
    }

    printf("└────┴──────────┴────────┴────────┴──────────┴──────────┴──────────┴──────┴───────────────┴───────────────┴──────────┘\n\n");
    fflush(stdout);
}

static void print_log_header_once(void) {
    printf("type svc rings_req created failed  VmLckMiB  VmPinMiB  VmRSSMiB   VMAs  memlock_curKB memlock_maxKB setrlim\n");
    printf("---- --- --------- ------- ------ --------- --------- --------- ------ ------------- ------------- ------\n");
}

static void print_log_row(char type, int svc, const SimMsg *m) {
    char sr[12];
    if (m->setrlimit_rc == 0) snprintf(sr, sizeof(sr), "ok");
    else snprintf(sr, sizeof(sr), "err:%d", m->setrlimit_errno);

    printf(" %c   %3d %9d %7d %6d %9.1f %9.1f %9.1f %6ld %13ld %13ld %6s\n",
           type, svc, m->rings_requested, m->created, m->failed,
           m->vmlck_kb/1024.0, m->vmpin_kb/1024.0, m->vmrss_kb/1024.0, m->vmas,
           m->rlim_cur_kb, m->rlim_max_kb, sr);

    if (m->first_failure[0]) {
        printf("      first failure: %s\n", m->first_failure);
    }
}

// ------------- usage -------------
static void usage(const char *p) {
    printf("Usage: %s [options]\n\n", p);
    printf("Services:\n");
    printf("  -P NUM      services/processes (default 1)\n\n");
    printf("Rings/service model:\n");
    printf("  -m MODE     0=direct(-n), 1=threads(-T), 2=queues(-Q), 3=threads*queues (default 0)\n");
    printf("  -n NUM      rings/service (model 0; default 20)\n");
    printf("  -T NUM      threads/service (model 1/3)\n");
    printf("  -Q NUM      NIC queues (model 2/3)\n\n");
    printf("Per-ring config:\n");
    printf("  -q DEPTH    queue depth (default 512)\n");
    printf("  -b NUM      buffers per ring (default 128)\n");
    printf("  -s BYTES    buffer size bytes (default 16384)\n");
    printf("  -f NUM      fixed fds per ring (default 64)\n");
    printf("  -L          disable mlock (VmLck likely 0; VmPin shows pinned)\n");
    printf("  -M          mmap-per-buffer mode (more VMAs)\n");
    printf("  -G          add guard page VMA per buffer (stronger VMA pressure)\n\n");
    printf("Memlock emulation:\n");
    printf("  -k SIZE     setrlimit MEMLOCK per service (e.g. 512M, 1G). May fail if hard limit smaller.\n\n");
    printf("Reporting:\n");
    printf("  -S FACTOR   safety factor (default 1.50)\n");
    printf("  -p N        progress update every N rings (default 1)\n");
    printf("  -I          interactive redraw table\n");
    printf("  -v          verbose\n");
    printf("  -h          help\n");
}

int main(int argc, char **argv) {
    memset(&config, 0, sizeof(config));
    config.num_services = 1;
    config.ring_model = 0;
    config.rings_per_service = 20;
    config.threads_per_service = 1;
    config.nic_queues = 1;
    config.queue_depth = 512;
    config.num_buffers = 128;
    config.buffer_size = 16384;
    config.num_registered_fds = 64;
    config.lock_memory = 1;
    config.vma_per_buffer = 0;
    config.guard_pages = 0;
    config.set_memlock_limit = 0;
    config.memlock_limit_bytes = 0;
    config.safety_factor = 1.5;
    config.progress_every = 1;
    config.interactive = 0;
    config.verbose = 0;

    int opt;
    while ((opt = getopt(argc, argv, "P:m:n:T:Q:q:b:s:f:k:S:p:LMIvGh")) != -1) {
        switch (opt) {
            case 'P': config.num_services = atoi(optarg); if (config.num_services < 1) config.num_services = 1; break;
            case 'm': config.ring_model = atoi(optarg); if (config.ring_model < 0 || config.ring_model > 3) config.ring_model = 0; break;
            case 'n': config.rings_per_service = atoi(optarg); if (config.rings_per_service < 1) config.rings_per_service = 1; break;
            case 'T': config.threads_per_service = atoi(optarg); if (config.threads_per_service < 1) config.threads_per_service = 1; break;
            case 'Q': config.nic_queues = atoi(optarg); if (config.nic_queues < 1) config.nic_queues = 1; break;
            case 'q': config.queue_depth = atoi(optarg); if (config.queue_depth < 16) config.queue_depth = 16; if (config.queue_depth > 4096) config.queue_depth = 4096; break;
            case 'b': config.num_buffers = atoi(optarg); if (config.num_buffers < 1) config.num_buffers = 1; break;
            case 's': config.buffer_size = (size_t)atoll(optarg); if (config.buffer_size < 4096) config.buffer_size = 4096; break;
            case 'f': config.num_registered_fds = atoi(optarg); if (config.num_registered_fds < 0) config.num_registered_fds = 0; break;

            case 'k': {
                size_t v = parse_size(optarg);
                if (!v) { fprintf(stderr, "Invalid -k size: %s\n", optarg); return 2; }
                config.set_memlock_limit = 1;
                config.memlock_limit_bytes = v;
            } break;

            case 'S': config.safety_factor = atof(optarg); if (config.safety_factor < 1.0) config.safety_factor = 1.0; break;
            case 'p': config.progress_every = atoi(optarg); if (config.progress_every < 1) config.progress_every = 1; break;
            case 'L': config.lock_memory = 0; break;
            case 'M': config.vma_per_buffer = 1; break;
            case 'G': config.guard_pages = 1; break;
            case 'I': config.interactive = 1; break;
            case 'v': config.verbose = 1; break;

            case 'h':
            default:
                usage(argv[0]);
                return (opt == 'h') ? 0 : 1;
        }
    }

    printf("\n=== CONFIG ===\n");
    printf("services=%d | ring_model=%d | rings/service=%d\n", config.num_services, config.ring_model, compute_rings_per_service());
    printf("queue_depth=%d | buffers=%d | buffer_size=%zu | mlock=%s | vma_mode=%s | guard=%s\n",
           config.queue_depth, config.num_buffers, config.buffer_size,
           config.lock_memory ? "on" : "off",
           config.vma_per_buffer ? "mmap-per-buffer" : "pooled",
           config.guard_pages ? "on" : "off");
    if (config.set_memlock_limit) {
        printf("requested setrlimit MEMLOCK: %zu bytes (%s)\n",
               config.memlock_limit_bytes, tier_memlock(config.memlock_limit_bytes));
    }
    printf("\n");

    print_recommendations_tables();
    if (config.interactive) {
        printf("\n[NOTE] -I clears the screen while running.\n\n");
        fflush(stdout);
        usleep(250000);
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) { perror("pipe"); return 2; }

    for (int s = 0; s < config.num_services; s++) {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); return 2; }
        if (pid == 0) {
            close(pipefd[0]);
            int rc = run_one_service(s, pipefd[1]);
            close(pipefd[1]);
            _exit(rc ? 1 : 0);
        }
    }
    close(pipefd[1]);

    const int N = config.num_services;
    int  *req      = calloc((size_t)N, sizeof(int));
    int  *created  = calloc((size_t)N, sizeof(int));
    int  *failed   = calloc((size_t)N, sizeof(int));
    long *vmlck    = calloc((size_t)N, sizeof(long));
    long *vmpin    = calloc((size_t)N, sizeof(long));
    long *rss      = calloc((size_t)N, sizeof(long));
    long *vmas     = calloc((size_t)N, sizeof(long));
    long *rlim_cur = calloc((size_t)N, sizeof(long));
    long *rlim_max = calloc((size_t)N, sizeof(long));
    int  *setrc    = calloc((size_t)N, sizeof(int));
    int  *seterr   = calloc((size_t)N, sizeof(int));
    char (*first_fail)[160] = calloc((size_t)N, 160);

    if (!req||!created||!failed||!vmlck||!vmpin||!rss||!vmas||!rlim_cur||!rlim_max||!setrc||!seterr||!first_fail) {
        perror("calloc");
        return 2;
    }

    int finals = 0;
    int printed_log_header = 0;

    while (finals < N) {
        SimMsg msg;
        ssize_t r = read(pipefd[0], &msg, sizeof(msg));
        if (r == 0) break;
        if (r < 0) { perror("read"); break; }
        if (r != (ssize_t)sizeof(msg)) continue;
        if (msg.magic != SIMMSG_MAGIC) continue;

        int s = (int)msg.service_id;
        if (s < 0 || s >= N) continue;

        req[s]     = msg.rings_requested;
        created[s] = msg.created;
        failed[s]  = msg.failed;

        vmlck[s]    = msg.vmlck_kb;
        vmpin[s]    = msg.vmpin_kb;
        rss[s]      = msg.vmrss_kb;
        vmas[s]     = msg.vmas;
        rlim_cur[s] = msg.rlim_cur_kb;
        rlim_max[s] = msg.rlim_max_kb;
        setrc[s]    = msg.setrlimit_rc;
        seterr[s]   = msg.setrlimit_errno;

        if (msg.first_failure[0] && first_fail[s][0] == '\0') {
            snprintf(first_fail[s], 160, "%s", msg.first_failure);
        }

        if (msg.type == MSG_FINAL) finals++;

        if (config.interactive) {
            print_interactive_table(finals, N, req, created, failed, vmlck, vmpin, rss, vmas, rlim_cur, rlim_max, setrc, seterr, first_fail);
        } else {
            if (!printed_log_header) { print_log_header_once(); printed_log_header = 1; }
            print_log_row((msg.type == MSG_FINAL) ? 'F' : 'P', s, &msg);
        }
    }

    close(pipefd[0]);
    for (int i = 0; i < N; i++) { int st=0; (void)wait(&st); }

    // Final summary
    const size_t page = 4096;
    const size_t buf_len = round_up(config.buffer_size, page);
    const size_t pinned_per_ring_buffers = (size_t)config.num_buffers * buf_len;
    const size_t ring_overhead =
        (config.queue_depth * 4) +
        (config.queue_depth * 2 * 16) +
        (config.queue_depth * 64) +
        (4096 * 3);
    const size_t pinned_per_ring_total = pinned_per_ring_buffers + ring_overhead;

    int total_created = 0, total_failed = 0;
    size_t est_pinned_total = 0;
    long sum_vmlck = 0, sum_vmpin = 0, sum_rss = 0, max_vmas = 0;

    for (int i = 0; i < N; i++) {
        total_created += created[i];
        total_failed  += failed[i];
        est_pinned_total += (size_t)created[i] * pinned_per_ring_total;
        sum_vmlck += vmlck[i];
        sum_vmpin += vmpin[i];
        sum_rss   += rss[i];
        if (vmas[i] > max_vmas) max_vmas = vmas[i];
    }

    printf("\n=== FINAL RESULTS (PER SERVICE) ===\n");
    printf("┌────┬──────────┬────────┬────────┬──────────┬──────────┬──────────┬──────┬───────────────┬───────────────┬──────────┐\n");
    printf("│svc │ rings_req │created │ failed │ VmLck MiB│ VmPin MiB│ VmRSS MiB│ VMAs │ memlock_curKB │ memlock_maxKB │ setrlim  │\n");
    printf("├────┼──────────┼────────┼────────┼──────────┼──────────┼──────────┼──────┼───────────────┼───────────────┼──────────┤\n");
    for (int i = 0; i < N; i++) {
        char sr[12];
        if (setrc[i] == 0) snprintf(sr, sizeof(sr), "ok");
        else snprintf(sr, sizeof(sr), "err:%d", seterr[i]);

        printf("│%3d │%9d │%7d │%7d │%9.1f │%9.1f │%9.1f │%5ld │%14ld │%14ld │ %-8s│\n",
               i, req[i], created[i], failed[i],
               vmlck[i]/1024.0, vmpin[i]/1024.0, rss[i]/1024.0, vmas[i],
               rlim_cur[i], rlim_max[i], sr);

        if (first_fail[i][0]) {
            printf("│    └─ first failure: %s\n", first_fail[i]);
        }
    }
    printf("└────┴──────────┴────────┴────────┴──────────┴──────────┴──────────┴──────┴───────────────┴───────────────┴──────────┘\n");

    printf("\n=== FINAL SUMMARY ===\n");
    printf("total rings created=%d failed=%d\n", total_created, total_failed);
    printf("estimated pinned total (all svcs): %.2f GiB\n", est_pinned_total / (1024.0*1024.0*1024.0));
    printf("kernel VmLck sum (all svcs):       %.2f GiB\n", sum_vmlck / (1024.0*1024.0));
    if (sum_vmpin > 0) printf("kernel VmPin sum (all svcs):       %.2f GiB\n", sum_vmpin / (1024.0*1024.0));
    printf("kernel VmRSS sum (all svcs):       %.2f GiB\n", sum_rss / (1024.0*1024.0));
    printf("max VMAs in a single svc:          %ld\n", max_vmas);

    printf("\n=== RECOMMENDATIONS (REPRINT) ===\n");
    print_recommendations_tables();

    free(req); free(created); free(failed);
    free(vmlck); free(vmpin); free(rss); free(vmas);
    free(rlim_cur); free(rlim_max);
    free(setrc); free(seterr);
    free(first_fail);

    return (total_failed > 0) ? 1 : 0;
}
