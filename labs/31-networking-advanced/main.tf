################################################################################
# Lab 31: Advanced AWS Networking
# SAA-C03 Exam Focus: Hybrid connectivity, inter-VPC routing, acceleration,
#                     VPC endpoints, and traffic observability
################################################################################
#
# TOPIC OVERVIEW
# ==============
#
# 1. SITE-TO-SITE VPN
# --------------------
# An IPSec encrypted tunnel connecting your on-premises network to AWS.
# Key components:
#   - Virtual Private Gateway (VGW): AWS side termination point, attached to a VPC.
#   - Customer Gateway (CGW): represents your on-prem device (firewall/router).
#   - VPN Connection: logically joins VGW + CGW; always has TWO tunnels for HA.
#
# Bandwidth: each tunnel supports up to 1.25 Gbps (and is subject to network jitter).
# Routing options:
#   - Static routing:  you manually specify on-prem CIDRs in AWS.
#   - Dynamic routing: uses BGP (Border Gateway Protocol); AWS ASN 64512 by default.
#     BGP propagates routes automatically and supports failover between tunnels.
#
# SAA-C03 EXAM TIPS:
#   "Encrypted connection to on-premises"        = Site-to-Site VPN (default answer)
#   "Dedicated, private, high-bandwidth"         = Direct Connect
#   "Encrypted dedicated connection"             = DX + VPN over it (DX is NOT encrypted)
#   "VPN over internet is too slow/unreliable"   = Direct Connect
#   Two VPN tunnels per connection = HA; do NOT confuse with two separate VPN connections.
#
# 2. DIRECT CONNECT (DX)
# ----------------------
# A dedicated private physical connection from your data center to an AWS DX location.
# Bandwidth options: 1, 10, or 100 Gbps.
# Key characteristics:
#   - Lower latency and more consistent throughput than internet-based VPN.
#   - NOT encrypted by default — traffic traverses a private circuit but is not IPSec.
#   - To encrypt DX: run a Site-to-Site VPN tunnel over the DX connection.
#
# Virtual Interfaces (VIFs):
#   - Private VIF: connects to resources inside a single VPC via a VGW.
#   - Public VIF:  connects to AWS public services (S3, DynamoDB) without internet.
#   - Transit VIF: connects to a Transit Gateway (supports multiple VPCs/regions).
#
# Direct Connect Gateway (DXGW):
#   - Allows a single DX connection to reach multiple VPCs across multiple regions.
#   - Attach multiple VGWs (or a TGW via Transit VIF) to one DXGW.
#   - Key exam distinction: DXGW does NOT enable VPC-to-VPC routing; it only routes
#     between on-prem and each VPC individually.
#
# SAA-C03 EXAM PATTERNS:
#   "Connect single DX to multiple VPCs in different regions" = DX Gateway
#   "Encrypted traffic over dedicated circuit"               = DX + VPN
#   "Public VIF"                                             = reach S3/DynamoDB via DX
#
# 3. TRANSIT GATEWAY (TGW)
# -------------------------
# A regional, fully managed hub-and-spoke network transit hub.
# Connects: VPCs, Site-to-Site VPNs, Direct Connect (via Transit VIF), and
#           other TGWs (inter-region peering).
#
# Key concepts:
#   - Each attachment (VPC, VPN, DX, peering) gets an entry in a TGW route table.
#   - Multiple route tables allow traffic segmentation (e.g., prod vs. dev).
#   - Supports IP Multicast (unique to TGW — VPC peering does not).
#   - Inter-region peering: connect TGWs across regions for global routing.
#   - Bandwidth: up to 50 Gbps per VPC attachment (burst).
#
# SAA-C03 EXAM PATTERN:
#   "You have 5 VPCs that all need to communicate" = Transit Gateway (not VPC peering).
#   VPC peering requires N*(N-1)/2 connections for full mesh — TGW is O(N).
#   "On-prem needs to reach multiple VPCs"         = TGW + VPN or TGW + DX Transit VIF.
#   "Shared services VPC"                          = TGW with separate route tables.
#
# 4. VPC PEERING
# ---------------
# A one-to-one connection between two VPCs enabling private routing.
# Constraints:
#   - No transitive routing: if VPC-A peers with VPC-B and VPC-B peers with VPC-C,
#     VPC-A CANNOT reach VPC-C through VPC-B. Each pair needs its own peering.
#   - No overlapping CIDRs allowed.
#   - Works across accounts and across regions.
#   - No bandwidth cap (uses the underlying AWS backbone).
#
# SAA-C03 EXAM TIP:
#   "Does not support transitive routing" is a KEY differentiator from TGW.
#   For 2 VPCs: peering is simpler and cheaper. For 3+: prefer TGW.
#
# 5. AWS PRIVATELINK (VPC ENDPOINT SERVICES)
# -------------------------------------------
# Expose a service running behind an NLB in your VPC to consumers in OTHER VPCs
# without requiring VPC peering, internet gateway, NAT, or VPN.
#
# Two endpoint types:
#   - Interface Endpoint: creates an ENI in your VPC with a private IP.
#     Backed by AWS PrivateLink. Used for AWS services (SSM, Secrets Manager, etc.)
#     and custom endpoint services. Costs per-hour + per-GB.
#   - Gateway Endpoint: FREE; only supports S3 and DynamoDB.
#     Adds an entry to your VPC route table pointing to the AWS-managed prefix list.
#
# SAA-C03 EXAM PATTERNS:
#   "EC2 in private subnet needs access to S3 without internet"   = Gateway Endpoint (free)
#   "Expose internal microservice to other VPC without peering"   = PrivateLink / Interface Endpoint
#   "Private access to SSM, Secrets Manager, ECR from private subnet" = Interface Endpoints
#
# 6. AWS GLOBAL ACCELERATOR
# --------------------------
# Provides two static anycast IP addresses that route user traffic to the nearest
# healthy AWS endpoint using the AWS global network backbone.
#
# Supports: ALB, NLB, EC2 instances, Elastic IPs.
# Protocol support: TCP and UDP (NOT HTTP-aware, no caching).
#
# Key characteristics:
#   - Anycast: the same two IPs are advertised from all AWS edge locations worldwide.
#   - Failover: automatically reroutes traffic to healthy endpoints within seconds.
#   - Traffic dials and endpoint weights: control traffic distribution per endpoint group.
#   - Health checks built-in (unlike Route 53 which needs separate health check resources).
#
# Global Accelerator vs CloudFront:
# +--------------------+---------------------------+-------------------------------+
# | Feature            | Global Accelerator        | CloudFront                    |
# +--------------------+---------------------------+-------------------------------+
# | Protocol           | TCP / UDP (any)           | HTTP / HTTPS only             |
# | Caching            | No                        | Yes (edge caching)            |
# | Static IP          | Yes (2 anycast IPs)       | No (uses CNAMEs)              |
# | Use case           | Gaming, IoT, VoIP, APIs   | Web content, media, HTML      |
# | IP whitelisting    | Easy (only 2 IPs)         | Hard (many CF IPs)            |
# +--------------------+---------------------------+-------------------------------+
#
# SAA-C03 EXAM PATTERNS:
#   "Non-HTTP workload needing low-latency global routing"   = Global Accelerator
#   "Static IP needed for global multi-region app"           = Global Accelerator
#   "HTTP caching for static content"                        = CloudFront
#
# 7. VPC FLOW LOGS
# -----------------
# Capture METADATA about IP traffic flowing through VPC network interfaces.
# Flow logs do NOT capture packet content (not a packet capture tool).
# Captured fields: srcaddr, dstaddr, srcport, dstport, protocol, packets,
#                  bytes, start, end, action (ACCEPT/REJECT), log-status.
#
# Scope: VPC level, subnet level, or individual ENI level.
# Destinations:
#   - CloudWatch Logs (for querying via Insights, dashboards, alarms)
#   - Amazon S3      (for Athena queries, long-term storage, cost-effective)
#   - Kinesis Data Firehose (for near-real-time streaming to destinations)
#
# SAA-C03 EXAM TIPS:
#   "Why is traffic being REJECTED to my EC2?"    = Check VPC Flow Logs (REJECT entries)
#   "Audit network traffic for compliance"        = VPC Flow Logs to S3 / CloudWatch
#   Flow logs capture AFTER security group / NACL decisions, so REJECT = blocked by SG/NACL.
#
################################################################################

