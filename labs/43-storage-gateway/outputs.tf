# =============================================================================
# OUTPUTS — LAB 43: STORAGE GATEWAY
# SAA-C03 Study Lab — Hybrid Storage: On-Premises <-> AWS
# =============================================================================

# =============================================================================
# STORAGE GATEWAY — S3 FILE GATEWAY ARN AND ID
# =============================================================================

output "gateway_arn" {
  description = <<-EOT
    ARN of the S3 File Gateway resource.
    SAA-C03 exam tip: The gateway ARN is used to:
      - Associate cache disks (aws_storagegateway_cache resource)
      - Create NFS/SMB file shares (the gateway_arn parameter)
      - Reference the gateway in IAM and bucket policies
      - Set up CloudWatch alarms for gateway-level metrics
    Format: arn:aws:storagegateway:<region>:<account-id>:gateway/sgw-XXXXXXXX

    NOTE: This output will only populate after real gateway activation.
    With the placeholder activation_key, the gateway resource will fail to
    create at apply time — all other resources (S3, IAM, VPC) still succeed.
    This is expected behavior for this study lab.
  EOT
  value       = try(aws_storagegateway_gateway.s3_file_gateway.arn, "NOT-ACTIVATED-requires-real-appliance")
}

output "gateway_id" {
  description = <<-EOT
    ID of the S3 File Gateway (short gateway identifier, e.g. sgw-XXXXXXXX).
    SAA-C03 exam tip: The gateway ID appears in the Storage Gateway console
    and is used when assigning local disks as cache or upload buffer storage.
    After activation, local disks must be explicitly assigned using the API
    or console before file shares can be created — Terraform manages this via
    the aws_storagegateway_cache resource (disk_path + gateway_arn).
  EOT
  value       = try(aws_storagegateway_gateway.s3_file_gateway.id, "NOT-ACTIVATED-requires-real-appliance")
}

output "gateway_ec2_instance_id" {
  description = <<-EOT
    EC2 instance ID of the gateway appliance (only set for EC2-based deployments).
    SAA-C03 exam tip: When deploying Storage Gateway as an EC2 AMI, minimum
    instance sizing requirements are:
      - Minimum: m5.xlarge (4 vCPU, 16 GiB RAM) for production workloads
      - High-throughput: m5.2xlarge or c5.2xlarge or larger
      - Cache disk: attach a separate EBS volume (min 150 GiB)
      - Upload buffer: separate EBS volume from cache disk (Volume/Tape only)
    The EC2 gateway must have port 80 accessible during activation, but this
    can be removed from the security group immediately after activation.
  EOT
  value       = try(aws_storagegateway_gateway.s3_file_gateway.ec2_instance_id, "NOT-ACTIVATED-requires-real-appliance")
}

# =============================================================================
# S3 BUCKETS
# =============================================================================

output "file_gateway_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket backing the NFS and SMB file shares.
    SAA-C03 exam tip: Files written via NFS or SMB become native S3 objects.
    The S3 key mirrors the file path relative to the share root — for example:
      /mnt/share/reports/q1.csv  ->  s3://<bucket>/reports/q1.csv
    This means the same data is simultaneously accessible via:
      1. NFS/SMB from on-premises clients (through the gateway)
      2. S3 API from cloud services (Lambda, EC2, Athena, EMR, Glue)
    This dual-access pattern is the defining characteristic of S3 File Gateway
    and a common basis for hybrid data lake exam questions.
  EOT
  value       = aws_s3_bucket.file_gateway_bucket.id
}

output "file_gateway_bucket_arn" {
  description = <<-EOT
    ARN of the S3 bucket backing the file shares.
    SAA-C03 exam tip: This ARN must appear in THREE places:
      1. IAM role policy (role_arn on the file share) — allows gateway to write
      2. S3 bucket policy — restricts writes to the gateway IAM role only
      3. File share location_arn — tells the share which bucket to use
    Exam pattern: "Who controls access to the S3 bucket used by Storage Gateway?"
    Answer: The IAM role attached to the file share AND the S3 bucket policy
    must both permit the gateway — both layers must allow for access to succeed.
    In cross-account scenarios, the target bucket account must have a bucket
    policy that explicitly allows the gateway role from the source account.
  EOT
  value       = aws_s3_bucket.file_gateway_bucket.arn
}

