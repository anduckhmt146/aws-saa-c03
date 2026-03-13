###############################################################################
# LAB 41 - AWS Systems Manager (SSM)
# AWS SAA-C03 Exam Prep
###############################################################################
#
# AWS SYSTEMS MANAGER (SSM)
# ==========================
# Unified operations hub for managing EC2 instances AND on-premises servers.
# No SSH/RDP required; no open inbound ports; no bastion host needed.
# Requires: SSM Agent (pre-installed on Amazon Linux 2/Windows AMIs) + IAM role.
#
# SSM CAPABILITIES (know all for SAA-C03):
#
# 1. SESSION MANAGER
#    - Browser-based interactive shell (or AWS CLI with session-manager-plugin)
#    - No port 22 / 3389 inbound rules needed
#    - Sessions logged to S3 and/or CloudWatch Logs (compliance audit trail)
#    - Works for EC2 AND on-premises servers (hybrid activations)
#    - SAA-C03: "Secure shell access without opening port 22" = Session Manager
#    - SAA-C03: "Replace bastion host" = Session Manager
#
# 2. PATCH MANAGER
#    - Automates OS and application patching for EC2 and on-premises
#    - Patch Baseline: defines WHICH patches to approve (auto/manual approval)
#      - AWS-managed baselines: AWS-DefaultPatchBaseline, AWS-AmazonLinux2DefaultPatchBaseline, etc.
#      - Custom baselines: override AWS defaults with your own approval rules
#    - Patch Groups: associate instances with a specific baseline via EC2 tag "Patch Group"
#    - Maintenance Windows: scheduled time window to run patching (and other tasks)
#    - Patch compliance data stored in SSM Inventory; queryable via Config/Security Hub
#    - SAA-C03: "Automatically patch EC2 at 2 AM every Sunday" = Patch Manager + Maintenance Window
#
# 3. PARAMETER STORE
#    - Hierarchical secure storage for config data and secrets (covered in Lab 33)
#    - Standard (free, 4KB) vs Advanced (larger values, parameter policies, TTL)
#    - Integration with Secrets Manager for secret rotation
#
# 4. RUN COMMAND
#    - Execute scripts or commands across a fleet of instances
#    - No SSH needed; uses SSM Agent as the execution channel
#    - Documents define the command (AWS-managed or custom)
#    - Rate controls: max concurrent executions, error thresholds
#    - Output to S3 or CloudWatch Logs
#    - SAA-C03: "Run a shell script on 200 instances simultaneously" = Run Command
#
# 5. STATE MANAGER
#    - Ensures instances maintain a desired configuration (idempotent)
#    - Associations: link a document + targets + schedule
#    - Example: ensure CloudWatch Agent is always installed and running
#    - SAA-C03: "Enforce configuration drift prevention" = State Manager
#
# 6. INVENTORY
#    - Collects metadata: installed apps, network config, Windows updates, registry
#    - Stores in SSM Managed Instance Inventory; query with Resource Data Sync
#    - SAA-C03: "List all software installed on EC2 fleet" = SSM Inventory
#
# 7. AUTOMATION
#    - Runbooks: multi-step operational playbooks (JSON/YAML)
#    - Example: restart EC2, create AMI, update CloudFormation stack
#    - SAA-C03: "Automate remediation" = SSM Automation (triggered by Config or EventBridge)
#
# 8. OPSCENTER
#    - Aggregates operational issues (OpsItems) from AWS services
#    - Integrates with CloudWatch Alarms, Config rules, Security Hub findings
#
# SAA-C03 QUICK REFERENCE:
#   "No bastion host / no port 22"           → Session Manager
#   "Automate patching on schedule"          → Patch Manager + Maintenance Window
#   "Run script on multiple instances"       → Run Command
#   "Enforce desired state on instances"     → State Manager
#   "View installed software on EC2 fleet"  → SSM Inventory
#
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
  default     = "saa-lab41"
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

###############################################################################
# IAM ROLE FOR EC2 SSM MANAGED INSTANCES
#
# Instances MUST have an IAM instance profile with SSM permissions.
# This is the only requirement (besides SSM Agent) for Session Manager to work.
# No security group inbound rules needed - SSM Agent makes outbound HTTPS calls.
#
# SAA-C03: The instance needs AmazonSSMManagedInstanceCore policy at minimum.
#          For Session Manager logging: add S3/CloudWatch permissions.
###############################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_instance_role" {
  name               = "${var.project}-ssm-instance-role"
  description        = "EC2 instance role granting SSM managed instance access"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name    = "${var.project}-ssm-instance-role"
    Purpose = "Allow EC2 to be managed by SSM (Session Manager, Patch Manager, etc.)"
    Lab     = "41-systems-manager"
  }
}

