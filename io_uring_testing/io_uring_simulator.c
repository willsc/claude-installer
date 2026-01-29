/*
 * io_uring Memory Structure Simulator
 * 
 * This program simulates and calculates io_uring memory usage
 * without requiring actual kernel support. Useful for:
 * - Understanding memory layouts
 * - Planning capacity
 * - Educational purposes
 * 
 * Compile: gcc -o io_uring_simulator io_uring_simulator.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

/*
 * io_uring constants (from Linux kernel headers)
 */
#define IORING_MAX_ENTRIES      32768
#define IORING_MAX_CQ_ENTRIES   (2 * IORING_MAX_ENTRIES)

/* Standard structure sizes */
#define SQE_SIZE_STANDARD       64
#define SQE_SIZE_EXTENDED       128
#define CQE_SIZE_STANDARD       16
#define CQE_SIZE_EXTENDED       32

/* Ring header overhead (approximate) */
#define SQ_RING_HEADER_SIZE     128
#define CQ_RING_HEADER_SIZE     128

/*
 * Round up to nearest power of 2
 */
unsigned int roundup_pow2(unsigned int x)
{
    if (x == 0) return 1;
    x--;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}

/*
 * Round up to page size
 */
size_t page_align(size_t size)
{
    long page_size = sysconf(_SC_PAGESIZE);
    return ((size + page_size - 1) / page_size) * page_size;
}

/*
 * Calculate memory for a specific configuration
 */
struct ring_memory {
    unsigned int sq_entries;
    unsigned int cq_entries;
    size_t sq_ring_bytes;
    size_t cq_ring_bytes;
    size_t sqe_array_bytes;
    size_t total_user_bytes;
    size_t kernel_overhead_est;
    size_t total_estimated;
};

void calculate_ring_memory(unsigned int requested_sq_entries,
                           unsigned int requested_cq_entries,
                           int use_sqe128, int use_cqe32,
                           struct ring_memory *mem)
{
    /* Actual entries after rounding */
    mem->sq_entries = roundup_pow2(requested_sq_entries);
    if (mem->sq_entries > IORING_MAX_ENTRIES) {
        mem->sq_entries = IORING_MAX_ENTRIES;
    }
    
    /* CQ defaults to 2x SQ if not specified */
    if (requested_cq_entries == 0) {
        mem->cq_entries = mem->sq_entries * 2;
    } else {
        mem->cq_entries = roundup_pow2(requested_cq_entries);
    }
    if (mem->cq_entries > IORING_MAX_CQ_ENTRIES) {
        mem->cq_entries = IORING_MAX_CQ_ENTRIES;
    }
    
    /* Entry sizes */
    size_t sqe_size = use_sqe128 ? SQE_SIZE_EXTENDED : SQE_SIZE_STANDARD;
    size_t cqe_size = use_cqe32 ? CQE_SIZE_EXTENDED : CQE_SIZE_STANDARD;
    
    /* SQ ring: header + array of indices (unsigned int) */
    mem->sq_ring_bytes = page_align(SQ_RING_HEADER_SIZE + 
                                     mem->sq_entries * sizeof(unsigned int));
    
    /* CQ ring: header + array of CQEs */
    mem->cq_ring_bytes = page_align(CQ_RING_HEADER_SIZE + 
                                     mem->cq_entries * cqe_size);
    
    /* SQE array */
    mem->sqe_array_bytes = page_align(mem->sq_entries * sqe_size);
    
    /* Total user-space visible memory */
    mem->total_user_bytes = mem->sq_ring_bytes + mem->cq_ring_bytes + 
                            mem->sqe_array_bytes;
    
    /* Kernel-side overhead estimate (per-request context, etc.) */
    mem->kernel_overhead_est = mem->sq_entries * 256;  /* ~256 bytes per in-flight */
    
    mem->total_estimated = mem->total_user_bytes + mem->kernel_overhead_est;
}

/*
 * Print memory breakdown
 */
void print_memory_breakdown(struct ring_memory *mem)
{
    printf("  SQ Entries:       %u\n", mem->sq_entries);
    printf("  CQ Entries:       %u\n", mem->cq_entries);
    printf("  SQ Ring Memory:   %zu bytes (%zu KB)\n", 
           mem->sq_ring_bytes, mem->sq_ring_bytes / 1024);
    printf("  CQ Ring Memory:   %zu bytes (%zu KB)\n",
           mem->cq_ring_bytes, mem->cq_ring_bytes / 1024);
    printf("  SQE Array:        %zu bytes (%zu KB)\n",
           mem->sqe_array_bytes, mem->sqe_array_bytes / 1024);
    printf("  --------------------------------\n");
    printf("  User-Space Total: %zu bytes (%zu KB)\n",
           mem->total_user_bytes, mem->total_user_bytes / 1024);
    printf("  Kernel Overhead:  ~%zu bytes (%zu KB)\n",
           mem->kernel_overhead_est, mem->kernel_overhead_est / 1024);
    printf("  Total Estimated:  ~%zu bytes (%zu KB)\n",
           mem->total_estimated, mem->total_estimated / 1024);
}

