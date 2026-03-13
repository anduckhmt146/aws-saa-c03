# =============================================================================
# OUTPUTS: Lab 49 — NLB, GWLB, PrivateLink, Direct Connect, Client VPN
# =============================================================================

# -----------------------------------------------------------------------------
# Network Load Balancer Outputs
# -----------------------------------------------------------------------------

output "nlb_dns_name" {
  description = <<-EOT
    DNS name of the Network Load Balancer.
    SAA-C03: NLB DNS resolves to the static Elastic IPs assigned per AZ.
    Unlike ALB (which has dynamic IPs), NLB EIPs are fixed — enabling
    firewall IP whitelisting. Exam tip: "static IP" = NLB.
  EOT
  value       = aws_lb.nlb.dns_name
}

output "nlb_static_ips" {
  description = <<-EOT
    Static Elastic IP addresses assigned to the NLB, one per AZ.
    SAA-C03: This is the KEY differentiator vs ALB (ALB has no static IPs).
    Use case: customer firewall rules that must whitelist specific IPs.
    These IPs are stable — they do not change with NLB scaling events.
    Exam trigger: "whitelist IPs" + "load balancer" = NLB with Elastic IPs.
  EOT
  value       = aws_eip.nlb[*].public_ip
}

output "nlb_tcp_target_group_arn" {
  description = <<-EOT
    ARN of the NLB TCP target group.
    SAA-C03: NLB target group protocols: TCP, UDP, TCP_UDP, TLS.
    ALB target group protocols: HTTP, HTTPS.
    NLB TCP health checks: port-open check only (no HTTP path).
    NLB HTTP health checks: optional, if targets serve HTTP.
  EOT
  value       = aws_lb_target_group.nlb_tcp.arn
}

# -----------------------------------------------------------------------------
# Gateway Load Balancer Outputs
# -----------------------------------------------------------------------------

output "gwlb_arn" {
  description = <<-EOT
    ARN of the Gateway Load Balancer.
    SAA-C03: GWLB operates at Layer 3 (IP) using GENEVE protocol (port 6081).
    Distributes traffic to security appliances transparently — source and
    destination IPs are preserved (unlike NLB/ALB which modify headers).
    Exam tip: "inline inspection" + "third-party firewall" = GWLB.
    "Transparent" + "packet inspection" + "fleet" = GWLB.
  EOT
  value       = aws_lb.gwlb.arn
}

output "gwlb_endpoint_service_name" {
  description = <<-EOT
    Service name of the GWLB VPC Endpoint Service.
    SAA-C03: GWLB uses PrivateLink under the hood to connect workload VPCs
    to the security appliance fleet across VPC boundaries.
    Workload VPCs create a GatewayLoadBalancer-type endpoint pointing here.
    Route tables in workload VPC send traffic to this endpoint for inspection.
  EOT
  value       = aws_vpc_endpoint_service.gwlb.service_name
}

output "gwlb_consumer_endpoint_id" {
  description = <<-EOT
    ID of the GWLB Endpoint in the consumer (workload) VPC.
    SAA-C03: This endpoint is placed in route tables to redirect traffic
    through the GWLB security fleet before reaching its destination.
    Traffic flow: workload → GWLB endpoint → GWLB → appliance → return.
  EOT
  value       = aws_vpc_endpoint.gwlb.id
}

# -----------------------------------------------------------------------------
# PrivateLink Outputs
# -----------------------------------------------------------------------------

output "privatelink_service_name" {
  description = <<-EOT
    Service name of the PrivateLink VPC Endpoint Service.
    SAA-C03: Share this name with consumer VPCs/accounts so they can
    create Interface Endpoints pointing to your service.
    Format: com.amazonaws.vpce.<region>.<endpoint-service-id>
    Cross-account: YES. Cross-region: NO (same region only).
    Exam: "SaaS expose service privately to customers" = PrivateLink.
  EOT
  value       = aws_vpc_endpoint_service.main.service_name
}