################################################################################
# DATA SOURCES
################################################################################

# Fetch the current AWS account ID and region — used in resource names and policies.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

################################################################################
# VPCs
# We create two "spoke" VPCs that will be connected via Transit Gateway, plus
# a simulated "on-prem" VPC to illustrate VPN / peering concepts.
################################################################################

# SPOKE VPC A — production workloads
# SAA-C03: Non-overlapping CIDRs are REQUIRED for VPC peering and TGW attachments.
resource "aws_vpc" "spoke_a" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "lab31-spoke-vpc-a"
    # SAA-C03: DNS support + hostnames must both be true for Interface Endpoints
    # (PrivateLink) to work with private DNS names inside the VPC.
  }
}

# SPOKE VPC B — staging / secondary workloads
resource "aws_vpc" "spoke_b" {
  cidr_block           = "10.2.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "lab31-spoke-vpc-b"
  }
}

# Subnets in each spoke VPC — TGW attachments require at least one subnet per AZ.
resource "aws_subnet" "spoke_a_private" {
  vpc_id            = aws_vpc.spoke_a.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "lab31-spoke-a-private"
  }
}

resource "aws_subnet" "spoke_b_private" {
  vpc_id            = aws_vpc.spoke_b.id
  cidr_block        = "10.2.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "lab31-spoke-b-private"
  }
}

