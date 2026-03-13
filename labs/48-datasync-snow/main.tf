# =============================================================================
# LAB 48: DataSync + Snow Family + Transfer Family
# AWS SAA-C03 Study Lab
# =============================================================================
#
# WHAT THIS LAB COVERS:
#   - AWS DataSync: online data transfer with scheduling and verification
#   - Snow Family: offline data transfer for large-scale migrations
#   - AWS Transfer Family: managed SFTP/FTPS/FTP backed by S3 or EFS
#   - Decision framework for choosing the right migration/transfer service
#
# =============================================================================
# DATASYNC OVERVIEW (SAA-C03 core service)
# =============================================================================
#
# AWS DataSync is an online data movement and discovery service.
# It transfers data between on-premises storage and AWS storage services.
#
# HOW IT WORKS:
#   1. Deploy a DataSync agent (VM appliance or container) on-premises or in EC2
#   2. The agent connects to your source storage (NFS, SMB, HDFS, etc.)
#   3. You create "locations" (source and destination) in the DataSync console
#   4. You create a "task" linking source → destination with transfer options
#   5. Run the task once or on a recurring schedule
#
# SUPPORTED SOURCES (on-premises or cloud):
#   - NFS (Network File System)  — Linux file servers, NAS devices
#   - SMB (Server Message Block) — Windows file servers
#   - HDFS (Hadoop HDFS)         — Hadoop cluster data
#   - Object storage             — S3-compatible APIs (MinIO, etc.)
#   - Azure Blob Storage         — (as a source, to migrate to AWS)
#   - Google Cloud Storage       — (as a source, to migrate to AWS)
#
# SUPPORTED DESTINATIONS (AWS):
#   - Amazon S3          — any storage class (Standard, IA, Glacier, etc.)
#   - Amazon EFS         — POSIX file system, Linux workloads
#   - FSx for Windows    — SMB workloads, AD integration
#   - FSx for Lustre     — HPC workloads
#   - FSx ONTAP          — NFS + SMB + iSCSI (NetApp compatibility)
#   - FSx OpenZFS        — NFS + ZFS dataset compatibility
#
# KEY FEATURES:
#   Checksum verification:   DataSync computes and verifies checksums end-to-end
#   Incremental transfers:   subsequent runs only copy changed/new files
#   Scheduling:              run once or on a cron-like schedule
#   Filtering:               include/exclude files by pattern
#   Encryption:              TLS in transit (over internet or Direct Connect)
#   Bandwidth throttling:    set max transfer rate to protect network capacity
#   Logging:                 per-file transfer log to CloudWatch
#   Performance:             up to 10 Gbps per agent; parallel multi-threading
#
# =============================================================================
# DATASYNC vs SIMILAR SERVICES (SAA-C03 comparison matrix)
# =============================================================================
#
#   SERVICE               | BEST FOR                         | KEY DIFFERENTIATOR
#   ----------------------|----------------------------------|-------------------
#   DataSync              | Structured migration, scheduling | Checksum, incremental, schedules
#   S3 Transfer Accel     | Fast S3 PUT/GET from far away    | Edge locations for upload speed
#   Storage Gateway       | Ongoing hybrid access (not one-off) | Local cache, NFS/SMB to S3
#   Snow Family           | >10 TB offline transfers         | Physical device, no internet needed
#   Direct Connect        | Dedicated network, not data sync | Network, not a data mover
#   S3 Replication        | S3→S3 cross-region/account       | Only between S3 buckets
#
#   SAA-C03 DECISION RULES:
#   "Migrate 50 TB NFS to S3 with scheduling and verification" → DataSync
#   "Upload large files faster via internet to S3"            → S3 Transfer Acceleration
#   "Ongoing shared access to on-prem file server from AWS"   → Storage Gateway
#   "500 TB migration, bandwidth limited / no internet"       → Snowball
#   "Replace on-prem SFTP server"                             → Transfer Family
#
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# NETWORKING: VPC for DataSync and EFS
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
    Lab  = "48-datasync-snow"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${var.project_name}-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${var.project_name}-private-b"
  }
}

