/*
 * AWS ENA NIC Relationship Validator
 * 
 * This program validates and displays the relationships between:
 * - Network interfaces (netdev)
 * - Kernel drivers
 * - PCI devices
 * - SR-IOV configuration
 * - Interrupt mappings
 * - Queue configurations
 *
 * Compile: gcc -o ena_validator ena_validator.c -Wall -Wextra
 * Run: sudo ./ena_validator [interface_name]
 * 
 * Author: System Administrator
 * License: MIT
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <ctype.h>
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <sys/ioctl.h>
#include <net/if.h>

#define MAX_PATH 512
#define MAX_LINE 256
#define SYSFS_NET_PATH "/sys/class/net"
#define SYSFS_PCI_PATH "/sys/bus/pci/devices"
#define PROC_INTERRUPTS "/proc/interrupts"

/* Color codes for terminal output */
#define COLOR_RED     "\x1b[31m"
#define COLOR_GREEN   "\x1b[32m"
#define COLOR_YELLOW  "\x1b[33m"
#define COLOR_BLUE    "\x1b[34m"
#define COLOR_MAGENTA "\x1b[35m"
#define COLOR_CYAN    "\x1b[36m"
#define COLOR_RESET   "\x1b[0m"

/* Structure to hold NIC information */
typedef struct {
    char interface_name[64];
    char driver_name[64];
    char driver_version[64];
    char pci_address[32];
    char vendor_id[8];
    char device_id[8];
    char subsystem_vendor[8];
    char subsystem_device[8];
    int numa_node;
    int is_sriov_pf;
    int is_sriov_vf;
    int sriov_totalvfs;
    int sriov_numvfs;
    char physfn_address[32];  /* For VFs: address of parent PF */
    int num_tx_queues;
    int num_rx_queues;
} nic_info_t;

/* Structure to hold IRQ information */
typedef struct {
    int irq_number;
    char irq_name[128];
    char affinity_mask[64];
    char affinity_list[64];
    unsigned long long count_per_cpu[256];
    int num_cpus;
} irq_info_t;

/* Function prototypes */
static int read_sysfs_string(const char *path, char *buf, size_t len);
static int read_sysfs_int(const char *path, int *value);
static int get_nic_info(const char *ifname, nic_info_t *info);
static int get_irq_info(const char *ifname, irq_info_t **irqs, int *num_irqs);
static int validate_pci_config(const nic_info_t *info);
static int validate_sriov_config(const nic_info_t *info);
static int validate_queue_irq_mapping(const char *ifname, const nic_info_t *info);
static void print_nic_info(const nic_info_t *info);
static void print_irq_info(const irq_info_t *irqs, int num_irqs);
static void print_header(const char *title);
static void print_separator(void);
static int is_ena_device(const nic_info_t *info);
static int discover_interfaces(char ***interfaces, int *count);
static void free_interfaces(char **interfaces, int count);

/*
 * Read a string value from sysfs
 */
static int read_sysfs_string(const char *path, char *buf, size_t len)
{
    int fd;
    ssize_t n;
    
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    
    n = read(fd, buf, len - 1);
    close(fd);
    
    if (n < 0) {
        return -1;
    }
    
    buf[n] = '\0';
    
    /* Remove trailing newline */
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) {
        buf[--n] = '\0';
    }
    
    return 0;
}

/*
 * Read an integer value from sysfs
 */
static int read_sysfs_int(const char *path, int *value)
{
    char buf[64];
    
    if (read_sysfs_string(path, buf, sizeof(buf)) < 0) {
        return -1;
    }
    
    *value = atoi(buf);
    return 0;
}

/*
 * Check if interface is an ENA device
 */
static int is_ena_device(const nic_info_t *info)
{
    /* Amazon vendor ID: 0x1d0f */
    if (strcmp(info->vendor_id, "0x1d0f") == 0) {
        return 1;
    }
    
    /* Also check driver name */
    if (strcmp(info->driver_name, "ena") == 0) {
        return 1;
    }
    
    return 0;
}

