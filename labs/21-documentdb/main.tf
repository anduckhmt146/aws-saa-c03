# =============================================================================
# LAB 21: Amazon DocumentDB
# =============================================================================
#
# WHAT IS DOCUMENTDB?
# ---------------------
# Amazon DocumentDB is a fully managed, MongoDB-compatible document database.
# It stores data as JSON-like documents (BSON internally), making it ideal
# for content catalogs, user profiles, and applications already using MongoDB.
#
# KEY ARCHITECTURE CONCEPTS FOR SAA-C03:
#
# 1. CLUSTER ARCHITECTURE
#    - DocumentDB uses a CLUSTER model, not standalone instances.
#    - One cluster has ONE primary instance (read/write) and up to 15 read
#      replicas (read-only).
#    - All instances share the SAME underlying distributed storage volume.
#    - This is fundamentally different from RDS Multi-AZ, where each instance
#      has its own storage.
#
# 2. STORAGE ENGINE
#    - Storage is AUTO-SCALING: starts at 10 GB, grows in 10 GB increments,
#      up to 128 TB — you never provision storage size manually.
#    - Data is replicated SIX TIMES across THREE Availability Zones.
#    - This 6-way replication makes it extremely durable (99.99% SLA).
#    - Compare to Aurora, which uses the same shared-storage architecture
#      (DocumentDB actually runs on a similar engine to Aurora).
#
# 3. ENDPOINTS
#    - CLUSTER ENDPOINT: points to the primary (writer) instance. Use this
#      for writes and for reads that require the latest data.
#    - READER ENDPOINT: load-balances reads across all available replicas.
#      Use this to scale read throughput.
#    - INSTANCE ENDPOINTS: each individual instance also has its own endpoint.
#
# 4. MULTI-AZ & FAILOVER
#    - Place instances in different AZs for high availability.
#    - If the primary fails, DocumentDB promotes a replica automatically
#      in approximately 30 seconds (sub-minute failover).
#    - Promotion is fast because replicas already share the same storage —
#      no data replication lag to catch up on.
#
# 5. BACKUPS
#    - Automated backups: continuous, stored in S3, retained 1–35 days.
#      Supports point-in-time recovery (PITR) to any second in the window.
#    - Manual snapshots: user-initiated, kept until explicitly deleted.
#
# 6. SECURITY
#    - Encryption at rest: uses AWS KMS (must be enabled at cluster creation,
#      cannot be changed after).
#    - Encryption in transit: TLS 1.2. Controlled via the cluster parameter
#      group ("tls" parameter). Strongly recommended in production.
#    - VPC-only: DocumentDB runs inside a VPC — there is no public endpoint
#      option. Access from outside requires VPN, Direct Connect, or a bastion.
#
# SAA-C03 EXAM TRAP:
# ------------------
# DocumentDB is NOT globally distributed. It does NOT have a feature equivalent
# to DynamoDB Global Tables. The cluster lives in ONE region. If you need
# multi-region replication or global distribution, DynamoDB Global Tables is
# the correct answer. DocumentDB's cross-region story is disaster-recovery via
# snapshots, not active-active global replication.
#
# SAA-C03 EXAM KEYWORD TRIGGERS:
# - "MongoDB-compatible"        → DocumentDB
# - "managed document database" → DocumentDB
# - "JSON document store"       → DocumentDB (or DynamoDB if serverless needed)
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

# Fetch the current AWS account identity — useful for tagging and naming.
data "aws_caller_identity" "current" {}

# Fetch available AZs in the current region so we can place subnets
# across different AZs for high availability.
data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------------------------------------------------------------
# NETWORKING: VPC
# -----------------------------------------------------------------------------
# DocumentDB REQUIRES a VPC. There is no public internet access option.
# Best practice is private subnets only — applications access the cluster
# through the VPC, never directly from the internet.

resource "aws_vpc" "docdb_vpc" {
  cidr_block           = "10.21.0.0/16"
  enable_dns_hostnames = true # Required: DocumentDB uses DNS hostnames for endpoints
  enable_dns_support   = true

  tags = {
    Name = "docdb-lab-vpc"
  }
}

# Private Subnet A — in the first available AZ.
# "Private" means no route to an Internet Gateway. DocumentDB instances
# should never be directly reachable from the public internet.
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.docdb_vpc.id
  cidr_block        = "10.21.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "docdb-private-subnet-a"
    Tier = "private"
  }
}