output "privatelink_consumer_endpoint_dns" {
  description = <<-EOT
    DNS name of the Interface Endpoint in the consumer VPC.
    SAA-C03: Interface Endpoint creates an ENI in consumer's subnet.
    Consumer accesses the service via this private DNS name or ENI's private IP.
    No internet traffic — stays on AWS backbone end-to-end.
    Cost: Interface Endpoints (PrivateLink) have hourly + data charges.
    Gateway Endpoints (S3/DynamoDB) are FREE — use route table entries instead.
    Exam: "access S3 without internet" = Gateway Endpoint (free, not PrivateLink).
  EOT
  value       = aws_vpc_endpoint.consumer.dns_entry[0].dns_name
}

# -----------------------------------------------------------------------------
# Direct Connect Outputs
# -----------------------------------------------------------------------------

output "dx_gateway_id" {
  description = <<-EOT
    ID of the Direct Connect Gateway.
    SAA-C03: DX Gateway is a GLOBAL resource (not region-specific).
    Connects one DX connection to multiple VPCs (up to 10 VGWs) across regions.
    DX + DX Gateway: multi-VPC, multi-region connectivity from one DX connection.
    DX + DX Gateway + TGW: hundreds of VPCs via Transit Gateway.
    DX alone + VGW: single VPC only.
  EOT
  value       = aws_dx_gateway.main.id
}

output "dx_gateway_asn" {
  description = <<-EOT
    Amazon-side BGP ASN of the Direct Connect Gateway.
    SAA-C03: BGP (Border Gateway Protocol) is used for route exchange over DX.
    Amazon side ASN: 64512–65534 (private ASN range) or public ASN.
    Customer side: their own BGP ASN (private or public).
    DX uses BGP for dynamic routing — routes propagate automatically.
    Compare: Site-to-Site VPN also uses BGP (dynamic) or static routes.
  EOT
  value       = aws_dx_gateway.main.amazon_side_asn
}

# -----------------------------------------------------------------------------
# Client VPN Outputs
# -----------------------------------------------------------------------------

output "client_vpn_log_group" {
  description = <<-EOT
    CloudWatch Log Group name for Client VPN connection logs.
    SAA-C03: Client VPN logs track connections: who, when, from where, duration.
    Useful for compliance, auditing, and troubleshooting.
    Client VPN is for REMOTE USERS (not site-to-site).
    split_tunnel=true: only VPC traffic through VPN (internet goes direct).
    split_tunnel=false: ALL traffic through VPN (full tunnel, more secure).
    Exam: "remote workers access VPC" = Client VPN (not Site-to-Site VPN).
  EOT
  value       = aws_cloudwatch_log_group.client_vpn.name
}

# -----------------------------------------------------------------------------
# SAA-C03 Exam Cheat Sheet
# -----------------------------------------------------------------------------

