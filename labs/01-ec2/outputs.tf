output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.lab.id
}

output "instance_public_ip" {

  description = "EC2 public IP"
  value       = aws_instance.lab.public_ip
}

output "instance_type" {

  description = "Instance type used"
  value       = aws_instance.lab.instance_type
}

output "asg_name" {

  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.lab.name
}

output "launch_template_id" {

  description = "Launch Template ID"
  value       = aws_launch_template.lab.id
}

output "security_group_id" {

  description = "Security Group ID"
  value       = aws_security_group.lab_ec2.id
}
