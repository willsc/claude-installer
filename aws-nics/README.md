# AWS Metal Instance NIC Architecture: ENA Driver, PCI Layer, SR-IOV, and Physical NICs

## Executive Summary

This document provides an in-depth technical analysis of how AWS metal instance network interface cards (NICs) operate, covering the relationship between Linux netdev naming conventions, the Elastic Network Adapter (ENA) driver, TX/RX queues, interrupt handling, PCI layer integration, SR-IOV virtualization, and physical NIC mappings. It also examines how driver-level tuning affects physical hardware behavior.

---

## 1. AWS Nitro System Architecture Overview

### 1.1 The Nitro System Foundation

AWS's Nitro System represents a fundamental reimagining of cloud virtualization infrastructure. Unlike traditional hypervisor-based approaches where virtualization functions consume significant host resources, the Nitro System offloads networking, storage, and security functions to dedicated hardware components called Nitro Cards.

The key components include:

- **Nitro Cards**: Custom ASICs developed by Annapurna Labs (acquired by AWS in 2015) that handle I/O virtualization
- **Nitro Controller**: The exclusive gateway between physical servers and AWS control planes
- **Nitro Security Chip**: Provides hardware root of trust and secure boot
- **Nitro Hypervisor**: A minimal, firmware-like hypervisor for resource isolation

### 1.2 Bare Metal vs Virtualized Instances

For **virtualized EC2 instances**, the Nitro system uses SR-IOV (Single Root I/O Virtualization) to present Virtual Functions (VFs) to guest operating systems. Each VF appears as a dedicated PCIe device with its own configuration space and memory-mapped I/O regions.

For **bare metal instances** (e.g., `m5.metal`, `c5n.metal`), the guest operating system accesses the Physical Function (PF) directly. The Nitro Cards still handle network and storage I/O, but without hypervisor involvement-the OS has direct access to PCIe physical functions.

---

## 2. Linux Network Device Naming and ENA Driver Binding

### 2.1 Network Interface Naming Conventions

Linux systems use several naming schemes for network interfaces:

| Naming Scheme | Example | Description |
|---------------|---------|-------------|
| Predictable (systemd) | `ens5`, `enp0s3` | Based on firmware/topology |
| Traditional | `eth0`, `eth1` | Legacy sequential naming |
| MAC-based | `enx001122334455` | Based on MAC address |
| Custom (udev) | `lan0`, `mgmt0` | Administrator-defined rules |

On AWS instances, ENA devices typically appear as `ens5`, `ens6`, etc., following systemd's predictable naming scheme based on PCIe topology.

### 2.2 ENA Driver Architecture

The ENA (Elastic Network Adapter) driver is the Linux kernel driver for AWS's custom network interface. It's designed to be:

- **Link-speed independent**: Same driver works for 10GbE, 25GbE, 40GbE, 100GbE
- **Feature-negotiating**: Capabilities are discovered at runtime
- **Multi-queue capable**: Supports dedicated TX/RX queue pairs per CPU core

The driver consists of several key components:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Linux Kernel Network Stack                   │
├─────────────────────────────────────────────────────────────────┤
│                        ENA Net Device Layer                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ ena_netdev.c│  │ena_ethtool.c│  │   ena_com (common lib)  │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│                      Admin Queue (AQ/ACQ)                        │
│              Asynchronous Event Notification Queue (AENQ)        │
├─────────────────────────────────────────────────────────────────┤
│                     PCIe/MSI-X Interface                         │
├─────────────────────────────────────────────────────────────────┤
│                   ENA Device (Nitro Card)                        │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 Driver-to-Device Binding Process

When the ENA driver loads, the binding process follows these steps:

1. **PCI Enumeration**: The kernel's PCI subsystem discovers ENA devices via vendor/device IDs
2. **Driver Matching**: `pci_register_driver()` matches the ENA driver to compatible devices
3. **Probe Function**: `ena_probe()` initializes the adapter identified by `struct pci_dev`
4. **Resource Allocation**: BAR regions are mapped, DMA is configured
5. **Queue Setup**: Admin queues and I/O queues are initialized
6. **Network Registration**: `register_netdev()` creates the network interface