################################################################################
# SITE-TO-SITE VPN
# Components: Virtual Private Gateway (VGW) + Customer Gateway (CGW) + VPN Connection
################################################################################

# VIRTUAL PRIVATE GATEWAY (VGW)
# The AWS-side termination point for the Site-to-Site VPN tunnel.
# Attached to a VPC; you can only attach one VGW per VPC at a time.
# The amazon_side_asn defines the BGP ASN that AWS advertises to your on-prem router.
# Default AWS ASN is 64512; you can use any private ASN (64512-65534) or a public one.
resource "aws_vpn_gateway" "main" {
  vpc_id          = aws_vpc.spoke_a.id
  amazon_side_asn = 64512

  tags = {
    Name = "lab31-vgw"
    # SAA-C03: VGW is always attached to exactly ONE VPC.
    # If you need one VGW to reach MULTIPLE VPCs, you need a Transit Gateway instead.
  }
}

# CUSTOMER GATEWAY (CGW)
# Represents your on-premises VPN device (firewall, router, etc.).
# ip_address: the public IP of your on-prem device.
# bgp_asn:    the BGP ASN your on-prem device will use (private ASN 65000 here).
# SAA-C03: CGW is just a Terraform/AWS config object — it does NOT create any
#          physical hardware. You must configure your on-prem device separately.
resource "aws_customer_gateway" "on_prem" {
  bgp_asn    = 65000
  ip_address = "203.0.113.10" # RFC 5737 documentation IP (replace with real on-prem IP)
  type       = "ipsec.1"      # Only supported type; uses IKEv1 or IKEv2

  tags = {
    Name = "lab31-cgw-on-prem"
  }
}

