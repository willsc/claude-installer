/*
 * io_uring Memory Simulator & Tuning Recommender
 *
 * Simulates io_uring kernel structures being placed in memory and provides
 * Linux tuning recommendations for RLIMIT_MEMLOCK and vm.max_map_count.
 *
 * Features a real-time terminal animation showing:
 *   - SQ ring entries being populated with SQEs (submissions)
 *   - CQ ring entries being populated with CQEs (completions)
 *   - Live memory address map as structures are placed
 *   - Per-ring instance creation when running multiple rings
 *
 * Build:
 *   gcc -o io_uring_sim io_uring_sim.c -lm
 *
 * Usage:
 *   ./io_uring_sim [--interactive | --batch <args...>]
 *   Add --no-anim to skip the animation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <getopt.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>

/* ── io_uring constants (Linux 6.x) ────────────────────────────────── */

#define SQE_SIZE            64      /* sizeof(struct io_uring_sqe) */
#define CQE_SIZE_NORMAL     16      /* sizeof(struct io_uring_cqe) */
#define CQE_SIZE_CQE32      32      /* with IORING_SETUP_CQE32 */
#define RING_HEADER_BYTES    40      /* rough overhead per ring (params, padding) */
#define PAGE_SIZE           4096
#define DEFAULT_CQ_FACTOR    2      /* kernel default: CQ entries = 2 * SQ entries */

#define KERN_MAX_SQ_ENTRIES  32768
#define KERN_MAX_CQ_ENTRIES  (2 * KERN_MAX_SQ_ENTRIES)

/* ── ANSI escape helpers ───────────────────────────────────────────── */

#define ESC         "\033["
#define RESET       ESC "0m"
#define BOLD        ESC "1m"
#define DIM         ESC "2m"

/* Foreground colors */
#define FG_RED      ESC "31m"
#define FG_GREEN    ESC "32m"
#define FG_YELLOW   ESC "33m"
#define FG_BLUE     ESC "34m"
#define FG_MAGENTA  ESC "35m"
#define FG_CYAN     ESC "36m"
#define FG_GRAY     ESC "90m"
#define FG_BRED     ESC "91m"
#define FG_BGREEN   ESC "92m"
#define FG_BYELLOW  ESC "93m"
#define FG_BBLUE    ESC "94m"
#define FG_BMAGENTA ESC "95m"
#define FG_BCYAN    ESC "96m"
#define FG_BWHITE   ESC "97m"

#define CURSOR_UP(n)    printf(ESC "%dA", (n))
#define CURSOR_HIDE     printf(ESC "?25l")
#define CURSOR_SHOW     printf(ESC "?25h")

/* ── Helpers ───────────────────────────────────────────────────────── */

static uint64_t next_power_of_2(uint64_t v)
{
    if (v == 0) return 1;
    v--;
    v |= v >> 1;  v |= v >> 2;  v |= v >> 4;
    v |= v >> 8;  v |= v >> 16; v |= v >> 32;
    return v + 1;
}

static uint64_t page_align(uint64_t bytes)
{
    return (bytes + PAGE_SIZE - 1) & ~((uint64_t)PAGE_SIZE - 1);
}

static const char *human_bytes(uint64_t bytes, char *buf, size_t bufsz)
{
    const char *units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    int u = 0;
    double val = (double)bytes;
    while (val >= 1024.0 && u < 4) { val /= 1024.0; u++; }
    snprintf(buf, bufsz, "%.2f %s", val, units[u]);
    return buf;
}

static uint64_t parse_ram(const char *str)
{
    char *end;
    double val = strtod(str, &end);
    if (val <= 0) return 0;
    while (*end == ' ') end++;
    uint64_t multiplier = 1;
    if (*end) {
        switch (*end) {
        case 'K': case 'k': multiplier = 1024ULL; break;
        case 'M': case 'm': multiplier = 1024ULL * 1024; break;
        case 'G': case 'g': multiplier = 1024ULL * 1024 * 1024; break;
        case 'T': case 't': multiplier = 1024ULL * 1024 * 1024 * 1024; break;
        default:
            fprintf(stderr, "Warning: unknown suffix '%c', assuming bytes\n", *end);
        }
    }
    return (uint64_t)(val * (double)multiplier);
}

static void msleep(int ms)
{
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static int get_term_width(void)
{
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0)
        return w.ws_col;
    return 80;
}

/* ── Simulated opcode / result names ───────────────────────────────── */

static const char *sqe_opcodes[] = {
    "READV",  "WRITEV",   "FSYNC",    "READ_FIXED",  "WRITE_FIXED",
    "SENDMSG","RECVMSG",  "ACCEPT",   "CONNECT",     "POLL_ADD",
    "OPENAT", "CLOSE",    "STATX",    "FADVISE",     "MADVISE",
    "SEND",   "RECV",     "SPLICE",   "TEE",         "SHUTDOWN",
    "RENAMEAT","UNLINKAT", "MKDIRAT",  "SYMLINKAT",   "LINKAT",
    "TIMEOUT","TIMEOUT_REMOVE","NOP",  "ASYNC_CANCEL","PROVIDE_BUFFERS",
};
#define NUM_OPCODES (sizeof(sqe_opcodes) / sizeof(sqe_opcodes[0]))

