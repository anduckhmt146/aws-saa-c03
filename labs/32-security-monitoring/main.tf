################################################################################
# Lab 32: AWS Security Monitoring Services
# SAA-C03 Exam Focus: Threat detection, data discovery, vulnerability scanning,
#                     finding aggregation, incident investigation
################################################################################
#
# THE FIVE SECURITY MONITORING PILLARS (SAA-C03 MUST KNOW ALL):
#
# 1. AMAZON GUARDDUTY — Intelligent Threat Detection
#    - WHAT: ML-based threat detection; analyzes CloudTrail, VPC Flow Logs, DNS logs
#    - DETECTION: crypto-mining, port scans, unauthorized API calls, C2 callbacks
#    - DOES NOT block or prevent — detection only
#    - Auto-remediation: GuardDuty finding → EventBridge → Lambda → isolate EC2
#    - Multi-account: one GuardDuty administrator account aggregates all member findings
#    - SAA-C03: "compromised EC2 phoning home to botnet" = GuardDuty
#
# 2. AMAZON MACIE — Sensitive Data Discovery in S3
#    - WHAT: ML discovers PII, credentials, financial data, healthcare data in S3
#    - S3 only — does NOT scan EBS, RDS, DynamoDB, or on-prem data
#    - Two finding types: policy findings (bucket exposure) + sensitive data findings
#    - Custom data identifiers: define your own regex for org-specific sensitive data
#    - SAA-C03: "find PII in S3 buckets" or "GDPR/HIPAA data discovery" = Macie
#
# 3. AMAZON INSPECTOR — Vulnerability Assessment
#    - WHAT: automated CVE scanning for EC2 (SSM agent), ECR images, Lambda functions
#    - EC2: scans OS packages; requires SSM agent (no separate Inspector agent since v2)
#    - ECR: scans container images on push and continuously as new CVEs are published
#    - Lambda: scans function code and dependencies
#    - Risk score: combines CVE severity + network reachability (internet-facing = higher)
#    - SAA-C03: "CVE scanning on EC2" or "scan container images for vulnerabilities"
#
# 4. AWS SECURITY HUB — Centralized Finding Aggregation + CSPM
#    - WHAT: aggregates findings from GuardDuty, Macie, Inspector, Config, IAM Analyzer
#    - Normalizes all findings to ASFF (Amazon Security Finding Format)
#    - Standards: CIS AWS Foundations, AWS FSBP, PCI DSS, NIST SP 800-53, SOC 2
#    - Multi-account: administrator account aggregates all member findings
#    - SAA-C03: "single dashboard for all security findings" or "CIS Benchmark" = Security Hub
#
# 5. AMAZON DETECTIVE — Security Incident Investigation
#    - WHAT: behavioral graph using ML + statistical analysis for incident investigation
#    - Ingests: GuardDuty findings, VPC Flow Logs, CloudTrail logs, EKS audit logs
#    - Enables: pivot from a GuardDuty finding to full entity context (who, what, when, where)
#    - NOT prevention — used AFTER a finding to understand impact and scope
#    - SAA-C03: "investigate the scope of a GuardDuty finding" = Detective
#
# CRITICAL EXAM DISTINCTION:
# +---------------+------------------------------------+----------+
# | Service       | Role                               | Prevents?|
# +---------------+------------------------------------+----------+
# | GuardDuty     | Detects threats (ML on logs)       | No       |
# | Macie         | Discovers PII/sensitive data in S3 | No       |
# | Inspector     | Finds CVEs and vulnerabilities     | No       |
# | Security Hub  | Aggregates and scores findings     | No       |
# | Detective     | Investigates incidents post-fact   | No       |
# | Config        | Audits config drift vs rules       | No       |
# | WAF           | Blocks Layer 7 HTTP attacks        | YES      |
# | Shield        | Mitigates DDoS attacks             | YES      |
# | SCP           | Denies unauthorized API actions    | YES      |
# | Security Groups| Blocks unauthorized network flows | YES      |
# +---------------+------------------------------------+----------+
#
# MNEMONIC: GuardDuty=ALARM, Detective=INVESTIGATOR, Macie=DATA COP,
#           Inspector=BUILDING INSPECTOR, Security Hub=COMMAND CENTER
#
################################################################################