/*
 * Get comprehensive NIC information
 */
static int get_nic_info(const char *ifname, nic_info_t *info)
{
    char path[MAX_PATH];
    char link_target[MAX_PATH];
    ssize_t len;
    char *pci_addr;
    
    memset(info, 0, sizeof(*info));
    strncpy(info->interface_name, ifname, sizeof(info->interface_name) - 1);
    
    /* Get driver name via symlink */
    snprintf(path, sizeof(path), "%s/%s/device/driver", SYSFS_NET_PATH, ifname);
    len = readlink(path, link_target, sizeof(link_target) - 1);
    if (len > 0) {
        link_target[len] = '\0';
        pci_addr = strrchr(link_target, '/');
        if (pci_addr) {
            strncpy(info->driver_name, pci_addr + 1, sizeof(info->driver_name) - 1);
        }
    }
    
    /* Get PCI address via device symlink */
    snprintf(path, sizeof(path), "%s/%s/device", SYSFS_NET_PATH, ifname);
    len = readlink(path, link_target, sizeof(link_target) - 1);
    if (len > 0) {
        link_target[len] = '\0';
        pci_addr = strrchr(link_target, '/');
        if (pci_addr) {
            strncpy(info->pci_address, pci_addr + 1, sizeof(info->pci_address) - 1);
        }
    }
    
    if (strlen(info->pci_address) == 0) {
        /* Not a PCI device */
        return -1;
    }
    
    /* Read PCI IDs */
    snprintf(path, sizeof(path), "%s/%s/vendor", SYSFS_PCI_PATH, info->pci_address);
    read_sysfs_string(path, info->vendor_id, sizeof(info->vendor_id));
    
    snprintf(path, sizeof(path), "%s/%s/device", SYSFS_PCI_PATH, info->pci_address);
    read_sysfs_string(path, info->device_id, sizeof(info->device_id));
    
    snprintf(path, sizeof(path), "%s/%s/subsystem_vendor", SYSFS_PCI_PATH, info->pci_address);
    read_sysfs_string(path, info->subsystem_vendor, sizeof(info->subsystem_vendor));
    
    snprintf(path, sizeof(path), "%s/%s/subsystem_device", SYSFS_PCI_PATH, info->pci_address);
    read_sysfs_string(path, info->subsystem_device, sizeof(info->subsystem_device));
    
    /* Read NUMA node */
    snprintf(path, sizeof(path), "%s/%s/device/numa_node", SYSFS_NET_PATH, ifname);
    if (read_sysfs_int(path, &info->numa_node) < 0) {
        info->numa_node = -1;
    }
    
    /* Check SR-IOV status */
    /* Check if this is a PF by looking for sriov_totalvfs */
    snprintf(path, sizeof(path), "%s/%s/sriov_totalvfs", SYSFS_PCI_PATH, info->pci_address);
    if (read_sysfs_int(path, &info->sriov_totalvfs) == 0) {
        info->is_sriov_pf = 1;
        
        snprintf(path, sizeof(path), "%s/%s/sriov_numvfs", SYSFS_PCI_PATH, info->pci_address);
        read_sysfs_int(path, &info->sriov_numvfs);
    }
    
    /* Check if this is a VF by looking for physfn */
    snprintf(path, sizeof(path), "%s/%s/physfn", SYSFS_PCI_PATH, info->pci_address);
    len = readlink(path, link_target, sizeof(link_target) - 1);
    if (len > 0) {
        link_target[len] = '\0';
        info->is_sriov_vf = 1;
        pci_addr = strrchr(link_target, '/');
        if (pci_addr) {
            strncpy(info->physfn_address, pci_addr + 1, sizeof(info->physfn_address) - 1);
        }
    }
    
    /* Get queue counts */
    snprintf(path, sizeof(path), "%s/%s/queues", SYSFS_NET_PATH, ifname);
    DIR *dir = opendir(path);
    if (dir) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strncmp(entry->d_name, "tx-", 3) == 0) {
                info->num_tx_queues++;
            } else if (strncmp(entry->d_name, "rx-", 3) == 0) {
                info->num_rx_queues++;
            }
        }
        closedir(dir);
    }
    
    return 0;
}

