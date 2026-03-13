###############################################################################
# LAB 42 - AWS Config
# AWS SAA-C03 Exam Prep
###############################################################################
#
# AWS CONFIG
# ===========
# Continuous monitoring and recording of AWS resource configurations.
# Answers the question: "What did my resource look like at any point in time?"
# Maintains a configuration history timeline for every supported resource.
#
# CORE COMPONENTS:
#
# 1. CONFIGURATION RECORDER
#    - Records configuration changes for ALL resources or a specific subset
#    - Stores snapshots in S3; sends change notifications via SNS
#    - One recorder per region per account (you enable/disable it)
#    - SAA-C03: "Track configuration changes" = enable Config recorder
#
# 2. DELIVERY CHANNEL
#    - Defines WHERE to deliver configuration history and snapshots
#    - S3 bucket: stores configuration history files (JSON)
#    - SNS topic: sends notifications for configuration changes
#    - Snapshot frequency: how often to deliver config snapshots (1h, 3h, 6h, 12h, 24h)
#
# 3. CONFIG RULES
#    - Evaluate COMPLIANCE of resources against desired configurations
#    - Two types:
#        Managed Rules: pre-built by AWS (300+ available); just configure parameters
#        Custom Rules:  Lambda function you write; triggered on change or periodic
#    - Evaluation triggers:
#        Configuration change: evaluated when a resource is created/modified/deleted
#        Periodic: evaluated on a schedule (1h, 3h, 6h, 12h, 24h)
#    - Compliance results: COMPLIANT, NON_COMPLIANT, ERROR, NOT_APPLICABLE
#    - SAA-C03: Config rules = compliance checking; NOT preventive controls
#
# 4. REMEDIATION
#    - Automatic or manual remediation via SSM Automation runbooks
#    - Auto-remediation: triggers automatically when resource becomes NON_COMPLIANT
#    - Manual remediation: operator clicks "Remediate" in console
#    - Retry logic: configurable retry count and wait time
#    - SAA-C03: "Auto-fix non-compliant resources" = Config remediation + SSM Automation
#
# 5. CONFORMANCE PACKS
#    - Pre-packaged collections of Config rules + optional remediation actions
#    - Deployed as a single unit (CloudFormation-based)
#    - AWS sample packs: CIS AWS Foundations, PCI DSS, HIPAA, NIST 800-53
#    - Can deploy custom packs to multiple accounts/regions via StackSets
#    - SAA-C03: "Deploy compliance framework across org" = conformance pack
#
# 6. MULTI-ACCOUNT AGGREGATOR
#    - Aggregates compliance data from multiple accounts and regions
#    - Central view of compliance across the organisation
#    - Requires authorisation from source accounts
#    - SAA-C03: "Central compliance dashboard for all accounts" = Config aggregator
#
# IMPORTANT SAA-C03 DISTINCTIONS:
#
#   Config vs CloudTrail:
#     CloudTrail = WHO did WHAT (API calls, API activity log, audit)
#     Config     = WHAT did a resource LOOK LIKE at time T (configuration history)
#     Both together = "who changed the security group and what did it look like before?"
#
#   Config vs Security Hub:
#     Security Hub = aggregated security findings (from GuardDuty, Inspector, Macie, Config)
#     Config       = raw compliance data source; Security Hub consumes Config findings
#
#   Config is NOT real-time blocking:
#     Config DETECTS and RECORDS non-compliance; it does NOT prevent actions.
#     To PREVENT: use IAM policies, SCPs (Service Control Policies), or permission boundaries.
#     SAA-C03: "Prevent users from making S3 buckets public" = SCP or IAM deny policy
#              "Detect and alert when S3 bucket is made public" = Config rule
#
#   Config rule compliance check timing:
#     Change-triggered: within minutes of the resource change
#     Periodic: at the configured interval (hourly to daily)
#
# COMMON SAA-C03 CONFIG RULES:
#   s3-bucket-public-read-prohibited      - S3 buckets must not allow public read
#   s3-bucket-public-write-prohibited     - S3 buckets must not allow public write
#   s3-bucket-server-side-encryption-enabled - S3 buckets must have SSE
#   ec2-instance-no-public-ip             - EC2 instances must not have public IPs
#   encrypted-volumes                     - EBS volumes must be encrypted
#   required-tags                         - Resources must have required tags
#   restricted-ssh                        - Security groups must not allow 0.0.0.0/0:22
#   mfa-enabled-for-iam-console-access    - IAM users must have MFA
#   root-account-mfa-enabled              - Root account must have MFA
#   iam-password-policy                   - IAM password policy must meet requirements
#
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # archive provider: used to build the Lambda ZIP package inline
    # (avoids needing a separate build step or pre-built artifact)
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# VARIABLES
###############################################################################

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "saa-lab42"
}

