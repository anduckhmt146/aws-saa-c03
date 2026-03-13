################################################################################
# Lab 30: Amazon EFS and Amazon FSx
# SAA-C03 Exam Focus: Managed file systems, NFS vs SMB vs Lustre protocols,
#                     performance modes, throughput modes, storage classes,
#                     lifecycle policies, access points, S3 integration
################################################################################
#
# SHARED FILE STORAGE ON AWS — WHEN TO USE WHAT
# -----------------------------------------------
# AWS offers three fully managed file system services. Choosing the right one
# is a core SAA-C03 exam skill:
#
#   EFS (Elastic File System)
#     Protocol  : NFS v4.1 / v4.0
#     OS support: Linux / Unix ONLY (POSIX-compliant)
#     Clients   : Thousands of concurrent EC2, ECS, Lambda, EKS clients
#     Scale     : Petabyte-scale; storage grows and shrinks automatically
#     Pricing   : Pay per GB stored (no pre-provisioning)
#     Exam cues : "Linux", "shared NFS", "auto-scale storage", "multi-AZ", "POSIX"
#
#   FSx for Windows File Server
#     Protocol  : SMB (Server Message Block) 2.0 / 3.0
#     OS support: Windows ONLY
#     Auth      : Active Directory (AWS Managed AD or on-prem AD) — REQUIRED
#     Features  : NTFS permissions, Windows ACLs, DFS namespaces, Shadow Copies (VSS)
#     Pricing   : Pay per GB provisioned + throughput capacity
#     Exam cues : "Windows", "SMB", "Active Directory", "DFS", "NTFS ACLs"
#
#   FSx for Lustre
#     Protocol  : Lustre (parallel distributed file system)
#     OS support: Linux ONLY
#     Performance: Sub-millisecond latency, hundreds of GB/s, millions of IOPS
#     S3 link   : Native data repository integration — files appear from S3 lazily
#     Pricing   : Pay per GB provisioned + optional throughput
#     Exam cues : "HPC", "ML training", "genomics", "high throughput", "parallel FS"
#
# QUICK DECISION TABLE:
# +--------------------------+------------------------+
# | Need                     | Service                |
# +--------------------------+------------------------+
# | Linux shared NFS         | EFS                    |
# | Windows SMB + AD         | FSx for Windows        |
# | HPC / ML parallel FS     | FSx for Lustre         |
# | Multi-protocol NFS+SMB   | FSx for NetApp ONTAP   |
# | Lift-and-shift ZFS       | FSx for OpenZFS        |
# | On-prem → AWS bridge     | Storage Gateway        |
# +--------------------------+------------------------+
#
# PORT REFERENCE (SAA-C03 must know):
#   NFS (EFS)           = TCP 2049
#   SMB (FSx Windows)   = TCP 445
#   Lustre (FSx Lustre) = TCP 988 + TCP 1018-1023
#
################################################################################

################################################################################
# DATA SOURCES
# Use the default VPC and its subnets to keep this lab self-contained.
# The default VPC exists in every AWS region with pre-created subnets in each AZ.
# This avoids creating VPC/subnet/routing resources just to demonstrate EFS/FSx.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Default VPC — automatically created by AWS in every region for every account
data "aws_vpc" "default" {
  default = true
}

# All subnets in the default VPC — one per Availability Zone in most regions
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

################################################################################
# === SECTION 1: KMS KEY FOR EFS ENCRYPTION AT REST ===
#
# EFS supports two encryption-at-rest options:
#   1. AWS-managed key (aws/elasticfilesystem): simpler, no key management needed
#   2. Customer-managed key (CMK): full control over key rotation, key policy,
#      cross-account grants, and key disabling/deletion
#
# SAA-C03 EXAM: "Customer controls the encryption key" or "custom key rotation
# policy" = Customer Managed Key (CMK). AWS-managed keys cannot be disabled,
# scheduled for deletion, or used across accounts.
#
# enable_key_rotation = true: AWS rotates the underlying key material every year.
# The key ARN does NOT change after rotation — existing data stays accessible.
################################################################################

resource "aws_kms_key" "efs" {
  description             = "Customer-managed KMS key for EFS file system encryption at rest"
  deletion_window_in_days = 7 # Minimum 7 days. Key is recoverable during this window.

  # Annual automatic key rotation — AWS replaces the backing key material.
  # Previous versions are retained so data encrypted under old versions can still be read.
  # SAA-C03: Key rotation is transparent — the key ARN stays the same.
  enable_key_rotation = true

  tags = {
    Name    = "lab30-efs-kms-key"
    Purpose = "EFS encryption at rest - demonstrates CMK vs AWS-managed key"
  }
}

