# =============================================================================
# LAB 49: NLB, Gateway Load Balancer, PrivateLink, Direct Connect, Client VPN
# =============================================================================
# SAA-C03 Topics Covered:
#   - Network Load Balancer (Layer 4, static IPs, ultra-low latency)
#   - Gateway Load Balancer (Layer 3, GENEVE, security appliances)
#   - AWS PrivateLink (VPC Endpoint Service + Interface Endpoints)
#   - Direct Connect (Dedicated vs Hosted, DX Gateway, VGW)
#   - AWS Client VPN (remote access, split tunnel, auth options)
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# SECTION 1: VPC FOUNDATION
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.80.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "lab-main-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = ["10.80.0.0/24", "10.80.1.0/24"][count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "lab-public-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = ["10.80.10.0/24", "10.80.11.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "lab-private-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "lab-igw"
    Environment = var.environment
  }
}

resource "aws_eip" "nat" {
  count  = 1
  domain = "vpc"

  tags = {
    Name        = "lab-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "ngw" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "lab-ngw"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "lab-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ngw.id
  }

  tags = {
    Name        = "lab-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# SECTION 2: NETWORK LOAD BALANCER (NLB)
# =============================================================================
#
# KEY SAA-C03 FACTS ABOUT NLB:
#
# Layer:      Layer 4 (Transport) — operates on TCP, UDP, TLS
#             ALB = Layer 7 (Application, HTTP/HTTPS)
#             NLB = Layer 4 (TCP/UDP/TLS)
#             GWLB = Layer 3 (Network, IP packets)
#
# Static IPs: NLB supports ONE Elastic IP per AZ (static IP per subnet_mapping)
#             ALB has NO static IPs (DNS-based only, IPs change)
#             Exam trigger: "static IP" or "whitelist IP in firewall" = NLB
#
# Latency:    NLB ~100ms vs ALB ~400ms
#             NLB handles millions of requests per second
#
# Source IP:  NLB PRESERVES the client source IP address by default
#             ALB replaces source IP with its own; uses X-Forwarded-For header
#             Useful when backend needs to see real client IP
#
# Cross-zone: NLB has cross-zone LB DISABLED by default (extra cost if enabled)
#             ALB has cross-zone LB ENABLED by default at no extra charge
#
# TLS:        NLB can: terminate TLS (decrypt at LB), pass-through TCP (no decrypt),
#             or re-encrypt (decrypt + re-encrypt to targets)
#
# Use cases:  Gaming (low latency), financial trading, VoIP, IoT, streaming,
#             any TCP/UDP workload, anything needing static IPs
#
# Exam tip:   "Static IP" + "whitelisting" = NLB
#             "High performance" + "millions RPS" = NLB
#             "Preserve source IP" = NLB (Layer 4)
# =============================================================================

resource "aws_security_group" "nlb_targets" {
  name        = "lab-nlb-targets-sg"
  description = "Security group for NLB target EC2 instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere (NLB passes through client IP)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
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

  tags = {
    Name        = "lab-nlb-targets-sg"
    Environment = var.environment
  }
}

resource "aws_instance" "nlb_target" {
  count = 2

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.nlb_targets.id]

  # Install nginx to serve as NLB backend target
  user_data = <<-EOF
    #!/bin/bash
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx
    echo "<h1>NLB Target ${count.index + 1} - AZ: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</h1>" > /usr/share/nginx/html/index.html
  EOF

  tags = {
    Name        = "lab-nlb-target-${count.index + 1}"
    Environment = var.environment
  }
}

# Elastic IPs for NLB — one per AZ
# This is the KEY NLB differentiator: static, predictable IP addresses per AZ
# ALB does NOT support Elastic IPs (its IPs change dynamically)
resource "aws_eip" "nlb" {
  count  = 2
  domain = "vpc"

  tags = {
    Name        = "lab-nlb-eip-${count.index + 1}"
    Environment = var.environment
  }
}

# Network Load Balancer
# subnet_mapping with allocation_id = static Elastic IP per AZ
# This is the pattern that enables IP whitelisting in customer firewalls
resource "aws_lb" "nlb" {
  name               = "lab-nlb"
  internal           = false
  load_balancer_type = "network"

  # Static Elastic IPs — one per AZ (unique NLB capability)
  subnet_mapping {
    subnet_id     = aws_subnet.public[0].id
    allocation_id = aws_eip.nlb[0].id
  }

  subnet_mapping {
    subnet_id     = aws_subnet.public[1].id
    allocation_id = aws_eip.nlb[1].id
  }

  # Cross-zone load balancing: DISABLED by default on NLB
  # Enabling it costs extra (inter-AZ data transfer charges)
  # ALB: enabled by default, no extra charge
  enable_cross_zone_load_balancing = false

  tags = {
    Name        = "lab-nlb"
    Environment = var.environment
  }
}

# TCP Target Group (Layer 4 — no HTTP inspection)
resource "aws_lb_target_group" "nlb_tcp" {
  name     = "lab-nlb-tcp-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  # NLB health checks use TCP (or HTTP/HTTPS for HTTP-capable targets)
  # TCP health check: just checks port is open (no HTTP path)
  health_check {
    protocol            = "TCP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "lab-nlb-tcp-tg"
    Environment = var.environment
  }
}

# TLS Target Group
# NLB can terminate TLS here, then forward as TCP to targets
# OR forward as TLS (re-encrypt) — targets handle their own certs
resource "aws_lb_target_group" "nlb_tls" {
  name     = "lab-nlb-tls-tg"
  port     = 443
  protocol = "TLS"
  vpc_id   = aws_vpc.main.id

  health_check {
    protocol            = "TCP"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "lab-nlb-tls-tg"
    Environment = var.environment
  }
}

# Attach EC2 instances to TCP target group
resource "aws_lb_target_group_attachment" "nlb" {
  count = 2

  target_group_arn = aws_lb_target_group.nlb_tcp.arn
  target_id        = aws_instance.nlb_target[count.index].id
  port             = 80
}

# TCP listener on port 80
# NLB listeners: TCP, UDP, TCP_UDP, TLS
# ALB listeners: HTTP, HTTPS (with routing rules, host headers, paths)
resource "aws_lb_listener" "nlb_tcp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tcp.arn
  }
}

