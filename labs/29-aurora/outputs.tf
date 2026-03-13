output "aurora_cluster_endpoint" {
  description = "Writer endpoint — connects to primary instance"
  value       = aws_rds_cluster.aurora_mysql.endpoint
}
output "aurora_reader_endpoint" {
  description = "Reader endpoint — load-balanced across all read replicas"
  value       = aws_rds_cluster.aurora_mysql.reader_endpoint
}
output "aurora_cluster_id" {
  value = aws_rds_cluster.aurora_mysql.cluster_identifier
}
output "aurora_cluster_arn" {
  value = aws_rds_cluster.aurora_mysql.arn
}
output "aurora_port" {
  value = aws_rds_cluster.aurora_mysql.port
}
