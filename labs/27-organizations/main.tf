# =============================================================================
# LAB 27: AWS ORGANIZATIONS
# =============================================================================
#
# AWS ORGANIZATIONS OVERVIEW (SAA-C03 EXAM TOPIC)
# -----------------------------------------------
# AWS Organizations lets you centrally manage multiple AWS accounts under a
# single umbrella. Key concepts:
#
#   - Management Account (formerly "master account"): the account that creates
#     the organization. It CANNOT be restricted by SCPs — it always has full
#     permissions. All billing rolls up here.
#
#   - Member Accounts: any account that joins the organization. Their
#     permissions can be restricted by SCPs.
#
#   - Root: the top-level container for all accounts. SCPs attached to the
#     Root apply to EVERY account in the organization.
#
#   - Organizational Units (OUs): logical groupings of accounts.
#     Example structure:
#
#       Root
#       ├── Production OU    (prod accounts)
#       ├── Development OU   (dev/test accounts)
#       └── Security OU      (audit, log-archive accounts)
#
# =============================================================================
# SERVICE CONTROL POLICIES (SCPs) — CRITICAL FOR SAA-C03
# =============================================================================
#
#   - SCPs are JSON policies attached to the Root, an OU, or an account.
#   - SCPs set the MAXIMUM permissions (guardrails). They do NOT grant access.
#   - Even if an IAM policy says "Allow", an SCP Deny overrides it.
#   - The ROOT USER of a member account is restricted by SCPs — exam favorite!
#     Example: An SCP denying us-west-1 means even the root user of that
#     member account CANNOT create EC2 instances in us-west-1.
#   - Management account is NEVER affected by SCPs.
#
#   Inheritance rules:
#     - An account inherits SCPs from all OUs above it + the Root.
#     - If Production OU denies S3 delete, all accounts in Production OU
#       cannot delete S3 objects, regardless of their IAM policies.
#
#   Effective permissions = IAM permissions ∩ SCP allowed actions
#   (the intersection — you need BOTH to allow an action)
#
# =============================================================================
# ADDITIONAL ORGANIZATIONS FEATURES
# =============================================================================
#
#   Consolidated Billing:
#     - One monthly bill for all accounts.
#     - Usage across accounts is aggregated for volume pricing tiers.
#     - Reserved Instances and Savings Plans purchased in one account can be
#       shared with other accounts in the organization.
#
#   AWS IAM Identity Center (formerly AWS SSO):
#     - Centralized sign-in for all org accounts using one set of credentials.
#     - Integrate with external identity providers (Azure AD, Okta, etc.).
#     - Assign permission sets to users/groups per account.
#
#   Organization-Level CloudTrail:
#     - Create a single trail that captures API activity from ALL accounts.
#     - Logs land in a central S3 bucket in the management (or security) account.
#     - Member accounts cannot delete this trail (lock it down with an SCP).
#
# =============================================================================

# -----------------------------------------------------------------------------
# AWS ORGANIZATIONS — Enable the organization with all features + SCP support
# -----------------------------------------------------------------------------
# feature_set = "ALL" enables:
#   - Service Control Policies (SCPs)
#   - Tag Policies
#   - Backup Policies
#   - AI services opt-out policies
#
# feature_set = "CONSOLIDATED_BILLING" only enables billing consolidation.
# For the exam: to use SCPs you MUST enable "ALL" features.
#
# aws_policy_types enables SCP support at the root level. Without this, you
# can create SCP resources but they will have no effect.
# -----------------------------------------------------------------------------
resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  # Enable Service Control Policies at the root level.
  # Also enabling AI_OPT_OUT_POLICY and BACKUP_POLICY for completeness.
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",               # org-level CloudTrail
    "config.amazonaws.com",                   # AWS Config aggregator
    "sso.amazonaws.com",                      # IAM Identity Center (SSO)
    "reporting.trustedadvisor.amazonaws.com", # Trusted Advisor org-wide
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY", # SCPs — the main guardrail mechanism
    "TAG_POLICY",             # enforce tagging standards org-wide
    "BACKUP_POLICY",          # enforce AWS Backup plans org-wide
  ]
}

