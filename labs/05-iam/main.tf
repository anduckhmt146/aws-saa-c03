# ============================================================
# LAB 05 - IAM: Users, Groups, Roles, Policies, KMS
# IAM is a GLOBAL service (no region)
# All resources are destroy-safe
# ============================================================

# ============================================================
# IAM USER
# - Represents a person or application
# - Credentials: Password (console) or Access Keys (CLI/API)
# - MFA recommended
# ============================================================
resource "aws_iam_user" "lab" {
  name = var.lab_user_name
  path = "/lab/"

  tags = { Purpose = "lab-testing" }
}

# ============================================================
# IAM GROUP
# - Collection of users
# - Users inherit permissions from group
# - Cannot nest groups (no groups within groups)
# ============================================================
resource "aws_iam_group" "developers" {
  name = "lab-developers"
  path = "/lab/"
}

resource "aws_iam_group" "readonly" {

  name = "lab-readonly"
  path = "/lab/"
}

resource "aws_iam_user_group_membership" "lab" {

  user   = aws_iam_user.lab.name
  groups = [aws_iam_group.developers.name]
}

# ============================================================
# IAM POLICIES
# Policy types:
#   AWS Managed  = Created by AWS, cannot edit
#   Customer Managed = Created by you, reusable
#   Inline = Embedded directly in user/group/role (1:1)
#
# Policy evaluation order (DENY always wins):
#   1. Explicit DENY → deny
#   2. Explicit ALLOW → allow
#   3. Default → DENY (implicit)
# ============================================================

# Customer managed policy
resource "aws_iam_policy" "s3_read" {
  name        = "lab-s3-read-policy"
  description = "Allow read access to all S3 buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3Read"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]

      }
    ]
  })
}

# Policy with condition (IP restriction)
resource "aws_iam_policy" "conditional_access" {
  name        = "lab-conditional-policy"
  description = "Allow EC2 describe only from specific IP"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:Describe*"]
        Resource = "*"
        Condition = {
          IpAddress = {
            "aws:SourceIp" = ["10.0.0.0/8"]

          }

        }

      }
    ]
  })
}

# Attach AWS managed policy to group
resource "aws_iam_group_policy_attachment" "readonly" {
  group      = aws_iam_group.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_group_policy_attachment" "developers_s3" {

  group      = aws_iam_group.developers.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# ============================================================
# IAM ROLES
# - For AWS services (EC2, Lambda) or external identities
# - Uses temporary credentials (STS AssumeRole)
# - Trust policy = who can assume the role
# - Permission policy = what the role can do
# ============================================================

# Role for EC2 to access S3 and SSM
resource "aws_iam_role" "ec2_role" {
  name = "lab-ec2-s3-role"

  # Trust policy: EC2 can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Purpose = "ec2-lab" }
}

resource "aws_iam_role_policy_attachment" "ec2_s3" {

  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# Attach SSM policy (allows Systems Manager Session Manager — no SSH needed)
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile to attach role to EC2
resource "aws_iam_instance_profile" "ec2" {
  name = "lab-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lab-lambda-basic-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {

  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Cross-account role (another account can assume this)
resource "aws_iam_role" "cross_account" {
  name = "lab-cross-account-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::123456789012:root" } # External account
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "sts:ExternalId" = "unique-external-id" # Confused deputy protection

        }

      }
    }]
  })
}

# ============================================================
# KMS KEY (Key Management Service)
# - Create and manage encryption keys
# - Symmetric (AES-256): default, same key encrypt+decrypt
# - Asymmetric (RSA/ECC): public/private key pair
# - CMK = Customer Managed Key (you control rotation/deletion)
# - AWS Managed Key = AWS manages (auto-rotate every year)
# ============================================================
resource "aws_kms_key" "lab" {
  description             = "Lab KMS key for encryption"
  deletion_window_in_days = 7    # Minimum is 7 days
  enable_key_rotation     = true # Rotate annually (best practice)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

        }
        Action   = "kms:*"
        Resource = "*"

      }
    ]
  })

  tags = { Purpose = "lab-encryption" }
}

resource "aws_kms_alias" "lab" {

  name          = "alias/lab-key"
  target_key_id = aws_kms_key.lab.key_id
}

data "aws_caller_identity" "current" {}

# ============================================================
# IAM PASSWORD POLICY (Account-level)
# ============================================================
resource "aws_iam_account_password_policy" "lab" {
  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# ============================================================
# PERMISSION BOUNDARIES
# Sets the MAXIMUM permissions an IAM entity can have
# Even if a policy grants more, the boundary caps it
# Use case: delegate IAM to developers without full admin
# SAA-C03: boundary + policy = intersection (both must allow)
# ============================================================
resource "aws_iam_policy" "boundary" {
  name        = "lab-developer-boundary"
  description = "Permission boundary: devs can only touch their own resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowedServices"
        Effect   = "Allow"
        Action   = ["s3:*", "dynamodb:*", "lambda:*", "logs:*"]
        Resource = "*"
      },
      {
        Sid      = "DenyIAMEscalation"
        Effect   = "Deny"
        Action   = ["iam:CreateUser", "iam:AttachUserPolicy", "iam:PutUserPolicy"]
        Resource = "*"
      }
    ]
  })
}

