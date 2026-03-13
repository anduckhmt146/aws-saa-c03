output "data_lake_bucket" {
  value = aws_s3_bucket.data_lake.bucket
}
output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}
output "athena_workgroup_name" {
  value = aws_athena_workgroup.main.name
}
output "athena_database_name" {
  value = aws_athena_database.main.name
}
output "glue_database_name" {
  value = aws_glue_catalog_database.main.name
}
output "glue_etl_job_name" {
  value = aws_glue_job.csv_to_parquet.name
}

output "lake_formation_data_lake_arn" {
  description = <<-EOT
    ARN of the S3 bucket registered as a Lake Formation data lake location.
    SAA-C03: After registration, Lake Formation governs access to this S3 path.
    Use case: fine-grained column/row-level permissions on Glue catalog tables,
    cross-account data sharing, ACID transactions (Governed Tables).
    Exam: "row/column security on data lake" = Lake Formation (not S3 bucket policies).
  EOT
  value       = aws_s3_bucket.data_lake.arn
}

output "lake_formation_permissions_principal" {
  description = <<-EOT
    Principal ARN granted SELECT + DESCRIBE on all tables in the Glue database.
    SAA-C03: Lake Formation permissions work IN ADDITION TO IAM policies.
    Both must allow access. To restrict a column: use table_with_columns block
    instead of wildcard, specifying only the columns the principal may read.
  EOT
  value       = data.aws_caller_identity.current.arn
}
