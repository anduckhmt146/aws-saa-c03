# =============================================================================
# LAB 43: AWS STORAGE GATEWAY
# SAA-C03 Study Lab — Hybrid Storage: On-Premises ↔ AWS
# =============================================================================
#
# STORAGE GATEWAY OVERVIEW
# ─────────────────────────────────────────────────────────────────────────────
# AWS Storage Gateway is a HYBRID STORAGE SERVICE that connects on-premises
# environments to AWS cloud storage. It presents standard storage protocols
# (NFS, SMB, iSCSI, VTL) to on-prem clients while durably storing data in AWS.
#
# KEY EXAM CONCEPT: Storage Gateway is always the answer when the question
# mentions "on-premises" + "extend to AWS" or "cloud-backed storage".
#
# FIVE GATEWAY TYPES (must know for SAA-C03):
# ┌─────────────────────┬──────────────────────────────────────────────────────┐
# │ Gateway Type        │ What It Does                                         │
# ├─────────────────────┼──────────────────────────────────────────────────────┤
# │ S3 File Gateway     │ NFS/SMB → S3 objects. Files become S3 objects.       │
# │                     │ Use: file shares, data lakes, backup to S3           │
# ├─────────────────────┼──────────────────────────────────────────────────────┤
# │ FSx File Gateway    │ SMB → FSx for Windows File Server                    │
# │                     │ Use: Windows file shares with AD integration         │
# ├─────────────────────┼──────────────────────────────────────────────────────┤
# │ Volume (Stored)     │ iSCSI block volumes; PRIMARY data on-prem            │
# │                     │ Async backup to S3 as EBS snapshots                  │
# │                     │ Use: low-latency local block storage + cloud backup   │
# ├─────────────────────┼──────────────────────────────────────────────────────┤
# │ Volume (Cached)     │ iSCSI block volumes; PRIMARY data in S3              │
# │                     │ Frequently accessed data cached on-prem              │
# │                     │ Use: expand local storage capacity using S3          │
# ├─────────────────────┼──────────────────────────────────────────────────────┤
# │ Tape Gateway        │ Virtual Tape Library (VTL) over iSCSI                │
# │                     │ Replaces physical tape drives/changers                │
# │                     │ Virtual tapes → S3; archived tapes → S3 Glacier      │
# │                     │ Use: existing tape-based backup software (Veeam,     │
# │                     │      Veritas, Commvault) without code changes         │
# └─────────────────────┴──────────────────────────────────────────────────────┘
#
# DEPLOYMENT OPTIONS:
#   • EC2 AMI          — Run Storage Gateway as an EC2 instance in your VPC
#                        (useful for hybrid setups where on-prem connects via VPN/DX)
#   • VMware ESXi      — OVA appliance deployed in on-prem VMware environment
#   • Microsoft Hyper-V — VHD appliance for Hyper-V hosts
#   • KVM              — qcow2 image for Linux KVM
#   • Physical appliance — AWS-provided hardware for bandwidth-constrained sites
#
# ACTIVATION FLOW (required to understand for exam):
#   1. Deploy appliance (EC2 or on-prem VM/hardware)
#   2. AWS Console sends HTTP request to appliance's port 80 → returns activation key
#   3. Provide activation key to StorageGateway API → gateway is registered
#   4. Add local disks: cache disk and (for Volume/Tape) upload buffer disk
#   5. Create file shares / volumes / tapes
# =============================================================================

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# =============================================================================
# VPC AND NETWORKING
# (Used when deploying Storage Gateway as an EC2 AMI)
# =============================================================================

# VPC for the Storage Gateway EC2 appliance
# SAA-C03: In EC2-based deployments, the gateway sits in a VPC subnet and
# communicates with on-prem via Site-to-Site VPN or AWS Direct Connect.
resource "aws_vpc" "gateway_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Lab     = "43-storage-gateway"
    Purpose = "Hosts Storage Gateway EC2 appliance"
  }
}

resource "aws_subnet" "gateway_subnet" {
  vpc_id            = aws_vpc.gateway_vpc.id
  cidr_block        = var.gateway_subnet_cidr
  availability_zone = "${var.aws_region}a"

  # SAA-C03: Gateway subnet should be PRIVATE. The gateway appliance reaches
  # AWS services (S3, IAM, CloudWatch) via VPC endpoints or NAT Gateway.
  # It does NOT need a public IP to function.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-gateway-subnet"
    Lab  = "43-storage-gateway"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.gateway_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
    Lab  = "43-storage-gateway"
  }
}