static const char *cqe_results[] = {
    "OK:0",  "OK:4096", "OK:8192", "OK:512", "OK:1024",
    "OK:16384", "OK:2048", "OK:256", "ERR:-11", "ERR:-5",
    "OK:0",  "OK:32768", "OK:65536", "ERR:-9", "OK:128",
};
#define NUM_CQE_RESULTS (sizeof(cqe_results) / sizeof(cqe_results[0]))

/* ── Per-ring memory calculation ───────────────────────────────────── */

typedef struct {
    uint32_t sq_entries;
    uint32_t cq_entries;
    int      cqe32;
    uint64_t registered_bufs;
    uint32_t registered_files;
} ring_config_t;

typedef struct {
    uint64_t sq_ring_bytes;
    uint64_t cq_ring_bytes;
    uint64_t sqe_array_bytes;
    uint64_t reg_buf_bytes;
    uint64_t reg_file_bytes;
    uint64_t total_bytes;
    uint32_t mmap_regions;
    uint32_t sq_actual;
    uint32_t cq_actual;
} ring_memory_t;

static ring_memory_t calc_ring_memory(const ring_config_t *cfg)
{
    ring_memory_t m = {0};
    uint32_t sq = (uint32_t)next_power_of_2(cfg->sq_entries);
    uint32_t cq = (uint32_t)next_power_of_2(cfg->cq_entries);
    if (sq > KERN_MAX_SQ_ENTRIES) sq = KERN_MAX_SQ_ENTRIES;
    if (cq < sq * DEFAULT_CQ_FACTOR) cq = (uint32_t)next_power_of_2(sq * DEFAULT_CQ_FACTOR);
    if (cq > KERN_MAX_CQ_ENTRIES) cq = KERN_MAX_CQ_ENTRIES;
    m.sq_actual = sq;
    m.cq_actual = cq;
    uint32_t cqe_sz = cfg->cqe32 ? CQE_SIZE_CQE32 : CQE_SIZE_NORMAL;
    m.sq_ring_bytes   = page_align((uint64_t)sq * sizeof(uint32_t) + RING_HEADER_BYTES);
    m.cq_ring_bytes   = page_align((uint64_t)cq * cqe_sz + RING_HEADER_BYTES);
    m.sqe_array_bytes = page_align((uint64_t)sq * SQE_SIZE);
    m.reg_buf_bytes   = page_align(cfg->registered_bufs);
    m.reg_file_bytes  = page_align((uint64_t)cfg->registered_files * 8);
    m.total_bytes = m.sq_ring_bytes + m.cq_ring_bytes + m.sqe_array_bytes
                  + m.reg_buf_bytes + m.reg_file_bytes;
    m.mmap_regions = 2;
    if (cfg->registered_bufs > 0) m.mmap_regions += 1;
    if (cfg->registered_files > 0) m.mmap_regions += 1;
    return m;
}

/* ── Tuning ────────────────────────────────────────────────────────── */

typedef struct {
    uint64_t total_locked_mem;
    uint64_t memlock_limit;
    uint64_t max_map_count;
    uint32_t total_mmap_regions;
    double   ram_usage_pct;
} tuning_t;

static tuning_t calc_tuning(const ring_memory_t *per_ring, uint32_t num_rings,
                             uint64_t total_ram)
{
    tuning_t t = {0};
    t.total_locked_mem   = (uint64_t)per_ring->total_bytes * num_rings;
    t.total_mmap_regions = per_ring->mmap_regions * num_rings;
    t.memlock_limit      = page_align((uint64_t)((double)t.total_locked_mem * 1.2));
    uint64_t base_vmas = 1024;
    uint64_t vmas_per_ring = (uint64_t)per_ring->mmap_regions + 2;
    t.max_map_count = base_vmas + vmas_per_ring * num_rings;
    if (t.max_map_count < 65530) t.max_map_count = 65530;
    t.ram_usage_pct = (double)t.total_locked_mem / (double)total_ram * 100.0;
    return t;
}

/* ══════════════════════════════════════════════════════════════════════
 *  REAL-TIME RING VISUALIZATION
 * ══════════════════════════════════════════════════════════════════════ */

typedef struct {
    const char *name;
    uint64_t    addr;
    uint64_t    size;
    const char *color;
    int         allocated;
} mem_region_t;

/*
 * Draws one complete animation frame (all elements), returns how many
 * lines were printed so we can CURSOR_UP to overwrite on next frame.
 */