################################################################################
# DATA SOURCES
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

################################################################################
# === SECTION 1: KMS KEY FOR ENCRYPTION ===
#
# Security services generate sensitive findings data. Encrypting the S3 bucket
# where findings are stored with a KMS CMK gives you:
#   - Control over who can decrypt (key policy)
#   - Ability to disable decryption by disabling the key
#   - Audit trail in CloudTrail of every key use
#
# SAA-C03: "Encrypt GuardDuty findings at rest with customer-managed keys" =
#   KMS CMK + specify the key ARN in publishing destination configuration.
################################################################################

resource "aws_kms_key" "security" {
  description             = "CMK for encrypting security findings data (GuardDuty, Macie, etc.)"
  deletion_window_in_days = 7

  # Annual key rotation — backing key material replaced automatically.
  # Old versions retained to decrypt previously encrypted data.
  enable_key_rotation = true

  # Key policy: allow GuardDuty service to use this key for findings encryption.
  # Without this policy, GuardDuty cannot write encrypted findings to S3.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Account root has full key management control
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # GuardDuty service principal needs GenerateDataKey + Decrypt to encrypt findings
        # exported to S3. This is required for aws_guardduty_publishing_destination.
        Sid    = "AllowGuardDutyEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
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
    Name    = "lab32-security-findings-kms"
    Purpose = "Encrypt security monitoring findings data at rest"
  }
}

resource "aws_kms_alias" "security" {
  name          = "alias/lab32-security-findings"
  target_key_id = aws_kms_key.security.key_id
}

################################################################################
# === SECTION 2: S3 BUCKET FOR GUARDDUTY FINDINGS ===
#
# GuardDuty can export findings to an S3 bucket for long-term retention,
# SIEM ingestion, and compliance archiving.
#
# GuardDuty findings by default are retained in the GuardDuty console for
# 90 days only. Exporting to S3 provides:
#   - Findings history beyond 90 days
#   - Integration with SIEM tools (Splunk, Sumo Logic, Datadog)
#   - Athena queries over historical findings data
#   - Cross-account centralization (send all findings to security account S3)
#
# The S3 bucket policy MUST explicitly allow the GuardDuty service principal
# to write to the bucket — without this, publishing will fail.
################################################################################

resource "aws_s3_bucket" "guardduty_findings" {
  bucket        = "lab32-guardduty-findings-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = true # lab only

  tags = {
    Name     = "lab32-guardduty-findings"
    Purpose  = "GuardDuty findings export destination — long-term retention and SIEM integration"
    ExamNote = "GuardDuty findings default: 90-day retention. Export to S3 for longer retention."
  }
}

