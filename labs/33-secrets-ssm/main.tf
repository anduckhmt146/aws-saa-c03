# =============================================================================
# LAB 33: SECRETS MANAGER, SSM PARAMETER STORE, AND ACM
# =============================================================================
#
# SAA-C03 EXAM TOPICS COVERED:
#
# SECRETS MANAGER:
#   - Fully managed service to store, retrieve, and rotate secrets
#   - Use cases: DB passwords, API keys, OAuth tokens, SSH keys
#   - Auto-rotation: Lambda function invoked on a schedule (e.g., every 30 days)
#   - Built-in rotation support for: RDS, Aurora, Redshift, DocumentDB
#   - Cross-account access: resource-based policy on the secret + KMS key policy
#   - Multi-region replication: primary secret replicated to replica regions
#   - Cost: $0.40/secret/month + $0.05 per 10,000 API calls
#   - SAA-C03 KEY: Use Secrets Manager when you need AUTOMATIC ROTATION of
#     database credentials. Integrates natively with RDS/Aurora without
#     writing custom Lambda code.
#
# SSM PARAMETER STORE:
#   - Hierarchical key-value store for configuration data and secrets
#   - Tiers:
#       Standard: free, max 10,000 params, 4KB value, no param policies
#       Advanced: $0.05/param/month, max 100,000 params, 8KB value, TTL policies
#   - Types:
#       String     = plain text
#       StringList = comma-separated plain text
#       SecureString = encrypted with KMS (aws/ssm CMK or custom CMK)
#   - Hierarchy example: /myapp/prod/db_password, /myapp/dev/api_key
#   - No built-in rotation (need custom Lambda or EventBridge + Lambda)
#   - Cost: Standard = free; Advanced = $0.05/param/month
#   - SAA-C03 KEY: Parameter Store = cheaper option for config/secrets that
#     do NOT need auto-rotation. Use hierarchies for environment separation.
#
# SECRETS MANAGER vs PARAMETER STORE:
#   - Secrets Manager: auto-rotation built-in, cross-region replication,
#     higher cost, designed specifically for secrets
#   - Parameter Store: no rotation, cheaper (free tier), config + secrets,
#     larger limits for Advanced tier
#   - SAA-C03 DECISION RULE:
#       - DB credentials needing rotation → Secrets Manager
#       - App config, feature flags, cheap secrets → Parameter Store
#       - Need to share secrets across regions → Secrets Manager (replication)
#
# KMS INTEGRATION:
#   - Both services use KMS for encryption at rest
#   - Secrets Manager default CMK: aws/secretsmanager (AWS managed)
#   - Parameter Store SecureString default: aws/ssm (AWS managed)
#   - Custom CMK: specify kms_key_id for customer-managed keys
#   - Cross-account access requires explicit KMS key policy grants
#
# ACM (CERTIFICATE MANAGER):
#   - Provision, manage, and deploy SSL/TLS certificates
#   - Public certs: FREE when used with ALB, CloudFront, API Gateway, NLB
#   - Private certs: AWS Private CA (charged separately)
#   - Validation methods: DNS validation (recommended) or email validation
#   - DNS validation: adds CNAME record to Route 53 (auto-renewed)
#   - Email validation: sends email to domain contacts (manual renewal)
#   - Auto-renewal: ACM automatically renews before expiration
#   - CANNOT export private key → cannot install on EC2 directly
#   - SAA-C03 KEY:
#       - ACM certs = free for AWS load balancers and CloudFront
#       - Cannot use ACM cert on EC2 → use self-signed or bring-your-own
#       - Use ACM with ALB for HTTPS termination (offloads TLS from EC2)
#       - Wildcard certs (*.example.com) supported
#
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# KMS KEY FOR SECRETS MANAGER
# -----------------------------------------------------------------------------
# SAA-C03: Customer-managed CMK gives you control over key rotation,
# deletion windows, and cross-account access policies.
# Default aws/secretsmanager CMK is simpler but less control.