# -----------------------------------------------------------------------------
# ORGANIZATIONAL UNITS (OUs)
# -----------------------------------------------------------------------------
# OUs let you apply different SCPs to different groups of accounts.
# An account can only be in ONE OU at a time.
#
# parent_id = the root ID (from the org resource) — these are top-level OUs.
# You can nest OUs up to 5 levels deep.
# -----------------------------------------------------------------------------

# Production OU — highest restriction, no experimental services allowed
resource "aws_organizations_organizational_unit" "production" {
  name      = "Production"
  parent_id = aws_organizations_organization.main.roots[0].id

  # All accounts in this OU will inherit:
  #   - DenyLeavingOrganization SCP
  #   - DenyDisableCloudTrail SCP
  #   - DenyNonApprovedRegions SCP (only us-east-1, us-west-2)
}

# Development OU — less restrictive, devs need more flexibility
resource "aws_organizations_organizational_unit" "development" {
  name      = "Development"
  parent_id = aws_organizations_organization.main.roots[0].id

  # Accounts here may only have DenyLeavingOrganization attached.
  # We intentionally allow more regions and services for experimentation.
}

# Security OU — for audit/log-archive accounts, very locked down
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.main.roots[0].id

  # Accounts here typically:
  #   - Store centralized CloudTrail logs (log-archive account)
  #   - Run AWS Security Hub, GuardDuty, and Config aggregation (audit account)
  #   - Are the most restricted — even fewer humans can log in here
}

# =============================================================================
# SERVICE CONTROL POLICIES (SCPs)
# =============================================================================
# type = "SERVICE_CONTROL_POLICY" identifies these as SCPs (vs TAG_POLICY, etc.)
#
# SCP content is a JSON IAM-style policy document. Key rule:
#   - Use "Effect": "Deny" to BLOCK actions (most common pattern).
#   - Use "Effect": "Allow" with NotAction to whitelist only certain actions
#     (more restrictive, less common).
# =============================================================================