# Security group for DataSync agent and EFS mount targets
resource "aws_security_group" "datasync" {
  name        = "${var.project_name}-datasync-sg"
  description = "Security group for DataSync agent and EFS access"
  vpc_id      = aws_vpc.main.id

  # DataSync agent communicates with AWS DataSync service endpoints
  # All outbound is needed for the agent to reach the DataSync API
  egress {
    description = "All outbound for DataSync agent"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # EFS NFS port — DataSync needs this to mount the EFS destination
  ingress {
    description = "NFS for EFS mount"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    self        = true
  }

  tags = {
    Name = "${var.project_name}-datasync-sg"
  }
}

# =============================================================================
# S3 BUCKET: Migration source (simulates on-premises NFS server for this lab)
# =============================================================================
# In a real on-premises-to-AWS migration, the source would be an NFS or SMB
# share accessed via a DataSync agent. This S3 bucket serves as a stand-in
# so the lab can be deployed without on-premises infrastructure.
#
# SAA-C03: When the source IS on-premises NFS/SMB, you must deploy a DataSync
# agent VM on-premises. The agent mounts the source filesystem and streams
# data to the DataSync service endpoint over TLS (outbound HTTPS only).
# No agent is needed for S3-to-S3, EFS-to-S3, or other cloud-to-cloud transfers.

resource "aws_s3_bucket" "migration_source" {
  bucket = "${var.project_name}-source-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-source"
    Purpose = "Simulated on-premises NFS source for DataSync lab"
    Lab     = "48-datasync-snow"
  }
}

resource "aws_s3_bucket_public_access_block" "migration_source" {
  bucket                  = aws_s3_bucket.migration_source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# S3 BUCKET: Migration destination
# =============================================================================
# DataSync writes migrated files here. Also used by Transfer Family users.
# SAA-C03: DataSync can write to any S3 storage class.
# For archival migrations, use S3 Glacier Instant Retrieval or Glacier Deep Archive.

resource "aws_s3_bucket" "migration_destination" {
  bucket = "${var.project_name}-migration-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-migration-destination"
    Purpose = "DataSync and Transfer Family destination"
    Lab     = "48-datasync-snow"
  }
}

resource "aws_s3_bucket_versioning" "migration_destination" {
  bucket = aws_s3_bucket.migration_destination.id
  versioning_configuration {
    status = "Enabled" # Protect against accidental overwrites during migration
  }
}

# Lifecycle policy: automatically transition objects to cheaper storage classes
# after migration is complete — common SAA-C03 cost optimization pattern
resource "aws_s3_bucket_lifecycle_configuration" "migration_destination" {
  bucket = aws_s3_bucket.migration_destination.id

  rule {
    id     = "archive-after-migration"
    status = "Enabled"

    # Move to Infrequent Access after 30 days (cheaper, same durability)
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # Move to Glacier for long-term archive after 90 days
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# Block all public access — migration buckets should never be public
resource "aws_s3_bucket_public_access_block" "migration_destination" {
  bucket                  = aws_s3_bucket.migration_destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# IAM ROLE: DataSync access to S3
# =============================================================================
# DataSync assumes this role to write objects to the S3 destination bucket.
# The role must trust the datasync.amazonaws.com service principal.

resource "aws_iam_role" "datasync_s3" {
  name = "${var.project_name}-datasync-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "datasync.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-datasync-s3-role"
  }
}

resource "aws_iam_role_policy" "datasync_s3" {
  name = "${var.project_name}-datasync-s3-policy"
  role = aws_iam_role.datasync_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read access on the source bucket (DataSync reads from here)
      {
        Sid    = "S3SourceReadAccess"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:GetObjectVersion"
        ]
        Resource = [
          aws_s3_bucket.migration_source.arn,
          "${aws_s3_bucket.migration_source.arn}/*"
        ]
      },
      # Full access on the destination bucket (DataSync writes here)
      {
        Sid    = "S3DestinationAccess"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging"
        ]
        Resource = [
          aws_s3_bucket.migration_destination.arn,
          "${aws_s3_bucket.migration_destination.arn}/*"
        ]
      }
    ]
  })
}

# =============================================================================
# DATASYNC AGENT
# =============================================================================
# The DataSync agent is a VM appliance (OVA) deployed on-premises or as an
# EC2 instance. It acts as the "bridge" between your source storage and AWS.
#
# AGENT DEPLOYMENT OPTIONS:
#   On-premises VMware ESXi   → download OVA from AWS, deploy as VM
#   On-premises KVM/Hyper-V   → download image, deploy as VM
#   EC2 instance              → launch AMI from AWS Marketplace (for cloud-to-cloud)
#   AWS Snowcone              → DataSync agent pre-installed on the device
#
# ACTIVATION PROCESS (NOT automated by Terraform — requires manual steps):
#   1. Deploy the agent VM/EC2
#   2. Get the agent's IP address
#   3. In the browser: http://<agent-ip> to get an activation key
#   4. Use the activation key in aws_datasync_agent resource below
#   5. The agent "phones home" to the DataSync service and registers
#
# The activation_key variable below is a placeholder.
# In a real deployment you would obtain this key from the agent UI.
#
# SAA-C03 NOTE: You don't need to know the activation steps by heart,
# but you DO need to know: DataSync requires an agent for on-prem sources.
# No agent needed for S3-to-S3 or EFS-to-S3 transfers (cloud-to-cloud).