output "exam_cheat_sheet" {
  description = "Comprehensive SAA-C03 comparison: load balancers, endpoints, connectivity"
  value       = <<-EOT

    =====================================================================
    SAA-C03 EXAM CHEAT SHEET: Load Balancers & Network Connectivity
    =====================================================================

    --- LOAD BALANCER COMPARISON ---

    Feature                  | ALB              | NLB                    | GWLB
    -------------------------|------------------|------------------------|------------------
    OSI Layer                | Layer 7 (HTTP)   | Layer 4 (TCP/UDP/TLS)  | Layer 3 (IP)
    Protocol                 | HTTP, HTTPS, gRPC| TCP, UDP, TLS, TCP_UDP | GENEVE (6081 UDP)
    Static IP                | NO (DNS only)    | YES (Elastic IP/AZ)    | N/A
    Source IP preservation   | No (X-Fwd-For)   | YES (default)          | YES (transparent)
    Latency                  | ~400ms           | ~100ms                 | Appliance-dependent
    Cross-zone default       | Enabled (free)   | Disabled (costs extra) | Configurable
    Use case                 | Web apps, HTTP   | TCP/UDP, gaming, VoIP  | Security appliances
    Exam trigger             | "HTTP routing"   | "Static IP/whitelist"  | "Inline firewall"
                             | "Host/path route"| "Millions RPS"         | "Transparent IDS"
                             | "WAF integration"| "Preserve client IP"   | "3rd party FW"

    --- VPC ENDPOINT COMPARISON ---

    Feature              | Gateway Endpoint        | Interface Endpoint (PrivateLink)
    ---------------------|-------------------------|----------------------------------
    Services             | S3 and DynamoDB ONLY    | 150+ AWS services + custom
    Cost                 | FREE                    | Hourly + data transfer charges
    Implementation       | Route table entry       | ENI with private IP in subnet
    DNS                  | No DNS change needed    | Private DNS name (optional)
    Security group       | Not applicable          | Required (controls access)
    Cross-account        | No                      | YES (PrivateLink)
    Exam trigger         | "S3 without internet"   | "Private access to AWS service"
                         | "DynamoDB private"      | "SaaS expose to customers"

    --- PRIVATELINK vs VPC PEERING vs TRANSIT GATEWAY ---

    Feature          | VPC Peering         | PrivateLink          | Transit Gateway
    -----------------|---------------------|----------------------|-------------------
    Transitivity     | Non-transitive      | N/A (service model)  | Transitive (hub)
    CIDR overlap     | NOT allowed         | Allowed (ENI)        | NOT allowed
    Cross-account    | YES                 | YES                  | YES
    Cross-region     | YES                 | NO (same region)     | YES (peering)
    Scale            | N*N mesh problem    | 1 service → 1000s    | Centralized hub
    Use case         | Full VPC access     | Service exposure     | Many VPCs
    Exam trigger     | "2-3 VPCs share"    | "SaaS service"       | "10+ VPCs connect"
                     | "Full connectivity" | "No CIDR conflict"   | "Hub-and-spoke"

    --- DIRECT CONNECT vs SITE-TO-SITE VPN ---

    Feature          | Direct Connect              | Site-to-Site VPN
    -----------------|-----------------------------|----------------------
    Path             | Dedicated private circuit   | Internet (IPSec tunnel)
    Setup time       | Weeks to months             | Minutes
    Bandwidth        | 50Mbps - 100Gbps            | Up to 1.25 Gbps/tunnel
    Latency          | Consistent, low             | Variable (internet)
    Encryption       | NOT by default (add VPN)    | YES (IPSec always)
    Cost             | High (port fees)            | Low (data transfer)
    Redundancy       | Use 2nd DX or VPN failover  | Multi-tunnel HA
    Exam trigger     | "Consistent performance"    | "Quick setup"
                     | "Dedicated bandwidth"       | "Cost-effective hybrid"
                     | "Compliance, private"       | "Backup for DX"

    --- CLIENT VPN vs SITE-TO-SITE VPN ---

    Feature          | Client VPN                  | Site-to-Site VPN
    -----------------|-----------------------------|----------------------
    Who connects     | Individual remote users     | Networks (office to AWS)
    Client software  | AWS VPN Client (OpenVPN)    | Customer gateway device
    Auth             | Cert, AD, SAML/SSO          | Pre-shared key or cert
    Split tunnel     | Configurable (true/false)   | N/A
    Use case         | Remote workers, WFH         | On-premises to VPC
    Exam trigger     | "Remote employees"          | "Office network to VPC"
                     | "User-to-VPC access"        | "On-premises integration"

    --- DIRECT CONNECT GATEWAY PATTERNS ---

    Pattern                        | Connectivity
    -------------------------------|-----------------------------------------------
    DX + VGW                       | 1 DX connection → 1 VPC
    DX + DX Gateway                | 1 DX connection → up to 10 VPCs (multi-region)
    DX + DX Gateway + TGW          | 1 DX connection → hundreds of VPCs via TGW
    DX + VPN (IPSec over DX)       | Encrypted DX (compliance requirement)
    Primary DX + Backup VPN        | HA pattern: DX fails → VPN takes over (BGP)

    =====================================================================
  EOT
}
