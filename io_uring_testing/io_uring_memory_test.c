/*
 * io_uring Memory Structure Analysis and Tunable Testing
 * 
 * This program tests and measures:
 * 1. Memory consumption of io_uring structures (SQ/CQ entries)
 * 2. Effect of various tunables on memory usage
 * 3. Maximum ring sizes and their memory implications
 * 
 * Requires: Linux kernel >= 5.1, liburing
 * Compile: gcc -o io_uring_memory_test io_uring_memory_test.c -luring -lpthread
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysinfo.h>
#include <fcntl.h>
#include <time.h>
#include <liburing.h>

/* Structure to hold test results */
struct memory_test_result {
    unsigned int sq_entries;
    unsigned int cq_entries;
    size_t sq_ring_size;
    size_t cq_ring_size;
    size_t sqe_array_size;
    size_t total_memory;
    int setup_success;
    char error_msg[256];
};

/* Structure to hold tunable information */
struct io_uring_tunable {
    const char *name;
    const char *description;
    const char *sysctl_path;
    unsigned long default_value;
    unsigned long current_value;
    unsigned long min_value;
    unsigned long max_value;
};

/* Known io_uring tunables */
static struct io_uring_tunable tunables[] = {
    {
        .name = "iomem_limit",
        .description = "Maximum locked memory per user for io_uring (bytes)",
        .sysctl_path = "/proc/sys/kernel/io_uring_mem_limit",
        .default_value = 0,  /* Typically tied to RLIMIT_MEMLOCK */
        .min_value = 0,
        .max_value = ULONG_MAX
    },
    {
        .name = "max_entries",
        .description = "Maximum number of entries per ring",
        .sysctl_path = NULL,  /* Set via io_uring_params */
        .default_value = 32768,
        .min_value = 1,
        .max_value = 32768  /* IORING_MAX_ENTRIES */
    },
    {
        .name = "memlock_limit",
        .description = "RLIMIT_MEMLOCK - affects io_uring memory allocation",
        .sysctl_path = "/proc/sys/vm/max_map_count",
        .default_value = 65536,
        .min_value = 0,
        .max_value = ULONG_MAX
    }
};

#define NUM_TUNABLES (sizeof(tunables) / sizeof(tunables[0]))

/*
 * Calculate expected memory sizes for io_uring structures
 * 
 * SQ Ring memory layout:
 *   - Header: struct io_sq_ring (~40 bytes)
 *   - sq_array: unsigned int[sq_entries] (4 * sq_entries bytes)
 *   
 * CQ Ring memory layout:
 *   - Header: struct io_cq_ring (~40 bytes)  
 *   - cqes: struct io_uring_cqe[cq_entries] (16 * cq_entries bytes)
 *
 * SQE Array:
 *   - struct io_uring_sqe[sq_entries] (64 * sq_entries bytes)
 */
void calculate_expected_memory(unsigned int sq_entries, unsigned int cq_entries,
                               size_t *sq_ring, size_t *cq_ring, size_t *sqe_array)
{
    /* io_uring_sqe is 64 bytes */
    const size_t SQE_SIZE = 64;
    
    /* io_uring_cqe is 16 bytes (or 32 bytes with CQE32 flag) */
    const size_t CQE_SIZE = 16;
    
    /* Ring header overhead (approximate) */
    const size_t SQ_RING_HEADER = 128;
    const size_t CQ_RING_HEADER = 128;
    
    /* SQ ring: header + array of indices */
    *sq_ring = SQ_RING_HEADER + (sq_entries * sizeof(unsigned int));
    
    /* CQ ring: header + array of CQEs */
    *cq_ring = CQ_RING_HEADER + (cq_entries * CQE_SIZE);
    
    /* SQE array: array of SQEs */
    *sqe_array = sq_entries * SQE_SIZE;
    
    /* Round up to page size */
    long page_size = sysconf(_SC_PAGESIZE);
    *sq_ring = ((*sq_ring + page_size - 1) / page_size) * page_size;
    *cq_ring = ((*cq_ring + page_size - 1) / page_size) * page_size;
    *sqe_array = ((*sqe_array + page_size - 1) / page_size) * page_size;
}