resource "aws_datasync_agent" "on_prem" {
  # activation_key is obtained by visiting http://<agent-ip>/?gatewayType=SYNC
  # This key is time-sensitive (expires in ~10 minutes after generation)
  activation_key = "PLACEHOLDER-ACTIVATION-KEY"
  name           = "${var.project_name}-agent"

  # Tagging agents helps identify which site/location each agent serves
  tags = {
    Name     = "${var.project_name}-on-prem-agent"
    Location = "datacenter-primary"
    Lab      = "48-datasync-snow"
  }

  # NOTE: This resource will fail with a placeholder key.
  # Replace with a real activation key from a deployed DataSync agent.
  # For lab purposes, comment out this resource and the NFS location below
  # if you don't have an agent deployed.
  lifecycle {
    ignore_changes = [activation_key]
  }
}

# =============================================================================
# DATASYNC LOCATION: S3 Source (simulates on-premises NFS source for this lab)
# =============================================================================
# In a real migration from on-premises NFS, use aws_datasync_location_nfs instead.
# This S3 source location lets the lab run without an on-premises agent.
# See the commented aws_datasync_location_nfs block below for the real-world pattern.

resource "aws_datasync_location_s3" "source" {
  s3_bucket_arn = aws_s3_bucket.migration_source.arn
  subdirectory  = "/data"

  s3_config {
    bucket_access_role_arn = aws_iam_role.datasync_s3.arn
  }

  tags = {
    Name = "${var.project_name}-s3-source"
    Type = "source"
  }
}

# =============================================================================
# DATASYNC LOCATION: NFS Source (on-premises)
# =============================================================================
# Represents the on-premises NFS server that DataSync will read from.
# The agent mounts this NFS share and reads files from it.
#
# SUPPORTED NFS VERSIONS: NFSv3, NFSv4, NFSv4.1
# The on-prem NFS server must allow the agent's IP in its export rules.
#
# Mount options you can configure:
#   version: NFSv3 (default), NFSv4, NFSv4.1
#
# SAA-C03 SCENARIO: "Migrate 10 TB NFS share from on-premises to S3"
#   Answer: Deploy DataSync agent → create NFS location → create S3 location
#           → create DataSync task → run task

resource "aws_datasync_location_nfs" "source" {
  # The hostname or IP of the on-prem NFS server
  server_hostname = "192.168.1.100" # Replace with actual NFS server IP

  # The NFS export path to mount on the agent
  subdirectory = "/exports/data" # Replace with actual export path

  on_prem_config {
    # The DataSync agent(s) that will mount and read this NFS share
    # You can specify multiple agents for higher throughput
    agent_arns = [aws_datasync_agent.on_prem.arn]
  }

  mount_options {
    version = "AUTOMATIC" # Let DataSync negotiate the best NFS version
  }

  tags = {
    Name = "${var.project_name}-nfs-source"
    Type = "source"
  }
}

# =============================================================================
# DATASYNC LOCATION: S3 Destination
# =============================================================================
# Represents the S3 bucket where DataSync will write transferred files.
# No agent needed for S3 destinations — DataSync connects directly.
#
# S3 STORAGE CLASS OPTIONS (choose based on access frequency after migration):
#   STANDARD             — frequently accessed data (default)
#   STANDARD_IA          — infrequently accessed, fast retrieval
#   ONEZONE_IA           — IA but single AZ (lower cost, lower availability)
#   INTELLIGENT_TIERING  — auto-moves objects between tiers based on access
#   GLACIER              — archive, retrieval in minutes to hours
#   DEEP_ARCHIVE         — cheapest archive, 12-hour retrieval
#
# SAA-C03 TIP: Choosing the right destination storage class at DataSync task
# creation time avoids needing a separate S3 lifecycle policy post-migration.

resource "aws_datasync_location_s3" "destination" {
  s3_bucket_arn = aws_s3_bucket.migration_destination.arn

  # The prefix (folder path) within the bucket where DataSync writes files
  subdirectory = "/migrated-nfs-data"

  # Storage class for objects written by DataSync
  # STANDARD_IA saves ~46% vs STANDARD for data not accessed frequently after migration
  s3_storage_class = "STANDARD_IA"

  s3_config {
    # IAM role that DataSync assumes to write to S3
    bucket_access_role_arn = aws_iam_role.datasync_s3.arn
  }

  tags = {
    Name = "${var.project_name}-s3-destination"
    Type = "destination"
  }
}