# VPN CONNECTION
# Joins the VGW and CGW; AWS automatically provisions TWO IPSec tunnels for HA.
# If one tunnel fails, traffic automatically fails over to the second tunnel.
#
# static_routes_only = false means BGP (dynamic routing) is used.
# BGP advantages:
#   - Routes are automatically propagated (no manual CIDR management).
#   - Faster failover between tunnels compared to static routing.
#   - Supports BFD (Bidirectional Forwarding Detection) for sub-second failover.
#
# Tunnel options (optional — shown for exam awareness):
#   - tunnel1_preshared_key / tunnel2_preshared_key: shared secret for IKE auth.
#   - tunnel1_inside_cidr: /30 CIDR for the BGP peering address inside the tunnel.
#   - Phase 1 (IKE): authentication and key exchange.
#   - Phase 2 (IPSec): encrypts the actual data traffic.
resource "aws_vpn_connection" "to_on_prem" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.on_prem.id
  type                = "ipsec.1"
  static_routes_only  = false # false = BGP dynamic routing; true = static routing

  # SAA-C03: Two tunnels are ALWAYS created. Each supports 1.25 Gbps max.
  # For > 1.25 Gbps you need multiple VPN connections (ECMP is supported on TGW).
  # VGW does NOT support ECMP — TGW is required for aggregated bandwidth.

  tags = {
    Name = "lab31-vpn-to-on-prem"
  }
}

# VPN Route (only needed when static_routes_only = true)
# With BGP (static_routes_only=false), routes are propagated automatically.
# This resource is shown here as a reference for the static routing exam scenario.
# resource "aws_vpn_connection_route" "on_prem_cidr" {
#   destination_cidr_block = "192.168.0.0/16"   # on-prem CIDR
#   vpn_connection_id      = aws_vpn_connection.to_on_prem.id
# }

# VGW Route Propagation — tells the VPC route table to automatically learn
# routes advertised by BGP from the on-prem network via the VGW.
resource "aws_vpn_gateway_route_propagation" "spoke_a" {
  vpn_gateway_id = aws_vpn_gateway.main.id
  route_table_id = aws_vpc.spoke_a.default_route_table_id

  # SAA-C03: Without route propagation, instances in the VPC cannot reach on-prem
  # even though the VPN tunnel is established. Route propagation = automatic.
}

################################################################################
# TRANSIT GATEWAY (TGW)
# Hub-and-spoke: connects multiple VPCs, VPNs, and DX attachments.
################################################################################

# TRANSIT GATEWAY
# amazon_side_asn: BGP ASN for the TGW (used when connecting to VPN or DX).
# auto_accept_shared_attachments: when sharing TGW across accounts via RAM,
#   "enable" means attachments from other accounts are auto-accepted.
# default_route_table_association / propagation: controls whether new attachments
#   are automatically associated with and propagate routes to the default route table.
#   Setting to "disable" gives you full manual control (best practice for segmentation).
# dns_support: allows DNS resolution across TGW attachments.
# vpn_ecmp_support: enables Equal-Cost Multi-Path routing across multiple VPN tunnels
#   — this is what allows you to exceed the 1.25 Gbps single-tunnel limit.
resource "aws_ec2_transit_gateway" "main" {
  description                     = "Lab 31 Transit Gateway - hub for all VPCs and VPN"
  amazon_side_asn                 = 64512
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable" # SAA-C03: disable for manual segmentation
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable" # enables ECMP across VPN tunnels for > 1.25 Gbps

  tags = {
    Name = "lab31-tgw"
    # SAA-C03: TGW is REGIONAL. Inter-region routing requires TGW peering attachments.
    # TGW can connect: VPCs, Site-to-Site VPNs, DX (Transit VIF), other TGWs (peering).
  }
}

# TGW ATTACHMENT — SPOKE VPC A
# Attaches Spoke VPC A to the Transit Gateway.
# At least one subnet per AZ must be specified; TGW creates an ENI in each subnet.
# Best practice: use dedicated "TGW subnets" (/28 is sufficient) to avoid
# consuming IPs from application subnets.
resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_a" {
  subnet_ids         = [aws_subnet.spoke_a_private.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.spoke_a.id

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "lab31-tgw-attach-spoke-a"
  }
}

