#!/bin/bash
# =============================================================================
# Trading Metal Instance Bootstrap Script
# Configures: Network IRQ affinity, cgroups for EDP, EBS volumes
# =============================================================================

set -euo pipefail

exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting trading metal instance configuration..."
echo "Instance Type: ${instance_type}"
echo "Environment: ${environment}"

# -----------------------------------------------------------------------------
# System Updates and Dependencies
# -----------------------------------------------------------------------------

dnf update -y
dnf install -y \
    nvme-cli \
    irqbalance \
    tuned \
    sysstat \
    htop \
    numactl \
    util-linux \
    xfsprogs

# -----------------------------------------------------------------------------
# Disable irqbalance (we'll manage IRQ affinity manually)
# -----------------------------------------------------------------------------

systemctl stop irqbalance || true
systemctl disable irqbalance || true

# -----------------------------------------------------------------------------
# Configure Kernel Parameters for Low Latency Trading
# -----------------------------------------------------------------------------

cat > /etc/sysctl.d/99-trading.conf <<EOF
# Network tuning for low latency
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.netdev_max_backlog = 300000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 0
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# Memory management
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# Disable NUMA balancing
kernel.numa_balancing = 0

# Increase max open files
fs.file-max = 2097152
fs.nr_open = 2097152

# Core pattern for debugging
kernel.core_pattern = /tmp/core.%e.%p.%t
EOF

sysctl -p /etc/sysctl.d/99-trading.conf

# -----------------------------------------------------------------------------
# Disable Transparent Huge Pages
# -----------------------------------------------------------------------------

echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

cat > /etc/systemd/system/disable-thp.service <<EOF
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF

systemctl daemon-reload
systemctl enable disable-thp.service

# -----------------------------------------------------------------------------
# Create Trading User and Group
# -----------------------------------------------------------------------------

groupadd -f ${trading_group}
id -u ${trading_user} &>/dev/null || useradd -g ${trading_group} -m -s /bin/bash ${trading_user}

# -----------------------------------------------------------------------------
# Configure Network IRQ Affinity (configurable cores)
# -----------------------------------------------------------------------------

NETWORK_IRQ_CORES=${network_irq_cores}

cat > /usr/local/bin/configure-irq-affinity.sh <<'IRQSCRIPT'
#!/bin/bash
# Configure network IRQ affinity to specific cores

set -euo pipefail

NETWORK_IRQ_CORES=$${1:-13}
LOG_FILE="/var/log/irq-affinity.log"

echo "$(date): Starting IRQ affinity configuration for $NETWORK_IRQ_CORES cores" >> "$LOG_FILE"

# Generate CPU mask for network IRQs (first N cores)
generate_cpu_mask() {
    local num_cores=$1
    local mask=0
    for ((i=0; i<num_cores; i++)); do
        mask=$((mask | (1 << i)))
    done
    printf "%x" $mask
}

NETWORK_MASK=$(generate_cpu_mask $NETWORK_IRQ_CORES)
echo "Network IRQ CPU mask: 0x$NETWORK_MASK (cores 0-$((NETWORK_IRQ_CORES-1)))" >> "$LOG_FILE"

# Find ENA network interfaces
for iface in /sys/class/net/eth* /sys/class/net/ens*; do
    [ -e "$iface" ] || continue
    IFACE_NAME=$(basename "$iface")

    echo "Configuring IRQ affinity for interface: $IFACE_NAME" >> "$LOG_FILE"

    # Find all IRQs for this interface
    for irq_dir in /sys/class/net/$IFACE_NAME/device/msi_irqs/*; do
        [ -e "$irq_dir" ] || continue
        IRQ=$(basename "$irq_dir")

        if [ -f "/proc/irq/$IRQ/smp_affinity" ]; then
            echo "$NETWORK_MASK" > "/proc/irq/$IRQ/smp_affinity" 2>/dev/null || true
            echo "  Set IRQ $IRQ affinity to 0x$NETWORK_MASK" >> "$LOG_FILE"
        fi
    done

    # Check for IRQs in /proc/interrupts
    for IRQ in $(grep -E "$IFACE_NAME|ena" /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':'); do
        if [ -f "/proc/irq/$IRQ/smp_affinity" ]; then
            echo "$NETWORK_MASK" > "/proc/irq/$IRQ/smp_affinity" 2>/dev/null || true
            echo "  Set IRQ $IRQ (from /proc/interrupts) affinity to 0x$NETWORK_MASK" >> "$LOG_FILE"
        fi
    done
done

# Disable RPS
for rps in /sys/class/net/*/queues/rx-*/rps_cpus; do
    [ -e "$rps" ] || continue
    echo 0 > "$rps" 2>/dev/null || true
