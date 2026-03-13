################################################################################
# Lab 32 Outputs — Security Monitoring Services
################################################################################

output "guardduty_detector_id" {
  description = <<-EOT
    GuardDuty detector ID for this account and region.
    Use this ID when:
      - Creating GuardDuty filters (aws_guardduty_filter) to suppress false positives
      - Adding trusted IP lists (aws_guardduty_ipset) to whitelist known IPs
      - Creating threat intelligence sets (aws_guardduty_threatintelset) with custom IOCs
      - Configuring member account relationships (aws_guardduty_member)
    SAA-C03: GuardDuty is REGIONAL — each region has its own detector ID.
    Enable GuardDuty in all regions using AWS Organizations + GuardDuty delegated admin.
  EOT
  value       = aws_guardduty_detector.main.id
}

output "guardduty_publishing_destination_id" {
  description = <<-EOT
    ID of the GuardDuty S3 publishing destination.
    GuardDuty exports findings to the configured S3 bucket for:
      - Long-term retention (default 90-day console retention extends indefinitely in S3)
      - SIEM integration (Splunk, Sumo Logic, Datadog) via S3 event notifications
      - Athena queries over historical findings data
    SAA-C03: Exporting findings to S3 is the only way to retain them beyond 90 days.
  EOT
  value       = aws_guardduty_publishing_destination.s3.id
}

output "guardduty_findings_bucket" {
  description = <<-EOT
    S3 bucket receiving exported GuardDuty findings.
    Findings are encrypted with the KMS CMK: ${aws_kms_key.security.arn}
    Bucket is private with all public access blocked.
    Use S3 event notifications or EventBridge to trigger downstream SIEM ingestion.
  EOT
  value       = aws_s3_bucket.guardduty_findings.bucket
}

output "macie_account_status" {
  description = <<-EOT
    Amazon Macie account status: ENABLED or PAUSED.
    ENABLED: Macie is actively monitoring all S3 buckets for security posture
    (policy findings) and can run classification jobs for content scanning.
    PAUSED: Macie is temporarily suspended; bucket inventory stops but configuration is retained.
    SAA-C03: Macie is S3-only — it cannot scan RDS, DynamoDB, EBS, or on-premises data.
  EOT
  value       = aws_macie2_account.main.status
}

output "macie_classification_job_id" {
  description = <<-EOT
    ID of the Macie ONE_TIME classification job scanning the data lake bucket.
    ONE_TIME jobs run once and complete. Check job status in the Macie console.
    For ongoing monitoring use job_type = SCHEDULED with a daily/weekly cadence.
    SAA-C03: Classification jobs scan object content; bucket inventory findings
    are generated automatically without running a job.
  EOT
  value       = aws_macie2_classification_job.data_lake_scan.id
}

output "macie_custom_identifier_id" {
  description = <<-EOT
    ID of the Macie custom data identifier for employee IDs (pattern: EMP-XXXXXXX).
    Custom identifiers extend Macie's built-in ML models with org-specific patterns.
    SAA-C03: Use custom data identifiers when AWS's built-in identifiers don't
    cover your organization's proprietary data formats or internal reference numbers.
  EOT
  value       = aws_macie2_custom_data_identifier.employee_id.id
}

output "security_hub_arn" {
  description = <<-EOT
    AWS Security Hub account ARN for this account.
    Security Hub aggregates findings from:
      - Amazon GuardDuty (threat detection findings)
      - Amazon Macie (sensitive data findings)
      - Amazon Inspector (CVE vulnerability findings)
      - AWS Config (compliance rule findings)
      - AWS IAM Access Analyzer (external access findings)
    All findings normalized to ASFF (Amazon Security Finding Format).
    SAA-C03: "Single pane of glass for all security findings" = Security Hub.
  EOT
  value       = aws_securityhub_account.main.id
}

output "security_hub_cis_standard_arn" {
  description = <<-EOT
    ARN of the CIS AWS Foundations Benchmark standard subscription.
    CIS checks include: MFA on root, CloudTrail in all regions, S3 public access,
    password policy, VPC default SG rules, access key rotation.
    SAA-C03: "Implement CIS Benchmark" = enable this standard in Security Hub.
    Non-compliant controls appear as FAILED findings in the Security Hub console.
  EOT
  value       = aws_securityhub_standards_subscription.cis.id
}