static int draw_frame(
    /* SQ state */
    uint32_t sq_total, uint32_t sq_filled, int sq_pending,
    const char *sq_detail,
    /* CQ state */
    uint32_t cq_total, uint32_t cq_filled, int cq_pending,
    const char *cq_detail,
    /* Memory map */
    mem_region_t *regions, int nregions,
    uint64_t cumulative_locked, uint64_t total_ram,
    int ring_idx, int total_rings,
    /* Visual config */
    int vis_slots, int cqe_sz,
    uint64_t sq_addr, uint64_t cq_addr)
{
    int lines = 0;
    char buf[64], buf2[64];
    int tw = get_term_width();
    int map_bar_w = tw - 30;
    if (map_bar_w < 20) map_bar_w = 20;
    if (map_bar_w > 80) map_bar_w = 80;

    /* ── SQ Ring Bar ── */
    printf("  " BOLD FG_BCYAN "SQ " RESET DIM "0x%012lx " RESET DIM "|" RESET,
           (unsigned long)sq_addr);
    for (int i = 0; i < vis_slots; i++) {
        uint32_t idx = (uint32_t)((uint64_t)i * sq_total / vis_slots);
        if ((int)idx == sq_pending)
            printf(FG_BCYAN "\xe2\x96\x93" RESET);   /* ▓ */
        else if (idx < sq_filled)
            printf(FG_BCYAN "\xe2\x96\x88" RESET);   /* █ */
        else
            printf(FG_GRAY "\xe2\x96\x91" RESET);    /* ░ */
    }
    printf(DIM "|" RESET);
    human_bytes((uint64_t)sq_filled * SQE_SIZE, buf, sizeof(buf));
    printf(" " FG_BCYAN "%u/%u" RESET " (%s)" ESC "K\n", sq_filled, sq_total, buf);
    lines++;

    /* SQ detail line */
    printf("  %s" ESC "K\n", sq_detail);
    lines++;

    printf("\n");
    lines++;

    /* ── CQ Ring Bar ── */
    printf("  " BOLD FG_BGREEN "CQ " RESET DIM "0x%012lx " RESET DIM "|" RESET,
           (unsigned long)cq_addr);
    for (int i = 0; i < vis_slots; i++) {
        uint32_t idx = (uint32_t)((uint64_t)i * cq_total / vis_slots);
        if ((int)idx == cq_pending)
            printf(FG_BGREEN "\xe2\x96\x93" RESET);
        else if (idx < cq_filled)
            printf(FG_BGREEN "\xe2\x96\x88" RESET);
        else
            printf(FG_GRAY "\xe2\x96\x91" RESET);
    }
    printf(DIM "|" RESET);
    human_bytes((uint64_t)cq_filled * cqe_sz, buf, sizeof(buf));
    printf(" " FG_BGREEN "%u/%u" RESET " (%s)" ESC "K\n", cq_filled, cq_total, buf);
    lines++;

    /* CQ detail line */
    printf("  %s" ESC "K\n", cq_detail);
    lines++;

    printf("\n");
    lines++;

    /* ── Memory Map ── */
    printf("  " BOLD FG_BWHITE "MEMORY MAP" RESET DIM "  (ring %d/%d)" RESET ESC "K\n",
           ring_idx, total_rings);
    lines++;

    double pct = (double)cumulative_locked / (double)total_ram;
    if (pct > 1.0) pct = 1.0;
    int filled_chars = (int)(pct * map_bar_w);
    printf("  RAM " DIM "[" RESET);
    for (int i = 0; i < map_bar_w; i++) {
        if (i < filled_chars)
            printf(FG_CYAN "\xe2\x96\x88" RESET);
        else
            printf(FG_GRAY "\xe2\x96\x91" RESET);
    }
    printf(DIM "]" RESET " %s%.1f%%" RESET ESC "K\n",
           (pct > 0.75) ? FG_RED : (pct > 0.5) ? FG_YELLOW : FG_GREEN, pct * 100.0);
    lines++;

    for (int i = 0; i < nregions; i++) {
        if (regions[i].size == 0) continue;
        if (regions[i].allocated) {
            human_bytes(regions[i].size, buf, sizeof(buf));
            printf("  %s\xe2\x97\x8f %-18s" RESET " @ " DIM "0x%012lx" RESET "  %s",
                   regions[i].color, regions[i].name, (unsigned long)regions[i].addr, buf);
        } else {
            printf("  " FG_GRAY "\xe2\x97\x8b %-18s   " DIM "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" RESET
                   "  " FG_GRAY "pending" RESET, regions[i].name);
        }
        printf(ESC "K\n");
        lines++;
    }

    printf("  " DIM "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" RESET ESC "K\n");
    lines++;
    human_bytes(cumulative_locked, buf, sizeof(buf));
    human_bytes(total_ram, buf2, sizeof(buf2));
    printf("  Total locked: " BOLD "%s" RESET " / %s" ESC "K\n", buf, buf2);
    lines++;

    return lines;
}

