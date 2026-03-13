# =============================================================================
# LAB 33: OUTPUTS - SECRETS MANAGER, SSM PARAMETER STORE, ACM
# =============================================================================

# -----------------------------------------------------------------------------
# SECRETS MANAGER OUTPUTS
# -----------------------------------------------------------------------------

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the RDS master password"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "db_secret_name" {
  description = "Name of the Secrets Manager secret (use in application config)"
  value       = aws_secretsmanager_secret.db_password.name
}

output "api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the external API key"
  value       = aws_secretsmanager_secret.api_key.arn
}

output "rotation_lambda_arn" {
  description = "ARN of the Lambda function handling secret rotation"
  value       = aws_lambda_function.rotation.arn
}

# -----------------------------------------------------------------------------
# SSM PARAMETER STORE OUTPUTS
# -----------------------------------------------------------------------------

output "ssm_parameter_environment_name" {
  description = "SSM Parameter Store name for app environment (String)"
  value       = aws_ssm_parameter.app_environment.name
}

output "ssm_parameter_regions_name" {
  description = "SSM Parameter Store name for allowed regions (StringList)"
  value       = aws_ssm_parameter.allowed_regions.name
}

output "ssm_parameter_db_connection_name" {
  description = "SSM Parameter Store name for DB connection string (SecureString)"
  value       = aws_ssm_parameter.db_connection_string.name
}

output "ssm_parameter_db_connection_arn" {
  description = "ARN of the SecureString SSM parameter (use for IAM policy resource)"
  value       = aws_ssm_parameter.db_connection_string.arn
}

# -----------------------------------------------------------------------------
# KMS KEY OUTPUTS
# -----------------------------------------------------------------------------

output "secrets_kms_key_arn" {
  description = "ARN of KMS CMK used by Secrets Manager"
  value       = aws_kms_key.secrets.arn
}

output "secrets_kms_key_id" {
  description = "ID of KMS CMK used by Secrets Manager"
  value       = aws_kms_key.secrets.key_id
}

output "ssm_kms_key_arn" {
  description = "ARN of KMS CMK used by SSM Parameter Store SecureString"
  value       = aws_kms_key.ssm.arn
}

# -----------------------------------------------------------------------------
# ACM CERTIFICATE OUTPUTS
# -----------------------------------------------------------------------------

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate - use this in ALB/CloudFront/API GW config"
  value       = aws_acm_certificate.main.arn
}

output "acm_certificate_status" {
  description = "Current status of the ACM certificate (PENDING_VALIDATION, ISSUED, etc.)"
  value       = aws_acm_certificate.main.status
}

output "acm_certificate_domain_validation_options" {
  description = "DNS records that must exist in Route 53 to validate the certificate"
  value       = aws_acm_certificate.main.domain_validation_options
}

# -----------------------------------------------------------------------------
# SAA-C03 EXAM SUMMARY (in outputs for quick reference)
# -----------------------------------------------------------------------------
# Run: terraform output exam_tips
output "exam_tips" {
  description = "SAA-C03 key decision points for this lab"
  value       = <<-EOT
    SECRETS MANAGER vs SSM PARAMETER STORE:
      Auto-rotation needed?      → Secrets Manager ($0.40/secret/month)
      Config or no rotation?     → Parameter Store (free Standard tier)
      Multi-region replication?  → Secrets Manager only
      >4KB secret value?         → Parameter Store Advanced ($0.05/month)

    ACM:
      Free SSL for ALB/CloudFront/API GW?  → ACM public cert (free)
      Need cert on EC2 directly?           → Cannot use ACM (no private key export)
      CloudFront cert region?              → MUST create in us-east-1
      Auto-renewal?                        → DNS validation (recommended)
  EOT
}