done

echo "$(date): IRQ affinity configuration complete" >> "$LOG_FILE"
IRQSCRIPT

chmod +x /usr/local/bin/configure-irq-affinity.sh

cat > /etc/systemd/system/irq-affinity.service <<EOF
[Unit]
Description=Configure Network IRQ Affinity for Trading
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/configure-irq-affinity.sh ${network_irq_cores}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable irq-affinity.service
/usr/local/bin/configure-irq-affinity.sh ${network_irq_cores}

# -----------------------------------------------------------------------------
# Configure cgroups v2 for EDP Processes
# -----------------------------------------------------------------------------

EDP_CORES=${edp_cores}

if ! mountpoint -q /sys/fs/cgroup; then
    mount -t cgroup2 none /sys/fs/cgroup
fi

mkdir -p /sys/fs/cgroup/edp.slice

# EDP uses cores after network IRQ cores
EDP_START_CORE=${network_irq_cores}
EDP_END_CORE=$((EDP_START_CORE + EDP_CORES - 1))

echo "$EDP_START_CORE-$EDP_END_CORE" > /sys/fs/cgroup/edp.slice/cpuset.cpus
echo "0" > /sys/fs/cgroup/edp.slice/cpuset.mems

cat > /etc/systemd/system/edp.slice <<EOF
[Unit]
Description=EDP Trading Processes Slice
Before=slices.target

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
AllowedCPUs=$EDP_START_CORE-$EDP_END_CORE
EOF

cat > /etc/systemd/system/edp@.service <<EOF
[Unit]
Description=EDP Trading Process %i
After=network.target irq-affinity.service

[Service]
Type=simple
User=${trading_user}
Group=${trading_group}
Slice=edp.slice
CPUAffinity=$EDP_START_CORE-$EDP_END_CORE
Nice=-20
LimitNOFILE=1048576
LimitMEMLOCK=infinity
ExecStart=${binaries_mount}/%i

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