resource "aws_s3_bucket_public_access_block" "guardduty_findings" {
  bucket = aws_s3_bucket.guardduty_findings.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy: allow GuardDuty service to write findings to this bucket.
# GuardDuty uses the service principal guardduty.amazonaws.com to call PutObject.
# The aws:SourceArn condition scopes the permission to the specific detector ARN,
# preventing confused deputy attacks.
resource "aws_s3_bucket_policy" "guardduty_findings" {
  bucket = aws_s3_bucket.guardduty_findings.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGuardDutyGetBucketLocation"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:GetBucketLocation"
        Resource = aws_s3_bucket.guardduty_findings.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowGuardDutyPutObject"
        Effect = "Allow"
        Principal = {
          Service = "guardduty.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.guardduty_findings.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  # Policy must exist before GuardDuty publishing destination is created
  depends_on = [aws_s3_bucket_public_access_block.guardduty_findings]
}

################################################################################
# === SECTION 3: AMAZON GUARDDUTY ===
#
# GuardDuty is a fully managed intelligent threat detection service.
# It continuously analyzes data sources using ML, anomaly detection, and
# threat intelligence to identify malicious or unauthorized activity.
#
# DATA SOURCES (automatically analyzed — no agents, no extra log enablement):
#   - AWS CloudTrail management events: API calls, console sign-ins, IAM changes
#   - VPC Flow Logs: network traffic metadata (source/dest IP, port, protocol, bytes)
#   - Route 53 DNS resolver logs: DNS queries made from within the VPC
#   - (Optional) CloudTrail S3 data events: GetObject, PutObject, DeleteObject on S3
#   - (Optional) EKS audit logs: Kubernetes control plane activity
#   - (Optional) EBS malware scanning: scan EBS volumes attached to flagged EC2s
#   - (Optional) Lambda network activity: monitor Lambda network connections
#   - (Optional) RDS login activity: MySQL and PostgreSQL login attempts
#
# SAA-C03 KEY FACT: GuardDuty does NOT need you to separately enable CloudTrail
# or VPC Flow Logs. It reads independent copies of these logs from AWS infrastructure
# at no cost to you. This is different from CloudTrail or VPC Flow Logs where
# you pay for storage.
#
# FINDING TYPES (examples for the exam):
#   UnauthorizedAccess:EC2/TorIPCaller    — EC2 communicating with TOR exit nodes
#   CryptoCurrency:EC2/BitcoinTool.B      — crypto-mining detected
#   Trojan:EC2/DNSDataExfiltration        — DNS queries to known C2 domains
#   Recon:EC2/PortProbeUnprotectedPort    — port scanning from external IP
#   CredentialAccess:IAMUser/AnomalousBehavior — unusual IAM access patterns
#
# PUBLISHING FREQUENCY:
#   SIX_HOURS (default): findings batch-published every 6 hours
#   ONE_HOUR: published hourly — faster detection-to-response cycle
#   FIFTEEN_MINUTES: fastest — use for automated response workflows
#   SAA-C03: for automated Lambda remediation, use FIFTEEN_MINUTES to minimize
#   the window between detection and automatic response.
#
# MULTI-ACCOUNT MANAGEMENT:
#   - Designate one account as GuardDuty administrator (typically security/audit account)
#   - Enroll member accounts via AWS Organizations
#   - Member accounts' findings aggregate to the administrator account
#   - Members CANNOT disable GuardDuty once enrolled via Organizations
#   - SAA-C03: "centralize security findings across 100 accounts" = GuardDuty + Organizations
#
################################################################################

resource "aws_guardduty_detector" "main" {
  enable = true

  # finding_publishing_frequency: controls how often findings are exported to
  # EventBridge and to the S3 publishing destination.
  # FIFTEEN_MINUTES for fastest automated response; SIX_HOURS for cost optimization.
  finding_publishing_frequency = "SIX_HOURS"

  tags = {
    Name     = "lab32-guardduty-detector"
    ExamNote = "GuardDuty is REGIONAL — enable in each region separately. Regional findings only."
  }
}

# ---------------------------------------------------------------------------
# GUARDDUTY OPTIONAL PROTECTION PLANS
# Each additional data source is an optional opt-in feature with additional cost.
# In Terraform AWS provider v5+, these are configured as separate resources
# rather than inline datasources blocks.
# ---------------------------------------------------------------------------

# S3 PROTECTION: monitors S3 data events (GetObject, PutObject, DeleteObject)
# for suspicious activity like large-scale data exfiltration.
# SAA-C03: Default GuardDuty does NOT analyze S3 data events — only management
# events. S3 Protection must be explicitly enabled as an opt-in feature.
resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# EKS AUDIT LOG MONITORING: analyzes EKS control plane audit logs for
# suspicious container activity: privilege escalation, crypto-mining containers,
# suspicious API calls from pods.
# Set to DISABLED in this lab since we have no EKS cluster.
resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "DISABLED"
  # Enable when you have EKS clusters to protect
}

# EBS MALWARE PROTECTION: when GuardDuty raises a finding on an EC2 instance,
# it can snapshot the attached EBS volumes and scan them for malware using an
# out-of-band approach (no agent needed on the instance).
resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "DISABLED"
  # Enable to scan EBS volumes when GuardDuty raises an EC2-related finding
}

# ---------------------------------------------------------------------------
# GUARDDUTY PUBLISHING DESTINATION
# Exports all findings to an S3 bucket for long-term storage and SIEM ingestion.
#
# destination_type: S3 is the only currently supported destination type.
# kms_key_arn: encrypts the exported findings data at rest using the CMK.
#   GuardDuty needs kms:GenerateDataKey and kms:Decrypt on this key
#   (configured in the KMS key policy in Section 1).
#
# SAA-C03: GuardDuty findings are retained in the console for 90 days.
# Publishing to S3 is the only way to retain findings beyond 90 days.
# ---------------------------------------------------------------------------
resource "aws_guardduty_publishing_destination" "s3" {
  detector_id     = aws_guardduty_detector.main.id
  destination_arn = aws_s3_bucket.guardduty_findings.arn
  kms_key_arn     = aws_kms_key.security.arn

  destination_type = "S3"

  # Depends on the bucket policy and KMS key policy being in place before
  # GuardDuty attempts to validate it can write to the destination
  depends_on = [
    aws_s3_bucket_policy.guardduty_findings,
    aws_kms_key.security
  ]
}