static void animate_ring_instance(const ring_config_t *cfg, const ring_memory_t *m,
                                   int ring_idx, int total_rings,
                                   uint64_t base_addr, uint64_t cumulative_before,
                                   uint64_t total_ram, int speed_ms)
{
    uint32_t sq = m->sq_actual;
    uint32_t cq = m->cq_actual;
    int cqe_sz = cfg->cqe32 ? CQE_SIZE_CQE32 : CQE_SIZE_NORMAL;

    int tw = get_term_width();
    int vis_slots = tw - 50;
    if (vis_slots < 16) vis_slots = 16;
    if (vis_slots > 100) vis_slots = 100;

    /* Cap animated entries for large rings */
    uint32_t anim_sq = sq > 256 ? 256 : sq;
    uint32_t anim_cq = cq > 256 ? 256 : cq;

    /* Build memory regions */
    uint64_t addr = base_addr;
    mem_region_t regions[5];
    int nregions = 0;

    regions[nregions++] = (mem_region_t){"SQ Ring (indices)", addr, m->sq_ring_bytes, FG_BCYAN, 0};
    addr += m->sq_ring_bytes;
    regions[nregions++] = (mem_region_t){"CQ Ring (CQEs)", addr, m->cq_ring_bytes, FG_BGREEN, 0};
    addr += m->cq_ring_bytes;
    regions[nregions++] = (mem_region_t){"SQE Array", addr, m->sqe_array_bytes, FG_BYELLOW, 0};
    addr += m->sqe_array_bytes;
    if (m->reg_buf_bytes > 0) {
        regions[nregions++] = (mem_region_t){"Registered Bufs", addr, m->reg_buf_bytes, FG_BMAGENTA, 0};
        addr += m->reg_buf_bytes;
    }
    if (m->reg_file_bytes > 0) {
        regions[nregions++] = (mem_region_t){"Registered Files", addr, m->reg_file_bytes, FG_BBLUE, 0};
        addr += m->reg_file_bytes;
    }

    /* Print ring header (stays fixed) */
    printf("\n");
    printf("  " BOLD FG_BCYAN "\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97" RESET "\n");
    printf("  " BOLD FG_BCYAN "\xe2\x95\x91" RESET BOLD "  io_uring RING #%-4d  " RESET
           DIM "-- setting up instance" RESET
           BOLD FG_BCYAN "        \xe2\x95\x91" RESET "\n", ring_idx);
    printf("  " BOLD FG_BCYAN "\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d" RESET "\n");
    printf("\n");

    srand((unsigned)(time(NULL) ^ (ring_idx * 31)));
    uint64_t cum = cumulative_before;
    int prev_lines = 0;
    char sq_detail[256], cq_detail[256];

    /* Helper macro for redraw */
    #define REDRAW(sq_f, sq_p, sq_d, cq_f, cq_p, cq_d) do {           \
        if (prev_lines > 0) CURSOR_UP(prev_lines);                     \
        prev_lines = draw_frame(sq, (sq_f), (sq_p), (sq_d),            \
                                cq, (cq_f), (cq_p), (cq_d),           \
                                regions, nregions, cum, total_ram,      \
                                ring_idx, total_rings, vis_slots,       \
                                cqe_sz, regions[0].addr,                \
                                regions[1].addr);                       \
        fflush(stdout);                                                 \
    } while(0)

    /* ── Phase 1: Allocate mmap regions ─────────────────────────── */
    for (int r = 0; r < nregions; r++) {
        snprintf(sq_detail, sizeof(sq_detail),
                 DIM "  mmap: %s (%lu bytes)" RESET,
                 regions[r].name, (unsigned long)regions[r].size);
        snprintf(cq_detail, sizeof(cq_detail), DIM "  Waiting..." RESET);

        REDRAW(0, -1, sq_detail, 0, -1, cq_detail);
        msleep(speed_ms * 3);

        regions[r].allocated = 1;
        cum += regions[r].size;

        REDRAW(0, -1, sq_detail, 0, -1, cq_detail);
        msleep(speed_ms * 2);
    }

    /* ── Phase 2: Populate SQ ring with SQEs ────────────────────── */
    uint32_t step = anim_sq / 32;
    if (step < 1) step = 1;

    for (uint32_t i = 0; i <= anim_sq; i += step) {
        if (i > anim_sq) i = anim_sq;
        uint32_t display_i = (uint32_t)((uint64_t)i * sq / anim_sq);
        if (display_i > sq) display_i = sq;

        int pend = (i < anim_sq) ? (int)display_i : -1;

        if (i < anim_sq) {
            const char *op = sqe_opcodes[rand() % NUM_OPCODES];
            int fd = (rand() % 200) + 3;
            uint64_t off = (uint64_t)(rand() % 1048576) * 4096;
            snprintf(sq_detail, sizeof(sq_detail),
                     FG_BCYAN "  -> SQE[%u]" RESET " opcode=" BOLD "%s" RESET
                     " fd=%d off=0x%lx sz=%d",
                     display_i, op, fd, (unsigned long)off, SQE_SIZE);
        } else {
            snprintf(sq_detail, sizeof(sq_detail),
                     FG_BGREEN "  * Submission ring full -- %u SQEs queued" RESET, sq);
        }
        snprintf(cq_detail, sizeof(cq_detail), DIM "  Waiting for kernel..." RESET);

        REDRAW(display_i, pend, sq_detail, 0, -1, cq_detail);
        msleep(speed_ms);

        if (i + step > anim_sq && i < anim_sq) i = anim_sq - step;
    }
    msleep(speed_ms * 2);

    /* ── Phase 3: io_uring_enter() flash ────────────────────────── */
    snprintf(sq_detail, sizeof(sq_detail),
             FG_BYELLOW "  ** io_uring_enter() -- kernel processing submissions..." RESET);
    snprintf(cq_detail, sizeof(cq_detail),
             FG_BYELLOW "  ** Kernel dispatching I/O..." RESET);
    REDRAW(sq, -1, sq_detail, 0, -1, cq_detail);
    msleep(speed_ms * 5);

    /* ── Phase 4: CQ ring fills, SQ drains ──────────────────────── */
    uint32_t cq_step = anim_cq / 32;
    if (cq_step < 1) cq_step = 1;

    for (uint32_t i = 0; i <= anim_cq; i += cq_step) {
        if (i > anim_cq) i = anim_cq;
        uint32_t cq_display = (uint32_t)((uint64_t)i * cq / anim_cq);
        if (cq_display > cq) cq_display = cq;

        /* Drain SQ proportionally */
        uint32_t sq_remaining = sq;
        if (anim_cq > 0) {
            uint32_t drained = (uint32_t)((uint64_t)i * sq / anim_cq);
            if (drained > sq) drained = sq;
            sq_remaining = sq - drained;
        }

        if (sq_remaining > 0) {
            snprintf(sq_detail, sizeof(sq_detail),
                     FG_BCYAN "  ^ Draining: %u SQEs remaining" RESET, sq_remaining);
        } else {
            snprintf(sq_detail, sizeof(sq_detail),
                     FG_BGREEN "  * SQ ring drained" RESET);
        }

        int cq_pend = (i < anim_cq) ? (int)cq_display : -1;

        if (i < anim_cq) {
            const char *res = cqe_results[rand() % NUM_CQE_RESULTS];
            snprintf(cq_detail, sizeof(cq_detail),
                     FG_BGREEN "  <- CQE[%u]" RESET " user_data=0x%04x res=" BOLD "%s" RESET " sz=%d",
                     cq_display, (rand() % 0xFFFF), res, cqe_sz);
        } else {
            snprintf(cq_detail, sizeof(cq_detail),
                     FG_BGREEN "  * Completion ring full -- %u CQEs reaped" RESET, cq);
        }

        REDRAW(sq_remaining, -1, sq_detail, cq_display, cq_pend, cq_detail);
        msleep(speed_ms);

        if (i + cq_step > anim_cq && i < anim_cq) i = anim_cq - cq_step;
    }
    msleep(speed_ms * 2);

    /* ── Final state: rings idle ────────────────────────────────── */
    snprintf(sq_detail, sizeof(sq_detail),
             FG_BGREEN "  * Ring #%d ready -- all I/O complete" RESET, ring_idx);
    snprintf(cq_detail, sizeof(cq_detail),
             FG_BGREEN "  * All completions consumed" RESET);
    REDRAW(0, -1, sq_detail, 0, -1, cq_detail);
    msleep(speed_ms);

    printf("\n");
    #undef REDRAW
}