# =============================================================================
# SECURITY GROUP FOR STORAGE GATEWAY EC2 APPLIANCE
# =============================================================================

# SAA-C03: Storage Gateway EC2 appliance requires specific inbound ports:
# ┌──────────┬──────────┬─────────────────────────────────────────────────────┐
# │ Protocol │ Port(s)  │ Purpose                                             │
# ├──────────┼──────────┼─────────────────────────────────────────────────────┤
# │ TCP      │ 80       │ Activation only (one-time; can block after)         │
# │ TCP      │ 443      │ AWS service communication (HTTPS)                   │
# │ TCP      │ 2049     │ NFS (S3 File Gateway)                               │
# │ TCP/UDP  │ 111      │ NFS portmapper                                      │
# │ TCP      │ 20048    │ NFS mountd                                          │
# │ TCP      │ 445      │ SMB (S3 File Gateway, FSx File Gateway)             │
# │ TCP      │ 3260     │ iSCSI (Volume Gateway, Tape Gateway)                │
# └──────────┴──────────┴─────────────────────────────────────────────────────┘
resource "aws_security_group" "gateway_sg" {
  name        = "${var.project_name}-gateway-sg"
  description = "Security group for Storage Gateway EC2 appliance"
  vpc_id      = aws_vpc.gateway_vpc.id

  # NFS access — restricted to on-prem CIDR (SAA-C03: principle of least privilege)
  ingress {
    description = "NFS from on-prem clients"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  ingress {
    description = "NFS portmapper TCP"
    from_port   = 111
    to_port     = 111
    protocol    = "tcp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  ingress {
    description = "NFS portmapper UDP"
    from_port   = 111
    to_port     = 111
    protocol    = "udp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  ingress {
    description = "NFS mountd"
    from_port   = 20048
    to_port     = 20048
    protocol    = "tcp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  # SMB — for File Gateway (S3 or FSx) with Windows clients
  ingress {
    description = "SMB from on-prem clients"
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  # iSCSI — for Volume Gateway and Tape Gateway
  ingress {
    description = "iSCSI for Volume/Tape Gateway"
    from_port   = 3260
    to_port     = 3260
    protocol    = "tcp"
    cidr_blocks = [var.nfs_client_cidr]
  }

  # Activation port — TCP 80 used only during initial gateway activation
  # SAA-C03 exam note: After activation you can remove this rule.
  ingress {
    description = "Gateway activation (one-time)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound to AWS — gateway must reach S3, IAM, CloudWatch, etc.
  egress {
    description = "HTTPS to AWS services"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP for software updates"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-gateway-sg"
    Lab  = "43-storage-gateway"
  }
}

# =============================================================================
# S3 BUCKETS — ONE PER GATEWAY TYPE
# =============================================================================
#
# SAA-C03: Each Storage Gateway type uses S3 differently:
# • S3 File Gateway:    Each file = one S3 object (preserves metadata in S3)
# • Volume Gateway:     Stores EBS snapshot data (not directly browsable as files)
# • Tape Gateway:       Stores virtual tape contents; archived tapes go to S3 Glacier
#
# Key exam point: S3 File Gateway lets you access files stored in S3 via NFS/SMB
# from on-prem WITHOUT rewriting applications. Data is natively in S3, so other
# AWS services (Lambda, EMR, Athena) can access the same data concurrently.

# S3 bucket for S3 File Gateway file shares
resource "aws_s3_bucket" "file_gateway_bucket" {
  bucket        = "${var.project_name}-file-gateway-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-file-gateway-bucket"
    GatewayType = "S3FileGateway"
    Lab         = "43-storage-gateway"
    Purpose     = "NFS/SMB file shares backed by S3"
  }
}

# Enable versioning on the File Gateway bucket
# SAA-C03: Versioning protects against accidental overwrites/deletes from
# on-prem clients writing through the gateway. The gateway itself does NOT
# manage versioning — S3 versioning is configured independently on the bucket.
resource "aws_s3_bucket_versioning" "file_gateway_versioning" {
  bucket = aws_s3_bucket.file_gateway_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Block public access — S3 File Gateway buckets should NEVER be public
resource "aws_s3_bucket_public_access_block" "file_gateway_public_access" {
  bucket = aws_s3_bucket.file_gateway_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket for Volume Gateway (stores EBS snapshots of iSCSI volumes)
resource "aws_s3_bucket" "volume_gateway_bucket" {
  bucket        = "${var.project_name}-volume-gateway-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-volume-gateway-bucket"
    GatewayType = "VolumeGateway"
    Lab         = "43-storage-gateway"
    Purpose     = "iSCSI volume snapshots (EBS snapshot format)"
  }
}

resource "aws_s3_bucket_public_access_block" "volume_gateway_public_access" {
  bucket = aws_s3_bucket.volume_gateway_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket for Tape Gateway (virtual tape library)
# SAA-C03: Tape Gateway buckets have a TWO-TIER storage model:
#   • Active tapes:   Stored in S3 Standard (like a virtual tape library shelf)
#   • Archived tapes: Moved to S3 Glacier or S3 Glacier Deep Archive
#                     (like sending tapes off-site to Iron Mountain)
# You "eject" a virtual tape to move it from S3 to Glacier (archival).
resource "aws_s3_bucket" "tape_gateway_bucket" {
  bucket        = "${var.project_name}-tape-gateway-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-tape-gateway-bucket"
    GatewayType = "TapeGateway"
    Lab         = "43-storage-gateway"
    Purpose     = "Virtual tape library — active tapes in S3, archived in Glacier"
  }
}

resource "aws_s3_bucket_public_access_block" "tape_gateway_public_access" {
  bucket = aws_s3_bucket.tape_gateway_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# IAM ROLE FOR STORAGE GATEWAY
# =============================================================================
#
# SAA-C03: Storage Gateway uses IAM roles in two contexts:
#   1. The GATEWAY ITSELF needs IAM permissions to write to S3 on your behalf.
#      This is configured via the NFS/SMB file share's "Role ARN" — the gateway
#      assumes this role when storing files in S3.
#   2. S3 BUCKET POLICIES can additionally restrict which gateways can write.
#      Best practice: use BOTH IAM role + bucket policy for defense in depth.
#
# Exam pattern: "Who controls S3 access for Storage Gateway?"
#   → The IAM role attached to the file share + the S3 bucket policy.

resource "aws_iam_role" "storage_gateway_role" {
  name        = "${var.project_name}-gateway-role"
  description = "IAM role assumed by Storage Gateway to access S3"

  # Trust policy: only Storage Gateway service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StorageGatewayAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "storagegateway.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-gateway-role"
    Lab  = "43-storage-gateway"
  }
}

# IAM policy granting the gateway role access to the file share S3 bucket
resource "aws_iam_role_policy" "storage_gateway_s3_policy" {
  name = "${var.project_name}-gateway-s3-policy"
  role = aws_iam_role.storage_gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SAA-C03: GetBucketLocation is required for the gateway to determine
        # the correct S3 endpoint to use. Without this, file share creation fails.
        Sid    = "AllowGetBucketLocation"
        Effect = "Allow"
        Action = ["s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.file_gateway_bucket.arn
        ]
      },
      {
        # ListBucket needed to enumerate files — enables directory listings over NFS/SMB
        Sid    = "AllowListBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [
          aws_s3_bucket.file_gateway_bucket.arn
        ]
      },
      {
        # Object-level permissions — gateway reads, writes, and deletes S3 objects
        # SAA-C03: Each file written via NFS/SMB becomes one S3 object.
        # The S3 key reflects the file path (e.g., /share/reports/q1.csv → reports/q1.csv).
        Sid    = "AllowObjectOperations"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          "${aws_s3_bucket.file_gateway_bucket.arn}/*"
        ]
      }
    ]
  })
}

