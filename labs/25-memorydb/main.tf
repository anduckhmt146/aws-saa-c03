################################################################################
# Lab 25: Amazon MemoryDB for Redis
# SAA-C03 Exam Focus: Durable, Redis-compatible PRIMARY database
################################################################################
#
# KEY EXAM CONCEPT: MemoryDB vs ElastiCache Redis
# -----------------------------------------------
# MemoryDB for Redis:
#   - Redis-compatible IN-MEMORY DATABASE (not just a cache)
#   - DURABLE: data is persisted to a distributed, multi-AZ transaction log
#   - Survives node failures WITHOUT DATA LOSS
#   - Use as a PRIMARY database - data is the source of truth
#   - Microsecond read / single-digit millisecond write latency
#   - Higher cost than ElastiCache
#
# ElastiCache for Redis:
#   - Redis-compatible CACHE LAYER (sits in front of a real database)
#   - NOT durable by default - a node failure can mean DATA LOSS
#   - Use for caching, session store, leaderboards on top of another DB
#   - Lower cost, but data is ephemeral
#
# SAA-C03 TRICK QUESTION PATTERN:
#   "Need Redis that survives node failure without data loss"  => MemoryDB
#   "Need to cache DynamoDB queries with sub-ms latency"      => ElastiCache
#   "Need in-memory database with strong consistency"         => MemoryDB
#
# Use Cases for MemoryDB:
#   - User session management that MUST survive node failure
#   - Real-time leaderboards with durable state
#   - Microservices that need a fast, durable shared data store
#   - Replacing Redis OSS clusters that require persistence guarantees
#
# Multi-AZ Architecture:
#   - Primary node writes to the multi-AZ transaction log synchronously
#   - Replica nodes in other AZs replay the log for durability
#   - Automatic failover: if primary fails, replica is promoted with ZERO data loss
#   - Contrast with ElastiCache: async replication can lag, so failover MAY lose recent writes
#
# Cluster Mode:
#   - Data is sharded across multiple nodes (horizontal scaling)
#   - Each shard has 1 primary + N replicas
#   - Supports up to 500 nodes per cluster
#   - Scales both read throughput (more replicas) and dataset size (more shards)
#
# Security:
#   - Encryption in transit: TLS required (enforced on cluster, unlike ElastiCache where optional)
#   - Encryption at rest: AWS-managed or CMK via KMS
#   - ACL (Access Control List): fine-grained user/password authentication
#     unlike ElastiCache AUTH token (single shared token), MemoryDB supports multiple users
#
################################################################################

################################################################################
# NETWORKING
# MemoryDB requires a subnet group spanning at least 2 AZs for Multi-AZ
################################################################################

resource "aws_vpc" "memorydb_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "memorydb-lab-vpc"
  }
}

# Subnet in AZ-a
# MemoryDB will place shard primaries and replicas across these subnets
resource "aws_subnet" "subnet_a" {
  vpc_id            = aws_vpc.memorydb_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "memorydb-subnet-a"
  }
}

# Subnet in AZ-b
# Replicas (and failed-over primaries) will land here for Multi-AZ durability
resource "aws_subnet" "subnet_b" {
  vpc_id            = aws_vpc.memorydb_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "memorydb-subnet-b"
  }
}

# Security group: allow Redis traffic (port 6379) from within the VPC only
# MemoryDB is NOT internet-accessible; always accessed via private endpoints
resource "aws_security_group" "memorydb_sg" {
  name        = "memorydb-sg"
  description = "Allow Redis traffic on port 6379 from within VPC"
  vpc_id      = aws_vpc.memorydb_vpc.id

  ingress {
    description = "Redis port - from VPC CIDR only (never expose to internet)"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.memorydb_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "memorydb-sg"
  }
}

################################################################################
# MEMORYDB SUBNET GROUP
# Tells MemoryDB which subnets to place cluster nodes in.
# Best practice: include subnets from at least 2 AZs for Multi-AZ fault tolerance.
################################################################################

resource "aws_memorydb_subnet_group" "lab_subnet_group" {
  name        = "memorydb-lab-subnet-group"
  description = "Subnet group spanning 2 AZs for MemoryDB Multi-AZ deployment"

  subnet_ids = [
    aws_subnet.subnet_a.id,
    aws_subnet.subnet_b.id,
  ]

  tags = {
    Name = "memorydb-lab-subnet-group"
  }
}

################################################################################
# MEMORYDB PARAMETER GROUP
# Controls Redis engine settings (same concept as RDS parameter groups).
# The family must match the engine version used in the cluster.
#
# SAA-C03: Parameter groups are used across RDS, ElastiCache, and MemoryDB
# to configure engine-level settings without requiring a config file.
################################################################################

resource "aws_memorydb_parameter_group" "lab_params" {
  name        = "memorydb-lab-params"
  description = "Custom parameter group for MemoryDB lab"

  # Family must match the engine version: memorydb_redis7
  family = "memorydb_redis7"

  # Example: configure maxmemory eviction policy
  # noeviction = do not evict keys (good for primary DB use case - never lose data)
  # allkeys-lru = evict least recently used keys (better for cache use case)
  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  tags = {
    Name = "memorydb-lab-params"
  }
}