# Core SSM policy - required for Session Manager, Run Command, Patch Manager
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role = aws_iam_role.ssm_instance_role.name
  # This AWS-managed policy grants: ssm:*, ssmmessages:*, ec2messages:*, s3:GetObject (for SSM)
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent policy - required for pushing logs/metrics
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ssm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Additional inline policy for Session Manager logging and Patch Manager
data "aws_iam_policy_document" "ssm_extra" {
  # Allow writing Session Manager session logs to S3
  statement {
    sid    = "SessionManagerS3Logging"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetEncryptionConfiguration"
    ]
    resources = [
      "arn:aws:s3:::${var.project}-session-logs",
      "arn:aws:s3:::${var.project}-session-logs/*"
    ]
  }

  # Allow writing Session Manager logs to CloudWatch Logs
  statement {
    sid    = "SessionManagerCWLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm_extra" {
  name   = "${var.project}-ssm-extra"
  role   = aws_iam_role.ssm_instance_role.id
  policy = data.aws_iam_policy_document.ssm_extra.json
}

# Instance profile: the container that wraps the IAM role for EC2 attachment
resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ssm-instance-profile"
  role = aws_iam_role.ssm_instance_role.name

  tags = {
    Name = "${var.project}-ssm-instance-profile"
    Lab  = "41-systems-manager"
  }
}

###############################################################################
# SSM PATCH BASELINE - CUSTOM
#
# Patch baselines define the approval rules for patches.
# AWS provides managed baselines (one per OS) but you cannot modify them.
# Create a custom baseline to:
#   - Change approval delays (default is 7 days after release)
#   - Add specific patches by CVE or KB number
#   - Reject specific patches
#   - Configure compliance severity reporting
#
# APPROVAL RULE FIELDS:
#   patch_filter        - filter patches by: CLASSIFICATION, SEVERITY, PRODUCT
#   approve_after_days  - wait N days after patch release before auto-approving
#   compliance_level    - CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED
#   enable_non_security - include non-security patches (e.g., bug fixes)
#
# SAA-C03: Patch groups link instances to baselines via tag "Patch Group" = <group-name>
###############################################################################

resource "aws_ssm_patch_baseline" "amazon_linux2_custom" {
  name             = "${var.project}-al2-baseline"
  description      = "Custom patch baseline for Amazon Linux 2 - approve critical/important after 7 days"
  operating_system = "AMAZON_LINUX_2" # Must match the OS of target instances

  # Approval rules: evaluated in order; a patch is approved if ANY rule matches
  approval_rule {
    # Rule 1: auto-approve critical/important security patches after 7 days
    approve_after_days = 7
    compliance_level   = "CRITICAL" # Instances are CRITICAL non-compliant if missing these

    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security", "Bugfix"]
    }

    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }

  approval_rule {
    # Rule 2: auto-approve moderate security patches after 14 days
    approve_after_days  = 14
    compliance_level    = "HIGH"
    enable_non_security = false

    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security"]
    }

    patch_filter {
      key    = "SEVERITY"
      values = ["Medium", "Low"]
    }
  }

  # Explicitly approve a specific patch regardless of rules (e.g., emergency patch)
  # approved_patches = ["kernel-4.14.301-224.520.amzn2.x86_64"]

  # Explicitly reject a patch known to cause issues
  # rejected_patches = ["python3-3.7.10-1.amzn2.0.1"]

  tags = {
    Name = "${var.project}-al2-baseline"
    Lab  = "41-systems-manager"
  }
}

###############################################################################
# SSM PATCH GROUP
#
# A patch group is a tag-based logical grouping of instances.
# Instances tagged "Patch Group" = <group-name> use the associated baseline.
# One baseline can have multiple patch groups; one instance can be in ONE group.
#
# Registration links a patch group name to a specific baseline.
# Without explicit registration, instances use the AWS-DefaultPatchBaseline.
#
# SAA-C03: "Different patching schedules for dev vs prod" = different Patch Groups
###############################################################################

resource "aws_ssm_patch_group" "production" {
  # This name must match the EC2 tag: "Patch Group" = "production-al2"
  baseline_id = aws_ssm_patch_baseline.amazon_linux2_custom.id
  patch_group = "production-al2"
}

resource "aws_ssm_patch_group" "development" {
  # Dev instances can use the AWS-managed default baseline (less strict)
  # Here we register them against our custom baseline too (for exam completeness)
  baseline_id = aws_ssm_patch_baseline.amazon_linux2_custom.id
  patch_group = "development-al2"
}