# =============================================================================
# S3 BUCKET POLICY — File Gateway Bucket
# =============================================================================
#
# SAA-C03: S3 bucket policy provides a SECOND layer of access control.
# Even if the IAM role has permissions, the bucket policy can restrict access
# to only the Storage Gateway service or specific gateway ARNs.
# This prevents other IAM principals from accidentally writing to the bucket.

resource "aws_s3_bucket_policy" "file_gateway_bucket_policy" {
  bucket = aws_s3_bucket.file_gateway_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowStorageGatewayRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.storage_gateway_role.arn
        }
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          aws_s3_bucket.file_gateway_bucket.arn,
          "${aws_s3_bucket.file_gateway_bucket.arn}/*"
        ]
      },
      {
        # Deny all access that doesn't originate from the Storage Gateway service
        # SAA-C03: This is a common hardening pattern — "DenyNonGatewayAccess"
        # Exam note: This would break direct S3 access (e.g., from an EC2 instance
        # or AWS CLI). Only use if the bucket is EXCLUSIVELY for gateway use.
        Sid    = "DenyNonStorageGatewayAccess"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.file_gateway_bucket.arn,
          "${aws_s3_bucket.file_gateway_bucket.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = aws_iam_role.storage_gateway_role.arn
          }
          StringNotEquals = {
            "aws:PrincipalServiceName" = "storagegateway.amazonaws.com"
          }
        }
      }
    ]
  })
}

