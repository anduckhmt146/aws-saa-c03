################################################################################
# LAB 29: Amazon Aurora
# AWS SAA-C03 Exam Prep
#
# KEY CONCEPTS FOR THE EXAM:
#
# AURORA vs RDS:
#   - Aurora is AWS's proprietary relational database, NOT vanilla MySQL/PostgreSQL
#   - Aurora MySQL is ~5x faster than standard MySQL on RDS
#   - Aurora PostgreSQL is ~3x faster than standard PostgreSQL on RDS
#   - Aurora uses a shared, distributed storage layer (not local instance storage)
#   - Storage auto-grows in 10 GB increments up to 128 TB (you never provision storage)
#   - 6 copies of data across 3 AZs (2 copies per AZ) — survives loss of 2 copies for writes,
#     3 copies for reads
#   - Continuous incremental backups to S3 (no performance impact)
#   - Instantaneous failover (typically <30s); Aurora Serverless can take longer
#
# AURORA CLUSTER ARCHITECTURE:
#   Cluster = 1 writer instance + up to 15 read replicas
#   All instances share the same underlying cluster volume (storage is NOT per-instance)
#   Two endpoint types at cluster level:
#     - Cluster endpoint (writer endpoint): always points to current writer instance
#     - Reader endpoint: load-balances across all read replicas
#   Additional endpoint types:
#     - Custom endpoints: point to a user-defined subset of instances
#     - Instance endpoints: connect to a specific individual instance (for fine-grained routing)
#
# AURORA REPLICAS:
#   - Up to 15 read replicas per cluster (vs 5 for standard RDS)
#   - Replication lag typically <100 ms (because storage is shared, not log-shipping)
#   - Can be used as failover targets; Aurora promotes the replica with the least lag
#   - Can Auto Scale replicas with Application Auto Scaling (aws_appautoscaling_*)
#
# AURORA GLOBAL DATABASE:
#   - Spans multiple AWS Regions (1 primary + up to 5 secondary)
#   - Storage-level replication (not database-level), so typically <1 second RPO
#   - RTO (failover to secondary region) < 1 minute
#   - Use case: disaster recovery across regions, low-latency global reads
#   - SAA-C03 trigger words: "cross-region DR", "RPO < 1 second", "RTO < 1 minute"
#
# AURORA SERVERLESS v2:
#   - engine_mode = "provisioned" (confusingly) with serverlessv2_scaling_configuration
#   - Scales in fine-grained increments (0.5 ACU) vs v1 which had coarser scaling
#   - ACU = Aurora Capacity Unit (each ACU ~= 2 GB RAM + proportional CPU/network)
#   - min_capacity as low as 0.5 ACU; max_capacity up to 128 ACU
#   - Ideal for variable/unpredictable workloads, dev/test, intermittent use
#   - v1 uses engine_mode = "serverless"; v2 uses engine_mode = "provisioned" + scaling block
#   - SAA-C03 tip: "scales instantly", "variable workload", "pay per second" → Serverless v2
#
# AURORA MULTI-MASTER:
#   - All instances are writers (active-active writes)
#   - Only supported for Aurora MySQL 5.6
#   - Application must handle conflict resolution (Aurora can reject conflicting writes)
#   - Use case: continuous write availability (immediate failover with zero downtime)
#   - SAA-C03 tip: "no write downtime", "continuous write availability" → Multi-Master
#   - Less common exam topic than Global Database
#
# AURORA PARALLEL QUERY:
#   - Pushes query processing down to the distributed storage layer
#   - Dramatically speeds up analytical queries against the same cluster serving OLTP
#   - No need to extract data to a separate analytics system for many workloads
#   - engine_mode = "parallelquery" (mutually exclusive with serverless/multi-master)
#
# AURORA BACKTRACK:
#   - Rewind the database to a previous point in time WITHOUT restoring from a backup
#   - In-place rewind — no new cluster needed (unlike PITR which creates a new cluster)
#   - Only supported for Aurora MySQL
#   - backtrack_window = seconds (max 259200 = 72 hours)
#   - SAA-C03 tip: "undo accidental delete", "rewind without restore" → Backtrack
#   - Contrast: PITR (Point-In-Time Recovery) → creates a new cluster (RDS and Aurora)
#
# AURORA MySQL vs PostgreSQL:
#   MySQL:    port 3306, supports Backtrack, Multi-Master, Parallel Query
#   PostgreSQL: port 5432, supports Babelfish (T-SQL compatibility for SQL Server migrations)
#
# STORAGE ENCRYPTION:
#   - Enable at cluster creation; cannot be added later (must snapshot → copy encrypted → restore)
#   - Encrypts underlying storage, automated backups, snapshots, and replicas
#   - Uses AWS KMS CMK (Customer Managed Key) or AWS-managed key
################################################################################