# Private Subnet B — in a DIFFERENT AZ for Multi-AZ placement.
# Distributing instances across AZs means a single AZ outage doesn't
# take down the entire DocumentDB cluster.
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.docdb_vpc.id
  cidr_block        = "10.21.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "docdb-private-subnet-b"
    Tier = "private"
  }
}

# Private Subnet C — third AZ.
# DocumentDB storage replicates across 3 AZs regardless of where instances
# are placed, but putting instances in 3 AZs gives the best HA posture.
resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.docdb_vpc.id
  cidr_block        = "10.21.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[2]

  tags = {
    Name = "docdb-private-subnet-c"
    Tier = "private"
  }
}

# -----------------------------------------------------------------------------
# SECURITY GROUP
# -----------------------------------------------------------------------------
# A security group acts as a virtual firewall for the DocumentDB cluster.
# DocumentDB listens on port 27017 (the default MongoDB port).
#
# EXAM NOTE: Security groups are STATEFUL — if you allow inbound traffic on
# port 27017, the response traffic is automatically allowed outbound.
# This is different from Network ACLs, which are STATELESS (you must
# explicitly allow both inbound and outbound).

resource "aws_security_group" "docdb_sg" {
  name        = "docdb-cluster-sg"
  description = "Security group for DocumentDB cluster - allows MongoDB port 27017"
  vpc_id      = aws_vpc.docdb_vpc.id

  # Inbound: allow MongoDB traffic from within the VPC only.
  # In a real environment, you would restrict this further to the specific
  # security group(s) of your application servers.
  ingress {
    description = "MongoDB/DocumentDB port from within VPC"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.docdb_vpc.cidr_block]
  }

  # Outbound: allow all outbound traffic (AWS default behavior for SGs).
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "docdb-cluster-sg"
  }
}

# -----------------------------------------------------------------------------
# SUBNET GROUP
# -----------------------------------------------------------------------------
# A DB Subnet Group tells DocumentDB which subnets it can place instances in.
# It must span at least TWO AZs (AWS requirement).
# Best practice: include subnets in ALL AZs you want to use.
#
# EXAM NOTE: Subnet groups are also required for RDS and ElastiCache —
# same concept across all AWS managed database services.

