# ============================================================
# LAB 20 - Route 53: DNS, Routing Policies, Health Checks
#
# Concepts:
#   - Hosted zones (public + private)
#   - Record types: A, AAAA, CNAME, MX, TXT, Alias
#   - Routing policies: Simple, Weighted, Latency, Failover,
#     Geolocation, Geoproximity, Multivalue Answer
#   - Health checks (endpoint, CloudWatch alarm, calculated)
#   - Route 53 Resolver (hybrid DNS)
#
# SAA-C03 Key Points:
#   - Alias records are FREE (unlike CNAME) and work at zone apex
#   - Health checks enable automatic failover
#   - Latency routing → lowest latency, not geographically closest
#   - Geolocation → based on user's geographic location
#   - Weighted routing → A/B testing, gradual traffic shifting
#   - TTL: high = fewer DNS queries (cheaper), low = faster changes
# ============================================================

# ============================================================
# VPC (for Private Hosted Zone demo)
# ============================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # Required for private hosted zones
  enable_dns_hostnames = true
  tags                 = { Name = "lab-dns-vpc" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "lab-dns-subnet-${count.index + 1}" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ============================================================
# PUBLIC HOSTED ZONE
# Authoritative DNS for a domain on the internet
# Requires domain registration (or NS delegation)
# AWS charges $0.50/month per hosted zone
# ============================================================
resource "aws_route53_zone" "public" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name
  # comment = "Managed by Terraform"
}

# ============================================================
# PRIVATE HOSTED ZONE
# DNS resolution only within associated VPCs
# Use case: internal service discovery (db.internal, cache.internal)
# No charge for DNS queries within VPC
# ============================================================
resource "aws_route53_zone" "private" {
  name = "lab.internal"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = { Name = "lab-private-zone" }
}

# ============================================================
# RECORD TYPES
# A     = IPv4 address
# AAAA  = IPv6 address
# CNAME = Canonical name (cannot be at zone apex)
# MX    = Mail exchange
# TXT   = Text (SPF, DKIM, domain verification)
# NS    = Name servers
# SOA   = Start of authority
# Alias = AWS-specific, maps to AWS resource (FREE, at apex OK)
# ============================================================

# A Record (private) — app server
resource "aws_route53_record" "app_private" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "app.lab.internal"
  type    = "A"
  ttl     = 300 # seconds — higher TTL = fewer queries, lower = faster updates
  records = ["10.99.1.10"]
}

# CNAME Record (private) — service alias
resource "aws_route53_record" "api_cname" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "api.lab.internal"
  type    = "CNAME"
  ttl     = 300
  records = ["app.lab.internal"]
}

# TXT Record — domain verification / SPF
resource "aws_route53_record" "txt_verify" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "lab.internal"
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 include:amazonses.com ~all", "verification=lab-demo"]
}

# ============================================================
# ALB for routing policy demos
# ============================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-dns-igw" }
}

resource "aws_security_group" "alb" {
  name   = "lab-dns-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
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

resource "aws_lb" "primary" {
  name               = "lab-dns-alb-primary"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "lab-dns-alb-primary" }
}

resource "aws_lb" "secondary" {
  name               = "lab-dns-alb-secondary"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "lab-dns-alb-secondary" }
}

# ============================================================
# HEALTH CHECKS
# Monitor endpoints and trigger failover
# Types:
#   HTTP/HTTPS/TCP endpoint
#   CloudWatch alarm
#   Calculated (combine multiple checks)
# ============================================================
resource "aws_route53_health_check" "primary" {
  fqdn              = aws_lb.primary.dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = 3  # Fail after 3 consecutive failures
  request_interval  = 30 # Check every 30s (10s = faster but costs more)

  tags = { Name = "lab-primary-health-check" }
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = aws_lb.secondary.dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = { Name = "lab-secondary-health-check" }
}

# ============================================================
# ROUTING POLICIES (all demonstrated with private zone)
# ============================================================

# 1. SIMPLE ROUTING
# Single resource, no health check support (unless using alias)
# Use case: single web server
resource "aws_route53_record" "simple" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "simple.lab.internal"
  type    = "A"
  ttl     = 300
  records = ["10.99.1.20"]
}

# 2. WEIGHTED ROUTING
# Split traffic by weight percentage
# Use case: A/B testing, gradual blue/green deployments
# Weight 0 = no traffic, weight = null = all other traffic
resource "aws_route53_record" "weighted_v1" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "weighted.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.10"]
  set_identifier = "v1"
  weighted_routing_policy {
    weight = 80 # 80% to v1
  }
}

resource "aws_route53_record" "weighted_v2" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "weighted.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.11"]
  set_identifier = "v2"
  weighted_routing_policy {
    weight = 20 # 20% to v2
  }
}

# 3. LATENCY ROUTING
# Route to region with lowest network latency from user
# NOT the geographically closest — based on measured latency
# Use case: multi-region apps, global APIs
resource "aws_route53_record" "latency_us" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "latency.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.20"]
  set_identifier = "us-east-1"
  latency_routing_policy {
    region = "us-east-1"
  }
}

resource "aws_route53_record" "latency_eu" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "latency.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.21"]
  set_identifier = "eu-west-1"
  latency_routing_policy {
    region = "eu-west-1"
  }
}