variable "aggregator_account_ids" {
  description = "List of AWS account IDs to aggregate Config data from"
  type        = list(string)
  default     = [] # Populate with actual account IDs in multi-account setups
}

variable "required_tag_keys" {
  description = "Tag keys that must be present on all evaluated resources"
  type        = list(string)
  default     = ["Environment", "Owner", "CostCenter"]
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

###############################################################################
# S3 BUCKET - CONFIG DELIVERY
#
# Config delivers:
#   - Configuration history files: one per resource type per 6-hour period
#   - Configuration snapshots: point-in-time JSON of all recorded resources
#   - Compliance history
#
# Bucket policy MUST grant Config service write access.
# SAA-C03: Config history files in S3 are searchable via Athena for deep analysis.
###############################################################################

resource "aws_s3_bucket" "config_delivery" {
  bucket        = "${var.project}-config-delivery-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Lab only; remove in production

  tags = {
    Name    = "${var.project}-config-delivery"
    Purpose = "AWS Config configuration history and snapshots"
    Lab     = "42-config"
  }
}

resource "aws_s3_bucket_versioning" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access to the Config delivery bucket
resource "aws_s3_bucket_public_access_block" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: move old Config history to cheaper storage
resource "aws_s3_bucket_lifecycle_configuration" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  rule {
    id     = "config-history-lifecycle"
    status = "Enabled"

    filter {
      prefix = "AWSLogs/"
    }

    # Transition to STANDARD_IA after 90 days (infrequent access but still queryable)
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    # Transition to GLACIER after 365 days (long-term compliance archive)
    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    # Expire after 2555 days (7 years - common compliance retention requirement)
    expiration {
      days = 2555
    }
  }
}

# Bucket policy: grant AWS Config service write access
resource "aws_s3_bucket_policy" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Config checks bucket ACL before writing
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_delivery.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # Config lists the bucket (required for some delivery checks)
        Sid    = "AWSConfigBucketExistenceCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.config_delivery.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        # Config writes configuration history files to this prefix
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_delivery.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

###############################################################################
# SNS TOPIC - CONFIG NOTIFICATIONS
#
# Config can publish notifications for:
#   - Configuration item changes (resource created/modified/deleted)
#   - Config rule compliance changes (COMPLIANT / NON_COMPLIANT)
#   - Delivery status (snapshot delivered, history delivered, etc.)
#
# SAA-C03: Combine SNS notifications with Lambda/email for real-time alerts on
#          compliance changes (e.g., S3 bucket made public → SNS → email alert).
###############################################################################

resource "aws_sns_topic" "config_notifications" {
  name = "${var.project}-config-notifications"

  tags = {
    Name    = "${var.project}-config-notifications"
    Purpose = "AWS Config compliance change notifications"
    Lab     = "42-config"
  }
}

# Allow Config service to publish to this SNS topic
resource "aws_sns_topic_policy" "config_notifications" {
  arn = aws_sns_topic.config_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigSNSPublish"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.config_notifications.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

###############################################################################
# IAM ROLE - AWS CONFIG SERVICE ROLE
#
# Config needs permissions to:
#   - Read resource configurations (ec2:Describe*, s3:GetBucketPolicy, etc.)
#   - Write to S3 delivery bucket
#   - Publish to SNS topic
#
# AWS provides a managed policy: AWSConfigRole (legacy) or
# AWSConfigServiceRolePolicy (newer, for service-linked role).
# Using service-linked role is preferred but requires manual creation.
# Here we use an explicit role with AWSConfigRole for lab clarity.
###############################################################################

data "aws_iam_policy_document" "config_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${var.project}-config-role"
  description        = "IAM role for AWS Config service"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json

  tags = {
    Name = "${var.project}-config-role"
    Lab  = "42-config"
  }
}

