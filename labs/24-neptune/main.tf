# =============================================================================
# AWS SAA-C03 Lab 24: Amazon Neptune
# =============================================================================
#
# WHAT IS NEPTUNE?
# Amazon Neptune is a fully managed graph database optimized for storing and
# querying highly connected data — data where the RELATIONSHIPS between items
# are as important as the items themselves.
#
# GRAPH DATABASE CONCEPTS:
#   - Vertices (nodes): entities — Person, Product, Transaction, Account
#   - Edges:            relationships — KNOWS, BOUGHT, TRANSFERRED_TO
#   - Properties:       attributes on vertices and edges — name="Alice", amount=500
#
# THE GRAPH ADVANTAGE over relational databases:
# In SQL, "find all friends of friends of Alice" requires multiple self-JOINs.
# In a graph DB, you simply traverse edges — this is O(edges_traversed), not
# O(table_size). Graphs excel when queries involve variable-depth traversals.
#
# QUERY LANGUAGES SUPPORTED (know all three for the exam):
#
#   1. GREMLIN (Apache TinkerPop)
#      - Property graph model
#      - Traversal-based: g.V().has('name','Alice').out('KNOWS').out('KNOWS')
#      - Most common in Neptune, integrates with many graph tools
#
#   2. SPARQL (W3C standard)
#      - RDF (Resource Description Framework) model
#      - Triple-based: subject → predicate → object
#      - Used for knowledge graphs and semantic web applications
#      - Example: SELECT ?friend WHERE { :Alice :knows ?friend }
#
#   3. openCypher
#      - Property graph model (like Gremlin, different syntax)
#      - Pattern-matching syntax: MATCH (a:Person)-[:KNOWS]->(b) RETURN b
#      - Same language used by Neo4j (popular open-source graph DB)
#      - Easier to migrate from Neo4j to Neptune using openCypher
#
# SAA-C03 KEY USE CASES — memorize these trigger phrases:
#
#   "Social network — who are the friends of friends?"
#     → Neptune with Gremlin or openCypher traversal
#
#   "Fraud detection — find accounts connected to known fraudulent accounts"
#     → Neptune: traverse transaction graph to find suspicious patterns
#
#   "Knowledge graph — represent entities and their relationships"
#     → Neptune with SPARQL (RDF model) or Gremlin
#
#   "Recommendation engine — what did users similar to me buy?"
#     → Neptune: traverse user→product edges for collaborative filtering
#
#   "Identity resolution — link customer records across systems"
#     → Neptune: represent each record as a node, link shared attributes as edges
#
# WHEN THE EXAM SAYS "graph database" — the answer is Neptune.
# =============================================================================

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# VPC AND NETWORKING
# =============================================================================
#
# Neptune is a VPC-only service — it cannot be accessed from the public
# internet. You MUST place it inside a VPC and access it via:
#   - Resources in the same VPC
#   - VPC peering / Transit Gateway from another VPC
#   - AWS Client VPN or Site-to-Site VPN
#
# Neptune port: 8182 (both HTTP REST API and WebSocket connections)
# This is the SAA-C03 exam port to remember for Neptune.
# Compare: RDS MySQL=3306, PostgreSQL=5432, Redis=6379, Neptune=8182
# =============================================================================

resource "aws_vpc" "neptune" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "neptune-lab-vpc"
    Lab  = "24-neptune"
  }
}

# Private subnet in AZ-a
# Neptune instances live in private subnets — they should never be
# directly reachable from the internet.
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.neptune.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "neptune-private-a"
    Lab  = "24-neptune"
  }
}

# Private subnet in AZ-b
# Neptune subnet group requires at least 2 subnets in different AZs
# to support Multi-AZ failover.
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.neptune.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "neptune-private-b"
    Lab  = "24-neptune"
  }
}

# Security group for Neptune
# Only allow port 8182 from within the VPC (or from specific app security groups).
resource "aws_security_group" "neptune" {
  name        = "neptune-sg"
  description = "Security group for Amazon Neptune cluster"
  vpc_id      = aws_vpc.neptune.id

  # Allow inbound Gremlin/SPARQL/openCypher traffic on port 8182
  # from within the VPC only.
  ingress {
    description = "Neptune graph database port"
    from_port   = 8182
    to_port     = 8182
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.neptune.cidr_block] # Restrict to VPC CIDR
  }

  # Allow all outbound (Neptune needs to reach S3 for bulk load via IAM role)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "neptune-sg"
    Lab  = "24-neptune"
  }
}

