# =============================================================================
# Trading Metal Instance Infrastructure
# Single instance deployment with public access and SSH
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Local Variables
# -----------------------------------------------------------------------------

locals {
  common_tags = merge(var.additional_tags, {
    Project     = "trading-infrastructure"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# -----------------------------------------------------------------------------
# AMI - Amazon Linux 2023 (latest)
# -----------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# SSH Key Pair
# -----------------------------------------------------------------------------

resource "aws_key_pair" "trading" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "trading-metal-${var.environment}-${var.instance_name}"
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "trading_metal" {
  name_prefix = "trading-metal-${var.instance_name}-"
  description = "Security group for trading metal instance"
  vpc_id      = var.vpc_id

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
    description = "SSH access"
  }

  # Trading application ports
  dynamic "ingress" {
    for_each = var.trading_port_start != null && var.trading_port_end != null ? [1] : []
    content {
      from_port   = var.trading_port_start
      to_port     = var.trading_port_end
      protocol    = "tcp"
      cidr_blocks = var.trading_allowed_cidrs
      description = "Trading application ports"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(local.common_tags, {
    Name = "trading-metal-${var.instance_name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Trading Instance
# -----------------------------------------------------------------------------

resource "aws_iam_role" "trading_instance" {
  name_prefix = "trading-metal-${var.instance_name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.trading_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "trading_instance" {
  name_prefix = "trading-metal-policy-"
  role        = aws_iam_role.trading_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeInstances",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "trading" {
  name_prefix = "trading-metal-${var.instance_name}-"
  role        = aws_iam_role.trading_instance.name
  tags        = local.common_tags
}

# -----------------------------------------------------------------------------
# Partition Placement Group
# -----------------------------------------------------------------------------

resource "aws_placement_group" "trading" {
  name            = "trading-metal-${var.environment}-${var.instance_name}"
  strategy        = "partition"
  partition_count = var.partition_count

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Elastic IP for Public Access
# -----------------------------------------------------------------------------

resource "aws_eip" "trading" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "trading-metal-${var.instance_name}-eip"
  })
}

resource "aws_eip_association" "trading" {
  instance_id   = aws_instance.trading_metal.id
  allocation_id = aws_eip.trading.id
}

# -----------------------------------------------------------------------------
# Metal Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "trading_metal" {
  ami           = var.custom_ami_id != "" ? var.custom_ami_id : data.aws_ami.al2023.id
  instance_type = var.instance_type

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.trading_metal.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.trading.name

  key_name = var.ssh_public_key != "" ? aws_key_pair.trading[0].key_name : var.existing_key_pair_name

  placement_group            = aws_placement_group.trading.id
  placement_partition_number = var.partition_number

  # Disable source/dest check for potential network optimizations
  source_dest_check = false

  # CPU options for metal instances - disable hyperthreading
  cpu_options {
    threads_per_core = 1
  }

  # Root volume
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    iops                  = var.root_volume_iops
    throughput            = var.root_volume_throughput
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.common_tags, {
      Name = "trading-metal-${var.instance_name}-root"
    })
  }

  # Binaries volume
  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_size           = var.binaries_volume_size
    volume_type           = "gp3"
    iops                  = var.binaries_volume_iops
    throughput            = var.binaries_volume_throughput
    encrypted             = true
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "trading-metal-${var.instance_name}-binaries"
    })
  }

  # Logs volume
  ebs_block_device {
    device_name           = "/dev/sdc"
    volume_size           = var.logs_volume_size
    volume_type           = "gp3"
    iops                  = var.logs_volume_iops
    throughput            = var.logs_volume_throughput
    encrypted             = true
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "trading-metal-${var.instance_name}-logs"
    })
  }

  # NOTE: Core dumps disk excluded per requirements

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring = true

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    environment       = var.environment
    instance_type     = var.instance_type
    network_irq_cores = var.network_irq_cores
    edp_cores         = var.edp_cores
    binaries_device   = "/dev/sdb"
    binaries_mount    = var.binaries_mount_point
    logs_device       = "/dev/sdc"
    logs_mount        = var.logs_mount_point
    trading_user      = var.trading_user
    trading_group     = var.trading_group
  }))

  tags = merge(local.common_tags, {
    Name = "trading-metal-${var.instance_name}"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "trading-metal-${var.instance_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU utilization high on trading metal instance"

  dimensions = {
    InstanceId = aws_instance.trading_metal.id
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "trading-metal-${var.instance_name}-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Status check failed on trading metal instance"

  dimensions = {
    InstanceId = aws_instance.trading_metal.id
  }

  alarm_actions = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  tags = local.common_tags
}