```c
/* ENA PCI Device IDs */
#define PCI_VENDOR_ID_AMAZON    0x1d0f
#define PCI_DEVICE_ID_ENA_PF    0xec20
#define PCI_DEVICE_ID_ENA_LLQ   0xec21
#define PCI_DEVICE_ID_ENA_VF    0xec20
```

---

## 3. TX/RX Queue Architecture

### 3.1 Queue Structure

ENA implements a multi-queue architecture where each CPU core can have its own dedicated queue pair:

```
┌────────────────────────────────────────────────────────────────┐
│                        Per-Queue Structure                      │
├────────────────────────────────────────────────────────────────┤
│  TX Direction:                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│  │ TX Submission │────▶│  TX Completion│────▶│   MSI-X IRQ   │   │
│  │    Queue (SQ)│     │    Queue (CQ) │     │   Handler     │   │
│  └──────────────┘     └──────────────┘     └──────────────┘   │
│                                                                 │
│  RX Direction:                                                  │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│  │ RX Submission │◀────│  RX Completion│◀────│   MSI-X IRQ   │   │
│  │    Queue (SQ)│     │    Queue (CQ) │     │   Handler     │   │
│  └──────────────┘     └──────────────┘     └──────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

### 3.2 Queue Operation Modes

ENA supports two queue operation modes for TX Submission Queues:

**Regular Queue Mode (Host Memory)**
- TX descriptors and packet data reside in host memory
- ENA device fetches descriptors and data via DMA
- Lower hardware requirements

**Low Latency Queue (LLQ) Mode / Push Mode**
- Driver pushes TX descriptors and first 128 bytes of packet directly to device memory
- Uses write-combine capable PCI BAR mapping
- Reduces latency by several microseconds
- Critical for Nitro v4+ instances (disabling causes severe performance degradation)

### 3.3 Queue Configuration

The number and size of queues can be queried and modified via ethtool:

```bash
# Query current queue configuration
ethtool -l ens5

# Set number of combined TX/RX queues
ethtool -L ens5 combined 8

# Query ring buffer sizes
ethtool -g ens5

# Set ring buffer sizes
ethtool -G ens5 rx 1024 tx 1024
```

ENA devices support up to 32 queues per ENI (Elastic Network Interface), with the actual number depending on instance type and vCPU count.

---

## 4. Interrupt Architecture and MSI-X Mapping

### 4.1 MSI-X Vector Allocation

ENA uses MSI-X (Message Signaled Interrupts - Extended) for interrupt delivery. The interrupt allocation follows this pattern:

```
┌────────────────────────────────────────────────────────────────┐
│                    MSI-X Vector Allocation                      │
├────────────────────────────────────────────────────────────────┤
│  Vector 0:      Management (Admin CQ + AENQ)                   │
│  Vector 1:      I/O Queue Pair 0 (TX0 + RX0)                   │
│  Vector 2:      I/O Queue Pair 1 (TX1 + RX1)                   │
│  ...                                                            │
│  Vector N:      I/O Queue Pair N-1                              │
│                                                                 │
│  Total Vectors = 1 (mgmt) + num_io_queues                      │
└────────────────────────────────────────────────────────────────┘
```

### 4.2 Interrupt Handler Flow

```c
/* MSI-X I/O Interrupt Handler */
static irqreturn_t ena_intr_msix_io(int irq, void *data)
{
    struct ena_napi *ena_napi = data;
    
    /* Schedule NAPI for bottom-half processing */
    napi_schedule_irqoff(&ena_napi->napi);
    
    return IRQ_HANDLED;
}
```

The interrupt handler performs minimal work, immediately scheduling NAPI (New API) for packet processing. This follows the Linux networking model where:

1. **Hard IRQ**: Brief handler schedules softirq
2. **Soft IRQ / NAPI**: Polls for packets in batches
3. **Auto-mask**: Device masks interrupt until driver unmasks after NAPI completion

### 4.3 Interrupt Moderation

ENA supports both static and adaptive interrupt moderation:

**Static Moderation**
```bash
# Set TX/RX coalescing delays
ethtool -C ens5 tx-usecs 64 rx-usecs 64
```

**Adaptive Moderation (DIM - Dynamic Interrupt Moderation)**
```bash
# Enable adaptive RX moderation
ethtool -C ens5 adaptive-rx on