/*
 * Simulate tunable effects
 */
void simulate_tunables(void)
{
    printf("\n");
    printf("==========================================================================\n");
    printf("              io_uring Memory Structure Simulation                        \n");
    printf("==========================================================================\n\n");
    
    /* System info */
    printf("System Parameters:\n");
    printf("------------------\n");
    printf("  Page Size:             %ld bytes\n", sysconf(_SC_PAGESIZE));
    printf("  IORING_MAX_ENTRIES:    %d\n", IORING_MAX_ENTRIES);
    printf("  IORING_MAX_CQ_ENTRIES: %d\n\n", IORING_MAX_CQ_ENTRIES);
    
    /* Structure sizes */
    printf("io_uring Structure Sizes:\n");
    printf("-------------------------\n");
    printf("  struct io_uring_sqe (standard):  %d bytes\n", SQE_SIZE_STANDARD);
    printf("  struct io_uring_sqe (extended):  %d bytes\n", SQE_SIZE_EXTENDED);
    printf("  struct io_uring_cqe (standard):  %d bytes\n", CQE_SIZE_STANDARD);
    printf("  struct io_uring_cqe (extended):  %d bytes\n\n", CQE_SIZE_EXTENDED);
    
    /* Test various entry counts */
    printf("Memory Usage by Entry Count (Standard SQE/CQE):\n");
    printf("================================================\n\n");
    
    printf("%-12s %-12s %-12s %-12s %-12s %-12s\n",
           "Requested", "SQ Actual", "CQ Actual", "SQ+CQ Ring", "SQE Array", "Total");
    printf("%-12s %-12s %-12s %-12s %-12s %-12s\n",
           "Entries", "Entries", "Entries", "(bytes)", "(bytes)", "(bytes)");
    printf("------------------------------------------------------------------------\n");
    
    unsigned int test_sizes[] = {1, 4, 16, 64, 256, 1024, 4096, 16384, 32768};
    int num_tests = sizeof(test_sizes) / sizeof(test_sizes[0]);
    
    for (int i = 0; i < num_tests; i++) {
        struct ring_memory mem;
        calculate_ring_memory(test_sizes[i], 0, 0, 0, &mem);
        
        printf("%-12u %-12u %-12u %-12zu %-12zu %-12zu\n",
               test_sizes[i], mem.sq_entries, mem.cq_entries,
               mem.sq_ring_bytes + mem.cq_ring_bytes,
               mem.sqe_array_bytes, mem.total_user_bytes);
    }
    
    /* CQ Size multiplier effects */
    printf("\n\nEffect of CQ Size Multiplier (SQ=1024):\n");
    printf("=======================================\n\n");
    
    printf("%-12s %-12s %-12s %-12s %-12s\n",
           "CQ Mult", "SQ Entries", "CQ Entries", "CQ Ring", "Total");
    printf("------------------------------------------------------------\n");
    
    unsigned int cq_multipliers[] = {1, 2, 4, 8, 16};
    for (int i = 0; i < sizeof(cq_multipliers)/sizeof(cq_multipliers[0]); i++) {
        struct ring_memory mem;
        calculate_ring_memory(1024, 1024 * cq_multipliers[i], 0, 0, &mem);
        
        printf("%-12ux %-12u %-12u %-12zu %-12zu\n",
               cq_multipliers[i], mem.sq_entries, mem.cq_entries,
               mem.cq_ring_bytes, mem.total_user_bytes);
    }
    
    /* Extended entry size effects */
    printf("\n\nEffect of Extended Entry Sizes (1024 entries):\n");
    printf("==============================================\n\n");
    
    printf("%-20s %-12s %-12s %-12s %-12s\n",
           "Configuration", "SQE Size", "CQE Size", "SQE Array", "Total");
    printf("----------------------------------------------------------------------\n");
    
    struct {
        const char *name;
        int sqe128;
        int cqe32;
    } configs[] = {
        {"Standard", 0, 0},
        {"SQE128", 1, 0},
        {"CQE32", 0, 1},
        {"SQE128 + CQE32", 1, 1}
    };
    
    for (int i = 0; i < 4; i++) {
        struct ring_memory mem;
        calculate_ring_memory(1024, 0, configs[i].sqe128, configs[i].cqe32, &mem);
        
        printf("%-20s %-12d %-12d %-12zu %-12zu\n",
               configs[i].name,
               configs[i].sqe128 ? SQE_SIZE_EXTENDED : SQE_SIZE_STANDARD,
               configs[i].cqe32 ? CQE_SIZE_EXTENDED : CQE_SIZE_STANDARD,
               mem.sqe_array_bytes, mem.total_user_bytes);
    }
}

/*
 * Interactive capacity planner
 */