# =============================================================================
# NEPTUNE SUBNET GROUP
# =============================================================================
#
# Like RDS, Neptune requires a DB subnet group — a collection of subnets
# across multiple AZs where Neptune instances can be placed.
#
# Minimum: 2 subnets in 2 different AZs (required for Multi-AZ).
# =============================================================================

resource "aws_neptune_subnet_group" "main" {
  name        = "neptune-subnet-group"
  description = "Subnet group for Neptune cluster across two AZs"

  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]

  tags = {
    Name = "neptune-subnet-group"
    Lab  = "24-neptune"
  }
}

# =============================================================================
# NEPTUNE CLUSTER PARAMETER GROUP
# =============================================================================
#
# Parameter groups let you customize Neptune engine settings — similar to
# RDS parameter groups.
#
# neptune_enable_audit_log = 1 → enables CloudWatch Logs for all queries.
# This is important for compliance and fraud investigation use cases.
# =============================================================================

resource "aws_neptune_cluster_parameter_group" "main" {
  family      = "neptune1.3" # Neptune engine family
  name        = "neptune-params"
  description = "Neptune cluster parameter group"

  parameter {
    name  = "neptune_enable_audit_log"
    value = "1" # Enable audit logging to CloudWatch Logs
  }

  tags = {
    Name = "neptune-params"
    Lab  = "24-neptune"
  }
}

# =============================================================================
# NEPTUNE CLUSTER
# =============================================================================
#
# ARCHITECTURE — understand this deeply for SAA-C03:
#
# Neptune uses a CLUSTER architecture similar to Aurora:
#
#   [Primary Instance] ──writes──→ [Shared Cluster Storage Volume]
#   [Read Replica 1]  ──reads──→  [Shared Cluster Storage Volume]
#   [Read Replica 2]  ──reads──→  [Shared Cluster Storage Volume]
#   (up to 15 read replicas)
#
# KEY POINT: Storage is SHARED and SEPARATE from compute.
# All instances (primary + replicas) read from the SAME underlying storage.
# This means:
#   - Replicas are always up-to-date (no replication lag for reads)
#   - Failover is fast (~30 seconds) — a replica is promoted to primary
#     and immediately has full access to all data (no data copy needed)
#   - You can have up to 15 read replicas for read scaling
#
# STORAGE DETAILS:
#   - Auto-grows in 10GB increments, up to 128 TB
#   - 6 copies of data across 3 AZs (2 copies per AZ)
#   - Can survive losing an entire AZ and still have enough copies to serve reads
#   - This is "SSD-backed, purpose-built distributed storage" — similar to Aurora
#
# MULTI-AZ:
#   - Automatic failover if primary instance fails
#   - Failover time: approximately 30 seconds
#   - During failover: the cluster endpoint automatically redirects to the new primary
#   - No manual intervention required
#
# ENDPOINTS (two types — both important for SAA-C03):
#
#   Cluster Endpoint (writer):
#     - Always points to the CURRENT primary instance
#     - Use for all WRITE operations (create vertex, add edge, update property)
#     - After failover, this endpoint automatically points to the promoted replica
#
#   Reader Endpoint (read):
#     - Load balances reads across ALL available read replicas
#     - Use for READ-HEAVY graph traversals (recommendations, social queries)
#     - If a replica fails, the reader endpoint automatically stops routing to it
# =============================================================================

