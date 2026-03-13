output "alb_dns_name" { value = aws_lb.lab.dns_name }
output "cloudfront_domain" { value = aws_cloudfront_distribution.lab.domain_name }
output "cloudfront_id" { value = aws_cloudfront_distribution.lab.id }
output "target_group_main_arn" { value = aws_lb_target_group.main.arn }

output "acm_certificate_arn" {
  description = <<-EOT
    ARN of the ACM certificate for lab.example.com.
    SAA-C03: This ARN is what you reference in:
      - aws_lb_listener: certificate_arn
      - aws_cloudfront_distribution: viewer_certificate.acm_certificate_arn
      - aws_api_gateway_domain_name: certificate_arn
    IMPORTANT: CloudFront certs MUST be in us-east-1.
    ALB/API GW certs must be in the SAME region as the resource.
  EOT
  value       = aws_acm_certificate.main.arn
}

output "acm_certificate_status" {
  description = <<-EOT
    ACM certificate validation status: PENDING_VALIDATION | ISSUED | INACTIVE | EXPIRED | VALIDATION_TIMED_OUT | REVOKED | FAILED
    SAA-C03: Certificate stays PENDING_VALIDATION until the DNS CNAME validation record
    is added to the hosted zone. Once ISSUED, AWS auto-renews 60 days before expiry.
    VALIDATION_TIMED_OUT: DNS record was never added within 72 hours → recreate cert.
  EOT
  value       = aws_acm_certificate.main.status
}

output "acm_domain_validation_options" {
  description = <<-EOT
    DNS validation CNAME records to add to your Route 53 hosted zone.
    Each domain_name in the cert needs its own CNAME record.
    SAA-C03: Automate this with:
      for_each = { for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => dvo }
      resource "aws_route53_record" { name = dvo.resource_record_name, type = dvo.resource_record_type, records = [dvo.resource_record_value] }
  EOT
  value       = aws_acm_certificate.main.domain_validation_options
}