################################################################################
# === SECTION 4: AMAZON MACIE ===
#
# Macie uses machine learning to automatically discover, classify, and protect
# sensitive data stored in Amazon S3.
#
# WHAT MACIE FINDS:
#   PII:          Names, email addresses, phone numbers, dates of birth, SSNs
#   Financial:    Credit card numbers, bank routing numbers, IBAN numbers
#   Healthcare:   PHI (Protected Health Information) — relevant for HIPAA
#   Credentials:  AWS access keys, private keys, passwords found in S3 objects
#   Custom:       Any regex pattern you define via custom data identifiers
#
# HOW MACIE WORKS:
#   1. Bucket inventory: Macie automatically inventories ALL S3 buckets in the
#      account and evaluates bucket-level security posture:
#        - Is the bucket publicly accessible?
#        - Are objects encrypted?
#        - Is the bucket shared cross-account?
#      These generate "policy findings" without running any classification job.
#
#   2. Classification jobs: you explicitly trigger scans of S3 object CONTENT.
#      Jobs can be ONE_TIME (ad-hoc) or SCHEDULED (recurring).
#      The job reads objects and applies ML models + managed data identifiers
#      + custom data identifiers to find sensitive data patterns.
#      Findings from jobs are "sensitive data findings."
#
# MACIE FINDINGS ROUTING:
#   Findings are published to EventBridge automatically.
#   Can integrate with Security Hub (Macie findings appear in Security Hub dashboard).
#   Can trigger SNS → email, or EventBridge → Lambda for automated response.
#
# COST MODEL:
#   - Bucket inventory: flat monthly fee per bucket monitored
#   - Classification jobs: per-GB scanned fee
#   - Cost control: use sampling_percentage and scoping to limit what's scanned
#
# SAA-C03 EXAM TRAPS:
#   - Macie is S3 ONLY — it cannot scan RDS, DynamoDB, EBS, on-prem data
#   - Macie does NOT block access — it only detects and reports
#   - "Find credit card numbers accidentally uploaded to S3" = Macie
#   - "Prevent upload of PII to S3" = S3 Object Lambda + custom Lambda function
#
################################################################################

resource "aws_macie2_account" "main" {
  status = "ENABLED"

  # finding_publishing_frequency: how often Macie publishes sensitive data findings.
  # Options: FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS
  # Policy findings (bucket-level) are always published immediately.
  finding_publishing_frequency = "SIX_HOURS"
}