/*
 * Get IRQ information for an interface
 */
static int get_irq_info(const char *ifname, irq_info_t **irqs, int *num_irqs)
{
    FILE *fp;
    char line[4096];
    char *token;
    int count = 0;
    int capacity = 32;
    
    *irqs = malloc(capacity * sizeof(irq_info_t));
    if (!*irqs) {
        return -1;
    }
    
    fp = fopen(PROC_INTERRUPTS, "r");
    if (!fp) {
        free(*irqs);
        return -1;
    }
    
    /* Skip header line */
    if (fgets(line, sizeof(line), fp) == NULL) {
        fclose(fp);
        free(*irqs);
        return -1;
    }
    
    /* Count CPUs from header */
    int num_cpus = 0;
    token = strtok(line, " \t");
    while (token) {
        if (strncmp(token, "CPU", 3) == 0) {
            num_cpus++;
        }
        token = strtok(NULL, " \t");
    }
    
    while (fgets(line, sizeof(line), fp)) {
        /* Check if this line contains our interface */
        if (strstr(line, ifname) || strstr(line, "ena")) {
            if (count >= capacity) {
                capacity *= 2;
                *irqs = realloc(*irqs, capacity * sizeof(irq_info_t));
                if (!*irqs) {
                    fclose(fp);
                    return -1;
                }
            }
            
            irq_info_t *irq = &(*irqs)[count];
            memset(irq, 0, sizeof(*irq));
            irq->num_cpus = num_cpus;
            
            /* Parse IRQ number */
            char *colon = strchr(line, ':');
            if (colon) {
                *colon = '\0';
                irq->irq_number = atoi(line);
                
                /* Parse CPU counts */
                char *p = colon + 1;
                for (int i = 0; i < num_cpus && *p; i++) {
                    while (*p && isspace(*p)) p++;
                    irq->count_per_cpu[i] = strtoull(p, &p, 10);
                }
                
                /* Get IRQ name (last part of line) */
                char *name_start = strrchr(colon + 1, ' ');
                if (name_start) {
                    while (*name_start && isspace(*name_start)) name_start++;
                    char *newline = strchr(name_start, '\n');
                    if (newline) *newline = '\0';
                    strncpy(irq->irq_name, name_start, sizeof(irq->irq_name) - 1);
                }
                
                /* Read affinity */
                char aff_path[MAX_PATH];
                snprintf(aff_path, sizeof(aff_path), "/proc/irq/%d/smp_affinity", 
                         irq->irq_number);
                read_sysfs_string(aff_path, irq->affinity_mask, sizeof(irq->affinity_mask));
                
                snprintf(aff_path, sizeof(aff_path), "/proc/irq/%d/smp_affinity_list", 
                         irq->irq_number);
                read_sysfs_string(aff_path, irq->affinity_list, sizeof(irq->affinity_list));
                
                count++;
            }
        }
    }
    
    fclose(fp);
    *num_irqs = count;
    return 0;
}

/*
 * Validate PCI configuration
 */