static void run_animation(const ring_config_t *cfg, const ring_memory_t *m,
                           uint32_t num_rings, uint64_t total_ram, int speed_ms)
{
    char buf[64];
    CURSOR_HIDE;

    printf("\n");
    printf("  " BOLD FG_BWHITE "====================================================================" RESET "\n");
    printf("  " BOLD FG_BWHITE "  io_uring STRUCTURE SIMULATION" RESET "\n");
    printf("  " DIM "  Placing %u ring instance%s into %s of physical RAM" RESET "\n",
           num_rings, num_rings == 1 ? "" : "s",
           human_bytes(total_ram, buf, sizeof(buf)));
    printf("  " BOLD FG_BWHITE "====================================================================" RESET "\n");
    fflush(stdout);
    msleep(speed_ms * 4);

    uint64_t base_addr = 0x7f0000000000ULL;
    uint64_t cumulative = 0;

    /* Fully animate up to 5 rings */
    uint32_t full_anim = num_rings;
    if (full_anim > 5) full_anim = 5;

    for (uint32_t i = 1; i <= full_anim; i++) {
        animate_ring_instance(cfg, m, (int)i, (int)num_rings,
                               base_addr + cumulative,
                               cumulative, total_ram, speed_ms);
        cumulative += m->total_bytes;
    }

    /* Fast-forward remaining rings */
    if (num_rings > full_anim) {
        uint32_t remaining = num_rings - full_anim;
        printf("\n  " FG_BYELLOW "** Fast-forwarding %u remaining ring instances..." RESET "\n", remaining);
        fflush(stdout);

        uint32_t ff_step = remaining / 20;
        if (ff_step < 1) ff_step = 1;
        for (uint32_t r = 0; r < remaining; r += ff_step) {
            uint32_t current = full_anim + r + ff_step;
            if (current > num_rings) current = num_rings;
            uint64_t cum_now = (uint64_t)current * m->total_bytes;

            printf("\r  " FG_BCYAN "  Ring %u/%u" RESET "  locked: " BOLD "%s" RESET "  (%.1f%% RAM)    ",
                   current, num_rings,
                   human_bytes(cum_now, buf, sizeof(buf)),
                   (double)cum_now / (double)total_ram * 100.0);
            fflush(stdout);
            msleep(speed_ms / 2);
        }
        cumulative = (uint64_t)num_rings * m->total_bytes;
        printf("\r  " FG_BGREEN "  * All %u rings allocated" RESET
               "  locked: " BOLD "%s" RESET "  (%.1f%% RAM)      \n",
               num_rings,
               human_bytes(cumulative, buf, sizeof(buf)),
               (double)cumulative / (double)total_ram * 100.0);
    }

    printf("\n");
    CURSOR_SHOW;
    fflush(stdout);
}