###############################################################################
# SSM MAINTENANCE WINDOW
#
# Defines a recurring time window during which SSM can safely run tasks
# (patching, Run Command, Automation, Step Functions, Lambda).
#
# SCHEDULE: cron or rate expressions (same as EventBridge)
# DURATION:  maximum hours the window can stay open (1-24)
# CUTOFF:    stop initiating NEW tasks N hours before window closes
#
# SAA-C03: Maintenance Window = "when" to patch; Patch Group = "which" instances;
#          Patch Baseline = "which" patches. All three work together.
###############################################################################

resource "aws_ssm_maintenance_window" "weekly_patch" {
  name        = "${var.project}-weekly-patching"
  description = "Weekly patching window: Sundays 02:00-05:00 UTC"

  # cron(min hour day-of-month month day-of-week year)
  schedule = "cron(0 2 ? * SUN *)" # Every Sunday at 02:00 UTC

  # Duration: how long the window stays open (hours)
  duration = 3

  # Cutoff: stop registering NEW tasks 1 hour before window closes
  # Prevents starting a long patch job that will exceed the window
  cutoff = 1

  # Allow unregistered targets (instances tagged but not explicitly registered)
  allow_unassociated_targets = false

  # Timezone for the schedule display (not for execution - execution is always UTC)
  schedule_timezone = "UTC"

  enabled = true

  tags = {
    Name = "${var.project}-weekly-patching"
    Lab  = "41-systems-manager"
  }
}

###############################################################################
# SSM MAINTENANCE WINDOW TARGET
#
# Defines WHICH instances participate in this maintenance window.
# Targeting methods:
#   - Tags (recommended): e.g., "Patch Group" = "production-al2"
#   - Resource groups
#   - Specific instance IDs
###############################################################################

resource "aws_ssm_maintenance_window_target" "production_instances" {
  window_id     = aws_ssm_maintenance_window.weekly_patch.id
  name          = "${var.project}-prod-instances"
  description   = "All production AL2 instances in the production patch group"
  resource_type = "INSTANCE" # INSTANCE or RESOURCE_GROUP

  # Target by tag; all instances with this tag are included
  targets {
    key    = "tag:Patch Group"
    values = ["production-al2"]
  }

  # Can add additional tag filters to narrow scope
  targets {
    key    = "tag:Environment"
    values = ["production"]
  }
}

###############################################################################
# SSM MAINTENANCE WINDOW TASK - RUN PATCH BASELINE
#
# Task types:
#   RUN_COMMAND  - execute an SSM document on instances
#   AUTOMATION   - run an SSM Automation runbook
#   STEP_FUNCTIONS - trigger a Step Functions state machine
#   LAMBDA       - invoke a Lambda function
#
# For patching: use RUN_COMMAND with AWS-RunPatchBaseline document.
# AWS-RunPatchBaseline scans for missing patches then installs them.
###############################################################################

# IAM role that the Maintenance Window service assumes to run tasks
data "aws_iam_policy_document" "maintenance_window_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "maintenance_window" {
  name               = "${var.project}-maintenance-window-role"
  description        = "Role assumed by SSM Maintenance Window to run patch tasks"
  assume_role_policy = data.aws_iam_policy_document.maintenance_window_assume.json

  tags = {
    Name = "${var.project}-maintenance-window-role"
    Lab  = "41-systems-manager"
  }
}

resource "aws_iam_role_policy_attachment" "maintenance_window_ssm" {
  role = aws_iam_role.maintenance_window.name
  # Grants permissions to send commands and write results to S3/CloudWatch
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole"
}

resource "aws_ssm_maintenance_window_task" "patch_task" {
  window_id        = aws_ssm_maintenance_window.weekly_patch.id
  name             = "${var.project}-run-patch-baseline"
  description      = "Run AWS-RunPatchBaseline to scan and install missing patches"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline" # AWS-managed document for patching
  service_role_arn = aws_iam_role.maintenance_window.arn

  # Priority: lower number = higher priority (runs first); 1 is highest
  priority = 1

  # Max concurrency: how many instances to patch simultaneously
  # "10%" = patch 10% of targets at a time (rolling update pattern)
  max_concurrency = "10%"

  # Max errors: abort if this many instances fail
  # "10%" = tolerate up to 10% failure rate before aborting
  max_errors = "10%"

  # Associate with the target group defined above
  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.production_instances.id]
  }

  # Task-specific parameters for AWS-RunPatchBaseline
  task_invocation_parameters {
    run_command_parameters {
      # Operation: Scan = check only; Install = apply patches
      # SAA-C03: Use "Scan" during business hours; "Install" in maintenance window
      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      # RebootOption: RebootIfNeeded (default) or NoReboot
      parameter {
        name   = "RebootOption"
        values = ["RebootIfNeeded"]
      }

      # Timeout for each instance (seconds); 600 = 10 minutes per instance
      timeout_seconds = 600

      # Send command output to CloudWatch Logs
      cloudwatch_config {
        cloudwatch_log_group_name = "/ssm/${var.project}/patch-output"
        cloudwatch_output_enabled = true
      }
    }
  }
}