# =============================================================================
# EFS FILE SYSTEM: Alternative migration destination
# =============================================================================
# EFS (Elastic File System) provides POSIX-compliant NFS storage in AWS.
# Use EFS as a DataSync destination when:
#   - Your apps need NFS mount access after migration (no refactoring needed)
#   - You're migrating Linux workloads that use file permissions/ownership
#   - Multiple EC2 instances need simultaneous access to the migrated data
#
# SAA-C03 COMPARISON:
#   S3 as destination  → cheaper storage, object-based, no NFS mount in apps
#   EFS as destination → more expensive, NFS mount in apps works unchanged
#   FSx for Windows    → use when migrating Windows SMB file shares
#   FSx for Lustre     → use for HPC/ML workloads needing high-throughput NFS

resource "aws_efs_file_system" "migration_destination" {
  encrypted = true # Encryption at rest — always enable for compliance

  performance_mode = "generalPurpose" # Options: generalPurpose (default), maxIO (>thousands of clients)
  throughput_mode  = "elastic"        # Options: bursting (default), provisioned, elastic

  tags = {
    Name    = "${var.project_name}-efs-destination"
    Purpose = "Migration destination for NFS workloads"
    Lab     = "48-datasync-snow"
  }
}

# EFS mount target: allows EC2 instances in the subnet to mount EFS
# DataSync also uses this to write to EFS
resource "aws_efs_mount_target" "migration_destination_a" {
  file_system_id  = aws_efs_file_system.migration_destination.id
  subnet_id       = aws_subnet.private_a.id
  security_groups = [aws_security_group.datasync.id]
}

# =============================================================================
# DATASYNC LOCATION: EFS Destination
# =============================================================================
# Represents the EFS file system as a DataSync destination.
# DataSync connects to EFS via an NFS mount target in your VPC.
# No agent needed — DataSync connects directly to EFS.

resource "aws_datasync_location_efs" "destination" {
  efs_file_system_arn = aws_efs_file_system.migration_destination.arn

  # The path within EFS where DataSync writes files
  subdirectory = "/migrated-data"

  ec2_config {
    # DataSync uses this subnet and security group to mount the EFS file system
    subnet_arn          = aws_subnet.private_a.arn
    security_group_arns = [aws_security_group.datasync.arn]
  }

  # Wait for the mount target to be ready before creating the EFS location
  depends_on = [aws_efs_mount_target.migration_destination_a]

  tags = {
    Name = "${var.project_name}-efs-destination"
    Type = "destination"
  }
}

# =============================================================================
# DATASYNC TASK: NFS → S3 migration
# =============================================================================
# A task ties together:
#   - Source location  (where to read FROM)
#   - Destination loc. (where to write TO)
#   - Transfer options (what to do, how to verify, what to log)
#   - Schedule        (when to run)
#
# TRANSFER MODES:
#   CHANGED:  only transfer files that changed since last task execution (incremental)
#   ALL:      transfer all files every run regardless of change detection
#
# VERIFY MODES:
#   ONLY_FILES_TRANSFERRED: verify checksums only for files transferred this run
#   ALL:                    verify ALL files in destination after each run (slow but thorough)
#   NONE:                   no checksum verification (fastest, not recommended)
#
# PRESERVE OPTIONS:
#   PRESERVE_DELETED_FILES: if a file was deleted from source, keep it in destination
#   REMOVE:                 mirror deletions from source to destination (sync mode)
#
# SAA-C03: DataSync is the answer for "migrate with checksum verification" and
# "incremental scheduled transfers" — these specific capabilities distinguish it
# from simple cp/rsync or S3 sync approaches.