resource "aws_kms_key" "secrets" {
  # SAA-C03: enable_key_rotation = true is a security best practice
  # AWS automatically rotates the CMK material every year
  description             = "CMK for Secrets Manager - lab 33"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSecretsManagerServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "lab33-secrets-cmk"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/lab33-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# -----------------------------------------------------------------------------
# SECRETS MANAGER: DATABASE PASSWORD SECRET
# -----------------------------------------------------------------------------
# SAA-C03: aws_secretsmanager_secret defines the secret container (metadata).
# aws_secretsmanager_secret_version stores the actual secret value.
# The secret value should be JSON for structured credentials.

resource "aws_secretsmanager_secret" "db_password" {
  name        = "lab33/rds/master-password"
  description = "RDS master password for lab 33 database"

  # Use customer-managed KMS key instead of default aws/secretsmanager
  kms_key_id = aws_kms_key.secrets.arn

  # SAA-C03: recovery_window_in_days is the "soft delete" window
  # During this time, the secret is marked for deletion but can be restored
  # Set to 0 to force immediate deletion (useful in dev/test)
  recovery_window_in_days = 7

  # SAA-C03: Replica secrets are useful for multi-region applications
  # The primary secret is replicated to the replica region with its own KMS key
  # replica {
  #   region     = "us-west-2"
  #   kms_key_id = "arn:aws:kms:us-west-2:ACCOUNT:key/KEY-ID"
  # }

  tags = {
    Name = "lab33-db-password"
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id

  # SAA-C03: Best practice is to store structured JSON for RDS credentials
  # The rotation Lambda function expects this format:
  # engine, host, username, password, dbname, port
  secret_string = jsonencode({
    engine   = "mysql"
    host     = "lab33-db.cluster-xxxx.us-east-1.rds.amazonaws.com"
    username = "admin"
    password = "PLACEHOLDER_CHANGE_ME_${random_id.suffix.hex}"
    dbname   = "labdb"
    port     = 3306
  })

  # SAA-C03: version_stages control which version is "current"
  # AWSCURRENT = the active version apps should use
  # AWSPENDING  = set by rotation Lambda before promoting
  # AWSPREVIOUS = old version kept for rollback
  version_stages = ["AWSCURRENT"]
}

resource "random_id" "suffix" {
  byte_length = 4
}

# SAA-C03: Separate API key secret to demonstrate simple string secrets
resource "aws_secretsmanager_secret" "api_key" {
  name                    = "lab33/external-api/key"
  description             = "Third-party API key - no auto-rotation needed"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7

  tags = {
    Name = "lab33-api-key"
  }
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = "sk-PLACEHOLDER-api-key-value"
}

# -----------------------------------------------------------------------------
# IAM ROLE FOR ROTATION LAMBDA
# -----------------------------------------------------------------------------
# SAA-C03: The rotation Lambda needs permissions to:
#   1. Call secretsmanager:GetSecretValue, PutSecretValue, UpdateSecretVersionStage
#   2. Use the KMS key to decrypt/re-encrypt
#   3. Connect to the database to change the password

resource "aws_iam_role" "rotation_lambda" {
  name = "lab33-secrets-rotation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "lab33-rotation-lambda-role"
  }
}

resource "aws_iam_role_policy" "rotation_lambda_secrets" {
  name = "lab33-rotation-lambda-secrets-policy"
  role = aws_iam_role.rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerPermissions"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Sid    = "KMSDecryptForRotation"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.secrets.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# LAMBDA FUNCTION FOR ROTATION
# -----------------------------------------------------------------------------
# SAA-C03: AWS provides pre-built rotation Lambda functions for:
#   - RDS MySQL/PostgreSQL/Oracle/SQL Server
#   - DocumentDB, Redshift
#   - Generic secret rotation
# Deploy from AWS Serverless Application Repository (SAR) in production.
# This lab creates a placeholder Lambda to illustrate the rotation setup.

resource "aws_lambda_function" "rotation" {
  function_name = "lab33-secrets-rotation"
  role          = aws_iam_role.rotation_lambda.arn

  # SAA-C03: In production, use the AWS-provided rotation function from SAR:
  # aws serverlessrepo get-application --application-id \
  #   arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSMySQLRotationSingleUser
  filename         = data.archive_file.rotation_lambda.output_path
  source_code_hash = data.archive_file.rotation_lambda.output_base64sha256
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${data.aws_region.current.name}.amazonaws.com"
    }
  }

  tags = {
    Name = "lab33-rotation-lambda"
  }
}

data "archive_file" "rotation_lambda" {
  type        = "zip"
  output_path = "/tmp/lab33-rotation-lambda.zip"

  source {
    content  = <<-PYTHON
      import boto3
      import json

      def handler(event, context):
          """
          SAA-C03: Rotation Lambda is called with 4 steps:
          1. createSecret  - generate new secret value (AWSPENDING stage)
          2. setSecret     - set new password on the database
          3. testSecret    - verify AWSPENDING version works
          4. finishSecret  - promote AWSPENDING to AWSCURRENT
          """
          arn   = event['SecretId']
          token = event['ClientRequestToken']
          step  = event['Step']
          print(f"Rotation step: {step} for secret: {arn}")
          # In production: implement each step to change DB password
          return {"status": "ok", "step": step}
    PYTHON
    filename = "index.py"
  }
}