output "volume_gateway_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket used by the Volume Gateway for EBS snapshot storage.
    SAA-C03 exam tip: Volume Gateway uses S3 to store EBS snapshots of iSCSI
    volumes. Objects in this bucket are NOT directly accessible as regular files
    — they are stored in EBS snapshot format (internal AWS format).
    To restore data: create an EBS volume from a snapshot in the AWS console,
    then attach it to an EC2 instance or restore it to an on-prem volume.
    STORED mode — local disk is primary, S3 holds asynchronous backup snapshots.
    CACHED mode — S3 is primary source of truth, local disk holds hot-data cache.
  EOT
  value       = aws_s3_bucket.volume_gateway_bucket.id
}

output "tape_gateway_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket used by the Tape Gateway virtual tape library (VTL).
    SAA-C03 exam tip: Tape Gateway uses a two-tier storage model:
      - Active tapes (in the VTL):    stored in S3 Standard (fast retrieval)
      - Archived/ejected tapes:       moved to S3 Glacier or Glacier Deep Archive
    "Ejecting" a virtual tape in the Tape Gateway console triggers the move
    from S3 Standard to Glacier — analogous to sending physical tapes offsite.
    Retrieval times (must know for exam):
      S3 Glacier Flexible Retrieval:   3-5 hours standard / 1-5 min expedited
      S3 Glacier Deep Archive:         12 hours standard / 48 hours bulk
    Exam pattern: "Replace physical tapes at lowest cost" -> Tape Gateway + Glacier Deep Archive
  EOT
  value       = aws_s3_bucket.tape_gateway_bucket.id
}

output "s3_bucket_arns" {
  description = <<-EOT
    ARNs of all three Storage Gateway S3 buckets as a map.
    SAA-C03 exam tip: Each bucket serves a different gateway type and storage
    pattern. Use this output to quickly reference ARNs for IAM policies or
    cross-resource references in other Terraform modules.
  EOT
  value = {
    file_gateway   = aws_s3_bucket.file_gateway_bucket.arn
    volume_gateway = aws_s3_bucket.volume_gateway_bucket.arn
    tape_gateway   = aws_s3_bucket.tape_gateway_bucket.arn
  }
}

# =============================================================================
# FILE SHARE OUTPUTS
# =============================================================================

output "nfs_file_share_arn" {
  description = <<-EOT
    ARN of the NFS file share on the S3 File Gateway.
    SAA-C03 exam tip: NFS file shares are used by Linux, Unix, and macOS clients.
    Key NFS file share settings to know for the exam:
      client_list: IP CIDR ranges permitted to mount (source IP ACL on the share)
      squash setting controls root privilege mapping:
        RootSquash (default): root on client maps to nobody — prevents privilege
                              escalation from on-prem to S3 objects
        AllSquash:            all users map to nobody (most restrictive)
        NoSquash:             root on client has full S3 access (avoid in prod)
      cache_stale_timeout_in_seconds:
        0   = always check S3 for updates (consistent, slower)
        300 = cache valid for 5 min (better performance, slight staleness risk)
    Exam tip: if on-prem users read files that were modified directly in S3 and
    see stale data, lower the cache_stale_timeout_in_seconds value.
  EOT
  value       = try(aws_storagegateway_nfs_file_share.nfs_share.arn, "NOT-ACTIVATED-requires-real-gateway")
}

output "nfs_file_share_path" {
  description = <<-EOT
    NFS mount path for the file share (format: <gateway-ip>:/<path>).
    SAA-C03 exam tip: Linux clients mount with:
      sudo mount -t nfs -o nolock <gateway-ip>:/<bucket-name> /mnt/share
    The share path defaults to the S3 bucket name if file_share_name is not set.
    The -o nolock flag disables NLM (Network Lock Manager) which Storage Gateway
    does not support — always include this flag.
  EOT
  value       = try(aws_storagegateway_nfs_file_share.nfs_share.path, "NOT-ACTIVATED-requires-real-gateway")
}

