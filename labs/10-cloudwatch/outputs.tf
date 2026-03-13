output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "log_group_app" { value = aws_cloudwatch_log_group.app.name }
output "dashboard_name" { value = aws_cloudwatch_dashboard.lab.dashboard_name }
output "ssm_db_password_arn" { value = aws_ssm_parameter.db_password.arn }