# 4. FAILOVER ROUTING
# Active-passive HA: primary handles all traffic,
# secondary only receives traffic when primary health check fails
# MUST have health checks attached
resource "aws_route53_record" "failover_primary" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "failover.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.30"]
  set_identifier = "primary"
  failover_routing_policy {
    type = "PRIMARY"
  }
  health_check_id = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "failover_secondary" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "failover.lab.internal"
  type           = "A"
  ttl            = 60
  records        = ["10.99.1.31"]
  set_identifier = "secondary"
  failover_routing_policy {
    type = "SECONDARY"
  }
  health_check_id = aws_route53_health_check.secondary.id
}

# 5. GEOLOCATION ROUTING
# Route based on user's geographic location (continent/country)
# Must include a default record for unmatched locations
# Use case: serve regional content, compliance, language
resource "aws_route53_record" "geo_us" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "geo.lab.internal"
  type           = "A"
  ttl            = 300
  records        = ["10.99.1.40"]
  set_identifier = "us"
  geolocation_routing_policy {
    country = "US"
  }
}

resource "aws_route53_record" "geo_eu" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "geo.lab.internal"
  type           = "A"
  ttl            = 300
  records        = ["10.99.1.41"]
  set_identifier = "eu"
  geolocation_routing_policy {
    continent = "EU"
  }
}

resource "aws_route53_record" "geo_default" {
  zone_id        = aws_route53_zone.private.zone_id
  name           = "geo.lab.internal"
  type           = "A"
  ttl            = 300
  records        = ["10.99.1.42"]
  set_identifier = "default"
  geolocation_routing_policy {
    country = "*" # Default = catch-all
  }
}

# 6. MULTIVALUE ANSWER ROUTING
# Returns up to 8 healthy records (like simple but with health checks)
# NOT a load balancer — client picks randomly from returned IPs
# Use case: simple load distribution across multiple IPs
resource "aws_route53_record" "multi_1" {
  zone_id                          = aws_route53_zone.private.zone_id
  name                             = "multi.lab.internal"
  type                             = "A"
  ttl                              = 60
  records                          = ["10.99.1.50"]
  set_identifier                   = "server-1"
  multivalue_answer_routing_policy = true
  health_check_id                  = aws_route53_health_check.primary.id
}

resource "aws_route53_record" "multi_2" {
  zone_id                          = aws_route53_zone.private.zone_id
  name                             = "multi.lab.internal"
  type                             = "A"
  ttl                              = 60
  records                          = ["10.99.1.51"]
  set_identifier                   = "server-2"
  multivalue_answer_routing_policy = true
  health_check_id                  = aws_route53_health_check.secondary.id
}

# ============================================================
# ALIAS RECORD (public zone, if domain provided)
# Alias = AWS-specific record, points to AWS resource
# Benefits vs CNAME:
#   - FREE DNS queries (CNAME charges apply)
#   - Works at zone apex (e.g. example.com, not just www.example.com)
#   - Returns IP of target, not a hostname
#   - Auto-follows target IP changes
# Alias targets: ELB, CloudFront, S3 website, API GW, VPC endpoints
# ============================================================
resource "aws_route53_record" "alias_alb" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = aws_route53_zone.public[0].zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.primary.dns_name
    zone_id                = aws_lb.primary.zone_id
    evaluate_target_health = true # Forward health check to target
  }
}

# Apex alias (zone apex = root domain, e.g. example.com)
resource "aws_route53_record" "alias_apex" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = aws_route53_zone.public[0].zone_id
  name    = var.domain_name # zone apex
  type    = "A"
  alias {
    name                   = aws_lb.primary.dns_name
    zone_id                = aws_lb.primary.zone_id
    evaluate_target_health = true
  }
}

# ============================================================
# ROUTE 53 RESOLVER
# Hybrid DNS: resolve DNS between on-prem and AWS VPC
#
# Inbound endpoint:  on-prem → resolves AWS private DNS
# Outbound endpoint: VPC → resolves on-prem DNS
# Forwarding rules:  forward specific domains to on-prem resolvers
# ============================================================
resource "aws_security_group" "resolver" {
  name        = "lab-route53-resolver-sg"
  description = "Route 53 Resolver endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "lab-resolver-sg" }
}

# Inbound Resolver endpoint (on-prem queries AWS private DNS)
resource "aws_route53_resolver_endpoint" "inbound" {
  name      = "lab-inbound-resolver"
  direction = "INBOUND"

  security_group_ids = [aws_security_group.resolver.id]

  ip_address {
    subnet_id = aws_subnet.public[0].id
  }
  ip_address {
    subnet_id = aws_subnet.public[1].id
  }

  tags = { Name = "lab-inbound-resolver" }
}

# Outbound Resolver endpoint (VPC queries on-prem DNS)
resource "aws_route53_resolver_endpoint" "outbound" {
  name      = "lab-outbound-resolver"
  direction = "OUTBOUND"

  security_group_ids = [aws_security_group.resolver.id]

  ip_address {
    subnet_id = aws_subnet.public[0].id
  }
  ip_address {
    subnet_id = aws_subnet.public[1].id
  }

  tags = { Name = "lab-outbound-resolver" }
}

# Forwarding rule: forward corp.internal queries to on-prem DNS
# Replace 192.168.1.53 with actual on-prem DNS resolver IP
resource "aws_route53_resolver_rule" "forward_onprem" {
  domain_name          = "corp.internal"
  name                 = "lab-forward-onprem"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  target_ip {
    ip   = "192.168.1.53" # On-prem DNS resolver
    port = 53
  }

  tags = { Name = "lab-forward-corp-internal" }
}

# Associate rule with VPC
resource "aws_route53_resolver_rule_association" "forward_onprem" {
  resolver_rule_id = aws_route53_resolver_rule.forward_onprem.id
  vpc_id           = aws_vpc.main.id
}
