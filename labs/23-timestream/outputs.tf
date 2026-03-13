# =============================================================================
# Outputs — Timestream Lab 23
# =============================================================================

output "timestream_database_name" {
  description = "Name of the Timestream database"
  value       = aws_timestreamwrite_database.iot_telemetry.database_name
}

output "timestream_database_arn" {
  description = "ARN of the Timestream database"
  value       = aws_timestreamwrite_database.iot_telemetry.arn
}

output "sensor_readings_table_arn" {
  description = "ARN of the sensor_readings table"
  value       = aws_timestreamwrite_table.sensor_readings.arn
}

output "app_metrics_table_arn" {
  description = "ARN of the app_metrics table"
  value       = aws_timestreamwrite_table.app_metrics.arn
}

output "timestream_writer_role_arn" {
  description = "ARN of the IAM role for writing to Timestream (attach to Lambda or IoT Rule)"
  value       = aws_iam_role.timestream_writer.arn
}

# =============================================================================
# STUDY NOTES — what to remember from this lab
# =============================================================================
#
# 1. Timestream = serverless time-series DB. No cluster management.
#
# 2. Two storage tiers:
#      - Memory store (hot):    hours retention, fast, expensive
#      - Magnetic store (cold): days/years retention, slow, cheap
#
# 3. Data automatically flows: memory → magnetic → deleted
#
# 4. Enable magnetic store writes for late-arriving / out-of-order data.
#
# 5. DescribeEndpoints permission is REQUIRED in IAM policies.
#
# 6. SAA-C03 trigger words:
#      "IoT sensor data"       → Timestream
#      "time-series metrics"   → Timestream
#      "time functions built-in" → Timestream
#      "general-purpose NoSQL" → DynamoDB
#
# 7. Integrations: Kinesis → Timestream, IoT Core → Timestream, Grafana UI
# =============================================================================