resource "aws_iam_role_policy_attachment" "config_aws_managed" {
  role = aws_iam_role.config.name
  # AWS-managed policy granting read access to all AWS resources for Config recording
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRole"
}

# Additional permissions for S3 delivery
data "aws_iam_policy_document" "config_delivery" {
  statement {
    sid    = "ConfigS3Delivery"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetBucketAcl"
    ]
    resources = [
      aws_s3_bucket.config_delivery.arn,
      "${aws_s3_bucket.config_delivery.arn}/*"
    ]
  }

  statement {
    sid       = "ConfigSNSPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.config_notifications.arn]
  }
}

resource "aws_iam_role_policy" "config_delivery" {
  name   = "${var.project}-config-delivery"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_delivery.json
}

###############################################################################
# AWS CONFIG CONFIGURATION RECORDER
#
# The recorder continuously monitors supported AWS resources for changes.
# recording_group options:
#   all_supported = true  : record all supported resource types (recommended)
#   include_global_resource_types = true : also record IAM users, roles, policies
#
# SAA-C03: You must ENABLE the recorder; it can be stopped/started.
#          Stopping does NOT delete history; just pauses new recordings.
###############################################################################

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.project}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    # Record ALL supported resource types in this region
    all_supported = true

    # Include global resources (IAM) - these are recorded in every region you enable this
    # To avoid duplicate recordings, only enable in ONE region (e.g., us-east-1)
    include_global_resource_types = true
  }
}

###############################################################################
# AWS CONFIG DELIVERY CHANNEL
#
# Delivery channel specifies WHERE Config sends configuration data.
# snapshot_delivery_properties controls how often snapshots are delivered.
# Note: The configuration recorder must exist before the delivery channel.
###############################################################################