# =============================================================================
# SECTION 3: GATEWAY LOAD BALANCER (GWLB)
# =============================================================================
#
# KEY SAA-C03 FACTS ABOUT GWLB:
#
# Layer:       Layer 3 (Network) — operates on raw IP packets
#              Uses GENEVE protocol (port 6081) to encapsulate packets
#              Source and destination IPs are UNCHANGED (transparent inspection)
#
# Purpose:     Distribute traffic to a fleet of security appliances
#              (firewalls, IDS/IPS, DPI, packet inspection tools)
#              Appliances see the original traffic, inspect it, then return it
#
# Architecture (exam must-know flow):
#   1. Workload VPC has GWLB Endpoint in route table
#   2. Traffic destined for internet hits GWLB Endpoint first
#   3. GWLB Endpoint sends to GWLB (via PrivateLink tunnel)
#   4. GWLB distributes to security appliances (GENEVE encapsulation)
#   5. Appliance inspects, allows/blocks, returns to GWLB
#   6. GWLB returns traffic to GWLB Endpoint
#   7. Traffic continues to original destination
#
# GENEVE:      Generic Network Virtualization Encapsulation (RFC 8926)
#              Wraps original packet so appliance sees full L3+ content
#              Port 6081 UDP
#
# Appliances:  Palo Alto VM-Series, Cisco FTD, Fortinet FortiGate,
#              CheckPoint CloudGuard, Trend Micro, custom IDPS
#
# vs Network Firewall:
#   GWLB         = Bring Your Own Appliance (3rd party, full control)
#   Network Firewall = AWS-managed, Suricata rule engine, simpler setup
#
# Exam tip:    "Inline inspection" + "third-party firewall" = GWLB
#              "Transparent" + "packet inspection" = GWLB
# =============================================================================

