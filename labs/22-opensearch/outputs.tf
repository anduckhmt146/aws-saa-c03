# =============================================================================
# OUTPUTS: Amazon OpenSearch Service Lab
# =============================================================================
#
# These outputs expose the key connection details and identifiers for the
# OpenSearch domain after a successful `terraform apply`.
#
# HOW TO USE THESE ENDPOINTS:
# - domain_endpoint:   REST API base URL for OpenSearch (index/search documents)
# - kibana_endpoint:   OpenSearch Dashboards UI (formerly Kibana) — browser access
#
# EXAMPLE CURL COMMAND (index a document):
#   curl -X PUT "https://<domain_endpoint>/my-index/_doc/1" \
#     -H "Content-Type: application/json" \
#     -d '{"title": "Test document", "timestamp": "2024-01-01T00:00:00Z"}'
#
# EXAMPLE CURL COMMAND (search):
#   curl -X GET "https://<domain_endpoint>/my-index/_search?q=title:Test"
# =============================================================================

# -----------------------------------------------------------------------------
# DOMAIN IDENTITY
# -----------------------------------------------------------------------------

output "domain_id" {
  description = "The unique identifier for the OpenSearch domain (account-id/domain-name format)"
  value       = aws_opensearch_domain.opensearch_lab.domain_id
}

output "domain_name" {
  description = "The name of the OpenSearch domain"
  value       = aws_opensearch_domain.opensearch_lab.domain_name
}

output "domain_arn" {
  description = "ARN of the OpenSearch domain — use in IAM policies to grant access to this specific domain"
  value       = aws_opensearch_domain.opensearch_lab.arn
}

# -----------------------------------------------------------------------------
# CONNECTION ENDPOINTS
# -----------------------------------------------------------------------------

# DOMAIN ENDPOINT (REST API)
# The primary endpoint for all OpenSearch API operations:
# - Indexing documents (PUT/POST /<index>/_doc/<id>)
# - Searching (GET /<index>/_search)
# - Cluster/index management (GET /_cluster/health)
#
# EXAM NOTE: This endpoint is used by:
# - Application code (OpenSearch SDK, REST calls)
# - Kinesis Data Firehose (as the OpenSearch destination)
# - Lambda functions shipping logs to OpenSearch
# - AWS Glue and other services writing to OpenSearch
output "domain_endpoint" {
  description = <<-EOT
    OpenSearch domain REST API endpoint (HTTPS).
    Use this URL as the base for all OpenSearch API calls.
    Format: https://<endpoint>/<index>/_search
    NOTE: This is a public endpoint (no VPC in this lab config).
    In production, use VPC access and reference the VPC endpoint instead.
  EOT
  value       = "https://${aws_opensearch_domain.opensearch_lab.endpoint}"
}

# KIBANA / OPENSEARCH DASHBOARDS ENDPOINT
# OpenSearch Dashboards is the visualization layer — a fork of Kibana.
# Use this URL to:
# - Create visualizations and dashboards
# - Explore and analyze indexed data interactively
# - Manage index patterns, users, and roles (when FGAC is enabled)
# - Monitor cluster health via the built-in monitoring plugin
#
# EXAM NOTE: "Kibana" and "OpenSearch Dashboards" are used interchangeably
# in exam questions. Both refer to the same visualization tool concept.
# If you see "Kibana" in a question about OpenSearch Service, it means
# OpenSearch Dashboards.
#
# ACCESS: The Dashboards URL requires authentication.
# - With FGAC + internal user DB: use master_user_name/master_user_password
# - With FGAC + IAM: use AWS credentials (Signature V4 signed requests)
# - Without FGAC: controlled by the domain access policy
output "kibana_endpoint" {
  description = <<-EOT
    OpenSearch Dashboards (formerly Kibana) endpoint — open in a browser.
    Login with the master_user credentials configured in advanced_security_options.
    URL format: https://<endpoint>/_dashboards/
  EOT
  value       = "https://${aws_opensearch_domain.opensearch_lab.kibana_endpoint}"
}

# -----------------------------------------------------------------------------
# CLUSTER CONFIGURATION DETAILS
# -----------------------------------------------------------------------------

output "engine_version" {
  description = "OpenSearch engine version deployed"
  value       = aws_opensearch_domain.opensearch_lab.engine_version
}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG GROUP ARNS
# -----------------------------------------------------------------------------
# These ARNs are needed when configuring other services to write to these log
# groups, or when setting up CloudWatch Logs Insights queries.

output "log_group_index_slow" {
  description = "CloudWatch Log Group ARN for OpenSearch index slow logs"
  value       = aws_cloudwatch_log_group.opensearch_index_slow.arn
}

output "log_group_search_slow" {
  description = "CloudWatch Log Group ARN for OpenSearch search slow logs"
  value       = aws_cloudwatch_log_group.opensearch_search_slow.arn
}

output "log_group_application" {
  description = "CloudWatch Log Group ARN for OpenSearch application/error logs"
  value       = aws_cloudwatch_log_group.opensearch_application.arn
}

output "log_group_audit" {
  description = "CloudWatch Log Group ARN for OpenSearch audit logs (compliance)"
  value       = aws_cloudwatch_log_group.opensearch_audit.arn
}

# -----------------------------------------------------------------------------
# EXAM STUDY NOTES (as output map)
# -----------------------------------------------------------------------------

output "exam_notes" {
  description = "Key SAA-C03 facts about OpenSearch Service"
  value = {
    formerly_known_as     = "Amazon Elasticsearch Service (rebranded 2021)"
    domain_means          = "'Domain' = the entire OpenSearch cluster (not a DNS domain)"
    dedicated_masters     = "Always use 3 or 5 dedicated masters — odd number prevents split-brain"
    ultrawarm_use_case    = "S3-backed warm tier for cost-effective storage of older, rarely queried data"
    encryption_checklist  = "3 layers: encrypt_at_rest + node_to_node + enforce_https"
    fgac_use_cases        = "Field-level security, document-level security, multi-tenant Dashboards"
    exam_pattern          = "CloudWatch Logs → Subscription Filter → Lambda → OpenSearch"
    alt_ingestion_pattern = "Kinesis Data Firehose → OpenSearch (no Lambda needed, higher throughput)"
    vpc_recommendation    = "Use VPC access for production — public endpoint only for dev/test"
    kibana_alias          = "'Kibana' in exam questions = OpenSearch Dashboards"
    not_serverless        = "Standard OpenSearch requires instance provisioning; OpenSearch Serverless is separate"
    scaling               = "Scale horizontally by adding data nodes; scale vertically by changing instance type"
  }
}