resource "aws_datasync_task" "nfs_to_s3" {
  name                     = "${var.project_name}-nfs-to-s3"
  source_location_arn      = aws_datasync_location_nfs.source.arn
  destination_location_arn = aws_datasync_location_s3.destination.arn

  # CloudWatch log group for per-file transfer logs
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.datasync.arn

  options {
    # Only transfer files that are new or modified since the last run
    # CHANGED mode is the default and most efficient for ongoing/recurring transfers
    transfer_mode = "CHANGED"

    # Checksum verification: verify integrity of transferred files
    # ONLY_FILES_TRANSFERRED = fast, verifies only what was transferred this run
    # ALL = verifies everything in the destination (use for final validation pass)
    verify_mode = "ONLY_FILES_TRANSFERRED"

    # What to do if a file in the source was deleted since last run:
    # PRESERVE = keep the file in the destination (safe default)
    # REMOVE   = delete from destination too (true sync/mirror behavior)
    preserve_deleted_files = "PRESERVE"

    # POSIX metadata: preserve Linux file permissions, ownership (UID/GID), timestamps
    # Important when migrating Linux workloads where file permissions matter
    posix_permissions = "PRESERVE"
    uid               = "INT_VALUE" # Preserve numeric UID (not mapped)
    gid               = "INT_VALUE" # Preserve numeric GID (not mapped)

    # Preserve modification timestamps on transferred files
    mtime = "PRESERVE"

    # How verbose to be in CloudWatch transfer logs
    # TRANSFER = log only transferred files (most common)
    # ALL      = log every file checked (very verbose, expensive for large datasets)
    # OFF      = no per-file logging
    log_level = "TRANSFER"

    # Bandwidth limit (bytes per second per agent)
    # -1 = no limit (use all available bandwidth)
    # Set a positive value to avoid saturating your WAN link during business hours
    bytes_per_second = -1
  }

  # Schedule: run the task automatically on a recurring basis
  # Uses cron syntax — runs every day at 2 AM UTC (off-peak hours)
  # SAA-C03: scheduled DataSync = "automated recurring migration" scenario
  schedule {
    schedule_expression = "cron(0 2 * * ? *)" # Daily at 02:00 UTC
  }

  # Filter rules: include/exclude specific files or directories
  # Include only .csv and .json files (exclude everything else)
  includes {
    filter_type = "SIMPLE_PATTERN"
    value       = "*.csv|*.json" # Include patterns (pipe-separated)
  }

  # Exclude temp files and hidden directories
  excludes {
    filter_type = "SIMPLE_PATTERN"
    value       = "*.tmp|*/.git/*|*/node_modules/*" # Exclude patterns
  }

  tags = {
    Name       = "${var.project_name}-nfs-to-s3-task"
    SourceType = "NFS"
    DestType   = "S3"
  }

  depends_on = [
    aws_datasync_location_nfs.source,
    aws_datasync_location_s3.destination
  ]
}

# CloudWatch log group for DataSync task logs
resource "aws_cloudwatch_log_group" "datasync" {
  name              = "/aws/datasync/${var.project_name}"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-datasync-logs"
  }
}