# Separate VPC for security appliances (best practice: isolate inspection fleet)
resource "aws_vpc" "security" {
  cidr_block           = "10.90.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "lab-security-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "security_appliance" {
  count = 2

  vpc_id            = aws_vpc.security.id
  cidr_block        = ["10.90.0.0/24", "10.90.1.0/24"][count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "lab-security-appliance-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

# Simulated security appliances (in real deployments: Palo Alto, Fortinet, etc.)
# Must have IP forwarding enabled to pass traffic after inspection
resource "aws_instance" "security_appliance" {
  count = 2

  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.security_appliance[count.index].id

  # Enable IP forwarding so the appliance can forward inspected packets
  # Real appliances: licensed firewall software (Palo Alto PAN-OS, FortiOS, etc.)
  user_data = <<-EOF
    #!/bin/bash
    # Enable IP forwarding (required for transparent pass-through appliances)
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # Simple health check endpoint (GWLB probes this to verify appliance health)
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx
    echo "OK" > /usr/share/nginx/html/health
  EOF

  # Source/destination check MUST be disabled on security appliances
  # By default, EC2 drops packets not destined for its own IP
  # Appliances need to forward traffic for other hosts
  source_dest_check = false

  tags = {
    Name        = "lab-security-appliance-${count.index + 1}"
    Environment = var.environment
  }
}

# Gateway Load Balancer
# Distributes traffic across security appliance fleet
# Automatically scales, provides health checking and failover
resource "aws_lb" "gwlb" {
  name               = "lab-gwlb"
  load_balancer_type = "gateway"

  # GWLB lives in the security appliance subnets, NOT the workload VPC
  subnets = aws_subnet.security_appliance[*].id

  # GWLB typically has cross-zone enabled for appliance fleet redundancy
  enable_cross_zone_load_balancing = true

  tags = {
    Name        = "lab-gwlb"
    Environment = var.environment
  }
}

# GWLB Target Group — uses GENEVE protocol, port 6081
# Targets are the security appliance instances
resource "aws_lb_target_group" "gwlb" {
  name     = "lab-gwlb-tg"
  port     = 6081
  protocol = "GENEVE"
  vpc_id   = aws_vpc.security.id

  # Health check to verify appliances are operational
  # GWLB uses HTTP health check to the appliance's management endpoint
  health_check {
    port     = 80
    protocol = "HTTP"
    path     = "/health"
  }

  tags = {
    Name        = "lab-gwlb-tg"
    Environment = var.environment
  }
}

resource "aws_lb_target_group_attachment" "gwlb" {
  count = 2

  target_group_arn = aws_lb_target_group.gwlb.arn
  target_id        = aws_instance.security_appliance[count.index].id
  port             = 6081
}

# GWLB Listener
# NOTE: Gateway LB listeners do NOT specify port or protocol arguments
# The listener only needs load_balancer_arn and default_action
# All IP traffic is forwarded — GWLB operates at Layer 3 on all protocols
resource "aws_lb_listener" "gwlb" {
  load_balancer_arn = aws_lb.gwlb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gwlb.arn
  }
}

# VPC Endpoint Service for GWLB (PrivateLink mechanism)
# This creates the "service" side — workload VPCs create GWLB Endpoints pointing here
# GWLB uses PrivateLink under the hood to connect across VPC boundaries
resource "aws_vpc_endpoint_service" "gwlb" {
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]
  acceptance_required        = false

  tags = {
    Name        = "lab-gwlb-endpoint-service"
    Environment = var.environment
  }
}

# GWLB Endpoint in consumer (workload) VPC
# When traffic hits this endpoint, it's redirected to the GWLB security fleet
# Route tables in the workload VPC point to this endpoint for inspection
resource "aws_vpc_endpoint" "gwlb" {
  vpc_id            = aws_vpc.main.id
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.private[0].id]

  tags = {
    Name        = "lab-gwlb-endpoint"
    Environment = var.environment
  }
}

# =============================================================================
# SECTION 4: AWS PRIVATELINK (VPC ENDPOINT SERVICE)
# =============================================================================
#
# KEY SAA-C03 FACTS ABOUT PRIVATELINK:
#
# What it is:  Private connectivity from consumer VPC to a service in provider VPC
#              No VPC peering, no internet gateway, no NAT, no VPN needed
#              Traffic stays within AWS network
#
# Components:
#   Provider:  NLB + aws_vpc_endpoint_service ("PrivateLink service")
#   Consumer:  aws_vpc_endpoint with vpc_endpoint_type = "Interface"
#              Creates an ENI (Elastic Network Interface) with private IP in consumer subnet
#
# acceptance_required = true:
#   Provider manually approves each consumer connection request
#   Use when you want to control who can connect to your service
#
# Cross-account: YES — consumer VPC can be in a different AWS account
# Cross-region:  NO  — PrivateLink is same-region only
#
# No CIDR overlap restriction:
#   Unlike VPC peering, PrivateLink does NOT care about overlapping CIDRs
#   The ENI in consumer VPC gets a private IP from consumer's CIDR
#
# Scale:       One service endpoint → thousands of consumer VPCs
#              No "VPC peering mesh" problem (peering is non-transitive)
#
# DNS:         private_dns_enabled=true allows using the service's DNS name
#              in the consumer VPC (requires Route 53 private hosted zone)
#
# Endpoint types (exam must-know):
#   Interface Endpoint  = PrivateLink, creates ENI, costs money, any service
#   Gateway Endpoint    = S3 and DynamoDB ONLY, free, route table entry (no ENI)
#
# Exam scenarios:
#   "SaaS vendor expose service privately to customers" = PrivateLink
#   "Access S3 without internet" = Gateway Endpoint (free)
#   "Access other AWS services privately" = Interface Endpoint (PrivateLink)
#   "Connect two VPCs with overlapping CIDRs" = PrivateLink (not peering)
# =============================================================================

