# ============================================================
# LAB 13 - ElastiCache: Redis + Memcached
# In-memory caching — sub-millisecond latency
# Redis: data structures, persistence, replication, pub/sub
# Memcached: simple cache, multi-threaded, no persistence
# ============================================================

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# SECURITY GROUP
# ============================================================
resource "aws_security_group" "redis" {
  name        = "lab-redis-sg"
  description = "ElastiCache Redis security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Redis port"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "memcached" {

  name        = "lab-memcached-sg"
  description = "ElastiCache Memcached security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 11211
    to_port     = 11211
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# SUBNET GROUP
# ============================================================
resource "aws_elasticache_subnet_group" "lab" {
  name       = "lab-elasticache-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# ============================================================
# PARAMETER GROUP
# ============================================================
resource "aws_elasticache_parameter_group" "redis" {
  name   = "lab-redis-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru" # Eviction policy when memory is full
  }
}

# ============================================================
# REDIS CLUSTER (Cluster Mode Disabled)
# - Primary node + Read Replicas
# - Automatic failover with Multi-AZ
# - Supports: strings, hashes, lists, sets, sorted sets
# - Use case: session store, leaderboards, pub/sub, queues
# - Persistence: RDB (snapshots) + AOF (append-only file)
# ============================================================
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "lab-redis"
  description          = "Lab Redis replication group"

  node_type            = var.node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.lab.name
  security_group_ids   = [aws_security_group.redis.id]

  # Replication: 1 primary + 1 replica
  num_cache_clusters = 2 # primary + 1 replica

  # Multi-AZ with automatic failover
  automatic_failover_enabled = true
  multi_az_enabled           = true

  # Encryption
  at_rest_encryption_enabled = true # Encrypt data at rest
  transit_encryption_enabled = true # Encrypt in transit (TLS)

  # Maintenance
  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_window          = "04:00-05:00"
  snapshot_retention_limit = 1 # Days (0 = disabled)

  # destroy-safe
  final_snapshot_identifier = null
  apply_immediately         = true

  tags = { Name = "lab-redis" }
}

# ============================================================
# MEMCACHED CLUSTER
# - Multi-threaded, horizontally scalable
# - Simple key-value cache only
# - No persistence, no replication, no failover
# - Use case: simple caching, stateless
# ============================================================
resource "aws_elasticache_cluster" "memcached" {
  cluster_id           = "lab-memcached"
  engine               = "memcached"
  node_type            = var.node_type
  num_cache_nodes      = 2 # Multiple nodes for sharding
  port                 = 11211
  parameter_group_name = "default.memcached1.6"
  subnet_group_name    = aws_elasticache_subnet_group.lab.name
  security_group_ids   = [aws_security_group.memcached.id]

  tags = { Name = "lab-memcached" }
}