/*
 * Test io_uring setup with specific parameters and measure memory
 */
int test_io_uring_memory(unsigned int entries, unsigned int flags,
                         struct memory_test_result *result)
{
    struct io_uring ring;
    struct io_uring_params params;
    int ret;
    
    memset(&params, 0, sizeof(params));
    params.flags = flags;
    
    /* For testing CQ size separately */
    if (flags & IORING_SETUP_CQSIZE) {
        params.cq_entries = entries * 2;  /* Test with 2x CQ entries */
    }
    
    ret = io_uring_queue_init_params(entries, &ring, &params);
    
    if (ret < 0) {
        result->setup_success = 0;
        snprintf(result->error_msg, sizeof(result->error_msg),
                "io_uring_queue_init failed: %s", strerror(-ret));
        return ret;
    }
    
    result->setup_success = 1;
    result->sq_entries = params.sq_entries;
    result->cq_entries = params.cq_entries;
    
    /* Get actual ring sizes from the ring structure */
    result->sq_ring_size = ring.sq.ring_sz;
    result->cq_ring_size = ring.cq.ring_sz;
    
    /* Calculate SQE array size */
    result->sqe_array_size = params.sq_entries * sizeof(struct io_uring_sqe);
    
    /* Total memory (excluding kernel-side structures) */
    result->total_memory = result->sq_ring_size + result->cq_ring_size + 
                          result->sqe_array_size;
    
    io_uring_queue_exit(&ring);
    return 0;
}

/*
 * Get current memory usage of the process
 */
size_t get_process_memory_usage(void)
{
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    
    unsigned long size, resident;
    if (fscanf(f, "%lu %lu", &size, &resident) != 2) {
        fclose(f);
        return 0;
    }
    fclose(f);
    
    return resident * sysconf(_SC_PAGESIZE);
}

/*
 * Read sysctl value
 */
unsigned long read_sysctl(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    
    unsigned long value;
    if (fscanf(f, "%lu", &value) != 1) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return value;
}

/*
 * Get RLIMIT_MEMLOCK
 */
unsigned long get_memlock_limit(void)
{
    struct rlimit rlim;
    if (getrlimit(RLIMIT_MEMLOCK, &rlim) == 0) {
        return rlim.rlim_cur;
    }
    return 0;
}

/*
 * Print header for test results
 */
void print_header(void)
{
    printf("\n");
    printf("==========================================================================\n");
    printf("                    io_uring Memory Structure Analysis                    \n");
    printf("==========================================================================\n\n");
}

/*
 * Print system information
 */
void print_system_info(void)
{
    struct sysinfo si;
    sysinfo(&si);
    
    printf("System Information:\n");
    printf("-------------------\n");
    printf("  Page Size:        %ld bytes\n", sysconf(_SC_PAGESIZE));
    printf("  Total RAM:        %lu MB\n", si.totalram / (1024 * 1024));
    printf("  Free RAM:         %lu MB\n", si.freeram / (1024 * 1024));
    printf("  MEMLOCK Limit:    %lu bytes", get_memlock_limit());
    if (get_memlock_limit() == RLIM_INFINITY) {
        printf(" (unlimited)\n");
    } else {
        printf("\n");
    }
    printf("  Max Map Count:    %lu\n", read_sysctl("/proc/sys/vm/max_map_count"));
    printf("\n");
}

/*
 * Print io_uring structure sizes
 */
void print_structure_sizes(void)
{
    printf("io_uring Structure Sizes (compile-time):\n");
    printf("-----------------------------------------\n");
    printf("  sizeof(struct io_uring_sqe):  %zu bytes\n", sizeof(struct io_uring_sqe));
    printf("  sizeof(struct io_uring_cqe):  %zu bytes\n", sizeof(struct io_uring_cqe));
    printf("  sizeof(struct io_uring):      %zu bytes\n", sizeof(struct io_uring));
    printf("\n");
}

/*
 * Run memory tests with various entry counts
 */