# Allow Secrets Manager to invoke the rotation Lambda
resource "aws_lambda_permission" "allow_secretsmanager" {
  statement_id  = "AllowSecretsManagerInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.db_password.arn
}

# -----------------------------------------------------------------------------
# SECRETS MANAGER: ROTATION CONFIGURATION
# -----------------------------------------------------------------------------
# SAA-C03: Rotation schedule:
#   - automatically_after_days: rotate every N days (e.g., 30)
#   - schedule_expression: cron or rate expression (Advanced option)
# When rotation is enabled, Secrets Manager immediately rotates once,
# then follows the schedule.
#
# SAA-C03 EXAM NOTE: RDS/Aurora native integration means you do NOT need
# to write a custom Lambda. Secrets Manager calls the RDS API to change
# the password AND updates the secret value atomically.

resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    # SAA-C03: 30-day rotation is a common compliance requirement (PCI-DSS, etc.)
    automatically_after_days = 30

    # Alternative: use schedule_expression for more precise control
    # schedule_expression = "cron(0 2 1 * ? *)"  # 2 AM on 1st of each month
  }

  depends_on = [aws_lambda_permission.allow_secretsmanager]
}

# -----------------------------------------------------------------------------
# SSM PARAMETER STORE: STRING PARAMETER
# -----------------------------------------------------------------------------
# SAA-C03: String type = plain text, no encryption.
# Use for non-sensitive config: app version, feature flags, URLs.
# Standard tier is free and sufficient for most use cases.

resource "aws_ssm_parameter" "app_environment" {
  name        = "/lab33/app/environment"
  description = "Current deployment environment"
  type        = "String"
  value       = "production"

  # SAA-C03: Standard tier = free, 4KB max, no parameter policies (TTL, notifications)
  # tier = "Standard"  # default, no cost

  tags = {
    Name = "lab33-app-environment"
  }
}

# -----------------------------------------------------------------------------
# SSM PARAMETER STORE: STRINGLIST PARAMETER
# -----------------------------------------------------------------------------
# SAA-C03: StringList = comma-separated values stored as plain text.
# Use for: allowed IP ranges, feature flag lists, AZ lists.
# NOT encrypted, so do not store sensitive data.

resource "aws_ssm_parameter" "allowed_regions" {
  name        = "/lab33/app/allowed-regions"
  description = "AWS regions this application is allowed to operate in"
  type        = "StringList"
  value       = "us-east-1,us-west-2,eu-west-1"

  tags = {
    Name = "lab33-allowed-regions"
  }
}

# -----------------------------------------------------------------------------
# SSM PARAMETER STORE: SECURESTRING PARAMETER
# -----------------------------------------------------------------------------
# SAA-C03: SecureString = value encrypted with KMS.
# Use for: passwords, API keys, secrets that DON'T need rotation.
# Reading SecureString requires kms:Decrypt permission on the CMK.
#
# STANDARD vs ADVANCED tier for SecureString:
#   Standard: free, 4KB, no TTL policy, no change notification
#   Advanced: $0.05/month, 8KB, TTL policy (auto-expire), EventBridge notifications
#
# Cross-account: grant target account access to KMS key + SSM parameter (resource policy
# only available on Advanced tier via parameter policy, OR use RAM for sharing)

resource "aws_ssm_parameter" "db_connection_string" {
  name        = "/lab33/app/db-connection-string"
  description = "Database connection string - encrypted with custom KMS key"
  type        = "SecureString"
  value       = "mysql://admin:password@lab33-db.us-east-1.rds.amazonaws.com:3306/labdb"

  # SAA-C03: Specify custom KMS key ARN for SecureString
  # Default (omit key_id) uses aws/ssm AWS-managed key
  key_id = aws_kms_key.ssm.arn

  # SAA-C03: Advanced tier enables:
  #   - Parameter policies: TTL (auto-delete), Expiration (notification), NoChangeNotification
  #   - 8KB value size limit (vs 4KB Standard)
  #   - Up to 100,000 params (vs 10,000 Standard)
  # tier = "Advanced"

  tags = {
    Name = "lab33-db-connection-string"
  }
}