# =============================================================================
# SNOW FAMILY OVERVIEW (SAA-C03 — cannot be provisioned via Terraform)
# =============================================================================
# Snow Family devices are physical appliances ordered through the AWS Console.
# Terraform CANNOT provision physical hardware, but the concepts below are
# critical for the SAA-C03 exam.
#
# ----------------------------------------------------------------------------
# DEVICE COMPARISON TABLE
# ----------------------------------------------------------------------------
#
#   DEVICE                      | STORAGE     | COMPUTE             | USE CASE
#   ----------------------------|-------------|---------------------|---------------------------
#   Snowcone (HDD)              | 8 TB usable | 2 vCPU, 4 GB RAM    | Edge data collection, small migration
#   Snowcone (SSD)              | 14 TB usable| 2 vCPU, 4 GB RAM    | Edge + slightly more storage
#   Snowball Edge Stor. Opt.    | 80 TB usable| 40 vCPUs, 80 GB RAM | Large-scale data center migration
#   Snowball Edge Compute Opt.  | 42 TB usable| 52 vCPUs, 208 GB RAM| Edge computing + moderate migration
#   Snowball Edge Compute + GPU | 42 TB usable| 52 vCPUs + NVIDIA V100 GPU | ML inference at the edge
#   Snowmobile                  | 100 PB      | N/A (truck)         | Exabyte-scale data center migration
#
# ----------------------------------------------------------------------------
# SAA-C03 DECISION TREE FOR DATA MIGRATION
# ----------------------------------------------------------------------------
#
#   How much data needs to be migrated?
#
#   < 10 TB:
#     → Use DataSync (online) or S3 direct upload
#     → Internet bandwidth is sufficient
#
#   10 TB – 10 PB (and bandwidth is limited / migration window is short):
#     → Snowball Edge (order 1 or more devices)
#     → Rule of thumb: if DataSync would take > 1 week, consider Snowball
#
#   > 10 PB (or entire data center):
#     → Snowmobile (AWS sends a truck with a 100 PB container)
#     → Requires coordination with AWS account team
#
#   Remote/disconnected location (no internet or limited connectivity):
#     → Snowcone: portable, rugged, fits in a backpack
#     → Snowball Edge: larger, for field offices or ships
#
#   Edge computing needed (run workloads where data is created):
#     → Snowball Edge Compute Optimized or Compute + GPU
#     → Supports EC2 instances and Lambda via "Local Compute and Storage"
#
# ----------------------------------------------------------------------------
# SNOWCONE SPECIFICS (SAA-C03 exam favorite)
# ----------------------------------------------------------------------------
#
#   - Smallest Snow device (2.1 kg / 4.5 lbs)
#   - Available as Snowcone (8 TB HDD) and Snowcone SSD (14 TB)
#   - Pre-installed with a DataSync agent
#   - Can transfer data ONLINE via DataSync (when connected to internet)
#     OR offline (ship the device back to AWS)
#   - Use case: collect data in the field, on a ship, in a remote office
#   - Powers via standard USB-C
#   - Works with OpsHub GUI for management
#
#   SAA-C03 TIP: "edge location with limited bandwidth + DataSync agent pre-installed"
#   → Snowcone
#
# ----------------------------------------------------------------------------
# SNOWBALL EDGE STORAGE OPTIMIZED
# ----------------------------------------------------------------------------
#
#   - 80 TB usable HDD storage
#   - 40 vCPUs, 80 GB RAM (for lightweight edge compute)
#   - S3-compatible API on device for local app access
#   - NFS/SMB mount point support
#   - Cluster mode: up to 15 nodes (petabyte-scale local storage)
#   - Best for: large data center migrations (> 10 TB)
#
# ----------------------------------------------------------------------------
# SNOWBALL EDGE COMPUTE OPTIMIZED
# ----------------------------------------------------------------------------
#
#   - 42 TB usable storage
#   - 52 vCPUs, 208 GB RAM (serious edge compute capability)
#   - Optional NVIDIA Tesla V100 GPU variant for ML inference
#   - Supports EC2-compatible instances and Lambda functions at the edge
#   - Best for: edge machine learning, video analysis, data preprocessing
#   - Best for: moderate data migration + edge compute in same device
#
# ----------------------------------------------------------------------------
# SNOWMOBILE
# ----------------------------------------------------------------------------
#
#   - AWS 45-foot shipping container on a semi-truck
#   - Up to 100 PB storage capacity
#   - Requires: GPS tracking, 24/7 security, dedicated fiber connection to your DC
#   - AWS drives the truck to your data center, you load data, AWS drives it back
#   - Ingest time: several weeks to load, plus shipping time
#   - Best for: entire data center evacuation, cloud migration projects
#
#   SAA-C03 RULE: If data exceeds 100 TB and time/bandwidth makes online transfer
#   impractical, choose Snowball. If it's exabyte-scale (hundreds of PB), Snowmobile.
#
# ----------------------------------------------------------------------------
# OPSHUB (Management GUI)
# ----------------------------------------------------------------------------
#
#   - Desktop application for managing Snow Family devices
#   - No AWS console access required (works offline)
#   - Can unlock devices, launch EC2 instances, monitor storage, configure networking
#   - SAA-C03: "manage Snow device without internet" → OpsHub
#
# ----------------------------------------------------------------------------
# SNOW FAMILY ORDERING PROCESS
# ----------------------------------------------------------------------------
#
#   1. Open AWS Console → Snow Family → Order a device
#   2. Choose device type, capacity, shipping speed
#   3. Configure: storage capacity, compute resources, S3 bucket destination
#   4. AWS ships the device to your address (typically 1-2 weeks)
#   5. You connect the device to your local network
#   6. Use OpsHub or CLI to unlock the device and start copying data
#   7. Copy data using: S3 CLI, NFS mount, or DataSync agent on device
#   8. Ship the device back to AWS (prepaid label included)
#   9. AWS ingests the data to S3 (or the configured service)
#   10. AWS wipes the device after ingestion (NIST 800-88 media sanitization)
#
# ----------------------------------------------------------------------------
# ILLUSTRATIVE TERRAFORM (commented out — physical device, cannot provision)
# ----------------------------------------------------------------------------
#
# If Snow devices could be Terraformed, it might look like this:
#
# resource "aws_snowball_job" "migration" {
#   # This resource does NOT exist in the Terraform AWS provider.
#   # Snow devices must be ordered via the AWS Console or AWS CLI.
#   #
#   # aws snowball create-job \
#   #   --job-type IMPORT \
#   #   --resources '{
#   #     "S3Resources": [{
#   #       "BucketArn": "arn:aws:s3:::my-migration-bucket",
#   #       "KeyRange": {}
#   #     }]
#   #   }' \
#   #   --description "Data center migration Q1 2026" \
#   #   --address-id "ADID1234567890abcde" \
#   #   --kms-key-arn "arn:aws:kms:us-east-1:123456789012:key/..." \
#   #   --role-arn "arn:aws:iam::123456789012:role/SnowballImportRole" \
#   #   --snowball-type STANDARD \
#   #   --shipping-option NEXT_DAY
# }
#
# You CAN use Terraform to prepare the AWS-side resources that a Snow job needs:
#   - S3 bucket to receive imported data (see aws_s3_bucket.migration_destination above)
#   - IAM role for Snowball import
#   - KMS key for device encryption
#
# resource "aws_iam_role" "snowball_import" {
#   name = "snowball-import-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect    = "Allow"
#       Principal = { Service = "importexport.amazonaws.com" }
#       Action    = "sts:AssumeRole"
#     }]
#   })
# }
#
# resource "aws_iam_role_policy_attachment" "snowball_s3" {
#   role       = aws_iam_role.snowball_import.name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
# }