resource "aws_docdb_subnet_group" "docdb_subnet_group" {
  name        = "docdb-lab-subnet-group"
  description = "Subnet group for DocumentDB - spans 3 AZs for high availability"

  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id,
    aws_subnet.private_c.id,
  ]

  tags = {
    Name = "docdb-lab-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# CLUSTER PARAMETER GROUP
# -----------------------------------------------------------------------------
# Parameter groups allow you to configure DocumentDB engine settings.
# Think of them as "configuration files" for the database engine.
#
# Key parameters for SAA-C03:
# - tls: enable/disable TLS encryption in transit. Default is "enabled".
#   Setting to "disabled" is NOT recommended — only do this for testing.
# - ttl_monitor: controls document TTL expiration monitoring interval.
# - profiler: enables slow query logging (useful for performance tuning).
#
# EXAM NOTE: If you change a static parameter, you must REBOOT the instances
# for the change to take effect. Dynamic parameters apply immediately.
# "tls" is a STATIC parameter — changing it requires a reboot.

resource "aws_docdb_cluster_parameter_group" "docdb_params" {
  name        = "docdb-lab-params"
  family      = "docdb5.0" # DocumentDB engine version family
  description = "Parameter group for DocumentDB lab - enforces TLS"

  # TLS PARAMETER: encryption in transit
  # - "enabled"  = all connections must use TLS (recommended for production)
  # - "disabled" = connections can be unencrypted (development/testing only)
  # For SAA-C03: know that TLS is controlled via parameter group, NOT via a
  # toggle on the cluster resource itself (unlike RDS which has separate settings).
  parameter {
    name  = "tls"
    value = "enabled"
  }

  # PROFILER PARAMETER: logs queries that take longer than the threshold.
  # Useful for diagnosing slow queries. Default is "disabled".
  parameter {
    name  = "profiler"
    value = "disabled"
  }

  tags = {
    Name = "docdb-lab-params"
  }
}

# -----------------------------------------------------------------------------
# KMS KEY FOR ENCRYPTION AT REST
# -----------------------------------------------------------------------------
# DocumentDB supports encryption at rest using AWS KMS.
# You can use the AWS-managed key (aws/rds) or a Customer Managed Key (CMK).
# Using a CMK gives you more control: key rotation, key policies, audit via
# CloudTrail. For the exam, know the difference:
# - AWS Managed Key: AWS controls rotation (automatic every year)
# - CMK: you control the key policy, can disable/delete, manual or auto rotation
#
# IMPORTANT: Encryption at rest must be configured AT CLUSTER CREATION TIME.
# You CANNOT enable or disable encryption on an existing cluster.
# (To encrypt an unencrypted cluster, you must snapshot → restore encrypted.)

resource "aws_kms_key" "docdb_kms" {
  description             = "KMS key for DocumentDB cluster encryption at rest"
  deletion_window_in_days = 7 # Minimum 7 days, maximum 30 days waiting period

  # Key rotation: automatically rotates the key material every year.
  # Rotation creates new key material but the key ID stays the same —
  # DocumentDB continues working without any changes.
  enable_key_rotation = true

  tags = {
    Name    = "docdb-lab-kms-key"
    Purpose = "DocumentDB encryption at rest"
  }
}

resource "aws_kms_alias" "docdb_kms_alias" {
  name          = "alias/docdb-lab"
  target_key_id = aws_kms_key.docdb_kms.key_id
}

# -----------------------------------------------------------------------------
# DOCUMENTDB CLUSTER
# -----------------------------------------------------------------------------
# The CLUSTER is the core resource. It defines the shared storage volume,
# backup settings, encryption, and networking configuration.
# Individual compute instances (below) attach to this cluster.
#
# ARCHITECTURE REMINDER:
# - The cluster has ONE endpoint for writes (cluster_endpoint)
# - The cluster has ONE reader endpoint for load-balanced reads (reader_endpoint)
# - Each instance also has its own individual endpoint (instance_endpoint)
#
# STORAGE: You do NOT specify storage size. DocumentDB automatically allocates
# and grows storage in 10 GB increments. Max is 128 TB. You are billed for
# what you use, not what you allocate.

resource "aws_docdb_cluster" "docdb_cluster" {
  cluster_identifier = "docdb-lab-cluster"

  # ENGINE: DocumentDB is compatible with MongoDB 3.6, 4.0, 5.0 API.
  # "docdb" is the engine name used in Terraform (not "mongodb").
  engine         = "docdb"
  engine_version = "5.0.0"

  # CREDENTIALS: Master username and password for the admin user.
  # In production, use AWS Secrets Manager to store these and rotate them
  # automatically. DocumentDB integrates natively with Secrets Manager.
  master_username = "docdbadmin"
  master_password = "LabPassword123!" # In production: use Secrets Manager!

  # NETWORKING: Attach to our private subnets and security group.
  db_subnet_group_name   = aws_docdb_subnet_group.docdb_subnet_group.name
  vpc_security_group_ids = [aws_security_group.docdb_sg.id]

  # PORT: DocumentDB default port is 27017 (MongoDB compatible).
  port = 27017

  # PARAMETER GROUP: Apply our custom parameter group (TLS enabled).
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.docdb_params.name

  # BACKUP: Automated backups retained for 7 days.
  # - backup_retention_period: 1–35 days. 0 disables automated backups.
  # - preferred_backup_window: when AWS takes the daily backup snapshot.
  #   Must not overlap with the preferred_maintenance_window.
  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00" # UTC — pick a low-traffic window

  # MAINTENANCE WINDOW: when AWS can perform patching and maintenance.
  # Format: ddd:hh24:mi-ddd:hh24:mi (day:hour:minute)
  preferred_maintenance_window = "sun:05:00-sun:06:00" # Sundays at 5 AM UTC

  # ENCRYPTION AT REST: Enable using our CMK.
  # storage_encrypted = true enables encryption; kms_key_id specifies the key.
  # If you omit kms_key_id, AWS uses the default aws/rds managed key.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.docdb_kms.arn

  # DELETION PROTECTION: Prevents accidental deletion of the cluster.
  # To delete, you must first disable this setting. Recommended for production.
  deletion_protection = false # Set to true for production!

  # SKIP FINAL SNAPSHOT: For labs, skip the snapshot on destroy to save time.
  # In production, set to false and provide final_snapshot_identifier.
  skip_final_snapshot = true

  # CLOUDWATCH LOGS: Export logs to CloudWatch Logs for monitoring.
  # - "audit"    = log all authenticated operations (DDL/DML)
  # - "profiler" = log slow queries (when profiler parameter is enabled)
  enabled_cloudwatch_logs_exports = ["audit", "profiler"]

  tags = {
    Name = "docdb-lab-cluster"
  }
}

# -----------------------------------------------------------------------------
# DOCUMENTDB CLUSTER INSTANCES
# -----------------------------------------------------------------------------
# Instances are the compute layer. They process queries and access the shared
# storage volume. All instances (primary and replicas) read from the same
# underlying storage — there is no replication lag for reads.
#
# INSTANCE ROLES:
# - The FIRST instance created gets elected as the PRIMARY (read/write).
# - Additional instances become READ REPLICAS automatically.
# - If the primary fails, DocumentDB promotes the "best" replica (typically
#   the one with the lowest replication lag, though since storage is shared,
#   all replicas are equally up-to-date).
#
# INSTANCE SIZING:
# - Instance class determines CPU and RAM, which affects query performance.
# - All instances in a cluster can be different sizes (but same family is best).
# - db.t3.medium is suitable for dev/test; use db.r5/r6g for production.
#
# EXAM NOTE: DocumentDB does NOT support "serverless" capacity (unlike Aurora
# Serverless). You must choose and manage instance sizes manually.

# PRIMARY INSTANCE
# The first instance in the cluster typically becomes the primary writer.
# It handles all write operations and can also serve reads.
resource "aws_docdb_cluster_instance" "primary" {
  identifier         = "docdb-lab-primary"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id
  instance_class     = "db.t3.medium"

  # Place in the first AZ for explicit AZ distribution.
  # DocumentDB will assign the primary/replica role dynamically.
  availability_zone = data.aws_availability_zones.available.names[0]

  # AUTO MINOR VERSION UPGRADE: allow AWS to apply minor engine patches
  # automatically during the maintenance window.
  auto_minor_version_upgrade = true

  # PROMOTION TIER: determines which replica gets promoted first on failover.
  # Lower number = higher priority. Range: 0 (highest) to 15 (lowest).
  # Multiple instances can share the same tier; AWS picks one randomly if tied.
  promotion_tier = 0 # Primary gets highest promotion priority (it won't need it,
  # but good practice to keep primaries at tier 0)

  tags = {
    Name = "docdb-lab-primary"
    Role = "primary"
  }
}

# READ REPLICA 1
# Shares the same storage volume as the primary — no replication lag.
# Serves read traffic routed through the reader endpoint.
resource "aws_docdb_cluster_instance" "replica_1" {
  identifier         = "docdb-lab-replica-1"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id
  instance_class     = "db.t3.medium"

  # Place in a DIFFERENT AZ from the primary for fault tolerance.
  availability_zone = data.aws_availability_zones.available.names[1]

  auto_minor_version_upgrade = true

  # PROMOTION TIER: if the primary fails, this replica has the second-highest
  # priority for promotion (tier 1 < tier 2).
  promotion_tier = 1

  # Replicas depend on the primary — create primary first, then replicas.
  depends_on = [aws_docdb_cluster_instance.primary]

  tags = {
    Name = "docdb-lab-replica-1"
    Role = "replica"
  }
}

# READ REPLICA 2
# Third instance in the third AZ — maximum availability distribution.
# With 3 instances across 3 AZs, the cluster survives a full AZ outage.
resource "aws_docdb_cluster_instance" "replica_2" {
  identifier         = "docdb-lab-replica-2"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id
  instance_class     = "db.t3.medium"

  # Third AZ — now we span all three AZs in the region.
  availability_zone = data.aws_availability_zones.available.names[2]

  auto_minor_version_upgrade = true

  # PROMOTION TIER: lowest priority for promotion (tier 2).
  promotion_tier = 2

  depends_on = [aws_docdb_cluster_instance.primary]

  tags = {
    Name = "docdb-lab-replica-2"
    Role = "replica"
  }
}