/* ══════════════════════════════════════════════════════════════════════
 *  STATIC OUTPUT
 * ══════════════════════════════════════════════════════════════════════ */

static void print_separator(void)
{
    printf("----------------------------------------------------------------\n");
}

static void print_ring_config(const ring_config_t *cfg)
{
    printf("\n");
    print_separator();
    printf("  RING CONFIGURATION\n");
    print_separator();
    printf("  SQ entries       : %u (rounded to power of 2: %u)\n",
           cfg->sq_entries, (uint32_t)next_power_of_2(cfg->sq_entries));
    uint32_t cq = (uint32_t)next_power_of_2(cfg->cq_entries);
    uint32_t sq = (uint32_t)next_power_of_2(cfg->sq_entries);
    if (cq < sq * DEFAULT_CQ_FACTOR) cq = (uint32_t)next_power_of_2(sq * DEFAULT_CQ_FACTOR);
    printf("  CQ entries       : %u (rounded to power of 2: %u)\n",
           cfg->cq_entries, cq);
    printf("  CQE size         : %d bytes%s\n",
           cfg->cqe32 ? CQE_SIZE_CQE32 : CQE_SIZE_NORMAL,
           cfg->cqe32 ? " (CQE32 mode)" : "");
    char buf[64];
    printf("  Registered bufs  : %s\n", human_bytes(cfg->registered_bufs, buf, sizeof(buf)));
    printf("  Registered files : %u\n", cfg->registered_files);
}

static void print_memory_breakdown(const ring_memory_t *m)
{
    char buf[64];
    printf("\n");
    print_separator();
    printf("  PER-RING MEMORY BREAKDOWN\n");
    print_separator();
    printf("  SQ ring region   : %s\n", human_bytes(m->sq_ring_bytes, buf, sizeof(buf)));
    printf("  CQ ring region   : %s\n", human_bytes(m->cq_ring_bytes, buf, sizeof(buf)));
    printf("  SQE array        : %s\n", human_bytes(m->sqe_array_bytes, buf, sizeof(buf)));
    if (m->reg_buf_bytes)
        printf("  Registered bufs  : %s\n", human_bytes(m->reg_buf_bytes, buf, sizeof(buf)));
    if (m->reg_file_bytes)
        printf("  Registered files : %s\n", human_bytes(m->reg_file_bytes, buf, sizeof(buf)));
    printf("  --------------------------------\n");
    printf("  Total per ring   : %s\n", human_bytes(m->total_bytes, buf, sizeof(buf)));
    printf("  mmap regions     : %u\n", m->mmap_regions);
}

