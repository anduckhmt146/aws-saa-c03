###############################################################################
# LAB 38 - Elastic Beanstalk & AWS App Runner
# AWS SAA-C03 Exam Prep
###############################################################################
#
# ===========================================================================
# ELASTIC BEANSTALK
# ===========================================================================
#
# CORE CONCEPT: PaaS (Platform as a Service)
#   You upload application code (or a Docker image), Beanstalk handles ALL
#   infrastructure: EC2, Auto Scaling Group, Application Load Balancer,
#   CloudWatch alarms, RDS (optional), security groups, etc.
#
# SUPPORTED PLATFORMS (runtime stacks):
#   Java, .NET, Node.js, Python, Ruby, PHP, Go, Docker (single/multi-container)
#   EXAM TIP: If a question says "developer wants to deploy code without
#   managing infrastructure" -> Elastic Beanstalk is the answer.
#
# KEY COMPONENTS:
#   Application      = logical container for all environments and versions.
#   Application Version = a specific deployment artifact stored in S3.
#   Environment      = the actual running infrastructure (EC2 + ALB + ASG).
#   Environment Tier:
#     - Web Server tier   = handles HTTP/HTTPS requests. Has an ALB + ASG.
#     - Worker tier       = processes background jobs from an SQS queue.
#                          A daemon on each instance polls SQS and POSTs
#                          messages to a local HTTP endpoint (your app).
#
# DEPLOYMENT POLICIES (critical for exam):
#   All at once        = fastest, but DOWNTIME during deploy. OK for dev/test.
#   Rolling            = updates in batches. Reduced capacity during deploy.
#                        No new instances provisioned.
#   Rolling with batch = spins up a NEW batch of instances first, then rolls.
#                        Maintains full capacity. Slightly slower & costlier.
#   Immutable          = deploys to a completely NEW ASG, then swaps.
#                        Zero capacity reduction. Fastest rollback (terminate
#                        new ASG). Best for production.
#   Blue/Green         = swap ENVIRONMENT URLs (CNAME swap or Route 53 update).
#                        Two full environments run simultaneously. Instant
#                        rollback (swap URLs back). Most expensive.
#                        NOT a built-in Beanstalk feature - you do it manually
#                        or with "Swap Environment URLs" in the console.
#
# UNDER THE HOOD (what Beanstalk creates for you):
#   - EC2 instances (your chosen instance type)
#   - Auto Scaling Group with configurable min/max/desired
#   - Application Load Balancer (or Classic LB, or no LB for single-instance)
#   - CloudWatch alarms for scale-out/in
#   - Security groups (ALB SG, instance SG)
#   - S3 bucket for application versions and logs
#   - Optional: RDS database (but NOT recommended - tied to env lifecycle)
#
# EXAM TIP - RDS IN BEANSTALK:
#   If you create RDS inside the Beanstalk environment, the DB is DELETED when
#   the environment is deleted. For production, create RDS OUTSIDE Beanstalk
#   and pass the connection string as an environment variable.
#
# CONFIGURATION:
#   .ebextensions/ folder in your app bundle: YAML/JSON config files that
#   customize EC2 instances (install packages, run scripts, set env vars).
#   Platform hooks (newer): .platform/ directory for hook scripts.
#
# MONITORING:
#   Enhanced health monitoring: Beanstalk sends 1-minute metrics to
#   CloudWatch and shows health dashboard. Uses a health agent on each
#   instance. Default health checks: ELB health checks + HTTP response codes.
#
# LIFT AND SHIFT:
#   EXAM TIP: "Lift and shift existing web application to AWS with minimal
#   code changes" -> Elastic Beanstalk. Developer-focused, not infra-focused.
#
# ===========================================================================
# AWS APP RUNNER
# ===========================================================================
#
# CORE CONCEPT: Fully managed service for containerized apps and source code.
#   Even simpler than Beanstalk. You provide:
#     a) A container image from ECR or Docker Hub, OR
#     b) Source code from GitHub (App Runner builds it)
#   App Runner handles: load balancing, TLS, auto-scaling, health checks,
#   deployments, zero-downtime updates.
#
# KEY DIFFERENCES FROM BEANSTALK:
#   - No EC2 instances visible at all (fully managed compute)
#   - Auto-scales to ZERO when idle (cost optimization) and back up on demand
#   - No configuration of ALB, ASG, or launch templates needed
#   - VPC connector needed to access private resources (RDS, ElastiCache)
#
# VPC CONNECTOR:
#   By default, App Runner runs outside your VPC. To access private RDS,
#   ElastiCache, or other VPC resources, attach a VPC Connector with the
#   appropriate subnets and security groups.
#
# EXAM TIP - App Runner use case:
#   "Developer wants to deploy a Docker container to AWS with NO knowledge of
#   Kubernetes, ECS, or load balancers. Auto-scaling including scale to zero."
#   -> AWS App Runner is the answer.
#
# COMPARISON TABLE (exam cheat sheet):
#   Service          Manages             K8s?  Scale-to-0  Complexity
#   -------          --------            ----  ----------  ----------
#   App Runner       Everything          No    Yes         Lowest
#   Beanstalk        Most infra          No    No          Low
#   ECS Fargate      Cluster+tasks       No    No          Medium
#   EKS Fargate      K8s + nodes         Yes   No          High
#   EC2 + manual     Nothing             No    No          Highest
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