# Internal NLB backing the PrivateLink service
# PrivateLink REQUIRES an NLB (not ALB) as the service provider load balancer
resource "aws_lb" "service_nlb" {
  name               = "lab-privatelink-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = aws_subnet.private[*].id

  tags = {
    Name        = "lab-privatelink-nlb"
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "service" {
  name     = "lab-service-tg"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = {
    Name        = "lab-service-tg"
    Environment = var.environment
  }
}

resource "aws_lb_listener" "service" {
  load_balancer_arn = aws_lb.service_nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service.arn
  }
}

# VPC Endpoint Service — this IS the PrivateLink service
# Provider exposes their NLB-backed service here
# Consumers discover it via service_name and create Interface Endpoints
resource "aws_vpc_endpoint_service" "main" {
  network_load_balancer_arns = [aws_lb.service_nlb.arn]

  # acceptance_required = true: provider must manually accept consumer requests
  # acceptance_required = false: auto-accept all connection requests
  acceptance_required = true

  # allowed_principals: restrict which AWS accounts/IAM principals can connect
  # Empty list means any account can REQUEST (but still needs acceptance if true above)
  allowed_principals = []

  tags = {
    Name        = "lab-privatelink-service"
    Environment = var.environment
  }
}

# =============================================================================
# Consumer VPC — simulates a different customer/tenant VPC
# In real scenarios this is often a different AWS account
# =============================================================================

resource "aws_vpc" "consumer" {
  cidr_block           = "10.85.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "lab-consumer-vpc"
    Environment = var.environment
  }
}

resource "aws_subnet" "consumer" {
  vpc_id            = aws_vpc.consumer.id
  cidr_block        = "10.85.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name        = "lab-consumer-subnet"
    Environment = var.environment
  }
}

# Security group for the Interface Endpoint ENI in consumer VPC
# Controls which consumer resources can reach the PrivateLink endpoint
resource "aws_security_group" "endpoint_consumer" {
  name        = "lab-endpoint-consumer-sg"
  description = "Security group for PrivateLink Interface Endpoint"
  vpc_id      = aws_vpc.consumer.id

  ingress {
    description = "HTTPS from consumer VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.consumer.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "lab-endpoint-consumer-sg"
    Environment = var.environment
  }
}

# Interface Endpoint (consumer side)
# Creates an ENI in consumer's subnet with a private IP from consumer's CIDR
# Consumer accesses the service via this ENI's private IP or DNS name
# No internet gateway, VPN, or peering needed — stays on AWS backbone
resource "aws_vpc_endpoint" "consumer" {
  vpc_id             = aws_vpc.consumer.id
  service_name       = aws_vpc_endpoint_service.main.service_name
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.consumer.id]
  security_group_ids = [aws_security_group.endpoint_consumer.id]

  # private_dns_enabled = true would let consumers use the service's DNS hostname
  # Requires associating a private hosted zone with the consumer VPC
  private_dns_enabled = false

  tags = {
    Name        = "lab-privatelink-consumer-endpoint"
    Environment = var.environment
  }
}

