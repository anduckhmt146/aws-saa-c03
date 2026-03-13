# ============================================================
# LAB 08 - ALB (Application Load Balancer) + CloudFront
# ELB Types: ALB (layer 7), NLB (layer 4), GWLB (layer 3)
# ============================================================

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ============================================================
# SECURITY GROUPS
# ============================================================
resource "aws_security_group" "alb" {
  name        = "lab-alb-sg"
  description = "ALB security group"
  vpc_id      = data.aws_vpc.default.id

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
}

resource "aws_security_group" "ec2" {

  name        = "lab-ec2-alb-sg"
  description = "EC2 behind ALB"
  vpc_id      = data.aws_vpc.default.id

  # Only allow traffic from ALB security group
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# EC2 INSTANCES as backend targets
# ============================================================
resource "aws_instance" "backend" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = tolist(data.aws_subnets.default.ids)[count.index % length(data.aws_subnets.default.ids)]
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum install -y httpd
    systemctl start httpd
    echo "<h1>Instance ${count.index + 1}: $(hostname)</h1>" > /var/www/html/index.html
  EOF
  )

  tags = { Name = "lab-backend-${count.index + 1}" }
}

# ============================================================
# APPLICATION LOAD BALANCER (ALB)
# Layer 7 (HTTP/HTTPS)
# Features:
#   - Host-based routing (api.example.com vs app.example.com)
#   - Path-based routing (/api/* vs /static/*)
#   - Header/query string routing
#   - WebSocket support
#   - HTTP/2
#   - Target: EC2, Lambda, ECS, IP
# ============================================================
resource "aws_lb" "lab" {
  name               = "lab-alb"
  internal           = false
  load_balancer_type = "application" # ALB
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  # destroy-safe
  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb-logs"
    enabled = true
  }

  tags = { Name = "lab-alb" }
}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "lab-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "alb_logs" {

  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb-logs/*"
    }]
  })
}

# ============================================================
# TARGET GROUP
# Health checks determine if target is healthy
# ============================================================
resource "aws_lb_target_group" "main" {
  name     = "lab-tg-main"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = { Name = "lab-tg-main" }
}

resource "aws_lb_target_group" "api" {

  name     = "lab-tg-api"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path    = "/"
    matcher = "200"
  }
}

# Register EC2 instances to target groups
resource "aws_lb_target_group_attachment" "main" {
  count            = length(aws_instance.backend)
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.backend[count.index].id
  port             = 80
}

# ============================================================
# LISTENER + ROUTING RULES
# Default: forward to main target group
# Path-based: /api/* → API target group
# ============================================================
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 80
  protocol          = "HTTP"

  # Default action
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# Path-based routing rule: /api/* → api target group
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern { values = ["/api/*"] }
  }
}

# Redirect HTTP → HTTPS (best practice)
# resource "aws_lb_listener" "redirect" {
#   load_balancer_arn = aws_lb.lab.arn
#   port              = 80
#   protocol          = "HTTP"
#   default_action {
#     type = "redirect"
#     redirect {
#       port        = "443"
#       protocol    = "HTTPS"
#       status_code = "HTTP_301"
#     }
#   }
# }

# ============================================================
# CLOUDFRONT DISTRIBUTION
# CDN: cache at 400+ edge locations globally
# Origins: S3, ALB, EC2, custom HTTP
# Use case: lowest latency globally, DDoS protection
# ============================================================
resource "aws_cloudfront_distribution" "lab" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # US, Canada, Europe only (cheapest)

  # Origin = ALB
  origin {
    domain_name = aws_lb.lab.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]

    }
  }

  default_cache_behavior {

    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }

    }

    # TTL settings (seconds)
    min_ttl     = 0
    default_ttl = 3600  # 1 hour
    max_ttl     = 86400 # 1 day
  }

  # Cache behavior for /api/* (no caching)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      cookies { forward = "all" }

    }

    min_ttl     = 0
    default_ttl = 0 # No caching for API
    max_ttl     = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {

    cloudfront_default_certificate = true # Use CloudFront cert (*.cloudfront.net)
  }

  # destroy-safe
  retain_on_delete = false

  tags = { Name = "lab-cloudfront" }
}

# =============================================================================
# SECTION: AWS CERTIFICATE MANAGER (ACM)
# =============================================================================
# ACM manages SSL/TLS certificates for AWS services.
# SAA-C03: ACM appears in nearly every HTTPS scenario.
# KEY FACTS:
#   - ACM certs are FREE (no charge for cert itself)
#   - Auto-renewal (managed by AWS, no manual renewal)
#   - Can validate via DNS (recommended) or EMAIL
#   - CloudFront requires certs in us-east-1 ONLY (even if distro serves globally)
#   - ALB/API Gateway: cert must be in same region as the LB
#   - Cannot export ACM-managed private key (use ACM Private CA for exportable)
#   - Public certs: domain validation (DNS/email), free
#   - Private CA: Internal PKI, ~$400/month per CA, certs can be exported
# EXAM TIPS:
#   - "Automate SSL renewal" = ACM
#   - "Free SSL cert" = ACM
#   - "CloudFront HTTPS" = ACM cert in us-east-1
#   - "Cannot export private key" = ACM public cert (use ACM Private CA if needed)

# ACM Certificate — DNS validation (recommended over email)
resource "aws_acm_certificate" "main" {
  domain_name               = "lab.example.com"
  subject_alternative_names = ["*.lab.example.com", "api.lab.example.com"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
    # SAA-C03: create_before_destroy is REQUIRED for certs attached to live resources.
    # Without it, Terraform would destroy the old cert before creating the new one,
    # causing a brief period where the LB/CloudFront has no valid cert.
  }

  tags = {
    Purpose = "lab-acm-demo"
  }
}

# ACM Certificate Validation (DNS method)
# SAA-C03: DNS validation = add CNAME record to your hosted zone.
# AWS then periodically checks the CNAME to verify domain ownership.
# Advantage over email: works even if domain has no email configured,
# and auto-renews WITHOUT any human action (as long as CNAME stays in DNS).
resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn
  # validation_record_fqdns would be populated from aws_route53_record resources
  # In a real deployment:
  #   for_each = { for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => dvo }
  #   resource "aws_route53_record" "cert_validation" { ... }
  #
  # EXAM: Once dns validation CNAME is added → cert becomes ISSUED in minutes.
  # ISSUED cert auto-renews 60 days before expiry (AWS manages this entirely).
  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS Listener on ALB using the ACM cert
# SAA-C03: ALB + ACM is the standard pattern for HTTPS termination.
# ALB decrypts HTTPS → forwards HTTP to targets (no cert needed on EC2).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  # ssl_policy: TLS 1.3 preferred policy. SAA-C03 exam tip:
  #   ELBSecurityPolicy-TLS13-1-2-2021-06 = TLS 1.2 + TLS 1.3 (recommended)
  #   ELBSecurityPolicy-FS = forward secrecy (ECDHE cipher suites)
  #   Use stricter policies when compliance requires PCI-DSS or HIPAA.
  certificate_arn = aws_acm_certificate.main.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# HTTP → HTTPS redirect (best practice)
# SAA-C03: Always redirect HTTP to HTTPS — never serve sensitive content over HTTP.
# This replaces the original HTTP listener's default action (conceptually).
resource "aws_lb_listener_rule" "http_redirect" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
      # 301 = permanent redirect (browsers cache it → SEO benefit)
      # 302 = temporary redirect (browsers don't cache it)
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

# SNI: Multiple Certificates on One ALB Listener
# SAA-C03: ALB supports SNI — one HTTPS listener can serve multiple domains
# using different ACM certs. Add extra certs with aws_lb_listener_certificate.
resource "aws_lb_listener_certificate" "additional" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate.main.arn
  # In a real scenario, this would be a DIFFERENT cert for a different domain.
  # Use case: example.com and api.example.com each have separate ACM certs,
  # both served from the SAME ALB listener using SNI.
}