# Query current settings
ethtool -c ens5
```

The default TX interrupt delay is 64 microseconds. RX moderation settings vary by instance type.

### 4.4 IRQ Affinity and CPU Mapping

Each MSI-X vector can be assigned to specific CPUs:

```bash
# View interrupt assignments
cat /proc/interrupts | grep ena

# View IRQ affinity for specific interrupt
cat /proc/irq/123/smp_affinity

# Set IRQ affinity (hex bitmask)
echo 1 > /proc/irq/123/smp_affinity      # CPU 0 only
echo f > /proc/irq/123/smp_affinity      # CPUs 0-3
```

The relationship between queues, interrupts, and CPUs:

```
┌─────────────────────────────────────────────────────────────────┐
│  Queue 0 ──▶ MSI-X Vec 1 ──▶ IRQ 123 ──▶ CPU 0 (via affinity)  │
│  Queue 1 ──▶ MSI-X Vec 2 ──▶ IRQ 124 ──▶ CPU 1 (via affinity)  │
│  Queue 2 ──▶ MSI-X Vec 3 ──▶ IRQ 125 ──▶ CPU 2 (via affinity)  │
│  Queue 3 ──▶ MSI-X Vec 4 ──▶ IRQ 126 ──▶ CPU 3 (via affinity)  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. PCI Layer Integration

### 5.1 PCIe Device Structure

ENA devices expose themselves as PCIe endpoints with the following characteristics:

```
┌────────────────────────────────────────────────────────────────┐
│                    PCIe Configuration Space                     │
├────────────────────────────────────────────────────────────────┤
│  Vendor ID:     0x1d0f (Amazon)                                │
│  Device ID:     0xec20 (ENA PF) or 0xec21 (ENA LLQ)           │
│  Class Code:    Network Controller                              │
│  Capabilities:  MSI-X, PCIe, SR-IOV (if supported)             │
├────────────────────────────────────────────────────────────────┤
│                         BAR Regions                             │
├────────────────────────────────────────────────────────────────┤
│  BAR 0:  MMIO Registers (control/status, accessed at init)     │
│  BAR 2:  Memory Space (LLQ push region, write-combine)         │
│  BAR 4:  MSI-X Table                                            │
└────────────────────────────────────────────────────────────────┘
```

### 5.2 Sysfs Interface

The Linux PCI subsystem exposes device information via sysfs:

```
/sys/bus/pci/devices/0000:00:05.0/
├── class                 # PCI class code
├── vendor               # Vendor ID (0x1d0f)
├── device               # Device ID (0xec20)
├── driver/              # Symlink to driver
├── net/                 # Network interfaces
│   └── ens5/
│       ├── address      # MAC address
│       ├── queues/      # Per-queue info
│       └── statistics/  # Interface stats
├── msi_irqs/            # MSI-X IRQ numbers
├── numa_node            # NUMA node affinity
├── resource             # BAR resources
└── sriov_numvfs         # SR-IOV VF count (if PF)
```

### 5.3 IOMMU and DMA

Metal instances support IOMMU for both x86_64 and ARM64:

```bash
# Check IOMMU groups
ls /sys/kernel/iommu_groups/*/devices/

# View DMA mappings
cat /sys/kernel/debug/iommu/intel/dmar*/domain_translation_struct
```

---

## 6. SR-IOV Architecture

### 6.1 SR-IOV Fundamentals

Single Root I/O Virtualization (SR-IOV) enables a single PCIe device to appear as multiple virtual devices:

