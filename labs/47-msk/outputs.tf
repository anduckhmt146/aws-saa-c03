# =============================================================================
# OUTPUTS - Lab 47: MSK + Kinesis Data Analytics
# =============================================================================
# These outputs expose the key identifiers you need to connect producers and
# consumers to MSK and to reference the Flink application downstream.
# On the SAA-C03 exam you are NOT expected to know bootstrap broker strings
# by heart, but you should know WHEN to use TLS vs IAM endpoints.

# --- MSK Provisioned Cluster ---

output "msk_cluster_arn" {
  description = "ARN of the MSK provisioned cluster. Used in IAM policies that grant Kafka clients permission to connect via IAM authentication."
  value       = aws_msk_cluster.main.arn
}

output "msk_bootstrap_brokers_tls" {
  description = <<-EOT
    Comma-separated list of TLS broker endpoints (port 9094).
    Use these when clients authenticate with TLS mutual-auth (client certificates).
    Format: b-1.<cluster>.<id>.<region>.kafka.amazonaws.com:9094,...
  EOT
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "msk_bootstrap_brokers_iam" {
  description = <<-EOT
    Comma-separated list of IAM/SASL broker endpoints (port 9098).
    Use these when clients authenticate using AWS IAM roles/policies.
    SAA-C03 tip: IAM auth is the AWS-native, no-credential option for MSK.
  EOT
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}

# --- MSK Serverless Cluster ---

output "msk_serverless_arn" {
  description = <<-EOT
    ARN of the MSK Serverless cluster.
    SAA-C03 tip: Choose MSK Serverless when you need Kafka without managing
    broker capacity, and your workload is unpredictable or intermittent.
    MSK Serverless only supports IAM authentication.
  EOT
  value       = aws_msk_serverless_cluster.main.arn
}

# --- Kinesis Data Analytics (Apache Flink) ---

output "kinesis_analytics_app_arn" {
  description = <<-EOT
    ARN of the Kinesis Data Analytics (Flink) application.
    SAA-C03 tip: KDA Flink is the recommended choice for complex real-time
    stream processing (stateful joins, windows, anomaly detection).
    Simpler use cases can use Kinesis Firehose + Lambda instead.
  EOT
  value       = aws_kinesisanalyticsv2_application.flink_app.arn
}

output "kinesis_source_stream_arn" {
  description = "ARN of the Kinesis Data Stream that feeds the Flink application. Producers write records here; Flink reads and processes them in real time."
  value       = aws_kinesis_stream.source.arn
}