# S3 bucket simulating a data lake that Macie will scan.
# In production, this would contain customer records, financial transactions,
# healthcare records, or any other data requiring sensitive data compliance.
resource "aws_s3_bucket" "data_lake" {
  bucket        = "lab32-data-lake-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = true

  tags = {
    Name        = "lab32-data-lake"
    Sensitivity = "high"
    Compliance  = "PII-GDPR-HIPAA"
    Purpose     = "Target bucket for Macie sensitive data classification job"
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# MACIE CUSTOM DATA IDENTIFIER
# Define your own sensitive data detection pattern using regex.
#
# Use when AWS's built-in managed data identifiers don't cover your specific
# data format. Examples:
#   - Employee ID numbers: EMP-\d{7}
#   - Internal account numbers: ACCT-[A-Z]{2}-\d{8}
#   - Customer reference codes: CUS\d{10}
#
# keywords: one or more words that must appear near the regex match.
#   Reduces false positives by requiring context around the pattern.
#   Example: "employee ID" must appear within 50 characters of the regex match.
#
# maximum_match_distance: how far (in characters) a keyword can be from the
#   regex match while still being considered context. Default is 50.
#
# ignore_words: strings that, if present, indicate the match is NOT sensitive.
#   Example: "TEST", "SAMPLE" — discard matches in test data files.
#
# SAA-C03: custom data identifiers let Macie find organization-specific data
# that AWS's built-in detectors don't cover out of the box.
# ---------------------------------------------------------------------------
resource "aws_macie2_custom_data_identifier" "employee_id" {
  name        = "lab32-employee-id-pattern"
  description = "Detects internal employee ID numbers in the format EMP-XXXXXXX"

  # Regex pattern: employee ID format (e.g., EMP-1234567)
  regex = "EMP-\\d{7}"

  # keywords: the pattern is only flagged if one of these words appears nearby
  # within maximum_match_distance characters of the regex match
  keywords = ["employee", "employee id", "emp id", "staff id"]

  # maximum_match_distance: characters between keyword and regex match (default 50)
  maximum_match_distance = 50

  # ignore_words: if these strings appear in the matching context, suppress the finding
  # Useful to avoid false positives from test files or documentation
  ignore_words = ["TEST", "SAMPLE", "EXAMPLE", "TEMPLATE"]

  depends_on = [aws_macie2_account.main]

  tags = {
    Name    = "lab32-employee-id-identifier"
    Purpose = "Custom Macie identifier: detect internal employee IDs in S3 objects"
  }
}

# ---------------------------------------------------------------------------
# MACIE CLASSIFICATION JOB
# Triggers Macie to scan the content of S3 objects for sensitive data.
#
# job_type:
#   ONE_TIME:  runs once immediately; stops when all current objects are scanned.
#              Use for: ad-hoc compliance checks, incident response scans.
#   SCHEDULED: runs on a recurring schedule (daily, weekly, monthly).
#              Use for: continuous compliance monitoring of growing data lakes.
#
# s3_job_definition.bucket_definitions: list of accounts and buckets to scan.
# s3_job_definition.scoping: filter objects by prefix, tag, or last modified date.
#   Omitting scoping = scan ALL objects in all specified buckets.
#
# managed_data_identifier_selector: which of Macie's built-in ML models to use.
#   ALL (default): use all managed identifiers (PII, financial, credentials, etc.)
#   NONE: only use custom data identifiers (cheaper if you only need custom patterns)
#   RECOMMENDED: use Macie's curated subset of highest-confidence identifiers
#
# SAA-C03 COST CONTROL: set sampling_percentage < 100 to scan only a portion
# of objects. Useful for large buckets where full scan is prohibitively expensive.
# ---------------------------------------------------------------------------
resource "aws_macie2_classification_job" "data_lake_scan" {
  name     = "lab32-data-lake-pii-scan"
  job_type = "ONE_TIME"

  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [aws_s3_bucket.data_lake.bucket]
    }

    # Use all managed data identifiers (built-in ML models for PII, financial, etc.)
    # plus our custom employee ID identifier defined above
  }

  # custom_data_identifier_ids: link custom identifiers to this job.
  # Macie will apply both managed identifiers AND these custom patterns.
  custom_data_identifier_ids = [aws_macie2_custom_data_identifier.employee_id.id]

  depends_on = [aws_macie2_account.main]

  tags = {
    Name    = "lab32-macie-scan"
    Purpose = "Scan data lake bucket for PII, credentials, and employee IDs"
  }
}

################################################################################
# === SECTION 5: AMAZON INSPECTOR v2 ===
#
# Inspector v2 (current version — always assume v2 on the exam) performs automated
# vulnerability assessments across three resource types:
#
# EC2 SCANNING:
#   - Scans OS packages and network reachability for CVEs
#   - Requires: SSM agent installed and running on the EC2 instance
#   - No separate Inspector agent needed (v2 improvement over v1)
#   - SAA-C03: "EC2 instance without SSM agent" = Inspector shows as "unmanaged"
#   - Network reachability: identifies which ports are reachable from the internet
#     and correlates with CVEs on those ports for risk scoring
#
# ECR CONTAINER IMAGE SCANNING:
#   - Scans images on push AND continuously rescans when new CVEs are published
#   - Agentless — no changes to your CI/CD pipeline required beyond enabling Inspector
#   - SAA-C03: "scan container images for CVEs on every push to ECR" = Inspector
#
# LAMBDA FUNCTION SCANNING:
#   - Scans Lambda function code and third-party package dependencies
#   - Identifies known CVEs in npm, pip, maven packages used by the function
#   - LAMBDA_CODE: deeper analysis of the function code itself (not just dependencies)
#
# RISK SCORING:
#   Inspector combines:
#     - CVSS base score (severity of the vulnerability itself)
#     - Network reachability (is the port exposed to the internet?)
#   A critical CVE on an internet-facing EC2 scores HIGHER than the same CVE
#   on an isolated internal instance, prioritizing what to fix first.
#
# INSPECTOR vs SECURITY HUB:
#   Inspector GENERATES vulnerability findings → sends them to Security Hub
#   Security Hub AGGREGATES findings from Inspector + GuardDuty + Macie + Config
#
# SAA-C03 EXAM:
#   "Inspector does NOT block deployments" — it only reports vulnerabilities.
#   "Inspector does NOT patch instances" — use SSM Patch Manager for that.
#   "Inspector does NOT scan non-AWS workloads" — AWS resources only.
#
################################################################################