###############################################################################
# SSM DOCUMENT - CUSTOM COMMAND DOCUMENT
#
# SSM Documents define actions to run on instances (or automation steps).
# Document types:
#   Command    - Run Command and State Manager (run scripts/commands)
#   Automation - Automation runbooks (multi-step operational workflows)
#   Session    - Session Manager preferences (shell profile, logging)
#   Package    - Distributor packages (custom software deployment)
#
# Format: JSON or YAML; schema version determines available features.
# AWS provides 400+ pre-built documents; you can create custom ones.
#
# SAA-C03: Know that Run Command uses SSM Documents; custom docs allow custom scripts.
###############################################################################

resource "aws_ssm_document" "install_cloudwatch_agent" {
  name            = "${var.project}-InstallCloudWatchAgent"
  document_type   = "Command"
  document_format = "YAML"

  content = <<-YAML
    schemaVersion: "2.2"
    description: "Install and configure the CloudWatch Agent on Amazon Linux 2"
    parameters:
      ConfigParameter:
        type: String
        description: "SSM Parameter Store path for CW agent config (optional)"
        default: "/cloudwatch-agent/config/default"
    mainSteps:
      - action: aws:configurePackage
        name: InstallCWAgent
        inputs:
          action: Install
          name: AmazonCloudWatchAgent
          # Installs the latest version from SSM Distributor (AWS package repository)
          version: latest
      - action: aws:runShellScript
        name: StartCWAgent
        inputs:
          runCommand:
            - |
              # Load config from Parameter Store and start the agent
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
                -a fetch-config \
                -m ec2 \
                -s \
                -c ssm:{{ ConfigParameter }}
            - echo "CloudWatch Agent configured and started successfully"
  YAML

  tags = {
    Name = "${var.project}-InstallCloudWatchAgent"
    Lab  = "41-systems-manager"
  }
}

###############################################################################
# SSM DOCUMENT - SESSION MANAGER PREFERENCES
#
# Session document type configures Session Manager behaviour:
#   - Shell profile (which shell to use, environment variables)
#   - Logging: encrypt and stream session data to S3 / CloudWatch Logs
#   - Idle session timeout
#   - Run-as: specify Linux user context for sessions (instead of root/ssm-user)
#
# SAA-C03: Logging to S3/CW is an audit/compliance requirement; set via Session document.
###############################################################################

resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell" # Reserved name for default session preferences
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Default Session Manager preferences: log to S3 and CloudWatch"
    sessionType   = "Standard_Stream"
    inputs = {
      # S3 logging: bucket must exist; prefix organises logs by session
      s3BucketName        = "${var.project}-session-logs"
      s3KeyPrefix         = "session-manager-logs/"
      s3EncryptionEnabled = true
      # CloudWatch Logs: stream every session to a log group
      cloudWatchLogGroupName      = "/ssm/session-manager/${var.project}"
      cloudWatchEncryptionEnabled = true
      cloudWatchStreamingEnabled  = true
      # KMS encryption for session data in transit (uses KMS CMK)
      kmsKeyId = ""
      # Run-as: default ssm-user or specify a Linux username
      runAsEnabled     = false
      runAsDefaultUser = ""
      # Shell profile: set environment variables or run init commands
      shellProfile = {
        linux   = "export HISTFILE=/dev/null; echo 'Session started by $(whoami) at $(date)'"
        windows = ""
      }
      # Idle session timeout in minutes (max 60)
      idleSessionTimeout = "20"
    }
  })

  tags = {
    Name = "${var.project}-session-preferences"
    Lab  = "41-systems-manager"
  }
}

###############################################################################
# SSM ASSOCIATION - STATE MANAGER
#
# State Manager associations enforce that instances maintain desired configuration.
# An association = document + targets + schedule + parameters.
# SSM evaluates association compliance on the schedule and after instance boot.
#
# Drift detection: if an instance drifts from desired state (e.g., agent uninstalled),
# State Manager detects it and re-applies the document on next evaluation.
#
# SAA-C03: "Ensure all EC2 instances always have CloudWatch Agent installed" = State Manager
###############################################################################