# ------------------------------------------------------------------------------
# DATA SOURCES
# ------------------------------------------------------------------------------

# Fetch available AZs in the configured region.
# Aurora requires subnets in at least 2 AZs for the DB subnet group.
data "aws_availability_zones" "available" {
  state = "available"
}

# Use the default VPC to keep the lab self-contained.
# In production, Aurora should be in a dedicated private VPC.
data "aws_vpc" "default" {
  default = true
}

# Fetch all subnets belonging to the default VPC.
# We will use these for the DB subnet group.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ------------------------------------------------------------------------------
# SECURITY GROUP
# ------------------------------------------------------------------------------
# Aurora MySQL listens on port 3306.
# For the exam: security groups are STATEFUL — if you allow inbound 3306,
# the response traffic is automatically allowed outbound.

resource "aws_security_group" "aurora" {
  name        = "aurora-lab-sg"
  description = "Allow MySQL/Aurora access on port 3306 (lab only)"
  vpc_id      = data.aws_vpc.default.id

  # Inbound: allow MySQL from anywhere in the VPC CIDR.
  # Production: restrict to application server SG, never 0.0.0.0/0.
  ingress {
    description = "MySQL from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Outbound: allow all (AWS default; Aurora needs to reach S3 for backups).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "aurora-lab-sg"
  }
}

# ------------------------------------------------------------------------------
# DB SUBNET GROUP
# ------------------------------------------------------------------------------
# A DB subnet group defines which subnets Aurora can place instances in.
# Must span at least 2 AZs.
# SAA-C03: Aurora storage is always 6-way replicated across 3 AZs regardless of
# how many instances you provision — the subnet group only governs instance placement.

resource "aws_db_subnet_group" "aurora" {
  name        = "aurora-lab-subnet-group"
  description = "Subnet group for Aurora lab cluster — spans multiple AZs"
  subnet_ids  = data.aws_subnets.default.ids

  tags = {
    Name = "aurora-lab-subnet-group"
  }
}

# ------------------------------------------------------------------------------
# CLUSTER PARAMETER GROUP
# ------------------------------------------------------------------------------
# Cluster-level parameters apply to all instances in the cluster.
# Contrast with DB parameter groups, which are instance-level.
# SAA-C03: know that Aurora has both cluster and instance parameter groups.

resource "aws_rds_cluster_parameter_group" "aurora_mysql" {
  family      = "aurora-mysql8.0"
  name        = "aurora-lab-cluster-pg"
  description = "Custom cluster parameter group for Aurora MySQL 8.0 lab"

  # Example: enable the slow query log for query performance insights.
  # In production, you would also tune innodb_buffer_pool_size, etc.
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  # binlog_format is required if you use Aurora as a replication source.
  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "aurora-lab-cluster-pg"
  }
}

# ------------------------------------------------------------------------------
# AURORA CLUSTER (Writer + Shared Storage Layer)
# ------------------------------------------------------------------------------
# The aws_rds_cluster resource represents the Aurora CLUSTER — the logical
# grouping of instances and the shared storage volume.
#
# KEY EXAM POINTS about this resource:
#   - cluster_identifier: the logical name; used in the DNS endpoints
#   - engine: "aurora-mysql" or "aurora-postgresql"
#   - engine_version: pinned; Aurora manages minor version auto-upgrades
#   - master_username / master_password: only for the cluster (not per-instance)
#   - backup_retention_period: 1–35 days; automated backups to S3 are FREE
#   - preferred_backup_window: must not overlap with maintenance_window
#   - deletion_protection: set true in production; blocks accidental destroy
#   - storage_encrypted: enable at creation; cannot change after. Always enable.
#   - db_subnet_group_name / vpc_security_group_ids: network placement
#   - backtrack_window: Aurora MySQL only; 0 to disable, max 259200 (72h)
#     Backtrack rewinds in-place — much faster than PITR but limited to 72h
#   - enable_http_endpoint: enables Data API (serverless SQL over HTTPS, no VPN needed)
#   - iam_database_authentication_enabled: lets IAM users/roles authenticate
#     instead of username/password — important for SAA-C03 security questions

