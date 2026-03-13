###############################################################################
# LAB 39 - Outputs: AWS CloudFormation
# AWS SAA-C03 Exam Prep
###############################################################################
#
# These outputs expose the key identifiers for CloudFormation stacks and
# StackSets managed via Terraform. They demonstrate a real-world meta-pattern:
# using Terraform (general-purpose IaC) to orchestrate CloudFormation
# (AWS-native IaC) as part of a larger multi-tool infrastructure pipeline.
#
# EXAM TIP - IaC tool comparison (SAA-C03 commonly tests this):
#   CloudFormation  = AWS-native, free (no cost for CF itself), automatic
#                     rollback on failure, native AWS Console support,
#                     no state file to manage. AWS-ONLY resources.
#   Terraform       = multi-cloud, requires state file (S3 + DynamoDB for
#                     remote state), plan/apply workflow, HCL syntax,
#                     large provider ecosystem. Manages non-AWS resources too.
#   CDK             = TypeScript/Python/Java/Go/C# code that synthesizes to
#                     CloudFormation templates. Best for developers preferring
#                     code over YAML/JSON. Still deploys via CloudFormation.
#   SAM (Serverless Application Model) = CloudFormation extension for serverless.
#                     Uses Transform: AWS::Serverless-2016-10-31 macro.
#                     Simplifies Lambda, API Gateway, DynamoDB definitions.
#                     EXAM TIP: "Serverless application IaC" -> AWS SAM.
#
###############################################################################

# === CLOUDFORMATION STACK OUTPUTS ===

output "stack_id" {
  description = "CloudFormation stack ID (ARN format: arn:aws:cloudformation:region:account:stack/name/uuid)"
  value       = aws_cloudformation_stack.demo.id
  # The stack ID is the unique ARN of this deployed stack instance.
  # SAA-C03: Stacks are scoped to a single AWS account + region.
  # To deploy the same template to another region, create a separate stack there
  # (or use StackSets to do it automatically across accounts/regions).
  #
  # Stack lifecycle:
  #   CREATE_IN_PROGRESS -> CREATE_COMPLETE (or CREATE_FAILED -> ROLLBACK_COMPLETE)
  #   UPDATE_IN_PROGRESS -> UPDATE_COMPLETE (or UPDATE_ROLLBACK_COMPLETE)
  #   DELETE_IN_PROGRESS -> DELETE_COMPLETE
  # EXAM TIP: If a stack is stuck in ROLLBACK_COMPLETE, you must DELETE it
  # before you can recreate it with the same name.
}

output "stack_outputs" {
  description = "Map of all CloudFormation Outputs from the demo stack (key = Output logical ID, value = resolved value)"
  value       = aws_cloudformation_stack.demo.outputs
  # Terraform exposes all CloudFormation Outputs as a string map here.
  # Access individual values: aws_cloudformation_stack.demo.outputs["BucketName"]
  #
  # SAA-C03 - CloudFormation Outputs cross-stack reference pattern:
  #   Stack A defines:
  #     Outputs:
  #       VpcId:
  #         Value: !Ref MyVpc
  #         Export: { Name: "shared-vpc-id" }
  #   Stack B consumes:
  #     Resources:
  #       MySubnet:
  #         Properties:
  #           VpcId: !ImportValue "shared-vpc-id"
  #
  #   EXAM TIP: You CANNOT delete Stack A while Stack B is importing its exports.
  #   Cross-stack references create a dependency between stacks.
  #   They are limited to the SAME account and SAME region.
}

output "stackset_id" {
  description = "CloudFormation StackSet ID — unique identifier for the multi-account/multi-region deployment set"
  value       = aws_cloudformation_stack_set.logging.id
  # SAA-C03: A StackSet deploys ONE template to MANY accounts/regions simultaneously.
  # The StackSet definition lives in an "administrator" account.
  # "Stack instances" are the individual deployments in target accounts/regions.
  #
  # PERMISSION MODELS:
  #   SELF_MANAGED: manually create IAM roles in admin account AND every target account.
  #     Admin account: AWSCloudFormationStackSetAdministrationRole (trusts CF service)
  #     Target accounts: AWSCloudFormationStackSetExecutionRole (trusts admin account)
  #
  #   SERVICE_MANAGED: uses AWS Organizations trust relationships automatically.
  #     No manual role creation. Requires management account or delegated admin.
  #     Supports AUTOMATIC deployment to new accounts added to the target OU.
  #     EXAM TIP: SERVICE_MANAGED is preferred for Organizations deployments.
}