# -----------------------------------------------------------------------------
# SCP 1: Deny Leaving the Organization
# -----------------------------------------------------------------------------
# This is the most universally applied SCP in real organizations.
# Without it, a rogue admin in a member account could run:
#   aws organizations leave-organization
# ...and that account would be removed from the org, losing all SCPs/billing.
#
# SAA-C03 scenario: "How do you prevent member accounts from leaving the org?"
# Answer: Attach an SCP that Denies organizations:LeaveOrganization.
# -----------------------------------------------------------------------------
resource "aws_organizations_policy" "deny_leaving_organization" {
  name        = "DenyLeavingOrganization"
  description = "Prevents any principal in member accounts from leaving the organization"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeaveOrg"
        Effect   = "Deny"
        Action   = "organizations:LeaveOrganization"
        Resource = "*"
        # No Condition block = applies to EVERYONE including root user
        # This is the power of SCPs: even the account's root user cannot
        # call LeaveOrganization while this SCP is attached.
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SCP 2: Deny Disabling CloudTrail
# -----------------------------------------------------------------------------
# Ensures audit logs cannot be tampered with from member accounts.
# An attacker who gains admin access in a member account would typically try
# to cover their tracks by disabling CloudTrail — this SCP blocks that.
#
# Actions blocked:
#   - cloudtrail:DeleteTrail         (delete a trail entirely)
#   - cloudtrail:StopLogging         (pause logging without deleting)
#   - cloudtrail:UpdateTrail         (change destination bucket, etc.)
#
# SAA-C03: Pair this with an org-level trail in a Security account whose
# S3 bucket has a restrictive bucket policy — defense in depth.
# -----------------------------------------------------------------------------
resource "aws_organizations_policy" "deny_disable_cloudtrail" {
  name        = "DenyDisableCloudTrail"
  description = "Prevents disabling, deleting, or modifying CloudTrail in member accounts"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyCloudTrailModification"
        Effect = "Deny"
        Action = [
          "cloudtrail:DeleteTrail",
          "cloudtrail:StopLogging",
          "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors", # prevent reducing event coverage
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SCP 3: Deny Non-Approved Regions
# -----------------------------------------------------------------------------
# Restricts all API calls to only the approved regions.
# This is a WHITELIST approach using NotAction + Deny.
#
# Why NotAction instead of Action?
#   Some services are global (IAM, STS, S3 bucket creation via us-east-1,
#   Route 53, Support, Budgets). These must be excluded from the deny, or
#   the account becomes unusable.
#
# Pattern: "Deny everything EXCEPT these global services, in any region
#            that is NOT in our approved list."
#
# SAA-C03 scenario:
#   "Company must ensure workloads only run in us-east-1 and us-west-2
#    for data residency. Even account admins should not be able to spin up
#    resources in other regions. What do you use?"
#   Answer: SCP with Deny + Condition on aws:RequestedRegion.
# -----------------------------------------------------------------------------
resource "aws_organizations_policy" "deny_non_approved_regions" {
  name        = "DenyNonApprovedRegions"
  description = "Restricts resource creation to us-east-1 and us-west-2 only"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonApprovedRegions"
        Effect = "Deny"

        # NotAction = deny ALL actions EXCEPT these global/essential ones.
        # If we used Action = ["*"], IAM, STS, etc. would break.
        NotAction = [
          "a4b:*", # Alexa for Business (global)
          "acm:*", # ACM (global for CloudFront certs)
          "aws-marketplace-management:*",
          "aws-marketplace:*",
          "aws-portal:*", # billing console
          "budgets:*",    # Budgets (global service)
          "ce:*",         # Cost Explorer (global)
          "chime:*",
          "cloudfront:*", # CloudFront is global
          "config:*",
          "cur:*", # Cost and Usage Reports
          "directconnect:*",
          "ec2:DescribeRegions", # needed for region enumeration
          "ec2:DescribeTransitGateways",
          "fms:*",
          "globalaccelerator:*",
          "health:*", # AWS Health Dashboard
          "iam:*",    # IAM is global — must be excluded
          "importexport:*",
          "kms:*", # KMS has regional endpoints but keys are critical
          "mobileanalytics:*",
          "networkmanager:*",
          "organizations:*", # Organizations is global
          "pricing:*",
          "route53:*", # Route 53 is global
          "route53domains:*",
          "route53resolver:*",
          "s3:CreateMultiRegionAccessPoint",
          "s3:DeleteMultiRegionAccessPoint",
          "s3:DescribeMultiRegionAccessPointOperation",
          "s3:GetAccountPublicAccessBlock",
          "s3:GetBucketLocation",
          "s3:GetMultiRegionAccessPoint",
          "s3:GetMultiRegionAccessPointPolicy",
          "s3:GetMultiRegionAccessPointPolicyStatus",
          "s3:GetStorageLensConfiguration",
          "s3:GetStorageLensDashboard",
          "s3:ListAllMyBuckets",
          "s3:ListMultiRegionAccessPoints",
          "s3:ListStorageLensConfigurations",
          "s3:PutAccountPublicAccessBlock",
          "s3:SubmitMultiRegionAccessPointRequests",
          "shield:*",
          "sts:*",     # STS is global (AssumeRole, GetCallerIdentity)
          "support:*", # Support center is global
          "trustedadvisor:*",
          "waf-regional:*",
          "waf:*",
          "wafv2:*",
        ]

        Resource = "*"

        Condition = {
          # StringNotEquals = deny if requested region is NOT in this list
          StringNotEquals = {
            "aws:RequestedRegion" = [
              "us-east-1", # US East (N. Virginia)
              "us-west-2", # US West (Oregon)
            ]
          }
        }
      }
    ]
  })
}

