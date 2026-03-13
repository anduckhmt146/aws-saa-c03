###############################################################################
# LAB 39 - AWS CloudFormation
# AWS SAA-C03 Exam Prep
###############################################################################
#
# CORE CONCEPT: CloudFormation = AWS-native Infrastructure as Code
#   Define AWS resources in a JSON or YAML TEMPLATE.
#   CloudFormation creates, updates, and deletes resources as a STACK.
#   Terraform is a general-purpose IaC tool; CloudFormation is AWS-only.
#
# THIS LAB: uses Terraform to MANAGE CloudFormation stacks.
#   This is a real-world pattern: CloudFormation for AWS-native IaC,
#   wrapped in Terraform for state management and cross-provider orchestration.
#
# ===========================================================================
# CORE CLOUDFORMATION CONCEPTS
# ===========================================================================
#
# TEMPLATE SECTIONS:
#   AWSTemplateFormatVersion : "2010-09-09" (only valid value)
#   Description    : human-readable description
#   Parameters     : user inputs at deploy time (like Terraform variables)
#   Mappings       : lookup tables (e.g., region -> AMI ID)
#   Conditions     : conditional resource creation (if/then logic)
#   Resources      : REQUIRED. The actual AWS resources to create.
#   Outputs        : values to export or display after deployment
#   Metadata       : additional info (e.g., CloudFormation Designer hints)
#   Transform      : macros (e.g., AWS::Serverless-2016-10-31 for SAM)
#
# STACK:
#   A STACK is the deployed instance of a template. Stacks have a name
#   and are scoped to a single account + region. Resources within a stack
#   are managed together: create, update, delete atomically (with rollback).
#
# ROLLBACK:
#   EXAM TIP: If ANY resource in a stack fails to create or update,
#   CloudFormation automatically rolls back ALL changes in that operation.
#   This is the key advantage over manual infrastructure changes.
#   You can disable rollback (for debugging) but it's not recommended.
#
# CHANGE SETS:
#   Preview what changes will occur before executing an update.
#   Like "terraform plan" before "terraform apply".
#   Lets you review resource replacements (destructive changes) before commit.
#
# DRIFT DETECTION:
#   Detects when actual resource configuration differs from the template.
#   Manual changes (via console or CLI) cause DRIFT.
#   EXAM TIP: CloudFormation does NOT auto-remediate drift. You must detect
#   it, then manually update the template or re-deploy to fix it.
#
# NESTED STACKS:
#   A stack can reference other stacks via AWS::CloudFormation::Stack.
#   Enables modular template design (e.g., VPC template, security template,
#   app template all composed together in a root stack).
#   EXAM TIP: Use nested stacks when template exceeds 51,200 bytes limit
#   or to reuse common patterns across multiple deployments.
#
# STACK SETS:
#   Deploy the SAME stack to MULTIPLE accounts and/or MULTIPLE regions.
#   Useful for: compliance baselines, centralized logging, security guardrails.
#   Requires trust: a delegated admin account or the management (master) account.
#   Two deployment models:
#     SELF_MANAGED: manual trust setup between admin and target accounts.
#     SERVICE_MANAGED: uses AWS Organizations for automatic trust.
#
# DELETION POLICY:
#   Controls what happens to a resource when its stack is deleted (or the
#   resource is removed from the template).
#   Delete   = (default) resource is deleted with the stack.
#   Retain   = resource is kept after stack deletion (orphaned). Use for
#              data stores you want to preserve.
#   Snapshot = RDS, ElastiCache, Redshift: take a final snapshot before delete.
#   EXAM TIP: DeletionPolicy: Retain is the answer when asked "how to
#   prevent data loss when a CloudFormation stack is deleted".
#
# CUSTOM RESOURCES:
#   AWS::CloudFormation::CustomResource (or Custom::MyResourceType)
#   Backed by a Lambda function or SNS topic.
#   Use when you need to provision non-AWS resources or run custom logic
#   during stack operations (e.g., register a domain, call a 3rd-party API).
#   EXAM TIP: Custom resources are invoked synchronously during CREATE,
#   UPDATE, DELETE stack operations. Lambda must send a response to the
#   pre-signed S3 URL provided in the event.
#
# STACK POLICIES:
#   JSON policy document attached to a stack to PROTECT specific resources
#   from being updated or replaced. Different from IAM policies.
#
# CLOUDFORMATION vs TERRAFORM (exam context):
#   CloudFormation: AWS-native, free (no cost for CF itself), deep AWS
#     integration, rollback on failure, AWS Console support.
#   Terraform: multi-provider, open source, state file management required,
#     plan/apply workflow, larger community ecosystem.
#   EXAM TIP: Questions about "IaC for AWS with automatic rollback and
#   native AWS integration" -> CloudFormation.
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