output "smb_file_share_arn" {
  description = <<-EOT
    ARN of the SMB file share on the S3 File Gateway.
    SAA-C03 exam tip: SMB file shares serve Windows clients. Authentication modes:
      GuestAccess:       No credentials required (dev/test environments only)
      ActiveDirectory:   Domain user credentials (production; gateway must be
                         joined to the AD domain using smb_active_directory_settings)
    Exam distinction — S3 File Gateway SMB vs FSx File Gateway:
      S3 File Gateway + SMB:  Files stored as S3 objects. No true NTFS ACLs.
                              Use for cloud-native data lake or S3-backed shares.
      FSx File Gateway + SMB: Files stored in FSx for Windows File Server.
                              Full NTFS permissions, DFS namespaces, AD integration.
                              Use when replacing an on-prem Windows file server.
  EOT
  value       = try(aws_storagegateway_smb_file_share.smb_share.arn, "NOT-ACTIVATED-requires-real-gateway")
}

output "smb_file_share_path" {
  description = <<-EOT
    SMB UNC path for connecting Windows clients to the file share.
    Format: \\<gateway-ip>\<share-name>
    SAA-C03 exam tip: Windows clients connect using standard UNC paths.
    Map a network drive in Windows Explorer or use: net use Z: \\<ip>\<share>
  EOT
  value       = try(aws_storagegateway_smb_file_share.smb_share.path, "NOT-ACTIVATED-requires-real-gateway")
}

# =============================================================================
# IAM ROLE
# =============================================================================

output "gateway_iam_role_arn" {
  description = <<-EOT
    ARN of the IAM role assumed by Storage Gateway to access S3.
    SAA-C03 exam tip: This role ARN is specified as the role_arn parameter when
    creating NFS or SMB file shares. The gateway assumes this role when it reads
    or writes objects to the backing S3 bucket.
    Required IAM permissions (minimum):
      Bucket-level:  s3:GetBucketLocation, s3:ListBucket
      Object-level:  s3:GetObject, s3:PutObject, s3:DeleteObject,
                     s3:AbortMultipartUpload, s3:ListMultipartUploadParts
    In cross-account scenarios: the destination bucket must have a bucket policy
    explicitly allowing this role ARN from the gateway's AWS account — IAM role
    permissions alone are not sufficient across account boundaries.
  EOT
  value       = aws_iam_role.storage_gateway_role.arn
}

# =============================================================================
# NETWORKING
# =============================================================================

output "vpc_id" {
  description = <<-EOT
    VPC ID hosting the Storage Gateway EC2 appliance.
    SAA-C03 exam tip: EC2-based Storage Gateway deployment options for
    connecting on-premises to AWS:
      Site-to-Site VPN:    Encrypted IPsec tunnel over public internet.
                           Cost-effective; variable latency.
      AWS Direct Connect:  Dedicated private circuit. Predictable latency,
                           up to 100 Gbps. Required for consistent performance.
    The gateway communicates outbound to S3, IAM, and CloudWatch on TCP 443.
    Use S3 VPC Endpoints to keep gateway-to-S3 traffic on the AWS private
    network, avoid internet exposure, and eliminate NAT Gateway data charges.
  EOT
  value       = aws_vpc.gateway_vpc.id
}

output "gateway_subnet_id" {
  description = <<-EOT
    Subnet ID where the Storage Gateway EC2 instance is deployed.
    SAA-C03 exam tip: Place the gateway in a PRIVATE subnet (no public IP).
    Connectivity checklist for the gateway subnet:
      - Route to on-prem via VPN or Direct Connect virtual interface
      - Route to AWS services via NAT Gateway or S3/STS VPC Endpoints
      - Security group allows inbound NFS (2049), SMB (445), or iSCSI (3260)
        restricted to on-prem client CIDR only — never open to 0.0.0.0/0
  EOT
  value       = aws_subnet.gateway_subnet.id
}