static void print_simulation(const ring_memory_t *m, uint32_t num_rings,
                              uint64_t total_ram)
{
    tuning_t t = calc_tuning(m, num_rings, total_ram);
    char buf[64], buf2[64];

    printf("\n");
    print_separator();
    printf("  SIMULATION RESULTS (%u ring instances)\n", num_rings);
    print_separator();
    printf("  Total physical RAM       : %s\n", human_bytes(total_ram, buf, sizeof(buf)));
    printf("  Total locked memory      : %s\n", human_bytes(t.total_locked_mem, buf, sizeof(buf)));
    printf("  RAM usage by io_uring    : %.2f%%\n", t.ram_usage_pct);
    printf("  Total mmap regions       : %u\n", t.total_mmap_regions);

    if (t.ram_usage_pct > 75.0)
        printf("\n  WARNING: io_uring would consume >75%% of total RAM!\n");
    else if (t.ram_usage_pct > 50.0)
        printf("\n  CAUTION: io_uring would consume >50%% of total RAM.\n");

    uint64_t max_rings = 0;
    if (m->total_bytes > 0)
        max_rings = (uint64_t)((double)total_ram * 0.80) / m->total_bytes;

    printf("\n");
    print_separator();
    printf("  CAPACITY ESTIMATE\n");
    print_separator();
    printf("  Max rings in 80%% RAM    : %lu\n", (unsigned long)max_rings);

    printf("\n");
    print_separator();
    printf("  TUNING RECOMMENDATIONS\n");
    print_separator();

    printf("\n  +-- /etc/security/limits.conf ----------------------------+\n");
    printf("  |                                                         |\n");
    printf("  |  *  soft  memlock  %-10lu                           |\n",
           (unsigned long)(t.memlock_limit / 1024));
    printf("  |  *  hard  memlock  %-10lu                           |\n",
           (unsigned long)(t.memlock_limit / 1024));
    printf("  |                                                         |\n");
    printf("  |  (values in KiB -- limit = %s)%*s|\n",
           human_bytes(t.memlock_limit, buf, sizeof(buf)),
           (int)(20 - strlen(human_bytes(t.memlock_limit, buf2, sizeof(buf2)))), "");
    printf("  +---------------------------------------------------------+\n");

    printf("\n  +-- /etc/sysctl.conf -------------------------------------+\n");
    printf("  |                                                         |\n");
    printf("  |  vm.max_map_count = %-10lu                          |\n",
           (unsigned long)t.max_map_count);
    printf("  |                                                         |\n");
    printf("  +---------------------------------------------------------+\n");

    printf("\n  +-- systemd override (per-service) -----------------------+\n");
    printf("  |                                                         |\n");
    printf("  |  [Service]                                              |\n");
    printf("  |  LimitMEMLOCK=%lu\n", (unsigned long)t.memlock_limit);
    printf("  |                                                         |\n");
    printf("  +---------------------------------------------------------+\n");

    printf("\n  +-- Apply at runtime -------------------------------------+\n");
    printf("  |                                                         |\n");
    printf("  |  ulimit -l %lu\n", (unsigned long)(t.memlock_limit / 1024));
    printf("  |  sysctl -w vm.max_map_count=%lu\n", (unsigned long)t.max_map_count);
    printf("  |                                                         |\n");
    printf("  +---------------------------------------------------------+\n");
}

/* ── Sweep mode ────────────────────────────────────────────────────── */

static void sweep_mode(const ring_config_t *cfg, uint64_t total_ram)
{
    uint32_t counts[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512,
                          1024, 2048, 4096, 8192, 16384, 32768, 65536};
    int ncounts = (int)(sizeof(counts) / sizeof(counts[0]));
    ring_memory_t m = calc_ring_memory(cfg);
    char buf[64];

    printf("\n");
    print_separator();
    printf("  SWEEP: Tuning across ring counts (per-ring = %s)\n",
           human_bytes(m.total_bytes, buf, sizeof(buf)));
    print_separator();
    printf("\n  %-8s  %-14s  %-6s  %-16s  %-12s\n",
           "Rings", "Locked Mem", "RAM%", "memlock (KiB)", "max_map_count");
    printf("  %-8s  %-14s  %-6s  %-16s  %-12s\n",
           "--------", "--------------", "------", "----------------", "------------");

    for (int i = 0; i < ncounts; i++) {
        tuning_t t = calc_tuning(&m, counts[i], total_ram);
        if (t.ram_usage_pct > 95.0) break;
        char lock_buf[64];
        human_bytes(t.total_locked_mem, lock_buf, sizeof(lock_buf));
        printf("  %-8u  %-14s  %5.1f%%  %-16lu  %-12lu\n",
               counts[i], lock_buf, t.ram_usage_pct,
               (unsigned long)(t.memlock_limit / 1024),
               (unsigned long)t.max_map_count);
    }
    printf("\n");
}

/* ── Interactive mode ──────────────────────────────────────────────── */

static uint64_t prompt_uint64(const char *prompt, uint64_t def)
{
    char line[256];
    printf("  %s [%lu]: ", prompt, (unsigned long)def);
    fflush(stdout);
    if (!fgets(line, sizeof(line), stdin) || line[0] == '\n')
        return def;
    return strtoull(line, NULL, 10);
}

static void interactive_mode(int no_anim)
{
    char line[256];
    printf("\n");
    print_separator();
    printf("  io_uring MEMORY SIMULATOR -- Interactive Mode\n");
    print_separator();

    printf("\n  Enter total physical RAM (e.g. 16G, 512M, 8589934592): ");
    fflush(stdout);
    if (!fgets(line, sizeof(line), stdin)) return;
    line[strcspn(line, "\n")] = 0;
    uint64_t total_ram = parse_ram(line);
    if (total_ram == 0) { fprintf(stderr, "  Error: invalid RAM value\n"); return; }
    char buf[64];
    printf("  -> Parsed: %s\n", human_bytes(total_ram, buf, sizeof(buf)));

    printf("\n");
    ring_config_t cfg = {0};
    cfg.sq_entries = (uint32_t)prompt_uint64("SQ entries per ring", 128);
    cfg.cq_entries = (uint32_t)prompt_uint64("CQ entries per ring (0 = auto 2x SQ)", 0);
    if (cfg.cq_entries == 0) cfg.cq_entries = cfg.sq_entries * DEFAULT_CQ_FACTOR;

    printf("  Use 32-byte CQEs? (y/N): ");
    fflush(stdout);
    if (fgets(line, sizeof(line), stdin) && (line[0] == 'y' || line[0] == 'Y'))
        cfg.cqe32 = 1;

    printf("\n  Enter total registered buffer size per ring (e.g. 1M, 0): ");
    fflush(stdout);
    if (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\n")] = 0;
        cfg.registered_bufs = parse_ram(line);
    }
    cfg.registered_files = (uint32_t)prompt_uint64("Registered file descriptors per ring", 0);
    uint32_t num_rings = (uint32_t)prompt_uint64("\n  Number of io_uring instances", 1);

    ring_memory_t m = calc_ring_memory(&cfg);
    if (!no_anim) run_animation(&cfg, &m, num_rings, total_ram, 40);

    print_ring_config(&cfg);
    print_memory_breakdown(&m);
    print_simulation(&m, num_rings, total_ram);
    printf("\n");
}