output "security_hub_fsbp_standard_arn" {
  description = <<-EOT
    ARN of the AWS Foundational Security Best Practices standard subscription.
    FSBP covers more services than CIS (RDS, Lambda, ECS, EKS, etc.).
    Enabling both CIS and FSBP gives comprehensive coverage.
    SAA-C03: control_finding_generator = SECURITY_CONTROL deduplicates findings
    when the same control appears in multiple standards.
  EOT
  value       = aws_securityhub_standards_subscription.aws_fsbp.id
}

output "detective_graph_arn" {
  description = <<-EOT
    ARN of the Amazon Detective behavior graph.
    Use Detective to investigate GuardDuty findings by visualizing:
      - Which IAM principals interacted with the affected resource
      - What API calls were made and from which IP addresses
      - Network connections the EC2 instance established
      - Timeline of events leading up to and following the finding
    SAA-C03: Detective = INVESTIGATION after GuardDuty detection.
    GuardDuty raises the alarm; Detective explains the blast radius.
    Data retention: up to 1 year of behavioral data for investigation.
  EOT
  value       = aws_detective_graph.main.graph_arn
}

output "kms_key_arn" {
  description = <<-EOT
    ARN of the KMS CMK used to encrypt GuardDuty findings at rest.
    Using a CMK (vs default aws/guardduty key) enables:
      - Custom key policy (restrict who can decrypt findings)
      - Key disabling (instantly prevent findings decryption)
      - Cross-account grants (share findings with SIEM account)
      - CloudTrail audit of every key usage (who decrypted findings and when)
    SAA-C03: CMK for security findings = tightest access control over sensitive data.
  EOT
  value       = aws_kms_key.security.arn
  sensitive   = false
}

output "config_delivery_bucket" {
  description = <<-EOT
    S3 bucket receiving AWS Config configuration history and periodic snapshots.
    Config + Security Hub integration: when Config rules evaluate resources as
    NON_COMPLIANT, Security Hub automatically receives these as findings.
    This creates the compliance audit trail that Security Hub surfaces in its dashboard.
    SAA-C03: Config detects (and records) config drift. Security Hub shows it centrally.
  EOT
  value       = aws_s3_bucket.config.bucket
}

output "exam_reference" {
  description = "SAA-C03 security monitoring service quick reference"
  value       = <<-EOT
    SAA-C03 SECURITY MONITORING QUICK REFERENCE:
    ─────────────────────────────────────────────────────────────────────────
    GuardDuty:    Threat detection (ML on CloudTrail + VPC Flow Logs + DNS)
                  Findings: UnauthorizedAccess, CryptoCurrency, Trojan, Recon
                  Auto-remediate: GuardDuty → EventBridge → Lambda → isolate EC2
                  Multi-account: admin + member accounts via Organizations
                  90-day finding retention; export to S3 for longer retention

    Macie:        Sensitive data discovery (PII, credentials, financial) — S3 ONLY
                  Bucket inventory (policy findings) automatic; content scanning = jobs
                  Custom data identifiers: add your own regex patterns
                  GDPR / HIPAA compliance data discovery use cases

    Inspector:    CVE vulnerability scanning — EC2 (SSM agent), ECR, Lambda
                  Risk score = CVE severity × network reachability
                  Agentless for ECR and Lambda; SSM agent required for EC2
                  Does NOT block; does NOT patch; sends findings to Security Hub

    Security Hub: Aggregator + CSPM — GuardDuty + Macie + Inspector + Config
                  Standards: CIS v1.2/1.4, AWS FSBP, PCI DSS, NIST, SOC 2
                  ASFF normalization; SECURITY_CONTROL mode deduplicates findings
                  Multi-account: admin aggregates all member account findings

    Detective:    Investigation after GuardDuty finding — visualizes blast radius
                  Behavior graph: entity relationships, API calls, network flows
                  1-year data retention for historical investigation
                  GuardDuty = ALARM; Detective = INVESTIGATOR

    Config:       Configuration change recorder + compliance rule evaluator
                  Configuration history: "What did this SG look like 30 days ago?"
                  Rules: managed (AWS pre-built) or custom (Lambda-based)
                  Sends findings to Security Hub automatically
                  Does NOT prevent changes (use SCP for prevention)
    ─────────────────────────────────────────────────────────────────────────
    NONE of these services PREVENT attacks. They DETECT and REPORT.
    To PREVENT: WAF (Layer 7), Shield (DDoS), SCP (API actions), SGs (network)
    ─────────────────────────────────────────────────────────────────────────
  EOT
}