resource "aws_kms_alias" "efs" {
  # Aliases make keys human-readable and can be updated to point to new keys
  # without changing the alias reference in your application configs.
  name          = "alias/lab30-efs-key"
  target_key_id = aws_kms_key.efs.key_id
}

################################################################################
# === SECTION 2: AMAZON EFS FILE SYSTEM ===
#
# aws_efs_file_system creates the logical file system and configures its behavior.
# It does NOT create network interfaces — mount targets (Section 3) do that.
#
# EFS PERFORMANCE MODES (set at creation time, CANNOT be changed later):
#
#   generalPurpose (DEFAULT — use this for almost everything):
#     - Lowest per-operation latency (~1–2 ms)
#     - Ideal for: web servers, CMS, home directories, dev/test, code repos
#     - Supports up to 35,000 IOPS
#     - Works with ALL throughput modes
#
#   maxIO (LEGACY — AWS recommends elastic throughput instead):
#     - Higher aggregate throughput and IOPS for massively parallel workloads
#     - Higher per-operation latency (tens of milliseconds) — trade-off
#     - Intended for: big data, media processing, genomics with 1,000+ EC2 clients
#     - SAA-C03 trigger: "tens of thousands of EC2s all writing simultaneously"
#
# EFS THROUGHPUT MODES (can be changed after creation):
#
#   bursting (DEFAULT — throughput scales with storage size):
#     - Baseline: 50 KB/s per GB stored (minimum 1 MB/s)
#     - Burst: up to 100 MB/s for smaller file systems using burst credit tokens
#     - Credits accumulate at baseline when under-utilized; depleted when bursting
#     - Problem: a 10 GB file system gets only ~512 KB/s baseline — often too slow
#     - Best for: infrequent, unpredictable access patterns; dev/test
#
#   provisioned (DECOUPLED — pay for throughput separately from storage):
#     - Specify a fixed MB/s regardless of how much data is stored
#     - Example: 1 GB of data but need 100 MB/s throughput → use provisioned
#     - Use when: your throughput requirement far exceeds what storage size provides
#     - Requires: provisioned_throughput_in_mibps argument
#
#   elastic (RECOMMENDED for most production workloads):
#     - Throughput scales up/down automatically based on actual workload demand
#     - No burst credits, no pre-provisioning — EFS handles scaling transparently
#     - Up to 3 GB/s reads and 1 GB/s writes per file system
#     - Pay per GB of data transferred (not per MB/s provisioned)
#     - Best for: unpredictable or highly variable I/O workloads
#
# SAA-C03 THROUGHPUT MODE SELECTION:
#   "Small file system but needs consistent high throughput" = provisioned
#   "Unpredictable spiky workloads, auto-scaling throughput" = elastic
#   "Low-cost, infrequent access, throughput proportional to storage" = bursting
#
################################################################################

