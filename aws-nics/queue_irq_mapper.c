/*
 * NIC Queue-IRQ-CPU Mapper
 * 
 * This program demonstrates the mapping relationships between:
 * - Network interface queues (TX/RX)
 * - MSI-X interrupt vectors
 * - CPU affinity
 * - PCI device configuration
 *
 * Particularly useful for understanding AWS ENA architecture.
 *
 * Compile: gcc -o queue_irq_mapper queue_irq_mapper.c -Wall -Wextra
 * Run: sudo ./queue_irq_mapper <interface>
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>

#define MAX_PATH 512
#define MAX_QUEUES 64
#define MAX_CPUS 256

/* Queue to IRQ mapping structure */
typedef struct {
    int queue_id;
    char queue_type[8];  /* "tx" or "rx" */
    int irq_number;
    char irq_name[128];
    unsigned int affinity_mask;
    char affinity_list[64];
    unsigned long long irq_count;
    int rps_cpus;  /* For RX queues */
    int xps_cpus;  /* For TX queues */
} queue_mapping_t;

/* Helper function to read sysfs files */
static int read_sysfs_file(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    
    ssize_t n = read(fd, buf, len - 1);
    close(fd);
    
    if (n < 0) return -1;
    buf[n] = '\0';
    
    /* Strip trailing whitespace */
    while (n > 0 && isspace(buf[n-1])) buf[--n] = '\0';
    return 0;
}

/* Parse CPU mask from hex string */
static unsigned int parse_cpu_mask(const char *hex_str)
{
    unsigned int mask = 0;
    const char *p = hex_str;
    
    /* Skip "0x" prefix if present */
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        p += 2;
    }
    
    /* Skip leading zeros and commas */
    while (*p == '0' || *p == ',') p++;
    
    /* Parse remaining hex digits */
    while (*p) {
        if (*p == ',') {
            p++;
            continue;
        }
        mask = mask * 16;
        if (*p >= '0' && *p <= '9') {
            mask += *p - '0';
        } else if (*p >= 'a' && *p <= 'f') {
            mask += *p - 'a' + 10;
        } else if (*p >= 'A' && *p <= 'F') {
            mask += *p - 'A' + 10;
        }
        p++;
    }
    
    return mask;
}

/* Find IRQ for a given interface and queue */
static int find_queue_irq(const char *ifname, int queue_id, const char *queue_type,
                          int *irq_out, char *irq_name_out, unsigned long long *count_out)
{
    FILE *fp;
    char line[4096];
    char search_pattern[128];
    
    /* Build search pattern - ENA uses patterns like "ena-Tx-0" or "eth0-TxRx-0" */
    snprintf(search_pattern, sizeof(search_pattern), "%s-%s", 
             ifname, queue_type);
    
    fp = fopen("/proc/interrupts", "r");
    if (!fp) return -1;
    
    /* Skip header */
    fgets(line, sizeof(line), fp);
    
    while (fgets(line, sizeof(line), fp)) {
        char *name_pos;
        int irq;
        
        /* Check for our interface pattern */
        if ((name_pos = strstr(line, ifname)) != NULL ||
            (name_pos = strstr(line, "ena")) != NULL) {
            
            /* Extract IRQ number */
            char *colon = strchr(line, ':');
            if (!colon) continue;
            
            *colon = '\0';
            irq = atoi(line);
            
            /* Check if this matches our queue */
            char queue_str[32];
            snprintf(queue_str, sizeof(queue_str), "-%d", queue_id);
            
            if (strstr(name_pos, queue_str) || 
                (queue_id == 0 && strstr(name_pos, "mgmt"))) {
                
                *irq_out = irq;
                
                /* Extract IRQ name */
                char *last_space = strrchr(name_pos, ' ');
                if (last_space) {
                    while (*last_space == ' ') last_space++;
                    char *newline = strchr(last_space, '\n');
                    if (newline) *newline = '\0';
                    strncpy(irq_name_out, last_space, 127);
                } else {
                    char *newline = strchr(name_pos, '\n');
                    if (newline) *newline = '\0';
                    strncpy(irq_name_out, name_pos, 127);
                }
                
                /* Sum up IRQ counts */
                *count_out = 0;
                char *p = colon + 1;
                while (*p) {
                    while (*p && isspace(*p)) p++;
                    if (!*p || !isdigit(*p)) break;
                    *count_out += strtoull(p, &p, 10);
                }
                
                fclose(fp);
                return 0;
            }
        }
    }
    
    fclose(fp);
    return -1;
}