void capacity_planner(void)
{
    printf("\n\n");
    printf("==========================================================================\n");
    printf("                      Capacity Planning Examples                          \n");
    printf("==========================================================================\n\n");
    
    /* High-throughput scenario */
    printf("Scenario 1: High-Throughput File Server\n");
    printf("---------------------------------------\n");
    printf("  Requirements: Handle 10,000 concurrent I/O operations\n");
    printf("  Configuration: 8192 SQ entries, 16384 CQ entries\n\n");
    
    struct ring_memory mem1;
    calculate_ring_memory(8192, 16384, 0, 0, &mem1);
    print_memory_breakdown(&mem1);
    
    printf("\n\nScenario 2: Low-Latency Network Service\n");
    printf("----------------------------------------\n");
    printf("  Requirements: Minimize latency, 256 concurrent connections\n");
    printf("  Configuration: 256 SQ entries, 512 CQ entries\n\n");
    
    struct ring_memory mem2;
    calculate_ring_memory(256, 512, 0, 0, &mem2);
    print_memory_breakdown(&mem2);
    
    printf("\n\nScenario 3: Multi-Ring Architecture (8 rings x 1024 entries)\n");
    printf("------------------------------------------------------------\n");
    printf("  Requirements: CPU-affinity, per-core rings\n");
    printf("  Configuration: 8 rings, each 1024 SQ entries\n\n");
    
    struct ring_memory mem3;
    calculate_ring_memory(1024, 0, 0, 0, &mem3);
    printf("  Per-ring memory:\n");
    print_memory_breakdown(&mem3);
    printf("\n  Total for 8 rings: %zu bytes (%zu KB)\n",
           mem3.total_estimated * 8, (mem3.total_estimated * 8) / 1024);
    
    printf("\n\nScenario 4: NVMe with Extended SQEs (for passthrough)\n");
    printf("-----------------------------------------------------\n");
    printf("  Requirements: NVMe passthrough, large commands\n");
    printf("  Configuration: 4096 SQ entries with SQE128\n\n");
    
    struct ring_memory mem4;
    calculate_ring_memory(4096, 0, 1, 0, &mem4);
    print_memory_breakdown(&mem4);
}

/*
 * Print tuning recommendations
 */
void print_recommendations(void)
{
    printf("\n\n");
    printf("==========================================================================\n");
    printf("                      Tuning Recommendations                              \n");
    printf("==========================================================================\n\n");
    
    printf("1. RLIMIT_MEMLOCK Configuration:\n");
    printf("   -----------------------------\n");
    printf("   io_uring rings are allocated as locked memory.\n");
    printf("   Increase the limit if ring creation fails with ENOMEM:\n");
    printf("\n");
    printf("   # View current limit\n");
    printf("   ulimit -l\n");
    printf("\n");
    printf("   # Set to 1GB (in /etc/security/limits.conf)\n");
    printf("   * soft memlock 1048576\n");
    printf("   * hard memlock 1048576\n\n");
    
    printf("2. Entry Count Selection:\n");
    printf("   -----------------------\n");
    printf("   Rule of thumb:\n");
    printf("   - Low latency apps:    32-256 entries\n");
    printf("   - General purpose:     256-1024 entries\n");
    printf("   - High throughput:     2048-8192 entries\n");
    printf("   - Extreme workloads:   16384-32768 entries\n\n");
    
    printf("3. CQ/SQ Ratio Tuning:\n");
    printf("   --------------------\n");
    printf("   - Default: CQ = 2x SQ\n");
    printf("   - Bursty completions: CQ = 4-8x SQ\n");
    printf("   - Synchronous patterns: CQ = 1x SQ\n");
    printf("   - Set via IORING_SETUP_CQSIZE flag\n\n");
    
    printf("4. Multiple Rings Strategy:\n");
    printf("   -------------------------\n");
    printf("   - One ring per CPU core for scaling\n");
    printf("   - Pin threads to cores\n");
    printf("   - Smaller rings (512-2048) per core often better\n");
    printf("   - Total memory = N_cores * per_ring_memory\n\n");
    
    printf("5. Memory Budget Formula:\n");
    printf("   -----------------------\n");
    printf("   Total_per_ring ≈ page_align(128 + 4*SQ) +     # SQ ring\n");
    printf("                    page_align(128 + 16*CQ) +    # CQ ring\n");
    printf("                    page_align(64*SQ) +          # SQE array\n");
    printf("                    ~256*SQ                      # kernel overhead\n\n");
    
    printf("6. sysctl Tunables:\n");
    printf("   -----------------\n");
    printf("   # Max memory mappings (affects large rings)\n");
    printf("   sysctl -w vm.max_map_count=262144\n\n");
    printf("   # Some kernels have io_uring specific limits\n");
    printf("   # Check /proc/sys/kernel/io_uring* if available\n\n");
}

/*
 * Generate detailed report
 */
void generate_report(void)
{
    simulate_tunables();
    capacity_planner();
    print_recommendations();
    
    printf("==========================================================================\n");
    printf("                           End of Report                                  \n");
    printf("==========================================================================\n");
}

int main(int argc, char *argv[])
{
    printf("\n");
    printf("io_uring Memory Structure Simulator\n");
    printf("===================================\n");
    printf("This tool simulates io_uring memory usage for capacity planning.\n");
    printf("No kernel support required - uses calculated values.\n");
    
    generate_report();
    
    return 0;
}
