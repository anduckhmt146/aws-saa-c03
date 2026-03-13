output "vpc_id" {
  value = aws_vpc.main.id
}
output "alb_dns_name" {
  value = aws_lb.main.dns_name
}
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}
output "rds_endpoint" {
  value     = aws_db_instance.main.endpoint
  sensitive = true
}
output "redis_endpoint" {
  value = aws_elasticache_replication_group.main.primary_endpoint_address
}
output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.bucket
}
output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
