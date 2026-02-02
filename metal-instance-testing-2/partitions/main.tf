terraform {
  required_version = ">= 1.0.0"

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

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "placement_group_name" {
  description = "Name of the placement group"
  type        = string
  default     = "my-partition-group"
}

variable "partition_count" {
  description = "Number of partitions in the placement group"
  type        = number
  default     = 15
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "production"
}

resource "aws_placement_group" "partition_group" {
  name            = var.placement_group_name
  strategy        = "partition"
  partition_count = var.partition_count

  tags = {
    Name        = var.placement_group_name
    Environment = var.environment
  }
}

output "placement_group_id" {
  description = "ID of the placement group"
  value       = aws_placement_group.partition_group.id
}

output "placement_group_arn" {
  description = "ARN of the placement group"
  value       = aws_placement_group.partition_group.arn
}

output "placement_group_name" {
  description = "Name of the placement group"
  value       = aws_placement_group.partition_group.name
}

output "partition_count" {
  description = "Number of partitions"
  value       = aws_placement_group.partition_group.partition_count
}