void run_entry_count_tests(void)
{
    printf("Memory Usage vs Entry Count:\n");
    printf("============================\n\n");
    
    unsigned int test_sizes[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 
                                  1024, 2048, 4096, 8192, 16384, 32768};
    int num_tests = sizeof(test_sizes) / sizeof(test_sizes[0]);
    
    printf("%-10s %-10s %-10s %-12s %-12s %-12s %-12s\n",
           "Requested", "SQ Actual", "CQ Actual", "SQ Ring", "CQ Ring", 
           "SQE Array", "Total");
    printf("%-10s %-10s %-10s %-12s %-12s %-12s %-12s\n",
           "Entries", "Entries", "Entries", "(bytes)", "(bytes)", 
           "(bytes)", "(bytes)");
    printf("--------------------------------------------------------------------------\n");
    
    for (int i = 0; i < num_tests; i++) {
        struct memory_test_result result;
        memset(&result, 0, sizeof(result));
        
        int ret = test_io_uring_memory(test_sizes[i], 0, &result);
        
        if (ret == 0 && result.setup_success) {
            printf("%-10u %-10u %-10u %-12zu %-12zu %-12zu %-12zu\n",
                   test_sizes[i], result.sq_entries, result.cq_entries,
                   result.sq_ring_size, result.cq_ring_size,
                   result.sqe_array_size, result.total_memory);
        } else {
            printf("%-10u FAILED: %s\n", test_sizes[i], result.error_msg);
        }
    }
    printf("\n");
}

/*
 * Test effect of IORING_SETUP_CQSIZE flag
 */
void run_cqsize_tests(void)
{
    printf("Effect of IORING_SETUP_CQSIZE Flag:\n");
    printf("===================================\n\n");
    
    printf("Testing with SQ=1024 entries, varying CQ multiplier:\n\n");
    
    printf("%-15s %-10s %-10s %-12s %-12s\n",
           "CQ Multiplier", "SQ Actual", "CQ Actual", "CQ Ring", "Total");
    printf("---------------------------------------------------------------\n");
    
    /* Test without CQSIZE flag first */
    {
        struct io_uring ring;
        int ret = io_uring_queue_init(1024, &ring, 0);
        if (ret == 0) {
            printf("%-15s %-10u %-10u %-12zu %-12zu\n",
                   "Default (2x)", ring.sq.ring_sz, ring.cq.ring_entries,
                   ring.cq.ring_sz,
                   ring.sq.ring_sz + ring.cq.ring_sz + 
                   ring.sq.ring_entries * sizeof(struct io_uring_sqe));
            io_uring_queue_exit(&ring);
        }
    }
    
    /* Test with various CQ sizes */
    unsigned int cq_multipliers[] = {1, 2, 4, 8, 16};
    for (int i = 0; i < sizeof(cq_multipliers)/sizeof(cq_multipliers[0]); i++) {
        struct io_uring ring;
        struct io_uring_params params;
        
        memset(&params, 0, sizeof(params));
        params.flags = IORING_SETUP_CQSIZE;
        params.cq_entries = 1024 * cq_multipliers[i];
        
        int ret = io_uring_queue_init_params(1024, &ring, &params);
        if (ret == 0) {
            char mult_str[16];
            snprintf(mult_str, sizeof(mult_str), "%ux", cq_multipliers[i]);
            printf("%-15s %-10u %-10u %-12zu %-12zu\n",
                   mult_str, params.sq_entries, params.cq_entries,
                   ring.cq.ring_sz,
                   ring.sq.ring_sz + ring.cq.ring_sz +
                   params.sq_entries * sizeof(struct io_uring_sqe));
            io_uring_queue_exit(&ring);
        } else {
            printf("%-15s FAILED: %s\n", "custom", strerror(-ret));
        }
    }
    printf("\n");
}

/*
 * Test effect of IORING_SETUP_SQE128 and IORING_SETUP_CQE32 flags
 */