output "gateway_security_group_id" {
  description = <<-EOT
    Security group ID protecting the Storage Gateway EC2 appliance.
    SAA-C03 exam tip — port reference table (frequently tested):
      TCP 80    — Activation ONLY (one-time; remove from SG after activation)
      TCP 443   — Outbound to AWS services (must always be open outbound)
      TCP 2049  — NFS (S3 File Gateway, Linux/Unix/macOS clients)
      TCP/UDP 111 — NFS portmapper (required alongside 2049)
      TCP 20048 — NFS mountd (required alongside 2049)
      TCP 445   — SMB (Windows clients, S3 File Gateway or FSx File Gateway)
      TCP 3260  — iSCSI (Volume Gateway block access, Tape Gateway VTL)
    Best practice: restrict ALL inbound ports to the on-premises CIDR block.
    Never expose iSCSI (3260) or NFS (2049) to the public internet.
  EOT
  value       = aws_security_group.gateway_sg.id
}

# =============================================================================
# ACCOUNT AND REGION
# =============================================================================

output "account_id" {
  description = "AWS account ID where Storage Gateway resources are deployed."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "AWS region where Storage Gateway resources are deployed."
  value       = data.aws_region.current.name
}

# =============================================================================
# VOLUME GATEWAY DETAILS (CONCEPTUAL — resources are commented out in main.tf)
# =============================================================================

output "volume_gateway_info" {
  description = <<-EOT
    Conceptual reference for Volume Gateway configuration.
    SAA-C03 exam tip — STORED vs CACHED volume gateway:
      STORED mode:
        Primary data location: ON-PREMISES local disk
        AWS role:              Async EBS snapshot backup in S3
        Latency:               Very low (sub-millisecond — all I/O is local)
        Capacity:              Limited by on-prem hardware
        Use case:              Low-latency block storage with cloud-based DR
        Recovery:              Create EBS volume from snapshot -> restore to host
      CACHED mode:
        Primary data location: S3 (cloud is the source of truth)
        Local role:            LRU cache of frequently accessed blocks
        Latency:               Low for cached blocks, S3 latency for cache miss
        Capacity:              Effectively unlimited (S3 scales to exabytes)
        Use case:              Expand storage beyond local hardware limits
    Decision rule for the exam:
      "Need low latency + local primary + cloud backup"  -> STORED Volume Gateway
      "Need to expand on-prem capacity beyond local disk" -> CACHED Volume Gateway
  EOT
  value = {
    stored_mode_primary = "on-premises disk (S3 = async EBS snapshot backup)"
    cached_mode_primary = "S3 (local disk = hot-data cache only)"
    protocol            = "iSCSI block device (not file-level)"
    recovery            = "restore EBS snapshot to new volume"
    bucket              = aws_s3_bucket.volume_gateway_bucket.id
  }
}

# =============================================================================
# TAPE GATEWAY DETAILS (CONCEPTUAL — resources are commented out in main.tf)
# =============================================================================

output "tape_gateway_info" {
  description = <<-EOT
    Conceptual reference for Tape Gateway configuration.
    SAA-C03 exam tip: Tape Gateway (VTL) presents a standard iSCSI VTL interface
    to existing backup software — Veeam, Veritas NetBackup, Commvault, and others
    see virtual tape drives and changers with NO application changes required.
    Supported virtual tape drive type in this lab: IBM-ULT3580-TD5
    Supported changer type: AWS-Gateway-VTL
    Storage tiers:
      Active tapes (in VTL):  S3 Standard (immediate access, fast backup/restore)
      Archived tapes (ejected): S3 Glacier Flexible or S3 Glacier Deep Archive
    Common exam patterns:
      "Migrate physical tape infra to cloud at lowest cost"
        -> Tape Gateway + S3 Glacier Deep Archive
      "Backup software must work without modification"
        -> Tape Gateway (VTL interface; no code changes needed)
      "Need faster archived tape retrieval than Glacier Deep Archive"
        -> Tape Gateway + S3 Glacier Flexible Retrieval (3-5h standard)
  EOT
  value = {
    active_tape_storage   = "S3 Standard (in virtual tape library shelf)"
    archived_tape_storage = "S3 Glacier or S3 Glacier Deep Archive (ejected tapes)"
    protocol              = "iSCSI VTL (virtual tape library)"
    backup_app_changes    = "none — presents standard VTL interface"
    bucket                = aws_s3_bucket.tape_gateway_bucket.id
  }
}

