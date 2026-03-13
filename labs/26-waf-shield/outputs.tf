output "waf_acl_arn" {
  description = "WAF Web ACL ARN — associate this with ALB/CloudFront/API GW"
  value       = aws_wafv2_web_acl.lab_waf_acl.arn
}
output "waf_acl_id" {
  value = aws_wafv2_web_acl.lab_waf_acl.id
}
output "waf_log_group_name" {
  value = aws_cloudwatch_log_group.waf_logs.name
}
output "blocked_ip_set_arn" {
  value = aws_wafv2_ip_set.blocked_ips.arn
}
