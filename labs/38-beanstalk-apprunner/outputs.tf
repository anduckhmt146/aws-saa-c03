###############################################################################
# LAB 38 - Outputs: Elastic Beanstalk & App Runner
# AWS SAA-C03 Exam Prep
###############################################################################
#
# These outputs expose the key identifiers and URLs for the resources
# provisioned in main.tf. They are also the canonical "answers" to common
# SAA-C03 scenario questions about Beanstalk and App Runner:
#
#   - beanstalk_app_name  : logical container for all environments/versions
#   - beanstalk_env_url   : endpoint URL via the ELB (for HTTP access)
#   - beanstalk_env_cname : CNAME assigned by Beanstalk (used in Blue/Green)
#   - apprunner_service_url : auto-provisioned HTTPS URL (no ACM setup needed)
#   - apprunner_service_arn : ARN for IAM policies and cross-service references
#
# EXAM TIP - Blue/Green deployments with Beanstalk:
#   Blue environment has URL: myapp-blue.us-east-1.elasticbeanstalk.com
#   Green environment has URL: myapp-green.us-east-1.elasticbeanstalk.com
#   "Swap Environment URLs" in the console atomically swaps the CNAMEs.
#   Instant rollback: swap them back. Both environments stay running during swap.
#
###############################################################################

# === ELASTIC BEANSTALK OUTPUTS ===

output "beanstalk_app_name" {
  description = "Name of the Elastic Beanstalk application (logical container for all environments and versions)"
  value       = aws_elastic_beanstalk_application.app.name
  # SAA-C03: An Application is the top-level Beanstalk object. It holds ALL
  # environments (dev, staging, prod) and ALL application versions (v1, v2, v3).
  # You reference this name when creating new environments or deploying versions.
}

output "beanstalk_env_name" {
  description = "Name of the Elastic Beanstalk web server environment"
  value       = aws_elastic_beanstalk_environment.web.name
}

output "beanstalk_env_url" {
  description = "ELB endpoint URL for the Beanstalk web environment (HTTP access via the Application Load Balancer)"
  value       = aws_elastic_beanstalk_environment.web.endpoint_url
  # endpoint_url is the DNS name of the ELB created by Beanstalk.
  # SAA-C03: Beanstalk automatically creates and manages the ALB/ELB for you.
  # The endpoint_url is what you use in Route 53 alias records to map a
  # custom domain to the Beanstalk environment.
}

output "beanstalk_env_cname" {
  description = "CNAME assigned to the Beanstalk environment (e.g. myapp.us-east-1.elasticbeanstalk.com) — swap this for Blue/Green deployments"
  value       = aws_elastic_beanstalk_environment.web.cname
  # EXAM TIP - Blue/Green deployments with Beanstalk:
  #   Two full environments run in parallel (Blue = current, Green = new version).
  #   When Green is healthy, use "Swap Environment URLs" to atomically exchange
  #   the CNAMEs. All traffic instantly shifts to Green.
  #   Rollback = swap CNAMEs back to Blue. Zero downtime, instant rollback.
  #   This is NOT a built-in DeploymentPolicy; it is a manual CNAME swap action.
}

output "beanstalk_solution_stack" {
  description = "Platform stack name (OS + runtime) running in the Beanstalk environment"
  value       = aws_elastic_beanstalk_environment.web.solution_stack_name
  # SAA-C03: The solution_stack_name determines the OS + runtime platform.
  # Examples: Node.js 20, Python 3.11, Java SE, Docker.
  # Beanstalk manages OS-level security patches when Managed Platform Updates
  # are enabled - you never SSH in to patch the OS manually.
}

output "beanstalk_app_version" {
  description = "Application version label currently deployed to the environment"
  value       = aws_elastic_beanstalk_application_version.v1.name
  # SAA-C03: Application Versions are immutable deployment artifacts stored in S3.
  # Each Beanstalk deploy creates a new version. You can deploy any past version
  # to any environment - this is the rollback mechanism for Beanstalk.
  # Blue/Green rollback = swap CNAMEs; single-environment rollback = redeploy an
  # older application version (slower, takes a full deployment cycle).
}

output "beanstalk_artifact_bucket" {
  description = "S3 bucket where Elastic Beanstalk application bundles (ZIP files) are stored"
  value       = aws_s3_bucket.beanstalk_artifacts.bucket
  # All application version bundles live here. Beanstalk downloads from this
  # bucket when deploying to EC2 instances. Keep S3 versioning enabled so you
  # can access historical bundles even after a lifecycle policy cleans up
  # Beanstalk application versions.
}