# Role with permission boundary applied
resource "aws_iam_role" "developer" {
  name                 = "lab-developer-role"
  permissions_boundary = aws_iam_policy.boundary.arn # Max permissions capped here

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ============================================================
# ABAC (Attribute-Based Access Control)
# Use resource tags to control access
# Scale: one policy covers many resources via tags
# SAA-C03: ABAC scales better than RBAC for large orgs
# Example: dev can only touch resources tagged Environment=dev
# ============================================================
resource "aws_iam_policy" "abac_dev" {
  name        = "lab-abac-dev-policy"
  description = "Devs can only access resources tagged with their team"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowTaggedResources"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Team" = "$${aws:PrincipalTag/Team}" # Tag must match caller's tag
          }
        }
      },
      {
        Sid      = "AllowS3WithTeamPrefix"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::*/$${aws:PrincipalTag/Team}/*"
      }
    ]
  })
}

# ============================================================
# IAM ACCESS ANALYZER
# Identifies resources shared with external entities
# Findings: S3 buckets, IAM roles, KMS keys, Lambda, SQS, secrets
# Zone of trust: your account or organization
# SAA-C03: use Access Analyzer to audit public/cross-account access
# ============================================================
resource "aws_accessanalyzer_analyzer" "lab" {
  analyzer_name = "lab-access-analyzer"
  type          = "ACCOUNT" # ACCOUNT or ORGANIZATION (org-level requires delegated admin)

  tags = { Purpose = "security-audit" }
}

# ============================================================
# STS (Security Token Service)
# Issues temporary credentials for:
#   - AssumeRole: switch roles within or across accounts
#   - AssumeRoleWithWebIdentity: federate with OIDC (Cognito, Google)
#   - AssumeRoleWithSAML: federate with enterprise IdP (AD, Okta)
#   - GetSessionToken: MFA-protected API calls
# Temporary credentials: AccessKeyId + SecretAccessKey + SessionToken
# Max duration: 1 hour (default) to 12 hours for roles
# ============================================================

# Role for Web Identity Federation (mobile/web apps via Cognito or OIDC)
resource "aws_iam_role" "web_identity" {
  name = "lab-web-identity-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = "us-east-1:example-identity-pool-id"
        }
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "web_identity_s3" {
  role       = aws_iam_role.web_identity.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# Role for SAML Federation (enterprise SSO — Okta, Azure AD, etc.)
resource "aws_iam_role" "saml_federation" {
  name = "lab-saml-federation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:saml-provider/MyIdP"
      }
      Action = "sts:AssumeRoleWithSAML"
      Condition = {
        StringEquals = {
          "SAML:aud" = "https://signin.aws.amazon.com/saml"
        }
      }
    }]
  })
}

# ============================================================
# COGNITO USER POOL
# Managed user directory for web/mobile apps
# Features: sign-up/in, MFA, social login (Google, Facebook)
#           email/phone verification, custom Lambda triggers
# SAA-C03: User Pool = authentication (who are you?)
#           Identity Pool = authorization (what can you do in AWS?)
# ============================================================
resource "aws_cognito_user_pool" "lab" {
  name = "lab-user-pool"

  # Password policy
  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # MFA
  mfa_configuration = "OPTIONAL" # OFF | OPTIONAL | ON

  # Email verification
  auto_verified_attributes = ["email"]

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Username configuration
  username_configuration {
    case_sensitive = false
  }

  tags = { Purpose = "lab-auth" }
}

# App client (represents your web/mobile app)
resource "aws_cognito_user_pool_client" "lab" {
  name         = "lab-app-client"
  user_pool_id = aws_cognito_user_pool.lab.id

  # OAuth flows
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  allowed_oauth_flows_user_pool_client = true
  callback_urls                        = ["https://example.com/callback"]
  logout_urls                          = ["https://example.com/logout"]

  supported_identity_providers = ["COGNITO"]

  # Token validity
  access_token_validity  = 1  # hours
  id_token_validity      = 1  # hours
  refresh_token_validity = 30 # days

  # Don't return secret (for public clients like SPAs)
  generate_secret = false
}

# ============================================================
# COGNITO IDENTITY POOL
# Exchanges Cognito/social tokens for AWS credentials (STS)
# Enables authenticated + unauthenticated (guest) access
# SAA-C03: Identity Pool bridges your app to AWS services
# ============================================================
resource "aws_cognito_identity_pool" "lab" {
  identity_pool_name               = "lab_identity_pool"
  allow_unauthenticated_identities = false # No guest access

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.lab.id
    provider_name           = aws_cognito_user_pool.lab.endpoint
    server_side_token_check = false
  }
}

# Authenticated role for Identity Pool
resource "aws_cognito_identity_pool_roles_attachment" "lab" {
  identity_pool_id = aws_cognito_identity_pool.lab.id
  roles = {
    "authenticated" = aws_iam_role.web_identity.arn
  }
}

# =============================================================================
# SECTION: IAM IDENTITY CENTER (AWS SSO)
# =============================================================================
# IAM Identity Center (formerly AWS SSO) = centralized access management
# for multiple AWS accounts and applications from one place.
#
# SAA-C03 KEY FACTS:
#   - Single sign-on across all accounts in the Organization
#   - Identity sources: Built-in directory, Active Directory (AWS Managed or on-prem via AD Connector),
#     or external IdP (Okta, Azure AD, Google Workspace via SAML 2.0 / SCIM)
#   - Permission Sets: IAM policies packaged and deployed to accounts
#     (think: "assign ReadOnlyAccess to dev team for sandbox account")
#   - Attribute-Based Access Control (ABAC): use user/group attributes as conditions
#   - Replaces: account-level IAM users for cross-account access
#   - Replaces: manual cross-account role switching
#
# EXAM TIPS:
#   - "Single sign-on for all AWS accounts" = IAM Identity Center
#   - "Centrally manage access to multiple accounts" = IAM Identity Center
#   - "SCIM provisioning" = auto-sync users from Okta/Azure AD to Identity Center
#   - "Permission Set" = reusable IAM policy deployed across accounts
#   - "AD integration" = Identity Center + AD Connector or AWS Managed AD
#   - Distinguish from: Cognito (app user auth) vs IAM Identity Center (workforce/employee SSO)
#
# NOTE: aws_ssoadmin_* resources require IAM Identity Center to be enabled
# in the management account. The instance_arn comes from the IAM Identity Center console.

data "aws_ssoadmin_instances" "main" {}
# Returns the IAM Identity Center instance ARN and identity store ID.
# There is only ONE Identity Center instance per AWS organization.
# SAA-C03: Identity Center is a regional service but the instance is org-scoped.

locals {
  sso_instance_arn      = tolist(data.aws_ssoadmin_instances.main.arns)[0]
  sso_identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]
}

# Permission Set: Read-Only Access for auditors
resource "aws_ssoadmin_permission_set" "read_only" {
  name             = "lab-ReadOnlyAccess"
  description      = "Read-only access to all AWS services for auditors"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H" # ISO 8601: 8 hours (max 12h)
  # SAA-C03: session_duration is the max SSO session length.
  # After expiry, users must re-authenticate via the Identity Center portal.
}

# Attach AWS managed policy to Permission Set
resource "aws_ssoadmin_managed_policy_attachment" "read_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Permission Set: Developer access (S3 + DynamoDB + Lambda)
resource "aws_ssoadmin_permission_set" "developer" {
  name             = "lab-DeveloperAccess"
  description      = "Developer access: S3, DynamoDB, Lambda, CloudWatch"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

# Inline policy for developer permission set
resource "aws_ssoadmin_permission_set_inline_policy" "developer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*", "dynamodb:*", "lambda:*", "cloudwatch:*", "logs:*"]
        Resource = "*"
      }
    ]
  })
}

# Identity Center Group
resource "aws_identitystore_group" "developers" {
  identity_store_id = local.sso_identity_store_id
  display_name      = "lab-Developers"
  description       = "Developer team group"
}

# Identity Center User
resource "aws_identitystore_user" "dev_user" {
  identity_store_id = local.sso_identity_store_id
  display_name      = "Lab Developer"
  user_name         = "lab-dev-user"

  name {
    given_name  = "Lab"
    family_name = "Developer"
  }

  emails {
    value   = "lab-dev@example.com"
    primary = true
  }
}

# Add user to group
resource "aws_identitystore_group_membership" "dev_user" {
  identity_store_id = local.sso_identity_store_id
  group_id          = aws_identitystore_group.developers.group_id
  member_id         = aws_identitystore_user.dev_user.user_id
}

# Assign Permission Set to Group for an Account
# This gives the developers group DeveloperAccess in the current account.
resource "aws_ssoadmin_account_assignment" "developers" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn

  principal_type = "GROUP"
  principal_id   = aws_identitystore_group.developers.group_id

  target_type = "AWS_ACCOUNT"
  target_id   = data.aws_caller_identity.current.account_id
  # SAA-C03: One account_assignment per permission_set + principal + account.
  # In Organizations: assign to multiple accounts by creating multiple account_assignments.
  # The developers group now has DeveloperAccess in this account.
}