variable "lab_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "saa-c03-lab39"
}

variable "org_id" {
  description = "AWS Organizations ID for StackSet deployment (e.g. o-xxxxxxxxxx)"
  type        = string
  default     = "o-exampleorgid"
  # In a real lab: run `aws organizations describe-organization` to get this.
}

variable "target_ou_id" {
  description = "Target Organizational Unit ID for StackSet instance"
  type        = string
  default     = "ou-xxxx-xxxxxxxx"
  # The OU where StackSet instances will be deployed.
  # Get via: aws organizations list-roots / list-organizational-units-for-parent
}

variable "stackset_target_region" {
  description = "Region where StackSet instances will be deployed"
  type        = string
  default     = "us-east-1"
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

###############################################################################
# IAM ROLE FOR CLOUDFORMATION STACKSETS
# StackSets requires IAM roles in both the ADMIN account and TARGET accounts.
#
# SELF-MANAGED permissions model:
#   Admin account: AWSCloudFormationStackSetAdministrationRole
#     - Trusts cloudformation.amazonaws.com
#     - Assumes AWSCloudFormationStackSetExecutionRole in target accounts
#   Target accounts: AWSCloudFormationStackSetExecutionRole
#     - Trusts the admin account (account ID in trust policy)
#     - Has permissions to create resources the StackSet template specifies
#
# SERVICE_MANAGED permissions model:
#   Uses AWS Organizations service-linked roles. Simpler - no manual role
#   creation in each account. Requires management account or delegated admin.
###############################################################################

data "aws_iam_policy_document" "stacksets_admin_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudformation.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "stacksets_admin" {
  name               = "AWSCloudFormationStackSetAdministrationRole"
  assume_role_policy = data.aws_iam_policy_document.stacksets_admin_assume.json
  description        = "CloudFormation StackSets administration role"
  # EXAM TIP: This role name is the AWS-prescribed name. CloudFormation looks
  # for this exact name in the admin account by default when using
  # SELF_MANAGED permission model.
}

resource "aws_iam_role_policy" "stacksets_admin_execution" {
  name = "AssumeRole-AWSCloudFormationStackSetExecutionRole"
  role = aws_iam_role.stacksets_admin.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = "arn:aws:iam::*:role/AWSCloudFormationStackSetExecutionRole"
        # Allows the admin role to assume the execution role in ANY account.
        # In production, restrict to specific account IDs.
      }
    ]
  })
}

###############################################################################
# CLOUDFORMATION STACK - INLINE TEMPLATE
# This stack demonstrates the main CloudFormation template sections:
# Parameters, Mappings, Conditions, Resources, Outputs.
#
# The template creates:
#   - An S3 bucket with versioning (conditional)
#   - An SNS topic for notifications
#   - SNS subscription if an email is provided
###############################################################################