void run_extended_entry_tests(void)
{
    printf("Effect of Extended Entry Sizes (SQE128/CQE32):\n");
    printf("==============================================\n\n");
    
    unsigned int entries = 1024;
    
    printf("Testing with %u entries:\n\n", entries);
    printf("%-20s %-15s %-15s %-12s\n",
           "Configuration", "SQE Size", "CQE Size", "Total Memory");
    printf("--------------------------------------------------------------\n");
    
    /* Standard configuration */
    {
        struct io_uring ring;
        int ret = io_uring_queue_init(entries, &ring, 0);
        if (ret == 0) {
            printf("%-20s %-15s %-15s %-12zu\n",
                   "Standard", "64 bytes", "16 bytes",
                   ring.sq.ring_sz + ring.cq.ring_sz +
                   entries * sizeof(struct io_uring_sqe));
            io_uring_queue_exit(&ring);
        }
    }
    
#ifdef IORING_SETUP_SQE128
    /* SQE128 configuration */
    {
        struct io_uring ring;
        struct io_uring_params params;
        memset(&params, 0, sizeof(params));
        params.flags = IORING_SETUP_SQE128;
        
        int ret = io_uring_queue_init_params(entries, &ring, &params);
        if (ret == 0) {
            printf("%-20s %-15s %-15s %-12zu\n",
                   "SQE128", "128 bytes", "16 bytes",
                   ring.sq.ring_sz + ring.cq.ring_sz +
                   entries * 128);  /* 128-byte SQEs */
            io_uring_queue_exit(&ring);
        } else {
            printf("%-20s Not supported\n", "SQE128");
        }
    }
#else
    printf("%-20s Not available (kernel too old)\n", "SQE128");
#endif

#ifdef IORING_SETUP_CQE32
    /* CQE32 configuration */
    {
        struct io_uring ring;
        struct io_uring_params params;
        memset(&params, 0, sizeof(params));
        params.flags = IORING_SETUP_CQE32;
        
        int ret = io_uring_queue_init_params(entries, &ring, &params);
        if (ret == 0) {
            printf("%-20s %-15s %-15s %-12zu\n",
                   "CQE32", "64 bytes", "32 bytes",
                   ring.sq.ring_sz + ring.cq.ring_sz +
                   entries * sizeof(struct io_uring_sqe));
            io_uring_queue_exit(&ring);
        } else {
            printf("%-20s Not supported\n", "CQE32");
        }
    }
#else
    printf("%-20s Not available (kernel too old)\n", "CQE32");
#endif

#if defined(IORING_SETUP_SQE128) && defined(IORING_SETUP_CQE32)
    /* Both extended */
    {
        struct io_uring ring;
        struct io_uring_params params;
        memset(&params, 0, sizeof(params));
        params.flags = IORING_SETUP_SQE128 | IORING_SETUP_CQE32;
        
        int ret = io_uring_queue_init_params(entries, &ring, &params);
        if (ret == 0) {
            printf("%-20s %-15s %-15s %-12zu\n",
                   "SQE128 + CQE32", "128 bytes", "32 bytes",
                   ring.sq.ring_sz + ring.cq.ring_sz +
                   entries * 128);
            io_uring_queue_exit(&ring);
        } else {
            printf("%-20s Not supported\n", "SQE128 + CQE32");
        }
    }
#endif
    
    printf("\n");
}

/*
 * Test maximum ring sizes based on MEMLOCK limit
 */
void run_memlock_tests(void)
{
    printf("Maximum Ring Size vs MEMLOCK Limit:\n");
    printf("===================================\n\n");
    
    unsigned long memlock = get_memlock_limit();
    printf("Current MEMLOCK limit: ");
    if (memlock == RLIM_INFINITY) {
        printf("unlimited\n\n");
    } else {
        printf("%lu bytes (%lu KB)\n\n", memlock, memlock / 1024);
    }
    
    /* Try to find maximum working ring size */
    printf("Finding maximum working ring size...\n\n");
    
    unsigned int max_working = 0;
    unsigned int test_size = 32768;  /* Start from max */
    
    while (test_size >= 1) {
        struct io_uring ring;
        int ret = io_uring_queue_init(test_size, &ring, 0);
        if (ret == 0) {
            if (test_size > max_working) {
                max_working = test_size;
            }
            io_uring_queue_exit(&ring);
            break;
        }
        test_size /= 2;
    }
    
    if (max_working > 0) {
        /* Calculate memory for max working size */
        struct io_uring ring;
        int ret = io_uring_queue_init(max_working, &ring, 0);
        if (ret == 0) {
            size_t total = ring.sq.ring_sz + ring.cq.ring_sz + 
                          ring.sq.ring_entries * sizeof(struct io_uring_sqe);
            printf("Maximum working ring size: %u entries\n", max_working);
            printf("Memory required: %zu bytes (%zu KB)\n", total, total / 1024);
            io_uring_queue_exit(&ring);
        }
    } else {
        printf("Could not create any io_uring instance!\n");
    }
    printf("\n");
}