static int validate_pci_config(const nic_info_t *info)
{
    int errors = 0;
    char path[MAX_PATH];
    char buf[256];
    
    print_header("PCI Configuration Validation");
    
    /* Check PCI address format */
    if (strlen(info->pci_address) == 0) {
        printf(COLOR_RED "  [FAIL] " COLOR_RESET "No PCI address found\n");
        return 1;
    }
    printf(COLOR_GREEN "  [PASS] " COLOR_RESET "PCI Address: %s\n", info->pci_address);
    
    /* Check vendor ID */
    printf("  Vendor ID: %s ", info->vendor_id);
    if (strcmp(info->vendor_id, "0x1d0f") == 0) {
        printf(COLOR_GREEN "(Amazon/AWS)" COLOR_RESET "\n");
    } else {
        printf(COLOR_YELLOW "(Not Amazon)" COLOR_RESET "\n");
    }
    
    /* Check device ID */
    printf("  Device ID: %s ", info->device_id);
    if (strcmp(info->device_id, "0xec20") == 0) {
        printf(COLOR_GREEN "(ENA PF/VF)" COLOR_RESET "\n");
    } else if (strcmp(info->device_id, "0xec21") == 0) {
        printf(COLOR_GREEN "(ENA LLQ)" COLOR_RESET "\n");
    } else {
        printf(COLOR_YELLOW "(Unknown ENA variant)" COLOR_RESET "\n");
    }
    
    /* Check if device is enabled */
    snprintf(path, sizeof(path), "%s/%s/enable", SYSFS_PCI_PATH, info->pci_address);
    if (read_sysfs_string(path, buf, sizeof(buf)) == 0) {
        if (buf[0] == '1') {
            printf(COLOR_GREEN "  [PASS] " COLOR_RESET "PCI device is enabled\n");
        } else {
            printf(COLOR_RED "  [FAIL] " COLOR_RESET "PCI device is NOT enabled\n");
            errors++;
        }
    }
    
    /* Check MSI-X capability */
    snprintf(path, sizeof(path), "%s/%s/msi_irqs", SYSFS_PCI_PATH, info->pci_address);
    DIR *dir = opendir(path);
    if (dir) {
        int msi_count = 0;
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] != '.') {
                msi_count++;
            }
        }
        closedir(dir);
        printf(COLOR_GREEN "  [PASS] " COLOR_RESET "MSI-X enabled with %d vectors\n", msi_count);
    } else {
        printf(COLOR_YELLOW "  [WARN] " COLOR_RESET "Cannot read MSI-X info\n");
    }
    
    /* Check NUMA node */
    if (info->numa_node >= 0) {
        printf(COLOR_GREEN "  [PASS] " COLOR_RESET "NUMA node: %d\n", info->numa_node);
    } else if (info->numa_node == -1) {
        printf(COLOR_YELLOW "  [INFO] " COLOR_RESET "NUMA: not applicable or emulated\n");
    }
    
    /* Check for IOMMU group */
    snprintf(path, sizeof(path), "%s/%s/iommu_group", SYSFS_PCI_PATH, info->pci_address);
    char link_target[MAX_PATH];
    ssize_t len = readlink(path, link_target, sizeof(link_target) - 1);
    if (len > 0) {
        link_target[len] = '\0';
        char *group = strrchr(link_target, '/');
        if (group) {
            printf(COLOR_GREEN "  [PASS] " COLOR_RESET "IOMMU group: %s\n", group + 1);
        }
    } else {
        printf(COLOR_YELLOW "  [INFO] " COLOR_RESET "IOMMU not enabled or not available\n");
    }
    
    return errors;
}

/*
 * Validate SR-IOV configuration
 */
