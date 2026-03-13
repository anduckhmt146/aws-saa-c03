# =============================================================================
# LAB 34: AMAZON REDSHIFT — DATA WAREHOUSING
# =============================================================================
#
# SAA-C03 EXAM TOPICS COVERED:
#
# WHAT IS REDSHIFT?
#   - Fully managed PETABYTE-SCALE data warehouse (OLAP, not OLTP)
#   - Built on PostgreSQL — uses SQL, JDBC/ODBC, psql-compatible
#   - MPP (Massively Parallel Processing): distributes query work across nodes
#   - Columnar storage: compresses data by column, perfect for aggregations
#   - SAA-C03 KEY: Redshift = analytics/reporting on large structured datasets.
#     Do NOT use for high-concurrency transactional workloads (use RDS/Aurora).
#
# CLUSTER ARCHITECTURE — LEADER NODE + COMPUTE NODES:
#   Leader Node:
#     - Single node that receives client SQL queries
#     - Parses SQL, develops query execution plan, and coordinates compute nodes
#     - Aggregates results from compute nodes before returning to the client
#     - NOT billed separately (included with multi-node clusters at no extra cost)
#   Compute Nodes:
#     - Execute query steps assigned by the leader node in parallel (MPP)
#     - Each node divided into SLICES (parallel processing units per node)
#     - Directly store data in columnar format on local disk (DC2) or RMS (RA3)
#   Node Slices:
#     - dc2.large  = 2 slices per node
#     - ra3.xlplus = 4 slices per node
#     - ra3.4xlarge = 12 slices per node, ra3.16xlarge = 16 slices per node
#
# NODE TYPES (SAA-C03 KEY DECISION):
#   RA3 (Recommended — Managed Storage):
#     - Separates compute and storage via Redshift Managed Storage (RMS)
#     - Storage automatically scales on S3 with local NVMe SSD as cache layer
#     - Pay separately for compute hours AND storage used
#     - Resize cluster (add/remove nodes) without migrating data
#     - Types: ra3.xlplus, ra3.4xlarge, ra3.16xlarge
#     - SAA-C03: Choose RA3 when storage needs grow faster than compute needs
#
#   DC2 (Dense Compute):
#     - SSD-based, compute-optimized, fixed local storage
#     - dc2.large: 160 GB SSD, 2 vCPU — cheapest option for dev/test
#     - dc2.8xlarge: 2.56 TB SSD, 32 vCPU
#     - SAA-C03: DC2 = best price/performance for datasets < 1 TB, fixed size
#
#   DS2 (Dense Storage — LEGACY, do not use for new workloads):
#     - HDD-based, high storage capacity, low cost per GB
#     - Replaced by RA3 which offers same economics with managed storage
#     - SAA-C03: AWS recommends migrating existing DS2 clusters to RA3
#
# CLUSTER vs SERVERLESS (SAA-C03 DECISION):
#   Cluster (Provisioned):
#     - Provision specific node types and counts; always-on billing
#     - Full control: WLM queues, parameter groups, maintenance windows
#     - Supports Reserved Instances for 1- or 3-year cost savings
#     - Best for: sustained, predictable analytical workloads
#   Serverless:
#     - No cluster to manage; capacity auto-scales based on query load
#     - Billed per RPU-second only during query execution ($0 when idle)
#     - Managed via Namespace (storage/credentials) + Workgroup (compute/network)
#     - Best for: intermittent/ad-hoc queries, dev/test, unknown query patterns
#
# DISTRIBUTION STYLES (critical for query performance — high exam frequency):
#   KEY:
#     - Rows distributed to slices based on hash of the DISTKEY column value
#     - Rows sharing the same key value land on the same slice
#     - Co-located JOINs on that column require NO data movement across nodes
#     - Use on columns that are JOIN keys between large fact tables
#     - SAA-C03: KEY distribution eliminates data movement cost in large JOINs
#   ALL:
#     - A complete copy of the entire table on every slice of every node
#     - Any JOIN using this table requires NO data movement (table is already local)
#     - Best for small dimension/lookup tables (< a few GB)
#     - Cost: storage multiplied by total slice count; not suitable for large tables
#     - SAA-C03: ALL = small reference tables joined frequently with large fact tables
#   EVEN:
#     - Rows distributed round-robin across all slices
#     - Uniform distribution; no column dependency; no data skew
#     - Best for tables that are NOT joined with other large tables
#     - SAA-C03: EVEN = staging/temp tables; bulk loads; no JOIN requirement
#   AUTO:
#     - Redshift automatically chooses between ALL and EVEN based on table size
#     - Small tables → ALL; larger tables → EVEN
#     - SAA-C03: AUTO = reasonable default; let AWS decide for new tables
#
# SORT KEYS (improve query performance by enabling zone-map block skipping):
#   Zone Maps:
#     - Redshift stores min/max values for each 1 MB block on disk
#     - If a WHERE clause value falls outside a block's range, that block is skipped
#     - Sort keys maximize block skipping for range/equality filter queries
#   Compound Sort Key:
#     - Rows sorted by first column, then second, then third (like a B-tree index)
#     - Most effective when WHERE/ORDER BY/GROUP BY uses leading sort columns
#     - Performance degrades when queries skip the leading sort column
#     - Maintenance: VACUUM SORT to reclaim space after large loads/deletes
#     - SAA-C03: Compound sort key = predictable, fixed query filter patterns
#   Interleaved Sort Key:
#     - Equal weight given to each column in the sort key definition
#     - Effective when queries filter on ANY subset of the sort columns
#     - Higher VACUUM REINDEX cost to maintain sort order (write-heavy penalty)
#     - SAA-C03: Interleaved = ad-hoc queries with varied filter columns
#
# REDSHIFT SPECTRUM:
#   - Query S3 data directly via external schema/external tables (no ETL loading)
#   - External schema points to AWS Glue Data Catalog or Hive Metastore
#   - Spectrum layer uses its own fleet of nodes (separate from your cluster)
#   - Billed at $5 per TB of S3 data scanned (not per query time)
#   - Combine Spectrum (cold S3 data) + cluster tables (hot data) in one SQL query
#   - Optimize costs: use Parquet/ORC formats + date partitioning to reduce scan GB
#   - SAA-C03: Spectrum = extend your data warehouse to S3 data lake without loading
#
# ENHANCED VPC ROUTING:
#   - By default, COPY/UNLOAD/Spectrum traffic routes over the public AWS network
#   - Enhanced VPC Routing: forces all S3 traffic through YOUR VPC
#   - Required if cluster is in private subnet without NAT Gateway or internet route
#   - Enables fine-grained VPC controls: security groups, NACLs, S3 VPC endpoints
#   - SAA-C03: Enable for compliance/security; required when using S3 VPC endpoints
#
# ENCRYPTION:
#   - At-rest: AES-256 using AWS-managed key (aws/redshift) or customer CMK (KMS)
#   - In-transit: SSL/TLS for all client connections (enforce with require_ssl param)
#   - IMPORTANT: Encryption must be enabled at cluster creation; converting an
#     existing unencrypted cluster requires restore-from-snapshot to new cluster
#   - SAA-C03: encrypted=true + kms_key_id for customer-managed encryption key
#
# SNAPSHOT SCHEDULES & CROSS-REGION SNAPSHOTS:
#   - Automated snapshots: taken every 8 hours OR per 5 GB of data change
#   - Manual snapshots: user-initiated, retained until deleted
#   - Cross-region snapshot copy: configure on cluster for DR to a second region
#   - Snapshot schedules: cron/rate expressions to override default 8h frequency
#   - SAA-C03: Cross-region snapshots = Redshift DR strategy; snapshot → restore
#
# WORKLOAD MANAGEMENT (WLM):
#   Automatic WLM (default):
#     - AWS dynamically manages memory and concurrency per queue
#     - Up to 8 queues; system adjusts slots/memory based on workload
#     - Simplest option; recommended unless specific queue control is needed
#   Manual WLM:
#     - You define: number of queues, memory %, concurrency slots, query groups
#     - Allows priority routing: ETL jobs vs BI reports vs ad-hoc queries
#     - Configured via wlm_json_configuration parameter in a parameter group
#   Concurrency Scaling:
#     - Spins up additional temporary cluster capacity during query bursts
#     - Seamless to users; queries are routed automatically
#     - First 1 hour/day of scaling is free; billed per second after
#     - SAA-C03: Enable for unpredictable peak query volumes
#   Short Query Acceleration (SQA):
#     - Routes short-running queries to a dedicated sub-queue
#     - Prevents long-running ETL from blocking interactive queries
#
# REDSHIFT SERVERLESS ARCHITECTURE:
#   Namespace:
#     - Logical container for database objects, users, and schemas
#     - Holds storage layer, IAM roles, KMS key, and admin credentials
#     - Each namespace has its own isolated storage
#   Workgroup:
#     - Defines the compute environment: RPU capacity, network settings
#     - One workgroup per namespace; RPU range 8-512 (multiples of 8)
#     - Has its own VPC subnets, security groups, and endpoint
#   SAA-C03: Serverless auto-scales within your configured max RPU ceiling
#
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# SAA-C03: Use the default VPC for lab simplicity.
# In production, create a dedicated VPC with private subnets for the cluster.
data "aws_vpc" "default" {
  default = true
}

