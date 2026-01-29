/*
 * io_uring RLIMIT_MEMLOCK Sliding Scale Analysis
 * ================================================
 * 
 * This program creates a comprehensive matrix showing:
 * - How many io_uring rings of various sizes can be created
 * - At different RLIMIT_MEMLOCK settings
 * - Memory consumption per configuration
 * 
 * It demonstrates the relationship between OS tunables and io_uring capacity.
 * 
 * Compile: gcc -o rlimit_scale_test rlimit_scale_test.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

/*
 * io_uring constants
 */
#define IORING_MAX_ENTRIES      32768
#define SQE_SIZE                64
#define CQE_SIZE                16
#define SQ_RING_HEADER          128
#define CQ_RING_HEADER          128

/*
 * Common RLIMIT_MEMLOCK values in KB
 */
typedef struct {
    const char *name;
    unsigned long kb;
} memlock_preset_t;

static memlock_preset_t memlock_presets[] = {
    {"Default (64 KB)",          64},
    {"Low (256 KB)",             256},
    {"Medium (1 MB)",            1024},
    {"High (8 MB)",              8192},
    {"Very High (64 MB)",        65536},
    {"Large (256 MB)",           262144},
    {"Very Large (1 GB)",        1048576},
    {"Unlimited (4 GB cap)",     4194304}
};
#define NUM_PRESETS (sizeof(memlock_presets) / sizeof(memlock_presets[0]))

/*
 * Ring size configurations to test
 */
typedef struct {
    const char *name;
    unsigned int sq_entries;
    unsigned int cq_multiplier;  /* CQ = SQ * multiplier */
} ring_config_t;

static ring_config_t ring_configs[] = {
    {"Tiny (32 entries)",        32,  2},
    {"Small (128 entries)",      128, 2},
    {"Medium (512 entries)",     512, 2},
    {"Standard (1K entries)",    1024, 2},
    {"Large (4K entries)",       4096, 2},
    {"XLarge (8K entries)",      8192, 2},
    {"Huge (16K entries)",       16384, 2},
    {"Max (32K entries)",        32768, 2}
};
#define NUM_CONFIGS (sizeof(ring_configs) / sizeof(ring_configs[0]))

/*
 * Round up to power of 2
 */
