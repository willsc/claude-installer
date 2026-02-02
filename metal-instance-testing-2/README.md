# Trading Metal Instance Infrastructure

Terraform configuration for deploying a single AWS c8i metal instance with public SSH access, optimized for high-frequency trading workloads.

## Features

- Single instance deployment (c8i.metal-48xl or c8i.metal-96xl)
- **Public IP** with Elastic IP for stable SSH access
- **Partition placement group** for fault isolation
- Configurable region, instance type, and storage
- Network IRQ pinning (13 cores default)
- EDP cgroup isolation (16 cores default)
- EBS volumes: Binaries (50GB) + Logs (200GB)
- Core dumps disk excluded per requirements

## Quick Start

```bash
# 1. Copy and edit the example configuration
cp terraform.tfvars.example terraform.tfvars

# 2. Edit terraform.tfvars with your VPC, subnet, and SSH key

# 3. Deploy
terraform init
terraform plan
terraform apply

# 4. SSH to your instance
ssh -i your-key.pem ec2-user@<public-ip>
```

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| `vpc_id` | VPC ID |
| `subnet_id` | **Public** subnet ID (must have internet gateway) |
| `ssh_public_key` or `existing_key_pair_name` | SSH key for access |

### Instance Configuration

```hcl
aws_region    = "eu-west-1"           # Configurable region
instance_type = "c8i.metal-48xl"      # or "c8i.metal-96xl"
instance_name = "edp-01"              # Unique identifier
```

### Partition Placement Group

```hcl
partition_count  = 7    # Number of partitions (1-7)
partition_number = 1    # Which partition for this instance
```

### Storage Configuration

```hcl
# Root volume
root_volume_size       = 100
root_volume_iops       = 3000
root_volume_throughput = 125

# Binaries volume (default 50GB)
binaries_volume_size       = 50
binaries_volume_iops       = 3000
binaries_volume_throughput = 125

# Logs volume (default 200GB)
logs_volume_size       = 200
logs_volume_iops       = 3000
logs_volume_throughput = 250
```

### CPU Allocation

```hcl
network_irq_cores = 13   # Cores 0-12 for network IRQs
edp_cores         = 16   # Cores 13-28 for EDP processes
```

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  c8i.metal Instance                          │
├──────────────────────────────────────────────────────────────┤
│  Public IP: Elastic IP ──► SSH Access (port 22)             │
├──────────────────────────────────────────────────────────────┤
│  CPU Allocation:                                             │
│  ┌───────────┐  ┌──────────────┐  ┌────────────────┐        │
│  │ Cores 0-12│  │ Cores 13-28  │  │  Cores 29+     │        │
│  │ Net IRQ   │  │ EDP (cgroup) │  │  General       │        │
│  └───────────┘  └──────────────┘  └────────────────┘        │
├──────────────────────────────────────────────────────────────┤
│  EBS:  Root (100GB) │ Binaries (50GB) │ Logs (200GB)        │
├──────────────────────────────────────────────────────────────┤
│  Placement: Partition Group (partition N of 7)               │
└──────────────────────────────────────────────────────────────┘
```

## Outputs

After deployment:

```bash
terraform output public_ip           # SSH connection IP
terraform output ssh_connection_string
terraform output instance_summary
```

## Multiple Instances

To deploy multiple instances in the same placement group:

```bash
# Instance 1
terraform apply -var="instance_name=edp-01" -var="partition_number=1"

# Instance 2 (use separate state or workspace)
terraform workspace new instance-02
terraform apply -var="instance_name=edp-02" -var="partition_number=2"
```

## Files

```
├── main.tf                  # Instance, security group, EIP, placement group
├── variables.tf             # All configurable variables
├── outputs.tf               # Instance details and SSH info
├── terraform.tfvars.example # Example configuration
└── templates/
    └── user_data.sh.tpl     # Bootstrap script (IRQ, cgroup, mounts)
```

## Verification

After SSH access:

```bash
# Check setup summary
cat /var/log/trading-setup-summary.log

# Verify cgroup
cat /sys/fs/cgroup/edp.slice/cpuset.cpus

# Check IRQ affinity
cat /var/log/irq-affinity.log

# View mounted volumes
df -h | grep trading
```
