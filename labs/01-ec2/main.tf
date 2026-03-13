# ============================================================
# LAB 01 - EC2, Auto Scaling, Placement Groups
# All resources are destroy-safe (no deletion_protection)
# Run: terraform apply / terraform destroy
# ============================================================

# Data sources
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_availability_zones" "available" {

  state = "available"
}

data "aws_vpc" "default" {

  default = true
}

data "aws_subnets" "default" {

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# SECURITY GROUP
# ============================================================
resource "aws_security_group" "lab_ec2" {
  name        = "lab-ec2-sg"
  description = "Security group for EC2 lab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict in production
  }

  ingress {

    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# EC2 INSTANCE (On-Demand - t3.micro free tier)
# Instance type families:
#   T3/T4g = Burstable (dev/test)
#   M5/M6  = General Purpose
#   C5/C6  = Compute Optimized (CPU-intensive)
#   R5/R6  = Memory Optimized (in-memory DB)
#   P3/P4  = Accelerated (ML training, GPU)
#   I3/I4  = Storage Optimized (high IOPS)
# ============================================================
resource "aws_instance" "lab" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.lab_ec2.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # Instance Store vs EBS:
  # - EBS: Persistent, survives stop/terminate
  # - Instance Store: Ephemeral, lost on stop/terminate, very high IOPS
  root_block_device {
    volume_type           = "gp3" # gp3 = General Purpose SSD (newer, cheaper than gp2)
    volume_size           = 8
    delete_on_termination = true # destroy-safe
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    echo "<h1>Lab 01 - EC2 Instance: $(hostname)</h1>" > /var/www/html/index.html
  EOF

  tags = {

    Name         = "lab-ec2-instance"
    PricingModel = "on-demand"
  }
}

# ============================================================
# PLACEMENT GROUP - Cluster (Low latency, same AZ)
# Types:
#   Cluster   = Low latency, high throughput, same AZ (HPC)
#   Spread    = High availability, max 7 instances/AZ
#   Partition = Big data (Hadoop/Kafka), max 7 partitions/AZ
# ============================================================
resource "aws_placement_group" "cluster" {
  name     = "lab-cluster-pg"
  strategy = "cluster"
}

resource "aws_placement_group" "spread" {

  name     = "lab-spread-pg"
  strategy = "spread"
}

resource "aws_placement_group" "partition" {

  name            = "lab-partition-pg"
  strategy        = "partition"
  partition_count = 2
}

# ============================================================
# LAUNCH TEMPLATE (recommended over Launch Configuration)
# Launch Template supports:
#   - Versioning
#   - Multiple instance types
#   - Spot + On-Demand mix
# Launch Configuration (legacy):
#   - No versioning, single instance type
# ============================================================
resource "aws_launch_template" "lab" {
  name_prefix   = "lab-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.lab_ec2.id]

  # Mix On-Demand + Spot for cost optimization
  instance_market_options {
    market_type = "spot" # 50-90% cheaper, can be interrupted with 2-min warning
    # Use case: fault-tolerant, batch processing, CI/CD
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    echo "<h1>ASG Instance: $(hostname)</h1>" > /tmp/info.txt
  EOF
  )

  tag_specifications {

    resource_type = "instance"
    tags = {
      Name = "lab-asg-instance"

    }
  }
}

# ============================================================
# AUTO SCALING GROUP
# Scaling Policies:
#   Target Tracking  = Maintain metric at target (easiest)
#   Step Scaling     = Different steps per threshold
#   Simple Scaling   = Single adjustment + cooldown
#   Scheduled        = Scale at specific times
#   Predictive       = ML-based forecast (proactive)
# ============================================================
resource "aws_autoscaling_group" "lab" {
  name                = "lab-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = data.aws_subnets.default.ids

  launch_template {
    id      = aws_launch_template.lab.id
    version = "$Latest"
  }

  # Health check: EC2 (instance status) or ELB (app health - recommended)
  health_check_type         = "EC2"
  health_check_grace_period = 300 # Default cooldown = 300 seconds

  tag {

    key                 = "Name"
    value               = "lab-asg-instance"
    propagate_at_launch = true
  }
}

# ============================================================
# AUTO SCALING POLICY - Target Tracking (keep CPU at 50%)
# ============================================================
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "lab-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.lab.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"

    }
    target_value = 50.0
  }
}

# ============================================================
# SCHEDULED SCALING (scale up at 8am, down at 8pm UTC)
# ============================================================
resource "aws_autoscaling_schedule" "scale_up" {
  scheduled_action_name  = "lab-scale-up-morning"
  autoscaling_group_name = aws_autoscaling_group.lab.name
  recurrence             = "0 8 * * *"
  desired_capacity       = var.asg_max_size
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
}

resource "aws_autoscaling_schedule" "scale_down" {

  scheduled_action_name  = "lab-scale-down-night"
  autoscaling_group_name = aws_autoscaling_group.lab.name
  recurrence             = "0 20 * * *"
  desired_capacity       = var.asg_min_size
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
}