output "beanstalk_ec2_instance_profile" {
  description = "IAM instance profile name attached to Beanstalk EC2 instances (used by your app code)"
  value       = aws_iam_instance_profile.beanstalk_ec2.name
  # SAA-C03 distinction:
  #   Service Role (aws_iam_role.beanstalk_service) = used BY BEANSTALK to manage
  #     infrastructure (create ELB, modify ASG, publish CloudWatch metrics).
  #   Instance Profile (aws_iam_instance_profile.beanstalk_ec2) = used BY YOUR
  #     APP CODE running on EC2 (access S3, call DynamoDB, write to SQS, etc.).
  # Always follow least privilege: only attach policies your app actually needs.
}

# === APP RUNNER OUTPUTS ===

output "apprunner_service_url" {
  description = "App Runner HTTPS endpoint URL — automatically provisioned TLS, no ACM or Route 53 setup required"
  value       = "https://${aws_apprunner_service.main.service_url}"
  # SAA-C03: App Runner provides a built-in HTTPS endpoint automatically.
  # No need to provision ACM certificates, configure ALB listeners, or create
  # Route 53 records for the default URL.
  # Custom domain: use aws_apprunner_custom_domain_association to map your own
  # domain (requires a CNAME record in your DNS pointing to the App Runner URL).
}

output "apprunner_service_arn" {
  description = "App Runner service ARN — used in IAM policies and cross-service references"
  value       = aws_apprunner_service.main.arn
  # Reference this ARN in IAM policies to grant/restrict access to the service.
  # Also used when setting up custom domains, observability, or VPC ingress.
}

output "apprunner_service_id" {
  description = "App Runner service ID (short identifier)"
  value       = aws_apprunner_service.main.service_id
}

output "apprunner_vpc_connector_arn" {
  description = "VPC Connector ARN — enables App Runner to reach private VPC resources (RDS, ElastiCache, etc.)"
  value       = aws_apprunner_vpc_connector.main.arn
  # SAA-C03: By default, App Runner runs OUTSIDE your VPC in AWS-managed infra.
  # A VPC Connector places ENIs in your VPC subnets so App Runner traffic can
  # reach private resources (RDS, ElastiCache, internal ALBs).
  # EXAM SCENARIO: "App Runner service cannot connect to private RDS instance"
  # SOLUTION: Add a VPC Connector; configure egress_type = "VPC"; update the
  # RDS security group to allow inbound from the VPC Connector's security group.
}

output "apprunner_auto_scaling_config_arn" {
  description = "Auto scaling configuration ARN — defines concurrency threshold and min/max instance counts"
  value       = aws_apprunner_auto_scaling_configuration_version.main.arn
  # SAA-C03: App Runner scales based on CONCURRENCY (requests per instance).
  # When active requests per instance > max_concurrency, App Runner scales OUT.
  # When instances are idle, App Runner scales IN (down to min_size, or 0).
  # Key difference from Beanstalk: App Runner CAN scale to zero (Beanstalk cannot).
}

output "apprunner_instance_role_arn" {
  description = "IAM role ARN for App Runner container instances (your application code's AWS permissions)"
  value       = aws_iam_role.apprunner_instance.arn
  # SAA-C03 distinction (mirrors Beanstalk):
  #   Access Role (build.apprunner.amazonaws.com) = App Runner pulling from ECR.
  #   Instance Role (tasks.apprunner.amazonaws.com) = your APPLICATION CODE calling
  #     AWS services at runtime (S3, DynamoDB, SQS, Secrets Manager, etc.).
}

###############################################################################
# SAA-C03 DEPLOYMENT STRATEGY QUICK REFERENCE
# ============================================================================
# Strategy                 Downtime  Capacity  Cost   Rollback Speed
# ----------------------   --------  --------  -----  ----------------
# All at Once              YES       Full      $      Redeploy (slow)
# Rolling                  No        Reduced   $      Redeploy (slow)
# Rolling w/ Extra Batch   No        Full      $$     Redeploy (slow)
# Immutable                No        Full      $$$    Fast (delete new ASG)
# Blue/Green (CNAME swap)  No        Full      $$$$   Instant (swap URLs back)
###############################################################################