# Fetch all subnets in the default VPC.
# Redshift subnet group should span multiple AZs for node placement flexibility.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ===========================================================================================
# SECTION 1: SECURITY GROUP
# ===========================================================================================

# -----------------------------------------------------------------------------
# SECURITY GROUP: REDSHIFT CLUSTER
# -----------------------------------------------------------------------------
# SAA-C03: Redshift uses port 5439 — NOT the default PostgreSQL port 5432.
# This is a frequent exam distractor. Always use 5439 for Redshift SG rules.
# Restrict inbound to trusted CIDR ranges (VPC CIDR, app tier SG, bastion host).
# Never open 5439 to 0.0.0.0/0 in production — data warehouses hold sensitive data.

resource "aws_security_group" "redshift" {
  name        = "lab34-redshift-sg"
  description = "Security group for Redshift cluster - port 5439"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Redshift SQL access from within VPC (port 5439, not 5432)"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    # SAA-C03: Restrict to VPC CIDR; in production scope to app-tier SG only
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Outbound for Enhanced VPC Routing S3 traffic and Spectrum"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab34-redshift-sg"
  }
}

# ===========================================================================================
# SECTION 2: NETWORKING — SUBNET GROUP
# ===========================================================================================

# -----------------------------------------------------------------------------
# REDSHIFT SUBNET GROUP
# -----------------------------------------------------------------------------
# SAA-C03: A subnet group is required to launch a Redshift cluster in a VPC.
# Include subnets from at least 2 AZs so Redshift can choose placement.
# Note: A standard Redshift cluster lives in ONE AZ (not Multi-AZ by default).
# RA3 multi-AZ is available as a newer feature for RA3 node types.

