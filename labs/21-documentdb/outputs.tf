# =============================================================================
# OUTPUTS: Amazon DocumentDB Lab
# =============================================================================
#
# Outputs expose key values after a successful `terraform apply`.
# These are the values your application needs to connect to DocumentDB.
#
# ENDPOINT QUICK REFERENCE:
# - cluster_endpoint  → use for WRITES (always points to the primary)
# - reader_endpoint   → use for READS (load-balances across all replicas)
# - port              → always 27017 for DocumentDB (MongoDB-compatible)
#
# CONNECTION STRING FORMAT (MongoDB driver):
#   mongodb://user:pass@<cluster_endpoint>:27017/?tls=true&replicaSet=rs0
#   mongodb://user:pass@<reader_endpoint>:27017/?tls=true&readPreference=secondary
# =============================================================================

# -----------------------------------------------------------------------------
# CLUSTER IDENTITY
# -----------------------------------------------------------------------------

output "cluster_id" {
  description = "The unique identifier of the DocumentDB cluster"
  value       = aws_docdb_cluster.docdb_cluster.id
}

output "cluster_arn" {
  description = "ARN of the DocumentDB cluster — use in IAM policies and resource-based policies"
  value       = aws_docdb_cluster.docdb_cluster.arn
}

# -----------------------------------------------------------------------------
# CONNECTION ENDPOINTS
# -----------------------------------------------------------------------------

# CLUSTER ENDPOINT (Writer)
# Always routes to the PRIMARY instance.
# Use this endpoint for:
#   - All WRITE operations (insert, update, delete)
#   - Reads that must reflect the very latest committed writes
#     (i.e., "read your own writes" consistency)
#
# SAA-C03 EXAM NOTE: After a failover, the cluster endpoint automatically
# points to the newly promoted primary — your application connection string
# does NOT need to change. This is the key benefit of the cluster endpoint.
output "cluster_endpoint" {
  description = <<-EOT
    Cluster (writer) endpoint — routes to the PRIMARY instance.
    Use for ALL write operations and reads requiring strong consistency.
    Automatically updates to the new primary after a failover event.
  EOT
  value       = aws_docdb_cluster.docdb_cluster.endpoint
}

# READER ENDPOINT (Read Replicas)
# Load-balances connections across all available READ REPLICA instances.
# Use this endpoint for:
#   - Read-heavy workloads (analytics queries, reporting)
#   - Offloading read traffic from the primary
#
# EXAM NOTE: The reader endpoint does NOT guarantee read-after-write
# consistency. Since all instances share the same storage volume, however,
# DocumentDB replicas have minimal replication lag (effectively zero for
# storage-level reads). Still, use the cluster endpoint when you need to
# read data you JUST wrote in the same request.
output "reader_endpoint" {
  description = <<-EOT
    Reader endpoint — load-balances across all READ REPLICA instances.
    Use for read-heavy workloads to scale read throughput horizontally.
    Does NOT route to the primary; for writes always use cluster_endpoint.
  EOT
  value       = aws_docdb_cluster.docdb_cluster.reader_endpoint
}

# PORT
# DocumentDB uses port 27017 — the same as MongoDB.
# Your security group must allow inbound TCP on this port from your app tier.
output "port" {
  description = "DocumentDB port (27017 — MongoDB-compatible default)"
  value       = aws_docdb_cluster.docdb_cluster.port
}

# -----------------------------------------------------------------------------
# INDIVIDUAL INSTANCE ENDPOINTS
# -----------------------------------------------------------------------------
# Each instance has its own direct endpoint. Normally you use the cluster
# or reader endpoint and let AWS handle routing. Individual endpoints are
# useful for:
# - Pinning specific workloads to a specific replica
# - Direct access for diagnostics or admin operations
# - Testing failover behavior by connecting directly

output "primary_instance_endpoint" {
  description = "Direct endpoint for the primary (writer) instance"
  value       = aws_docdb_cluster_instance.primary.endpoint
}

output "replica_1_endpoint" {
  description = "Direct endpoint for read replica 1 (AZ-b)"
  value       = aws_docdb_cluster_instance.replica_1.endpoint
}

output "replica_2_endpoint" {
  description = "Direct endpoint for read replica 2 (AZ-c)"
  value       = aws_docdb_cluster_instance.replica_2.endpoint
}

# -----------------------------------------------------------------------------
# SECURITY & NETWORKING
# -----------------------------------------------------------------------------

output "security_group_id" {
  description = "Security group ID attached to the DocumentDB cluster — reference this in app-tier SG ingress rules"
  value       = aws_security_group.docdb_sg.id
}

output "subnet_group_name" {
  description = "DocumentDB subnet group name — spans 3 private subnets across 3 AZs"
  value       = aws_docdb_subnet_group.docdb_subnet_group.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for DocumentDB encryption at rest"
  value       = aws_kms_key.docdb_kms.arn
}

# -----------------------------------------------------------------------------
# EXAM STUDY NOTES (as output descriptions)
# -----------------------------------------------------------------------------

output "exam_notes" {
  description = "Key SAA-C03 facts about DocumentDB"
  value = {
    storage_model         = "Shared distributed storage, auto-grows in 10 GB increments, max 128 TB"
    replication           = "6 copies across 3 AZs — always, regardless of instance count"
    failover_time         = "~30 seconds — promotes replica to primary automatically"
    not_global            = "DocumentDB is REGIONAL only — no Global Tables equivalent"
    mongodb_compatible    = "Supports MongoDB 3.6, 4.0, 5.0 wire protocol"
    encryption_at_rest    = "Must be enabled at creation — cannot change on existing cluster"
    encryption_in_transit = "Controlled via cluster parameter group 'tls' parameter"
    max_replicas          = "Up to 15 read replicas per cluster"
  }
}