resource "aws_rds_cluster" "aurora_mysql" {
  cluster_identifier = "aurora-lab-cluster"

  # Aurora MySQL 8.0 compatible.
  # engine_mode defaults to "provisioned" (standard, always-on instances).
  # Other values: "serverless" (v1 — legacy), "parallelquery", "multimaster"
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.04.1"

  # Credentials: in production use aws_secretsmanager_secret + random_password.
  # Never hardcode passwords in Terraform for real workloads.
  master_username = "admin"
  master_password = "LabPassword123!" # rotate immediately after lab

  # Networking
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  # Cluster parameter group (cluster-level tuning)
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora_mysql.name

  # Backup & maintenance
  backup_retention_period      = 7             # days; free storage for automated backups
  preferred_backup_window      = "03:00-04:00" # UTC; outside business hours
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  # Backtrack — Aurora MySQL only.
  # Allows in-place rewind up to 72 hours without creating a new cluster.
  # SAA-C03: "rewind", "undo accidental change" → Backtrack (not PITR).
  backtrack_window = 86400 # 24 hours in seconds

  # Encryption at rest using AWS-managed KMS key.
  # To use a CMK: set kms_key_id = aws_kms_key.aurora.arn
  storage_encrypted = true

  # IAM authentication: allows tokens instead of passwords.
  # Useful with ECS tasks / Lambda that already have IAM roles.
  iam_database_authentication_enabled = true

  # Data API: HTTP endpoint for serverless SQL calls (no VPC/driver required).
  # Primarily used with Aurora Serverless but can be enabled here for testing.
  enable_http_endpoint = false

  # Lab safety: false so we can destroy without manual intervention.
  # PRODUCTION: always set to true; requires manual deletion protection disable.
  deletion_protection = false

  # Skip final snapshot for lab; set to false and provide final_snapshot_identifier in prod.
  skip_final_snapshot = true

  tags = {
    Name    = "aurora-lab-cluster"
    Purpose = "SAA-C03 Aurora exam prep lab"
  }
}

# ------------------------------------------------------------------------------
# AURORA CLUSTER INSTANCES
# ------------------------------------------------------------------------------
# Each aws_rds_cluster_instance is a compute node attached to the shared storage.
# Instance 1 will be the writer; instance 2 will be a reader (replica).
#
# SAA-C03 KEY POINTS:
#   - The CLUSTER endpoint always points to the WRITER instance
#     (Aurora auto-updates the DNS if failover occurs — no app change needed)
#   - The READER endpoint load-balances across all reader instances
#   - Up to 15 read replicas per cluster (contrast: 5 for standard RDS)
#   - Replicas can be promoted to writer during failover
#   - promotion_tier (0–15): lower number = higher priority for failover
#     Reader with promotion_tier=0 is promoted first if writer fails
#   - auto_minor_version_upgrade: let Aurora patch minor versions automatically
#   - performance_insights_enabled: provides query-level metrics (SAA-C03: monitoring)
#   - publicly_accessible: false for production; instances should be in private subnets

# Writer instance (primary)
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "aurora-lab-writer"
  cluster_identifier = aws_rds_cluster.aurora_mysql.id
  instance_class     = "db.t3.medium" # minimum class supporting Aurora MySQL 8.0

  engine         = aws_rds_cluster.aurora_mysql.engine
  engine_version = aws_rds_cluster.aurora_mysql.engine_version

  # The writer has the highest failover priority (lowest tier number).
  # If the writer fails, Aurora promotes the reader with the lowest promotion_tier.
  promotion_tier = 0

  # Enhanced Monitoring: publishes OS-level metrics every 1–60 seconds.
  # SAA-C03: CloudWatch only gets DB metrics; Enhanced Monitoring gives OS metrics.
  # monitoring_interval = 60
  # monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  # Performance Insights: query digest and wait event data.
  performance_insights_enabled = true

  auto_minor_version_upgrade = true
  publicly_accessible        = false

  db_subnet_group_name = aws_db_subnet_group.aurora.name

  tags = {
    Name = "aurora-lab-writer"
    Role = "writer"
  }
}

# Reader instance (replica)
resource "aws_rds_cluster_instance" "reader" {
  identifier         = "aurora-lab-reader-1"
  cluster_identifier = aws_rds_cluster.aurora_mysql.id
  instance_class     = "db.t3.medium"

  engine         = aws_rds_cluster.aurora_mysql.engine
  engine_version = aws_rds_cluster.aurora_mysql.engine_version

  # Lower priority than writer for failover; will become writer only if tier-0 is unavailable.
  promotion_tier = 1

  performance_insights_enabled = true
  auto_minor_version_upgrade   = true
  publicly_accessible          = false

  db_subnet_group_name = aws_db_subnet_group.aurora.name

  tags = {
    Name = "aurora-lab-reader-1"
    Role = "reader"
  }
}