resource "aws_redshift_subnet_group" "main" {
  name        = "lab34-redshift-subnet-group"
  description = "Subnet group for lab34 Redshift cluster spanning default VPC subnets"

  # All default VPC subnets span multiple AZs automatically
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "lab34-redshift-subnet-group"
  }
}

# ===========================================================================================
# SECTION 3: KMS ENCRYPTION KEY
# ===========================================================================================

# -----------------------------------------------------------------------------
# KMS KEY FOR REDSHIFT ENCRYPTION AT REST
# -----------------------------------------------------------------------------
# SAA-C03: Redshift encryption-at-rest options:
#   1. No encryption: not recommended for production
#   2. AWS-managed key (aws/redshift): default, no extra cost, less control
#   3. Customer-managed CMK (this lab): full control, cross-account capable
#   4. CloudHSM-backed key: highest compliance (FIPS 140-2 Level 3)
#
# CRITICAL: Encryption must be enabled at cluster creation time.
# To encrypt an existing unencrypted cluster you must restore from a snapshot
# into a NEW cluster that has encryption enabled — there is no in-place option.

resource "aws_kms_key" "redshift" {
  description             = "CMK for Redshift at-rest encryption - lab 34"
  deletion_window_in_days = 7

  # SAA-C03: Annual automatic key rotation is a security best practice
  # and often required for compliance frameworks (PCI-DSS, HIPAA, SOC2)
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # SAA-C03: Grant Redshift service permission to use the CMK for
        # GenerateDataKey (encrypt new data blocks) and Decrypt (read existing blocks)
        Sid    = "AllowRedshiftServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          # CreateGrant is required for Redshift to create grants for cluster nodes
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "lab34-redshift-cmk"
  }
}

