# ============================================================
# LAB 16 - Migration & Transfer: DMS, DataSync, Transfer Family
# Snow Family = physical devices (cannot provision with Terraform)
# ============================================================

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_caller_identity" "current" {}
resource "random_id" "suffix" { byte_length = 4 }

# ============================================================
# DMS - DATABASE MIGRATION SERVICE
# Migrate databases with minimal downtime
#
# Migration types:
#   Full Load:          One-time copy of existing data
#   CDC Only:           Ongoing change capture only
#   Full Load + CDC:    Copy then keep in sync (most common)
#
# Homogeneous:  Same engine (MySQL → MySQL, no SCT needed)
# Heterogeneous: Different engine (Oracle → Aurora) + SCT
# SCT = Schema Conversion Tool (converts DDL, stored procs)
# ============================================================

resource "aws_security_group" "dms" {

  name        = "lab-dms-sg"
  description = "DMS replication instance security group"
  vpc_id      = data.aws_vpc.default.id

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_dms_replication_subnet_group" "lab" {

  replication_subnet_group_description = "Lab DMS subnet group"
  replication_subnet_group_id          = "lab-dms-subnet-group"
  subnet_ids                           = data.aws_subnets.default.ids
}

# DMS Replication Instance
# This is the compute that runs migration tasks
resource "aws_dms_replication_instance" "lab" {
  replication_instance_id     = "lab-dms-instance"
  replication_instance_class  = "dms.t3.micro" # Smallest class
  allocated_storage           = 10             # GB
  publicly_accessible         = false
  multi_az                    = false # Set true for HA in production
  vpc_security_group_ids      = [aws_security_group.dms.id]
  replication_subnet_group_id = aws_dms_replication_subnet_group.lab.replication_subnet_group_id

  # destroy-safe
  # SAA-C03: aws_dms_replication_instance does not support a skip_final_snapshot argument.

  tags = { Name = "lab-dms-replication-instance" }
}

# Source endpoint (MySQL — source database)
resource "aws_dms_endpoint" "source" {
  endpoint_id   = "lab-source-mysql"
  endpoint_type = "source"
  engine_name   = "mysql"
  server_name   = "source-mysql.example.com" # Replace with real source
  port          = 3306
  database_name = "sourcedb"
  username      = "admin"
  password      = var.db_password

  tags = { Name = "lab-dms-source" }
}

# Target endpoint (Aurora MySQL — destination)
resource "aws_dms_endpoint" "target" {
  endpoint_id   = "lab-target-aurora"
  endpoint_type = "target"
  engine_name   = "aurora"
  server_name   = "target-aurora.cluster.us-east-1.rds.amazonaws.com" # Replace with real target
  port          = 3306
  database_name = "targetdb"
  username      = "admin"
  password      = var.db_password

  tags = { Name = "lab-dms-target" }
}

# DMS Replication Task
resource "aws_dms_replication_task" "lab" {
  replication_task_id      = "lab-migration-task"
  replication_instance_arn = aws_dms_replication_instance.lab.replication_instance_arn
  source_endpoint_arn      = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn      = aws_dms_endpoint.target.endpoint_arn
  migration_type           = "full-load-and-cdc" # full-load | cdc | full-load-and-cdc

  table_mappings = jsonencode({
    rules = [{
      rule-type = "selection"
      rule-id   = "1"
      rule-name = "include-all"
      object-locator = {
        schema-name = "%"
        table-name  = "%"

      }
      rule-action = "include"
    }]
  })

  replication_task_settings = jsonencode({

    TargetMetadata = {
      TargetSchema       = ""
      SupportLobs        = true
      FullLobMode        = false
      LobChunkSize       = 64
      LimitedSizeLobMode = true
      LobMaxSize         = 32

    }
    FullLoadSettings = {
      TargetTablePrepMode = "DROP_AND_CREATE"

    }
    Logging = {
      EnableLogging = true
      LogComponents = [{
        Id = "SOURCE_UNLOAD"
      Severity = "LOGGER_SEVERITY_DEFAULT" }]

    }
  })

  tags = { Name = "lab-migration-task" }
}

# ============================================================
# DATASYNC
# Automated data transfer between on-premises and AWS
# Agent-based (on-premises) or agentless (S3, EFS, FSx)
# Destinations: S3, EFS, FSx for Windows, FSx for Lustre
# Features: scheduling, bandwidth throttling, data verification
# Use case: migrate file shares, sync on-prem to S3
# ============================================================

# DataSync S3 destination location
resource "aws_s3_bucket" "datasync_dest" {
  bucket        = "lab-datasync-dest-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_iam_role" "datasync_s3" {

  name = "lab-datasync-s3-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "datasync.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "datasync_s3" {

  name = "lab-datasync-s3-policy"
  role = aws_iam_role.datasync_s3.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:ListMultipartUploadParts", "s3:PutObject", "s3:GetObjectTagging", "s3:PutObjectTagging"]
      Resource = ["${aws_s3_bucket.datasync_dest.arn}", "${aws_s3_bucket.datasync_dest.arn}/*"]
    }]
  })
}

resource "aws_datasync_location_s3" "dest" {

  s3_bucket_arn = aws_s3_bucket.datasync_dest.arn
  subdirectory  = "/migration-data/"

  s3_config {
    bucket_access_role_arn = aws_iam_role.datasync_s3.arn
  }
}