################################################################################
# MEMORYDB ACL (Access Control List)
# Controls which users can connect to the cluster and what they can do.
#
# EXAM NOTE: MemoryDB ACLs vs ElastiCache AUTH:
#   - ElastiCache: uses a single AUTH token (password) shared by all clients
#   - MemoryDB: supports multiple users with individual passwords and command permissions
#     This is more secure for production multi-tenant workloads.
#
# The "open-access" ACL allows all connections (for lab purposes only).
# In production, create aws_memorydb_user resources and restrict commands.
################################################################################

resource "aws_memorydb_acl" "lab_acl" {
  name = "memorydb-lab-acl"

  # "open-access" is a built-in ACL that allows all users without auth.
  # For production: create named users with passwords and assign them here.
  user_names = ["admin"]

  tags = {
    Name = "memorydb-lab-acl"
  }
}

################################################################################
# MEMORYDB CLUSTER
# The core resource. Key parameters for SAA-C03:
#
# num_shards:
#   Number of shards that partition the keyspace (horizontal scaling).
#   More shards = larger total dataset capacity + more write throughput.
#
# num_replicas_per_shard:
#   Replicas per shard for read scaling and Multi-AZ failover.
#   At least 1 replica required for Multi-AZ automatic failover.
#
# tls_enabled:
#   Encryption in transit. MemoryDB REQUIRES TLS by default (unlike ElastiCache).
#   Exam tip: if a question mentions enforcing encryption in transit for Redis, MemoryDB is safer.
#
# kms_key_arn (optional):
#   MemoryDB ALWAYS encrypts data at rest - there is no toggle to disable it.
#   Omit this argument to use the AWS-managed key, or provide a CMK ARN for
#   customer-controlled key rotation and cross-account access policies.
#
# auto_minor_version_upgrade:
#   AWS automatically applies minor Redis engine upgrades during maintenance windows.
#
# node_type:
#   Instance size. Larger nodes = more RAM = larger dataset per shard.
#   db.r6g.large is a common general-purpose choice; db.t4g.small for low-cost labs.
################################################################################

resource "aws_memorydb_cluster" "lab_cluster" {
  name        = "memorydb-lab-cluster"
  description = "SAA-C03 lab: durable Redis-compatible primary database"

  # Node type determines memory per shard node
  # db.t4g.small is the smallest/cheapest for lab use
  node_type = "db.t4g.small"

  # Engine version - must match the parameter group family above
  engine_version = "7.0"

  # 2 shards: keyspace is split across 2 primary nodes
  # Each shard independently handles a portion of the data
  num_shards = 2

  # 1 replica per shard in a different AZ = Multi-AZ durability
  # If the primary in shard-0 fails, the replica is promoted with NO DATA LOSS
  # (unlike ElastiCache where async replication may miss the last few writes)
  num_replicas_per_shard = 1

  # Security: TLS required for all client connections
  tls_enabled = true

  # Encryption at rest: MemoryDB ALWAYS encrypts data at rest - it is not optional.
  # The Terraform aws_memorydb_cluster resource does not expose an at_rest_encryption_enabled
  # toggle because encryption at rest is always on. You can optionally provide a KMS CMK;
  # if omitted, AWS uses the default AWS-managed key for MemoryDB.
  # kms_key_arn = aws_kms_key.memorydb_key.arn

  # Networking
  subnet_group_name  = aws_memorydb_subnet_group.lab_subnet_group.name
  security_group_ids = [aws_security_group.memorydb_sg.id]

  # ACL for authentication
  acl_name = aws_memorydb_acl.lab_acl.name

  # Parameter group for engine configuration
  parameter_group_name = aws_memorydb_parameter_group.lab_params.name

  # Snapshot: MemoryDB supports point-in-time snapshots on top of the transaction log
  snapshot_retention_limit = 7 # keep 7 days of daily snapshots
  snapshot_window          = "05:00-06:00"

  # Maintenance window: when AWS applies minor version upgrades
  maintenance_window = "sun:02:00-sun:03:00"

  auto_minor_version_upgrade = true

  tags = {
    Name = "memorydb-lab-cluster"
    # Tag to help remember exam distinction
    ExamNote = "MemoryDB = durable Redis primary DB; ElastiCache = ephemeral cache layer"
  }
}

################################################################################
# OUTPUTS
################################################################################

output "memorydb_cluster_endpoint" {
  description = <<-EOT
    MemoryDB cluster endpoint (used by client applications).
    Connect with any Redis client using TLS on port 6379.
    Example: redis-cli -h <endpoint> -p 6379 --tls
  EOT
  value       = aws_memorydb_cluster.lab_cluster.cluster_endpoint
}

output "memorydb_cluster_arn" {
  description = "ARN of the MemoryDB cluster - used for IAM policies and CloudTrail"
  value       = aws_memorydb_cluster.lab_cluster.arn
}

output "memorydb_num_shards" {
  description = "Number of shards (data partitions) in the cluster"
  value       = aws_memorydb_cluster.lab_cluster.num_shards
}

output "exam_reminder" {
  description = "SAA-C03 key distinction"
  value       = "MemoryDB = Redis-compatible DURABLE primary DB (multi-AZ transaction log). ElastiCache Redis = cache layer, NOT a primary DB, data can be lost on failure."
}