resource "aws_config_delivery_channel" "main" {
  name           = "${var.project}-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_delivery.id
  sns_topic_arn  = aws_sns_topic.config_notifications.arn

  # How often to deliver configuration snapshots to S3
  # Options: One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours
  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# Enable the recorder AFTER the delivery channel is configured
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

###############################################################################
# AWS CONFIG RULE 1 - s3-bucket-public-read-prohibited
#
# AWS Managed Rule: checks that S3 bucket ACLs do not allow public read access.
# Scope: triggered on S3 bucket configuration changes.
# SAA-C03: Most common Config rule question: detect public S3 buckets.
# Remember: Config DETECTS; SCPs/IAM/Block Public Access PREVENT.
###############################################################################

resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name        = "${var.project}-s3-bucket-public-read-prohibited"
  description = "Checks that S3 buckets do not allow public read access via ACLs"

  source {
    owner             = "AWS" # AWS-managed rule
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  # Scope: only evaluate this rule when S3 bucket resources change
  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  # No input parameters for this rule (some managed rules accept parameters)

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-s3-public-read"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 2 - required-tags
#
# AWS Managed Rule: checks that resources have specific required tags.
# Accepts up to 6 tag key-value pairs as parameters.
# tag1Key is required; tag1Value is optional (checks key existence if omitted).
# SAA-C03: Use required-tags rule for cost allocation and governance enforcement.
###############################################################################

resource "aws_config_config_rule" "required_tags" {
  name        = "${var.project}-required-tags"
  description = "Checks that EC2 instances and S3 buckets have required tags: Environment, Owner, CostCenter"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  scope {
    compliance_resource_types = [
      "AWS::EC2::Instance",
      "AWS::S3::Bucket",
      "AWS::RDS::DBInstance"
    ]
  }

  # Parameters: tagNKey / tagNValue pairs (N = 1..6)
  input_parameters = jsonencode({
    tag1Key = "Environment"
    tag2Key = "Owner"
    tag3Key = "CostCenter"
    # Optionally enforce specific values:
    # tag1Value = "production"
  })

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-required-tags"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 3 - ec2-instance-no-public-ip
#
# AWS Managed Rule: checks that EC2 instances do not have public IP addresses.
# Evaluation trigger: configuration change on EC2 instances.
# SAA-C03: "Detect EC2 instances with public IPs in private subnets" = this rule.
###############################################################################

resource "aws_config_config_rule" "ec2_no_public_ip" {
  name        = "${var.project}-ec2-instance-no-public-ip"
  description = "Checks that EC2 instances are not directly accessible from the internet via public IPs"

  source {
    owner             = "AWS"
    source_identifier = "EC2_INSTANCE_NO_PUBLIC_IP"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-ec2-no-public-ip"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 4 - encrypted-volumes
#
# AWS Managed Rule: checks that EBS volumes attached to EC2 instances are encrypted.
# SAA-C03: Combined with encryption-by-default (account level), this rule provides
#          compliance evidence. Note: enabling encryption-by-default is better prevention.
###############################################################################

resource "aws_config_config_rule" "encrypted_volumes" {
  name        = "${var.project}-encrypted-volumes"
  description = "Checks that all EBS volumes attached to EC2 instances are encrypted"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Volume"]
  }

  # Optional: specify a KMS key ID to require encryption with a specific CMK
  # input_parameters = jsonencode({ kmsId = "arn:aws:kms:..." })

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-encrypted-volumes"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG REMEDIATION - AUTO-REMEDIATE required-tags
#
# Remediation configuration links a Config rule to an SSM Automation document.
# When a resource is NON_COMPLIANT, Config triggers the SSM runbook.
#
# REMEDIATION TYPES:
#   automatic = false : manual remediation (operator initiates in console/CLI)
#   automatic = true  : auto-remediation (Config triggers SSM automatically)
#
# PARAMETERS: Map rule parameters to SSM document parameters.
#   Static: hardcoded values
#   Dynamic: reference event data (e.g., "${RESOURCE_ID}" = the non-compliant resource)
#
# RETRY LOGIC:
#   maximum_automatic_attempts: how many times to retry (max 25)
#   retry_attempt_seconds: wait between retries
#
# SAA-C03: Know that remediation uses SSM Automation; Lambda is NOT used for
#          remediation directly (Lambda is used for custom RULES, not remediation).
###############################################################################

# IAM role that Config assumes to trigger SSM Automation
data "aws_iam_policy_document" "config_remediation_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config_remediation" {
  name               = "${var.project}-config-remediation"
  description        = "Role for SSM Automation to remediate Config non-compliant resources"
  assume_role_policy = data.aws_iam_policy_document.config_remediation_assume.json

  tags = {
    Name = "${var.project}-config-remediation"
    Lab  = "42-config"
  }
}

data "aws_iam_policy_document" "config_remediation" {
  # Allow adding tags to EC2 instances (for required-tags remediation)
  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
  }

  # Allow adding tags to S3 buckets
  statement {
    effect    = "Allow"
    actions   = ["s3:PutBucketTagging"]
    resources = ["*"]
  }

  # Allow reading resource info during automation
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "s3:GetBucketTagging"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "config_remediation" {
  name   = "${var.project}-config-remediation"
  role   = aws_iam_role.config_remediation.id
  policy = data.aws_iam_policy_document.config_remediation.json
}

resource "aws_config_remediation_configuration" "add_required_tags" {
  config_rule_name = aws_config_config_rule.required_tags.name

  # SSM Automation document that adds default tags to non-compliant resources
  # AWS-AddRequiredTags is an AWS-managed runbook for this purpose
  target_type    = "SSM_DOCUMENT"
  target_id      = "AWS-AddRequiredTags"
  target_version = "1" # Specific version for reproducibility

  # Auto-remediation: automatically fix non-compliant resources
  automatic = true

  # Retry up to 5 times before giving up
  maximum_automatic_attempts = 5

  # Wait 60 seconds between retry attempts
  retry_attempt_seconds = 60

  # Parameters passed to the SSM Automation document
  # ResourceType and ResourceId are filled dynamically from the Config event
  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.config_remediation.arn
  }

  parameter {
    name           = "ResourceId"
    resource_value = "RESOURCE_ID" # Dynamic: Config substitutes the non-compliant resource ID
  }

  parameter {
    name         = "TagsToAdd"
    static_value = jsonencode({ "Environment" = "untagged", "Owner" = "untagged" })
  }

  depends_on = [aws_config_config_rule.required_tags]
}

###############################################################################
# AWS CONFIG AGGREGATE AUTHORIZATION
#
# In a multi-account setup, source accounts must AUTHORISE the aggregator account
# to collect their Config data.
# The authorisation is created in the SOURCE account; the aggregator is in a
# separate (management/security) account.
#
# SAA-C03: Aggregator requires:
#   1. aws_config_aggregate_authorization in EACH source account
#   2. aws_config_configuration_aggregator in the AGGREGATOR account
###############################################################################

# This resource is created in source accounts to allow the aggregator account to read Config data
resource "aws_config_aggregate_authorization" "to_aggregator" {
  # The account ID that will aggregate Config data (e.g., security/management account)
  account_id = data.aws_caller_identity.current.account_id # In real use: aggregator account ID
  # NOTE: the `region` argument was removed in recent provider versions (deprecated).
  # The authorisation now applies to all regions automatically; scope is controlled
  # by the aggregator's account_aggregation_source.all_regions setting instead.

  tags = {
    Name = "${var.project}-aggregate-auth"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG CONFIGURATION AGGREGATOR
#
# The aggregator pulls Config data from multiple source accounts/regions
# into a central view.
#
# Aggregator types:
#   account: specify individual account IDs + regions explicitly
#   organization: automatically includes all accounts in the AWS Organization
#
# SAA-C03: Organisation-level aggregator is the scalable choice (auto-adds new accounts).
#          Management account can create an org aggregator without per-account authorisation.
###############################################################################

resource "aws_config_configuration_aggregator" "org_aggregator" {
  name = "${var.project}-org-aggregator"

  # Account-based aggregator (specify accounts explicitly)
  # For org-wide: replace with organization_aggregation_source block
  account_aggregation_source {
    account_ids = length(var.aggregator_account_ids) > 0 ? var.aggregator_account_ids : [data.aws_caller_identity.current.account_id]

    # Aggregate from all regions (recommended for complete visibility)
    all_regions = true

    # OR specify specific regions:
    # regions = ["us-east-1", "us-west-2", "eu-west-1"]
  }

  tags = {
    Name    = "${var.project}-org-aggregator"
    Purpose = "Central Config compliance aggregator"
    Lab     = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 5 - iam-root-access-key-check
#
# AWS Managed Rule: checks that the root account does not have active access keys.
# Root access keys are a critical security risk because root cannot be restricted
# by IAM policies. This is a periodic rule (not change-triggered) since root key
# creation is not a Config-tracked resource change event.
#
# SAA-C03: Root access keys = highest severity finding. Use IAM users/roles instead.
#          Disable root access keys + enable root MFA = foundational security baseline.
###############################################################################

resource "aws_config_config_rule" "iam_root_access_key" {
  name        = "${var.project}-iam-root-access-key-check"
  description = "Checks that the root AWS account does not have active access keys"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  # Periodic rule: no scope block; evaluated on the configured schedule
  # (not triggered by a specific resource change event)

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-root-access-key"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 6 - mfa-enabled-for-iam-console-access
#
# AWS Managed Rule: checks that IAM users who have console passwords have MFA enabled.
# Periodic rule; does not trigger on IAM user changes (IAM is eventually consistent).
#
# SAA-C03: MFA requirement is foundational. Config detects IAM users WITHOUT MFA.
#          To enforce MFA: use IAM policy condition "aws:MultiFactorAuthPresent"
#          (preventive); this Config rule is the detective control.
###############################################################################

resource "aws_config_config_rule" "mfa_iam_console" {
  name        = "${var.project}-mfa-enabled-for-iam-console-access"
  description = "Checks that MFA is enabled for all IAM users with console password access"

  source {
    owner             = "AWS"
    source_identifier = "MFA_ENABLED_FOR_IAM_CONSOLE_ACCESS"
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-mfa-iam-console"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG RULE 7 - restricted-ssh (SECURITY_GROUP_ALLOWS_SSH_FROM_ANYWHERE)
#
# AWS Managed Rule: checks that security groups do not allow unrestricted SSH
# access (port 22 from 0.0.0.0/0 or ::/0).
#
# SAA-C03: Unrestricted SSH is a common security misconfiguration.
#          Preventive: use Session Manager (no port 22 needed at all).
#          Detective: this Config rule.
###############################################################################

resource "aws_config_config_rule" "restricted_ssh" {
  name        = "${var.project}-restricted-ssh"
  description = "Checks that security groups do not allow unrestricted SSH access from 0.0.0.0/0"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "${var.project}-restricted-ssh"
    Lab  = "42-config"
  }
}

###############################################################################
# CUSTOM CONFIG RULE - LAMBDA-BACKED
#
# Custom rules use an AWS Lambda function to evaluate compliance.
# Use custom rules when no AWS managed rule covers your requirement.
#
# HOW IT WORKS:
#   1. Config invokes the Lambda with a JSON payload containing:
#      - configurationItem: the resource configuration snapshot
#      - resultToken: used to call PutEvaluations back to Config
#   2. Lambda evaluates the resource and calls config:PutEvaluations
#      with COMPLIANT / NON_COMPLIANT / NOT_APPLICABLE
#
# TRIGGER TYPES:
#   ConfigurationItemChangeNotification: on resource change
#   OversizedConfigurationItemChangeNotification: when item too large for SNS
#   ScheduledNotification: periodic evaluation
#
# SAA-C03: Know that custom rules require Lambda; managed rules do NOT need Lambda.
#          Lambda must have permission to call config:PutEvaluations.
###############################################################################

# IAM role for the custom rule Lambda function
data "aws_iam_policy_document" "custom_rule_lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "custom_rule_lambda" {
  name               = "${var.project}-custom-rule-lambda"
  description        = "Execution role for the custom Config rule Lambda function"
  assume_role_policy = data.aws_iam_policy_document.custom_rule_lambda_assume.json

  tags = {
    Name = "${var.project}-custom-rule-lambda"
    Lab  = "42-config"
  }
}

resource "aws_iam_role_policy_attachment" "custom_rule_lambda_basic" {
  role = aws_iam_role.custom_rule_lambda.name
  # Basic execution: write logs to CloudWatch Logs
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "custom_rule_lambda_config" {
  statement {
    sid    = "ConfigPutEvaluations"
    effect = "Allow"
    # Lambda must call PutEvaluations to report compliance back to Config
    actions   = ["config:PutEvaluations"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadEC2Tags"
    effect = "Allow"
    # This custom rule checks EC2 instance tags; Lambda needs describe access
    actions   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "custom_rule_lambda_config" {
  name   = "${var.project}-custom-rule-config"
  role   = aws_iam_role.custom_rule_lambda.id
  policy = data.aws_iam_policy_document.custom_rule_lambda_config.json
}

# The Lambda function itself (inline ZIP with a simple Python handler)
data "archive_file" "custom_rule_lambda" {
  type        = "zip"
  output_path = "/tmp/${var.project}-custom-rule.zip"

  source {
    filename = "index.py"
    # Evaluates EC2 instances: compliant if they have a "CostCenter" tag
    content = <<-PYTHON
      import json
      import boto3

      config_client = boto3.client('config')

      def lambda_handler(event, context):
          invoking_event = json.loads(event['invokingEvent'])
          rule_params   = json.loads(event.get('ruleParameters', '{}'))

          # This rule is change-triggered; evaluate the changed configuration item
          config_item = invoking_event.get('configurationItem')
          if not config_item:
              return

          resource_type = config_item['resourceType']
          resource_id   = config_item['resourceId']

          # Only evaluate EC2 instances
          if resource_type != 'AWS::EC2::Instance':
              put_evaluation(event['resultToken'], resource_id, resource_type, 'NOT_APPLICABLE')
              return

          # Check if CostCenter tag is present and non-empty
          tags = config_item.get('tags', {})
          required_tag = rule_params.get('RequiredTag', 'CostCenter')

          if required_tag in tags and tags[required_tag]:
              compliance = 'COMPLIANT'
              annotation = f'Tag {required_tag} is present with value: {tags[required_tag]}'
          else:
              compliance = 'NON_COMPLIANT'
              annotation = f'Tag {required_tag} is missing or empty'

          put_evaluation(event['resultToken'], resource_id, resource_type, compliance, annotation)

      def put_evaluation(result_token, resource_id, resource_type, compliance, annotation=''):
          config_client.put_evaluations(
              Evaluations=[{
                  'ComplianceResourceType': resource_type,
                  'ComplianceResourceId':   resource_id,
                  'ComplianceType':         compliance,
                  'Annotation':             annotation,
                  'OrderingTimestamp':      __import__('datetime').datetime.utcnow()
              }],
              ResultToken=result_token
          )
    PYTHON
  }
}

resource "aws_lambda_function" "custom_config_rule" {
  function_name = "${var.project}-ec2-required-tag-check"
  description   = "Custom Config rule: checks EC2 instances have a required tag (CostCenter)"
  role          = aws_iam_role.custom_rule_lambda.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"
  filename      = data.archive_file.custom_rule_lambda.output_path
  # source_code_hash detects when the Lambda code changes and forces a redeploy
  source_code_hash = data.archive_file.custom_rule_lambda.output_base64sha256

  timeout     = 60  # Config rule evaluations should complete well within 60s
  memory_size = 128 # Minimal memory; this function makes only lightweight API calls

  tags = {
    Name    = "${var.project}-custom-config-rule"
    Purpose = "Custom Config rule for EC2 required-tag compliance check"
    Lab     = "42-config"
  }
}

# Allow Config service to invoke this Lambda function
resource "aws_lambda_permission" "allow_config" {
  statement_id  = "AllowConfigInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.custom_config_rule.function_name
  principal     = "config.amazonaws.com"
  # Restrict to this account to prevent cross-account invocations
  source_account = data.aws_caller_identity.current.account_id
}

# The Config rule referencing our custom Lambda
resource "aws_config_config_rule" "custom_ec2_required_tag" {
  name        = "${var.project}-custom-ec2-required-tag"
  description = "Custom rule: checks EC2 instances have a CostCenter tag (Lambda-backed)"

  source {
    owner = "CUSTOM_LAMBDA" # Distinguishes from AWS-managed rules

    # The Lambda ARN must be specified for custom rules
    source_identifier = aws_lambda_function.custom_config_rule.arn

    # Trigger type: evaluate when EC2 instance configuration changes
    source_detail {
      event_source                = "aws.config"
      message_type                = "ConfigurationItemChangeNotification"
      maximum_execution_frequency = null # Not used for change-triggered rules
    }

    source_detail {
      # Also trigger for oversized config items (items too large for SNS delivery)
      event_source = "aws.config"
      message_type = "OversizedConfigurationItemChangeNotification"
    }
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  # Pass the required tag key as a parameter to the Lambda
  input_parameters = jsonencode({
    RequiredTag = "CostCenter"
  })

  depends_on = [
    aws_config_configuration_recorder_status.main,
    aws_lambda_permission.allow_config
  ]

  tags = {
    Name = "${var.project}-custom-ec2-required-tag"
    Lab  = "42-config"
  }
}

###############################################################################
# AWS CONFIG CONFORMANCE PACK
#
# A conformance pack is a collection of Config rules and optional remediation
# actions packaged together as a YAML template (CloudFormation-based).
#
# DEPLOYMENT:
#   - Deployed per account/region (or org-wide via AWS Organizations)
#   - Immutable after deployment; update by redeploying the pack
#   - Status: COMPLETE, CREATE_IN_PROGRESS, DELETE_IN_PROGRESS, CREATE_FAILED
#
# AWS SAMPLE PACKS (use these for SAA-C03 framework questions):
#   Operational-Best-Practices-for-CIS-AWS-v1.4-Level1
#   Operational-Best-Practices-for-NIST-800-53-rev-4
#   Operational-Best-Practices-for-PCI-DSS-3.2.1
#   Operational-Best-Practices-for-HIPAA-Security
#
# CUSTOM PACKS: define your own set of rules + remediation as a YAML template.
#
# SAA-C03: "Deploy CIS/PCI/NIST compliance controls across org" = conformance pack
#          "Single unit for rules + remediation" = conformance pack
###############################################################################

resource "aws_config_conformance_pack" "operational_best_practices" {
  name = "${var.project}-operational-best-practices"

  # Inline YAML template defining the conformance pack rules
  # In production, reference an S3 template_s3_uri for large packs
  template_body = <<-YAML
    Parameters:
      MaxAccessKeyAge:
        Type: String
        Default: "90"
        Description: "Maximum age in days for IAM access keys before they are considered non-compliant"
    Resources:
      # Rule 1: S3 buckets must not allow public read
      S3BucketPublicReadProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: cp-s3-bucket-public-read-prohibited
          Description: "Checks that S3 buckets do not allow public read access"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket

      # Rule 2: S3 bucket server-side encryption must be enabled
      S3BucketSSEEnabled:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: cp-s3-bucket-server-side-encryption-enabled
          Description: "Checks that S3 bucket default encryption is enabled"
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED
          Scope:
            ComplianceResourceTypes:
              - AWS::S3::Bucket

      # Rule 3: IAM access keys must be rotated within MaxAccessKeyAge days
      AccessKeysRotated:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: cp-access-keys-rotated
          Description: "Checks that IAM user access keys are rotated every 90 days"
          Source:
            Owner: AWS
            SourceIdentifier: ACCESS_KEYS_ROTATED
          InputParameters:
            maxAccessKeyAge: !Ref MaxAccessKeyAge

      # Rule 4: EBS volumes must be encrypted
      EncryptedVolumes:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: cp-encrypted-volumes
          Description: "Checks that EBS volumes attached to EC2 instances are encrypted"
          Source:
            Owner: AWS
            SourceIdentifier: ENCRYPTED_VOLUMES
          Scope:
            ComplianceResourceTypes:
              - AWS::EC2::Volume

      # Rule 5: RDS instances must have backup enabled
      RDSInstanceBackupEnabled:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: cp-rds-instance-backup-enabled
          Description: "Checks that RDS DB instances have automatic backups enabled"
          Source:
            Owner: AWS
            SourceIdentifier: DB_INSTANCE_BACKUP_ENABLED
          Scope:
            ComplianceResourceTypes:
              - AWS::RDS::DBInstance
  YAML

  # Delivery bucket for conformance pack results
  delivery_s3_bucket = aws_s3_bucket.config_delivery.id

  depends_on = [aws_config_configuration_recorder_status.main]
}

# =============================================================================
# CONFIG vs CLOUDTRAIL - SAA-C03 DECISION TABLE
#
# Question asked                                  | Service to use
# ------------------------------------------------+----------------------------
# "What did the security group look like at 3pm?" | AWS Config (config history)
# "Who changed the security group at 3pm?"        | CloudTrail (API activity)
# "Is this S3 bucket compliant right now?"        | AWS Config (compliance check)
# "Who called s3:PutBucketPolicy yesterday?"      | CloudTrail (management event)
# "Alert me when an EC2 is launched in prod"      | CloudTrail + EventBridge rule
# "Show me all non-compliant EBS volumes"         | AWS Config (aggregate query)
# "Enforce tagging policy across the org"         | Config rule + remediation
# "Prevent creating public S3 buckets"            | SCP or IAM deny policy (NOT Config)
#
# KEY INSIGHT: Config is DETECTIVE (finds/records compliance state).
#              CloudTrail is INVESTIGATIVE (who did what, when).
#              SCPs/IAM are PREVENTIVE (block the action before it happens).
#
# CONFIG RETENTION:
#   Configuration items stored in S3 indefinitely (based on bucket lifecycle).
#   Config does not impose its own retention limit; S3 lifecycle controls it.
#   Default 7-year retention is common for compliance frameworks.
#
# RESOURCE RELATIONSHIPS:
#   Config builds a dependency map: EC2 instance → Security Group → VPC → Subnet
#   The Config console "Resource Relationships" view shows these connections.
#   Useful for impact analysis: "which EC2 instances use this security group?"
# =============================================================================