resource "aws_cloudformation_stack" "demo" {
  name = "${var.lab_prefix}-demo-stack"

  # INLINE TEMPLATE BODY
  # In production, use template_url to reference a template in S3.
  # Inline templates are limited to 51,200 bytes.
  # EXAM TIP: Large templates -> store in S3, use template_url parameter.
  template_body = <<-TEMPLATE
    AWSTemplateFormatVersion: "2010-09-09"

    Description: >
      SAA-C03 CloudFormation demo stack.
      Creates an S3 bucket with optional versioning and an SNS topic.
      Demonstrates Parameters, Mappings, Conditions, Resources, and Outputs.

    ##########################################################################
    # PARAMETERS: User-supplied inputs at deploy time.
    # Types: String, Number, List<Number>, CommaDelimitedList,
    #        AWS-specific types (AWS::EC2::VPC::Id, AWS::SSM::Parameter::Value)
    ##########################################################################
    Parameters:
      EnvironmentName:
        Type: String
        Default: dev
        AllowedValues:
          - dev
          - staging
          - prod
        Description: Deployment environment (affects resource naming and settings)

      EnableVersioning:
        Type: String
        Default: "false"
        AllowedValues:
          - "true"
          - "false"
        Description: Enable S3 bucket versioning

      NotificationEmail:
        Type: String
        Default: ""
        Description: Email address for SNS notifications (leave blank to skip subscription)

      BucketNameSuffix:
        Type: String
        Default: "demo"
        MinLength: 3
        MaxLength: 20
        AllowedPattern: "[a-z0-9-]+"
        ConstraintDescription: Bucket name suffix must be lowercase alphanumeric and hyphens only

    ##########################################################################
    # MAPPINGS: Static lookup tables. Indexed by key(s).
    # Common use: region -> AMI ID, or environment -> instance type.
    # EXAM TIP: Mappings are resolved at deploy time. Use Fn::FindInMap to
    # retrieve values. Cannot use dynamic values (use Parameters for those).
    ##########################################################################
    Mappings:
      EnvironmentConfig:
        dev:
          BucketRetentionDays: 7
          InstanceType: t3.micro
          MultiAZ: false
        staging:
          BucketRetentionDays: 30
          InstanceType: t3.small
          MultiAZ: false
        prod:
          BucketRetentionDays: 90
          InstanceType: t3.medium
          MultiAZ: true

      RegionMap:
        us-east-1:
          ShortName: use1
        us-west-2:
          ShortName: usw2
        eu-west-1:
          ShortName: euw1

    ##########################################################################
    # CONDITIONS: Boolean logic for conditional resource creation/properties.
    # Based on Parameters or other Conditions.
    # EXAM TIP: Conditions let you use ONE template for multiple environments.
    # Reference conditions with: Condition: ConditionName in resource definition,
    # or Fn::If for conditional property values.
    ##########################################################################
    Conditions:
      IsProduction: !Equals [!Ref EnvironmentName, prod]
      IsVersioningEnabled: !Equals [!Ref EnableVersioning, "true"]
      HasNotificationEmail: !Not [!Equals [!Ref NotificationEmail, ""]]
      EnableMFA: !And
        - !Condition IsProduction
        - !Condition IsVersioningEnabled
      # EnableMFA is true only if BOTH conditions are true: prod AND versioning.
      # Other logical functions: Fn::Or, Fn::Not

    ##########################################################################
    # RESOURCES: The only REQUIRED section. All AWS resources are defined here.
    # Logical IDs (e.g., DemoBucket) are scoped to this stack only.
    # Physical IDs (actual resource names) are auto-generated unless specified.
    ##########################################################################
    Resources:

      # S3 BUCKET
      DemoBucket:
        Type: AWS::S3::Bucket
        DeletionPolicy: Retain
        # DeletionPolicy: Retain = keep bucket when stack is deleted.
        # DeletionPolicy: Delete = delete bucket (fails if not empty).
        # DeletionPolicy: Snapshot = not available for S3 (only RDS/EBS).
        # EXAM TIP: Always use Retain for buckets with data you want to keep.
        UpdateReplacePolicy: Retain
        # UpdateReplacePolicy: what to do with the OLD resource when it needs
        # to be REPLACED (not just updated) during a stack update.
        Properties:
          BucketName: !Sub
            - "$${LabPrefix}-$${Suffix}-$${ShortRegion}"
            - LabPrefix: !Ref AWS::StackName
              Suffix: !Ref BucketNameSuffix
              ShortRegion: !FindInMap [RegionMap, !Ref AWS::Region, ShortName]
          # Fn::Sub (short: !Sub) substitutes $${Variable} references.
          # AWS::StackName and AWS::Region are PSEUDO-PARAMETERS (built-in).
          # Other pseudo-parameters: AWS::AccountId, AWS::NoValue, AWS::URLSuffix

          VersioningConfiguration:
            Status: !If [IsVersioningEnabled, Enabled, Suspended]
            # Fn::If: [ConditionName, ValueIfTrue, ValueIfFalse]
            # This sets versioning based on the EnableVersioning parameter.

          LifecycleConfiguration:
            Rules:
              - Id: ExpireOldVersions
                Status: Enabled
                NoncurrentVersionExpiration:
                  NoncurrentDays: !FindInMap
                    - EnvironmentConfig
                    - !Ref EnvironmentName
                    - BucketRetentionDays
                  # Fn::FindInMap: [MapName, TopLevelKey, SecondLevelKey]
                  # Returns the value from the Mappings section.

          PublicAccessBlockConfiguration:
            BlockPublicAcls: true
            BlockPublicPolicy: true
            IgnorePublicAcls: true
            RestrictPublicBuckets: true

          Tags:
            - Key: Environment
              Value: !Ref EnvironmentName
            - Key: ManagedBy
              Value: CloudFormation
            - Key: StackName
              Value: !Ref AWS::StackName

      # BUCKET POLICY - only applied in production
      DemoBucketPolicy:
        Type: AWS::S3::BucketPolicy
        Condition: IsProduction
        # This resource is ONLY created when IsProduction condition is true.
        # If EnvironmentName != prod, this resource does not exist.
        Properties:
          Bucket: !Ref DemoBucket
          # !Ref on a resource returns its physical ID. For S3: bucket name.
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: DenyHTTP
                Effect: Deny
                Principal: "*"
                Action: "s3:*"
                Resource:
                  - !GetAtt DemoBucket.Arn
                  - !Sub "$${DemoBucket.Arn}/*"
                  # !GetAtt returns an attribute of a resource.
                  # DemoBucket.Arn = the ARN of the DemoBucket resource.
                Condition:
                  Bool:
                    "aws:SecureTransport": false
                # Deny all non-HTTPS requests to the bucket.

      # SNS TOPIC
      NotificationTopic:
        Type: AWS::SNS::Topic
        Properties:
          TopicName: !Sub "$${AWS::StackName}-notifications"
          DisplayName: !Sub "Notifications for $${EnvironmentName} environment"
          KmsMasterKeyId: !If
            - IsProduction
            - alias/aws/sns
            - !Ref AWS::NoValue
            # AWS::NoValue removes the property when condition is false.
            # In dev/staging: no KMS encryption. In prod: use AWS-managed key.

      # SNS SUBSCRIPTION - conditional on email being provided
      EmailSubscription:
        Type: AWS::SNS::Subscription
        Condition: HasNotificationEmail
        Properties:
          TopicArn: !Ref NotificationTopic
          Protocol: email
          Endpoint: !Ref NotificationEmail
          # This subscription is only created if an email was provided.

      # CLOUDWATCH ALARM - example of cross-resource referencing
      BucketSizeAlarm:
        Type: AWS::CloudWatch::Alarm
        Properties:
          AlarmName: !Sub "$${AWS::StackName}-bucket-size-alarm"
          AlarmDescription: Alert when S3 bucket exceeds 1 GB
          MetricName: BucketSizeBytes
          Namespace: AWS/S3
          Statistic: Average
          Period: 86400
          EvaluationPeriods: 1
          Threshold: 1073741824
          ComparisonOperator: GreaterThanThreshold
          Dimensions:
            - Name: BucketName
              Value: !Ref DemoBucket
            - Name: StorageType
              Value: StandardStorage
          AlarmActions:
            - !Ref NotificationTopic
            # !Ref on an SNS topic returns the topic ARN.
          TreatMissingData: notBreaching

    ##########################################################################
    # OUTPUTS: Values to display after stack deployment or export to other
    # stacks. Cross-stack references: Export/Import with Fn::ImportValue.
    # EXAM TIP: Outputs from one stack can be imported by another stack
    # in the same region/account using Fn::ImportValue and Export Name.
    ##########################################################################
    Outputs:
      BucketName:
        Description: Name of the S3 bucket created by this stack
        Value: !Ref DemoBucket
        Export:
          Name: !Sub "$${AWS::StackName}-BucketName"
          # Export makes this value available to other stacks via:
          # Fn::ImportValue: "saa-c03-lab39-demo-stack-BucketName"

      BucketArn:
        Description: ARN of the S3 bucket
        Value: !GetAtt DemoBucket.Arn
        Export:
          Name: !Sub "$${AWS::StackName}-BucketArn"

      TopicArn:
        Description: ARN of the SNS notification topic
        Value: !Ref NotificationTopic
        Export:
          Name: !Sub "$${AWS::StackName}-TopicArn"

      EnvironmentType:
        Description: Deployed environment name
        Value: !Ref EnvironmentName

      IsProductionDeployment:
        Description: Whether this is a production deployment
        Value: !If [IsProduction, "YES - Production", "NO - Non-production"]
  TEMPLATE

  # PARAMETERS passed to the CloudFormation template
  parameters = {
    EnvironmentName   = "dev"
    EnableVersioning  = "false"
    NotificationEmail = ""
    BucketNameSuffix  = "lab"
  }

  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]
  # CAPABILITY_IAM: required when the template creates IAM resources
  # (roles, policies, instance profiles) with auto-generated names.
  # CAPABILITY_NAMED_IAM: required when IAM resources have EXPLICIT names.
  # CAPABILITY_AUTO_EXPAND: required when template uses Transform (SAM macros).
  # EXAM TIP: Forgetting capabilities causes an InsufficientCapabilities error.

  on_failure = "ROLLBACK"
  # on_failure options for initial stack creation:
  #   ROLLBACK      = rollback and delete all created resources (default)
  #   DELETE        = delete the entire stack
  #   DO_NOTHING    = leave resources as-is for debugging
  # EXAM TIP: For troubleshooting failed deployments, use DO_NOTHING to
  # inspect resources. Use ROLLBACK in production.

  timeout_in_minutes = 30
  # If stack creation takes longer than 30 minutes, CloudFormation fails
  # and rolls back. Prevents stuck resources from blocking indefinitely.

  tags = {
    Name        = "${var.lab_prefix}-demo-stack"
    ManagedBy   = "Terraform"
    Environment = "lab"
  }
}

