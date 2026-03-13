output "main_bucket_name" {
  description = "Main S3 bucket name"
  value       = aws_s3_bucket.main.id
}

output "main_bucket_arn" {

  description = "Main S3 bucket ARN"
  value       = aws_s3_bucket.main.arn
}

output "website_bucket_name" {

  description = "Static website bucket name"
  value       = aws_s3_bucket.website.id
}

output "website_endpoint" {

  description = "Static website URL"
  value       = aws_s3_bucket_website_configuration.website.website_endpoint
}

output "replica_bucket_name" {

  description = "Replication destination bucket name"
  value       = aws_s3_bucket.replica.id
}

output "logs_bucket_name" {

  description = "Access logs bucket name"
  value       = aws_s3_bucket.logs.id
}
