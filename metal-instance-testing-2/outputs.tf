# =============================================================================
# Outputs for Trading Metal Instance Infrastructure
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.trading_metal.id
}

output "instance_type" {
  description = "EC2 instance type"
  value       = aws_instance.trading_metal.instance_type
}

output "public_ip" {
  description = "Elastic IP address (use this for SSH)"
  value       = aws_eip.trading.public_ip
}

output "public_dns" {
  description = "Public DNS name"
  value       = aws_eip.trading.public_dns
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.trading_metal.private_ip
}

output "private_dns" {
  description = "Private DNS name"
  value       = aws_instance.trading_metal.private_dns
}

output "availability_zone" {
  description = "Availability zone"
  value       = aws_instance.trading_metal.availability_zone
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.trading_metal.id
}

output "placement_group_id" {
  description = "Placement group ID"
  value       = aws_placement_group.trading.id
}

output "placement_group_name" {
  description = "Placement group name"
  value       = aws_placement_group.trading.name
}

output "partition_number" {
  description = "Partition number within placement group"
  value       = var.partition_number
}

output "iam_role_arn" {
  description = "IAM role ARN"
  value       = aws_iam_role.trading_instance.arn
}

output "ssh_connection_string" {
  description = "SSH connection command"
  value       = "ssh -i <your-key.pem> ec2-user@${aws_eip.trading.public_ip}"
}

output "instance_summary" {
  description = "Summary of instance configuration"
  value = {
    name              = var.instance_name
    instance_id       = aws_instance.trading_metal.id
    instance_type     = aws_instance.trading_metal.instance_type
    public_ip         = aws_eip.trading.public_ip
    private_ip        = aws_instance.trading_metal.private_ip
    availability_zone = aws_instance.trading_metal.availability_zone
    region            = var.aws_region
    placement_group   = aws_placement_group.trading.name
    partition         = var.partition_number
  }
}
