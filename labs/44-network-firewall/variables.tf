variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "lab-network-firewall"
}

# =============================================================================
# VPC CIDR VARIABLES
# =============================================================================

variable "vpc_cidr" {
  type        = string
  default     = "10.44.0.0/16"
  description = <<-EOT
    CIDR for the inspection VPC.
    SAA-C03: AWS Network Firewall is deployed into a dedicated VPC (or dedicated
    subnets within a VPC). The classic pattern is a centralized "Inspection VPC"
    that sits between an Internet Gateway and workload subnets.
    All traffic is routed through the firewall endpoints before reaching workloads.
  EOT
}

variable "firewall_subnet_cidr_az1" {
  type        = string
  default     = "10.44.1.0/24"
  description = <<-EOT
    CIDR for the firewall subnet in AZ1.
    SAA-C03: EACH Availability Zone requires its own dedicated firewall subnet.
    Network Firewall creates one firewall endpoint (ENI) per AZ subnet.
    Traffic must be routed to the endpoint in the SAME AZ for proper HA.
    Exam trap: If you route cross-AZ through a single firewall endpoint,
    traffic will fail when that AZ is unavailable.
  EOT
}

variable "firewall_subnet_cidr_az2" {
  type        = string
  default     = "10.44.2.0/24"
  description = "CIDR for the firewall subnet in AZ2. See az1 description for HA notes."
}

variable "protected_subnet_cidr_az1" {
  type        = string
  default     = "10.44.11.0/24"
  description = <<-EOT
    CIDR for the protected (workload) subnet in AZ1.
    SAA-C03: Protected subnets contain the workloads whose traffic is inspected.
    Their route tables send 0.0.0.0/0 to the firewall endpoint (not directly
    to the IGW). The firewall endpoint's route table sends inspected traffic
    onward to the IGW.
  EOT
}

variable "protected_subnet_cidr_az2" {
  type        = string
  default     = "10.44.12.0/24"
  description = "CIDR for the protected (workload) subnet in AZ2."
}

# =============================================================================
# LOGGING RETENTION
# =============================================================================

variable "log_retention_days" {
  type        = number
  default     = 30
  description = <<-EOT
    CloudWatch log group retention for Network Firewall logs.
    SAA-C03: Network Firewall supports three log destinations:
      1. Amazon S3            — cost-effective long-term storage, query with Athena
      2. Amazon CloudWatch    — real-time monitoring, metric filters, alarms
      3. Amazon Kinesis Data Firehose — streaming to Splunk, Elasticsearch, S3, etc.
    Two log types:
      • FLOW   — connection-level records (similar to VPC Flow Logs)
      • ALERT  — triggered when a rule fires (DROP or ALERT action)
  EOT
}

# =============================================================================
# FIREWALL MANAGER NOTE VARIABLE (documentation only)
# =============================================================================

variable "firewall_manager_note" {
  type        = string
  default     = "not-configured"
  description = <<-EOT
    SAA-C03: AWS Firewall Manager (FMS) — Exam Key Points
    ─────────────────────────────────────────────────────────────────────
    FMS is a CENTRALIZED SECURITY MANAGEMENT service for multi-account orgs.
    It manages:
      • AWS WAF rules       — across ALBs, CloudFront, API Gateway
      • Network Firewall    — deploy consistent policies across all VPCs/accounts
      • Shield Advanced     — enrollment and protection management
      • Security Groups     — audit and remediate overly permissive rules
      • Route 53 Resolver DNS Firewall

    FMS Requirements:
      • AWS Organizations must be enabled
      • FMS administrator account must be designated
      • All member accounts must have Config enabled (FMS uses Config rules)

    Exam Pattern: "How to enforce Network Firewall policy across 50 AWS accounts
    in an Organization?" → Answer: AWS Firewall Manager.
    ─────────────────────────────────────────────────────────────────────
    This variable is documentation-only; FMS itself is configured outside
    Terraform in a multi-account Organizations setup.
  EOT
}