# =============================================================================
# SECTION 5: DIRECT CONNECT (CONCEPTUAL — TERRAFORMABLE RESOURCES)
# =============================================================================
#
# KEY SAA-C03 FACTS ABOUT DIRECT CONNECT:
#
# Connection types:
#   Dedicated:  1 Gbps, 10 Gbps, 100 Gbps
#               Direct physical port at AWS colocation facility
#               Takes weeks to months to provision
#   Hosted:     50 Mbps, 100 Mbps, 200 Mbps, 300 Mbps, 400 Mbps, 500 Mbps,
#               1 Gbps, 2 Gbps, 5 Gbps, 10 Gbps
#               Via APN Partner (faster provisioning, flexible bandwidth)
#               Sub-1Gbps speeds only available via Hosted (from partner)
#
# Gateway hierarchy (exam must-know):
#
#   DX + VGW (Virtual Private Gateway):
#     - Connect DX to ONE VPC
#     - VGW is attached to a single VPC
#
#   DX + DX Gateway:
#     - Connect ONE DX connection to MULTIPLE VPCs (up to 10)
#     - VPCs can be in different regions (same account or cross-account)
#     - DX Gateway is a global resource (not region-specific)
#
#   DX + DX Gateway + Transit Gateway:
#     - Connect DX to HUNDREDS of VPCs via Transit Gateway
#     - Most scalable pattern for large enterprises
#
# Encryption:
#   DX is NOT encrypted by default (private connection, but no encryption)
#   For encryption: run VPN (IPSec) over the DX connection
#   MACsec: Layer 2 encryption, available on Dedicated 10/100Gbps connections
#
# Failover pattern (exam):
#   Primary:  Direct Connect (high bandwidth, low latency, consistent)
#   Backup:   Site-to-Site VPN (internet-based, lower cost, auto-failover via BGP)
#
# Virtual Interfaces:
#   Private VIF: connect to resources in a VPC (via VGW or DX Gateway)
#   Public VIF:  access AWS public endpoints (S3, DynamoDB, etc.) via DX
#   Transit VIF: connect to Transit Gateway via DX Gateway
#
# Exam triggers:
#   "Consistent network performance" = Direct Connect (not VPN over internet)
#   "Dedicated bandwidth" = Direct Connect
#   "On-premises to AWS, weeks setup" = Direct Connect
#   "Hybrid cloud, compliance" = Direct Connect
# =============================================================================

# Direct Connect Gateway — can be Terraformed (software resource, no hardware)
# Global resource: attach DX connections from any region
# Associate with up to 10 VGWs or 1 Transit Gateway
resource "aws_dx_gateway" "main" {
  name            = "lab-dx-gateway"
  amazon_side_asn = 64512
}

# Associate DX Gateway with Transit Gateway (once real DX connection exists)
# Uncomment when aws_ec2_transit_gateway.main exists (e.g., from lab 31)
# resource "aws_dx_gateway_association" "tgw" {
#   dx_gateway_id         = aws_dx_gateway.main.id
#   associated_gateway_id = aws_ec2_transit_gateway.main.id
# }

# Virtual Private Gateway — per-VPC gateway for Direct Connect or VPN
# Attach to VPC, then associate with DX Gateway or use for Site-to-Site VPN
resource "aws_vpn_gateway" "dx_vgw" {
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = 64513

  tags = {
    Name        = "lab-dx-vgw"
    Environment = var.environment
  }
}

# Resources that CANNOT be Terraformed without physical hardware/colocation:
#
# resource "aws_dx_connection" "main" {
#   # Requires reserving a physical port at an AWS colocation facility
#   # Or purchasing hosted connection capacity from an APN Partner
#   name      = "lab-dx-connection"
#   bandwidth = "1Gbps"
#   location  = "EqDC2"  # equinix DC, check aws_dx_locations data source
# }
#
# resource "aws_dx_private_virtual_interface" "main" {
#   # Requires an active DX connection
#   # Private VIF: connect to VPC resources via VGW or DX Gateway
#   connection_id    = aws_dx_connection.main.id
#   name             = "lab-private-vif"
#   vlan             = 4094
#   address_family   = "ipv4"
#   bgp_asn          = 65000  # customer BGP ASN
#   dx_gateway_id    = aws_dx_gateway.main.id
# }
#
# resource "aws_dx_public_virtual_interface" "main" {
#   # Public VIF: access AWS public services (S3, DynamoDB) over DX
#   # Bypasses internet, uses AWS backbone to reach public endpoints
#   connection_id    = aws_dx_connection.main.id
#   name             = "lab-public-vif"
#   vlan             = 4093
#   address_family   = "ipv4"
#   bgp_asn          = 65000
#   route_filter_prefixes = ["192.0.2.0/24"]  # your on-premises prefix
# }
#
# resource "aws_dx_hosted_connection" "main" {
#   # APN Partner provisions a hosted connection on your behalf
#   # Faster setup, flexible bandwidth (50Mbps to 10Gbps)
#   connection_id    = "dxcon-XXXXXXXX"  # partner's parent connection
#   name             = "lab-hosted-dx"
#   bandwidth        = "500Mbps"
#   owner_account_id = "123456789012"
#   vlan             = 101
# }