resource "aws_kms_alias" "redshift" {
  name          = "alias/lab34-redshift"
  target_key_id = aws_kms_key.redshift.key_id
}

# ===========================================================================================
# SECTION 4: IAM — S3 AND SPECTRUM ACCESS ROLE
# ===========================================================================================

# -----------------------------------------------------------------------------
# IAM ROLE FOR REDSHIFT: S3 / SPECTRUM / GLUE ACCESS
# -----------------------------------------------------------------------------
# SAA-C03: Redshift clusters use attached IAM roles (not instance profiles) for:
#   - COPY command: bulk load data from S3 into Redshift tables
#   - UNLOAD command: export query results from Redshift to S3
#   - Redshift Spectrum: query S3 external tables via Glue Data Catalog
#   - Redshift ML: train and run SageMaker AutoPilot models from SQL
# The role is attached to the cluster via the iam_roles argument.
# Multiple roles can be attached (up to 10 per cluster).

resource "aws_iam_role" "redshift_s3" {
  name = "lab34-redshift-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "lab34-redshift-s3-role"
  }
}

resource "aws_iam_role_policy" "redshift_s3_access" {
  name = "lab34-redshift-s3-policy"
  role = aws_iam_role.redshift_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadForCOPY"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        # SAA-C03: In production, restrict to specific data lake bucket ARNs
        Resource = "*"
      },
      {
        Sid    = "S3WriteForUNLOAD"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "*"
      },
      {
        # SAA-C03: Glue permissions required for Redshift Spectrum to read
        # external table metadata from the Glue Data Catalog
        Sid    = "GlueForSpectrum"
        Effect = "Allow"
        Action = [
          "glue:CreateDatabase",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:CreateTable",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions"
        ]
        Resource = "*"
      }
    ]
  })
}

# ===========================================================================================
# SECTION 5: PARAMETER GROUP — WLM CONFIGURATION
# ===========================================================================================

# -----------------------------------------------------------------------------
# REDSHIFT PARAMETER GROUP WITH MANUAL WLM QUEUES
# -----------------------------------------------------------------------------
# SAA-C03: Parameter groups control cluster-level behavior.
# Key difference from RDS: Redshift parameter changes require a cluster REBOOT.
#
# WORKLOAD MANAGEMENT (WLM) — wlm_json_configuration parameter:
#
# AUTOMATIC WLM (auto_wlm: true):
#   - AWS dynamically manages memory allocation and concurrency per queue
#   - Up to 8 queues; system sets slots based on available memory and workload
#   - Simplest approach; recommended for most new clusters
#
# MANUAL WLM (auto_wlm not set, or auto_wlm: false):
#   - You explicitly define: memory %, concurrency slots, query group labels
#   - Allows hard partitioning of resources between workload types
#
# QUEUE PARAMETERS:
#   query_group           : SET query_group TO 'etl' routes queries to this queue
#   user_group            : DB users in this group always use this queue
#   memory_percent_to_use : % of cluster memory allocated to this queue
#   query_concurrency     : max number of simultaneous queries (1-50 per queue)
#   max_execution_time    : cancel queries running longer than N ms (0=unlimited)
#   concurrency_scaling   : "auto" enables burst capacity; "off" disables it
#
# QUEUE ROUTING (top to bottom, first match wins):
#   1. Superuser queue (auto-created, reserved for superuser queries)
#   2. User-defined queues (matched by user_group, then query_group)
#   3. Default queue (catches all unmatched queries; always last in JSON)

