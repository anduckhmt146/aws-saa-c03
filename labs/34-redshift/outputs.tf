# =============================================================================
# LAB 34: OUTPUTS — AMAZON REDSHIFT
# =============================================================================

# ===========================================================================================
# SECTION 1: PROVISIONED CLUSTER OUTPUTS
# ===========================================================================================

# SAA-C03: cluster_endpoint is the primary connection string for SQL clients.
# Format: <cluster-identifier>.<random-id>.<region>.redshift.amazonaws.com:5439
# Use this in JDBC/ODBC connection strings and application configuration.
output "cluster_endpoint" {
  description = "Redshift cluster connection endpoint (hostname:port) — use in SQL client config"
  value       = aws_redshift_cluster.main.endpoint
}

# SAA-C03: cluster_id (cluster_identifier) is used in AWS CLI/SDK calls,
# snapshot associations, scheduled actions, and IAM resource ARNs.
output "cluster_id" {
  description = "Redshift cluster identifier — used in AWS CLI, scheduled actions, and snapshot associations"
  value       = aws_redshift_cluster.main.cluster_identifier
}

output "cluster_arn" {
  description = "Full ARN of the Redshift cluster — use in IAM policy Resource fields"
  value       = aws_redshift_cluster.main.arn
}

output "cluster_database_name" {
  description = "Name of the default database in the cluster"
  value       = aws_redshift_cluster.main.database_name
}

output "cluster_port" {
  description = "Redshift connection port — always 5439 (NOT 5432 like standard PostgreSQL)"
  value       = aws_redshift_cluster.main.port
}

output "cluster_node_type" {
  description = "Node type of the provisioned cluster (dc2.large for this lab)"
  value       = aws_redshift_cluster.main.node_type
}

# SAA-C03: JDBC connection string ready for SQL clients like DBeaver, SQL Workbench/J
output "jdbc_connection_string" {
  description = "JDBC connection string for SQL client tools (DBeaver, SQL Workbench/J, etc.)"
  value       = "jdbc:redshift://${aws_redshift_cluster.main.endpoint}/${aws_redshift_cluster.main.database_name}"
}

# ===========================================================================================
# SECTION 2: SERVERLESS OUTPUTS
# ===========================================================================================

# SAA-C03: serverless_namespace_arn is the unique identifier for the namespace.
# Reference this ARN when granting cross-account access or in resource policies.
output "serverless_namespace_arn" {
  description = "ARN of the Redshift Serverless namespace (storage + identity layer)"
  value       = aws_redshiftserverless_namespace.main.arn
}

output "serverless_namespace_id" {
  description = "ID of the Redshift Serverless namespace"
  value       = aws_redshiftserverless_namespace.main.id
}

# SAA-C03: serverless_workgroup_endpoint is the connection string for Serverless.
# Uses the same port 5439 and same SQL interface as a provisioned cluster.
# Clients connecting to Serverless do not need to change their SQL — it is
# fully compatible with the same JDBC/ODBC drivers.
output "serverless_workgroup_endpoint" {
  description = "Redshift Serverless workgroup connection endpoint — same port 5439 as provisioned"
  value       = aws_redshiftserverless_workgroup.main.endpoint
}

output "serverless_workgroup_arn" {
  description = "ARN of the Redshift Serverless workgroup (compute layer)"
  value       = aws_redshiftserverless_workgroup.main.arn
}

# ===========================================================================================
# SECTION 3: SECURITY AND NETWORKING OUTPUTS
# ===========================================================================================

output "redshift_security_group_id" {
  description = "Security group ID for the Redshift cluster (allows port 5439 from VPC CIDR)"
  value       = aws_security_group.redshift.id
}

output "redshift_subnet_group_name" {
  description = "Name of the Redshift subnet group (spans all default VPC subnets)"
  value       = aws_redshift_subnet_group.main.name
}

output "redshift_kms_key_arn" {
  description = "ARN of the KMS CMK used for Redshift at-rest encryption"
  value       = aws_kms_key.redshift.arn
}

output "redshift_iam_role_arn" {
  description = "ARN of the IAM role attached to Redshift for S3 COPY/UNLOAD and Spectrum"
  value       = aws_iam_role.redshift_s3.arn
}

# ===========================================================================================
# SECTION 4: SNAPSHOT SCHEDULE OUTPUTS
# ===========================================================================================

output "snapshot_schedule_identifier" {
  description = "Identifier of the daily snapshot schedule (midnight UTC cron)"
  value       = aws_redshift_snapshot_schedule.daily.id
}

# ===========================================================================================
# SECTION 5: SAA-C03 EXAM QUICK REFERENCE
# ===========================================================================================

output "exam_tips" {
  description = "SAA-C03 key decision points for Redshift — run: terraform output exam_tips"
  value       = <<-EOT
    REDSHIFT FUNDAMENTALS:
      OLAP analytics, NOT OLTP transactions → use RDS/Aurora for OLTP
      Port 5439 (not PostgreSQL's 5432) — always on SG ingress rules
      MPP: leader node coordinates; compute nodes run queries in parallel
      Columnar storage: fast aggregations, bad for row-by-row updates

    NODE TYPE SELECTION:
      RA3  → new workloads; storage scales independently from compute (managed S3)
      DC2  → fixed SSD, < 1 TB data, latency-sensitive, dev/test (this lab)
      DS2  → legacy HDD; migrate to RA3

    DISTRIBUTION STYLES (joins + data movement):
      KEY  → distribute on join column; co-locates rows → zero data movement JOIN
      ALL  → small dimension tables; full copy on every slice → always local
      EVEN → staging/temp tables; no join requirement; round-robin
      AUTO → let Redshift decide (EVEN for large, ALL for small)

    SORT KEYS (zone map block skipping):
      Compound    → fixed query patterns; filter on leading sort column
      Interleaved → ad-hoc queries; any subset of sort columns equally weighted

    SPECTRUM (query S3 without loading):
      External schema → Glue Data Catalog → external tables on S3
      Cost: $5/TB scanned → minimize with Parquet format + date partitioning
      Combine cluster (hot) + Spectrum (cold) in a single SQL query

    SERVERLESS vs PROVISIONED:
      Serverless  → sporadic queries, no idle cost, auto-scale, dev/test
      Provisioned → sustained workload, Reserved Instances, WLM control

    SECURITY:
      Enhanced VPC Routing → S3/Spectrum traffic through VPC (not internet)
      Encryption at rest → must enable at creation (cannot add in-place)
      require_ssl parameter → enforce TLS for all client connections

    SNAPSHOTS / DR:
      Automated: every 8h or 5 GB change; 1-35 day retention
      Manual: indefinite; cross-region copy for multi-region DR
      Snapshot schedule: cron/rate expression for custom timing

    WLM (Workload Management):
      Automatic WLM → AWS manages memory/concurrency (recommended default)
      Manual WLM → define queues, memory %, concurrency, query_group routing
      Concurrency Scaling → burst capacity; first 1h/day FREE
  EOT
}
