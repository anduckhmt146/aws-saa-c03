output "primary_endpoint" {
  description = "RDS primary endpoint"
  value       = aws_db_instance.primary.endpoint
}

output "replica_endpoint" {

  description = "RDS read replica endpoint"
  value       = aws_db_instance.read_replica.endpoint
}

output "primary_arn" {

  value = aws_db_instance.primary.arn
}

output "db_subnet_group_name" {

  value = aws_db_subnet_group.lab.name
}
