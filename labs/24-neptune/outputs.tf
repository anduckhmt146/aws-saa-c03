# =============================================================================
# Outputs — Neptune Lab 24
# =============================================================================

# CLUSTER ENDPOINT (writer)
# Always resolves to the current PRIMARY instance.
# Use this endpoint for ALL write operations:
#   - Adding vertices (nodes)
#   - Adding edges (relationships)
#   - Updating or deleting graph elements
# After failover, this DNS name automatically redirects to the new primary.
output "neptune_cluster_endpoint" {
  description = "Neptune cluster writer endpoint — use for all write operations"
  value       = aws_neptune_cluster.main.endpoint
}

# READER ENDPOINT
# Load-balances queries across all available READ REPLICAS.
# Use this endpoint for READ-HEAVY graph traversals:
#   - Social graph queries (friends of friends)
#   - Fraud detection traversals
#   - Recommendation engine queries
# Automatically removes failed replicas from the rotation.
output "neptune_reader_endpoint" {
  description = "Neptune cluster reader endpoint — load-balanced across all read replicas"
  value       = aws_neptune_cluster.main.reader_endpoint
}

output "neptune_cluster_port" {
  description = "Neptune port (8182) — remember this for the SAA-C03 exam"
  value       = aws_neptune_cluster.main.port
}

output "neptune_cluster_id" {
  description = "Neptune cluster identifier"
  value       = aws_neptune_cluster.main.cluster_identifier
}

output "neptune_writer_instance_id" {
  description = "Neptune primary (writer) instance identifier"
  value       = aws_neptune_cluster_instance.writer.identifier
}

output "neptune_reader_instance_id" {
  description = "Neptune read replica instance identifier"
  value       = aws_neptune_cluster_instance.reader.identifier
}

output "neptune_s3_loader_role_arn" {
  description = "IAM role ARN for Neptune bulk loading from S3"
  value       = aws_iam_role.neptune_s3_loader.arn
}

output "vpc_id" {
  description = "VPC ID containing the Neptune cluster"
  value       = aws_vpc.neptune.id
}

# =============================================================================
# STUDY NOTES — what to remember from this lab
# =============================================================================
#
# 1. Neptune = managed graph DB. Vertices + Edges + Properties.
#
# 2. Three query languages:
#      - Gremlin    → property graph, traversal syntax
#      - SPARQL     → RDF model, semantic web / knowledge graphs
#      - openCypher → property graph, pattern-matching syntax (like Neo4j)
#
# 3. Architecture:
#      - 1 primary + up to 15 read replicas
#      - Shared cluster storage (like Aurora)
#      - Two endpoints: writer (cluster) and reader (load-balanced)
#      - Multi-AZ failover ~30 seconds
#
# 4. Storage: auto-grows up to 128 TB, 6-way replication across 3 AZs.
#
# 5. Port: 8182 (both Gremlin WebSocket and SPARQL/openCypher HTTP)
#
# 6. IAM role required for bulk loading from S3 (uses rds.amazonaws.com principal)
#
# 7. Neptune Streams: ordered log of graph changes (like DynamoDB Streams)
#
# 8. Neptune Analytics: in-memory, for large-scale graph algorithms + vector search
#
# 9. SAA-C03 trigger words:
#      "social network friends of friends" → Neptune
#      "fraud detection related accounts"  → Neptune
#      "knowledge graph"                   → Neptune
#      "recommendation engine graph"       → Neptune
# =============================================================================