variable "app_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "saa-c03-lab38"
}

variable "s3_bucket_name" {
  description = "S3 bucket containing the Beanstalk application bundle"
  type        = string
  default     = "saa-c03-lab38-beanstalk-artifacts"
}

variable "app_version_key" {
  description = "S3 key for the application bundle (.zip file)"
  type        = string
  default     = "app-v1.0.zip"
}

variable "ecr_image_uri" {
  description = "Full ECR image URI for App Runner (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest)"
  type        = string
  default     = "public.ecr.aws/aws-containers/hello-app-runner:latest"
  # Using public ECR image as a placeholder for the lab.
  # In production: push your image to private ECR and reference it here.
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
# S3 BUCKET FOR BEANSTALK APPLICATION VERSIONS
# Beanstalk stores each deployment artifact (code bundle) in S3.
# The bucket must exist before creating application versions.
###############################################################################

resource "aws_s3_bucket" "beanstalk_artifacts" {
  bucket        = "${var.s3_bucket_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "beanstalk-artifacts"
    Purpose = "Elastic Beanstalk application version storage"
  }
}

resource "aws_s3_bucket_versioning" "beanstalk_artifacts" {
  bucket = aws_s3_bucket.beanstalk_artifacts.id

  versioning_configuration {
    status = "Enabled"
    # Versioning on the artifact bucket is best practice:
    # you can roll back to any previous application version.
  }
}