resource "aws_efs_file_system" "main" {
  # ---------------------------------------------------------------------------
  # PERFORMANCE MODE
  # Using generalPurpose for lowest latency — correct for most use cases.
  # Only switch to maxIO if you have confirmed that thousands of EC2 clients
  # are simultaneously hammering the file system.
  # ---------------------------------------------------------------------------
  performance_mode = "generalPurpose"

  # ---------------------------------------------------------------------------
  # THROUGHPUT MODE
  # elastic: automatically scales with workload — no management overhead.
  # For a lab with predictable needs, bursting would also work, but elastic
  # is the current AWS best-practice recommendation for production workloads.
  # ---------------------------------------------------------------------------
  throughput_mode = "elastic"

  # Uncomment to switch to provisioned and fix throughput at 100 MiB/s:
  # throughput_mode                 = "provisioned"
  # provisioned_throughput_in_mibps = 100

  # ---------------------------------------------------------------------------
  # ENCRYPTION AT REST
  # encrypted = true: all data written to disk is encrypted using KMS.
  # kms_key_id: use our CMK instead of the default aws/elasticfilesystem key.
  # Omitting kms_key_id uses the AWS-managed key (simpler but less control).
  #
  # ENCRYPTION IN TRANSIT (separate from at-rest):
  #   Enforced by the NFS mount command: mount -t efs -o tls ...
  #   The -o tls flag tells the EFS mount helper to use TLS for the NFS session.
  #   This lab's file system policy (Section 5) DENIES non-TLS connections.
  # ---------------------------------------------------------------------------
  encrypted  = true
  kms_key_id = aws_kms_key.efs.arn

  # ---------------------------------------------------------------------------
  # LIFECYCLE POLICIES — AUTOMATIC STORAGE TIERING
  #
  # EFS STORAGE CLASSES:
  #
  #   Standard (primary tier):
  #     - For frequently accessed files
  #     - ~$0.30/GB-month (us-east-1)
  #     - Low per-request latency
  #
  #   Standard-IA (Infrequent Access):
  #     - For files not accessed for N days
  #     - ~$0.025/GB-month — about 92% cheaper than Standard per GB stored
  #     - Higher per-request retrieval fee ($0.01 per GB read)
  #     - Files remain accessible transparently — EFS reads from IA with slight overhead
  #
  # LIFECYCLE POLICY DIRECTIONS:
  #   transition_to_ia: Standard → IA after N days without access
  #   transition_to_primary_storage_class: IA → Standard on next access
  #
  # SAA-C03 COST OPTIMIZATION: "Reduce EFS storage cost for infrequently accessed
  # files" = enable lifecycle policy to move files to EFS IA storage class.
  # The trade-off: retrieval fees. If a file is read often enough, Standard is
  # cheaper overall. The lifecycle policy handles this analysis automatically.
  # ---------------------------------------------------------------------------
  lifecycle_policy {
    # After 30 days without any NFS read or write operation, move to IA tier.
    # Other valid values: AFTER_7_DAYS, AFTER_14_DAYS, AFTER_60_DAYS, AFTER_90_DAYS
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    # When a file in IA is accessed, move it back to Standard immediately.
    # This prevents repeated IA retrieval fees for files that become "hot" again.
    # AFTER_1_ACCESS is the only valid value for this direction.
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name     = "lab30-efs-main"
    Purpose  = "SAA-C03 EFS lab: generalPurpose + elastic throughput + IA lifecycle + CMK"
    ExamNote = "EFS = NFS v4.1, Linux only, multi-AZ, elastic storage, pay per GB stored"
  }
}

################################################################################
# === SECTION 3: EFS MOUNT TARGETS (NFS ENDPOINTS PER AZ) ===
#
# A mount target is an NFS endpoint (an ENI with an IP address) placed in a
# specific subnet within a specific Availability Zone.
#
# DESIGN RULES:
#   - Create exactly ONE mount target per AZ for regional (multi-AZ) EFS
#   - EC2 instances in an AZ connect to the mount target in their own AZ
#     (DNS-based routing: the same EFS DNS name resolves to the local AZ mount IP)
#   - All mount targets share the same underlying file system data
#   - Best practice: place mount targets in PRIVATE subnets (no public IP needed)
#
# MULTI-AZ HIGH AVAILABILITY:
#   - Regional EFS: data is redundantly stored across multiple AZs
#   - If one AZ fails, EC2 instances in other AZs continue mounting through their
#     own mount targets without any interruption
#
# MOUNT COMMAND (on EC2, requires amazon-efs-utils package):
#   sudo mount -t efs -o tls <file-system-id>:/ /mnt/efs
#   The "-o tls" flag enforces encryption in transit (TLS/NFS over TLS).
#
# SAA-C03: "EFS is highly available across Availability Zones" — this is because
# each AZ has its own mount target, and data is replicated across AZs internally.
################################################################################

resource "aws_efs_mount_target" "main" {
  # Create one mount target per subnet (one per AZ) in the default VPC.
  # toset() converts the list to a set so for_each uses subnet ID as the key.
  # This dynamically handles regions with 2, 3, 4, or 6 AZs.
  for_each = toset(data.aws_subnets.default.ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value # one subnet = one AZ
  security_groups = [aws_security_group.efs_nfs.id]

  # The mount target gets a private IP in the subnet.
  # EFS DNS: <file-system-id>.efs.<region>.amazonaws.com
  # Route 53 returns the mount target IP in the requesting EC2's AZ.
}

################################################################################
# === SECTION 4: SECURITY GROUP FOR EFS (NFS PORT 2049) ===
#
# EFS uses the NFS v4.1 protocol over TCP port 2049.
# The security group must allow inbound TCP 2049 from the EC2 instances
# that will mount the file system.
#
# BEST PRACTICE IN PRODUCTION:
#   Instead of opening port 2049 to the entire VPC CIDR, use security group
#   referencing: allow port 2049 only FROM the EC2 security group.
#   This gives you source identity rather than just source IP range.
#
# SAA-C03 PORT REFERENCE (memorize):
#   NFS  = TCP 2049  (EFS)
#   SMB  = TCP 445   (FSx for Windows)
#   iSCSI = TCP 3260 (Volume Gateway, iSCSI block storage)
#   Lustre = TCP 988 + 1018-1023 (FSx for Lustre)
################################################################################

resource "aws_security_group" "efs_nfs" {
  name        = "lab30-efs-nfs-sg"
  description = "Allow NFS inbound traffic to EFS mount targets on TCP port 2049"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "NFS protocol from VPC CIDR — port 2049 is the NFS port (always TCP, not UDP)"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
    # Production alternative: use security_groups = [aws_security_group.ec2.id]
    # to restrict access to only your application EC2 instances
  }

  egress {
    description = "Allow all outbound — NFS responses need a return path"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab30-efs-nfs-sg"
  }
}