###############################################################################
# CLOUDFORMATION STACK SET
# Deploys the SAME template across MULTIPLE accounts and/or regions.
# Use case: organization-wide compliance baseline, centralized logging,
# security guardrails, tagging policies deployed as Config Rules everywhere.
#
# EXAM TIP: StackSets = same template, many accounts/regions simultaneously.
# Managed from a single "administrator" account.
###############################################################################

resource "aws_cloudformation_stack_set" "logging" {
  name             = "${var.lab_prefix}-logging-stackset"
  description      = "Deploys centralized logging S3 bucket across org OUs"
  permission_model = "SELF_MANAGED"
  # permission_model options:
  #   SELF_MANAGED    = you manually create IAM roles in admin + target accounts
  #   SERVICE_MANAGED = uses AWS Organizations, auto-manages trust relationships.
  #                     Requires management (master) account or delegated admin.
  # EXAM TIP: SERVICE_MANAGED is preferred for Organizations because it
  # automatically deploys to NEW accounts added to the OU.

  administration_role_arn = aws_iam_role.stacksets_admin.arn
  execution_role_name     = "AWSCloudFormationStackSetExecutionRole"
  # execution_role_name: name of the IAM role in each TARGET account.
  # CloudFormation assumes this role (via the admin role) to create resources.

  auto_deployment {
    enabled                          = false
    retain_stacks_on_account_removal = false
    # auto_deployment is only for SERVICE_MANAGED permission model.
    # When enabled: automatically deploys to new accounts added to target OU.
    # retain_stacks_on_account_removal: if false, stacks are deleted when
    # an account leaves the OU. If true, resources persist.
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  operation_preferences {
    max_concurrent_count    = 5
    failure_tolerance_count = 2
    region_concurrency_type = "PARALLEL"
    # max_concurrent_count: deploy to at most 5 accounts simultaneously.
    # failure_tolerance_count: allow up to 2 account failures before stopping.
    # region_concurrency_type: PARALLEL = all regions at once in each account.
    #                          SEQUENTIAL = one region at a time per account.
    # EXAM TIP: Lower failure_tolerance + lower concurrency = safer but slower.
    # For initial rollouts, use low concurrency to detect issues early.
  }

  template_body = <<-TEMPLATE
    AWSTemplateFormatVersion: "2010-09-09"
    Description: >
      Centralized logging S3 bucket - deployed via StackSet to all accounts.
      Part of the organization security baseline.

    Parameters:
      OrganizationId:
        Type: String
        Description: AWS Organizations ID for bucket policy scope

      RetentionDays:
        Type: Number
        Default: 365
        Description: Number of days to retain log files

    Resources:
      CentralLoggingBucket:
        Type: AWS::S3::Bucket
        DeletionPolicy: Retain
        UpdateReplacePolicy: Retain
        Properties:
          BucketName: !Sub "central-logs-$${!AWS::AccountId}-$${!AWS::Region}"
          # Note: in YAML heredoc inside Terraform, use $${Var} to prevent
          # Terraform from interpolating $${Var} as a Terraform expression.
          VersioningConfiguration:
            Status: Enabled
          LifecycleConfiguration:
            Rules:
              - Id: TransitionToIA
                Status: Enabled
                Transitions:
                  - TransitionInDays: 30
                    StorageClass: STANDARD_IA
                    # Move to Infrequent Access after 30 days (cheaper).
                  - TransitionInDays: 90
                    StorageClass: GLACIER
                    # Move to Glacier after 90 days (even cheaper).
                ExpirationInDays: !Ref RetentionDays
                # Delete objects after RetentionDays.
          PublicAccessBlockConfiguration:
            BlockPublicAcls: true
            BlockPublicPolicy: true
            IgnorePublicAcls: true
            RestrictPublicBuckets: true
          Tags:
            - Key: Purpose
              Value: CentralizedLogging
            - Key: ManagedBy
              Value: CloudFormation-StackSet
            - Key: AccountId
              Value: !Ref AWS::AccountId

      LoggingBucketPolicy:
        Type: AWS::S3::BucketPolicy
        Properties:
          Bucket: !Ref CentralLoggingBucket
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: AllowOrganizationWrite
                Effect: Allow
                Principal: "*"
                Action:
                  - "s3:PutObject"
                Resource: !Sub "$${CentralLoggingBucket.Arn}/AWSLogs/*"
                Condition:
                  StringEquals:
                    "aws:PrincipalOrgID": !Ref OrganizationId
                # Allow ANY principal in the AWS Organization to write logs.
                # This is the standard pattern for cross-account CloudTrail,
                # Config, and ALB access log centralization.
              - Sid: DenyDelete
                Effect: Deny
                Principal: "*"
                Action:
                  - "s3:DeleteObject"
                  - "s3:DeleteBucket"
                Resource:
                  - !Sub "$${CentralLoggingBucket.Arn}"
                  - !Sub "$${CentralLoggingBucket.Arn}/*"
                # Prevent log tampering - nobody can delete logs.

    Outputs:
      LoggingBucketName:
        Description: Name of the centralized logging bucket in this account
        Value: !Ref CentralLoggingBucket
        Export:
          Name: CentralLoggingBucketName

      LoggingBucketArn:
        Description: ARN of the centralized logging bucket
        Value: !GetAtt CentralLoggingBucket.Arn
        Export:
          Name: CentralLoggingBucketArn
  TEMPLATE

  parameters = {
    OrganizationId = var.org_id
    RetentionDays  = "365"
  }

  tags = {
    Name      = "${var.lab_prefix}-logging-stackset"
    ManagedBy = "Terraform"
    Purpose   = "CentralizedLogging"
  }

  depends_on = [aws_iam_role.stacksets_admin]
}

###############################################################################
# CLOUDFORMATION STACK SET INSTANCE
# An "instance" is the deployment of a StackSet into a SPECIFIC account
# and region (or OU + region combination).
#
# For SERVICE_MANAGED: target deployment_targets (OU IDs).
# For SELF_MANAGED: target specific account IDs.
###############################################################################

resource "aws_cloudformation_stack_set_instance" "logging_ou" {
  stack_set_name = aws_cloudformation_stack_set.logging.name
  # NOTE: the top-level "region" argument is deprecated in AWS provider v5.x.
  # Target region is now specified via deployment_targets or defaults to the
  # provider region. Use the stackset_target_region variable in the provider
  # alias if multi-region deployment is needed.

  deployment_targets {
    organizational_unit_ids = [var.target_ou_id]
    # Deploy to ALL accounts currently in this OU.
    # When SERVICE_MANAGED auto_deployment is enabled, new accounts added
    # to this OU automatically get the stack deployed.
  }

  operation_preferences {
    max_concurrent_count    = 3
    failure_tolerance_count = 1
    region_concurrency_type = "PARALLEL"
  }

  parameter_overrides = {
    RetentionDays = "180"
    # Override the default parameter value FOR THIS SPECIFIC INSTANCE.
    # Allows customization per OU/account without changing the StackSet template.
    # OrganizationId is inherited from the StackSet parameter (not overridden).
  }

  # EXAM TIP: StackSet instances can have parameter overrides per account/OU.
  # This lets you use ONE StackSet with different retention periods for
  # different OUs (e.g., regulated accounts = longer retention).
}

###############################################################################
# ADDITIONAL REFERENCE: CLOUDFORMATION CUSTOM RESOURCE PATTERN
# (defined as a local to document the pattern - not actually deployed here)
###############################################################################

locals {
  custom_resource_template_example = <<-DOC
    # CUSTOM RESOURCE TEMPLATE PATTERN (reference only, not deployed)
    #
    # Custom Resources invoke a Lambda function during CREATE/UPDATE/DELETE
    # stack operations. The Lambda must signal success/failure back to
    # CloudFormation via a pre-signed S3 URL.
    #
    # Use cases:
    #   - Create resources CloudFormation doesn't natively support
    #   - Call external APIs during deployment
    #   - Run data migration scripts as part of a stack update
    #   - Look up values dynamically (AMI IDs, SSM parameters, account IDs)
    #
    # AWSTemplateFormatVersion: "2010-09-09"
    # Resources:
    #   CustomResourceLambda:
    #     Type: AWS::Lambda::Function
    #     Properties:
    #       FunctionName: custom-resource-handler
    #       Runtime: python3.12
    #       Handler: index.handler
    #       Role: !GetAtt LambdaExecutionRole.Arn
    #       Code:
    #         ZipFile: |
    #           import json, urllib3, boto3
    #           def handler(event, context):
    #             # event contains: RequestType (Create/Update/Delete),
    #             #   ResourceProperties, ResponseURL (pre-signed S3 URL)
    #             request_type = event['RequestType']
    #             response = {
    #               'Status': 'SUCCESS',
    #               'PhysicalResourceId': 'my-custom-resource-id',
    #               'StackId': event['StackId'],
    #               'RequestId': event['RequestId'],
    #               'LogicalResourceId': event['LogicalResourceId'],
    #               'Data': {'OutputKey': 'OutputValue'}
    #             }
    #             http = urllib3.PoolManager()
    #             http.request('PUT', event['ResponseURL'],
    #                          body=json.dumps(response),
    #                          headers={'Content-Type': ''})
    #
    #   MyCustomResource:
    #     Type: Custom::MyResource
    #     Properties:
    #       ServiceToken: !GetAtt CustomResourceLambda.Arn
    #       # ServiceToken = Lambda ARN or SNS topic ARN to invoke
    #       CustomParam1: "value1"
    #       # All other properties are passed to Lambda in ResourceProperties
    DOC
  # This local just documents the pattern. In a real lab you would deploy
  # the custom resource Lambda and reference it in a stack template.
}

###############################################################################
# S3 BUCKET FOR CLOUDFORMATION TEMPLATES
# CloudFormation templates can be stored in S3 and referenced via template_url.
#
# WHY S3 for templates:
#   1. Size limit: inline template_body is capped at 51,200 bytes.
#      Large templates MUST use template_url pointing to an S3 object.
#   2. Nested stacks: AWS::CloudFormation::Stack resources REQUIRE template_url.
#      You cannot use an inline template for a nested stack child.
#   3. Versioning: S3 versioning on the template bucket lets you track changes
#      to templates over time and roll back to previous template versions.
#   4. Access control: restrict who can modify templates via S3 bucket policies
#      and IAM policies (important for compliance and GitOps workflows).
#
# EXAM TIP - Nested Stacks:
#   Root stack (parent) contains:
#     Type: AWS::CloudFormation::Stack
#     Properties:
#       TemplateURL: https://s3.amazonaws.com/my-bucket/vpc-stack.yaml
#       Parameters: { VpcCidr: "10.0.0.0/16" }
#   The child stack creates a VPC; root stack references its Outputs via:
#     Fn::GetAtt: [VpcStack, Outputs.VpcId]
#   This modular approach is the CloudFormation equivalent of Terraform modules.
###############################################################################

resource "aws_s3_bucket" "cf_templates" {
  bucket        = "${var.lab_prefix}-cf-templates-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  # Account ID suffix guarantees global uniqueness (S3 names are global).
  # force_destroy = true allows Terraform to delete even non-empty buckets.
  # In production: remove force_destroy and use lifecycle policies.

  tags = {
    Name    = "${var.lab_prefix}-cf-templates"
    Purpose = "CloudFormation template storage for nested stacks and large templates"
  }
}

resource "aws_s3_bucket_versioning" "cf_templates" {
  bucket = aws_s3_bucket.cf_templates.id

  versioning_configuration {
    status = "Enabled"
    # Versioning tracks every change to a template file.
    # If you push a broken template update, you can reference the previous
    # S3 version URL in your CloudFormation stack to roll back.
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cf_templates" {
  bucket = aws_s3_bucket.cf_templates.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
      # SSE-S3 encryption for template files.
      # CloudFormation can read SSE-S3 encrypted templates without extra config.
      # If you use SSE-KMS, ensure CloudFormation's service role has kms:Decrypt.
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cf_templates" {
  bucket                  = aws_s3_bucket.cf_templates.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  # Templates in S3 should NOT be publicly accessible.
  # CloudFormation accesses them using the service's own credentials,
  # not via public URLs. The bucket just needs to be readable by CF.
}

# Upload a nested stack template demonstrating DeletionPolicy: Retain.
# This file would normally be a complete CloudFormation template stored in your
# version control system and uploaded to S3 as part of a CI/CD pipeline.
resource "aws_s3_object" "nested_stack_template" {
  bucket       = aws_s3_bucket.cf_templates.id
  key          = "templates/nested-s3-bucket.yaml"
  content_type = "application/x-yaml"

  content = <<-YAML
    AWSTemplateFormatVersion: "2010-09-09"
    Description: >
      Nested stack example: creates an S3 bucket with DeletionPolicy: Retain.
      This template is referenced by a parent stack via TemplateURL pointing
      to this S3 object. Demonstrates Nested Stacks and DeletionPolicy.

    Parameters:
      BucketSuffix:
        Type: String
        Default: "nested-demo"
        Description: Suffix appended to the bucket name for uniqueness

      EnableVersioning:
        Type: String
        Default: "true"
        AllowedValues:
          - "true"
          - "false"

    Conditions:
      VersioningEnabled: !Equals [!Ref EnableVersioning, "true"]

    Resources:
      NestedBucket:
        Type: AWS::S3::Bucket
        DeletionPolicy: Retain
        UpdateReplacePolicy: Retain
        # DeletionPolicy: Retain = when the PARENT stack is deleted (or this
        # nested stack is removed from the parent), this S3 bucket is NOT deleted.
        # The bucket becomes an "orphan" - it exists in your account but no
        # CloudFormation stack manages it.
        #
        # EXAM TIP - DeletionPolicy values:
        #   Delete   = (default) delete the resource when stack is deleted
        #   Retain   = keep the resource, detach from stack management
        #   Snapshot = supported by RDS, ElastiCache, Redshift only.
        #              Takes a final snapshot BEFORE deleting the resource.
        Properties:
          BucketName: !Sub "nested-$${BucketSuffix}-$${AWS::AccountId}"
          VersioningConfiguration:
            Status: !If [VersioningEnabled, Enabled, Suspended]
          PublicAccessBlockConfiguration:
            BlockPublicAcls: true
            BlockPublicPolicy: true
            IgnorePublicAcls: true
            RestrictPublicBuckets: true
          Tags:
            - Key: ManagedBy
              Value: CloudFormation-NestedStack
            - Key: DeletionPolicy
              Value: Retain
            - Key: ParentStack
              Value: !Ref AWS::StackId

    Outputs:
      NestedBucketName:
        Description: Name of the bucket created by this nested stack
        Value: !Ref NestedBucket
        # Parent stack accesses this via:
        #   Fn::GetAtt: [NestedStackLogicalId, Outputs.NestedBucketName]

      NestedBucketArn:
        Description: ARN of the bucket created by this nested stack
        Value: !GetAtt NestedBucket.Arn
        Export:
          Name: !Sub "$${AWS::StackName}-NestedBucketArn"
  YAML

  etag = md5(<<-YAML
    AWSTemplateFormatVersion: "2010-09-09"
    Description: >
      Nested stack example: creates an S3 bucket with DeletionPolicy: Retain.
      This template is referenced by a parent stack via TemplateURL pointing
      to this S3 object. Demonstrates Nested Stacks and DeletionPolicy.

    Parameters:
      BucketSuffix:
        Type: String
        Default: "nested-demo"
        Description: Suffix appended to the bucket name for uniqueness

      EnableVersioning:
        Type: String
        Default: "true"
        AllowedValues:
          - "true"
          - "false"

    Conditions:
      VersioningEnabled: !Equals [!Ref EnableVersioning, "true"]

    Resources:
      NestedBucket:
        Type: AWS::S3::Bucket
        DeletionPolicy: Retain
        UpdateReplacePolicy: Retain
        Properties:
          BucketName: !Sub "nested-$${BucketSuffix}-$${AWS::AccountId}"
          VersioningConfiguration:
            Status: !If [VersioningEnabled, Enabled, Suspended]
          PublicAccessBlockConfiguration:
            BlockPublicAcls: true
            BlockPublicPolicy: true
            IgnorePublicAcls: true
            RestrictPublicBuckets: true
          Tags:
            - Key: ManagedBy
              Value: CloudFormation-NestedStack
            - Key: DeletionPolicy
              Value: Retain
            - Key: ParentStack
              Value: !Ref AWS::StackId

    Outputs:
      NestedBucketName:
        Description: Name of the bucket created by this nested stack
        Value: !Ref NestedBucket

      NestedBucketArn:
        Description: ARN of the bucket created by this nested stack
        Value: !GetAtt NestedBucket.Arn
        Export:
          Name: !Sub "$${AWS::StackName}-NestedBucketArn"
  YAML
  )
  # etag based on template content ensures Terraform re-uploads when the
  # template changes (triggers CloudFormation stack update if template_url is used).

  tags = {
    Name    = "nested-s3-bucket-template"
    Purpose = "Nested stack demo - DeletionPolicy Retain example"
  }
}

###############################################################################
# NOTE: All outputs are defined in outputs.tf (see that file for descriptions
# and SAA-C03 exam notes on each output value).
###############################################################################

###############################################################################
# SAA-C03 EXAM CHEATSHEET - CLOUDFORMATION
# ============================================================================
# Q: What happens if a CloudFormation stack update fails?
# A: Automatic ROLLBACK to the previous known-good state. All changes made
#    during that update operation are reversed.
#
# Q: What is a Change Set?
# A: Preview of changes before applying an update. Like "terraform plan".
#    Shows which resources will be added, modified, or REPLACED (destructive).
#
# Q: How do you prevent data loss when deleting a CloudFormation stack?
# A: Set DeletionPolicy: Retain on the resource (e.g., S3, RDS).
#    The resource persists after stack deletion but is no longer managed by CF.
#
# Q: What is Drift Detection?
# A: Detects differences between actual resource config and the CF template.
#    Caused by manual changes. CF does NOT auto-remediate drift.
#
# Q: StackSets vs Nested Stacks?
# A: StackSets = same template -> multiple accounts/regions.
#    Nested Stacks = modular templates composed into a parent stack (same account).
#
# Q: What are Custom Resources used for?
# A: Provisioning non-AWS resources or running custom code during stack ops.
#    Backed by Lambda or SNS. Must signal SUCCESS/FAILURE back to CF.
#
# Q: What CAPABILITY is required for IAM resources in a CF template?
# A: CAPABILITY_IAM (auto-named) or CAPABILITY_NAMED_IAM (explicit names).
#    Forgetting this -> InsufficientCapabilitiesException.
#
# Q: What is the AWS::NoValue pseudo-parameter?
# A: Used with Fn::If to conditionally OMIT a property from a resource.
#    e.g., !If [IsProd, alias/aws/kms, !Ref AWS::NoValue]
###############################################################################
