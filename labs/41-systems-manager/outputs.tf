###############################################################################
# OUTPUTS - Lab 41: AWS Systems Manager
###############################################################################

output "ssm_instance_role_arn" {
  description = "ARN of the IAM role to attach to EC2 instances for SSM management"
  value       = aws_iam_role.ssm_instance_role.arn
}

output "ssm_instance_profile_name" {
  description = "Name of the IAM instance profile to attach to EC2 instances"
  value       = aws_iam_instance_profile.ssm.name
}

output "ssm_instance_profile_arn" {
  description = "ARN of the IAM instance profile"
  value       = aws_iam_instance_profile.ssm.arn
}

output "patch_baseline_id" {
  description = "ID of the custom Amazon Linux 2 patch baseline"
  value       = aws_ssm_patch_baseline.amazon_linux2_custom.id
}

output "patch_baseline_name" {
  description = "Name of the custom patch baseline"
  value       = aws_ssm_patch_baseline.amazon_linux2_custom.name
}

output "maintenance_window_id" {
  description = "ID of the weekly patching maintenance window"
  value       = aws_ssm_maintenance_window.weekly_patch.id
}

output "maintenance_window_schedule" {
  description = "Schedule expression for the maintenance window"
  value       = aws_ssm_maintenance_window.weekly_patch.schedule
}

output "maintenance_window_target_id" {
  description = "ID of the maintenance window target (production instances)"
  value       = aws_ssm_maintenance_window_target.production_instances.id
}

output "maintenance_window_role_arn" {
  description = "ARN of the IAM role used by the Maintenance Window service"
  value       = aws_iam_role.maintenance_window.arn
}

output "cloudwatch_agent_document_name" {
  description = "Name of the custom SSM Command document for CloudWatch Agent installation"
  value       = aws_ssm_document.install_cloudwatch_agent.name
}

output "cloudwatch_agent_document_arn" {
  description = "ARN of the CloudWatch Agent installation SSM document"
  value       = aws_ssm_document.install_cloudwatch_agent.arn
}

output "state_manager_association_id" {
  description = "ID of the State Manager association that enforces CloudWatch Agent installation"
  value       = aws_ssm_association.cloudwatch_agent.association_id
}

output "state_manager_association_name" {
  description = "Name of the State Manager association"
  value       = aws_ssm_association.cloudwatch_agent.association_name
}

output "session_preferences_document_name" {
  description = "Name of the Session Manager preferences document"
  value       = aws_ssm_document.session_preferences.name
}

# --- Parameter Store outputs (added with KMS + parameter resources) ---

output "ssm_parameter_arns" {
  description = "Map of all SSM Parameter Store parameter ARNs (String, StringList, SecureString, Advanced)"
  value = {
    environment   = aws_ssm_parameter.app_config_env.arn
    log_level     = aws_ssm_parameter.app_config_log_level.arn
    allowed_cidrs = aws_ssm_parameter.allowed_cidr_blocks.arn
    db_password   = aws_ssm_parameter.db_password.arn
    api_key       = aws_ssm_parameter.api_key.arn
    temp_token    = aws_ssm_parameter.temp_token.arn
  }
}

output "kms_key_arn" {
  description = "ARN of the KMS CMK used to encrypt SecureString parameters and Session Manager logs"
  value       = aws_kms_key.ssm.arn
}

output "kms_key_alias" {
  description = "Alias of the KMS CMK for easy reference"
  value       = aws_kms_alias.ssm.name
}

output "session_logs_bucket_name" {
  description = "Name of the S3 bucket storing Session Manager session transcripts"
  value       = aws_s3_bucket.session_logs.bucket
}

output "session_logs_bucket_arn" {
  description = "ARN of the Session Manager logs S3 bucket"
  value       = aws_s3_bucket.session_logs.arn
}

output "run_command_document_name" {
  description = "Name of the custom Run Command SSM document (CollectSystemInfo)"
  value       = aws_ssm_document.custom_run_command.name
}

output "run_command_document_arn" {
  description = "ARN of the custom Run Command SSM document"
  value       = aws_ssm_document.custom_run_command.arn
}

output "automation_document_name" {
  description = "Name of the Automation runbook document (RestartApplicationWithBackup)"
  value       = aws_ssm_document.restart_app_automation.name
}