################################################################################
# === SECTION 5: EFS ACCESS POINTS ===
#
# An EFS access point is an application-specific entry point into a file system.
# Each access point enforces two things:
#
#   1. ROOT DIRECTORY RESTRICTION (path isolation):
#      The access point presents a specific directory (e.g., /app1/data) as the
#      root "/" for all clients using this access point. Clients cannot navigate
#      above this path — chroot-like isolation within the shared file system.
#
#   2. POSIX IDENTITY OVERRIDE (UID/GID enforcement):
#      All NFS writes through this access point appear with the specified
#      UID/GID regardless of what identity the EC2 or Lambda uses locally.
#      This prevents one app from accidentally overwriting another app's files
#      even if they share the same EFS file system.
#
# WHY USE ACCESS POINTS?
#   - Without access points: all clients see the "/" root and must manage their
#     own file ownership and permission structures manually.
#   - With access points: each application/team gets an isolated directory with
#     enforced ownership — no cross-contamination of file data.
#
# SAA-C03 KEY FACTS:
#   - Lambda functions REQUIRE an access point to use EFS (no raw mounts)
#   - ECS tasks can use access points for per-container isolation
#   - creation_info: EFS auto-creates the root directory if it doesn't exist
#
################################################################################

# Access point for Application 1 (e.g., a web application)
resource "aws_efs_access_point" "app1" {
  file_system_id = aws_efs_file_system.main.id

  # ---------------------------------------------------------------------------
  # POSIX USER ENFORCEMENT
  # Any I/O through this access point is executed as uid=1001, gid=1001.
  # If the EC2 process runs as root (uid=0), EFS maps it to uid=1001 instead.
  # secondary_gids: additional group IDs for supplemental permission checks.
  # ---------------------------------------------------------------------------
  posix_user {
    uid            = 1001       # Application service account UID (e.g., "webapp")
    gid            = 1001       # Primary group GID
    secondary_gids = [100, 200] # Optional: additional supplemental groups
  }

  # ---------------------------------------------------------------------------
  # ROOT DIRECTORY — PER-APPLICATION ISOLATED PATH
  # Clients using this access point see /app1/data as their "/" root.
  # They cannot read or write outside /app1/data.
  #
  # creation_info: if /app1/data doesn't exist, EFS creates it automatically
  # on the first mount using the specified owner_uid, owner_gid, and permissions.
  # permissions = "0755" = rwxr-xr-x (owner can write; group and others read + execute)
  # ---------------------------------------------------------------------------
  root_directory {
    path = "/app1/data"

    creation_info {
      owner_uid   = 1001   # Directory owner UID
      owner_gid   = 1001   # Directory owner GID
      permissions = "0755" # rwxr-xr-x
    }
  }

  tags = {
    Name     = "lab30-efs-ap-app1"
    AppName  = "app1"
    Purpose  = "Per-application EFS access point with enforced UID/GID isolation"
    ExamNote = "Access points: root dir restriction + POSIX identity enforcement"
  }
}

# Access point for Lambda functions
# Lambda REQUIRES an access point — it cannot mount EFS without one.
# Lambda runs with UID 1000 in its execution environment by default.
resource "aws_efs_access_point" "lambda" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = 1000 # Lambda execution environment default UID
    gid = 1000 # Lambda execution environment default GID
  }

  root_directory {
    path = "/lambda/cache"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name     = "lab30-efs-ap-lambda"
    Purpose  = "EFS access point for Lambda — Lambda REQUIRES access points for EFS"
    ExamNote = "Lambda + EFS: always use an access point; configure in aws_lambda_function file_system_config"
  }
}