resource "aws_ssm_association" "cloudwatch_agent" {
  name             = aws_ssm_document.install_cloudwatch_agent.name
  association_name = "${var.project}-ensure-cw-agent"

  # Schedule: how often to check and enforce compliance
  # rate(30 minutes) for frequent checks; cron for daily window checks
  schedule_expression = "rate(1 day)" # Check daily; re-apply if non-compliant

  # Targets: apply to all instances tagged with Environment=production
  targets {
    key    = "tag:Environment"
    values = ["production"]
  }

  # Parameters passed to the SSM document
  parameters = {
    ConfigParameter = "/cloudwatch-agent/config/default"
  }

  # Compliance severity if association fails to apply
  compliance_severity = "MEDIUM"

  # Max concurrency / errors (same semantics as Run Command and Maintenance Window)
  max_concurrency = "20%"
  max_errors      = "5%"

  # Wait for success before moving to next target batch
  wait_for_success_timeout_seconds = 300
}

# =============================================================================
# S3 BUCKET - SESSION MANAGER LOGS
#
# Session Manager can stream every session keystroke to S3 and/or CloudWatch
# Logs for compliance auditing. This bucket stores those session transcripts.
#
# SAA-C03: "Audit trail for shell access without bastion host" =
#          Session Manager + S3 logging (+ optionally KMS encryption).
#
# The bucket name must match what is referenced in the Session Preferences
# document (SSM-SessionManagerRunShell) created above.
# =============================================================================

resource "aws_s3_bucket" "session_logs" {
  # Bucket name referenced in SSM-SessionManagerRunShell document above
  bucket        = "${var.project}-session-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # For lab teardown; do NOT set in production

  tags = {
    Name    = "${var.project}-session-logs"
    Purpose = "Store Session Manager session transcripts for audit compliance"
    Lab     = "41-systems-manager"
  }
}

resource "aws_s3_bucket_versioning" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  versioning_configuration {
    status = "Enabled" # Versioning protects logs from accidental deletion
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  rule {
    apply_server_side_encryption_by_default {
      # Use KMS CMK for session log encryption (not just SSE-S3)
      # This ensures only principals with KMS key access can read session data
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ssm.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  # Block all public access - session logs must never be publicly accessible
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  rule {
    id     = "expire-session-logs"
    status = "Enabled"
    # Transition to cheaper storage after 30 days; expire after 90 days
    # Adjust to match your compliance retention requirements
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 90
    }
  }
}

# =============================================================================
# KMS KEY - SSM ENCRYPTION
#
# Used to encrypt:
#   - SSM SecureString parameters (Parameter Store)
#   - Session Manager session data in S3 and CloudWatch Logs
#
# SAA-C03: SecureString parameters use KMS. By default AWS uses the
#          aws/ssm managed key. A CMK gives you full key policy control,
#          rotation, and cross-account sharing capability.
#
# ROTATION: Enable annual rotation (365 days). AWS rotates the key material
#           but keeps the same key ID - no re-encryption of existing data needed.
# =============================================================================

resource "aws_kms_key" "ssm" {
  description             = "KMS CMK for SSM Parameter Store SecureString and Session Manager encryption"
  deletion_window_in_days = 7 # Minimum 7 days; gives time to recover if accidentally deleted

  # Enable key rotation: AWS automatically creates new key material every year
  # Old key material is kept to decrypt data encrypted with previous versions
  enable_key_rotation = true

  # Key policy: defines who can administer and use this key
  # The root account has full access; restrict further in production
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # Allow SSM service to use this key for SecureString encryption/decryption
        Sid    = "AllowSSMService"
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.project}-ssm-kms-key"
    Purpose = "Encrypt SSM SecureString parameters and Session Manager session data"
    Lab     = "41-systems-manager"
  }
}

resource "aws_kms_alias" "ssm" {
  # Alias makes the key easier to reference by name instead of key ID
  name          = "alias/${var.project}-ssm"
  target_key_id = aws_kms_key.ssm.key_id
}

# =============================================================================
# SSM PARAMETER STORE
#
# PARAMETER TYPES:
#   String      - plain text; any config value (non-sensitive)
#   StringList  - comma-separated list of strings (e.g., allowed IPs)
#   SecureString - encrypted with KMS CMK; for secrets, passwords, API keys
#
# TIERS:
#   Standard  - free; max 4KB per parameter; no parameter policies; 10,000 limit
#   Advanced  - $0.05/parameter/month; max 8KB; supports parameter policies
#               (expiration TTL, notifications via EventBridge)
#
# PATH HIERARCHY:
#   /app/env/key  (e.g., /myapp/prod/db-password)
#   IAM policies can restrict access by path prefix (e.g., /myapp/prod/*)
#   Enables separation of dev vs prod secrets using IAM alone
#
# VERSIONING:
#   Every PutParameter call increments the version number automatically
#   You can retrieve a specific version: {{ssm:/path:version}}
#   No automatic expiry unless you use Advanced + parameter policy
#
# SAA-C03:
#   "Store database password securely, reference in EC2 user data" = SecureString
#   "Hierarchy for different environments"  = path-based (/app/dev/ vs /app/prod/)
#   "Notify when parameter about to expire" = Advanced tier + expiration policy
# =============================================================================