/* ── Usage ─────────────────────────────────────────────────────────── */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n\n"
        "Options:\n"
        "  --ram <size>         Total physical RAM (e.g. 16G, 512M)     [required]\n"
        "  --rings <n>          Number of io_uring instances             [default: 1]\n"
        "  --sq <n>             SQ entries per ring                      [default: 128]\n"
        "  --cq <n>             CQ entries per ring (0 = auto 2x SQ)    [default: 0]\n"
        "  --cqe32              Use 32-byte CQEs\n"
        "  --reg-bufs <size>    Registered buffer size per ring          [default: 0]\n"
        "  --reg-files <n>      Registered file descriptors per ring     [default: 0]\n"
        "  --interactive, -i    Interactive mode (ignores other flags)\n"
        "  --sweep              Show table for varying ring counts\n"
        "  --no-anim            Skip real-time ring visualization\n"
        "  --speed <ms>         Animation speed in ms per frame          [default: 40]\n"
        "  --help, -h           Show this help\n\n"
        "Examples:\n"
        "  %s --ram 16G --rings 4 --sq 256\n"
        "  %s --ram 8G --rings 1000 --sq 4096 --reg-bufs 4M --sweep\n"
        "  %s --interactive\n"
        "  %s --ram 4G --rings 4 --sq 512 --no-anim\n",
        prog, prog, prog, prog, prog);
}

/* ── Main ──────────────────────────────────────────────────────────── */

int main(int argc, char **argv)
{
    static struct option long_opts[] = {
        {"ram",         required_argument, 0, 'r'},
        {"rings",       required_argument, 0, 'n'},
        {"sq",          required_argument, 0, 's'},
        {"cq",          required_argument, 0, 'c'},
        {"cqe32",       no_argument,       0, '3'},
        {"reg-bufs",    required_argument, 0, 'b'},
        {"reg-files",   required_argument, 0, 'f'},
        {"interactive", no_argument,       0, 'i'},
        {"sweep",       no_argument,       0, 'w'},
        {"no-anim",     no_argument,       0, 'A'},
        {"speed",       required_argument, 0, 'S'},
        {"help",        no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    ring_config_t cfg = { .sq_entries = 128, .cq_entries = 0, .cqe32 = 0,
                           .registered_bufs = 0, .registered_files = 0 };
    uint64_t total_ram = 0;
    uint32_t num_rings = 1;
    int do_interactive = 0, do_sweep = 0, no_anim = 0, speed_ms = 40;

    if (argc == 1) do_interactive = 1;

    int opt;
    while ((opt = getopt_long(argc, argv, "r:n:s:c:b:f:iwAh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'r': total_ram = parse_ram(optarg); break;
        case 'n': num_rings = (uint32_t)atoi(optarg); break;
        case 's': cfg.sq_entries = (uint32_t)atoi(optarg); break;
        case 'c': cfg.cq_entries = (uint32_t)atoi(optarg); break;
        case '3': cfg.cqe32 = 1; break;
        case 'b': cfg.registered_bufs = parse_ram(optarg); break;
        case 'f': cfg.registered_files = (uint32_t)atoi(optarg); break;
        case 'i': do_interactive = 1; break;
        case 'w': do_sweep = 1; break;
        case 'A': no_anim = 1; break;
        case 'S': speed_ms = atoi(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    if (do_interactive) { interactive_mode(no_anim); return 0; }

    if (total_ram == 0) {
        fprintf(stderr, "Error: --ram is required in batch mode\n\n");
        usage(argv[0]);
        return 1;
    }
    if (cfg.cq_entries == 0) cfg.cq_entries = cfg.sq_entries * DEFAULT_CQ_FACTOR;

    ring_memory_t m = calc_ring_memory(&cfg);
    if (!no_anim) run_animation(&cfg, &m, num_rings, total_ram, speed_ms);

    print_ring_config(&cfg);
    print_memory_breakdown(&m);
    print_simulation(&m, num_rings, total_ram);
    if (do_sweep) sweep_mode(&cfg, total_ram);
    printf("\n");
    return 0;
}