# =============================================================================
# SECTION 6: AWS CLIENT VPN
# =============================================================================
#
# KEY SAA-C03 FACTS ABOUT CLIENT VPN:
#
# What it is:  OpenVPN-based managed VPN for remote users to access VPC resources
#              User installs AWS VPN Client (OpenVPN-compatible) on their device
#              Provides secure remote access (like corporate VPN)
#
# Authentication options:
#   Certificate-based:    Mutual TLS (client + server certs), most secure
#   Active Directory:     AWS Managed Microsoft AD or AD Connector (SSO-like)
#   SAML/Federated:       Okta, Azure AD, Ping Identity, OneLogin (modern SSO)
#
# Split tunnel (exam critical):
#   split_tunnel = true:  ONLY VPC-destined traffic goes through VPN
#                         Client accesses internet directly (bypasses VPN)
#                         Lower latency, lower bandwidth costs
#   split_tunnel = false: ALL traffic through VPN (full tunnel)
#                         More secure (internet traffic inspected too)
#                         Higher latency, more bandwidth consumed
#
# Client CIDR:
#   /22 block supports 1,022 concurrent connections
#   Must NOT overlap with VPC CIDR or on-premises networks
#   AWS allocates /27 per AZ association from this pool
#
# Scaling:
#   Associate endpoint with multiple subnets (one per AZ) for HA
#   Up to 5 subnet associations per endpoint
#
# vs Site-to-Site VPN:
#   Client VPN:       User-to-network (individual remote workers)
#   Site-to-Site VPN: Network-to-network (office to VPC, on-prem to AWS)
#
# Exam triggers:
#   "Remote workers" + "access VPC" = Client VPN
#   "Individual users" + "VPN" = Client VPN
#   "Office network" + "VPN to AWS" = Site-to-Site VPN
# =============================================================================

# CloudWatch Log Group for Client VPN connection logs
# Tracks: who connected, from which IP, connection duration, bytes transferred
resource "aws_cloudwatch_log_group" "client_vpn" {
  name              = "/aws/client-vpn/lab"
  retention_in_days = 7

  tags = {
    Name        = "lab-client-vpn-logs"
    Environment = var.environment
  }
}

# Client VPN Endpoint — commented out because it requires ACM certificates
# In a real lab: use aws_acm_certificate (or aws_acm_certificate_validation) with
# ACM-imported self-signed certs (use easyrsa or openssl to generate)
#
# resource "aws_ec2_client_vpn_endpoint" "main" {
#   description            = "lab-client-vpn"
#   server_certificate_arn = aws_acm_certificate.server.arn
#   client_cidr_block      = "10.200.0.0/22"  # /22 = 1022 concurrent connections
#
#   # Certificate-based mutual TLS authentication
#   authentication_options {
#     type                       = "certificate-authentication"
#     root_certificate_chain_arn = aws_acm_certificate.client_ca.arn
#   }
#
#   # Active Directory authentication (requires AWS Managed AD or AD Connector)
#   # authentication_options {
#   #   type                = "directory-service-authentication"
#   #   active_directory_id = aws_directory_service_directory.main.id
#   # }
#
#   # SAML/Federated authentication (Okta, Azure AD, etc.)
#   # authentication_options {
#   #   type              = "federated-authentication"
#   #   saml_provider_arn = aws_iam_saml_provider.vpn.arn
#   # }
#
#   connection_log_options {
#     enabled               = true
#     cloudwatch_log_group  = aws_cloudwatch_log_group.client_vpn.name
#     cloudwatch_log_stream = "connections"
#   }
#
#   # split_tunnel = true:  only VPC traffic through VPN, internet goes direct
#   # split_tunnel = false: ALL traffic through VPN (full tunnel, more secure)
#   split_tunnel = true
#
#   tags = {
#     Name        = "lab-client-vpn"
#     Environment = var.environment
#   }
# }
#
# # Associate endpoint with subnets for high availability across AZs
# resource "aws_ec2_client_vpn_network_association" "main" {
#   client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
#   subnet_id              = aws_subnet.private[0].id
# }
#
# # Authorization rule: which users/groups can access which CIDR ranges
# resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
#   client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.main.id
#   target_network_cidr    = aws_vpc.main.cidr_block
#   authorize_all_groups   = true
# }