# --- String Parameter: non-sensitive configuration ---
resource "aws_ssm_parameter" "app_config_env" {
  name        = "/${var.project}/app/environment"
  description = "Current deployment environment (non-sensitive config value)"
  type        = "String"
  # Standard tier: free, 4KB max, no parameter policies
  tier  = "Standard"
  value = "production"

  tags = {
    Name = "${var.project}-param-environment"
    Lab  = "41-systems-manager"
  }
}

resource "aws_ssm_parameter" "app_config_log_level" {
  name        = "/${var.project}/app/log-level"
  description = "Application log level (non-sensitive)"
  type        = "String"
  tier        = "Standard"
  value       = "INFO"

  tags = {
    Name = "${var.project}-param-log-level"
    Lab  = "41-systems-manager"
  }
}

# --- StringList Parameter: comma-separated values ---
resource "aws_ssm_parameter" "allowed_cidr_blocks" {
  name        = "/${var.project}/network/allowed-cidrs"
  description = "Comma-separated list of allowed CIDR blocks (StringList type)"
  # StringList: stored as comma-separated, no encryption; useful for lists
  type  = "StringList"
  tier  = "Standard"
  value = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

  tags = {
    Name = "${var.project}-param-allowed-cidrs"
    Lab  = "41-systems-manager"
  }
}

# --- SecureString Parameter: KMS-encrypted secret ---
resource "aws_ssm_parameter" "db_password" {
  name        = "/${var.project}/prod/db-password"
  description = "RDS database master password - encrypted with KMS CMK"
  # SecureString: value is encrypted with KMS before storage
  # Reference in code/user data as: {{ssm:/${var.project}/prod/db-password}}
  type = "SecureString"
  tier = "Standard"

  # key_id: which KMS key to use for encryption
  # Defaults to alias/aws/ssm (AWS-managed) if not specified
  # Using CMK gives you full audit trail in CloudTrail and key policy control
  key_id = aws_kms_key.ssm.arn

  # In real infrastructure use a random_password resource or Secrets Manager
  # This is a placeholder value for lab demonstration
  value = "CHANGE_ME_use_random_password_resource"

  # overwrite: allow Terraform to update if value drifts (for lab use only)
  # In production, rotate via Secrets Manager or a CI/CD pipeline
  overwrite = true

  tags = {
    Name        = "${var.project}-param-db-password"
    Sensitivity = "High"
    Lab         = "41-systems-manager"
  }
}

resource "aws_ssm_parameter" "api_key" {
  name        = "/${var.project}/prod/external-api-key"
  description = "External service API key - encrypted SecureString"
  type        = "SecureString"
  tier        = "Standard"
  key_id      = aws_kms_key.ssm.arn
  value       = "PLACEHOLDER_API_KEY_REPLACE_ME"
  overwrite   = true

  tags = {
    Name        = "${var.project}-param-api-key"
    Sensitivity = "High"
    Lab         = "41-systems-manager"
  }
}

# --- Advanced Parameter: supports parameter policies (expiration, notification) ---
resource "aws_ssm_parameter" "temp_token" {
  name        = "/${var.project}/prod/temp-access-token"
  description = "Temporary access token (Advanced tier - supports expiration policy)"
  type        = "SecureString"
  # Advanced tier: required for parameter policies (TTL/expiration)
  # Cost: $0.05 per advanced parameter per month
  tier      = "Advanced"
  key_id    = aws_kms_key.ssm.arn
  value     = "PLACEHOLDER_TOKEN_REPLACE_ME"
  overwrite = true

  # NOTE: Parameter policies (Expiration, ExpirationNotification, NoChangeNotification)
  # are NOT supported as Terraform resource attributes in the AWS provider.
  # They must be applied after creation via the AWS CLI:
  #
  #   aws ssm put-parameter \
  #     --name "/${var.project}/prod/temp-access-token" \
  #     --overwrite \
  #     --policies '[
  #       {"Type":"Expiration","Version":"1.0","Attributes":{"Timestamp":"2099-12-31T23:59:59.000Z"}},
  #       {"Type":"ExpirationNotification","Version":"1.0","Attributes":{"Before":"7","Unit":"Days"}}
  #     ]'
  #
  # SAA-C03: "Automatically delete temporary credentials after N days" =
  #          Advanced tier parameter + Expiration policy (set via CLI/SDK)
  # SAA-C03: "Notify when a parameter is about to expire" =
  #          Advanced tier + ExpirationNotification policy → EventBridge event

  tags = {
    Name        = "${var.project}-param-temp-token"
    Sensitivity = "High"
    Lab         = "41-systems-manager"
  }
}