resource "aws_s3_bucket_public_access_block" "beanstalk_artifacts" {
  bucket                  = aws_s3_bucket.beanstalk_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload a placeholder application bundle.
# In a real workflow you would upload a .zip of your application code.
resource "aws_s3_object" "app_bundle" {
  bucket  = aws_s3_bucket.beanstalk_artifacts.id
  key     = var.app_version_key
  content = "placeholder - replace with actual application bundle"
  # In practice: use source = "path/to/app.zip" or upload via CI/CD pipeline.
  # Beanstalk application bundles for Node.js: zip of package.json + app.js
  # For Docker: zip of Dockerrun.aws.json (single-container) or docker-compose
}

###############################################################################
# ELASTIC BEANSTALK APPLICATION
# The Application is the top-level container. It holds all environments
# and application versions. Think of it as a "project" in Beanstalk.
###############################################################################

resource "aws_elastic_beanstalk_application" "app" {
  name        = "${var.app_name}-application"
  description = "SAA-C03 lab - Elastic Beanstalk demo application"

  appversion_lifecycle {
    service_role          = aws_iam_role.beanstalk_service.arn
    max_count             = 10
    delete_source_from_s3 = true
    # Automatically delete old application versions from S3 when count exceeds
    # max_count. Prevents unbounded S3 storage growth over many deployments.
    # Can also use max_age_in_days instead of max_count.
  }

  tags = {
    Name = "${var.app_name}-application"
  }
}

###############################################################################
# ELASTIC BEANSTALK APPLICATION VERSION
# A specific point-in-time deployment artifact.
# Multiple versions can exist; you choose which one runs in each environment.
# EXAM TIP: You can deploy the same version to multiple environments
# (e.g., staging and production) independently.
###############################################################################

resource "aws_elastic_beanstalk_application_version" "v1" {
  application = aws_elastic_beanstalk_application.app.name
  name        = "${var.app_name}-v1.0"
  description = "Initial application version for SAA-C03 lab"
  bucket      = aws_s3_bucket.beanstalk_artifacts.id
  key         = aws_s3_object.app_bundle.key

  tags = {
    Name    = "${var.app_name}-v1.0"
    Version = "1.0"
  }
}

###############################################################################
# IAM ROLES FOR ELASTIC BEANSTALK
# Two roles are required:
#   1. Service Role  - Beanstalk service itself (manages resources on your behalf)
#   2. Instance Profile - EC2 instances in the environment (app permissions)
###############################################################################

data "aws_iam_policy_document" "beanstalk_service_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["elasticbeanstalk.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "beanstalk_service" {
  name               = "${var.app_name}-beanstalk-service-role"
  assume_role_policy = data.aws_iam_policy_document.beanstalk_service_assume.json
  # This role lets Beanstalk call EC2, ELB, ASG, CloudWatch on your behalf.
}

resource "aws_iam_role_policy_attachment" "beanstalk_enhanced_health" {
  role       = aws_iam_role.beanstalk_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"
}

resource "aws_iam_role_policy_attachment" "beanstalk_managed_updates" {
  role       = aws_iam_role.beanstalk_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy"
}

data "aws_iam_policy_document" "beanstalk_ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "beanstalk_ec2" {
  name               = "${var.app_name}-beanstalk-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.beanstalk_ec2_assume.json
  # EC2 instances use this role. Your application code runs with these
  # permissions. Attach only what the app needs (e.g., S3 read, DynamoDB).
}

resource "aws_iam_role_policy_attachment" "beanstalk_ec2_web" {
  role       = aws_iam_role.beanstalk_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_role_policy_attachment" "beanstalk_ec2_worker" {
  role       = aws_iam_role.beanstalk_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWorkerTier"
}

resource "aws_iam_instance_profile" "beanstalk_ec2" {
  name = "${var.app_name}-beanstalk-ec2-profile"
  role = aws_iam_role.beanstalk_ec2.name
  # Instance profiles wrap IAM roles for EC2 use. Beanstalk references the
  # profile name in the aws:autoscaling:launchconfiguration namespace.
}

###############################################################################
# ELASTIC BEANSTALK ENVIRONMENT (WEB SERVER TIER)
# The environment is the running infrastructure. Key settings controlled via
# option_settings (maps to .ebextensions configuration namespaces).
###############################################################################