# =============================================================================
# AWS TRANSFER FAMILY
# =============================================================================
# AWS Transfer Family provides managed SFTP, FTPS, FTP, and AS2 servers
# backed by Amazon S3 or EFS as the storage layer.
#
# HOW IT WORKS:
#   - AWS runs the server endpoint (no EC2 to manage)
#   - Your SFTP clients connect to <server-id>.server.transfer.<region>.amazonaws.com
#   - Files uploaded via SFTP are stored directly in S3 or EFS
#   - Files downloaded via SFTP are read directly from S3 or EFS
#
# PROTOCOLS SUPPORTED:
#   SFTP  — SSH File Transfer Protocol (port 22) — most common
#   FTPS  — FTP over TLS (port 21 + data ports)  — legacy partner integration
#   FTP   — unencrypted FTP (port 21)             — legacy, avoid if possible
#   AS2   — Applicability Statement 2             — EDI/B2B file exchange
#
# ENDPOINT TYPES:
#   PUBLIC   — publicly accessible endpoint (easiest, no VPC setup)
#   VPC      — endpoint inside your VPC (private or internet-facing via VPC)
#   VPC_ENDPOINT — deprecated alias for VPC type
#
# AUTHENTICATION OPTIONS:
#   Service-managed:  SSH public keys stored in AWS Transfer (simplest)
#   Custom IdP:       Lambda function calls your existing LDAP/AD/OAuth
#   AWS Directory:    authenticate against AWS Managed Microsoft AD
#
# SAA-C03 USE CASES:
#   "Replace on-prem SFTP server"                       → Transfer Family
#   "Partner file exchange over SFTP"                   → Transfer Family
#   "Legacy SFTP workflow, store files in S3"           → Transfer Family
#   "FTP clients need to access EFS"                    → Transfer Family + EFS backend
#   "SFTP but files need to be queryable by Athena"     → Transfer Family + S3 + Athena
#
# SAA-C03 DISTRACTOR: Transfer Family is NOT for bulk migration (use DataSync/Snow).
# It is for ONGOING file exchange via SFTP/FTP protocols.

resource "aws_transfer_server" "sftp" {
  # Protocol: SFTP runs over SSH (port 22)
  # SFTP is the most secure and commonly requested protocol
  protocols = ["SFTP"]

  # Storage backend: files are stored in S3 (or change to "EFS")
  domain = "S3"

  # PUBLIC endpoint: accessible from the internet on port 22
  # VPC endpoint: accessible only within your VPC (use for private partners)
  endpoint_type = "PUBLIC"

  # Security policy: TLS/cipher suite policy for SFTP connections
  # TransferSecurityPolicy-2023-05 = latest policy, supports TLS 1.2+
  security_policy_name = "TransferSecurityPolicy-2023-05"

  # Identity provider: SERVICE_MANAGED = AWS stores SSH public keys for users
  # CUSTOM: use a Lambda function to authenticate against your own IdP
  identity_provider_type = "SERVICE_MANAGED"

  # Force user to use only the SFTP protocol (not FTP/FTPS on same server)
  # Protocols list above already restricts this — this setting is redundant but explicit

  # Logging: CloudWatch logs for SFTP session activity
  # The role needs logs:CreateLogStream and logs:PutLogEvents permissions
  logging_role = aws_iam_role.transfer_logging.arn

  tags = {
    Name     = "${var.project_name}-sftp-server"
    Protocol = "SFTP"
    Backend  = "S3"
    Lab      = "48-datasync-snow"
  }
}

# =============================================================================
# IAM ROLE: Transfer Family logging
# =============================================================================
# Transfer Family needs a role to write connection/activity logs to CloudWatch.

resource "aws_iam_role" "transfer_logging" {
  name = "${var.project_name}-transfer-logging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "transfer.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "transfer_logging" {
  name = "${var.project_name}-transfer-logging-policy"
  role = aws_iam_role.transfer_logging.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.transfer.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "transfer" {
  name              = "/aws/transfer/${var.project_name}"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-transfer-logs"
  }
}

# =============================================================================
# IAM ROLE: Transfer Family user access to S3
# =============================================================================
# Each Transfer Family user assumes a role that grants access to their S3 home directory.
# The scope-down policy further restricts the user to only their own prefix.
#
# This separation (role per user vs shared role + scope-down policy) is a common
# SAA-C03 pattern: the role grants broad S3 access; the scope-down policy
# restricts each session to a specific prefix using session variables.

resource "aws_iam_role" "transfer_user" {
  name = "${var.project_name}-transfer-user-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "transfer.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-transfer-user-role"
  }
}