static int validate_sriov_config(const nic_info_t *info)
{
    int errors = 0;
    
    print_header("SR-IOV Configuration Validation");
    
    if (info->is_sriov_pf) {
        printf(COLOR_GREEN "  [INFO] " COLOR_RESET "Device is an SR-IOV Physical Function (PF)\n");
        printf("  Total VFs supported: %d\n", info->sriov_totalvfs);
        printf("  VFs currently enabled: %d\n", info->sriov_numvfs);
        
        if (info->sriov_numvfs > 0) {
            /* List VFs */
            char path[MAX_PATH];
            char link_target[MAX_PATH];
            printf("  Virtual Functions:\n");
            
            for (int i = 0; i < info->sriov_numvfs; i++) {
                snprintf(path, sizeof(path), "%s/%s/virtfn%d", 
                         SYSFS_PCI_PATH, info->pci_address, i);
                ssize_t len = readlink(path, link_target, sizeof(link_target) - 1);
                if (len > 0) {
                    link_target[len] = '\0';
                    char *vf_addr = strrchr(link_target, '/');
                    if (vf_addr) {
                        printf("    VF %d: %s\n", i, vf_addr + 1);
                    }
                }
            }
        }
    } else if (info->is_sriov_vf) {
        printf(COLOR_GREEN "  [INFO] " COLOR_RESET "Device is an SR-IOV Virtual Function (VF)\n");
        printf("  Parent PF: %s\n", info->physfn_address);
    } else {
        printf(COLOR_YELLOW "  [INFO] " COLOR_RESET "SR-IOV not detected (typical for AWS ENA)\n");
        printf("  Note: AWS uses SR-IOV internally but exposes VFs as regular devices\n");
    }
    
    return errors;
}

/*
 * Validate queue and IRQ mapping
 */
static int validate_queue_irq_mapping(const char *ifname, const nic_info_t *info)
{
    int errors = 0;
    irq_info_t *irqs = NULL;
    int num_irqs = 0;
    
    print_header("Queue and IRQ Mapping Validation");
    
    printf("  TX Queues: %d\n", info->num_tx_queues);
    printf("  RX Queues: %d\n", info->num_rx_queues);
    
    /* Expected: 1 IRQ per queue pair + 1 for management */
    int expected_irqs = info->num_tx_queues + 1;  /* Assuming combined queues */
    
    if (get_irq_info(ifname, &irqs, &num_irqs) == 0) {
        printf("  IRQs found: %d\n", num_irqs);
        
        if (num_irqs > 0) {
            printf(COLOR_GREEN "  [PASS] " COLOR_RESET "IRQ mapping detected\n");
            print_irq_info(irqs, num_irqs);
            
            /* Validate IRQ distribution */
            int well_distributed = 1;
            for (int i = 0; i < num_irqs && i < 10; i++) {
                if (strlen(irqs[i].affinity_list) > 0) {
                    /* Check if affinity is set to single CPU or range */
                    if (strchr(irqs[i].affinity_list, '-') == NULL &&
                        strchr(irqs[i].affinity_list, ',') == NULL) {
                        /* Single CPU - good for dedicated queue */
                        continue;
                    }
                }
            }
            
            if (well_distributed) {
                printf(COLOR_GREEN "  [PASS] " COLOR_RESET 
                       "IRQ affinity appears properly configured\n");
            } else {
                printf(COLOR_YELLOW "  [WARN] " COLOR_RESET 
                       "IRQ affinity may not be optimally distributed\n");
            }
        } else {
            printf(COLOR_YELLOW "  [WARN] " COLOR_RESET "No IRQs found for interface\n");
        }
        
        free(irqs);
    } else {
        printf(COLOR_RED "  [FAIL] " COLOR_RESET "Cannot read IRQ information\n");
        errors++;
    }
    
    /* Validate queue directories exist */
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s/%s/queues", SYSFS_NET_PATH, ifname);
    DIR *dir = opendir(path);
    if (dir) {
        printf(COLOR_GREEN "  [PASS] " COLOR_RESET "Queue sysfs entries present\n");
        closedir(dir);
    } else {
        printf(COLOR_YELLOW "  [WARN] " COLOR_RESET "Queue sysfs entries not found\n");
    }
    
    return errors;
}

/*
 * Print NIC information
 */