/*
 * Test multiple concurrent rings
 */
void run_concurrent_rings_test(void)
{
    printf("Multiple Concurrent Rings Test:\n");
    printf("===============================\n\n");
    
    printf("Testing how many rings can be created concurrently...\n\n");
    
    #define MAX_RINGS 64
    struct io_uring rings[MAX_RINGS];
    int ring_count = 0;
    size_t mem_before, mem_after;
    
    mem_before = get_process_memory_usage();
    
    for (int i = 0; i < MAX_RINGS; i++) {
        int ret = io_uring_queue_init(256, &rings[i], 0);
        if (ret < 0) {
            printf("Failed to create ring %d: %s\n", i + 1, strerror(-ret));
            break;
        }
        ring_count++;
    }
    
    mem_after = get_process_memory_usage();
    
    printf("Successfully created %d rings with 256 entries each\n", ring_count);
    printf("Memory before: %zu bytes\n", mem_before);
    printf("Memory after:  %zu bytes\n", mem_after);
    printf("Memory delta:  %zu bytes (%zu bytes per ring)\n",
           mem_after - mem_before,
           ring_count > 0 ? (mem_after - mem_before) / ring_count : 0);
    
    /* Cleanup */
    for (int i = 0; i < ring_count; i++) {
        io_uring_queue_exit(&rings[i]);
    }
    
    printf("\n");
}

/*
 * Generate summary and recommendations
 */
void print_summary_and_recommendations(void)
{
    printf("==========================================================================\n");
    printf("                    Summary and Recommendations                           \n");
    printf("==========================================================================\n\n");
    
    printf("Key Findings:\n");
    printf("-------------\n");
    printf("1. Each SQE (Submission Queue Entry) is %zu bytes\n", 
           sizeof(struct io_uring_sqe));
    printf("2. Each CQE (Completion Queue Entry) is %zu bytes\n",
           sizeof(struct io_uring_cqe));
    printf("3. Ring entry counts are always rounded up to power of 2\n");
    printf("4. Default CQ size is 2x SQ size\n");
    printf("5. Memory is allocated in page-size units (%ld bytes)\n\n",
           sysconf(_SC_PAGESIZE));
    
    printf("Tuning Recommendations:\n");
    printf("-----------------------\n");
    printf("1. RLIMIT_MEMLOCK: Increase for large rings\n");
    printf("   - Current: %lu bytes\n", get_memlock_limit());
    printf("   - Adjust via: ulimit -l <value_kb>\n\n");
    
    printf("2. Entry Count Selection:\n");
    printf("   - Low latency: Use smaller rings (32-256 entries)\n");
    printf("   - High throughput: Use larger rings (1024-4096 entries)\n");
    printf("   - Memory constrained: Balance entries vs count\n\n");
    
    printf("3. CQ Size Optimization:\n");
    printf("   - Use IORING_SETUP_CQSIZE for bursty workloads\n");
    printf("   - Set CQ 4-8x SQ for producer-consumer patterns\n\n");
    
    printf("4. Memory Formula (approximate):\n");
    printf("   Total = SQ_ring + CQ_ring + SQE_array\n");
    printf("   Where:\n");
    printf("   - SQ_ring ≈ page_align(128 + 4*sq_entries)\n");
    printf("   - CQ_ring ≈ page_align(128 + 16*cq_entries)\n");
    printf("   - SQE_array ≈ page_align(64*sq_entries)\n\n");
}

int main(int argc, char *argv[])
{
    print_header();
    print_system_info();
    print_structure_sizes();
    
    run_entry_count_tests();
    run_cqsize_tests();
    run_extended_entry_tests();
    run_memlock_tests();
    run_concurrent_rings_test();
    
    print_summary_and_recommendations();
    
    return 0;
}