resource "aws_inspector2_enabler" "main" {
  account_ids = [data.aws_caller_identity.current.account_id]

  # resource_types: which resource categories to enable scanning for.
  # EC2:         scan EC2 instances for OS CVEs (requires SSM agent)
  # ECR:         scan container images pushed to ECR (agentless)
  # LAMBDA:      scan Lambda dependencies for CVEs
  # LAMBDA_CODE: deeper code-level analysis of Lambda functions
  resource_types = ["EC2", "ECR"]

  # SAA-C03: Inspector v2 is regional — enable separately in each region.
  # For org-wide enablement: use Inspector delegated admin via Organizations.
}

################################################################################
# === SECTION 6: AWS SECURITY HUB ===
#
# Security Hub is a Cloud Security Posture Management (CSPM) service that:
#   1. AGGREGATES findings from multiple AWS security services into one dashboard
#   2. NORMALIZES findings to ASFF (Amazon Security Finding Format)
#   3. EVALUATES your environment against compliance standards
#
# FINDING SOURCES (automatic after enabling):
#   - Amazon GuardDuty
#   - Amazon Macie
#   - Amazon Inspector
#   - AWS Config (via Security Hub integration)
#   - AWS IAM Access Analyzer
#   - AWS Firewall Manager
#   - Third-party: Splunk, Crowdstrike, Palo Alto, etc. (via finding ingestion API)
#
# COMPLIANCE STANDARDS:
#   CIS AWS Foundations Benchmark v1.2 / v1.4
#     Checks: MFA on root, CloudTrail in all regions, S3 public access blocked,
#             password policy, VPC default SG, access key rotation
#   AWS Foundational Security Best Practices (FSBP)
#     Broader AWS-specific checks across all service categories
#   PCI DSS v3.2.1
#     Payment card industry compliance checks
#   NIST SP 800-53
#     US government security framework
#
# CONTROL_FINDING_GENERATOR MODES:
#   SECURITY_CONTROL (recommended): one finding per security control, shared
#     across all standards that include it (no duplicate findings)
#   STANDARD_CONTROL (legacy): separate finding per standard per control
#     (same control violation generates multiple findings if in multiple standards)
#
# MULTI-ACCOUNT:
#   Designate Security Hub administrator account via Organizations.
#   All member account findings roll up to the administrator account.
#   SAA-C03: "single security dashboard for entire organization" = Security Hub + Organizations
#
################################################################################

resource "aws_securityhub_account" "main" {
  # auto_enable_controls: automatically enable all controls when a new standard
  # is activated. Set to false to manually select which controls to enable.
  auto_enable_controls = true

  # enable_default_standards: if true, AWS automatically enables the AWS Foundational
  # Security Best Practices standard. Set to false here because we enable
  # specific standards below via aws_securityhub_standards_subscription.
  enable_default_standards = false

  # SECURITY_CONTROL: deduplicated findings — one per control across all standards.
  # This is the modern recommended configuration. Reduces alert fatigue.
  control_finding_generator = "SECURITY_CONTROL"
}