resource "aws_redshift_parameter_group" "main" {
  name        = "lab34-redshift-params"
  description = "Lab34 parameter group — manual WLM, SSL, activity logging"

  # SAA-C03: Parameter group family must match the engine version
  family = "redshift-1.0"

  # ── WLM JSON CONFIGURATION ───────────────────────────────────────────────
  parameter {
    name = "wlm_json_configuration"

    # SAA-C03: This JSON array defines 3 queues (ETL, BI, Default).
    # Total memory percentages must NOT exceed 100% (system reserves the rest).
    # The final queue in the array is always the default queue (no query_group).
    value = jsonencode([
      {
        # Queue 1: ETL / bulk loading
        # High memory allocation so COPY/INSERT can sort and hash large datasets.
        # Low concurrency: ETL jobs are memory-hungry; few concurrent jobs is correct.
        name                  = "ETL Queue"
        query_group           = ["etl", "copy", "bulk"]
        user_group            = ["etl_users", "glue_user"]
        memory_percent_to_use = 40
        query_concurrency     = 3
        # Concurrency scaling OFF for ETL — ETL is not user-facing; no need for burst
        concurrency_scaling = "off"
        # Cancel runaway ETL queries after 2 hours (7200000 ms)
        max_execution_time = 7200000
      },
      {
        # Queue 2: BI / interactive analytics
        # Lower memory per query but higher concurrency for many simultaneous BI users.
        # Enable concurrency scaling so burst BI load (e.g., end-of-month reports)
        # automatically spins up extra compute instead of queueing users.
        name                  = "BI Queue"
        query_group           = ["bi", "reports", "interactive"]
        user_group            = ["bi_users", "analysts", "tableau_user"]
        memory_percent_to_use = 40
        query_concurrency     = 10
        # SAA-C03: concurrency_scaling = "auto" handles BI peak load bursts
        # First 1 hour/day of scaling is FREE; then billed per scaled-second
        concurrency_scaling = "auto"
        # Cancel interactive queries after 5 minutes (300000 ms)
        max_execution_time = 300000
      },
      {
        # Default queue: catches all queries not matched above.
        # Remaining 20% of memory; 5 concurrency slots.
        # Note: Default queue must have no query_group or user_group keys.
        memory_percent_to_use = 20
        query_concurrency     = 5
        concurrency_scaling   = "off"
      }
    ])
  }

  # ── ACTIVITY LOGGING ─────────────────────────────────────────────────────
  parameter {
    # SAA-C03: Activity logging records all SQL statements to S3 for auditing.
    # Compliance use case: PCI-DSS requires logging all data access.
    # Requires an S3 logging bucket configured on the cluster (not shown here).
    name  = "enable_user_activity_logging"
    value = "true"
  }

  # ── SSL ENFORCEMENT ──────────────────────────────────────────────────────
  parameter {
    # SAA-C03: require_ssl = true enforces TLS for ALL client connections.
    # This is a data-in-transit encryption control (complements at-rest KMS).
    # Clients without SSL will receive a connection refused error.
    name  = "require_ssl"
    value = "true"
  }

  # ── CONCURRENCY SCALING LIMIT ────────────────────────────────────────────
  parameter {
    # SAA-C03: Set to 0 for this lab to prevent unexpected billing.
    # In production, set to 1-10 based on burst tolerance and budget.
    # This cluster-level cap applies across ALL queues with concurrency_scaling=auto.
    name  = "max_concurrency_scaling_clusters"
    value = "0"
  }

  tags = {
    Name = "lab34-redshift-params"
  }
}

# ===========================================================================================
# SECTION 6: REDSHIFT CLUSTER (PROVISIONED)
# ===========================================================================================

# -----------------------------------------------------------------------------
# REDSHIFT CLUSTER — SINGLE-NODE DC2.LARGE (COST-OPTIMIZED FOR LAB)
# -----------------------------------------------------------------------------
# SAA-C03: Key cluster arguments for the exam:
#   node_type       : hardware type; dc2.large = cheapest, good for < 160 GB data
#   cluster_type    : single-node (dev/test) or multi-node (production)
#   encrypted       : ALWAYS true in production; must be set at creation time
#   enhanced_vpc_routing : true routes S3 traffic through VPC (compliance)
#   publicly_accessible  : false in production; access via VPN or bastion host
#   iam_roles       : allows COPY, UNLOAD, Spectrum, Redshift ML operations
#   automated_snapshot_retention_period : 1-35 days; 0 disables automated snapshots