# ------------------------------------------------------------------------------
# APPLICATION AUTO SCALING FOR READ REPLICAS
# ------------------------------------------------------------------------------
# Aurora can automatically add/remove read replicas based on CPU or connections.
# This uses Application Auto Scaling (NOT EC2 Auto Scaling — different service).
#
# SAA-C03 KEY POINTS:
#   - Scalable dimension: "rds:cluster:ReadReplicaCount"
#   - Service namespace: "rds"
#   - Policies can target CPU utilization or average connections
#   - Min capacity ≥ 1 (need at least one reader for the reader endpoint to work)
#   - Max capacity ≤ 15 (Aurora limit for read replicas)
#   - Scale-out adds instances; scale-in removes them (Aurora terminates the replica)
#   - Cooldown periods prevent thrashing (scale-out cooldown < scale-in cooldown recommended)

resource "aws_appautoscaling_target" "aurora_readers" {
  service_namespace  = "rds"
  resource_id        = "cluster:${aws_rds_cluster.aurora_mysql.cluster_identifier}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"

  # Keep between 1 and 4 reader instances.
  # The 1 reader we provisioned above counts toward the minimum.
  min_capacity = 1
  max_capacity = 4

  depends_on = [aws_rds_cluster_instance.reader]
}

resource "aws_appautoscaling_policy" "aurora_readers_cpu" {
  name               = "aurora-lab-reader-cpu-scaling"
  service_namespace  = aws_appautoscaling_target.aurora_readers.service_namespace
  resource_id        = aws_appautoscaling_target.aurora_readers.resource_id
  scalable_dimension = aws_appautoscaling_target.aurora_readers.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    # Scale when average CPU across readers exceeds 70%.
    # Application Auto Scaling will add replicas to bring this below the target.
    predefined_metric_specification {
      predefined_metric_type = "RDSReaderAverageCPUUtilization"
    }

    target_value = 70.0

    # Wait 300s after scale-out before evaluating again (new replicas take ~5 min to start).
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

# ------------------------------------------------------------------------------
# AURORA SERVERLESS V2 — COMMENTED-OUT EXAMPLE
# ------------------------------------------------------------------------------
# Uncomment and adapt to deploy a Serverless v2 cluster instead of provisioned.
#
# KEY EXAM POINTS — Aurora Serverless v2:
#   - engine_mode = "provisioned" (NOT "serverless" — v2 is technically provisioned mode
#     with serverless scaling enabled via the serverlessv2_scaling_configuration block)
#   - Aurora Serverless v1 used engine_mode = "serverless" (legacy, limited features)
#   - Serverless v2 scales in increments of 0.5 ACU; nearly instant scaling
#   - 1 ACU ≈ 2 GB RAM + proportional CPU/network bandwidth
#   - min_capacity: lowest value is 0.5 ACU; set to 0 only with pause enabled (v1 feature)
#   - max_capacity: up to 128 ACU; set based on peak workload estimate
#   - Each instance in the cluster must use instance_class = "db.serverless"
#   - Serverless v2 CAN be mixed with provisioned instances in the same cluster
#     (e.g., serverless writer + provisioned readers, or vice versa)
#   - Supports Multi-AZ (unlike v1 which was single-AZ with failover option)
#   - SAA-C03 triggers: "variable traffic", "dev/test", "overnight batch + daytime OLTP"
#
# resource "aws_rds_cluster" "aurora_serverless_v2" {
#   cluster_identifier = "aurora-serverless-v2-lab"
#   engine             = "aurora-mysql"
#   engine_version     = "8.0.mysql_aurora.3.04.1"
#
#   # engine_mode must be "provisioned" for Serverless v2.
#   # This is counterintuitive — "serverless" engine_mode is Aurora Serverless v1 (legacy).
#   engine_mode = "provisioned"
#
#   master_username = "admin"
#   master_password = "LabPassword123!"
#
#   db_subnet_group_name   = aws_db_subnet_group.aurora.name
#   vpc_security_group_ids = [aws_security_group.aurora.id]
#
#   # Serverless v2 scaling configuration — defines the ACU range for ALL serverless
#   # instances in this cluster. Individual instances cannot override these bounds.
#   serverlessv2_scaling_configuration {
#     min_capacity = 0.5  # minimum 0.5 ACU (~1 GB RAM); scale down to this when idle
#     max_capacity = 16   # maximum 16 ACU (~32 GB RAM); increase for high-memory workloads
#     # max_capacity = 128 # absolute maximum supported by Aurora Serverless v2
#   }
#
#   backup_retention_period = 7
#   storage_encrypted       = true
#   deletion_protection     = false
#   skip_final_snapshot     = true
#
#   tags = {
#     Name = "aurora-serverless-v2-lab"
#   }
# }
#
# # Serverless v2 instance — note instance_class = "db.serverless"
# resource "aws_rds_cluster_instance" "serverless_v2_writer" {
#   identifier         = "aurora-sv2-writer"
#   cluster_identifier = aws_rds_cluster.aurora_serverless_v2.id
#   instance_class     = "db.serverless"  # required for Serverless v2 instances
#   engine             = aws_rds_cluster.aurora_serverless_v2.engine
#   engine_version     = aws_rds_cluster.aurora_serverless_v2.engine_version
#   promotion_tier     = 0
#
#   tags = {
#     Name = "aurora-sv2-writer"
#   }
# }

# ------------------------------------------------------------------------------
# AURORA GLOBAL DATABASE — CONCEPTUAL NOTES (not deployed — requires two regions)
# ------------------------------------------------------------------------------
# To create a Global Database:
#
#   resource "aws_rds_global_cluster" "global" {
#     global_cluster_identifier = "aurora-global-lab"
#     engine                    = "aurora-mysql"
#     engine_version            = "8.0.mysql_aurora.3.04.1"
#     database_name             = "globaldb"
#     storage_encrypted         = true
#   }
#
# Then in the PRIMARY region provider:
#   resource "aws_rds_cluster" "primary" {
#     global_cluster_identifier = aws_rds_global_cluster.global.id
#     ...
#   }
#
# Then in the SECONDARY region provider:
#   resource "aws_rds_cluster" "secondary" {
#     global_cluster_identifier = aws_rds_global_cluster.global.id
#     ...
#   }
#
# KEY EXAM POINTS — Aurora Global Database:
#   - Replication at the STORAGE level (not binlog/WAL) — lag typically < 1 second
#   - RPO (Recovery Point Objective): < 1 second
#   - RTO (Recovery Time Objective): < 1 minute for managed failover
#   - Secondary regions are READ-ONLY; promote to standalone cluster to make writable
#   - Use case: global low-latency reads + cross-region DR
#   - SAA-C03 triggers: "cross-region disaster recovery", "RPO 1 second", "global users"

# ------------------------------------------------------------------------------
# OUTPUTS
# ------------------------------------------------------------------------------

output "cluster_endpoint" {
  description = <<-EOT
    Aurora CLUSTER (writer) endpoint.
    Always points to the current writer instance — DNS updates automatically on failover.
    Connect your application's write traffic here.
    SAA-C03: this endpoint never changes even when the underlying writer instance changes.
  EOT
  value       = aws_rds_cluster.aurora_mysql.endpoint
}

output "reader_endpoint" {
  description = <<-EOT
    Aurora READER endpoint.
    Load-balances connections across all available read replica instances.
    Connect your application's read traffic here to offload the writer.
    SAA-C03: reader endpoint does NOT route to the writer, even if no replicas exist —
    it will return a connection refused if all replicas are down.
  EOT
  value       = aws_rds_cluster.aurora_mysql.reader_endpoint
}

output "cluster_identifier" {
  description = "Aurora cluster identifier — used in AWS CLI commands and console."
  value       = aws_rds_cluster.aurora_mysql.cluster_identifier
}

output "writer_instance_endpoint" {
  description = <<-EOT
    Direct endpoint for the writer instance (instance endpoint, not cluster endpoint).
    Use instance endpoints to route to a SPECIFIC instance (advanced routing).
    Typical apps should use the cluster endpoint, not this.
  EOT
  value       = aws_rds_cluster_instance.writer.endpoint
}

output "reader_instance_endpoint" {
  description = "Direct endpoint for the reader instance (bypasses reader load balancer)."
  value       = aws_rds_cluster_instance.reader.endpoint
}

output "aurora_port" {
  description = "Aurora MySQL port (3306). Aurora PostgreSQL would be 5432."
  value       = aws_rds_cluster.aurora_mysql.port
}

output "auto_scaling_resource_id" {
  description = "Application Auto Scaling resource ID for Aurora read replicas."
  value       = aws_appautoscaling_target.aurora_readers.resource_id
}