# TGW ATTACHMENT — SPOKE VPC B
resource "aws_ec2_transit_gateway_vpc_attachment" "spoke_b" {
  subnet_ids         = [aws_subnet.spoke_b_private.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.spoke_b.id

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "lab31-tgw-attach-spoke-b"
  }
}

# TGW ROUTE TABLE
# A TGW route table controls which attachments can route to which other attachments.
# You can create multiple route tables to isolate traffic:
#   - "prod" route table: only prod VPCs + VPN
#   - "dev" route table: only dev VPCs (no VPN access)
# SAA-C03: This is the primary mechanism for network segmentation in a TGW topology.
resource "aws_ec2_transit_gateway_route_table" "main" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = {
    Name = "lab31-tgw-rt-main"
  }
}

# Associate Spoke A attachment with the route table.
# Association determines which route table an attachment uses to look up destinations.
resource "aws_ec2_transit_gateway_route_table_association" "spoke_a" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_a.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke_b" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_b.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# Propagation: allows an attachment to automatically advertise its VPC CIDR into
# this route table. Without propagation, you must add static routes manually.
resource "aws_ec2_transit_gateway_route_table_propagation" "spoke_a" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_a.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "spoke_b" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke_b.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
}

# Add routes in spoke VPCs pointing to TGW for inter-VPC traffic.
# Each spoke's route table needs a route for the OTHER spoke's CIDR via TGW.
resource "aws_route" "spoke_a_to_spoke_b" {
  route_table_id         = aws_vpc.spoke_a.default_route_table_id
  destination_cidr_block = aws_vpc.spoke_b.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_a]
}

resource "aws_route" "spoke_b_to_spoke_a" {
  route_table_id         = aws_vpc.spoke_b.default_route_table_id
  destination_cidr_block = aws_vpc.spoke_a.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke_b]
}

################################################################################
# VPC PEERING
# One-to-one connection — illustrates the simpler (but non-scalable) alternative.
# SAA-C03: Use this for 2 VPCs. For 3+ VPCs prefer Transit Gateway.
################################################################################

# VPC PEERING CONNECTION between Spoke A and Spoke B.
# For same-account same-region peering the connection is auto-accepted.
# Cross-account or cross-region peering requires explicit acceptance.
resource "aws_vpc_peering_connection" "a_to_b" {
  vpc_id      = aws_vpc.spoke_a.id
  peer_vpc_id = aws_vpc.spoke_b.id
  auto_accept = true # Only works for same account + same region

  tags = {
    Name = "lab31-peering-a-to-b"
    # SAA-C03 KEY RULE: No transitive routing.
    # If A<->B and B<->C peering exists, traffic from A CANNOT reach C via B.
    # Each VPC pair that needs to communicate must have its own peering connection.
    # Additionally: NO overlapping CIDRs allowed between peered VPCs.
  }
}

# Route in Spoke A's route table pointing to Spoke B's CIDR via peering.
# BOTH sides must have routes — peering alone does not enable routing.
resource "aws_route" "peer_a_to_b" {
  route_table_id            = aws_vpc.spoke_a.default_route_table_id
  destination_cidr_block    = aws_vpc.spoke_b.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id
}

resource "aws_route" "peer_b_to_a" {
  route_table_id            = aws_vpc.spoke_b.default_route_table_id
  destination_cidr_block    = aws_vpc.spoke_a.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id
}

################################################################################
# VPC INTERFACE ENDPOINT (AWS PRIVATELINK)
# Private access to AWS SSM (Systems Manager) from within the VPC without
# routing traffic over the internet — no NAT Gateway, no IGW required.
################################################################################