# =============================================================================
# SCP ATTACHMENTS
# =============================================================================
# Attaching SCPs to OUs (or root) makes them active.
# An SCP must BOTH exist AND be attached to have any effect.
# Detaching an SCP removes the restriction immediately.
# =============================================================================

# Attach DenyLeavingOrganization to the ROOT — applies to ALL member accounts
# in the entire organization. The management account is still exempt from SCPs.
resource "aws_organizations_policy_attachment" "deny_leaving_root" {
  policy_id = aws_organizations_policy.deny_leaving_organization.id
  target_id = aws_organizations_organization.main.roots[0].id
  # target_id can be: root ID, OU ID, or individual account ID
}

# Attach DenyDisableCloudTrail to Production OU
# All accounts inside Production OU inherit this restriction.
resource "aws_organizations_policy_attachment" "deny_cloudtrail_production" {
  policy_id = aws_organizations_policy.deny_disable_cloudtrail.id
  target_id = aws_organizations_organizational_unit.production.id
}

# Also attach DenyDisableCloudTrail to Security OU
# We want audit accounts to be especially protected from tampering.
resource "aws_organizations_policy_attachment" "deny_cloudtrail_security" {
  policy_id = aws_organizations_policy.deny_disable_cloudtrail.id
  target_id = aws_organizations_organizational_unit.security.id
}

# Attach DenyNonApprovedRegions to Production OU only
# Development has more freedom; prod workloads must stay in approved regions.
resource "aws_organizations_policy_attachment" "deny_regions_production" {
  policy_id = aws_organizations_policy.deny_non_approved_regions.id
  target_id = aws_organizations_organizational_unit.production.id
}

# =============================================================================
# CREATING MEMBER ACCOUNTS (informational — not created in this lab)
# =============================================================================
# To add a new AWS account to the organization, use aws_organizations_account:
#
#   resource "aws_organizations_account" "prod_app" {
#     name      = "prod-application"
#     email     = "aws+prod-app@example.com"   # must be unique globally
#     parent_id = aws_organizations_organizational_unit.production.id
#     role_name = "OrganizationAccountAccessRole"
#     # This role is auto-created and allows the management account to
#     # AssumeRole into the new account for cross-account administration.
#   }
#
# NOTE: Creating an AWS account via Terraform is a real, irreversible action.
# Accounts can be closed but not deleted. Use with care.
#
# Cross-account access pattern:
#   Management account assumes OrganizationAccountAccessRole in member account
#   → gets AdministratorAccess in that member account
#   → this is how AWS Control Tower and Landing Zone work under the hood
# =============================================================================

# =============================================================================
# OUTPUTS
# =============================================================================

output "organization_id" {
  description = "The ID of the AWS Organization (e.g., o-xxxxxxxxxxxx)"
  value       = aws_organizations_organization.main.id
}

output "organization_arn" {
  description = "The ARN of the AWS Organization"
  value       = aws_organizations_organization.main.arn
}

output "organization_master_account_id" {
  description = "The AWS account ID of the management (master) account"
  value       = aws_organizations_organization.main.master_account_id
}

output "root_id" {
  description = "The ID of the organization root (r-xxxx) — used as SCP attachment target"
  value       = aws_organizations_organization.main.roots[0].id
}

output "production_ou_id" {
  description = "The ID of the Production Organizational Unit"
  value       = aws_organizations_organizational_unit.production.id
}

output "development_ou_id" {
  description = "The ID of the Development Organizational Unit"
  value       = aws_organizations_organizational_unit.development.id
}

output "security_ou_id" {
  description = "The ID of the Security Organizational Unit"
  value       = aws_organizations_organizational_unit.security.id
}