cat > /usr/local/bin/run-in-edp-cgroup.sh <<'CGROUPSCRIPT'
#!/bin/bash
if [ $# -lt 1 ]; then
    echo "Usage: $0 <command> [args...]"
    exit 1
fi
echo $$ > /sys/fs/cgroup/edp.slice/cgroup.procs 2>/dev/null || true
exec "$@"
CGROUPSCRIPT

chmod +x /usr/local/bin/run-in-edp-cgroup.sh

echo "EDP cgroup configured: cores $EDP_START_CORE-$EDP_END_CORE (${edp_cores} cores)"

# -----------------------------------------------------------------------------
# Mount EBS Volumes
# -----------------------------------------------------------------------------

sleep 10

# Function to find NVMe device
find_nvme_device() {
    local block_device=$1
    for nvme in /dev/nvme*n1; do
        [ -e "$nvme" ] || continue
        local vol_name=$(nvme id-ctrl "$nvme" 2>/dev/null | grep -o '/dev/[a-z]*' | head -1 || echo "")
        if [ "$vol_name" == "$block_device" ]; then
            echo "$nvme"
            return 0
        fi
    done
    [ -b "$block_device" ] && echo "$block_device" && return 0
    return 1
}

# Mount binaries volume
BINARIES_DEVICE="${binaries_device}"
BINARIES_MOUNT="${binaries_mount}"

echo "Waiting for binaries volume..."
for i in {1..30}; do
    BINARIES_NVME=$(find_nvme_device "$BINARIES_DEVICE" || echo "")
    if [ -n "$BINARIES_NVME" ] && [ -b "$BINARIES_NVME" ]; then
        break
    fi
    for dev in /dev/nvme1n1 /dev/nvme2n1; do
        if [ -b "$dev" ]; then
            BINARIES_NVME="$dev"
            break 2
        fi
    done
    sleep 2
done

if [ -n "$BINARIES_NVME" ] && [ -b "$BINARIES_NVME" ]; then
    echo "Found binaries device: $BINARIES_NVME"
    blkid "$BINARIES_NVME" | grep -q xfs || mkfs.xfs -f "$BINARIES_NVME"
    mkdir -p "$BINARIES_MOUNT"
    BINARIES_UUID=$(blkid -s UUID -o value "$BINARIES_NVME")
    grep -q "$BINARIES_UUID" /etc/fstab || echo "UUID=$BINARIES_UUID $BINARIES_MOUNT xfs defaults,noatime,nodiratime 0 2" >> /etc/fstab
    mount "$BINARIES_MOUNT" || mount -a
    chown ${trading_user}:${trading_group} "$BINARIES_MOUNT"
    chmod 755 "$BINARIES_MOUNT"
fi

# Mount logs volume
LOGS_DEVICE="${logs_device}"
LOGS_MOUNT="${logs_mount}"

echo "Waiting for logs volume..."
for i in {1..30}; do
    LOGS_NVME=$(find_nvme_device "$LOGS_DEVICE" || echo "")
    if [ -n "$LOGS_NVME" ] && [ -b "$LOGS_NVME" ]; then
        break
    fi
    for dev in /dev/nvme2n1 /dev/nvme3n1; do
        if [ -b "$dev" ] && [ "$dev" != "$BINARIES_NVME" ]; then
            LOGS_NVME="$dev"
            break 2
        fi
    done
    sleep 2
done

if [ -n "$LOGS_NVME" ] && [ -b "$LOGS_NVME" ]; then
    echo "Found logs device: $LOGS_NVME"
    blkid "$LOGS_NVME" | grep -q xfs || mkfs.xfs -f "$LOGS_NVME"
    mkdir -p "$LOGS_MOUNT"
    LOGS_UUID=$(blkid -s UUID -o value "$LOGS_NVME")
    grep -q "$LOGS_UUID" /etc/fstab || echo "UUID=$LOGS_UUID $LOGS_MOUNT xfs defaults,noatime,nodiratime 0 2" >> /etc/fstab
    mount "$LOGS_MOUNT" || mount -a
    chown ${trading_user}:${trading_group} "$LOGS_MOUNT"
    chmod 755 "$LOGS_MOUNT"
fi

# NOTE: Core dumps disk excluded per requirements

# -----------------------------------------------------------------------------
# Configure CPU Performance Governor
# -----------------------------------------------------------------------------

for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$cpu" ] && echo "performance" > "$cpu" 2>/dev/null || true
done

for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
    if [ -e "$cpu" ]; then
        max_freq=$(cat "$(dirname "$cpu")/scaling_max_freq")
        echo "$max_freq" > "$cpu" 2>/dev/null || true
    fi
done

tuned-adm profile latency-performance || tuned-adm profile throughput-performance || true

# -----------------------------------------------------------------------------
# Set Resource Limits
# -----------------------------------------------------------------------------

cat > /etc/security/limits.d/99-trading.conf <<EOF
${trading_user}    soft    nofile     1048576
${trading_user}    hard    nofile     1048576
${trading_user}    soft    nproc      unlimited
${trading_user}    hard    nproc      unlimited
${trading_user}    soft    memlock    unlimited
${trading_user}    hard    memlock    unlimited
${trading_user}    soft    stack      unlimited
${trading_user}    hard    stack      unlimited
${trading_user}    soft    nice       -20
${trading_user}    hard    nice       -20
${trading_user}    soft    rtprio     99
${trading_user}    hard    rtprio     99
EOF

# -----------------------------------------------------------------------------
# Create Directory Structure
# -----------------------------------------------------------------------------

mkdir -p ${binaries_mount}/{bin,lib,config}
mkdir -p ${logs_mount}/{app,system,audit}
chown -R ${trading_user}:${trading_group} ${binaries_mount}
chown -R ${trading_user}:${trading_group} ${logs_mount}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

cat > /var/log/trading-setup-summary.log <<EOF
=============================================================================
Trading Metal Instance Configuration Summary
=============================================================================
Timestamp: $(date -Iseconds)
Instance Type: ${instance_type}
Environment: ${environment}

Network IRQ: Cores 0-$((${network_irq_cores}-1)) (${network_irq_cores} cores)
EDP Cgroup:  Cores ${network_irq_cores}-$((${network_irq_cores}+${edp_cores}-1)) (${edp_cores} cores)

Binaries: ${binaries_mount}
Logs:     ${logs_mount}
Core dumps: EXCLUDED

User: ${trading_user} / Group: ${trading_group}
=============================================================================
EOF

cat /var/log/trading-setup-summary.log
echo "Trading metal instance configuration complete!"