################################################################################
# === SECTION 6: EFS FILE SYSTEM POLICY ===
#
# A file system policy is a resource-based IAM policy attached to the EFS
# file system itself (similar to an S3 bucket policy).
#
# PRIMARY USE CASES:
#   1. Enforce encryption in transit: deny any NFS mount that doesn't use TLS
#   2. Restrict cross-account access
#   3. Deny root access (UID=0) from untrusted principals
#   4. Enforce that only specific IAM roles can mount the file system
#
# HOW ENCRYPTION IN TRANSIT WORKS:
#   - aws:SecureTransport = true means the connection used TLS (HTTPS/NFS-over-TLS)
#   - aws:SecureTransport = false means the connection is unencrypted plain NFS
#   - Denying SecureTransport = false forces all clients to use the -o tls mount option
#
# SAA-C03: "Ensure all EFS connections are encrypted in transit" =
#   EFS file system policy with Deny on aws:SecureTransport = false
#
################################################################################

resource "aws_efs_file_system_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # STATEMENT 1: Deny any NFS mount that is NOT using TLS.
        # This forces all EC2 instances to use: mount -t efs -o tls ...
        # Without this policy, clients could mount EFS without TLS (unencrypted).
        # With this policy, unencrypted connections get an AccessDenied error.
        Sid       = "DenyNonTLSConnections"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "elasticfilesystem:ClientMount"
        Resource  = aws_efs_file_system.main.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        # STATEMENT 2: Allow the account owner full management access.
        # Without this, the Deny-all from Statement 1 could lock everyone out
        # if misapplied (it only denies non-TLS mounts, but this makes intent clear).
        Sid    = "AllowAccountRootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "elasticfilesystem:*"
        Resource = aws_efs_file_system.main.arn
      }
    ]
  })
}

################################################################################
# === SECTION 7: FSx FOR LUSTRE — HPC / ML FILE SYSTEM ===
#
# FSx for Lustre is a fully managed, high-performance parallel file system.
# "Lustre" = Linux + Cluster — designed for parallel I/O across thousands of clients.
#
# KEY CHARACTERISTICS:
#   - Sub-millisecond latencies; hundreds of GB/s aggregate throughput
#   - Scales to petabytes; millions of IOPS
#   - Linux ONLY (no Windows support)
#   - Native S3 integration: S3 objects appear as files in the Lustre namespace
#     without pre-copying (lazy loading — files fetched from S3 on first access)
#   - Modified files can be exported back to S3 (automatic or on-demand)
#
# DEPLOYMENT TYPES — SAA-C03 MUST KNOW:
#
#   SCRATCH_1 (legacy, avoid for new deployments):
#     - Temporary storage; NO data replication within the file system
#     - 200 MB/s/TiB baseline throughput per server
#     - Data is lost if the underlying hardware fails
#     - Use for: very short-lived HPC jobs; input data already in S3
#
#   SCRATCH_2 (preferred scratch — use this for temporary HPC/ML workloads):
#     - Temporary storage; NO replication (data not durable)
#     - 200–1000 MB/s/TiB baseline throughput (6x more burst than SCRATCH_1)
#     - Supports in-transit encryption
#     - Use for: short-lived batch processing; re-runnable jobs; data sourced from S3
#     - SAA-C03: "temporary HPC scratch space, data re-creatable from S3" = SCRATCH_2
#
#   PERSISTENT_1 (legacy persistent):
#     - Replicated WITHIN a single AZ (HA within AZ, not cross-AZ)
#     - 50, 100, or 200 MB/s/TiB throughput options
#     - Supports daily automatic backups
#     - Use for: longer-lived workloads where data durability matters
#
#   PERSISTENT_2 (recommended persistent — NVMe SSD):
#     - Replicated within AZ; lower latency than PERSISTENT_1
#     - 125 or 250 MB/s/TiB throughput
#     - SSD storage only; best-in-class latency and throughput
#     - Use for: latency-sensitive ML training, financial simulations, genomics
#     - SAA-C03: "persistent shared storage for ML training" = PERSISTENT_2
#
# SINGLE-AZ LIMITATION:
#   FSx for Lustre is ALWAYS single-AZ (unlike EFS which is multi-AZ).
#   If the AZ fails, the file system is unavailable.
#   For multi-AZ HPC storage, consider FSx for NetApp ONTAP.
#
# S3 DATA REPOSITORY ASSOCIATION:
#   import_path: S3 URI — files in S3 appear in the Lustre namespace automatically.
#     Lustre does NOT copy files from S3 upfront; it fetches them on first access
#     (lazy loading). Only files actually used are downloaded from S3.
#   export_path: S3 URI — Lustre writes changed/new files back to this S3 path.
#     Use HSM (Hierarchical Storage Management) commands or auto_import_policy to
#     control when exports happen.
#
# SAA-C03 PATTERN: "Process petabytes of training data stored in S3 with
# sub-millisecond latency" = FSx for Lustre linked to S3 as data repository.
#
################################################################################