# Security group for the interface endpoint ENIs.
# The endpoint ENI needs to ACCEPT HTTPS (port 443) from instances in the VPC.
resource "aws_security_group" "endpoint_sg" {
  name        = "lab31-endpoint-sg"
  description = "Allow HTTPS from VPC to Interface Endpoints"
  vpc_id      = aws_vpc.spoke_a.id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.spoke_a.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab31-endpoint-sg"
  }
}

# INTERFACE ENDPOINT for AWS Systems Manager (SSM).
# Creates an ENI in the specified subnet with a private IP from the VPC CIDR.
# private_dns_enabled = true: overrides the public SSM DNS name so that calls to
#   ssm.us-east-1.amazonaws.com resolve to the private ENI IP inside the VPC.
# SAA-C03: Three SSM endpoints are needed for full SSM Session Manager functionality:
#   - com.amazonaws.<region>.ssm
#   - com.amazonaws.<region>.ec2messages
#   - com.amazonaws.<region>.ssmmessages
# This lab only creates the primary ssm endpoint for demonstration.
resource "aws_vpc_endpoint" "ssm" {
  vpc_id            = aws_vpc.spoke_a.id
  service_name      = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type = "Interface" # SAA-C03: Interface = PrivateLink = ENI with private IP

  subnet_ids          = [aws_subnet.spoke_a_private.id]
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true

  # SAA-C03: Gateway Endpoints (S3, DynamoDB) are FREE and use route table entries.
  # Interface Endpoints cost ~$0.01/hr per AZ + $0.01/GB — but work for ALL services.
  # Gateway Endpoint example (no cost, no ENI):
  # vpc_endpoint_type = "Gateway"
  # route_table_ids   = [aws_vpc.spoke_a.default_route_table_id]

  tags = {
    Name = "lab31-endpoint-ssm"
  }
}

################################################################################
# AWS GLOBAL ACCELERATOR
# Static anycast IPs + intelligent routing to the nearest healthy endpoint
# using the AWS global backbone — NOT the public internet.
################################################################################

# GLOBAL ACCELERATOR
# Provisions two static anycast IPv4 addresses globally advertised from AWS edge
# PoPs. Traffic enters the AWS network at the nearest edge location and is then
# routed over the private AWS backbone to the endpoint — avoiding the internet
# for the majority of the path.
resource "aws_globalaccelerator_accelerator" "main" {
  name            = "lab31-global-accelerator"
  ip_address_type = "IPV4"
  enabled         = true

  # ip_addresses: optionally bring your own IPs (BYOIP).
  # If omitted, AWS assigns two IPs from its global anycast pool.

  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.flow_logs.bucket
    flow_logs_s3_prefix = "global-accelerator/"
    # SAA-C03: Global Accelerator flow logs show client IP, endpoint IP,
    # protocol, and bytes — useful for visibility and troubleshooting.
  }

  tags = {
    Name = "lab31-global-accelerator"
  }
}

# GLOBAL ACCELERATOR LISTENER
# Defines which ports and protocols the accelerator accepts traffic on.
# protocol = "TCP" or "UDP" — Global Accelerator is NOT HTTP-aware.
# For HTTP/HTTPS with content inspection and caching, use CloudFront instead.
resource "aws_globalaccelerator_listener" "http" {
  accelerator_arn = aws_globalaccelerator_accelerator.main.id
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }

  client_affinity = "NONE"
  # client_affinity options:
  #   NONE       — each connection may go to a different endpoint (default).
  #   SOURCE_IP  — same source IP always goes to the same endpoint (useful for
  #                stateful apps that don't use sticky sessions at the load balancer).
  # SAA-C03: SOURCE_IP affinity is the Global Accelerator way to achieve session stickiness.
}