# =============================================================================
# STORAGE GATEWAY — S3 FILE GATEWAY (PRIMARY DEMO RESOURCE)
# =============================================================================
#
# SAA-C03: S3 FILE GATEWAY USE CASES
# ─────────────────────────────────────────────────────────────────────────────
# • File shares for on-premises applications backed by durable S3 storage
# • Data lake ingestion: on-prem apps write files, cloud analytics reads them
# • Backup target: write backups via NFS, stored in S3 (or S3 Glacier via lifecycle)
# • Hybrid workflows: some processing on-prem, some in the cloud, shared S3 dataset
#
# HOW IT WORKS:
#   On-prem client → NFS/SMB mount → Gateway appliance → S3 PutObject
#   On-prem read   → NFS/SMB read  → Gateway cache (hit) OR S3 GetObject (miss)
#
# LOCAL CACHE:
#   The cache disk stores recently read/written data.
#   Write path:  data → cache → async upload to S3 (write-back cache)
#   Read path:   S3 GetObject → cache → client (subsequent reads hit cache)
#   Exam tip:    If clients report slow reads for frequently accessed files,
#                the cache is too small — increase cache disk size.
#
# BANDWIDTH THROTTLING:
#   SAA-C03: You can configure bandwidth throttle schedules on the gateway.
#   Example: throttle to 10 Mbps during business hours, full speed at night.
#   This prevents gateway backup traffic from saturating on-prem WAN links.
# ─────────────────────────────────────────────────────────────────────────────
#
# NOTE ON ACTIVATION KEY:
#   The activation_key below is a PLACEHOLDER. In a real deployment:
#     1. Start the gateway EC2/VM/hardware appliance
#     2. Call: GET http://<appliance-ip>/?activationRegion=us-east-1
#     3. The response redirects to the Storage Gateway service with a one-time key
#     4. Use that key here
#   The lifecycle block prevents Terraform from trying to update the key after
#   initial creation (the key is consumed on first use).

resource "aws_storagegateway_gateway" "s3_file_gateway" {
  gateway_name     = var.gateway_name
  gateway_timezone = var.gateway_timezone
  gateway_type     = "FILE_S3"

  # activation_key is obtained by hitting port 80 on the appliance.
  # See var.activation_key description for the full process.
  # For this lab, the placeholder value will cause the resource to fail at
  # apply time — all other resources (S3, IAM, VPC) will create successfully.
  activation_key = var.activation_key

  # BANDWIDTH THROTTLE (SAA-C03 exam concept):
  # These optional settings control upload/download rates.
  # Useful when gateway is on-prem and connected via limited WAN link.
  # average_upload_rate_limit_in_bits_per_sec   = 102400  # 100 Kbps example
  # average_download_rate_limit_in_bits_per_sec = 512000  # 500 Kbps example

  lifecycle {
    # Activation key is a one-time token consumed during gateway registration.
    # After creation, ignore changes to this field to prevent unnecessary updates.
    ignore_changes = [activation_key]
  }

  tags = {
    Name        = var.gateway_name
    GatewayType = "FILE_S3"
    Lab         = "43-storage-gateway"
    ExamNote    = "NFS/SMB access to S3; each file = one S3 object"
  }
}