resource "aws_redshift_cluster" "main" {
  cluster_identifier = "lab34-redshift"
  database_name      = "labdb"
  master_username    = "labadmin"

  # SAA-C03: In production, fetch master password from Secrets Manager:
  #   master_password = jsondecode(
  #     data.aws_secretsmanager_secret_version.redshift.secret_string
  #   )["password"]
  master_password = "Lab34Passw0rd!"

  # SAA-C03: dc2.large = smallest/cheapest for dev/test (160 GB SSD, 2 slices)
  # In production, use ra3.xlplus or larger for managed storage scalability
  node_type    = "dc2.large"
  cluster_type = "single-node"

  # For multi-node production cluster:
  #   cluster_type    = "multi-node"
  #   number_of_nodes = 2  # minimum for multi-node; max 128

  # SAA-C03: At-rest encryption with customer-managed CMK
  encrypted  = true
  kms_key_id = aws_kms_key.redshift.arn

  # SAA-C03: Enhanced VPC Routing forces COPY/UNLOAD/Spectrum through the VPC.
  # Without this, traffic uses the Redshift public network (outside your VPC).
  # Enable when: cluster is in a private subnet, using S3 VPC endpoint, or
  # compliance policy requires all traffic to stay within the VPC boundary.
  enhanced_vpc_routing = true

  # Network placement
  cluster_subnet_group_name    = aws_redshift_subnet_group.main.name
  vpc_security_group_ids       = [aws_security_group.redshift.id]
  availability_zone            = "${data.aws_region.current.name}a"
  cluster_parameter_group_name = aws_redshift_parameter_group.main.name

  # SAA-C03: Attach IAM role for S3 COPY/UNLOAD and Spectrum Glue catalog access
  iam_roles = [aws_iam_role.redshift_s3.arn]

  # SAA-C03: publicly_accessible = false → no public IP; VPC-only access
  publicly_accessible = false

  # SAA-C03: Automated snapshots retained for 1 day (lab); use 7-14 days in prod
  automated_snapshot_retention_period = 1

  # SAA-C03: manual_snapshot_retention_period = -1 keeps manual snapshots forever
  manual_snapshot_retention_period = -1

  # SAA-C03: Choose a low-traffic maintenance window for minor version patches
  preferred_maintenance_window = "sun:05:00-sun:05:30"

  # SAA-C03: skip_final_snapshot = true for lab to avoid orphaned snapshot costs.
  # In production: skip_final_snapshot = false with a final_snapshot_identifier.
  skip_final_snapshot = true

  tags = {
    Name = "lab34-redshift-cluster"
  }
}

# ===========================================================================================
# SECTION 7: SNAPSHOT SCHEDULE
# ===========================================================================================

# -----------------------------------------------------------------------------
# REDSHIFT SNAPSHOT SCHEDULE
# -----------------------------------------------------------------------------
# SAA-C03: Snapshot schedules let you control WHEN automated snapshots occur,
# overriding the default every-8-hours behavior.
#
# Use cases:
#   - Align snapshot timing with ETL completion (e.g., snapshot after nightly load)
#   - Reduce snapshot frequency to lower S3 storage costs in dev environments
#   - Ensure a clean snapshot exists before each maintenance window
#
# Expression formats:
#   rate(N hours)                         → simple interval (e.g., rate(12 hours))
#   cron(min hr day month day-of-week yr) → e.g., cron(0 3 * * ? *) = 3 AM daily
#
# CROSS-REGION SNAPSHOT COPY (DR pattern — exam scenario):
#   Configure in cluster settings to automatically copy each snapshot to a
#   second region. RPO depends on snapshot frequency; RTO = cluster restore time.
#   SAA-C03: Cross-region snapshot copy = Redshift DR strategy for exam questions.

resource "aws_redshift_snapshot_schedule" "daily" {
  identifier  = "lab34-daily-snapshot"
  description = "Daily snapshot at midnight UTC for lab34 cluster"

  # Take a snapshot at 00:00 UTC every day
  definitions = ["cron(0 0 * * ? *)"]

  tags = {
    Name = "lab34-daily-snapshot-schedule"
  }
}

# Associate the snapshot schedule with our specific cluster.
# A cluster can have exactly one schedule; one schedule can serve multiple clusters.
resource "aws_redshift_snapshot_schedule_association" "main" {
  cluster_identifier  = aws_redshift_cluster.main.cluster_identifier
  schedule_identifier = aws_redshift_snapshot_schedule.daily.id
}

# ===========================================================================================
# SECTION 8: PAUSE / RESUME SCHEDULED ACTIONS (COST OPTIMIZATION)
# ===========================================================================================