# S3 bucket to serve as the backing data repository for the Lustre file system.
# In a real HPC or ML scenario, training datasets, model weights, or simulation
# input data are stored here. Lustre presents them as local files.
resource "aws_s3_bucket" "lustre_data" {
  # Include account ID and region to guarantee global uniqueness
  bucket = "lab30-lustre-data-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"

  # force_destroy: allow terraform destroy to delete the bucket even with objects
  # NEVER use in production — objects would be permanently deleted
  force_destroy = true

  tags = {
    Name     = "lab30-lustre-data-repository"
    Purpose  = "S3 data repository for FSx Lustre — stores HPC/ML input and output data"
    ExamNote = "FSx Lustre + S3: lazy loading from S3 on first access, export back on completion"
  }
}

resource "aws_fsx_lustre_file_system" "hpc" {
  # ---------------------------------------------------------------------------
  # SUBNET — SINGLE AZ
  # FSx for Lustre is a single-AZ service. Specify exactly one subnet.
  # Place it in the same AZ as your compute (EC2, EKS worker nodes) to
  # minimize latency and avoid inter-AZ data transfer charges.
  # SAA-C03: Unlike EFS (multi-AZ), FSx Lustre is single-AZ only.
  # ---------------------------------------------------------------------------
  subnet_ids = [data.aws_subnets.default.ids[0]] # Single subnet = single AZ

  security_group_ids = [aws_security_group.fsx_lustre.id]

  # ---------------------------------------------------------------------------
  # DEPLOYMENT TYPE
  # SCRATCH_2: best choice for temporary HPC/ML workloads.
  # Data is NOT preserved on hardware failure or file system deletion.
  # Use when your authoritative data copy lives in S3 and can be re-linked.
  # For durable long-lived storage: use PERSISTENT_2 instead.
  # ---------------------------------------------------------------------------
  deployment_type = "SCRATCH_2"

  # ---------------------------------------------------------------------------
  # STORAGE CAPACITY
  # Must be a multiple of specific values depending on deployment type:
  #   SCRATCH_1:    1200 GiB or multiples of 3600 GiB
  #   SCRATCH_2:    1200 GiB or multiples of 2400 GiB
  #   PERSISTENT_1: multiples of 1200 GiB or 2400 GiB
  #   PERSISTENT_2: multiples of 1200 GiB
  # 1200 GiB is the minimum for SCRATCH_2.
  # ---------------------------------------------------------------------------
  storage_capacity = 1200 # 1.2 TiB — minimum for SCRATCH_2

  # ---------------------------------------------------------------------------
  # STORAGE TYPE
  # SSD (default): low latency, IOPS-intensive; ideal for ML training workloads
  #   with mixed random and sequential I/O patterns
  # HDD: higher throughput per dollar; best for large sequential reads like
  #   genomics pipelines, video transcoding, and media processing workflows
  # NOTE: PERSISTENT_2 supports SSD only; SCRATCH types support both SSD and HDD.
  # ---------------------------------------------------------------------------
  storage_type = "SSD"

  # ---------------------------------------------------------------------------
  # S3 DATA REPOSITORY ASSOCIATION
  #
  # import_path: S3 prefix that Lustre exposes as its root namespace.
  #   Files under s3://.../input/ appear as files in the Lustre FS.
  #   Files are NOT pre-downloaded; they are fetched lazily on first read.
  #   This "lazy loading" pattern saves time when only a subset of S3 data
  #   is actually accessed during a compute job.
  #
  # export_path: S3 prefix where Lustre writes modified files back to S3.
  #   Trigger export with: lfs hsm_archive <file> on the Lustre client,
  #   or set auto_import_policy to keep S3 and Lustre in sync automatically.
  #
  # imported_file_chunk_size: how large each S3 file chunk is when importing.
  #   Default 1024 MiB. Larger chunks = better sequential throughput.
  #   Smaller chunks = better random access for partial file reads.
  # ---------------------------------------------------------------------------
  import_path              = "s3://${aws_s3_bucket.lustre_data.bucket}/input"
  export_path              = "s3://${aws_s3_bucket.lustre_data.bucket}/output"
  imported_file_chunk_size = 1024 # MiB per chunk during S3 → Lustre import

  # auto_import_policy: automatically sync new/changed S3 objects into Lustre.
  # Options: NONE (manual), NEW, NEW_CHANGED, NEW_CHANGED_DELETED
  # Uncomment to enable automatic S3 → Lustre synchronization:
  # auto_import_policy = "NEW_CHANGED"

  # data_compression_type: compress data on-disk using LZ4.
  # Reduces storage footprint and can increase effective throughput for
  # compressible data. "NONE" disables compression.
  data_compression_type = "LZ4"

  tags = {
    Name           = "lab30-fsx-lustre-hpc"
    DeploymentType = "SCRATCH_2"
    Purpose        = "SAA-C03 FSx Lustre: HPC/ML with S3 data repository"
    ExamNote       = "FSx Lustre: sub-ms latency, parallel I/O, S3 integration, Linux-only, single-AZ"
  }
}