/* Get IRQ affinity information */
static int get_irq_affinity(int irq, unsigned int *mask, char *list)
{
    char path[MAX_PATH];
    char buf[128];
    
    snprintf(path, sizeof(path), "/proc/irq/%d/smp_affinity", irq);
    if (read_sysfs_file(path, buf, sizeof(buf)) == 0) {
        *mask = parse_cpu_mask(buf);
    } else {
        *mask = 0;
    }
    
    snprintf(path, sizeof(path), "/proc/irq/%d/smp_affinity_list", irq);
    if (read_sysfs_file(path, list, 64) != 0) {
        strcpy(list, "N/A");
    }
    
    return 0;
}

/* Get RPS/XPS configuration */
static int get_steering_config(const char *ifname, int queue_id, 
                                const char *queue_type, int *cpus)
{
    char path[MAX_PATH];
    char buf[128];
    
    if (strcmp(queue_type, "rx") == 0) {
        snprintf(path, sizeof(path), 
                 "/sys/class/net/%s/queues/rx-%d/rps_cpus", ifname, queue_id);
    } else {
        snprintf(path, sizeof(path), 
                 "/sys/class/net/%s/queues/tx-%d/xps_cpus", ifname, queue_id);
    }
    
    if (read_sysfs_file(path, buf, sizeof(buf)) == 0) {
        *cpus = parse_cpu_mask(buf);
        return 0;
    }
    
    *cpus = 0;
    return -1;
}

/* Count queues for an interface */
static int count_queues(const char *ifname, const char *queue_type)
{
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "/sys/class/net/%s/queues", ifname);
    
    DIR *dir = opendir(path);
    if (!dir) return 0;
    
    int count = 0;
    struct dirent *entry;
    
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, queue_type, strlen(queue_type)) == 0 &&
            entry->d_name[strlen(queue_type)] == '-') {
            count++;
        }
    }
    
    closedir(dir);
    return count;
}

/* Get PCI information */
static void print_pci_info(const char *ifname)
{
    char path[MAX_PATH];
    char buf[256];
    char link_target[256];
    
    printf("\n╔════════════════════════════════════════════════════════════════╗\n");
    printf("║                    PCI Device Information                       ║\n");
    printf("╠════════════════════════════════════════════════════════════════╣\n");
    
    /* Get PCI address */
    snprintf(path, sizeof(path), "/sys/class/net/%s/device", ifname);
    ssize_t len = readlink(path, link_target, sizeof(link_target) - 1);
    if (len > 0) {
        link_target[len] = '\0';
        char *pci_addr = strrchr(link_target, '/');
        if (pci_addr) {
            printf("║  PCI Address: %-47s ║\n", pci_addr + 1);
            
            /* Get vendor/device */
            char pci_path[MAX_PATH];
            snprintf(pci_path, sizeof(pci_path), 
                     "/sys/bus/pci/devices/%s/vendor", pci_addr + 1);
            if (read_sysfs_file(pci_path, buf, sizeof(buf)) == 0) {
                printf("║  Vendor ID: %-49s ║\n", buf);
            }
            
            snprintf(pci_path, sizeof(pci_path), 
                     "/sys/bus/pci/devices/%s/device", pci_addr + 1);
            if (read_sysfs_file(pci_path, buf, sizeof(buf)) == 0) {
                printf("║  Device ID: %-49s ║\n", buf);
            }
            
            /* Get driver */
            snprintf(pci_path, sizeof(pci_path), 
                     "/sys/bus/pci/devices/%s/driver", pci_addr + 1);
            len = readlink(pci_path, link_target, sizeof(link_target) - 1);
            if (len > 0) {
                link_target[len] = '\0';
                char *driver = strrchr(link_target, '/');
                if (driver) {
                    printf("║  Driver: %-52s ║\n", driver + 1);
                }
            }
            
            /* Get NUMA node */
            snprintf(pci_path, sizeof(pci_path), 
                     "/sys/bus/pci/devices/%s/numa_node", pci_addr + 1);
            if (read_sysfs_file(pci_path, buf, sizeof(buf)) == 0) {
                printf("║  NUMA Node: %-49s ║\n", buf);
            }
        }
    }
    
    printf("╚════════════════════════════════════════════════════════════════╝\n");
}