# GLOBAL ACCELERATOR ENDPOINT GROUP
# Groups one or more endpoints in a specific AWS region.
# You can create multiple endpoint groups for different regions; Global Accelerator
# routes to the geographically nearest healthy group.
resource "aws_globalaccelerator_endpoint_group" "main" {
  listener_arn = aws_globalaccelerator_listener.http.id

  endpoint_group_region         = var.aws_region
  traffic_dial_percentage       = 100 # 0-100; reduce to shift traffic to another region
  health_check_interval_seconds = 30
  health_check_protocol         = "HTTP"
  health_check_path             = "/health"
  threshold_count               = 3 # consecutive failures before endpoint is unhealthy

  # Endpoint: can be ALB, NLB, EC2 instance, or Elastic IP.
  # weight: 0-255; relative proportion of traffic among endpoints in the same group.
  # client_ip_preservation_enabled: passes the original client IP to the endpoint
  #   (requires NLB or EC2 endpoints; ALB with IP target type also supports this).
  endpoint_configuration {
    endpoint_id                    = aws_vpn_gateway.main.id # placeholder — normally an ALB/NLB ARN
    weight                         = 100
    client_ip_preservation_enabled = false
  }

  # SAA-C03 EXAM COMPARISON:
  # Global Accelerator health checks are built-in and automatic.
  # Route 53 latency routing also routes to the nearest region, but:
  #   - Uses DNS TTL-based failover (slower, DNS caching affects RTO).
  #   - Does NOT use a dedicated backbone (still traverses the internet).
  # Global Accelerator: faster failover (seconds), static IPs, TCP/UDP support.
}

################################################################################
# VPC FLOW LOGS (to S3)
# Captures IP traffic metadata at the VPC level.
################################################################################

# S3 BUCKET for flow logs and Global Accelerator logs.
# Using a single bucket with prefixes to separate log types.
resource "aws_s3_bucket" "flow_logs" {
  bucket        = "lab31-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Allow destroy even when bucket has objects (lab convenience)

  tags = {
    Name    = "lab31-flow-logs"
    Purpose = "VPC Flow Logs and Global Accelerator Logs"
    # SAA-C03: Flow logs to S3 are best for long-term retention and Athena queries.
    # Flow logs to CloudWatch Logs are best for real-time alerting and dashboards.
    # Flow logs to Kinesis Data Firehose are best for near-real-time streaming.
  }
}

# Block all public access to the logs bucket — never expose flow logs publicly.
resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# VPC FLOW LOG
# Captures traffic metadata for all ENIs in Spoke VPC A.
# traffic_type options:
#   ALL     — captures both ACCEPT and REJECT records (most comprehensive).
#   ACCEPT  — only traffic allowed by security groups and NACLs.
#   REJECT  — only traffic blocked by security groups or NACLs.
#             REJECT is most useful for troubleshooting connectivity issues.
resource "aws_flow_log" "spoke_a" {
  vpc_id          = aws_vpc.spoke_a.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = "${aws_s3_bucket.flow_logs.arn}/vpc-flow-logs/"

  log_destination_type = "s3"

  # log_format (optional): customize the fields captured in flow log records.
  # Default format includes the standard fields. Custom format can add:
  #   - ${vpc-id}, ${subnet-id}, ${instance-id} — resource context
  #   - ${tcp-flags} — SYN, ACK, FIN, RST flags
  #   - ${pkt-srcaddr}, ${pkt-dstaddr} — original IPs when NAT is involved
  # SAA-C03: The pkt-* fields are important when NAT Gateway is in use because
  # the standard srcaddr/dstaddr show NAT IPs, not the original endpoint IPs.

  tags = {
    Name = "lab31-flow-log-spoke-a"
  }
}

# IAM ROLE for VPC Flow Logs (required when destination is CloudWatch Logs).
# For S3 destination, AWS uses a service-linked role, but Terraform requires an
# iam_role_arn argument — we create a minimal role here.
resource "aws_iam_role" "flow_log" {
  name = "lab31-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "flow_log" {
  name = "lab31-flow-log-policy"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.flow_logs.arn}/*"
      }
    ]
  })
}