# Separate KMS key for SSM to demonstrate key separation by service
resource "aws_kms_key" "ssm" {
  description             = "CMK for SSM Parameter Store SecureString - lab 33"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "lab33-ssm-cmk"
  }
}

resource "aws_kms_alias" "ssm" {
  name          = "alias/lab33-ssm"
  target_key_id = aws_kms_key.ssm.key_id
}

# -----------------------------------------------------------------------------
# ACM: SSL/TLS CERTIFICATE WITH DNS VALIDATION
# -----------------------------------------------------------------------------
# SAA-C03: ACM provisions free SSL/TLS certificates for use with:
#   - Application Load Balancer (ALB)
#   - Network Load Balancer (NLB) - for TLS termination
#   - CloudFront distributions
#   - API Gateway
#   - Elastic Beanstalk
#
# CANNOT use ACM certificates on:
#   - EC2 instances directly (private key is not exportable)
#   - On-premises servers
#   - Self-managed Nginx/Apache on EC2
# Workaround for EC2: use self-signed cert, bring-your-own, or ACM Private CA
#
# VALIDATION METHODS:
#   DNS validation (recommended):
#     - Add CNAME record to hosted zone
#     - Auto-renews as long as CNAME exists
#     - Works even if email is unavailable
#   Email validation:
#     - Email sent to domain admin contacts (WHOIS)
#     - Must manually renew each year
#
# WILDCARD CERTIFICATES:
#   - *.example.com covers one level: app.example.com, api.example.com
#   - Does NOT cover: sub.app.example.com (two levels)
#   - Subject Alternative Names (SANs) can include multiple domains

resource "aws_acm_certificate" "main" {
  # SAA-C03: Use your actual domain. For lab purposes we use a placeholder.
  # CloudFront certs MUST be created in us-east-1 regardless of other resources.
  domain_name = "lab33.example.com"

  # SAA-C03: Subject Alternative Names allow one cert to cover multiple domains
  subject_alternative_names = [
    "api.lab33.example.com",
    "*.lab33.example.com"
  ]

  # SAA-C03: DNS validation preferred over EMAIL for auto-renewal
  validation_method = "DNS"

  # SAA-C03: lifecycle create_before_destroy prevents downtime when replacing certs
  # Without this, Terraform destroys the old cert before creating the new one,
  # causing a brief period where the ALB has no valid certificate.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "lab33-acm-cert"
  }
}

# -----------------------------------------------------------------------------
# ROUTE 53: DNS VALIDATION RECORDS FOR ACM
# -----------------------------------------------------------------------------
# SAA-C03: ACM generates CNAME records that must be added to your DNS zone.
# for_each on domain_validation_options handles SANs automatically.
# The validation record proves you control the domain.

# NOTE: This data source requires an existing Route 53 hosted zone.
# Comment out if you do not have a hosted zone for "example.com".
# data "aws_route53_zone" "main" {
#   name         = "example.com"
#   private_zone = false
# }

# resource "aws_route53_record" "cert_validation" {
#   for_each = {
#     for dvo in aws_acm_certificate.main.domain_validation_options :
#     dvo.domain_name => {
#       name   = dvo.resource_record_name
#       record = dvo.resource_record_value
#       type   = dvo.resource_record_type
#     }
#   }
#
#   allow_overwrite = true
#   name            = each.value.name
#   records         = [each.value.record]
#   ttl             = 60
#   type            = each.value.type
#   zone_id         = data.aws_route53_zone.main.zone_id
# }

# -----------------------------------------------------------------------------
# ACM CERTIFICATE VALIDATION
# -----------------------------------------------------------------------------
# SAA-C03: aws_acm_certificate_validation waits until ACM confirms DNS records
# are present and the certificate is issued (status = ISSUED).
# This can take 5-30 minutes for DNS propagation.
# Resources that depend on this (ALB listener, CloudFront) should reference
# this resource to ensure the cert is ready before being attached.

resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  # SAA-C03: validation_record_fqdns tells Terraform which DNS records to wait for.
  # Uncomment when Route 53 records are configured above.
  # validation_record_fqdns = [
  #   for record in aws_route53_record.cert_validation : record.fqdn
  # ]

  # Without the Route 53 records, this validation step will not complete
  # in a real environment — shown here for structural completeness.
  timeouts {
    create = "45m"
  }
}

# -----------------------------------------------------------------------------
# OUTPUTS FILE REFERENCE
# -----------------------------------------------------------------------------
# See outputs.tf for exported values:
#   - secrets_manager_secret_arn
#   - ssm_parameter_arns
#   - acm_certificate_arn
#   - kms_key_arns