```
┌─────────────────────────────────────────────────────────────────┐
│                   Physical Network Adapter                       │
│                    (Nitro Card / ENA Device)                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Physical Function (PF)                       │   │
│  │  - Full PCIe device with SR-IOV capability               │   │
│  │  - Manages VF creation/destruction                        │   │
│  │  - Has complete configuration space                       │   │
│  │  - Used by hypervisor or bare metal OS                   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│         ┌────────────────────┼────────────────────┐             │
│         ▼                    ▼                    ▼             │
│  ┌────────────┐      ┌────────────┐      ┌────────────┐        │
│  │   VF 0     │      │   VF 1     │      │   VF N     │        │
│  │            │      │            │      │            │        │
│  │ Lightweight│      │ Lightweight│      │ Lightweight│        │
│  │ PCIe func  │      │ PCIe func  │      │ PCIe func  │        │
│  └────────────┘      └────────────┘      └────────────┘        │
│        │                   │                   │                 │
│        ▼                   ▼                   ▼                 │
│    ┌───────┐          ┌───────┐          ┌───────┐             │
│    │ VM 1  │          │ VM 2  │          │ VM N  │             │
│    └───────┘          └───────┘          └───────┘             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 AWS Implementation

In AWS's Nitro architecture:

**Virtualized Instances**
- Guest OS receives SR-IOV Virtual Functions
- VFs appear as standard PCIe devices in the guest
- Each VF has its own PCI BDF (Bus:Device.Function)
- VF driver (ENA) operates identically to PF driver

**Bare Metal Instances**
- OS receives direct access to Physical Functions
- No hypervisor intervention for data path
- Full access to all hardware capabilities
- Nitro Cards still handle external network connectivity

### 6.3 VF Configuration (Reference)

While AWS manages VF allocation automatically, understanding the sysfs interface is valuable:

```bash
# View SR-IOV capability (on systems where accessible)
lspci -vvv -s 00:05.0 | grep -A 20 "SR-IOV"

# View number of VFs (from hypervisor perspective)
cat /sys/bus/pci/devices/0000:00:05.0/sriov_numvfs

# VF to PF relationship
ls -la /sys/bus/pci/devices/0000:00:05.1/physfn  # Links to PF
ls /sys/bus/pci/devices/0000:00:05.0/virtfn*     # Lists VFs
```

---

## 7. Physical NIC Mapping and Nitro Card Architecture

### 7.1 Nitro Card Network Path

The physical network path in AWS involves:

```
┌─────────────────────────────────────────────────────────────────┐
│                     EC2 Instance (Guest OS)                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │           ENA Driver (PF or VF depending on type)         │  │
│  └─────────────────────────────┬─────────────────────────────┘  │
│                                │ PCIe                            │
├────────────────────────────────┼────────────────────────────────┤
│                                ▼                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Nitro Network Card                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │  │
│  │  │ ENA Device  │  │ Packet      │  │   Encryption    │   │  │
│  │  │ Logic       │  │ Processing  │  │   (AES-256-GCM) │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │  │
│  │                           │                                │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │           Network Interface (Physical)              │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                │                                 │
├────────────────────────────────┼────────────────────────────────┤
│                                ▼                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              AWS Data Center Network Fabric               │  │
│  │         (VPC, Security Groups, Routing, etc.)             │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 ENI to Physical NIC Relationship

Elastic Network Interfaces (ENIs) are logical constructs that map to physical resources:

- Each ENI is backed by a Nitro Card virtual port
- ENIs can be attached/detached from instances dynamically
- Multiple ENIs can share the same physical Nitro Card
- Network limits (bandwidth, PPS) are enforced per-instance, not per-ENI

### 7.3 Hardware Offloads

Nitro Cards implement several hardware offloads:

| Offload | Description |
|---------|-------------|
| Checksum | IPv4/TCP/UDP checksum calculation |
| TSO | TCP Segmentation Offload |
| RSS | Receive Side Scaling (flow distribution) |
| LRO/GRO | Large/Generic Receive Offload |
| Encryption | In-transit encryption (AES-256-GCM) |

---

## 8. Driver Tuning and Physical Hardware Effects

### 8.1 What Driver Tuning Can and Cannot Affect

Understanding the boundary between software and hardware is crucial:

**Driver tuning CAN affect:**
- How packets are batched and processed on the host
- CPU utilization and interrupt distribution
- Host memory usage for buffers
- Latency characteristics on the host side
- How efficiently the host communicates with the Nitro Card

**Driver tuning CANNOT directly affect:**
- Nitro Card firmware behavior
- Physical network bandwidth limits
- AWS-imposed PPS/bandwidth allowances
- External network latency
- Other instances' behavior

### 8.2 Effective Tuning Parameters