# =============================================================================
# EXAM CHEAT SHEET
# =============================================================================

output "exam_cheat_sheet" {
  description = "SAA-C03 Storage Gateway quick-reference comparing all gateway types. No sensitive data."
  sensitive   = false
  value       = <<-EOT

  ╔══════════════════════════════════════════════════════════════════════════════╗
  ║         SAA-C03 EXAM CHEAT SHEET: AWS STORAGE GATEWAY TYPES                 ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                                                                              ║
  ║  GATEWAY TYPE       PROTOCOL     PRIMARY STORE     USE CASE TRIGGER         ║
  ║  ─────────────────  ───────────  ────────────────  ──────────────────────── ║
  ║  S3 File Gateway    NFS or SMB   S3                On-prem NFS/SMB to S3    ║
  ║                                                    Files become S3 objects  ║
  ║                                                    Data lake ingestion       ║
  ║                                                                              ║
  ║  FSx File Gateway   SMB only     FSx for Windows   Windows file server + AD ║
  ║                                  File Server       NTFS ACLs, DFS support   ║
  ║                                                    Full AD integration       ║
  ║                                                                              ║
  ║  Volume (STORED)    iSCSI block  On-prem disk      Low-latency local block  ║
  ║                                  S3 = backup only  Cloud DR via EBS snapsh  ║
  ║                                                                              ║
  ║  Volume (CACHED)    iSCSI block  S3 (primary)      Expand on-prem capacity  ║
  ║                                  Local = cache     Hot data cached locally   ║
  ║                                                                              ║
  ║  Tape Gateway       VTL / iSCSI  S3 (active)       Replace physical tapes   ║
  ║                                  Glacier (archive) Backup software unchanged ║
  ║                                                    Lowest long-term cost     ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  SERVICE COMPARISON                                                          ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  Storage Gateway  = ONGOING hybrid access (on-prem apps unchanged)          ║
  ║  DataSync         = ONE-TIME or scheduled bulk data migration to AWS        ║
  ║  Transfer Family  = SFTP/FTPS/FTP managed endpoint in front of S3 or EFS   ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  S3 FILE GATEWAY vs FSX FILE GATEWAY                                         ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  S3 File:  Data stored natively in S3 — queryable by Athena, EMR, Glue     ║
  ║            NFS or SMB. POSIX permissions. No native NTFS ACLs.              ║
  ║  FSx File: Data stored in FSx for Windows File Server                       ║
  ║            SMB only. Full NTFS ACLs. AD domain join required.               ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  PERFORMANCE TROUBLESHOOTING                                                 ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  Slow reads for hot files           -> Increase CACHE DISK size             ║
  ║  Writes stalling / gateway blocks   -> Increase UPLOAD BUFFER size          ║
  ║  WAN congestion during backup       -> Enable BANDWIDTH THROTTLING          ║
  ║  Stale reads after direct S3 edit   -> Lower cache_stale_timeout_in_seconds ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  KEY PORT NUMBERS                                                            ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  TCP 80     Activation only (remove SG rule after first-time activation)    ║
  ║  TCP 443    Outbound HTTPS to AWS services (always required)                ║
  ║  TCP 2049   NFS                                                              ║
  ║  TCP/UDP 111 NFS portmapper                                                  ║
  ║  TCP 20048  NFS mountd                                                       ║
  ║  TCP 445    SMB (Windows clients)                                            ║
  ║  TCP 3260   iSCSI (Volume Gateway and Tape Gateway)                         ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  NFS SQUASH SETTINGS                                                         ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  RootSquash  root on client -> nobody (recommended; prevents escalation)    ║
  ║  AllSquash   all users -> nobody (most restrictive)                         ║
  ║  NoSquash    root on client = root in S3 (avoid in production)              ║
  ╚══════════════════════════════════════════════════════════════════════════════╝
  EOT
}
