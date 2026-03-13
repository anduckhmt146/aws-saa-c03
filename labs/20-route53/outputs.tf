output "private_zone_id" {
  value = aws_route53_zone.private.zone_id
}
output "private_zone_name_servers" {
  value = aws_route53_zone.private.name_servers
}
output "public_zone_id" {
  value = var.domain_name != "" ? aws_route53_zone.public[0].zone_id : "N/A - set domain_name variable"
}
output "public_zone_name_servers" {
  description = "Delegate these NS records at your registrar"
  value       = var.domain_name != "" ? aws_route53_zone.public[0].name_servers : []
}
output "health_check_primary_id" {
  value = aws_route53_health_check.primary.id
}
output "resolver_inbound_ips" {
  description = "Configure on-prem DNS to forward AWS queries to these IPs"
  value       = aws_route53_resolver_endpoint.inbound.ip_address[*].ip
}
output "alb_primary_dns" {
  value = aws_lb.primary.dns_name
}