/* Print the mapping table */
static void print_mapping_table(const char *ifname, queue_mapping_t *mappings, 
                                 int num_mappings)
{
    printf("\n╔════════════════════════════════════════════════════════════════╗\n");
    printf("║              Queue → IRQ → CPU Mapping Table                    ║\n");
    printf("╠════════════════════════════════════════════════════════════════╣\n");
    printf("║ Queue    │ IRQ    │ CPU Affinity  │ IRQ Count    │ Steering    ║\n");
    printf("╠══════════╪════════╪═══════════════╪══════════════╪═════════════╣\n");
    
    for (int i = 0; i < num_mappings; i++) {
        queue_mapping_t *m = &mappings[i];
        char steering[16] = "N/A";
        
        if (strcmp(m->queue_type, "rx") == 0 && m->rps_cpus) {
            snprintf(steering, sizeof(steering), "RPS:0x%x", m->rps_cpus);
        } else if (strcmp(m->queue_type, "tx") == 0 && m->xps_cpus) {
            snprintf(steering, sizeof(steering), "XPS:0x%x", m->xps_cpus);
        }
        
        printf("║ %s-%-5d │ %-6d │ %-13s │ %-12llu │ %-11s ║\n",
               m->queue_type, m->queue_id,
               m->irq_number,
               m->affinity_list,
               m->irq_count,
               steering);
    }
    
    printf("╚════════════════════════════════════════════════════════════════╝\n");
}

/* Print ASCII diagram of the relationships */
static void print_relationship_diagram(const char *ifname, int num_tx, int num_rx)
{
    printf("\n");
    printf("┌──────────────────────────────────────────────────────────────────┐\n");
    printf("│             Network Interface: %-32s │\n", ifname);
    printf("├──────────────────────────────────────────────────────────────────┤\n");
    printf("│                                                                  │\n");
    printf("│  Application Layer                                               │\n");
    printf("│       │                                                          │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │                Linux Socket/Network Stack                  │  │\n");
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│       │                                                          │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │                   Network Device (netdev)                  │  │\n");
    printf("│  │                                                            │  │\n");
    
    /* TX Queues */
    printf("│  │   TX Queues (%d):                                           │  │\n", num_tx);
    printf("│  │   ");
    for (int i = 0; i < num_tx && i < 8; i++) {
        printf("[Q%d]", i);
    }
    if (num_tx > 8) printf("...");
    printf("\n");
    
    /* RX Queues */
    printf("│  │   RX Queues (%d):                                           │  │\n", num_rx);
    printf("│  │   ");
    for (int i = 0; i < num_rx && i < 8; i++) {
        printf("[Q%d]", i);
    }
    if (num_rx > 8) printf("...");
    printf("\n");
    
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│       │                                                          │\n");
    printf("│       │ Each queue pair shares one MSI-X vector                  │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │                   Driver (ENA / vfio / etc)                │  │\n");
    printf("│  │                                                            │  │\n");
    printf("│  │   MSI-X Vectors: [Mgmt][Q0][Q1][Q2]...                     │  │\n");
    printf("│  │                    │    │   │   │                          │  │\n");
    printf("│  │                    ▼    ▼   ▼   ▼                          │  │\n");
    printf("│  │   IRQ Numbers:   [N] [N+1][N+2][N+3]...                    │  │\n");
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│       │                                                          │\n");
    printf("│       │ IRQ Affinity determines which CPU handles interrupt      │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │                     CPUs (NAPI Processing)                 │  │\n");
    printf("│  │                                                            │  │\n");
    printf("│  │   [CPU0] [CPU1] [CPU2] [CPU3] ... [CPUN]                   │  │\n");
    printf("│  │      ↑      ↑      ↑      ↑                                │  │\n");
    printf("│  │   IRQ affinity binds interrupts to specific CPUs           │  │\n");
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│       │                                                          │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │                    PCIe Interface                          │  │\n");
    printf("│  │   - BAR0: MMIO Registers                                   │  │\n");
    printf("│  │   - BAR2: LLQ Region (write-combine)                       │  │\n");
    printf("│  │   - BAR4: MSI-X Table                                      │  │\n");
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│       │                                                          │\n");
    printf("│       ▼                                                          │\n");
    printf("│  ┌────────────────────────────────────────────────────────────┐  │\n");
    printf("│  │              Physical NIC (Nitro Card)                     │  │\n");
    printf("│  │                                                            │  │\n");
    printf("│  │   For SR-IOV:                                              │  │\n");
    printf("│  │   ┌─────────┐                                              │  │\n");
    printf("│  │   │   PF    │ ← Physical Function (hypervisor/bare metal)  │  │\n");
    printf("│  │   ├────┬────┤                                              │  │\n");
    printf("│  │   │VF0 │VF1 │ ← Virtual Functions (guest VMs)              │  │\n");
    printf("│  │   └────┴────┘                                              │  │\n");
    printf("│  └────────────────────────────────────────────────────────────┘  │\n");
    printf("│                                                                  │\n");
    printf("└──────────────────────────────────────────────────────────────────┘\n");
}