resource "aws_elastic_beanstalk_environment" "web" {
  name                = "${var.app_name}-web-env"
  application         = aws_elastic_beanstalk_application.app.name
  solution_stack_name = "64bit Amazon Linux 2023 v6.1.0 running Node.js 20"
  # solution_stack_name specifies the PLATFORM (OS + runtime).
  # EXAM TIP: Beanstalk platforms are regularly updated by AWS. Use the
  # latest managed platform to get OS security patches automatically.
  # Available stacks: Node.js, Python, Java SE, Java Tomcat, PHP, Ruby,
  # .NET Core on Linux, .NET on Windows Server, Docker, Go.

  version_label = aws_elastic_beanstalk_application_version.v1.name
  tier          = "WebServer"
  # Tier = "WebServer" -> provisions ALB + EC2 + ASG, handles HTTP traffic.
  # Tier = "Worker"    -> no ALB, polls SQS queue, invokes local HTTP server.

  # --------------------------------------------------------------------------
  # ENVIRONMENT TIER CONFIGURATION
  # --------------------------------------------------------------------------

  # EC2 instance configuration
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = "t3.micro"
    # t3.micro = free tier eligible, 2 vCPU, 1 GB RAM. Suitable for demos.
    # For production, at least t3.small. Use t3.medium+ for JVM languages.
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.beanstalk_ec2.name
    # Required: specifies which IAM instance profile EC2 nodes use.
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "DisableIMDSv1"
    value     = "true"
    # Force IMDSv2 (session-oriented) on all instances.
    # EXAM TIP: IMDSv2 mitigates SSRF attacks targeting metadata endpoint.
  }

  # Auto Scaling configuration
  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MinSize"
    value     = "1"
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MaxSize"
    value     = "4"
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "Availability Zones"
    value     = "Any 2"
    # Spread instances across at least 2 AZs for high availability.
  }

  # Load Balancer configuration
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "LoadBalancerType"
    value     = "application"
    # Options: "application" (ALB), "network" (NLB), "classic" (deprecated).
    # EXAM TIP: Use ALB for path-based routing, host-based routing, WAF
    # integration, and WebSocket support.
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = aws_iam_role.beanstalk_service.arn
  }

  # DEPLOYMENT POLICY CONFIGURATION
  # Rolling deployment: update instances in batches, maintaining availability
  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = "Rolling"
    # EXAM TIP - Deployment policies:
    # AllAtOnce        = fastest, causes downtime, for dev/test only
    # Rolling          = no new instances, one batch at a time, reduced capacity
    # RollingWithBatch = new batch first, maintains full capacity, extra cost
    # Immutable        = new ASG with all new instances, best for production,
    #                    fastest rollback (just terminate new ASG)
    # TrafficSplitting = canary deployments (split % traffic to new version)
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSize"
    value     = "30"
    # With Rolling policy: update 30% of instances per batch.
    # Type can be "Percentage" (default) or "Fixed" (number of instances).
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSizeType"
    value     = "Percentage"
  }

  # Health check and monitoring
  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = "enhanced"
    # Enhanced health monitoring: 1-minute CloudWatch metrics, health daemon
    # on each instance, detailed HTTP response code tracking, root cause
    # identification. Basic health = just ELB health checks (less detail).
  }

  # Application environment variables
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "NODE_ENV"
    value     = "production"
    # Environment variables are passed to the application process.
    # EXAM TIP: Use these for non-secret config. For secrets (DB passwords,
    # API keys), use SSM Parameter Store or Secrets Manager and fetch at
    # runtime. Do NOT hardcode secrets in option_settings.
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "PORT"
    value     = "8080"
  }

  # Logs: stream to CloudWatch
  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
    name      = "StreamLogs"
    value     = "true"
    # Streams /var/log/web.stdout.log and app logs to CloudWatch Logs.
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
    name      = "RetentionInDays"
    value     = "7"
  }

  tags = {
    Name        = "${var.app_name}-web-env"
    Environment = "lab"
  }
}

###############################################################################
# VPC FOR APP RUNNER VPC CONNECTOR
###############################################################################

resource "aws_vpc" "apprunner" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.app_name}-apprunner-vpc"
  }
}

resource "aws_subnet" "apprunner_private" {
  count             = 2
  vpc_id            = aws_vpc.apprunner.id
  cidr_block        = "10.1.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.app_name}-apprunner-private-${count.index + 1}"
  }
}

resource "aws_security_group" "apprunner_connector" {
  name        = "${var.app_name}-apprunner-connector-sg"
  description = "Security group for App Runner VPC connector"
  vpc_id      = aws_vpc.apprunner.id

  egress {
    description = "Allow App Runner to reach private VPC resources"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.1.0.0/16"]
    # Only allow egress to VPC CIDR, not the internet.
    # App Runner already has internet access via its managed network.
  }

  tags = {
    Name = "${var.app_name}-apprunner-connector-sg"
  }
}