# =============================================================================
# SSM DOCUMENT - RUN COMMAND (SHELL SCRIPT)
#
# RUN COMMAND OVERVIEW:
#   Execute commands or scripts across a fleet of managed instances without SSH.
#   Uses the SSM Agent as the execution channel (outbound HTTPS to SSM endpoints).
#
# DOCUMENT TYPES FOR RUN COMMAND:
#   AWS-RunShellScript      - run arbitrary Bash commands on Linux instances
#   AWS-RunPowerShellScript - run PowerShell commands on Windows instances
#   AWS-RunAnsiblePlaybook  - run Ansible playbooks
#   Custom Command docs     - your own parameterized scripts (this example)
#
# RATE CONTROLS (critical for SAA-C03):
#   MaxConcurrency: number or % of targets to run on simultaneously
#     - "10" = run on 10 instances at a time
#     - "25%" = run on 25% of targets simultaneously (rolling)
#   MaxErrors: stop sending to new targets after N failures
#     - "0" = abort on first error (strict)
#     - "10%" = tolerate up to 10% failure rate
#
# OUTPUT OPTIONS:
#   S3 bucket: full command output (stdout/stderr) per instance
#   CloudWatch Logs: stream output for real-time monitoring
#   Console: truncated (2500 bytes) for quick inspection
#
# TARGETING:
#   Instance IDs, tags, resource groups, or all managed instances
#
# SAA-C03: "Execute a script on 500 EC2 instances without SSH" = Run Command
#          "Rolling deployment of config change" = Run Command with MaxConcurrency %
# =============================================================================

resource "aws_ssm_document" "custom_run_command" {
  name            = "${var.project}-CollectSystemInfo"
  document_type   = "Command"
  document_format = "YAML"

  content = <<-YAML
    schemaVersion: "2.2"
    description: |
      Collect system information from managed instances and upload to S3.
      Demonstrates Run Command with parameters and multi-step execution.
    parameters:
      OutputBucket:
        type: String
        description: "S3 bucket to upload system info report"
        default: "REPLACE_WITH_BUCKET_NAME"
      IncludePackageList:
        type: String
        description: "Include installed package list (true/false)"
        default: "true"
        allowedValues:
          - "true"
          - "false"
    mainSteps:
      - action: aws:runShellScript
        name: CollectInfo
        inputs:
          timeoutSeconds: 120
          runCommand:
            - |
              #!/bin/bash
              set -e
              REPORT_FILE="/tmp/system-info-$(hostname)-$(date +%Y%m%d%H%M%S).txt"
              echo "=== System Information Report ===" > "$REPORT_FILE"
              echo "Hostname: $(hostname)" >> "$REPORT_FILE"
              echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)" >> "$REPORT_FILE"
              echo "Uptime: $(uptime)" >> "$REPORT_FILE"
              echo "Memory: $(free -h)" >> "$REPORT_FILE"
              echo "Disk: $(df -h /)" >> "$REPORT_FILE"
              if [ "{{ IncludePackageList }}" = "true" ]; then
                echo "=== Installed Packages ===" >> "$REPORT_FILE"
                rpm -qa --qf "%%{NAME}-%%{VERSION}\\n" 2>/dev/null | sort >> "$REPORT_FILE" \
                  || dpkg -l 2>/dev/null >> "$REPORT_FILE" \
                  || echo "Package manager not detected" >> "$REPORT_FILE"
              fi
              aws s3 cp "$REPORT_FILE" "s3://{{ OutputBucket }}/system-info/$(basename $REPORT_FILE)"
              echo "Report uploaded successfully to S3"
  YAML

  tags = {
    Name    = "${var.project}-CollectSystemInfo"
    Purpose = "Demonstrate Run Command with parameters, rate control, and S3 output"
    Lab     = "41-systems-manager"
  }
}