# =============================================================================
# STORAGE GATEWAY — FSx FILE GATEWAY (CONCEPTUAL RESOURCE)
# =============================================================================
#
# SAA-C03: FSX FILE GATEWAY vs S3 FILE GATEWAY
# ─────────────────────────────────────────────────────────────────────────────
# • FSx File Gateway:
#   - Provides on-prem SMB access to an EXISTING FSx for Windows File Server
#   - Supports Active Directory authentication (NTFS permissions, ACLs)
#   - Low-latency local cache for frequently accessed data
#   - Use case: Replace on-prem Windows file servers while keeping familiar SMB UX
#
# • S3 File Gateway:
#   - NFS or SMB access to S3 (files become S3 objects)
#   - No native NTFS permissions — uses POSIX permissions mapped to S3 ACLs
#   - Use case: Data lake ingestion, cloud-native workflows, S3 as primary store
#
# EXAM QUESTION PATTERN:
#   "Company needs Windows file shares with AD auth accessible from on-prem
#    with low latency" → FSx File Gateway
#   "Company needs to migrate file data to S3 accessible via NFS from on-prem"
#    → S3 File Gateway
# ─────────────────────────────────────────────────────────────────────────────
#
# NOTE: aws_storagegateway_gateway with type FILE_FSX requires:
#   1. An existing FSx for Windows File Server filesystem
#   2. SMB settings configured (AD domain join or guest access)
#   3. The gateway appliance deployed and activated
# This resource is commented out to avoid dependency on an FSx filesystem,
# but the configuration pattern is shown for study purposes.
#
# resource "aws_storagegateway_gateway" "fsx_file_gateway" {
#   gateway_name     = "${var.project_name}-fsx-gateway"
#   gateway_timezone = var.gateway_timezone
#   gateway_type     = "FILE_FSX"
#   activation_key   = var.activation_key
#
#   smb_active_directory_settings {
#     domain_name = "corp.example.com"
#     username    = "Admin"
#     password    = "REPLACE_WITH_AD_PASSWORD"  # Use SSM Parameter Store in production
#   }
#
#   lifecycle {
#     ignore_changes = [activation_key, smb_active_directory_settings]
#   }
# }

# =============================================================================
# STORAGE GATEWAY — VOLUME GATEWAY: STORED MODE (CONCEPTUAL)
# =============================================================================
#
# SAA-C03: VOLUME GATEWAY — STORED vs CACHED
# ─────────────────────────────────────────────────────────────────────────────
# STORED MODE:
#   • Primary data: stored ON-PREMISES (local disk)
#   • AWS backup:   async upload of EBS snapshots to S3
#   • Latency:      LOW — all reads/writes hit local disk
#   • Capacity:     Limited by on-prem disk capacity
#   • Recovery:     Create EBS volume from snapshot in AWS → restore on-prem
#   • Use case:     When you need sub-millisecond block storage latency and
#                   want cloud-based disaster recovery via EBS snapshots
#
# CACHED MODE:
#   • Primary data: stored IN S3 (cloud is source of truth)
#   • Local cache:  frequently accessed data cached on-prem (LRU eviction)
#   • Latency:      low for cached data, S3 latency for cache misses
#   • Capacity:     Limited by S3 (effectively unlimited)
#   • Use case:     When you need to expand storage capacity beyond local limits
#                   while keeping low latency for active datasets
#
# EXAM DECISION TREE:
#   Need low latency + local primary storage + cloud DR? → STORED Volume Gateway
#   Need to expand capacity + local cache for hot data?  → CACHED Volume Gateway
#   Need file-level NFS/SMB access?                      → S3 File Gateway
#   Need Windows file shares with AD?                    → FSx File Gateway
#   Have existing tape backup software?                  → Tape Gateway
# ─────────────────────────────────────────────────────────────────────────────
#
# resource "aws_storagegateway_gateway" "stored_volume_gateway" {
#   gateway_name     = "${var.project_name}-stored-volume-gw"
#   gateway_timezone = var.gateway_timezone
#   gateway_type     = "STORED"
#   activation_key   = var.activation_key
#   lifecycle { ignore_changes = [activation_key] }
# }