###############################################################################
# APP RUNNER VPC CONNECTOR
# By default, App Runner runs in AWS-managed infrastructure outside your VPC.
# A VPC Connector provides an outbound path from App Runner INTO your VPC,
# allowing the app to reach private RDS, ElastiCache, or other VPC resources.
#
# EXAM TIP: VPC Connector = App Runner -> your VPC (outbound only).
# Your VPC resources (RDS) must allow inbound traffic from the connector SG.
###############################################################################

resource "aws_apprunner_vpc_connector" "main" {
  vpc_connector_name = "${var.app_name}-vpc-connector"
  subnets            = aws_subnet.apprunner_private[*].id
  security_groups    = [aws_security_group.apprunner_connector.id]
  # Subnets and security groups determine where the connector places ENIs
  # in your VPC. Traffic from App Runner enters your VPC through these ENIs.

  tags = {
    Name = "${var.app_name}-vpc-connector"
  }
}

###############################################################################
# IAM ROLE FOR APP RUNNER
# App Runner needs this role to pull images from ECR.
###############################################################################

data "aws_iam_policy_document" "apprunner_access_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["build.apprunner.amazonaws.com"]
    }
    # build.apprunner.amazonaws.com = used during image pull / source build.
    # tasks.apprunner.amazonaws.com = used at runtime (for AWS API calls).
  }
}

resource "aws_iam_role" "apprunner_access" {
  name               = "${var.app_name}-apprunner-access-role"
  assume_role_policy = data.aws_iam_policy_document.apprunner_access_assume.json
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr_access" {
  role       = aws_iam_role.apprunner_access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
  # Grants App Runner permission to pull images from ECR (private repos).
  # Not needed when using public ECR images.
}

###############################################################################
# APP RUNNER SERVICE
# The core App Runner resource. Define the source (image or code),
# compute configuration, and network settings.
###############################################################################

resource "aws_apprunner_service" "main" {
  service_name = "${var.app_name}-apprunner-service"

  source_configuration {
    image_repository {
      image_configuration {
        port = "8080"
        # App Runner routes incoming traffic to port 8080 inside the container.
        # Your app must listen on this port.

        runtime_environment_variables = {
          APP_ENV   = "production"
          LOG_LEVEL = "info"
        }
        # Environment variables injected into the container at runtime.
        # For secrets: use runtime_environment_secrets and reference
        # SSM Parameter Store or Secrets Manager ARNs.
      }

      image_identifier      = var.ecr_image_uri
      image_repository_type = "ECR_PUBLIC"
      # image_repository_type options:
      #   ECR        = private ECR repository (requires access_role_arn)
      #   ECR_PUBLIC = public ECR gallery (no access role needed)
      # EXAM TIP: For private ECR, always set access_role_arn with the
      # AWSAppRunnerServicePolicyForECRAccess policy attached.
    }

    auto_deployments_enabled = true
    # When true: App Runner monitors the ECR image tag and automatically
    # redeploys when a new image is pushed to that tag.
    # Useful for CI/CD: push to ECR -> App Runner auto-deploys.
    # EXAM TIP: Combined with CodePipeline -> CodeBuild -> ECR -> App Runner
    # creates a fully managed CI/CD pipeline with zero infrastructure.
  }

  instance_configuration {
    cpu    = "1024"
    memory = "2048"
    # CPU in milli-vCPU: 256 (0.25 vCPU), 512, 1024 (1 vCPU), 2048, 4096
    # Memory in MiB: must be compatible with CPU setting.
    # 1024 CPU / 2048 memory = 1 vCPU, 2 GB RAM.
    # EXAM TIP: App Runner charges per vCPU-second and GB-second of active use.
    # When scaled to zero, you only pay for provisioned concurrency (if any).

    instance_role_arn = aws_iam_role.apprunner_instance.arn
    # The instance role grants your APPLICATION code permission to call AWS APIs
    # (e.g., read from S3, write to DynamoDB). Different from the access role
    # (which is just for ECR image pull).
  }

  health_check_configuration {
    healthy_threshold   = 1
    interval            = 10
    path                = "/health"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 5
    # App Runner performs HTTP health checks. Your app must return 2xx on /health.
    # If health checks fail, App Runner rolls back the deployment automatically.
  }

  auto_scaling_configuration_arn = aws_apprunner_auto_scaling_configuration_version.main.arn

  network_configuration {
    egress_configuration {
      egress_type       = "VPC"
      vpc_connector_arn = aws_apprunner_vpc_connector.main.arn
      # Route outbound traffic through the VPC connector (to reach private DB).
      # egress_type = "DEFAULT" routes outbound through App Runner's internet.
    }

    ingress_configuration {
      is_publicly_accessible = true
      # true = anyone on the internet can reach the App Runner service URL.
      # false = only accessible from within the VPC (private services).
    }
  }

  tags = {
    Name = "${var.app_name}-apprunner-service"
  }

  depends_on = [
    aws_iam_role_policy_attachment.apprunner_ecr_access
  ]
}