output "scp_deny_leaving_org_id" {
  description = "Policy ID for the DenyLeavingOrganization SCP"
  value       = aws_organizations_policy.deny_leaving_organization.id
}

output "scp_deny_disable_cloudtrail_id" {
  description = "Policy ID for the DenyDisableCloudTrail SCP"
  value       = aws_organizations_policy.deny_disable_cloudtrail.id
}

output "scp_deny_non_approved_regions_id" {
  description = "Policy ID for the DenyNonApprovedRegions SCP"
  value       = aws_organizations_policy.deny_non_approved_regions.id
}

# =============================================================================
# SECTION: AWS CONTROL TOWER
# =============================================================================
# Control Tower = automated setup of a multi-account AWS environment following
# AWS Landing Zone best practices. Built on top of AWS Organizations + SCPs.
#
# SAA-C03 KEY FACTS:
#   - Automates account factory: new accounts get guardrails applied automatically
#   - Landing Zone: baseline multi-account setup (Management, Audit, Log Archive accounts)
#   - Guardrails (= Controls): preventive (SCPs) + detective (Config rules)
#   - Account Factory: vending machine for new accounts (Terraform via Account Factory for Terraform)
#   - Account Factory for Terraform (AFT): GitOps-based account provisioning
#   - Dashboard: compliance status across all accounts at a glance
#   - Integrated with: Organizations, Config, CloudTrail, SSO (IAM Identity Center)
#
# EXAM TIPS:
#   - "Automate multi-account setup with best practices" = Control Tower
#   - "Account vending machine" = Account Factory (part of Control Tower)
#   - "Preventive guardrail" = SCP (e.g., deny leaving org, require MFA)
#   - "Detective guardrail" = Config rule (e.g., detect unencrypted S3 buckets)
#   - "Log Archive account" = centralized CloudTrail + Config logs
#   - "Audit account" = read-only cross-account access for security team
#
# NOTE: Control Tower cannot be fully provisioned via Terraform (it requires
# manual setup in the console or via the AWS Control Tower APIs).
# The aws_controltower_* resources manage controls (guardrails) AFTER
# Control Tower is set up.

# Enable a Control Tower control (guardrail) on an OU
# Requires: Control Tower already configured, OU exists in Organizations
# resource "aws_controltower_control" "deny_root_access" {
#   control_identifier = "arn:aws:controltower:us-east-1::control/AWS-GR_RESTRICT_ROOT_USER"
#   target_identifier  = aws_organizations_organizational_unit.production.arn
#   # This is a PREVENTIVE guardrail (SCP-based).
#   # It denies root user actions in all accounts in the Production OU.
#   # SAA-C03: AWS-GR_RESTRICT_ROOT_USER is one of the mandatory guardrails
#   # automatically enabled by Control Tower.
# }

# resource "aws_controltower_control" "detect_unencrypted_s3" {
#   control_identifier = "arn:aws:controltower:us-east-1::control/AWS-GR_S3_BUCKET_PUBLIC_READ_PROHIBITED"
#   target_identifier  = aws_organizations_organizational_unit.production.arn
#   # This is a DETECTIVE guardrail (Config rule-based).
#   # It detects (but does not prevent) S3 buckets with public read enabled.
#   # SAA-C03: Detective guardrails notify but don't block — use Preventive SCPs to block.
# }

# Control Tower Landing Zone baseline accounts (conceptual - created manually):
# 1. Management Account  = root of the Organization, hosts Control Tower
# 2. Log Archive Account = all CloudTrail + Config logs aggregated here
# 3. Audit Account       = security team has cross-account read-only access

# Control Tower + Account Factory for Terraform (AFT) pattern:
# AFT Pipeline:
#   Developer → Git PR → AFT CodePipeline → new account vended automatically
#   Each new account gets:
#     - Baseline guardrails (SCPs + Config rules)
#     - Default VPC deletion
#     - CloudTrail enabled
#     - AWS Config enabled
#     - SSO permission sets applied
