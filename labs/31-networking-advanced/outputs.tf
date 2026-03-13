################################################################################
# Lab 31 Outputs — Advanced Networking
################################################################################

output "spoke_a_vpc_id" {
  description = "VPC ID of Spoke A"
  value       = aws_vpc.spoke_a.id
}

output "spoke_b_vpc_id" {
  description = "VPC ID of Spoke B"
  value       = aws_vpc.spoke_b.id
}

output "vpn_gateway_id" {
  description = "Virtual Private Gateway ID (AWS-side VPN termination)"
  value       = aws_vpn_gateway.main.id
}

output "customer_gateway_id" {
  description = "Customer Gateway ID (represents on-prem device)"
  value       = aws_customer_gateway.on_prem.id
}

output "vpn_connection_id" {
  description = "Site-to-Site VPN connection ID"
  value       = aws_vpn_connection.to_on_prem.id
}

output "vpn_tunnel1_address" {
  description = "Public IP of VPN tunnel 1 (AWS side)"
  value       = aws_vpn_connection.to_on_prem.tunnel1_address
  # SAA-C03: Two tunnel IPs are always provisioned. Configure BOTH on your on-prem
  # device to enable HA failover if one tunnel goes down.
}

output "vpn_tunnel2_address" {
  description = "Public IP of VPN tunnel 2 (AWS side)"
  value       = aws_vpn_connection.to_on_prem.tunnel2_address
}

output "transit_gateway_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.main.id
}

output "transit_gateway_route_table_id" {
  description = "TGW route table ID for manual route and association management"
  value       = aws_ec2_transit_gateway_route_table.main.id
}

output "tgw_attachment_spoke_a_id" {
  description = "TGW attachment ID for Spoke VPC A"
  value       = aws_ec2_transit_gateway_vpc_attachment.spoke_a.id
}

output "tgw_attachment_spoke_b_id" {
  description = "TGW attachment ID for Spoke VPC B"
  value       = aws_ec2_transit_gateway_vpc_attachment.spoke_b.id
}

output "vpc_peering_connection_id" {
  description = "VPC peering connection ID between Spoke A and Spoke B"
  value       = aws_vpc_peering_connection.a_to_b.id
}

output "ssm_endpoint_id" {
  description = "Interface endpoint ID for AWS SSM in Spoke A"
  value       = aws_vpc_endpoint.ssm.id
}

output "ssm_endpoint_dns_entry" {
  description = "Private DNS entries for the SSM endpoint (use with private_dns_enabled=true)"
  value       = aws_vpc_endpoint.ssm.dns_entry
}

output "global_accelerator_arn" {
  description = "Global Accelerator ARN"
  value       = aws_globalaccelerator_accelerator.main.id
}

output "global_accelerator_ip_sets" {
  description = "Static anycast IP addresses assigned to the Global Accelerator"
  value       = aws_globalaccelerator_accelerator.main.ip_sets
  # SAA-C03: These two IPs are static and globally anycast — they never change.
  # Whitelist just these two IPs at your firewall for global ingress.
}

output "flow_logs_s3_bucket" {
  description = "S3 bucket name for VPC flow logs"
  value       = aws_s3_bucket.flow_logs.bucket
}

output "flow_log_id" {
  description = "VPC flow log resource ID for Spoke A"
  value       = aws_flow_log.spoke_a.id
}
