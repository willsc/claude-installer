# =============================================================================
# Trading Metal Instance - Example Configuration
# =============================================================================

# -----------------------------------------------------------------------------
# Region and Instance Identity
# -----------------------------------------------------------------------------

aws_region    = "eu-west-1"
environment   = "prod"
instance_name = "edp-01"

# -----------------------------------------------------------------------------
# Network (REQUIRED - replace with your values)
# -----------------------------------------------------------------------------

vpc_id    = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id = "subnet-xxxxxxxxxxxxxxxxx"  # Must be a PUBLIC subnet with IGW

# -----------------------------------------------------------------------------
# Instance Type
# -----------------------------------------------------------------------------

instance_type = "c8i.metal-48xl"  # or "c8i.metal-96xl"

# Optional: Use a custom pre-configured AMI
# custom_ami_id = "ami-xxxxxxxxxxxxxxxxx"

# -----------------------------------------------------------------------------
# Placement Group (Partition Strategy)
# -----------------------------------------------------------------------------

partition_count  = 7   # Number of partitions (1-7)
partition_number = 1   # Which partition to place this instance in

# -----------------------------------------------------------------------------
# CPU Configuration
# -----------------------------------------------------------------------------

network_irq_cores = 13   # Cores dedicated to network IRQ (0-12)
edp_cores         = 16   # Cores for EDP processes (13-28)

# -----------------------------------------------------------------------------
# Storage Configuration
# -----------------------------------------------------------------------------

# Root volume
root_volume_size       = 100
root_volume_iops       = 3000
root_volume_throughput = 125

# Binaries volume
binaries_volume_size       = 50
binaries_volume_iops       = 3000
binaries_volume_throughput = 125
binaries_mount_point       = "/opt/trading/bin"

# Logs volume
logs_volume_size       = 200
logs_volume_iops       = 3000
logs_volume_throughput = 250
logs_mount_point       = "/var/log/trading"

# Core dumps disk: EXCLUDED per requirements

# -----------------------------------------------------------------------------
# SSH Access
# -----------------------------------------------------------------------------

# Option 1: Provide your public key content
# ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ..."

# Option 2: Use an existing key pair in AWS
existing_key_pair_name = "my-existing-keypair"

# Restrict SSH access (recommended for production)
ssh_allowed_cidrs = ["0.0.0.0/0"]  # Replace with specific IPs

# -----------------------------------------------------------------------------
# Trading Application (optional)
# -----------------------------------------------------------------------------

trading_user  = "trading"
trading_group = "trading"

# Uncomment to open trading ports
# trading_port_start    = 10000
# trading_port_end      = 10100
# trading_allowed_cidrs = ["10.0.0.0/8"]

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------

enable_cloudwatch_alarms = true
# alarm_sns_topic_arn    = "arn:aws:sns:eu-west-1:123456789012:alerts"

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

additional_tags = {
  Team        = "trading-systems"
  Application = "edp"
  CostCenter  = "trading"
}