resource "aws_neptune_cluster" "main" {
  cluster_identifier = "neptune-graph-cluster"

  # ENGINE
  engine         = "neptune"
  engine_version = "1.3.1.0" # Verify current version in AWS console

  # NETWORKING
  vpc_security_group_ids    = [aws_security_group.neptune.id]
  neptune_subnet_group_name = aws_neptune_subnet_group.main.name

  # PARAMETER GROUP
  neptune_cluster_parameter_group_name = aws_neptune_cluster_parameter_group.main.name

  # ENCRYPTION AT REST
  # Neptune encrypts data at rest using AWS KMS.
  # Once enabled, encryption cannot be disabled.
  # Best practice: always enable for production.
  storage_encrypted = true
  # kms_key_arn = aws_kms_key.neptune.arn  # Use CMK for BYOK compliance

  # BACKUP
  # Neptune continuously backs up data to S3 (like Aurora).
  # Point-in-time restore is available within the backup window.
  # Backup retention: 1–35 days.
  backup_retention_period = 7             # Keep 7 days of automated backups
  preferred_backup_window = "02:00-03:00" # UTC — off-peak for graph workloads

  # IAM AUTHENTICATION
  # When enabled, you use IAM roles/policies instead of passwords to
  # connect to Neptune. Recommended for application access control.
  iam_database_authentication_enabled = true

  # NEPTUNE STREAMS
  # Neptune Streams captures every change to the graph as an ordered log.
  # Each change record contains: operation type (ADD/REMOVE), vertex/edge
  # data, and a sequence token (like a Kafka offset).
  #
  # USE CASES FOR NEPTUNE STREAMS:
  #   - Replicate graph changes to Elasticsearch (for full-text search)
  #   - Trigger Lambda on graph changes (event-driven patterns)
  #   - Audit trail for compliance
  #   - Sync graph data to a relational DB for reporting
  #
  # SAA-C03: Neptune Streams is the Neptune equivalent of DynamoDB Streams.
  #   - DynamoDB Streams → capture item-level changes in DynamoDB tables
  #   - Neptune Streams  → capture vertex/edge changes in Neptune graphs

  # NOTE: Neptune Streams is enabled via a cluster parameter, not directly
  # in the cluster resource. Set neptune_streams=1 in the parameter group.

  # SKIP FINAL SNAPSHOT (for lab environments only)
  # In production, remove this and set a final_snapshot_identifier.
  skip_final_snapshot = true

  # DELETION PROTECTION
  # Prevents accidental deletion of the cluster.
  # Set to true in production.
  deletion_protection = false

  tags = {
    Name        = "neptune-graph-cluster"
    Environment = "learning"
    Lab         = "24-neptune"
  }
}

# =============================================================================
# NEPTUNE CLUSTER INSTANCES
# =============================================================================
#
# Neptune separates COMPUTE (instances) from STORAGE (cluster volume).
# You create instances that attach to the shared cluster storage.
#
# INSTANCE TYPES:
#   db.r6g.*  — ARM Graviton2 (best price/performance for most workloads)
#   db.r5.*   — x86, larger instance sizes available
#   db.t4g.*  — burstable, for development/test only
#
# For SAA-C03: graph workloads are memory-intensive (traversals load
# subgraphs into memory). Choose memory-optimized (r-family) instances.
#
# INSTANCE ROLES:
#   - First instance: WRITER (primary). Handles all write traffic.
#   - Second instance: READER (replica). Handles read traffic.
#     After failover, the reader can become the writer.
#
# Note: instance promotion_tier determines failover order.
# Lower number = higher priority for promotion to primary.
# =============================================================================

# Primary (writer) instance
resource "aws_neptune_cluster_instance" "writer" {
  identifier         = "neptune-writer"
  cluster_identifier = aws_neptune_cluster.main.cluster_identifier

  engine         = "neptune"
  instance_class = "db.r6g.large" # Memory-optimized, ARM Graviton

  # Placement: writer goes in AZ-a
  neptune_subnet_group_name = aws_neptune_subnet_group.main.name
  availability_zone         = data.aws_availability_zones.available.names[0]

  # Auto minor version upgrades
  # Neptune patches minor versions (e.g., 1.3.0 → 1.3.1) automatically
  # during the maintenance window. Disable if you need strict version control.
  auto_minor_version_upgrade   = true
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  # Promotion tier 0 = highest priority for failover
  # This is the primary, so it has the highest tier (won't be "promoted" to itself)
  promotion_tier = 0

  tags = {
    Name = "neptune-writer"
    Role = "primary"
    Lab  = "24-neptune"
  }
}

