output "monthly_budget_name" {
  value = aws_budgets_budget.monthly_cost.name
}
output "ec2_budget_name" {
  value = aws_budgets_budget.monthly_ec2_usage.name
}
output "anomaly_monitor_arn" {
  value = aws_ce_anomaly_monitor.service_monitor.arn
}
output "anomaly_subscription_arn" {
  value = aws_ce_anomaly_subscription.alert_on_anomaly.arn
}