# =============================================================================
# SSM AUTOMATION DOCUMENT (RUNBOOK)
#
# AUTOMATION vs RUN COMMAND:
#   Run Command     - executes commands ON instances (requires managed instance)
#   Automation      - orchestrates multi-step workflows ACROSS AWS services
#                     Can call APIs, create/modify resources, invoke Lambda, etc.
#                     Does NOT require instances (can work entirely via AWS APIs)
#
# AUTOMATION EXECUTION MODES:
#   Simple       - sequential steps, single account/region
#   Rate control - run against multiple targets with concurrency/error controls
#   Multi-account/region - cross-account/region via AWS Organizations
#
# COMMON USE CASES (SAA-C03):
#   "Automatically stop non-compliant EC2 instances" = Automation triggered by Config
#   "Create AMI backup before patching"              = Automation runbook with EC2 API steps
#   "Remediate Security Hub finding"                 = Automation via EventBridge rule
#
# BUILT-IN RUNBOOKS: AWS-StopEC2Instance, AWS-StartEC2Instance, AWS-CreateImage,
#   AWS-RebootRDSInstance, AWS-UpdateCloudFormationStackWithApproval, etc.
# =============================================================================

resource "aws_ssm_document" "restart_app_automation" {
  name            = "${var.project}-RestartApplicationWithBackup"
  document_type   = "Automation"
  document_format = "YAML"

  content = <<-YAML
    schemaVersion: "0.3"
    description: |
      Automation runbook: create AMI snapshot of EC2 instance, then restart application.
      Demonstrates multi-step Automation with AWS API steps and Run Command integration.
    assumeRole: "{{ AutomationAssumeRole }}"
    parameters:
      InstanceId:
        type: String
        description: "EC2 instance ID to restart the application on"
      AutomationAssumeRole:
        type: String
        description: "IAM role ARN that Automation assumes to perform AWS API calls"
        default: ""
    mainSteps:
      - name: CreateAMIBackup
        action: aws:createImage
        inputs:
          InstanceId: "{{ InstanceId }}"
          ImageName: "pre-restart-backup-{{ InstanceId }}-{{ global:DATE_TIME }}"
          NoReboot: true
        outputs:
          - Name: ImageId
            Selector: $.ImageId
            Type: String
      - name: RestartApplication
        action: aws:runCommand
        inputs:
          DocumentName: AWS-RunShellScript
          InstanceIds:
            - "{{ InstanceId }}"
          Parameters:
            commands:
              - "sudo systemctl restart myapp || echo 'Service restart failed'"
              - "sleep 10"
              - "sudo systemctl status myapp"
        isEnd: true
  YAML

  tags = {
    Name    = "${var.project}-RestartApplicationWithBackup"
    Purpose = "Demonstrate multi-step Automation runbook with AMI backup and Run Command"
    Lab     = "41-systems-manager"
  }
}

# =============================================================================
# SUMMARY: SSM COMPONENT RELATIONSHIPS (SAA-C03 QUICK REFERENCE)
#
# Session Manager:
#   EC2 instance (SSM agent + IAM role AmazonSSMManagedInstanceCore)
#     → SSM endpoints (outbound HTTPS 443; NO inbound port 22 needed)
#     → Session transcripts → S3 (aws_s3_bucket.session_logs) + CloudWatch Logs
#     → Preferences: SSM-SessionManagerRunShell document (logging, shell profile)
#
# Patch Manager:
#   Patch Baseline (defines WHICH patches to approve)
#     → registered to Patch Group (links baseline to EC2 tag "Patch Group")
#     → Maintenance Window Target (which instances by tag)
#     → Maintenance Window (defines WHEN: cron schedule, duration, cutoff)
#     → Maintenance Window Task (runs AWS-RunPatchBaseline document)
#
# Parameter Store hierarchy:
#   /project/env/key  →  IAM conditions restrict access per environment
#   String (plain config) | StringList (CSV) | SecureString (KMS-encrypted)
#   Standard (free, 4KB) | Advanced ($0.05/month, 8KB, expiration policies)
#
# Run Command:
#   SSM Document (Command type) → fleet execution without SSH
#   Rate controls: MaxConcurrency + MaxErrors → safe rolling execution
#   Output: S3 bucket and/or CloudWatch Logs
#
# State Manager:
#   Association = Document + Target + Schedule → enforces desired state
#   Drift detection: re-applies document if instance becomes non-compliant
#
# Automation (Runbooks):
#   Multi-step AWS API orchestration; triggered by EventBridge/Config/manual
#   Can remediate Config findings, create AMIs, restart services, etc.
#
# Distributor: install and update software packages on managed instances
# Inventory:   collect installed software, services, network config metadata
# OpsCenter:   aggregate OpsItems (issues) from CloudWatch/Config/Security Hub
# =============================================================================