# Read replica instance
resource "aws_neptune_cluster_instance" "reader" {
  identifier         = "neptune-reader"
  cluster_identifier = aws_neptune_cluster.main.cluster_identifier

  engine         = "neptune"
  instance_class = "db.r6g.large"

  # Placement: reader goes in AZ-b (different AZ for true HA)
  neptune_subnet_group_name = aws_neptune_subnet_group.main.name
  availability_zone         = data.aws_availability_zones.available.names[1]

  auto_minor_version_upgrade   = true
  preferred_maintenance_window = "sun:05:00-sun:06:00" # Stagger from writer

  # Promotion tier 1 = second highest priority
  # If the primary fails, this replica will be promoted to primary.
  promotion_tier = 1

  # The reader instance depends on the writer being created first.
  # Terraform infers this from the cluster_identifier reference, but
  # explicit depends_on makes the intent clear.
  depends_on = [aws_neptune_cluster_instance.writer]

  tags = {
    Name = "neptune-reader"
    Role = "read-replica"
    Lab  = "24-neptune"
  }
}

# =============================================================================
# IAM ROLE FOR NEPTUNE → S3 BULK LOAD
# =============================================================================
#
# Neptune can bulk-load graph data from S3 using the Neptune Loader API.
# This is used to initially populate a Neptune database from flat files.
#
# SUPPORTED FILE FORMATS for bulk load:
#   - CSV (Gremlin format): vertex files and edge files
#   - RDF formats: Turtle, N-Triples, N-Quads, RDF/XML (for SPARQL model)
#   - openCypher format: node files and relationship files
#
# HOW IT WORKS:
#   1. Upload graph data files to S3
#   2. Neptune assumes this IAM role to read from S3
#   3. Call the Neptune Loader endpoint:
#      POST https://<cluster-endpoint>:8182/loader
#      { "source": "s3://my-bucket/graph-data/", "format": "csv", ... }
#   4. Neptune loads data in parallel from S3
#
# This IAM role is required — Neptune cannot access S3 without it.
# Attach it to the Neptune cluster via the iam_roles parameter (see below).
# =============================================================================

data "aws_iam_policy_document" "neptune_s3_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
      # Neptune uses the RDS service principal for IAM roles
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "neptune_s3_loader" {
  name               = "neptune-s3-loader-role"
  assume_role_policy = data.aws_iam_policy_document.neptune_s3_trust.json

  description = "Allows Neptune to read graph data files from S3 for bulk loading"

  tags = {
    Lab = "24-neptune"
  }
}

data "aws_iam_policy_document" "neptune_s3_permissions" {
  statement {
    sid    = "ReadGraphDataFromS3"
    effect = "Allow"

    actions = [
      "s3:GetObject",  # Read individual data files
      "s3:ListBucket", # List files in the bucket (required for bulk load)
    ]

    resources = [
      "arn:aws:s3:::your-neptune-data-bucket",  # The bucket itself (for ListBucket)
      "arn:aws:s3:::your-neptune-data-bucket/*" # Objects inside the bucket
    ]
    # Replace 'your-neptune-data-bucket' with your actual S3 bucket name.
  }
}

resource "aws_iam_policy" "neptune_s3_loader" {
  name        = "neptune-s3-loader-policy"
  description = "Allows Neptune bulk loader to read from S3"
  policy      = data.aws_iam_policy_document.neptune_s3_permissions.json
}

resource "aws_iam_role_policy_attachment" "neptune_s3_loader" {
  role       = aws_iam_role.neptune_s3_loader.name
  policy_arn = aws_iam_policy.neptune_s3_loader.arn
}

# =============================================================================
# NEPTUNE ANALYTICS (concept note)
# =============================================================================
#
# Neptune Analytics is a separate capability (not the same as the cluster above).
# It is an IN-MEMORY graph analytics engine for analyzing large graph datasets.
#
# KEY DIFFERENCES vs Neptune Database:
#
#   Neptune Database (what we built above):
#     - Persistent, durable storage
#     - Optimized for OLTP graph queries (real-time traversals)
#     - Gremlin, SPARQL, openCypher
#
#   Neptune Analytics:
#     - In-memory graph store (data loaded from S3 or Neptune Database)
#     - Optimized for OLAP graph analytics (large-scale algorithms)
#     - Supports vector similarity search (AI/ML use cases)
#     - Use for: PageRank, community detection, shortest path at scale
#
# SAA-C03 EXAM HINT:
#   "run graph algorithms on a large dataset" → Neptune Analytics
#   "vector similarity search on a graph"     → Neptune Analytics
#   "real-time social graph queries"          → Neptune Database
#
# Neptune Analytics is not yet supported in Terraform (as of 2024),
# so it is described here for exam knowledge only.
# =============================================================================