# -----------------------------------------------------------------------------
# IAM ROLE FOR REDSHIFT SCHEDULER
# -----------------------------------------------------------------------------
# SAA-C03: The Redshift scheduler service needs an IAM role to call
# PauseCluster, ResumeCluster, and ResizeCluster APIs on your behalf.
# The trust policy principal is scheduler.redshift.amazonaws.com.
#
# PAUSE/RESUME USE CASE:
#   Pause dev/test clusters on Friday evening → resume Monday morning.
#   Saves ~2.5 days of compute cost per week (~36% reduction).
#   IMPORTANT: Only RA3 node types support pause/resume.
#   DC2 clusters (including this lab) will fail at execution time with
#   "UnsupportedOperationFault" — included here for exam awareness only.

resource "aws_iam_role" "redshift_scheduler" {
  name = "lab34-redshift-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.redshift.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "lab34-redshift-scheduler-role"
  }
}

resource "aws_iam_role_policy" "redshift_scheduler" {
  name = "lab34-redshift-scheduler-policy"
  role = aws_iam_role.redshift_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "redshift:PauseCluster",
          "redshift:ResumeCluster",
          "redshift:ResizeCluster"
        ]
        Resource = aws_redshift_cluster.main.arn
      }
    ]
  })
}

# Pause cluster Friday 10 PM UTC (end of business day in US East Coast = weekend begins)
resource "aws_redshift_scheduled_action" "pause_weekend" {
  name        = "lab34-pause-weekend"
  description = "Pause cluster Friday 10 PM UTC to avoid weekend compute charges"
  schedule    = "cron(0 22 ? * FRI *)"
  iam_role    = aws_iam_role.redshift_scheduler.arn

  target_action {
    pause_cluster {
      cluster_identifier = aws_redshift_cluster.main.cluster_identifier
    }
  }
}

# Resume cluster Monday 6 AM UTC (before US East business hours start)
resource "aws_redshift_scheduled_action" "resume_monday" {
  name        = "lab34-resume-monday"
  description = "Resume cluster Monday 6 AM UTC before business hours"
  schedule    = "cron(0 6 ? * MON *)"
  iam_role    = aws_iam_role.redshift_scheduler.arn

  target_action {
    resume_cluster {
      cluster_identifier = aws_redshift_cluster.main.cluster_identifier
    }
  }
}

# ===========================================================================================
# SECTION 9: REDSHIFT SERVERLESS — NAMESPACE + WORKGROUP
# ===========================================================================================

# -----------------------------------------------------------------------------
# REDSHIFT SERVERLESS: NAMESPACE
# -----------------------------------------------------------------------------
# SAA-C03: A namespace is the storage and identity layer of Redshift Serverless.
# It contains:
#   - Database objects: schemas, tables, views, stored procedures
#   - Users and groups (separate from IAM)
#   - Admin credentials (equivalent to cluster master_username/password)
#   - IAM roles attached for S3/Glue/Spectrum access
#   - KMS key for encryption
#   - Audit log export targets (CloudWatch log types)
#
# One namespace can have multiple workgroups (compute environments).
# Namespaces are isolated: storage in one namespace is NOT visible in another.
# SAA-C03: Namespace = "what data and who can access it"; Workgroup = "how much compute"

resource "aws_redshiftserverless_namespace" "main" {
  namespace_name = "lab34-serverless-ns"

  # Admin credentials for connecting to the serverless database
  admin_username      = "serverlessadmin"
  admin_user_password = "Lab34Serverless1!"

  # Default database created inside this namespace
  db_name = "serverlessdb"

  # SAA-C03: Attach the same S3/Glue role used by the provisioned cluster.
  # Serverless namespaces support the same IAM role attachment pattern.
  iam_roles = [aws_iam_role.redshift_s3.arn]

  # SAA-C03: Encrypt serverless storage with the same CMK as the cluster
  kms_key_id = aws_kms_key.redshift.arn

  # SAA-C03: log_exports controls which events are sent to CloudWatch Logs.
  #   useractivitylog: all SQL statements (for compliance auditing)
  #   userlog        : user creation, deletion, password changes
  #   connectionlog  : connect/disconnect events
  log_exports = ["useractivitylog", "userlog", "connectionlog"]

  tags = {
    Name = "lab34-serverless-namespace"
  }
}