################################################################################
# === SECTION 8: SECURITY GROUP FOR FSx LUSTRE ===
#
# Lustre uses a proprietary protocol with specific TCP ports:
#   TCP 988:       Primary port — client-to-server and server-to-server communication
#   TCP 1018-1023: Lustre inter-node communication (OST/MDT metadata and data transfers)
#
# Both ranges must be open within the VPC for Lustre to function correctly.
# Unlike NFS (which only needs one port), Lustre requires a range.
#
################################################################################

resource "aws_security_group" "fsx_lustre" {
  name        = "lab30-fsx-lustre-sg"
  description = "Allow FSx for Lustre protocol traffic on TCP 988 and 1018-1023"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Lustre primary port 988 — client-server and inter-server communication"
    from_port   = 988
    to_port     = 988
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  ingress {
    description = "Lustre inter-node ports 1018-1023 — required for OST/MDT communication"
    from_port   = 1018
    to_port     = 1023
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab30-fsx-lustre-sg"
  }
}

################################################################################
# === SECTION 9: FSx FOR WINDOWS FILE SERVER (COMMENTED — REQUIRES AD) ===
#
# FSx for Windows File Server requires a Microsoft Active Directory domain.
# Creating AWS Managed Microsoft AD costs ~$144/month minimum, so this section
# is provided as commented reference code for SAA-C03 study.
#
# KEY CONCEPTS FOR THE EXAM:
#
# PROTOCOL: SMB (Server Message Block) 2.0 and 3.0
#   - The native Windows network file sharing protocol
#   - NOT compatible with Linux/NFS clients (use EFS for Linux workloads)
#   - Port 445 must be open in security groups
#
# ACTIVE DIRECTORY (REQUIRED — this is the most important constraint):
#   Option A — AWS Managed Microsoft AD:
#     Use aws_directory_service_directory with type = "MicrosoftAD"
#     Provides a fully managed Windows Server Active Directory domain in AWS
#     Supports: Kerberos auth, LDAP, Group Policy, NTLM
#   Option B — Self-managed AD (on-premises):
#     Use self_managed_active_directory block in the FSx resource
#     Provide DNS IPs, domain name, admin username/password, and optional OU path
#
# STORAGE TYPE:
#   SSD: low-latency databases, home directories, content management (~$0.23/GB-month)
#   HDD: large file shares, archive, print servers, higher capacity at lower cost
#   HDD requires: storage_capacity >= 2000 GiB
#
# THROUGHPUT CAPACITY (MB/s):
#   Options: 8, 16, 32, 64, 128, 256, 512, 1024, 2048
#   This determines how much data can be served per second from cache.
#   Higher throughput = higher cost. Scale up/down after creation.
#
# DEPLOYMENT TYPE (HA consideration):
#   SINGLE_AZ_1: single AZ, 1st generation (SSD or HDD)
#   SINGLE_AZ_2: single AZ, 2nd generation (SSD only, lower latency)
#   MULTI_AZ_1:  Active + Standby in two different AZs — automatic failover in ~30s
#                Requires TWO subnet_ids (one per AZ) and preferred_subnet_id
#                Use for production Windows file shares needing HA
#
# DFS NAMESPACES:
#   Allows aggregating multiple FSx shares under a single UNC path
#   e.g., \\corp.example.com\shares\ routes to the correct FSx instance
#   This is configured within Windows — not in Terraform directly
#
# SHADOW COPIES (VSS):
#   Windows Volume Shadow Copy Service creates point-in-time snapshots
#   Users can self-service recover previous file versions from Windows Explorer
#
# SAA-C03 EXAM PATTERNS:
#   "Lift-and-shift Windows file servers"                = FSx for Windows
#   "Windows apps needing SMB shares with AD auth"       = FSx for Windows
#   "DFS namespace for Windows file shares"              = FSx for Windows
#   "High availability Windows shares across 2 AZs"     = FSx for Windows MULTI_AZ_1
#   "Linux and Windows clients on same shared storage"   = FSx for NetApp ONTAP (NFS+SMB)
#
# resource "aws_fsx_windows_file_system" "windows" {
#   # Active Directory: FSx joins this domain during creation.
#   # This is a HARD requirement — there is no way to deploy FSx Windows without AD.
#   active_directory_id = aws_directory_service_directory.managed_ad.id
#
#   # Alternatively, for self-managed (on-prem or existing AD):
#   # self_managed_active_directory {
#   #   dns_ips                                = ["10.0.0.10", "10.0.0.20"]
#   #   domain_name                            = "corp.example.com"
#   #   username                               = "Admin"
#   #   password                               = var.ad_admin_password  # use sensitive variable
#   #   organizational_unit_distinguished_name = "OU=FSx,DC=corp,DC=example,DC=com"
#   # }
#
#   storage_capacity    = 32    # GiB minimum for SSD; 2000 GiB minimum for HDD
#   storage_type        = "SSD" # "SSD" or "HDD"
#   throughput_capacity = 8     # MB/s: 8, 16, 32, 64, 128, 256, 512, 1024, 2048
#
#   # SINGLE_AZ: one subnet
#   subnet_ids = [data.aws_subnets.default.ids[0]]
#
#   # MULTI_AZ_1: two subnets in different AZs + preferred subnet:
#   # deployment_type     = "MULTI_AZ_1"
#   # subnet_ids          = [data.aws_subnets.default.ids[0], data.aws_subnets.default.ids[1]]
#   # preferred_subnet_id = data.aws_subnets.default.ids[0]
#
#   # Security group must allow TCP 445 (SMB) from client subnets
#   security_group_ids = [aws_security_group.fsx_smb.id]
#
#   # Automatic backups: 0–90 days retention; 0 disables backups
#   automatic_backup_retention_days = 7
#   # Backup window: UTC time in "HH:MM" format
#   daily_automatic_backup_start_time = "03:00"
#
#   # Maintenance window: "ddd:HH:MM" format in UTC (7-day week, 0=Sunday)
#   weekly_maintenance_start_time = "1:05:00" # Monday 05:00 UTC
#
#   # Propagate resource tags to automated backup resources
#   copy_tags_to_backups = true
#
#   tags = {
#     Name    = "lab30-fsx-windows"
#     Purpose = "Windows SMB file share with Active Directory authentication"
#   }
# }
#
# SMB SECURITY GROUP (FSx for Windows):
# resource "aws_security_group" "fsx_smb" {
#   name        = "lab30-fsx-smb-sg"
#   description = "Allow SMB traffic to FSx for Windows on TCP 445"
#   vpc_id      = data.aws_vpc.default.id
#
#   ingress {
#     description = "SMB — Windows file sharing protocol; replaces older CIFS (port 139)"
#     from_port   = 445
#     to_port     = 445
#     protocol    = "tcp"
#     cidr_blocks = [data.aws_vpc.default.cidr_block]
#   }
#
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }
#
# AWS MANAGED AD (prerequisite for FSx Windows):
# resource "aws_directory_service_directory" "managed_ad" {
#   name     = "corp.example.com"
#   password = var.ad_admin_password  # use a sensitive Terraform variable
#   edition  = "Standard"             # Standard ($144/mo) or Enterprise ($288/mo)
#   type     = "MicrosoftAD"          # Full Windows Server AD (not SimpleAD)
#
#   vpc_settings {
#     vpc_id     = data.aws_vpc.default.id
#     # AD requires two subnets in different AZs (for its own redundant DCs)
#     subnet_ids = [data.aws_subnets.default.ids[0], data.aws_subnets.default.ids[1]]
#   }
# }
################################################################################