# =============================================================================
# STORAGE GATEWAY — TAPE GATEWAY (CONCEPTUAL)
# =============================================================================
#
# SAA-C03: TAPE GATEWAY — Virtual Tape Library (VTL)
# ─────────────────────────────────────────────────────────────────────────────
# Tape Gateway presents a VTL interface (iSCSI) to existing backup software.
# Backup applications (Veeam, Veritas NetBackup, Commvault, etc.) see virtual
# tape drives and tape changers — no application changes needed.
#
# VIRTUAL TAPE STORAGE TIERS:
#   • Active tapes (in VTL):  Stored in S3 Standard; fast retrieval
#   • Archived tapes (ejected): Stored in S3 Glacier (hours to restore) or
#                               S3 Glacier Deep Archive (12–48h to restore)
#
# SAA-C03 EXAM PATTERNS:
#   Q: "Migrate from physical tape infrastructure to cloud at lowest cost"
#   A: Tape Gateway → S3 Glacier Deep Archive
#
#   Q: "Tape backup software must continue working without modification"
#   A: Tape Gateway (presents standard VTL interface)
#
#   Q: "Need faster tape retrieval than Glacier Deep Archive"
#   A: Tape Gateway → S3 Glacier (standard retrieval: 3–5 hours)
# ─────────────────────────────────────────────────────────────────────────────
#
# resource "aws_storagegateway_gateway" "tape_gateway" {
#   gateway_name              = "${var.project_name}-tape-gateway"
#   gateway_timezone          = var.gateway_timezone
#   gateway_type              = "VTL"
#   activation_key            = var.activation_key
#   tape_drive_type           = "IBM-ULT3580-TD5"  # Virtual tape drive type
#   medium_changer_type       = "AWS-Gateway-VTL"  # Virtual tape changer
#   lifecycle { ignore_changes = [activation_key] }
# }

# =============================================================================
# STORAGE GATEWAY CACHE DISK CONFIGURATION
# =============================================================================
#
# SAA-C03: CACHE DISK vs UPLOAD BUFFER
# ─────────────────────────────────────────────────────────────────────────────
# Storage Gateway uses LOCAL DISKS attached to the appliance for two purposes:
#
# CACHE DISK (all gateway types):
#   • Stores recently read/written data for low-latency access
#   • Minimum: 150 GiB
#   • Acts as a write-back cache: data written to cache, then uploaded to AWS
#   • Exam: "Clients experience slow reads for frequently accessed files"
#            → Increase cache disk size
#
# UPLOAD BUFFER (Volume Gateway and Tape Gateway only):
#   • Staging area for data being uploaded to AWS
#   • Separate from cache disk
#   • If upload buffer fills up: writes to the gateway stall
#   • Exam: "Gateway is throttling writes / writes are failing"
#            → Increase upload buffer size OR check WAN bandwidth
#
# The aws_storagegateway_cache resource associates a LOCAL DISK (identified by
# disk path or disk ID) with a gateway as its cache storage.
# After gateway activation, you must first discover local disks, then assign them.
# ─────────────────────────────────────────────────────────────────────────────
#
# NOTE: This resource requires a real activated gateway. It is shown here with
# a depends_on to illustrate the relationship. In a lab with a real activation
# key, uncomment the disk_path with the actual EBS volume device path.
#
# resource "aws_storagegateway_cache" "s3_file_gateway_cache" {
#   # disk_path is the device path of the LOCAL DISK on the gateway appliance.
#   # For EC2-based gateway: attach an EBS volume (e.g., /dev/sdb) and use that path.
#   # The gateway console shows available disks after activation.
#   disk_path  = "/dev/sdb"
#   gateway_arn = aws_storagegateway_gateway.s3_file_gateway.arn
#
#   depends_on = [aws_storagegateway_gateway.s3_file_gateway]
# }

