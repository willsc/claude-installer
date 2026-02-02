# =============================================================================
# Variables for Trading Metal Instance Infrastructure
# =============================================================================

# -----------------------------------------------------------------------------
# Region and Environment
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "instance_name" {
  description = "Unique name identifier for this instance"
  type        = string
  default     = "trading-01"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where instance will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for instance deployment (must have internet gateway)"
  type        = string
}

# -----------------------------------------------------------------------------
# Instance Configuration
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type (c8i.metal-48xl or c8i.metal-96xl)"
  type        = string
  default     = "c8i.metal-48xl"

  validation {
    condition     = contains(["c8i.metal-48xl", "c8i.metal-96xl"], var.instance_type)
    error_message = "Instance type must be c8i.metal-48xl or c8i.metal-96xl."
  }
}

variable "custom_ami_id" {
  description = "Custom AMI ID (leave empty to use latest Amazon Linux 2023)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Placement Group Configuration
# -----------------------------------------------------------------------------

variable "partition_count" {
  description = "Number of partitions in the placement group (1-7)"
  type        = number
  default     = 7

  validation {
    condition     = var.partition_count >= 1 && var.partition_count <= 7
    error_message = "Partition count must be between 1 and 7."
  }
}

variable "partition_number" {
  description = "Partition number to place this instance in (1 to partition_count)"
  type        = number
  default     = 1

  validation {
    condition     = var.partition_number >= 1
    error_message = "Partition number must be at least 1."
  }
}

# -----------------------------------------------------------------------------
# CPU Configuration
# -----------------------------------------------------------------------------

variable "network_irq_cores" {
  description = "Number of CPU cores dedicated to network IRQ handling"
  type        = number
  default     = 13
}

variable "edp_cores" {
  description = "Number of CPU cores allocated for EDP processes via cgroup"
  type        = number
  default     = 16
}

# -----------------------------------------------------------------------------
# Storage Configuration - Root Volume
# -----------------------------------------------------------------------------

variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 100
}

variable "root_volume_iops" {
  description = "Root volume IOPS (gp3)"
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Root volume throughput in MB/s (gp3)"
  type        = number
  default     = 125
}

# -----------------------------------------------------------------------------
# Storage Configuration - Binaries Volume
# -----------------------------------------------------------------------------

variable "binaries_volume_size" {
  description = "Binaries volume size in GB"
  type        = number
  default     = 50
}

variable "binaries_volume_iops" {
  description = "Binaries volume IOPS (gp3)"
  type        = number
  default     = 3000
}

variable "binaries_volume_throughput" {
  description = "Binaries volume throughput in MB/s (gp3)"
  type        = number
  default     = 125
}

variable "binaries_mount_point" {
  description = "Mount point for binaries volume"
  type        = string
  default     = "/opt/trading/bin"
}

# -----------------------------------------------------------------------------
# Storage Configuration - Logs Volume
# -----------------------------------------------------------------------------

variable "logs_volume_size" {
  description = "Logs volume size in GB"
  type        = number
  default     = 200
}

variable "logs_volume_iops" {
  description = "Logs volume IOPS (gp3)"
  type        = number
  default     = 3000
}

variable "logs_volume_throughput" {
  description = "Logs volume throughput in MB/s (gp3)"
  type        = number
  default     = 250
}

variable "logs_mount_point" {
  description = "Mount point for logs volume"
  type        = string
  default     = "/var/log/trading"
}

# -----------------------------------------------------------------------------
# SSH Configuration
# -----------------------------------------------------------------------------

variable "ssh_public_key" {
  description = "SSH public key content (if provided, creates new key pair)"
  type        = string
  default     = ""
}

variable "existing_key_pair_name" {
  description = "Name of existing EC2 key pair (used if ssh_public_key is empty)"
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = alltrue([
      for cidr in var.ssh_allowed_cidrs :
      can(cidrhost(cidr, 0))
    ])
    error_message = "All SSH allowed CIDRs must be valid CIDR notation."
  }
}

# -----------------------------------------------------------------------------
# Trading Application Configuration
# -----------------------------------------------------------------------------

variable "trading_user" {
  description = "Linux user for trading application"
  type        = string
  default     = "trading"
}

variable "trading_group" {
  description = "Linux group for trading application"
  type        = string
  default     = "trading"
}

variable "trading_port_start" {
  description = "Start of trading application port range (null to disable)"
  type        = number
  default     = null
}

variable "trading_port_end" {
  description = "End of trading application port range (null to disable)"
  type        = number
  default     = null
}

variable "trading_allowed_cidrs" {
  description = "CIDR blocks allowed trading port access"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Monitoring Configuration
# -----------------------------------------------------------------------------

variable "enable_cloudwatch_alarms" {
  description = "Enable CloudWatch alarms for the instance"
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (optional)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
