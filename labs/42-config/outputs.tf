###############################################################################
# OUTPUTS - Lab 42: AWS Config
###############################################################################

output "config_recorder_name" {
  description = "Name of the Config configuration recorder that captures all resource changes"
  value       = aws_config_configuration_recorder.main.name
}

output "delivery_channel_name" {
  description = "Name of the Config delivery channel (sends snapshots to S3 and notifications to SNS)"
  value       = aws_config_delivery_channel.main.name
}

output "config_delivery_bucket" {
  description = "S3 bucket receiving Config configuration history files and snapshots"
  value       = aws_s3_bucket.config_delivery.bucket
}

output "config_notifications_topic_arn" {
  description = "SNS topic ARN for Config compliance change notifications"
  value       = aws_sns_topic.config_notifications.arn
}

output "config_service_role_arn" {
  description = "ARN of the IAM role used by AWS Config to read resource configurations"
  value       = aws_iam_role.config.arn
}

# config_rules_count: use length() on a list of the managed rule names
# SAA-C03 note: knowing how many rules are deployed helps scope compliance coverage
output "config_rules_count" {
  description = "Total number of AWS Config rules deployed in this lab (managed + custom)"
  value = length([
    aws_config_config_rule.s3_public_read_prohibited.name,
    aws_config_config_rule.required_tags.name,
    aws_config_config_rule.ec2_no_public_ip.name,
    aws_config_config_rule.encrypted_volumes.name,
    aws_config_config_rule.iam_root_access_key.name,
    aws_config_config_rule.mfa_iam_console.name,
    aws_config_config_rule.restricted_ssh.name,
    aws_config_config_rule.custom_ec2_required_tag.name,
  ])
}

output "config_rule_names" {
  description = "Names of all Config rules deployed, for reference and cross-lab use"
  value = [
    aws_config_config_rule.s3_public_read_prohibited.name,
    aws_config_config_rule.required_tags.name,
    aws_config_config_rule.ec2_no_public_ip.name,
    aws_config_config_rule.encrypted_volumes.name,
    aws_config_config_rule.iam_root_access_key.name,
    aws_config_config_rule.mfa_iam_console.name,
    aws_config_config_rule.restricted_ssh.name,
    aws_config_config_rule.custom_ec2_required_tag.name,
  ]
}

output "conformance_pack_name" {
  description = "Name of the deployed conformance pack (bundles multiple rules as one deployable unit)"
  value       = aws_config_conformance_pack.operational_best_practices.name
}

output "aggregator_arn" {
  description = "ARN of the Config aggregator providing multi-account/region compliance visibility"
  value       = aws_config_configuration_aggregator.org_aggregator.arn
}

output "custom_rule_lambda_arn" {
  description = "ARN of the Lambda function backing the custom Config rule"
  value       = aws_lambda_function.custom_config_rule.arn
}