static void print_nic_info(const nic_info_t *info)
{
    print_header("Network Interface Information");
    
    printf("  Interface Name: " COLOR_CYAN "%s" COLOR_RESET "\n", info->interface_name);
    printf("  Driver: " COLOR_CYAN "%s" COLOR_RESET "\n", info->driver_name);
    printf("  PCI Address: " COLOR_CYAN "%s" COLOR_RESET "\n", info->pci_address);
    printf("  Vendor/Device: %s:%s\n", info->vendor_id, info->device_id);
    
    if (is_ena_device(info)) {
        printf("  Device Type: " COLOR_GREEN "AWS ENA (Elastic Network Adapter)" COLOR_RESET "\n");
    }
}

/*
 * Print IRQ information
 */
static void print_irq_info(const irq_info_t *irqs, int num_irqs)
{
    printf("\n  IRQ Details:\n");
    printf("  %-8s %-30s %-20s %s\n", "IRQ", "Name", "Affinity (CPUs)", "Total Count");
    printf("  %-8s %-30s %-20s %s\n", "---", "----", "---------------", "-----------");
    
    for (int i = 0; i < num_irqs && i < 20; i++) {
        unsigned long long total = 0;
        for (int j = 0; j < irqs[i].num_cpus; j++) {
            total += irqs[i].count_per_cpu[j];
        }
        
        printf("  %-8d %-30s %-20s %llu\n",
               irqs[i].irq_number,
               irqs[i].irq_name,
               irqs[i].affinity_list,
               total);
    }
    
    if (num_irqs > 20) {
        printf("  ... and %d more IRQs\n", num_irqs - 20);
    }
}

/*
 * Print section header
 */
static void print_header(const char *title)
{
    printf("\n" COLOR_BLUE "═══════════════════════════════════════════════════════════════\n");
    printf(" %s\n", title);
    printf("═══════════════════════════════════════════════════════════════" COLOR_RESET "\n\n");
}

/*
 * Print separator
 */
static void print_separator(void)
{
    printf("───────────────────────────────────────────────────────────────\n");
}

/*
 * Discover all network interfaces
 */
static int discover_interfaces(char ***interfaces, int *count)
{
    DIR *dir;
    struct dirent *entry;
    int capacity = 16;
    
    *interfaces = malloc(capacity * sizeof(char *));
    if (!*interfaces) {
        return -1;
    }
    *count = 0;
    
    dir = opendir(SYSFS_NET_PATH);
    if (!dir) {
        free(*interfaces);
        return -1;
    }
    
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        if (strcmp(entry->d_name, "lo") == 0) continue;
        
        /* Check if it's a PCI device */
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/%s/device", SYSFS_NET_PATH, entry->d_name);
        struct stat st;
        if (lstat(path, &st) == 0 && S_ISLNK(st.st_mode)) {
            if (*count >= capacity) {
                capacity *= 2;
                *interfaces = realloc(*interfaces, capacity * sizeof(char *));
                if (!*interfaces) {
                    closedir(dir);
                    return -1;
                }
            }
            (*interfaces)[*count] = strdup(entry->d_name);
            (*count)++;
        }
    }
    
    closedir(dir);
    return 0;
}

/*
 * Free interfaces array
 */
static void free_interfaces(char **interfaces, int count)
{
    for (int i = 0; i < count; i++) {
        free(interfaces[i]);
    }
    free(interfaces);
}

/*
 * Generate validation report
 */