# =============================================================================
# NFS FILE SHARE
# =============================================================================
#
# SAA-C03: NFS FILE SHARE (S3 File Gateway)
# ─────────────────────────────────────────────────────────────────────────────
# An NFS file share mounts as a network drive on Linux/Unix/macOS clients.
# Mount command: mount -t nfs -o nolock <gateway-ip>:/<share-name> /mnt/share
#
# KEY SETTINGS:
#   • client_list:    Which IP ranges can mount (source IP filtering)
#   • squash:         Maps root (RootSquash) or all users (AllSquash) to anonymous
#                     SAA-C03: RootSquash prevents root on client from having
#                     root-equivalent access to S3 objects
#   • read_only:      Read-only shares for analytics use cases
#   • object_acl:     How S3 object ACLs are set (bucket-owner-full-control is
#                     recommended when bucket is in a different account)
#   • guess_mime_type: Automatically set Content-Type on S3 objects
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_storagegateway_nfs_file_share" "nfs_share" {
  # gateway_arn ties this file share to the activated gateway
  gateway_arn = aws_storagegateway_gateway.s3_file_gateway.arn

  # The IAM role the gateway assumes to write to S3
  role_arn = aws_iam_role.storage_gateway_role.arn

  # The S3 bucket backing this NFS share
  location_arn = aws_s3_bucket.file_gateway_bucket.arn

  # client_list: restrict NFS mount access to specific CIDRs
  # SAA-C03: This is equivalent to NFS exports configuration — only listed
  # CIDR ranges can mount the share. Defense in depth with the security group.
  client_list = [var.nfs_client_cidr]

  # squash: user mapping for root access
  # "RootSquash" (default): root user on NFS client is mapped to anonymous
  # "AllSquash": all users mapped to anonymous (most restrictive)
  # "NoSquash": root on client has root access to S3 objects (least secure)
  squash = "RootSquash"

  # object_acl: S3 object ACL applied to uploaded files
  # "bucket-owner-full-control" is required when the S3 bucket belongs to a
  # different AWS account than the gateway (cross-account scenario)
  object_acl = "bucket-owner-full-control"

  # read_only: set to true for analytics/read use cases to prevent accidental writes
  read_only = false

  # guess_mime_type: set Content-Type header on S3 objects based on file extension
  # Useful when files will be served from S3 or used in analytics
  guess_mime_type_enabled = true

  # requester_pays: who pays for S3 requests?
  # SAA-C03: requester_pays = true means the requester (not bucket owner) pays.
  # Useful when sharing data with external parties.
  requester_pays = false

  # nfs_file_share_defaults: POSIX permission defaults for new files and directories
  nfs_file_share_defaults {
    directory_mode = "0777"
    file_mode      = "0666"
    group_id       = 65534 # nobody group
    owner_id       = 65534 # nobody user
  }

  # cache_attributes: stale data timeout
  cache_attributes {
    # cache_stale_timeout_in_seconds: how long the gateway waits before
    # checking S3 for a newer version of a cached object.
    # Default: 0 (always check S3). Higher values improve performance
    # but risk serving stale data if S3 objects are modified directly.
    cache_stale_timeout_in_seconds = 300
  }

  depends_on = [
    aws_storagegateway_gateway.s3_file_gateway,
    aws_iam_role_policy.storage_gateway_s3_policy
  ]

  tags = {
    Name     = "${var.project_name}-nfs-share"
    Protocol = "NFS"
    Lab      = "43-storage-gateway"
  }
}

