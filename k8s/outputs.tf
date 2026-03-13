###############################################################################
# LAB 50 Outputs — Kubernetes Microservices + Helm
# NOTE: Primary outputs are defined inline in main.tf (ingress_nginx_lb_hostname,
# grafana_url, api_url, helm_status_commands, kubectl_useful_commands).
# This file adds supplemental SAA-C03 study outputs.
###############################################################################

output "user_service_iam_role_arn" {
  description = <<-EOT
    ARN of the IAM role for the user-service pod (IRSA — IAM Roles for Service Accounts).
    SAA-C03: IRSA lets individual pods assume an IAM role without node-level credentials.
    Pattern: EKS OIDC provider → ServiceAccount annotation → IAM role trust policy.
    Exam: "pod needs S3 access without sharing node role" = IRSA.
  EOT
  value       = aws_iam_role.user_service.arn
}

output "user_events_sqs_url" {
  description = <<-EOT
    SQS queue URL for user events (async microservice communication).
    SAA-C03: SQS decouples microservices — producer writes to queue, consumer polls independently.
    Dead-letter queue (DLQ) configured to capture failed messages after maxReceiveCount retries.
  EOT
  value       = aws_sqs_queue.user_events.url
}

output "user_profiles_bucket" {
  description = <<-EOT
    S3 bucket for user profile data accessed by the user-service via IRSA.
    SAA-C03: Pods access S3 via the IRSA role (no access keys in environment variables).
    Best practice: use presigned URLs for user-facing file uploads/downloads.
  EOT
  value       = aws_s3_bucket.user_profiles.bucket
}
