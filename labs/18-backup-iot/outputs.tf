output "iot_thing_name" { value = aws_iot_thing.sensor.name }
output "iot_policy_name" { value = aws_iot_policy.lab.name }
output "iot_certificate_arn" { value = aws_iot_certificate.sensor.arn }
output "iot_rule_name" { value = aws_iot_topic_rule.lab.name }
output "scheduler_hourly_arn" { value = aws_scheduler_schedule.hourly_report.arn }
output "directory_id" { value = aws_directory_service_directory.lab.id }
output "iot_alerts_topic_arn" { value = aws_sns_topic.iot_alerts.arn }