# ---------------------------------------------------------------------------
# CIS AWS FOUNDATIONS BENCHMARK
# The CIS Benchmark is one of the most commonly tested compliance frameworks
# in SAA-C03 exam scenarios. It checks:
#   - IAM: MFA enabled for root, no root access keys, password policy
#   - CloudTrail: enabled in all regions, log file validation enabled
#   - Networking: VPC default SG has no rules, no public access on S3
#   - Monitoring: CloudWatch alarms for root login, unauthorized API calls, etc.
#
# SAA-C03: "Implement CIS Benchmark" = Security Hub + CIS standards subscription
# SAA-C03: "Check if MFA is enabled on all IAM users" = Security Hub CIS check
# ---------------------------------------------------------------------------
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

# ---------------------------------------------------------------------------
# AWS FOUNDATIONAL SECURITY BEST PRACTICES (FSBP)
# AWS's own opinionated security checks covering all major services.
# Covers more services than CIS (e.g., RDS, Lambda, ECS, EKS checks).
# Enable both CIS and FSBP for comprehensive coverage.
# ---------------------------------------------------------------------------
resource "aws_securityhub_standards_subscription" "aws_fsbp" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

################################################################################
# === SECTION 7: AMAZON DETECTIVE ===
#
# Detective automatically collects log data and uses ML, statistical analysis,
# and graph theory to create a "behavior graph" — a unified, interactive view
# of resource activity and relationships over time.
#
# HOW IT WORKS:
#   Detective ingests: GuardDuty findings, VPC Flow Logs, CloudTrail logs, EKS audit logs
#   It builds entity models (EC2 instances, IAM roles, IP addresses, S3 buckets) and
#   maps relationships between them based on observed API calls and network flows.
#
# PRIMARY USE CASE — SECURITY INVESTIGATION:
#   1. GuardDuty raises an alert: "EC2 i-1234 is communicating with a known C2 server"
#   2. Security analyst opens Detective from the GuardDuty finding console
#   3. Detective shows: which IAM role the instance used, what API calls were made,
#      which other resources it communicated with, over what time period
#   4. Analyst can determine: was this a true positive? What is the blast radius?
#      Which other resources may be compromised?
#
# DETECTIVE vs GUARDDUTY:
#   GuardDuty = raises the ALARM (detects the threat)
#   Detective  = does the INVESTIGATION (explains what happened, what was affected)
#   They complement each other — Detective uses GuardDuty findings as investigation entry points.
#
# DETECTIVE vs CLOUDTRAIL:
#   CloudTrail = raw API log data (who called what API, when, from where)
#   Detective  = pre-analyzed, visualized, correlated view of that same data
#   Detective makes it faster to investigate; CloudTrail provides the raw evidence.
#
# DATA RETENTION: Detective retains data for up to one year for analysis.
#
# SAA-C03 EXAM:
#   "Investigate the scope of a security incident after GuardDuty finding" = Detective
#   "Visualize which resources an attacker may have accessed" = Detective
#   "Root cause analysis of unauthorized API activity" = Detective
#   "Build a timeline of a compromised IAM user's actions" = Detective
#
# ENABLING DETECTIVE:
#   aws_detective_graph enables Detective for the account.
#   GuardDuty must be enabled in the same account and region for full functionality.
#   (Detective can still function without GuardDuty but loses finding-based pivoting.)
#
################################################################################

resource "aws_detective_graph" "main" {
  # The aws_detective_graph resource enables Amazon Detective for this account.
  # Creating the graph starts data ingestion from CloudTrail and VPC Flow Logs.
  # After creation, you add member accounts to aggregate cross-account investigations.

  tags = {
    Name     = "lab32-detective-graph"
    Purpose  = "Security incident investigation — visualize entity relationships post-finding"
    ExamNote = "Detective = investigate GuardDuty findings; visualize blast radius of incidents"
  }

  # depends_on: Detective works best when GuardDuty is already active.
  # GuardDuty findings appear as investigation entry points in the Detective console.
  depends_on = [aws_guardduty_detector.main]
}