int main(int argc, char *argv[])
{
    if (argc != 2) {
        printf("Usage: %s <interface>\n", argv[0]);
        printf("Example: %s ens5\n", argv[0]);
        printf("\nThis tool displays the mapping between:\n");
        printf("  - Network queues (TX/RX)\n");
        printf("  - Interrupt (IRQ) numbers\n");
        printf("  - CPU affinity\n");
        printf("  - PCI device configuration\n");
        return 1;
    }
    
    const char *ifname = argv[1];
    
    /* Check if interface exists */
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "/sys/class/net/%s", ifname);
    if (access(path, F_OK) != 0) {
        fprintf(stderr, "Error: Interface '%s' not found\n", ifname);
        return 1;
    }
    
    printf("\n");
    printf("════════════════════════════════════════════════════════════════════\n");
    printf("          NIC Queue-IRQ-CPU Mapping Analysis for: %s\n", ifname);
    printf("════════════════════════════════════════════════════════════════════\n");
    
    /* Print PCI info */
    print_pci_info(ifname);
    
    /* Count queues */
    int num_tx = count_queues(ifname, "tx");
    int num_rx = count_queues(ifname, "rx");
    
    printf("\n  TX Queues: %d\n", num_tx);
    printf("  RX Queues: %d\n", num_rx);
    
    /* Build mapping table */
    queue_mapping_t mappings[MAX_QUEUES * 2];
    int num_mappings = 0;
    
    /* Map TX queues */
    for (int i = 0; i < num_tx && num_mappings < MAX_QUEUES * 2; i++) {
        queue_mapping_t *m = &mappings[num_mappings];
        memset(m, 0, sizeof(*m));
        
        m->queue_id = i;
        strcpy(m->queue_type, "tx");
        
        if (find_queue_irq(ifname, i, "Tx", &m->irq_number, 
                          m->irq_name, &m->irq_count) == 0 ||
            find_queue_irq(ifname, i, "TxRx", &m->irq_number,
                          m->irq_name, &m->irq_count) == 0) {
            get_irq_affinity(m->irq_number, &m->affinity_mask, m->affinity_list);
        }
        
        get_steering_config(ifname, i, "tx", &m->xps_cpus);
        num_mappings++;
    }
    
    /* Map RX queues */
    for (int i = 0; i < num_rx && num_mappings < MAX_QUEUES * 2; i++) {
        queue_mapping_t *m = &mappings[num_mappings];
        memset(m, 0, sizeof(*m));
        
        m->queue_id = i;
        strcpy(m->queue_type, "rx");
        
        if (find_queue_irq(ifname, i, "Rx", &m->irq_number,
                          m->irq_name, &m->irq_count) == 0 ||
            find_queue_irq(ifname, i, "TxRx", &m->irq_number,
                          m->irq_name, &m->irq_count) == 0) {
            get_irq_affinity(m->irq_number, &m->affinity_mask, m->affinity_list);
        }
        
        get_steering_config(ifname, i, "rx", &m->rps_cpus);
        num_mappings++;
    }
    
    /* Print mapping table */
    print_mapping_table(ifname, mappings, num_mappings);
    
    /* Print relationship diagram */
    print_relationship_diagram(ifname, num_tx, num_rx);
    
    /* Validation notes */
    printf("\n════════════════════════════════════════════════════════════════════\n");
    printf("                         Validation Notes\n");
    printf("════════════════════════════════════════════════════════════════════\n");
    printf("\n");
    printf("  ✓ Driver Tuning Effects on Physical NIC:\n");
    printf("    • Queue count changes affect parallelism, not hardware limits\n");
    printf("    • IRQ affinity affects CPU load distribution, not NIC behavior\n");
    printf("    • Ring buffer sizes affect host memory usage and burst capacity\n");
    printf("    • Interrupt coalescing affects latency/throughput tradeoff\n");
    printf("\n");
    printf("  ✓ SR-IOV Relationship:\n");
    printf("    • PF (Physical Function) = Full device access (bare metal)\n");
    printf("    • VF (Virtual Function) = Lightweight, guest-accessible device\n");
    printf("    • AWS exposes VFs to EC2 instances; Nitro Card manages PF\n");
    printf("    • VF driver (ENA) sees device as regular PCIe endpoint\n");
    printf("\n");
    printf("  ✓ Optimal Configuration:\n");
    printf("    • Match queue count to active CPUs handling network I/O\n");
    printf("    • Pin IRQs to specific CPUs (disable irqbalance for control)\n");
    printf("    • Use NUMA-local CPUs for IRQ processing\n");
    printf("    • Enable adaptive interrupt moderation for varying loads\n");
    printf("\n");
    
    return 0;
}
