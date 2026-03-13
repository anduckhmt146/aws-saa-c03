variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "lab-storage-gateway"
}

# =============================================================================
# GATEWAY CONFIGURATION VARIABLES
# =============================================================================

variable "gateway_name" {
  type        = string
  default     = "lab-s3-file-gateway"
  description = <<-EOT
    Human-readable name for the Storage Gateway.
    Shown in the AWS Console and in CloudWatch metrics.
    SAA-C03: Storage Gateway is identified by name + gateway ARN in exam questions.
  EOT
}

variable "gateway_timezone" {
  type        = string
  default     = "GMT"
  description = <<-EOT
    Timezone for the gateway appliance.
    Used for scheduled maintenance windows and log timestamps.
    Format: "GMT", "GMT+1", "US/Pacific", etc.
  EOT
}

# =============================================================================
# ACTIVATION KEY VARIABLE
# =============================================================================

variable "activation_key" {
  type        = string
  default     = "FAKE-ACTIVATION-KEY-FOR-LAB"
  description = <<-EOT
    SAA-C03 EXAM NOTE — Activation Key Process:
    ─────────────────────────────────────────────────────────────────────
    In production, you obtain the activation_key by:
      1. Deploy the Storage Gateway appliance:
           • As an EC2 instance using the AWS-provided Storage Gateway AMI, OR
           • As a physical/virtual appliance on-premises (VMware ESXi, KVM,
             Hyper-V, or physical hardware appliance)
      2. The appliance listens on TCP port 80 for activation.
      3. From the AWS Console or CLI, you initiate activation by sending
         an HTTP request to the appliance's IP address, which returns a
         one-time activation key.
      4. You provide that key to aws_storagegateway_gateway to complete
         association between the appliance and your AWS account.

    FOR THIS LAB: "FAKE-ACTIVATION-KEY-FOR-LAB" is a placeholder.
    Running terraform apply with this value will fail at the gateway resource
    because no real appliance is reachable. All surrounding AWS-side
    infrastructure (S3 buckets, IAM roles, VPC, security groups) will create
    successfully and represents real SAA-C03 exam-relevant architecture.
    ─────────────────────────────────────────────────────────────────────
  EOT
}

# =============================================================================
# NETWORK VARIABLES
# =============================================================================

variable "vpc_cidr" {
  type        = string
  default     = "10.43.0.0/16"
  description = "CIDR for the VPC used when running Storage Gateway as EC2 AMI."
}

variable "gateway_subnet_cidr" {
  type        = string
  default     = "10.43.1.0/24"
  description = <<-EOT
    Subnet for the Storage Gateway EC2 instance.
    SAA-C03: When deploying Storage Gateway as an EC2 AMI, place it in a
    private subnet. It reaches AWS services via VPC endpoints or NAT Gateway.
    It reaches on-prem clients via VPN or Direct Connect.
  EOT
}

# =============================================================================
# STORAGE VARIABLES
# =============================================================================

variable "cache_disk_size_gb" {
  type        = number
  default     = 150
  description = <<-EOT
    SAA-C03: Local cache disk sizing rules:
    • S3 File Gateway:   Minimum 150 GiB cache disk. Cache stores recently
                         accessed data for low-latency reads. Writes go directly
                         to S3; the cache absorbs bursts.
    • Volume Gateway:    Upload buffer disk (separate from cache) handles data
                         waiting to be uploaded to S3/EBS snapshot. Cache disk
                         stores frequently accessed volume data.
    • Tape Gateway:      Cache disk stores data being written to virtual tapes
                         before upload to S3. Upload buffer holds data in transit.
    Exam tip: Insufficient cache → increased latency and more S3 GET requests.
  EOT
}

variable "nfs_client_cidr" {
  type        = string
  default     = "10.0.0.0/8"
  description = <<-EOT
    CIDR allowed to mount the NFS file share.
    SAA-C03: S3 File Gateway NFS share is accessible only from specific
    client IPs — this is a key security control alongside IAM and bucket policies.
  EOT
}