# =============================================================================
# SMB FILE SHARE
# =============================================================================
#
# SAA-C03: SMB FILE SHARE vs NFS FILE SHARE
# ─────────────────────────────────────────────────────────────────────────────
# SMB (Server Message Block) is used by Windows clients.
# NFS is used by Linux/Unix clients.
# S3 File Gateway supports BOTH — you can have both an NFS and SMB share
# pointing to the SAME S3 bucket if needed.
#
# SMB authentication options:
#   • Active Directory: Join gateway to AD domain — users authenticate with
#                       their domain credentials. Full NTFS permission support.
#   • Guest access:     Anyone can connect without credentials. For dev/test only.
#
# EXAM PATTERN:
#   "Windows clients need SMB access to S3-backed file storage with AD auth"
#   → S3 File Gateway with SMB file share + AD integration
#
#   "Need POSIX permissions with NFS + AD not required"
#   → S3 File Gateway with NFS file share
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_storagegateway_smb_file_share" "smb_share" {
  gateway_arn  = aws_storagegateway_gateway.s3_file_gateway.arn
  role_arn     = aws_iam_role.storage_gateway_role.arn
  location_arn = aws_s3_bucket.file_gateway_bucket.arn

  # authentication: "ActiveDirectory" or "GuestAccess"
  # For production: use ActiveDirectory — requires the gateway to be domain-joined
  # For this lab: GuestAccess (no AD domain required)
  authentication = "GuestAccess"

  # access_based_enumeration: when true, users only see files/folders they have
  # access to (like Windows ABE feature). Requires ActiveDirectory auth.
  access_based_enumeration = false

  # admin_user_list: AD users/groups with admin rights to the share
  # (only relevant with ActiveDirectory authentication)
  # admin_user_list = ["AD\\ShareAdmins"]

  # valid_user_list: restrict share access to specific AD users/groups
  # valid_user_list = ["AD\\AllEmployees"]

  # invalid_user_list: deny access to specific AD users/groups
  # invalid_user_list = ["AD\\Contractors"]

  object_acl              = "bucket-owner-full-control"
  read_only               = false
  guess_mime_type_enabled = true
  requester_pays          = false

  # case_sensitivity: "ClientSpecified" (case-sensitive, like Linux) or
  # "ForcedCaseSensitivity" or "CaseInsensitive" (like Windows default)
  case_sensitivity = "ClientSpecified"

  # file_share_name: the share name visible to SMB clients
  # Default: the last part of the location_arn (S3 bucket name)
  # file_share_name = "MyWindowsShare"

  cache_attributes {
    cache_stale_timeout_in_seconds = 300
  }

  depends_on = [
    aws_storagegateway_gateway.s3_file_gateway,
    aws_iam_role_policy.storage_gateway_s3_policy
  ]

  tags = {
    Name     = "${var.project_name}-smb-share"
    Protocol = "SMB"
    Lab      = "43-storage-gateway"
  }
}

# =============================================================================
# S3 LIFECYCLE POLICY — File Gateway Bucket
# =============================================================================
#
# SAA-C03: COMBINING STORAGE GATEWAY WITH S3 LIFECYCLE RULES
# ─────────────────────────────────────────────────────────────────────────────
# Because files written via S3 File Gateway become native S3 objects, you can
# apply standard S3 lifecycle rules to them.
# Example scenario:
#   • Active files (< 30 days): S3 Standard (fast access via gateway cache)
#   • Aging files (30–90 days): S3 Standard-IA (lower cost, same durability)
#   • Archive (> 90 days):      S3 Glacier Instant Retrieval
#   • Long-term (> 180 days):   S3 Glacier Deep Archive
#
# This is transparent to on-prem clients — they still access files via NFS/SMB.
# Retrieval from Glacier incurs latency, so the cache is important here.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "file_gateway_lifecycle" {
  bucket = aws_s3_bucket.file_gateway_bucket.id

  rule {
    id     = "tier-aging-files"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    transition {
      days          = 180
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

# =============================================================================
# SAA-C03 EXAM QUICK REFERENCE — STORAGE GATEWAY DECISION TABLE
# =============================================================================
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ QUESTION TRIGGER           │ ANSWER                                      │
# ├──────────────────────────────────────────────────────────────────────────┤
# │ "NFS from on-prem → S3"    │ S3 File Gateway (NFS share)                 │
# │ "SMB from on-prem → S3"    │ S3 File Gateway (SMB share)                 │
# │ "Windows SMB + AD auth"    │ FSx File Gateway                            │
# │ "Block storage, local fast"│ Volume Gateway STORED                       │
# │ "Block storage, expand cap"│ Volume Gateway CACHED                       │
# │ "Replace physical tapes"   │ Tape Gateway → Glacier                      │
# │ "Tape software unchanged"  │ Tape Gateway (VTL interface)                │
# │ "Data lake from on-prem"   │ S3 File Gateway → S3 + Athena/EMR           │
# │ "Slow reads, frequent use" │ Increase gateway cache disk size            │
# │ "WAN congestion during bkp"│ Enable bandwidth throttling on gateway      │
# │ "Multi-account S3 bucket"  │ File share: object_acl=bucket-owner-full    │
# └──────────────────────────────────────────────────────────────────────────┘
#
# STORAGE GATEWAY vs DATASYNC vs TRANSFER FAMILY:
# • Storage Gateway:   ONGOING hybrid access — on-prem apps continuously use AWS
# • DataSync:          ONE-TIME or scheduled data MIGRATION/SYNC to AWS
# • Transfer Family:   SFTP/FTPS/FTP endpoint in front of S3 or EFS
# =============================================================================