#### Queue Configuration
```bash
# Optimal: Match queue count to vCPUs handling network traffic
ethtool -L ens5 combined $(nproc)

# Ring buffer sizing (larger = more memory, better burst handling)
ethtool -G ens5 rx 4096 tx 4096
```

#### Interrupt Moderation
```bash
# For latency-sensitive workloads
ethtool -C ens5 adaptive-rx off rx-usecs 0 tx-usecs 0

# For throughput-oriented workloads
ethtool -C ens5 adaptive-rx on
```

#### IRQ Affinity Best Practices
```bash
# Disable irqbalance for manual control
systemctl stop irqbalance

# Pin each queue IRQ to specific CPUs (match NUMA topology)
for irq in $(grep ena /proc/interrupts | cut -d: -f1); do
    echo $cpu_mask > /proc/irq/$irq/smp_affinity
done
```

#### Kernel Network Stack Tuning
```bash
# Increase socket buffer sizes
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# Increase backlog queue
sysctl -w net.core.netdev_max_backlog=10000

# Enable BPF JIT for XDP programs
sysctl -w net.core.bpf_jit_enable=1
```

### 8.3 Monitoring and Validation

Use ethtool statistics to monitor driver behavior:

```bash
# View comprehensive statistics
ethtool -S ens5

# Key metrics to monitor:
# - queue_X_tx_cnt/rx_cnt: Packets per queue
# - queue_X_tx_bytes/rx_bytes: Bytes per queue
# - bw_in_allowance_exceeded: Bandwidth limit hits
# - pps_allowance_exceeded: PPS limit hits
# - queue_X_tx_queue_stop: Queue backpressure events
```

---

## 9. Conclusion

The AWS ENA architecture represents a sophisticated integration between custom hardware (Nitro Cards), Linux kernel drivers, and virtualization technologies (SR-IOV). Key takeaways:

1. **Naming**: Linux netdev names (ens5, eth0, etc.) are assigned by udev/systemd based on PCIe topology and driver binding
2. **Queues**: Each TX/RX queue pair maps to a dedicated MSI-X interrupt vector, enabling per-CPU packet processing
3. **Interrupts**: MSI-X provides efficient, targeted interrupt delivery with configurable CPU affinity
4. **PCI Layer**: ENA devices appear as standard PCIe endpoints with BAR regions for MMIO, LLQ, and MSI-X
5. **SR-IOV**: Virtualized instances use VFs while bare metal uses PFs; both use the same ENA driver
6. **Physical NICs**: The Nitro Card handles the physical network interface; driver tuning affects host-side processing but not hardware limits

Driver tuning optimizes how the host system interacts with the Nitro Card but cannot bypass AWS-imposed network limits or modify hardware behavior. Effective optimization requires understanding both software and hardware boundaries.

---

## Appendix A: Quick Reference Commands

```bash
# View ENA device information
lspci -vvv | grep -A 50 "Elastic Network Adapter"

# Check driver binding
ethtool -i ens5

# View queue configuration
ethtool -l ens5

# View interrupt mapping
cat /proc/interrupts | grep ena

# View IRQ affinity
for irq in $(grep ena /proc/interrupts | cut -d: -f1); do
    echo "IRQ $irq: $(cat /proc/irq/$irq/smp_affinity_list)"
done

# View per-queue statistics
ethtool -S ens5 | grep queue_

# Check NUMA node
cat /sys/class/net/ens5/device/numa_node

# View PCIe topology
lspci -tv
```

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| ENA | Elastic Network Adapter - AWS custom network interface |
| ENI | Elastic Network Interface - AWS virtual network interface |
| MSI-X | Message Signaled Interrupts Extended |
| NAPI | New API - Linux kernel packet processing interface |
| PF | Physical Function - Full PCIe device in SR-IOV |
| VF | Virtual Function - Lightweight PCIe function in SR-IOV |
| LLQ | Low Latency Queue - Direct-to-device descriptor mode |
| RSS | Receive Side Scaling - Hardware packet distribution |
| NUMA | Non-Uniform Memory Access - Memory architecture |
| BAR | Base Address Register - PCIe memory mapping |
| DMA | Direct Memory Access - Hardware memory transfer |
| IOMMU | I/O Memory Management Unit |

---

*Document Version: 1.0*  
*Last Updated: January 2026*
