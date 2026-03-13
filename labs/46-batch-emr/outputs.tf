###############################################################################
# OUTPUTS - Lab 46: AWS Batch & EMR
###############################################################################

output "batch_compute_env_arn" {
  description = "ARN of the Spot Batch compute environment - reference this when building job queues or monitoring Spot capacity"
  value       = aws_batch_compute_environment.spot.arn
}

output "batch_job_queue_arn" {
  description = "ARN of the main Batch job queue (Spot-first, On-Demand fallback, priority=10) - submit standard jobs here"
  value       = aws_batch_job_queue.main.arn
}

output "batch_job_definition_arn" {
  description = "ARN of the data processor Batch job definition including revision number - use this ARN when submitting jobs"
  value       = aws_batch_job_definition.data_processor.arn
}

output "emr_cluster_id" {
  description = "EMR cluster ID (j-XXXXXXXXXXXXX) - use with aws emr add-steps and for CloudWatch log path lookups"
  value       = aws_emr_cluster.main.id
}

output "emr_cluster_master_dns" {
  description = "Public DNS of the EMR master node - SSH to this host for interactive access (restricted to VPC CIDR)"
  value       = aws_emr_cluster.main.master_public_dns
}

output "emr_serverless_app_id" {
  description = "EMR Serverless application ID - pass this when submitting job runs: aws emr-serverless start-job-run --application-id <id>"
  value       = aws_emrserverless_application.spark.id
}

output "emr_logs_bucket" {
  description = "S3 bucket storing EMR cluster logs - browse s3://<bucket>/emr-logs/<cluster-id>/ to debug failed steps"
  value       = aws_s3_bucket.emr_logs.bucket
}

output "emr_data_bucket" {
  description = "S3 bucket for EMR input data and job output - persists after cluster termination (EMRFS storage pattern)"
  value       = aws_s3_bucket.emr_data.bucket
}

output "batch_on_demand_compute_env_arn" {
  description = "ARN of the On-Demand Batch compute environment - used as fallback in job queues when Spot capacity is unavailable"
  value       = aws_batch_compute_environment.on_demand.arn
}

output "batch_high_priority_queue_arn" {
  description = "ARN of the high-priority Batch job queue (priority=100, On-Demand first) - submit time-sensitive jobs here"
  value       = aws_batch_job_queue.high_priority.arn
}
