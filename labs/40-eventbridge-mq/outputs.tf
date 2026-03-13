###############################################################################
# OUTPUTS - Lab 40: EventBridge + Amazon MQ
###############################################################################

output "custom_event_bus_arn" {
  description = "ARN of the custom EventBridge event bus"
  value       = aws_cloudwatch_event_bus.app.arn
}

output "custom_event_bus_name" {
  description = "Name of the custom EventBridge event bus"
  value       = aws_cloudwatch_event_bus.app.name
}

output "ec2_state_change_rule_arn" {
  description = "ARN of the EC2 state change EventBridge rule"
  value       = aws_cloudwatch_event_rule.ec2_state_change.arn
}

output "s3_object_created_rule_arn" {
  description = "ARN of the S3 object created EventBridge rule"
  value       = aws_cloudwatch_event_rule.s3_object_created.arn
}

output "daily_report_rule_arn" {
  description = "ARN of the scheduled daily report EventBridge rule"
  value       = aws_cloudwatch_event_rule.daily_report.arn
}

output "eventbridge_dlq_url" {
  description = "URL of the EventBridge dead-letter SQS queue"
  value       = aws_sqs_queue.eventbridge_dlq.id
}

output "ec2_events_queue_url" {
  description = "URL of the EC2 events SQS target queue"
  value       = aws_sqs_queue.ec2_events_queue.id
}

output "event_archive_arn" {
  description = "ARN of the EventBridge event archive"
  value       = aws_cloudwatch_event_archive.app_events.arn
}

output "schema_registry_arn" {
  description = "ARN of the EventBridge schema registry"
  value       = aws_schemas_registry.app.arn
}

output "mq_broker_id" {
  description = "ID of the Amazon MQ ActiveMQ broker"
  value       = aws_mq_broker.activemq.id
}

output "mq_broker_arn" {
  description = "ARN of the Amazon MQ ActiveMQ broker"
  value       = aws_mq_broker.activemq.arn
}

output "mq_broker_endpoints" {
  description = "Connection endpoints for the Amazon MQ broker (all protocols)"
  value       = aws_mq_broker.activemq.instances[*].endpoints
}

output "mq_console_url" {
  description = "ActiveMQ Web Console URL (requires VPC access)"
  value       = aws_mq_broker.activemq.instances[0].console_url
}

output "mq_configuration_id" {
  description = "ID of the Amazon MQ broker configuration"
  value       = aws_mq_configuration.activemq.id
}

output "mq_configuration_latest_revision" {
  description = "Latest revision number of the MQ broker configuration"
  value       = aws_mq_configuration.activemq.latest_revision
}

output "eventbridge_invoke_role_arn" {
  description = "ARN of the IAM role used by EventBridge to invoke targets"
  value       = aws_iam_role.eventbridge_invoke.arn
}