output "cf_templates_bucket" {
  description = "S3 bucket name for CloudFormation templates — used for template_url references and nested stack templates"
  value       = aws_s3_bucket.cf_templates.bucket
  # SAA-C03 - When to use S3 for CF templates:
  #   1. Template > 51,200 bytes: template_body limit exceeded -> use template_url
  #   2. Nested stacks: AWS::CloudFormation::Stack REQUIRES template_url (no inline)
  #   3. Shared templates: multiple teams/stacks reference the same template in S3
  #   4. GitOps: CI/CD pipeline uploads validated templates to S3, then CF deploys
  #
  # Template URL format:
  #   https://<bucket>.s3.<region>.amazonaws.com/<key>
  #   or the regional domain: <bucket>.s3.<region>.amazonaws.com/<key>
  #
  # EXAM TIP: Use the REGIONAL endpoint (not global s3.amazonaws.com) to ensure
  # CloudFormation accesses the template in the correct region without cross-region
  # latency or potential routing issues.
}

output "cf_templates_bucket_arn" {
  description = "ARN of the S3 bucket containing CloudFormation templates"
  value       = aws_s3_bucket.cf_templates.arn
  # Reference this ARN in IAM policies to grant CloudFormation service roles
  # read access to the template bucket:
  #   { Effect: Allow, Action: s3:GetObject, Resource: "<this ARN>/*" }
}

output "nested_stack_template_url" {
  description = "S3 HTTPS URL for the nested stack template — paste into AWS::CloudFormation::Stack TemplateURL property"
  value       = "https://${aws_s3_bucket.cf_templates.bucket_regional_domain_name}/${aws_s3_object.nested_stack_template.key}"
  # Use this URL in a parent stack:
  #   Resources:
  #     NestedStack:
  #       Type: AWS::CloudFormation::Stack
  #       Properties:
  #         TemplateURL: <this URL>
  #         Parameters:
  #           BucketSuffix: "my-app"
  #
  # Parent stack accesses nested stack outputs via:
  #   Fn::GetAtt: [NestedStack, Outputs.NestedBucketName]
  #
  # SAA-C03: Nested stacks enable modular CloudFormation design.
  # A root stack can compose a VPC stack, a security stack, and an app stack,
  # passing Outputs from one as Parameters to the next.
  # This is the CloudFormation equivalent of Terraform modules.
}

###############################################################################
# SAA-C03 CLOUDFORMATION QUICK REFERENCE
# ============================================================================
# Change Sets        = preview changes before applying (like terraform plan)
#                      Shows: Add, Modify, Remove, Replace (destructive!)
# Drift Detection    = detect manual changes made outside CloudFormation
#                      CF does NOT auto-remediate — only detects
# DeletionPolicy     = Retain | Delete | Snapshot
#                      Retain = keep resource after stack delete (safest for data)
#                      Snapshot = final snapshot before delete (RDS/ElastiCache)
# StackSets          = 1 template -> many accounts + regions simultaneously
# Nested Stacks      = modular templates composed in a parent (same account/region)
# Custom Resources   = Lambda-backed; provision anything CF doesn't support natively
# Rollback Triggers  = CloudWatch alarms that AUTO-ROLLBACK a stack update
# Stack Policies     = JSON policies protecting specific resources from updates
# CAPABILITY_IAM     = required when template creates IAM resources (auto-named)
# CAPABILITY_NAMED_IAM = required when IAM resources have explicit names
# AWS::NoValue       = conditionally omit a property (use with Fn::If)
# Pseudo-parameters  = AWS::AccountId, AWS::Region, AWS::StackName,
#                      AWS::StackId, AWS::NoValue, AWS::URLSuffix
###############################################################################