resource "aws_iam_role_policy" "transfer_user" {
  name = "${var.project_name}-transfer-user-policy"
  role = aws_iam_role.transfer_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow listing the bucket (needed to navigate directories in SFTP clients)
      {
        Sid    = "AllowListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.migration_destination.arn
      },
      # Allow SFTP operations (upload, download, delete) on user's home directory
      # The ${transfer:UserName} variable is substituted at session time
      {
        Sid    = "AllowUserHomeDirectory"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:GetObjectVersion",
          "s3:GetObjectACL",
          "s3:PutObjectACL"
        ]
        Resource = "${aws_s3_bucket.migration_destination.arn}/sftp-users/*"
      }
    ]
  })
}

# =============================================================================
# TRANSFER FAMILY USER
# =============================================================================
# A Transfer Family user represents one SFTP client identity.
# Users authenticate with SSH public keys (service-managed auth).
#
# HOME DIRECTORY TYPES:
#   PATH:    the user's home is a literal S3 key prefix (e.g., /bucket/user/)
#   LOGICAL: map virtual directories to real S3 paths (use home_directory_mappings)
#            This allows one bucket to serve many users with isolated home dirs.
#
# SAA-C03 scenario: "SFTP users should only see their own folder, not others'"
#   → Use LOGICAL home directory type with per-user mappings
#   → Optionally add a scope-down policy for extra isolation

resource "aws_transfer_user" "example" {
  server_id = aws_transfer_server.sftp.id
  user_name = "sftp-partner-user"
  role      = aws_iam_role.transfer_user.arn

  # LOGICAL home directory: map a virtual root "/" to a real S3 path
  # When the user connects via SFTP, they see "/" as their root
  # but it's actually mapped to /sftp-users/sftp-partner-user/ in S3
  home_directory_type = "LOGICAL"

  home_directory_mappings {
    entry  = "/"                                                                           # What the SFTP client sees
    target = "/${aws_s3_bucket.migration_destination.bucket}/sftp-users/sftp-partner-user" # Real S3 path
  }

  tags = {
    Name = "sftp-partner-user"
    Lab  = "48-datasync-snow"
  }

  # NOTE: To add an SSH public key, use aws_transfer_ssh_key resource:
  # resource "aws_transfer_ssh_key" "example" {
  #   server_id = aws_transfer_server.sftp.id
  #   user_name = aws_transfer_user.example.user_name
  #   body      = "ssh-rsa AAAA... user@example.com"
  # }
}

# =============================================================================
# SUMMARY: SERVICE SELECTION FRAMEWORK (SAA-C03 exam cheat sheet)
# =============================================================================
#
# QUESTION: How do I get data INTO AWS?
#
# Small amounts, online:
#   < 1 GB   → AWS CLI, SDK, S3 console upload
#   < 1 TB   → S3 Transfer Acceleration (fast PUT via CloudFront edge)
#   Any size → DataSync (with scheduling, verification, incremental)
#
# Large amounts, offline:
#   10 TB – 10 PB  → Snowball Edge
#   > 100 PB       → Snowmobile
#   Remote/rugged  → Snowcone (with pre-installed DataSync agent)
#
# Ongoing file exchange (partner/legacy):
#   SFTP/FTPS/FTP  → Transfer Family
#   NFS/SMB hybrid → Storage Gateway File Gateway
#
# QUESTION: DataSync vs Storage Gateway?
#   DataSync:        one-time or scheduled MIGRATION; data moves to AWS storage
#   Storage Gateway: ONGOING HYBRID ACCESS; on-prem apps access AWS storage as if local
#   SAA-C03 tip: "migrate" → DataSync; "ongoing access" → Storage Gateway
#
# QUESTION: DataSync vs S3 Replication?
#   DataSync:       source is NFS/SMB/HDFS/S3 → destination is S3/EFS/FSx
#   S3 Replication: source is S3 bucket → destination is another S3 bucket
#   DataSync works across protocols; S3 Replication is S3-to-S3 only
#
# QUESTION: What does the DataSync agent do?
#   - Runs on-premises (VM or container)
#   - Mounts the source NFS/SMB/HDFS
#   - Reads data and sends to AWS DataSync endpoints over TLS
#   - Not needed for cloud-to-cloud transfers (S3→S3, EFS→S3)
#   - Pre-installed on Snowcone devices
#
# QUESTION: Transfer Family authentication options?
#   Service-managed: AWS stores SSH keys → simplest, no external IdP
#   Custom IdP (Lambda): Lambda validates credentials against LDAP/AD/OAuth
#   AWS Directory Service: authenticate against AWS Managed Microsoft AD
#
# QUESTION: What is AS2 in Transfer Family?
#   Applicability Statement 2 = industry standard for EDI (Electronic Data Interchange)
#   Used in supply chain, healthcare, finance for B2B file exchange
#   SAA-C03: "EDI partner file exchange" → Transfer Family with AS2 protocol