# -----------------------------------------------------------------------------
# REDSHIFT SERVERLESS: WORKGROUP
# -----------------------------------------------------------------------------
# SAA-C03: A workgroup defines the COMPUTE layer of Redshift Serverless.
# Key settings:
#   base_capacity        : minimum RPUs always available (8-512, multiples of 8)
#                          Higher RPU = more memory + concurrency = faster queries
#                          Serverless auto-scales UP to 3x base during bursts
#   enhanced_vpc_routing : same concept as provisioned; forces S3 traffic through VPC
#   publicly_accessible  : false = VPC-only access (recommended for production)
#   subnet_ids           : which subnets the workgroup endpoint is deployed into
#   security_group_ids   : firewall rules (same port 5439 applies)
#
# EXAM COMPARISON — Serverless vs Provisioned:
#   Serverless → no idle cost, auto-scale, no WLM parameter groups to manage
#   Provisioned → Reserved Instances pricing, precise WLM queue control, pause/resume
#   SAA-C03: "minimize management overhead for sporadic queries" → Serverless
#   SAA-C03: "predictable sustained workload, cost optimization" → Provisioned + RI

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "lab34-serverless-wg"

  # SAA-C03: 8 RPU is the minimum; sufficient for lab/dev.
  # Production recommendation: 32+ RPU for acceptable query performance.
  base_capacity = 8

  # SAA-C03: Keep enhanced VPC routing OFF for this lab (no VPC endpoint configured).
  # In production with a private subnet + S3 VPC endpoint: set to true.
  enhanced_vpc_routing = false

  # Place workgroup endpoint in the default VPC subnets
  subnet_ids         = data.aws_subnets.default.ids
  security_group_ids = [aws_security_group.redshift.id]

  # SAA-C03: VPC-only access; no public endpoint
  publicly_accessible = false

  tags = {
    Name = "lab34-serverless-workgroup"
  }
}

# =============================================================================
# REDSHIFT SPECTRUM — QUERY S3 WITHOUT LOADING DATA (EXAM REFERENCE)
# =============================================================================
#
# SAA-C03: Redshift Spectrum extends your cluster to query data directly in S3
# using an external schema that maps to the AWS Glue Data Catalog.
#
# ARCHITECTURE FLOW:
#   Redshift cluster leader node
#       ↓ pushes predicate filters
#   Spectrum layer (independent AWS-managed fleet of nodes)
#       ↓ scans S3 in parallel, returns filtered results
#   Redshift cluster
#       ↓ JOIN with local tables, final aggregations
#   SQL client receives results
#
# SETUP STEPS (performed in SQL after cluster is running — not Terraform):
#
# Step 1: Attach the IAM role to the cluster (done via iam_roles above)
#
# Step 2: Create an external schema pointing to Glue Data Catalog
#   CREATE EXTERNAL SCHEMA spectrum_schema
#   FROM DATA CATALOG
#   DATABASE 'my_glue_database'
#   IAM_ROLE 'arn:aws:iam::ACCOUNT:role/lab34-redshift-s3-role'
#   CREATE EXTERNAL DATABASE IF NOT EXISTS;
#
# Step 3: Create an external table (or let Glue crawler create it)
#   CREATE EXTERNAL TABLE spectrum_schema.sales_history (
#     order_id    BIGINT,
#     customer_id BIGINT,
#     order_date  DATE,
#     amount      DECIMAL(12,2)
#   )
#   STORED AS PARQUET                            -- columnar format = less S3 scanned
#   LOCATION 's3://my-data-lake/sales/year=2023/'
#   TABLE PROPERTIES ('classification'='parquet');
#
# Step 4: Query across Redshift cluster tables + Spectrum S3 tables in one SQL
#   SELECT c.customer_name, SUM(s.amount) AS total_spend
#   FROM redshift_local.customers c                  -- local cluster table
#   JOIN spectrum_schema.sales_history s             -- Spectrum = reads from S3
#     ON c.customer_id = s.customer_id
#   WHERE s.order_date BETWEEN '2023-01-01' AND '2023-12-31'
#   GROUP BY 1
#   ORDER BY 2 DESC;
#
# COST OPTIMIZATION FOR SPECTRUM:
#   - Use PARQUET or ORC format   → only columns needed are scanned (columnar)
#   - Partition tables by date    → Spectrum only reads matching partitions
#   - Use predicate pushdown      → WHERE filters applied at the S3 read layer
#   - Compress files (Snappy/GZIP) → reduces bytes scanned
#   SAA-C03: Parquet + date partitioning can reduce Spectrum costs by 90%+ vs CSV
#
# =============================================================================