###############################################################################
# APP RUNNER AUTO SCALING CONFIGURATION
# Controls how App Runner scales the number of container instances.
###############################################################################

resource "aws_apprunner_auto_scaling_configuration_version" "main" {
  auto_scaling_configuration_name = "${var.app_name}-autoscaling"

  min_size        = 0
  max_size        = 10
  max_concurrency = 100
  # min_size = 0: scale to zero when no traffic. Cold start latency ~1-5 seconds.
  # max_concurrency: number of concurrent requests per instance before scaling out.
  # EXAM TIP: Lower max_concurrency = scales out earlier (more instances, lower
  # latency). Higher max_concurrency = packs more requests per instance (cheaper).

  tags = {
    Name = "${var.app_name}-autoscaling"
  }
}

###############################################################################
# IAM ROLE FOR APP RUNNER INSTANCE (application runtime permissions)
###############################################################################

data "aws_iam_policy_document" "apprunner_instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_instance" {
  name               = "${var.app_name}-apprunner-instance-role"
  assume_role_policy = data.aws_iam_policy_document.apprunner_instance_assume.json
  # Your application code assumes this role at runtime.
  # Attach policies for whatever AWS services your app uses.
}

resource "aws_iam_role_policy" "apprunner_instance_s3" {
  name = "${var.app_name}-apprunner-s3-access"
  role = aws_iam_role.apprunner_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.beanstalk_artifacts.arn}/*"
        # Example: allow the App Runner service to read/write to S3.
        # In production, create a dedicated bucket and restrict to it.
      }
    ]
  })
}

###############################################################################
# NOTE: All outputs are defined in outputs.tf (see that file for descriptions
# and SAA-C03 exam notes on each output value).
###############################################################################

###############################################################################
# SAA-C03 EXAM CHEATSHEET - BEANSTALK & APP RUNNER
# ============================================================================
# Q: What does Elastic Beanstalk NOT manage?
# A: Your application code logic. It manages ALL infrastructure. You control
#    code; AWS controls servers, networking, scaling, OS patches.
#
# Q: What deployment policy has zero downtime AND fastest rollback?
# A: Immutable deployment. New instances in a separate ASG. Rollback = delete
#    new ASG. No existing instances are touched until health checks pass.
#
# Q: What is the Worker tier used for?
# A: Background job processing. Pulls tasks from SQS, POSTs to localhost.
#    Use it when your web tier needs to offload long-running async tasks.
#
# Q: Beanstalk vs App Runner?
# A: Beanstalk = more control (choose instance type, deployment policy, VPC).
#    App Runner = zero infrastructure decisions; simplest possible deployment.
#    App Runner scales to 0; Beanstalk does not (min 1 instance always running).
#
# Q: When would you choose App Runner?
# A: Containerized microservice, no ops team, need HTTPS out of the box,
#    variable/spiky traffic (benefits from scale-to-zero), no K8s/ECS needed.
#
# Q: How does App Runner access a private RDS database?
# A: VPC Connector - attaches App Runner egress to subnets in your VPC.
#    RDS security group must allow inbound from the VPC connector SG.
###############################################################################