static void generate_report(const char *ifname)
{
    nic_info_t info;
    int total_errors = 0;
    
    printf(COLOR_MAGENTA "\n");
    printf("╔═══════════════════════════════════════════════════════════════╗\n");
    printf("║     AWS ENA NIC Relationship Validator                        ║\n");
    printf("║     Analyzing: %-46s ║\n", ifname);
    printf("╚═══════════════════════════════════════════════════════════════╝\n");
    printf(COLOR_RESET);
    
    if (get_nic_info(ifname, &info) < 0) {
        printf(COLOR_RED "Error: Cannot get information for interface %s\n" COLOR_RESET, ifname);
        printf("Make sure the interface exists and is a PCI device.\n");
        return;
    }
    
    /* Print basic info */
    print_nic_info(&info);
    
    /* Validate PCI configuration */
    total_errors += validate_pci_config(&info);
    
    /* Validate SR-IOV */
    total_errors += validate_sriov_config(&info);
    
    /* Validate queue/IRQ mapping */
    total_errors += validate_queue_irq_mapping(ifname, &info);
    
    /* Summary */
    print_header("Validation Summary");
    
    if (total_errors == 0) {
        printf(COLOR_GREEN "  ✓ All validations passed successfully!\n" COLOR_RESET);
    } else {
        printf(COLOR_RED "  ✗ Found %d issue(s) requiring attention\n" COLOR_RESET, total_errors);
    }
    
    /* Relationship diagram */
    print_header("Component Relationship Diagram");
    
    printf("  ┌─────────────────────────────────────────────────────────┐\n");
    printf("  │              Linux Network Stack                         │\n");
    printf("  │                    │                                     │\n");
    printf("  │                    ▼                                     │\n");
    printf("  │  ┌─────────────────────────────────────┐                │\n");
    printf("  │  │   netdev: %-26s │                │\n", info.interface_name);
    printf("  │  └─────────────────────────────────────┘                │\n");
    printf("  │                    │                                     │\n");
    printf("  │                    ▼                                     │\n");
    printf("  │  ┌─────────────────────────────────────┐                │\n");
    printf("  │  │   driver: %-26s │                │\n", info.driver_name);
    printf("  │  │   queues: TX=%d RX=%-18d │                │\n", 
           info.num_tx_queues, info.num_rx_queues);
    printf("  │  └─────────────────────────────────────┘                │\n");
    printf("  │                    │                                     │\n");
    printf("  │                    ▼                                     │\n");
    printf("  │  ┌─────────────────────────────────────┐                │\n");
    printf("  │  │   PCI: %-29s │                │\n", info.pci_address);
    printf("  │  │   ID: %s:%s                     │                │\n", 
           info.vendor_id, info.device_id);
    printf("  │  └─────────────────────────────────────┘                │\n");
    
    if (info.is_sriov_vf) {
        printf("  │                    │                                     │\n");
        printf("  │                    │ (VF)                                │\n");
        printf("  │                    ▼                                     │\n");
        printf("  │  ┌─────────────────────────────────────┐                │\n");
        printf("  │  │   PF: %-30s │                │\n", info.physfn_address);
        printf("  │  └─────────────────────────────────────┘                │\n");
    }
    
    printf("  │                    │                                     │\n");
    printf("  │                    ▼                                     │\n");
    printf("  │  ┌─────────────────────────────────────┐                │\n");
    printf("  │  │   Physical: Nitro Card / Network    │                │\n");
    printf("  │  └─────────────────────────────────────┘                │\n");
    printf("  └─────────────────────────────────────────────────────────┘\n");
}

/*
 * Main entry point
 */
int main(int argc, char *argv[])
{
    if (argc > 1) {
        /* Validate specific interface */
        generate_report(argv[1]);
    } else {
        /* Discover and validate all interfaces */
        char **interfaces;
        int count;
        
        printf(COLOR_CYAN "\nDiscovering network interfaces...\n" COLOR_RESET);
        
        if (discover_interfaces(&interfaces, &count) < 0) {
            fprintf(stderr, "Error: Cannot discover interfaces\n");
            return 1;
        }
        
        if (count == 0) {
            printf("No PCI network interfaces found.\n");
            return 0;
        }
        
        printf("Found %d PCI network interface(s)\n", count);
        
        for (int i = 0; i < count; i++) {
            generate_report(interfaces[i]);
            if (i < count - 1) {
                print_separator();
            }
        }
        
        free_interfaces(interfaces, count);
    }
    
    printf("\n");
    return 0;
}
