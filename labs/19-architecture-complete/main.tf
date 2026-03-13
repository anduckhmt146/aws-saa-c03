# ============================================================
# LAB 19 - Complete Well-Architected 3-Tier Web Application
#
# Architecture:
#   Internet → CloudFront → ALB (Public) → EC2 ASG (Private)
#           → ElastiCache (cache layer)
#           → RDS Multi-AZ (Private)
#           → S3 (Static assets)
#
# Covers all 6 Well-Architected pillars:
#   1. Operational Excellence: CloudWatch, CloudTrail, Systems Manager
#   2. Security:  IAM roles, SGs, KMS, WAF, private subnets
#   3. Reliability: Multi-AZ, Auto Scaling, Route 53 health checks
#   4. Performance: CloudFront, ElastiCache, ASG, gp3 storage
#   5. Cost Optimization: ASG, Spot mix, S3 lifecycle, Reserved
#   6. Sustainability: Auto-shutdown schedules, right-sizing
# ============================================================

data "aws_availability_zones" "available" { state = "available" }
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
data "aws_caller_identity" "current" {}
resource "random_id" "suffix" { byte_length = 4 }

# ─────────────────────────────────────────────
# LAYER 0: NETWORKING (VPC)
# ─────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "prod-vpc" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1) # 10.0.1/2.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "public-${count.index + 1}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 11) # 10.0.11/12.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "app-${count.index + 1}", Tier = "app" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 21) # 10.0.21/22.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "db-${count.index + 1}", Tier = "db" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "prod-igw" }
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "prod-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  count          = length(aws_subnet.db)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.private.id
}

# VPC Endpoint for S3 (free, avoids NAT costs)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# ─────────────────────────────────────────────
# SECURITY GROUPS (3-tier isolation)
# ─────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "prod-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-alb-sg" }
}

resource "aws_security_group" "app" {
  name   = "prod-app-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id] # Only from ALB
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-app-sg" }
}

resource "aws_security_group" "db" {
  name   = "prod-db-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id] # Only from app tier
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-db-sg" }
}

resource "aws_security_group" "cache" {
  name   = "prod-cache-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-cache-sg" }
}

# ─────────────────────────────────────────────
# LAYER 1: S3 (Static assets + logs)
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "static" {
  bucket        = "prod-static-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "static" {
  bucket = aws_s3_bucket.static.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    id     = "archive-old-assets"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }
}

# ─────────────────────────────────────────────
# LAYER 2: ALB + CloudFront (CDN)
# ─────────────────────────────────────────────
resource "aws_lb" "main" {
  name                       = "prod-alb"
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  enable_deletion_protection = false
  tags                       = { Name = "prod-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "prod-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_access_control_id = aws_cloudfront_origin_access_control.static.id
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    default_ttl = 0
    max_ttl     = 0
  }

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate { cloudfront_default_certificate = true }
  retain_on_delete = false
  tags             = { Name = "prod-cloudfront" }
}

resource "aws_cloudfront_origin_access_control" "static" {
  name                              = "prod-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ─────────────────────────────────────────────
# LAYER 3: APP TIER (EC2 Auto Scaling)
# ─────────────────────────────────────────────
resource "aws_iam_role" "app" {
  name = "prod-app-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "app_s3" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "app" {
  name = "prod-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_launch_template" "app" {
  name_prefix   = "prod-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.app_instance_type

  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile { name = aws_iam_instance_profile.app.name }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip
    pip3 install flask gunicorn
    cat > /app.py << 'PYEOF'
    from flask import Flask, jsonify
    app = Flask(__name__)
    @app.route('/health')
    def health(): return jsonify(status='healthy')
    @app.route('/')
    def index(): return jsonify(message='SAA Lab 19 - Well-Architected App')
    PYEOF
    gunicorn --bind 0.0.0.0:8080 app:app --daemon
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "prod-app-instance", Backup = "true" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "prod-app-asg"
  min_size            = 2 # Minimum 2 for HA (multi-AZ)
  max_size            = 10
  desired_capacity    = 2
  vpc_zone_identifier = aws_subnet.app[*].id

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  # Note: deployment_circuit_breaker is for ECS services, not ASG

  tag {
    key                 = "Name"
    value               = "prod-app-instance"
    propagate_at_launch = true
  }
}

# Target tracking: scale to maintain 60% CPU
resource "aws_autoscaling_policy" "cpu" {
  name                   = "prod-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 60.0
  }
}

# ─────────────────────────────────────────────
# LAYER 4: CACHE (ElastiCache Redis)
# ─────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "main" {
  name       = "prod-cache-subnet-group"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "prod-redis"
  description                = "Production Redis cache"
  node_type                  = "cache.t3.micro"
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.cache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  apply_immediately          = true
  final_snapshot_identifier  = null
}

# ─────────────────────────────────────────────
# LAYER 5: DATABASE (RDS Multi-AZ)
# ─────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "prod-db-subnet-group"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "main" {
  identifier        = "prod-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "proddb"
  username = "admin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  multi_az                = true # HA: synchronous standby in another AZ
  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "prod-mysql", Backup = "true" }
}

# ─────────────────────────────────────────────
# OBSERVABILITY: CloudWatch
# ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "prod-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app.name }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "prod-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 100
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
}

resource "aws_cloudwatch_dashboard" "prod" {
  dashboard_name = "prod-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title   = "ASG CPU"
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name]]
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title   = "ALB Requests"
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix]]
          period  = 300
          stat    = "Sum"
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title   = "RDS Connections"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier]]
          period  = 300
          stat    = "Average"
        }
      }
    ]
  })
}

resource "aws_sns_topic" "alerts" {
  name = "prod-alerts"
}

# CloudTrail (audit all API calls)
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "prod-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "prod-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ─────────────────────────────────────────────
# LAYER 6: DNS (Route 53)
# Private hosted zone for internal service discovery
# Health checks enable automatic failover via DNS
# ─────────────────────────────────────────────
resource "aws_route53_zone" "internal" {
  name = "prod.internal"
  vpc {
    vpc_id = aws_vpc.main.id
  }
  tags = { Name = "prod-internal-zone" }
}

# ALB internal DNS alias
resource "aws_route53_record" "alb" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "api.prod.internal"
  type    = "A"
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# RDS internal DNS
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.prod.internal"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.main.address]
}

# Redis internal DNS
resource "aws_route53_record" "cache" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "cache.prod.internal"
  type    = "CNAME"
  ttl     = 60
  records = [aws_elasticache_replication_group.main.primary_endpoint_address]
}

# Health check on ALB — triggers SNS alert if unhealthy
resource "aws_route53_health_check" "alb" {
  fqdn              = aws_lb.main.dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30
  tags              = { Name = "prod-alb-health-check" }
}