static unsigned int roundup_pow2(unsigned int x) {
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
static size_t page_align(size_t size) {
    long page_size = sysconf(_SC_PAGESIZE);
    return ((size + page_size - 1) / page_size) * page_size;
}

/*
 * Calculate memory for a single ring
 */
static size_t calculate_ring_memory(unsigned int sq_entries, unsigned int cq_multiplier) {
    unsigned int actual_sq = roundup_pow2(sq_entries);
    unsigned int actual_cq = actual_sq * cq_multiplier;
    
    if (actual_sq > IORING_MAX_ENTRIES) actual_sq = IORING_MAX_ENTRIES;
    if (actual_cq > IORING_MAX_ENTRIES * 2) actual_cq = IORING_MAX_ENTRIES * 2;
    
    size_t sq_ring = page_align(SQ_RING_HEADER + actual_sq * sizeof(unsigned int));
    size_t cq_ring = page_align(CQ_RING_HEADER + actual_cq * CQE_SIZE);
    size_t sqe_array = page_align(actual_sq * SQE_SIZE);
    
    return sq_ring + cq_ring + sqe_array;
}

/*
 * Calculate how many rings fit in a memlock limit
 */
static unsigned int rings_in_limit(size_t per_ring_bytes, unsigned long limit_kb) {
    unsigned long limit_bytes = limit_kb * 1024;
    if (per_ring_bytes == 0) return 0;
    return (unsigned int)(limit_bytes / per_ring_bytes);
}

/*
 * Format bytes for human readability
 */
static void format_bytes(size_t bytes, char *buf, size_t buflen) {
    if (bytes >= 1024 * 1024 * 1024) {
        snprintf(buf, buflen, "%.1f GB", (double)bytes / (1024 * 1024 * 1024));
    } else if (bytes >= 1024 * 1024) {
        snprintf(buf, buflen, "%.1f MB", (double)bytes / (1024 * 1024));
    } else if (bytes >= 1024) {
        snprintf(buf, buflen, "%.1f KB", (double)bytes / 1024);
    } else {
        snprintf(buf, buflen, "%zu B", bytes);
    }
}

/*
 * Print title and explanation
 */
static void print_header(void) {
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║         RLIMIT_MEMLOCK Sliding Scale Analysis for io_uring                  ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");
    
    printf("This analysis shows how many io_uring rings of various sizes can be created\n");
    printf("at different RLIMIT_MEMLOCK settings. This helps capacity planning and\n");
    printf("system tuning for io_uring-based applications.\n\n");
    
    printf("System Configuration:\n");
    printf("  Page Size: %ld bytes\n", sysconf(_SC_PAGESIZE));
    printf("  SQE Size:  %d bytes\n", SQE_SIZE);
    printf("  CQE Size:  %d bytes\n", CQE_SIZE);
    printf("  Max Entries: %d\n\n", IORING_MAX_ENTRIES);
}

/*
 * Print per-ring memory table
 */
static void print_ring_memory_table(void) {
    printf("┌─────────────────────────────────────────────────────────────────────────────┐\n");
    printf("│                    Per-Ring Memory Consumption                              │\n");
    printf("├─────────────────────────────────────────────────────────────────────────────┤\n");
    printf("│ %-25s │ %-12s │ %-12s │ %-15s │\n", 
           "Ring Configuration", "SQ Entries", "CQ Entries", "Memory/Ring");
    printf("├─────────────────────────────────────────────────────────────────────────────┤\n");
    
    for (int i = 0; i < NUM_CONFIGS; i++) {
        unsigned int actual_sq = roundup_pow2(ring_configs[i].sq_entries);
        unsigned int actual_cq = actual_sq * ring_configs[i].cq_multiplier;
        size_t mem = calculate_ring_memory(ring_configs[i].sq_entries, 
                                           ring_configs[i].cq_multiplier);
        char mem_str[32];
        format_bytes(mem, mem_str, sizeof(mem_str));
        
        printf("│ %-25s │ %-12u │ %-12u │ %-15s │\n",
               ring_configs[i].name, actual_sq, actual_cq, mem_str);
    }
    printf("└─────────────────────────────────────────────────────────────────────────────┘\n\n");
}

/*
 * Print the sliding scale matrix
 */
static void print_sliding_scale_matrix(void) {
    printf("┌─────────────────────────────────────────────────────────────────────────────┐\n");
    printf("│              Maximum Rings per RLIMIT_MEMLOCK Setting                       │\n");
    printf("├─────────────────────────────────────────────────────────────────────────────┤\n");
    
    /* Print column headers (memlock settings) */
    printf("│ %-17s │", "Ring Size");
    for (int j = 0; j < 6; j++) {  /* Show first 6 presets */
        printf(" %-8s│", memlock_presets[j].name);
    }
    printf("\n");
    printf("├─────────────────────────────────────────────────────────────────────────────┤\n");
    
    /* Print rows (ring configurations) */
    for (int i = 0; i < NUM_CONFIGS; i++) {
        size_t per_ring = calculate_ring_memory(ring_configs[i].sq_entries,
                                                ring_configs[i].cq_multiplier);
        
        printf("│ %-17s │", ring_configs[i].name);
        for (int j = 0; j < 6; j++) {
            unsigned int count = rings_in_limit(per_ring, memlock_presets[j].kb);
            if (count == 0) {
                printf(" %-8s│", "0");
            } else if (count > 9999) {
                printf(" %-8s│", ">9999");
            } else {
                printf(" %-8u│", count);
            }
        }
        printf("\n");
    }
    printf("└─────────────────────────────────────────────────────────────────────────────┘\n\n");
}

/*
 * Print detailed sliding scale with memory breakdowns
 */
static void print_detailed_scale(void) {
    printf("┌─────────────────────────────────────────────────────────────────────────────┐\n");
    printf("│                    Detailed Capacity Analysis                               │\n");
    printf("└─────────────────────────────────────────────────────────────────────────────┘\n\n");
    
    for (int j = 0; j < NUM_PRESETS; j++) {
        printf("RLIMIT_MEMLOCK = %s (%lu KB = %lu bytes)\n", 
               memlock_presets[j].name,
               memlock_presets[j].kb,
               memlock_presets[j].kb * 1024);
        printf("─────────────────────────────────────────────────────────────\n");
        
        printf("%-22s  %-12s  %-12s  %-12s\n", 
               "Ring Configuration", "Per Ring", "Max Rings", "Total Used");
        printf("%-22s  %-12s  %-12s  %-12s\n", 
               "──────────────────", "────────", "─────────", "──────────");
        
        for (int i = 0; i < NUM_CONFIGS; i++) {
            size_t per_ring = calculate_ring_memory(ring_configs[i].sq_entries,
                                                    ring_configs[i].cq_multiplier);
            unsigned int max_rings = rings_in_limit(per_ring, memlock_presets[j].kb);
            size_t total_used = max_rings * per_ring;
            
            char per_ring_str[32], total_str[32];
            format_bytes(per_ring, per_ring_str, sizeof(per_ring_str));
            format_bytes(total_used, total_str, sizeof(total_str));
            
            printf("%-22s  %-12s  %-12u  %-12s\n",
                   ring_configs[i].name, per_ring_str, max_rings, total_str);
        }
        printf("\n");
    }
}

/*
 * Print use case recommendations
 */
static void print_recommendations(void) {
    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║                    Tuning Recommendations by Use Case                        ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");
    
    printf("1. SINGLE APPLICATION / DESKTOP USE\n");
    printf("   ─────────────────────────────────\n");
    printf("   Typical: 1-4 rings, 256-1024 entries each\n");
    printf("   Minimum RLIMIT_MEMLOCK: 1 MB\n");
    printf("   Recommended: 8 MB (provides headroom)\n");
    printf("   Configuration:\n");
    printf("     ulimit -l 8192\n");
    printf("   Or in /etc/security/limits.conf:\n");
    printf("     * soft memlock 8192\n");
    printf("     * hard memlock 8192\n\n");
    
    printf("2. HIGH-PERFORMANCE SERVER (Database, Web Server)\n");
    printf("   ───────────────────────────────────────────────\n");
    printf("   Typical: 8-64 rings (per-CPU), 1024-4096 entries each\n");
    printf("   Minimum RLIMIT_MEMLOCK: 64 MB\n");
    printf("   Recommended: 256 MB - 1 GB\n");
    printf("   Configuration:\n");
    printf("     ulimit -l 262144  # 256 MB\n");
    printf("   Or in /etc/security/limits.conf:\n");
    printf("     * soft memlock 262144\n");
    printf("     * hard memlock 262144\n\n");
    
    printf("3. EXTREME WORKLOADS (Storage Arrays, Network Appliances)\n");
    printf("   ─────────────────────────────────────────────────────\n");
    printf("   Typical: 64+ rings, 8192-32768 entries each\n");
    printf("   Minimum RLIMIT_MEMLOCK: 1 GB\n");
    printf("   Recommended: Unlimited or 4+ GB\n");
    printf("   Configuration:\n");
    printf("     ulimit -l unlimited\n");
    printf("   Or in /etc/security/limits.conf:\n");
    printf("     * soft memlock unlimited\n");
    printf("     * hard memlock unlimited\n\n");
    
    printf("4. CONTAINERIZED ENVIRONMENTS (Docker, Kubernetes)\n");
    printf("   ────────────────────────────────────────────────\n");
    printf("   Note: Containers inherit limits from host or need explicit configuration\n");
    printf("   Docker Compose:\n");
    printf("     services:\n");
    printf("       myapp:\n");
    printf("         ulimits:\n");
    printf("           memlock:\n");
    printf("             soft: 262144\n");
    printf("             hard: 262144\n");
    printf("   Kubernetes:\n");
    printf("     securityContext:\n");
    printf("       capabilities:\n");
    printf("         add: [\"IPC_LOCK\"]\n\n");
}

/*
 * Print OS configuration methods
 */
static void print_os_configuration(void) {
    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║              How to Configure RLIMIT_MEMLOCK in Linux                        ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");
    
    printf("RLIMIT_MEMLOCK controls the maximum amount of memory that can be locked\n");
    printf("(prevented from being swapped out) by a process. io_uring rings are\n");
    printf("allocated as locked memory, making this the primary constraint.\n\n");
    
    printf("METHOD 1: Temporary (Current Session Only)\n");
    printf("──────────────────────────────────────────\n");
    printf("  # Check current limit (in KB)\n");
    printf("  ulimit -l\n\n");
    printf("  # Set to 256 MB (value in KB)\n");
    printf("  ulimit -l 262144\n\n");
    printf("  # Set to unlimited\n");
    printf("  ulimit -l unlimited\n\n");
    printf("  Note: Can only decrease, not increase, without root privileges.\n\n");
    
    printf("METHOD 2: Permanent (System-Wide via limits.conf)\n");
    printf("────────────────────────────────────────────────\n");
    printf("  Edit /etc/security/limits.conf:\n\n");
    printf("  # Format: <domain> <type> <item> <value>\n");
    printf("  # domain: username, @groupname, or * for all\n");
    printf("  # type: soft (warning) or hard (enforced) or - (both)\n\n");
    printf("  # Set 256 MB limit for all users\n");
    printf("  *  soft  memlock  262144\n");
    printf("  *  hard  memlock  262144\n\n");
    printf("  # Set unlimited for specific user\n");
    printf("  dbuser  soft  memlock  unlimited\n");
    printf("  dbuser  hard  memlock  unlimited\n\n");
    printf("  # Set unlimited for a group\n");
    printf("  @iouring  soft  memlock  unlimited\n");
    printf("  @iouring  hard  memlock  unlimited\n\n");
    printf("  Requires re-login to take effect.\n\n");
    
    printf("METHOD 3: Per-Service (systemd)\n");
    printf("──────────────────────────────\n");
    printf("  In /etc/systemd/system/myservice.service or override file:\n\n");
    printf("  [Service]\n");
    printf("  LimitMEMLOCK=infinity\n");
    printf("  # Or specific value:\n");
    printf("  LimitMEMLOCK=268435456  # 256 MB in bytes\n\n");
    printf("  Then reload and restart:\n");
    printf("  systemctl daemon-reload\n");
    printf("  systemctl restart myservice\n\n");
    
    printf("METHOD 4: Programmatic (Within Application)\n");
    printf("──────────────────────────────────────────\n");
    printf("  #include <sys/resource.h>\n\n");
    printf("  struct rlimit rlim;\n");
    printf("  rlim.rlim_cur = 256 * 1024 * 1024;  // 256 MB soft\n");
    printf("  rlim.rlim_max = 256 * 1024 * 1024;  // 256 MB hard\n");
    printf("  if (setrlimit(RLIMIT_MEMLOCK, &rlim) != 0) {\n");
    printf("      perror(\"setrlimit failed\");\n");
    printf("      // Requires CAP_SYS_RESOURCE capability\n");
    printf("  }\n\n");
    
    printf("METHOD 5: Related Kernel Parameters\n");
    printf("───────────────────────────────────\n");
    printf("  # Maximum number of memory mappings (affects large rings)\n");
    printf("  sysctl -w vm.max_map_count=262144\n\n");
    printf("  # Make persistent in /etc/sysctl.conf:\n");
    printf("  vm.max_map_count=262144\n\n");
    printf("  Note: Linux 5.11+ uses cgroup memory accounting instead of\n");
    printf("  RLIMIT_MEMLOCK for some io_uring operations.\n\n");
}

/*
 * Print verification commands
 */
static void print_verification(void) {
    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║                        Verification Commands                                 ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");
    
    printf("Check current limits:\n");
    printf("  ulimit -l                    # Current shell limit (KB)\n");
    printf("  ulimit -a                    # All limits\n");
    printf("  cat /proc/self/limits        # Detailed view\n");
    printf("  cat /proc/<pid>/limits       # For specific process\n\n");
    
    printf("Check system-wide locked memory:\n");
    printf("  cat /proc/meminfo | grep -i lock\n");
    printf("  # Shows: Mlocked, Unevictable memory\n\n");
    
    printf("Check io_uring memory (if available):\n");
    printf("  cat /proc/<pid>/io_uring     # Per-process io_uring info (newer kernels)\n\n");
    
    printf("Check capabilities:\n");
    printf("  capsh --print                # Current capabilities\n");
    printf("  # CAP_IPC_LOCK: bypass memlock limit\n");
    printf("  # CAP_SYS_RESOURCE: raise limits beyond hard limit\n\n");
}

/*
 * Print formula summary
 */
static void print_formula(void) {
    printf("╔══════════════════════════════════════════════════════════════════════════════╗\n");
    printf("║                    Memory Calculation Formula                                ║\n");
    printf("╚══════════════════════════════════════════════════════════════════════════════╝\n\n");
    
    printf("Per-Ring Memory = SQ_Ring + CQ_Ring + SQE_Array\n\n");
    printf("Where:\n");
    printf("  SQ_Ring   = page_align(128 + 4 × SQ_entries)\n");
    printf("  CQ_Ring   = page_align(128 + 16 × CQ_entries)\n");
    printf("  SQE_Array = page_align(64 × SQ_entries)\n\n");
    printf("  page_align(x) = ceil(x / 4096) × 4096\n\n");
    printf("  CQ_entries = SQ_entries × CQ_multiplier (default: 2)\n\n");
    
    printf("Required RLIMIT_MEMLOCK = Per_Ring_Memory × Number_of_Rings\n\n");
    
    printf("Quick Reference (standard configuration, CQ = 2×SQ):\n");
    printf("  32 entries:    ~12 KB per ring\n");
    printf("  256 entries:   ~32 KB per ring\n");
    printf("  1024 entries:  ~108 KB per ring\n");
    printf("  4096 entries:  ~408 KB per ring\n");
    printf("  32768 entries: ~3.2 MB per ring\n\n");
}

int main(int argc, char *argv[]) {
    print_header();
    print_ring_memory_table();
    print_sliding_scale_matrix();
    print_detailed_scale();
    print_os_configuration();
    print_recommendations();
    print_verification();
    print_formula();
    
    printf("═══════════════════════════════════════════════════════════════════════════════\n");
    printf("                            End of Analysis                                    \n");
    printf("═══════════════════════════════════════════════════════════════════════════════\n");
    
    return 0;
}