# ============================================================
# TRANSFER FAMILY
# Managed SFTP/FTPS/FTP service backed by S3 or EFS
# Use case: legacy apps using FTP protocols, partner file exchange
# ============================================================

resource "aws_s3_bucket" "transfer_dest" {
  bucket        = "lab-transfer-family-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_iam_role" "transfer_logging" {

  name = "lab-transfer-logging-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "transfer.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "transfer_logging" {

  role       = aws_iam_role.transfer_logging.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSTransferLoggingAccess"
}

resource "aws_transfer_server" "lab" {

  identity_provider_type = "SERVICE_MANAGED" # or API_GATEWAY for custom auth
  protocols              = ["SFTP"]          # SFTP, FTPS, FTP, AS2
  domain                 = "S3"              # S3 or EFS backend

  logging_role = aws_iam_role.transfer_logging.arn

  tags = { Name = "lab-transfer-server" }
}

# Transfer user (service-managed identity)
resource "aws_iam_role" "transfer_user" {
  name = "lab-transfer-user-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "transfer.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "transfer_user" {

  name = "lab-transfer-user-policy"
  role = aws_iam_role.transfer_user.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:GetObjectVersion", "s3:GetObjectACL", "s3:PutObjectACL"]
      Resource = "${aws_s3_bucket.transfer_dest.arn}/*"
      }, {
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = aws_s3_bucket.transfer_dest.arn
    }]
  })
}

resource "aws_transfer_user" "lab" {

  server_id      = aws_transfer_server.lab.id
  user_name      = "lab-sftp-user"
  role           = aws_iam_role.transfer_user.arn
  home_directory = "/${aws_s3_bucket.transfer_dest.bucket}/uploads"

  tags = { Name = "lab-sftp-user" }
}

# ============================================================
# AWS BACKUP
# Centralized backup across services:
#   EC2, EBS, RDS, DynamoDB, EFS, FSx, S3, DocumentDB
# Backup Plans: frequency, retention, lifecycle
# Backup Vault: encrypted storage for backups
# ============================================================

resource "aws_backup_vault" "lab" {

  name = "lab-backup-vault"
  tags = { Name = "lab-backup-vault" }
}

resource "aws_backup_plan" "lab" {

  name = "lab-backup-plan"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.lab.name
    schedule          = "cron(0 2 * * ? *)" # Daily at 2 AM UTC

    lifecycle {
      cold_storage_after = 30 # Move to cold storage after 30 days
      delete_after       = 90 # Delete after 90 days

    }
  }

  rule {

    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.lab.name
    schedule          = "cron(0 3 ? * SUN *)" # Weekly Sunday 3 AM

    lifecycle {
      delete_after = 365

    }
  }
}

resource "aws_iam_role" "backup" {

  name = "lab-backup-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {

  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Backup selection — tag-based (back up anything tagged Backup=true)
resource "aws_backup_selection" "lab" {
  name         = "lab-backup-selection"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.lab.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "true"
  }
}

# =============================================================================
# SECTION: AWS APPLICATION MIGRATION SERVICE (MGN) — Lift and Shift
# =============================================================================
# MGN (formerly CloudEndure Migration) = automated lift-and-shift tool.
# Continuously replicates source servers to AWS.
#
# SAA-C03 KEY FACTS:
#   - Agentless replication: install MGN agent on source server
#   - Continuous block-level replication to a staging area
#   - Minimal downtime: final cutover sync takes only seconds/minutes
#   - Supports: physical servers, VMware, Hyper-V, Azure, GCP → AWS
#   - Auto-converts boot volume to EBS, converts server to EC2
#   - Free: MGN service itself is free; pay only for EC2/EBS used
#   - Compare with SMS (Server Migration Service): older, deprecated → use MGN
#
# EXAM TIPS:
#   - "Lift-and-shift with minimal downtime" = MGN
#   - "Migrate physical servers to EC2" = MGN
#   - "Continuous replication" = MGN
#   - "Final cutover with minimal downtime" = MGN (vs. DMS which is for databases)
#   - "Re-platform" = often involves converting to containers/managed services (not MGN)
#   - "Re-host" = lift-and-shift = MGN
#
# MGN WORKFLOW:
#   1. Install MGN agent on source server
#   2. Agent replicates to staging EC2 (inexpensive t2.micro + inexpensive EBS)
#   3. Test: launch test instance (no interruption to source)
#   4. Cutover: brief downtime (minutes) for final sync → launch cutover instance
#   5. Decommission source server
#
# NOTE: MGN is primarily managed via the MGN console/API. Terraform supports
# very limited MGN resources (aws_mgn_replication_configuration_template).

resource "aws_mgn_replication_configuration_template" "main" {
  # Defines how source servers are replicated to AWS
  bandwidth_throttling                    = 0     # 0 = unlimited
  create_public_ip                        = false # staging area uses private IP
  data_plane_routing                      = "PRIVATE_IP"
  default_large_staging_disk_type         = "GP3"
  ebs_encryption                          = "DEFAULT"
  replication_server_instance_type        = "t3.small"
  replication_servers_security_groups_ids = [] # add your SG IDs
  staging_area_subnet_id                  = "" # add your staging subnet
  use_dedicated_replication_server        = false

  staging_area_tags = {
    Purpose = "mgn-staging-area"
  }

  # SAA-C03: The staging area is an inexpensive replication buffer in your VPC.
  # Source server data streams here continuously via TCP 1500 (MGN agent → staging).
  # Final instance runs in your target subnet (production subnet).
}
