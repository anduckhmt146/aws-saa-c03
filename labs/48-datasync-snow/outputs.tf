# =============================================================================
# OUTPUTS - Lab 48: DataSync + Snow Family + Transfer Family
# =============================================================================
# These outputs expose the key identifiers for the migration and file-transfer
# resources created in this lab.
# SAA-C03 tip: on the exam you choose WHICH service to use; these outputs
# help you reference resources in downstream automation or pipelines.

# --- DataSync S3 Buckets ---

output "datasync_source_bucket" {
  description = <<-EOT
    Name of the S3 bucket used as the DataSync source (simulates an on-prem NFS server).
    SAA-C03: In a real migration, the source would be an NFS location requiring
    a DataSync agent deployed on-premises. S3-to-S3 transfers require no agent.
  EOT
  value       = aws_s3_bucket.migration_source.bucket
}

output "datasync_destination_bucket" {
  description = <<-EOT
    Name of the S3 bucket used as the DataSync destination.
    Exam tip: the S3 storage class set in the DataSync location determines
    the storage tier for migrated objects (STANDARD, STANDARD_IA, GLACIER, etc.)
    without needing a separate lifecycle policy.
  EOT
  value       = aws_s3_bucket.migration_destination.bucket
}

# --- DataSync ---

output "datasync_task_arn" {
  description = <<-EOT
    ARN of the DataSync task that transfers data from the NFS location to S3.
    A task encapsulates: source location + destination location + transfer options.
    You start a task execution via the console, CLI, or EventBridge schedule.
  EOT
  value       = aws_datasync_task.nfs_to_s3.arn
}

output "datasync_s3_location_arn" {
  description = <<-EOT
    ARN of the DataSync S3 destination location.
    SAA-C03: DataSync can write to ANY S3 storage class (Standard, IA, Glacier, etc.)
    Choosing the right storage class at write time reduces cost for archive migrations.
  EOT
  value       = aws_datasync_location_s3.destination.arn
}

output "datasync_efs_location_arn" {
  description = <<-EOT
    ARN of the DataSync EFS destination location.
    Use EFS as a destination when migrating NFS workloads that need continued
    POSIX-compatible shared file access after migration (e.g., Linux app servers).
  EOT
  value       = aws_datasync_location_efs.destination.arn
}

# --- Transfer Family ---

output "sftp_server_id" {
  description = <<-EOT
    ID of the AWS Transfer Family SFTP server.
    SAA-C03: Transfer Family provides a managed SFTP/FTPS/FTP endpoint backed by S3 or EFS.
    No EC2 instances or OS patching required. Legacy SFTP clients connect unchanged.
    identity_provider_type options: SERVICE_MANAGED (built-in users) vs API_GATEWAY (Lambda-backed custom IdP).
  EOT
  value       = aws_transfer_server.sftp.id
}

output "sftp_server_endpoint" {
  description = <<-EOT
    DNS endpoint of the AWS Transfer Family SFTP server.
    Format: <server-id>.server.transfer.<region>.amazonaws.com
    Partners and legacy SFTP clients connect to this hostname on port 22.
    endpoint_type PUBLIC = internet-facing; VPC = private endpoint inside your VPC.
  EOT
  value       = aws_transfer_server.sftp.endpoint
}

output "sftp_user_arn" {
  description = <<-EOT
    ARN of the Transfer Family SFTP user.
    Each user assumes an IAM role that scopes their S3 access.
    home_directory_type LOGICAL hides the real S3 bucket path from the SFTP client,
    presenting a clean virtual directory tree instead.
  EOT
  value       = aws_transfer_user.example.arn
}

output "transfer_server_arn" {
  description = "ARN of the Transfer Family SFTP server. Use in IAM policies and CloudWatch log group names."
  value       = aws_transfer_server.sftp.arn
}

# --- Migration Destination ---

output "migration_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket used as the migration destination.
    DataSync writes transferred files here. Transfer Family users also land here.
    After migration, use S3 lifecycle rules to transition objects to Glacier for cost savings.
  EOT
  value       = aws_s3_bucket.migration_destination.bucket
}

# --- SAA-C03 Exam Cheat Sheet ---

output "exam_cheat_sheet" {
  description = "SAA-C03 service comparison: DataSync vs Storage Gateway vs Snow Family vs Transfer Family"
  value       = <<-EOT
    ============================================================
    SAA-C03 MIGRATION & TRANSFER SERVICE CHEAT SHEET
    ============================================================

    AWS DATASYNC
      Use when: scheduled/one-time data transfer with checksum verification
      Sources:  NFS, SMB, HDFS, S3, EFS, FSx, Azure Blob, GCS, object storage
      Targets:  S3 (any class), EFS, FSx for Windows/Lustre/ONTAP/OpenZFS
      Agent:    required for on-premises sources; NOT needed for cloud-to-cloud
      Key features: incremental (CHANGED mode), per-file verification, scheduling
      Exam keywords: "migrate NFS to S3", "scheduled replication", "checksum verify"

    STORAGE GATEWAY
      Use when: ongoing hybrid access (not one-off migration)
      File GW:  NFS/SMB mount on-prem backed by S3 (local cache)
      Volume GW: iSCSI block storage backed by S3 (stored or cached)
      Tape GW:  virtual tape library backed by S3 Glacier
      Exam keywords: "ongoing access", "hybrid storage", "replace tape backup"

    SNOW FAMILY (offline physical transfer)
      Snowcone (8 TB HDD / 14 TB SSD):
        - Battery-powered, backpack-portable, rugged
        - DataSync agent pre-installed
        - Exam: "edge, remote, battery, DataSync agent built-in"
      Snowball Edge Storage Optimized (80 TB, 40 vCPU):
        - Bulk data center migration
        - Exam: "80 TB migration, limited bandwidth"
      Snowball Edge Compute Optimized (42 TB, 52 vCPU + optional GPU):
        - Edge ML inference, video processing
        - Exam: "edge computing + GPU + offline"
      Snowmobile (100 PB per truck):
        - Exabyte-scale data center moves
        - Exam: "hundreds of PB", "entire data center", "100 PB"
      OpsHub: GUI desktop app to manage Snow devices offline

    TRANSFER FAMILY
      Use when: legacy SFTP/FTP clients need to write to S3 or EFS
      Protocols: SFTP (port 22), FTPS (port 21+TLS), FTP (port 21), AS2 (EDI/B2B)
      Backend:   S3 or EFS
      IdP types: SERVICE_MANAGED (SSH keys in AWS), API_GATEWAY (Lambda+LDAP/AD)
      Endpoint:  PUBLIC (internet) or VPC (private)
      Exam keywords: "replace SFTP server", "partner file exchange", "SFTP to S3"
      NOT for: bulk migration (use DataSync or Snow instead)

    DECISION RULES
      "Migrate NFS/SMB to AWS with verification + scheduling" → DataSync
      "Ongoing on-prem apps accessing S3 as a file share"     → Storage Gateway
      "> 10 TB, limited bandwidth, offline transfer"          → Snowball Edge
      "Exabyte scale, whole data center"                      → Snowmobile
      "Remote/rugged edge, 8 TB, DataSync pre-installed"      → Snowcone
      "SFTP clients must continue working, files go to S3"    → Transfer Family
      "B2B EDI exchange"                                      → Transfer Family AS2
    ============================================================
  EOT
}