################################################################################
# === SECTION 8: AWS CONFIG INTEGRATION WITH SECURITY HUB ===
#
# AWS Config records configuration changes to AWS resources and evaluates them
# against compliance rules. Security Hub automatically ingests Config rule
# compliance findings, presenting them alongside GuardDuty, Macie, and Inspector.
#
# CONFIG + SECURITY HUB INTEGRATION:
#   - When a Config rule evaluates a resource as NON_COMPLIANT, Security Hub
#     receives a finding automatically (no additional setup needed)
#   - Security Hub maps Config findings to the relevant CIS/FSBP controls
#   - Example: Config rule "restricted-ssh" → Security Hub CIS 4.1 check
#
# SAA-C03 EXAM DISTINCTION:
#   Config = records config changes + evaluates rules (history, compliance audit)
#   Config DOES NOT block changes — evaluation happens AFTER the fact
#   To PREVENT non-compliant resources: use SCP, IAM conditions, or Control Tower
#
# ADDITIONAL CONTEXT FOR CLOUDTRAIL + SECURITY HUB:
#   CloudTrail can be configured to send management events to Security Hub
#   via EventBridge rules. While CloudTrail itself is not a Security Hub
#   "finding generator" like GuardDuty or Macie, GuardDuty analyzes CloudTrail
#   events and surfaces suspicious activity as GuardDuty findings in Security Hub.
#   This creates the indirect integration: CloudTrail → GuardDuty → Security Hub.
#
################################################################################

# Config IAM role — required for Config to read resource configurations
resource "aws_iam_role" "config" {
  name = "lab32-config-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "lab32-config-role"
  }
}

# AWS managed policy grants Config the necessary read access to all supported
# resource types and write access to the delivery channel (S3 and SNS)
resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# S3 bucket for Config to deliver configuration history and snapshots
resource "aws_s3_bucket" "config" {
  bucket        = "lab32-config-history-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = true

  tags = {
    Name     = "lab32-config-delivery-bucket"
    Purpose  = "AWS Config configuration history files and periodic snapshots"
    ExamNote = "Config delivers history to S3; Security Hub reads Config findings automatically"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket policy: allow the Config service to write to this bucket.
# Config calls GetBucketAcl (to verify it has access) and PutObject (to write).
# The condition ensures Config writes with bucket-owner-full-control ACL.
resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.config]
}

# Config configuration recorder: defines WHICH resource types to record.
# all_supported = true records all currently supported resource types.
# include_global_resource_types = true records IAM users, roles, policies, and groups.
# SAA-C03: only enable global resource types in ONE region per account to avoid duplicates.
resource "aws_config_configuration_recorder" "main" {
  name     = "lab32-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

# Config delivery channel: sends configuration history and snapshots to S3.
# snapshot_delivery_properties: periodic full-account configuration snapshot.
# Individual resource changes are still recorded in near real-time regardless.
resource "aws_config_delivery_channel" "main" {
  name           = "lab32-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.bucket
  s3_key_prefix  = "config"

  snapshot_delivery_properties {
    # TwentyFour_Hours: deliver a full config snapshot to S3 once daily.
    # Does NOT affect how quickly individual changes are recorded (near real-time).
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.config
  ]
}

# Start the recorder. Separate resource required by Terraform (unlike console).
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ---------------------------------------------------------------------------
# CONFIG RULES — INTEGRATION WITH SECURITY HUB
# These rules evaluate resource configurations and produce findings.
# Security Hub automatically ingests these findings when integrated.
# ---------------------------------------------------------------------------

# restricted-ssh: flags any security group that allows port 22 from 0.0.0.0/0.
# Maps to CIS AWS Benchmark control 4.1 in Security Hub.
# SAA-C03: "detect SGs allowing unrestricted SSH" = Config rule restricted-ssh
resource "aws_config_config_rule" "restricted_ssh" {
  name        = "lab32-restricted-ssh"
  description = "Checks that no security group allows unrestricted inbound SSH (0.0.0.0/0 on port 22)"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder.main]

  tags = {
    Name     = "lab32-config-restricted-ssh"
    ExamNote = "Config detects the violation. SCP/IAM prevents it. Security Hub shows it."
  }
}

# encrypted-volumes: ensures all EBS volumes attached to EC2 are encrypted.
# SAA-C03: Config detects unencrypted volumes; does NOT encrypt them.
# To auto-encrypt: enable EC2 default EBS encryption setting (account-wide).
resource "aws_config_config_rule" "encrypted_volumes" {
  name        = "lab32-encrypted-volumes"
  description = "Checks that all EBS volumes attached to EC2 instances are encrypted"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  depends_on = [aws_config_configuration_recorder.main]

  tags = {
    Name = "lab32-config-encrypted-volumes"
  }
}
