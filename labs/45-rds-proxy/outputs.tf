###############################################################################
# OUTPUTS - Lab 45: RDS Proxy
###############################################################################

output "mysql_proxy_endpoint" {
  description = "RDS Proxy endpoint for MySQL - use this as the DB host in your application (read/write, routes to primary)"
  value       = aws_db_proxy.mysql.endpoint
}

output "postgresql_proxy_endpoint" {
  description = "RDS Proxy endpoint for PostgreSQL - use this as the DB host in your application (read/write, routes to primary)"
  value       = aws_db_proxy.postgres.endpoint
}

output "mysql_readonly_endpoint" {
  description = "Read-only proxy endpoint for MySQL - route analytics/reporting queries here to offload the primary"
  value       = aws_db_proxy_endpoint.mysql_readonly.endpoint
}

output "proxy_iam_role_arn" {
  description = "ARN of the IAM role assumed by RDS Proxy to retrieve DB credentials from Secrets Manager"
  value       = aws_iam_role.rds_proxy.arn
}

output "mysql_secret_arn" {
  description = "ARN of the Secrets Manager secret holding MySQL credentials - RDS Proxy reads this; the app never does"
  value       = aws_secretsmanager_secret.mysql_db.arn
}

output "mysql_db_instance_identifier" {
  description = "Identifier of the MySQL RDS instance registered as a proxy target"
  value       = aws_db_instance.mysql.identifier
}

output "postgres_db_instance_identifier" {
  description = "Identifier of the PostgreSQL RDS instance registered as a proxy target"
  value       = aws_db_instance.postgres.identifier
}

output "proxy_security_group_id" {
  description = "Security group ID for the RDS Proxy - reference this in Lambda/ECS security groups to allow outbound to proxy"
  value       = aws_security_group.proxy.id
}

output "vpc_id" {
  description = "VPC ID where the proxy and DB instances reside - proxy is VPC-only, never publicly accessible"
  value       = data.aws_vpc.default.id
}
