###############################################################################
# LAB 46 - AWS Batch & EMR (Elastic MapReduce)
# AWS SAA-C03 Exam Prep
###############################################################################
#
# ============================================================================
#                           AWS BATCH
# ============================================================================
#
# WHAT IS AWS BATCH?
# -------------------
# AWS Batch is a fully managed service for running batch computing workloads.
# "Batch" means: jobs that run for a defined duration, process a dataset,
# then exit -- as opposed to long-running services (like web servers).
# Examples: nightly ETL jobs, genomics pipelines, financial risk calculations,
#   rendering jobs, machine learning training jobs.
#
# CORE COMPONENTS (SAA-C03 must-know)
# -------------------------------------
#
# 1. COMPUTE ENVIRONMENT
#    - Defines the infrastructure pool where jobs run.
#    - MANAGED: AWS provisions, scales, and terminates EC2/Spot instances for you.
#               You specify instance type families, min/max vCPUs, and Spot %.
#               This is the most common type -- you don't manage the fleet.
#    - UNMANAGED: You provision and manage the ECS cluster yourself.
#                 Use when you need custom AMIs, GPU instances, or specialised
#                 hardware that Batch's managed mode doesn't support.
#    - Compute environments use ECS under the hood -- Batch jobs run as ECS tasks.
#
# 2. JOB QUEUE
#    - Jobs are submitted to a queue, not directly to a compute environment.
#    - Queues have a PRIORITY: higher priority queues are scheduled first.
#    - A queue can reference multiple compute environments in priority order:
#        Try Spot first (cheap) -> fall back to On-Demand if Spot unavailable.
#    - SAA-C03: "Route urgent jobs before routine jobs" = use separate queues
#      with different priorities pointing to the same compute environments.
#
# 3. JOB DEFINITION
#    - A template that describes HOW to run a job:
#        Container image (ECR, Docker Hub)
#        vCPUs and memory
#        Command to execute
#        Environment variables
#        Retry strategy (how many times to retry on failure)
#        Timeout (max job duration)
#        Job role (IAM role for the job container)
#    - Job definitions are versioned -- each update creates a new revision.
#    - SAA-C03: Think of a job definition as a "blueprint" for a Batch job.
#
# SPOT INSTANCES IN BATCH
# ------------------------
# AWS Batch is designed to work seamlessly with EC2 Spot Instances.
# Spot = spare EC2 capacity at 60-90% discount. Can be interrupted with 2-min notice.
# Batch jobs are IDEAL for Spot because:
#   - Jobs can be retried automatically on interruption (retry strategy).
#   - Long batch jobs are interruptible by nature.
# SAA-C03: "Cost-optimise batch workloads" = Spot instances in the compute env.
# SAA-C03: "Ensure batch jobs complete despite interruption" = retry strategy.
#
# ARRAY JOBS
# -----------
# Run the same job definition N times in parallel, each with a unique index.
# Example: process 1000 files -- submit one array job with array_size=1000.
#   Each child job gets AWS_BATCH_JOB_ARRAY_INDEX env var (0 to 999).
# SAA-C03: "Process large dataset in parallel" = Array jobs.
#
# MULTI-NODE PARALLEL (MNP) JOBS
# --------------------------------
# Tightly coupled HPC workloads (MPI, distributed ML training) where multiple
# nodes must communicate with each other during execution.
# Contrast with array jobs: array = embarrassingly parallel (no inter-job comms);
#   MNP = nodes communicate (HPC style).
# SAA-C03: "Run HPC/MPI workloads on AWS" = Batch MNP jobs with EFA networking.
#
# SERVICE COMPARISONS (critical for SAA-C03)
# -------------------------------------------
# Batch vs Lambda:
#   Lambda: max 15 min, 10 GB memory, no GPU, fully serverless.
#   Batch:  unlimited duration, any memory/GPU, runs in your VPC.
#   SAA-C03: "Job runs longer than 15 minutes" = Batch (not Lambda).
#   SAA-C03: "ML training job requiring GPU" = Batch (not Lambda).
#
# Batch vs Step Functions:
#   Step Functions: orchestrates workflows (state machines, retries, branching).
#   Batch:          executes compute-heavy jobs on EC2/containers.
#   They COMPLEMENT each other: Step Functions can invoke Batch jobs as a step.
#   SAA-C03: "Coordinate multiple Batch jobs with dependencies" = Step Functions.
#
# Batch vs Glue:
#   Glue: serverless managed Spark ETL, schema discovery, Data Catalog.
#   Batch: any containerised workload, custom code, non-Spark jobs.
#   SAA-C03: "Managed Spark ETL without cluster management" = Glue.
#   SAA-C03: "Custom container-based batch processing" = Batch.
#
# ============================================================================
#                      EMR (ELASTIC MAPREDUCE)
# ============================================================================
#
# WHAT IS EMR?
# -------------
# Amazon EMR is a managed Hadoop ecosystem service. It provisions and manages
# EC2-based clusters running open-source big data frameworks:
#   Spark, Hadoop MapReduce, Hive, Presto, HBase, Flink, Hudi, Iceberg, Zeppelin.
# Use EMR when you need: custom Spark code, full cluster control, large-scale
#   data processing, or integration with the Hadoop ecosystem.
#
# CLUSTER TYPES
# --------------
# Long-running cluster: stays up continuously; data scientists interactively
#   run queries via Zeppelin/JupyterHub; cluster is always warm.
#   Cost: expensive (paying for idle time between jobs).
# Transient cluster: spun up for a single job, terminated after completion.
#   Data lives in S3 (not HDFS) so it persists after cluster shutdown.
#   SAA-C03: "Cost-effective EMR" = transient clusters + S3 as primary storage.
#
# NODE TYPES (SAA-C03 MUST-KNOW)
# --------------------------------
# Master node (1 per cluster):
#   - Manages the cluster, coordinates YARN, tracks job progress.
#   - Single point of leadership -- if it fails, the cluster fails.
#   - Use On-Demand: cannot tolerate interruption.
#
# Core nodes (1 or more):
#   - Store data in HDFS AND run computation (map/reduce/Spark tasks).
#   - HDFS data is LOST if a core node is terminated unexpectedly.
#   - Use On-Demand to protect HDFS data.
#   - SAA-C03: "Core nodes store HDFS data" -> losing them = data loss.
#
# Task nodes (0 or more, optional):
#   - Run computation ONLY -- no HDFS storage.
#   - Stateless: can be added/removed at any time without data risk.
#   - IDEAL for Spot Instances: if interrupted, no data is lost.
#   - SAA-C03: "Use Spot for EMR" = Task nodes on Spot; Master+Core On-Demand.
#
# STORAGE OPTIONS
# ----------------
# HDFS: distributed across Core nodes, fast, EPHEMERAL (lost when cluster dies).
# EMRFS -> Amazon S3: durable (11 nines), persistent, enables transient clusters.
# SAA-C03: "Durable data that outlasts the cluster" = S3 (EMRFS), not HDFS.
#
# EMR vs GLUE vs REDSHIFT (critical triad for SAA-C03)
# ------------------------------------------------------
# EMR:      Custom Spark/Hadoop code, full cluster control, complex transformations.
#           "We have existing Spark code to migrate" = EMR.
# Glue:     Serverless managed PySpark ETL, auto schema discovery, Data Catalog.
#           "We want managed ETL without cluster management" = Glue.
# Redshift: Data warehouse for SQL analytics; OLAP queries on structured data.
#           "We need SQL queries and BI dashboards" = Redshift.
#
# EMR SERVERLESS
# ---------------
# No cluster to provision or manage. Submit a Spark or Hive job -> EMR Serverless
# automatically provisions workers, runs the job, releases workers.
# Pay per vCPU-second and GB-second used during job execution only.
# SAA-C03: "Run Spark jobs without managing clusters" = EMR Serverless (or Glue).
# Distinction: EMR Serverless = you bring custom Spark code; Glue = managed ETL.
#
# SECURITY
# ---------
# Kerberos: mutual authentication within the Hadoop cluster. Required for
#   multi-tenant clusters.
# Lake Formation: fine-grained table/column/row-level access control on S3 data.
# Security Configuration: bundles at-rest + in-transit encryption + auth settings.
# SAA-C03: "Encrypt EMR data at rest and in transit" = security configuration.
#
###############################################################################

# === DATA SOURCES ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# === S3 BUCKETS FOR EMR ======================================================
#
# EMR stores logs, bootstrap scripts, input data, and output results in S3.
# Using S3 as primary storage (EMRFS) is the SAA-C03 recommended pattern:
# it decouples storage from compute so you can terminate the cluster without
# losing data, then restart a new cluster against the same S3 datasets.

# EMR logs bucket: captures cluster, step, and application logs.
# Logs help diagnose failed steps. Always configure logging in production.
resource "aws_s3_bucket" "emr_logs" {
  bucket        = "${var.project_name}-emr-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-emr-logs"
    Lab     = "46"
    Purpose = "EMR cluster and step logs - required for debugging failed jobs"
  }
}

resource "aws_s3_bucket_public_access_block" "emr_logs" {
  bucket                  = aws_s3_bucket.emr_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# EMR data bucket: stores input datasets and job output results.
# Transient clusters read from here, process, write results back, then terminate.
resource "aws_s3_bucket" "emr_data" {
  bucket        = "${var.project_name}-emr-data-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-emr-data"
    Lab     = "46"
    Purpose = "EMR input data and job output results - persists after cluster termination"
  }
}

resource "aws_s3_bucket_public_access_block" "emr_data" {
  bucket                  = aws_s3_bucket.emr_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption for data bucket.
# SAA-C03: "Encrypt data at rest in S3" = SSE-S3 (AES-256) or SSE-KMS.
# SSE-KMS provides audit logs of who decrypted what via CloudTrail.
resource "aws_s3_bucket_server_side_encryption_configuration" "emr_data" {
  bucket = aws_s3_bucket.emr_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# === IAM - AWS BATCH =========================================================

# --- Batch Service Role ---
# The Batch service role allows AWS Batch itself to call EC2, ECS, and other
# AWS APIs to provision compute infrastructure and run jobs on your behalf.
# AWSBatchServiceRole is the AWS-managed policy with exactly the permissions
# Batch needs -- principle of least privilege at the service level.
resource "aws_iam_role" "batch_service" {
  name        = "${var.project_name}-batch-service-role"
  description = "IAM role assumed by the AWS Batch service to manage EC2 and ECS resources"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BatchServiceAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "batch.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-batch-service-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  role       = aws_iam_role.batch_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# --- EC2 Instance Role for Batch ---
# Batch compute environments run jobs as ECS tasks on EC2 instances.
# The EC2 instance profile gives the underlying instances permissions to:
#   - Register with ECS (so Batch can place tasks on them)
#   - Pull container images from ECR
#   - Write CloudWatch logs
#
# This is SEPARATE from the job role: the instance role is for
# the EC2 host; the job role is for the container running on that host.
resource "aws_iam_role" "batch_instance" {
  name        = "${var.project_name}-batch-instance-role"
  description = "IAM role for EC2 instances in Batch compute environment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-batch-instance-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy_attachment" "batch_instance_ecs" {
  role = aws_iam_role.batch_instance.name
  # AmazonEC2ContainerServiceforEC2Role: allows EC2 to register with ECS,
  # pull images from ECR, and report task status.
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# EC2 instances need an instance profile wrapper around the IAM role.
# An instance profile is how IAM roles are attached to EC2 instances.
# SAA-C03: EC2 -> IAM role = via instance profile; Lambda/ECS task -> IAM role = directly.
resource "aws_iam_instance_profile" "batch_instance" {
  name = "${var.project_name}-batch-instance-profile"
  role = aws_iam_role.batch_instance.name
}

# --- Batch Job Role ---
# The job role is assumed by the CONTAINER running inside the Batch job.
# Grants permissions the job code needs: read from S3, write to DynamoDB, etc.
#
# SAA-C03 distinction:
#   Instance role = host EC2 permissions (ECS, ECR, CloudWatch Logs)
#   Job role      = container application permissions (S3, DynamoDB, SQS, etc.)
resource "aws_iam_role" "batch_job" {
  name        = "${var.project_name}-batch-job-role"
  description = "IAM role assumed by Batch job containers - grants access to data sources and outputs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECSTasksAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-batch-job-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy" "batch_job_s3" {
  name = "${var.project_name}-batch-job-s3-policy"
  role = aws_iam_role.batch_job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BatchJobS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.emr_data.arn,
          "${aws_s3_bucket.emr_data.arn}/*"
        ]
      }
    ]
  })
}

# === SECURITY GROUP FOR BATCH =================================================

# Batch compute environment instances need outbound access to:
#   - Pull Docker images from ECR or Docker Hub
#   - Access S3 via VPC endpoint or NAT Gateway
#   - Report status to Batch/ECS control plane
# Inbound: not required for standard Batch jobs.
# For MNP jobs: add inbound on VPC CIDR for inter-node MPI communication.
resource "aws_security_group" "batch" {
  name        = "${var.project_name}-batch-sg"
  description = "Security group for Batch compute environment EC2 instances"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound - instances need ECR, S3, and ECS control plane access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-batch-sg"
    Lab  = "46"
  }
}

# === BATCH COMPUTE ENVIRONMENT - SPOT ========================================
#
# MANAGED Spot compute environment: AWS Batch provisions and terminates Spot
# instances automatically based on job queue demand.
#
# KEY CONFIGURATION:
#
# type = "MANAGED": AWS manages the EC2 Spot fleet lifecycle.
# compute_resources.type = "SPOT": use Spot Instances.
#
# bid_percentage: max % of On-Demand price willing to pay for Spot.
#   100% = accept any Spot price up to On-Demand. Maximises availability.
#
# instance_type = ["optimal"]: let AWS choose the best instance family.
#   Batch picks from C4, M4, R4 families based on job vCPU+memory requirements.
#
# min_vcpus = 0: scale to ZERO when no jobs are running. Pay nothing for idle.
#   SAA-C03: "Pay only when processing" = min_vcpus = 0.
#
# spot_iam_fleet_role: required for SPOT environments. Allows Batch to call
#   EC2 Spot Fleet APIs to request and manage Spot instances.

resource "aws_iam_role" "spot_fleet" {
  name        = "${var.project_name}-spot-fleet-role"
  description = "IAM role for EC2 Spot Fleet used by Batch SPOT compute environment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "spotfleet.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-spot-fleet-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy_attachment" "spot_fleet" {
  role       = aws_iam_role.spot_fleet.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

resource "aws_batch_compute_environment" "spot" {
  # NOTE: aws_batch_compute_environment uses "name", not "compute_environment_name".
  name         = "${var.project_name}-spot-env"
  service_role = aws_iam_role.batch_service.arn
  type         = "MANAGED"

  compute_resources {
    # SPOT: use Spot Instances for 60-90% cost savings.
    # Batch handles Spot interruption by marking the job failed and retrying
    # based on the job definition's retry strategy.
    type = "SPOT"

    # Accept Spot prices up to 100% of On-Demand to maximise availability.
    bid_percentage = 100

    spot_iam_fleet_role = aws_iam_role.spot_fleet.arn

    # Scale to zero when idle -- no cost for idle compute.
    min_vcpus     = 0
    max_vcpus     = 256
    desired_vcpus = 0

    # "optimal" lets Batch choose the right instance from C, M, R families.
    instance_type = ["optimal"]

    instance_role      = aws_iam_instance_profile.batch_instance.arn
    subnets            = [tolist(data.aws_subnets.default.ids)[0]]
    security_group_ids = [aws_security_group.batch.id]

    tags = {
      Name    = "${var.project_name}-spot-instance"
      Lab     = "46"
      Purpose = "Spot Batch worker instance"
    }
  }

  tags = {
    Name = "${var.project_name}-spot-env"
    Lab  = "46"
  }
}

# === BATCH COMPUTE ENVIRONMENT - ON-DEMAND ===================================
#
# On-Demand compute environment: fallback when Spot is unavailable,
# or for jobs that are time-sensitive and cannot tolerate interruption.
#
# JOB QUEUE PRIORITY PATTERN:
#   Job queue -> tries Spot compute env first (order = 1)
#             -> falls back to On-Demand env if Spot unavailable (order = 2)
# SAA-C03: "Use cheapest option with guaranteed completion" = Spot + On-Demand fallback.

resource "aws_batch_compute_environment" "on_demand" {
  name         = "${var.project_name}-ondemand-env"
  service_role = aws_iam_role.batch_service.arn
  type         = "MANAGED"

  compute_resources {
    type          = "EC2"
    min_vcpus     = 0
    max_vcpus     = 256
    desired_vcpus = 0
    instance_type = ["optimal"]
    instance_role = aws_iam_instance_profile.batch_instance.arn

    subnets            = [tolist(data.aws_subnets.default.ids)[0]]
    security_group_ids = [aws_security_group.batch.id]

    tags = {
      Name    = "${var.project_name}-ondemand-instance"
      Lab     = "46"
      Purpose = "On-Demand Batch worker - fallback when Spot is unavailable"
    }
  }

  tags = {
    Name = "${var.project_name}-ondemand-env"
    Lab  = "46"
  }
}

# === BATCH JOB QUEUE =========================================================
#
# Job queues receive job submissions and route them to compute environments.
#
# priority: higher number = higher priority scheduled first.
#   SAA-C03: Submit urgent jobs to high-priority queue; routine jobs to low-priority.
#
# compute_environment_order:
#   order = 1: try Spot first (cheapest).
#   order = 2: fall back to On-Demand if Spot capacity unavailable.

resource "aws_batch_job_queue" "main" {
  name     = "${var.project_name}-job-queue"
  state    = "ENABLED"
  priority = 10

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.spot.arn
  }

  compute_environment_order {
    order               = 2
    compute_environment = aws_batch_compute_environment.on_demand.arn
  }

  tags = {
    Name    = "${var.project_name}-job-queue"
    Lab     = "46"
    Purpose = "Primary job queue - routes to Spot first, On-Demand as fallback"
  }
}

# High-priority job queue: priority = 100 so it is scheduled before the main queue.
# Routes to On-Demand first to avoid Spot interruption risk for time-sensitive jobs.
# SAA-C03: Multiple queues with different priorities = flexible job scheduling.
resource "aws_batch_job_queue" "high_priority" {
  name     = "${var.project_name}-high-priority-queue"
  state    = "ENABLED"
  priority = 100

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.on_demand.arn
  }

  compute_environment_order {
    order               = 2
    compute_environment = aws_batch_compute_environment.spot.arn
  }

  tags = {
    Name    = "${var.project_name}-high-priority-queue"
    Lab     = "46"
    Purpose = "High-priority queue for time-sensitive jobs - On-Demand first"
  }
}

# === BATCH JOB DEFINITION ====================================================
#
# A job definition is a TEMPLATE for how to run a Batch job.
# Versioned -- each update creates a new revision.
#
# KEY FIELDS:
# type = "container": runs a Docker container (most common).
#
# container_properties:
#   image:       Docker image URI. Use ECR for private images.
#                ECR URI: <account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
#   vcpus:       vCPUs allocated. Affects job scheduling and instance selection.
#   memory:      MiB of memory. Batch uses this for instance selection.
#   job_role_arn: IAM role assumed by the CONTAINER (not the EC2 host).
#   command:     what the container executes. Ref::param references parameters.
#
# retry_strategy:
#   attempts: total tries including the first attempt.
#   evaluate_on_exit: conditional retry/fail based on exit code or status reason.
#   SAA-C03: "Ensure Spot-interrupted jobs complete" = retry_strategy attempts >= 3.
#
# timeout:
#   attempt_duration_seconds: max wall-clock time per attempt.
#   SAA-C03: "Limit maximum job runtime" = set timeout in job definition.
#   Note: Batch has NO inherent time limit (unlike Lambda's 15 min max).

resource "aws_batch_job_definition" "data_processor" {
  name = "${var.project_name}-data-processor"
  type = "container"

  container_properties = jsonencode({
    # Use a public Python image for this lab. In production: push to ECR.
    image  = "public.ecr.aws/docker/library/python:3.11-slim"
    vcpus  = 2
    memory = 4096

    # Job role: IAM role the container assumes for AWS API calls.
    # NOT the EC2 instance role -- this is the container-level identity.
    jobRoleArn = aws_iam_role.batch_job.arn

    # Command: Ref::inputKey references the job parameter defined below.
    # Override at submission: aws batch submit-job --parameters inputKey=s3://...
    command = ["python", "process.py", "--input", "Ref::inputKey", "--output", "Ref::outputKey"]

    environment = [
      {
        name  = "LOG_LEVEL"
        value = "INFO"
      },
      {
        name  = "DATA_BUCKET"
        value = aws_s3_bucket.emr_data.bucket
      }
    ]

    # Log configuration: send container stdout/stderr to CloudWatch Logs.
    # SAA-C03: "Centralised batch job logging" = awslogs driver -> CloudWatch.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/aws/batch/${var.project_name}"
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "data-processor"
      }
    }
  })

  # Retry strategy: up to 3 total attempts (2 retries after initial).
  # evaluate_on_exit: retry on Spot interruption, fail fast on app errors.
  retry_strategy {
    attempts = 3

    # Retry on Spot interruption -- host terminated by AWS, not an app bug.
    evaluate_on_exit {
      on_status_reason = "Host EC2*"
      action           = "RETRY"
    }

    # Do NOT retry on application logic errors (exit code 1).
    # Retrying on bugs wastes compute and delays failure detection.
    evaluate_on_exit {
      on_exit_code = "1"
      action       = "EXIT"
    }
  }

  # Timeout: kill the job if it runs longer than 1 hour.
  # Prevents runaway jobs from consuming unbounded compute and cost.
  timeout {
    attempt_duration_seconds = 3600
  }

  parameters = {
    inputKey  = "s3://placeholder/input/"
    outputKey = "s3://placeholder/output/"
  }

  tags = {
    Name    = "${var.project_name}-data-processor-job-def"
    Lab     = "46"
    Purpose = "Batch job definition for containerised data processing jobs"
  }
}

# === IAM - EMR ===============================================================

# --- EMR Service Role ---
# Allows the EMR service to call EC2, S3, CloudWatch, and other AWS APIs
# to provision and manage the cluster on your behalf.
resource "aws_iam_role" "emr_service" {
  name        = "${var.project_name}-emr-service-role"
  description = "IAM role assumed by EMR service to manage EC2 cluster resources"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EMRServiceAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "elasticmapreduce.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-emr-service-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy_attachment" "emr_service" {
  role       = aws_iam_role.emr_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
}

# --- EMR EC2 Instance Profile ---
# The EC2 instances in the EMR cluster assume this role. Grants:
#   - S3 read/write via EMRFS
#   - CloudWatch metrics
#   - DynamoDB (used by EMRFS consistency view in older EMR versions)
#
# In production: create a custom policy scoped to specific S3 bucket prefixes.
resource "aws_iam_role" "emr_ec2" {
  name        = "${var.project_name}-emr-ec2-role"
  description = "IAM role for EC2 instances in EMR cluster - grants S3 and CloudWatch access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-emr-ec2-role"
    Lab  = "46"
  }
}

resource "aws_iam_role_policy_attachment" "emr_ec2" {
  role       = aws_iam_role.emr_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

resource "aws_iam_instance_profile" "emr_ec2" {
  name = "${var.project_name}-emr-ec2-profile"
  role = aws_iam_role.emr_ec2.name
}

# === SECURITY GROUPS - EMR ===================================================
#
# EMR requires separate security groups for Master and Core/Task (slave) nodes.
# EMR adds its own managed rules to these SGs at cluster creation time.
#
# revoke_rules_on_delete = true: required because EMR adds cyclic SG references
# (master SG references slave SG and vice versa). Terraform cannot delete SGs
# with circular references unless this is set to true.

resource "aws_security_group" "emr_master" {
  name        = "${var.project_name}-emr-master-sg"
  description = "Security group for EMR master node"
  vpc_id      = data.aws_vpc.default.id

  # SSH to master node for interactive debugging.
  # In production: restrict to bastion host CIDR or use SSM Session Manager.
  ingress {
    description = "SSH to master node for debugging"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Allow all outbound - master needs S3, slave nodes, and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  revoke_rules_on_delete = true

  tags = {
    Name    = "${var.project_name}-emr-master-sg"
    Lab     = "46"
    Purpose = "EMR master node security group"
  }
}

resource "aws_security_group" "emr_slave" {
  name        = "${var.project_name}-emr-slave-sg"
  description = "Security group for EMR core and task nodes"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound - core/task nodes need S3 and inter-node HDFS comms"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  revoke_rules_on_delete = true

  tags = {
    Name    = "${var.project_name}-emr-slave-sg"
    Lab     = "46"
    Purpose = "EMR core and task node security group"
  }
}

# === EMR CLUSTER =============================================================
#
# aws_emr_cluster provisions a full Hadoop/Spark cluster on EC2.
#
# release_label: EMR version. emr-7.0.0 includes Spark 3.5, Hadoop 3.3, Hive 3.1.
#
# keep_job_flow_alive_when_no_steps = false: TRANSIENT cluster pattern.
#   Terminates when all steps finish. Cost-optimised -- pay only for compute time.
#   Set to true for interactive long-running clusters.
#
# termination_protection = false: allow cluster termination.
#   Set true for production long-running clusters with valuable HDFS data.
#
# Master node: always On-Demand. YARN ResourceManager, HDFS NameNode.
#   Losing master = cluster failure. Never use Spot for master.
#
# Core nodes: always On-Demand. Store HDFS data + run computation.
#   Losing core nodes unexpectedly = HDFS data loss.
#   r5.2xlarge: memory-optimised for Spark shuffle (R family = RAM optimised).
#   SAA-C03: Spark = high memory -> R or X instance families.
#
# Task nodes: created separately via aws_emr_instance_group (see below).
#   Stateless compute only -- safe for Spot.

resource "aws_emr_cluster" "main" {
  name          = "${var.project_name}-cluster"
  release_label = "emr-7.0.0"
  applications  = ["Spark", "Hadoop", "Hive"]
  service_role  = aws_iam_role.emr_service.arn

  log_uri = "s3://${aws_s3_bucket.emr_logs.bucket}/emr-logs/"

  keep_job_flow_alive_when_no_steps = false
  termination_protection            = false

  ec2_attributes {
    instance_profile                  = aws_iam_instance_profile.emr_ec2.arn
    subnet_id                         = tolist(data.aws_subnets.default.ids)[0]
    emr_managed_master_security_group = aws_security_group.emr_master.id
    emr_managed_slave_security_group  = aws_security_group.emr_slave.id
  }

  # Master node: On-Demand, m5.xlarge (4 vCPU, 16 GB RAM).
  # Never use Spot -- master interruption terminates the whole cluster.
  master_instance_group {
    instance_type = "m5.xlarge"

    ebs_config {
      size                 = 64
      type                 = "gp3"
      volumes_per_instance = 1
    }
  }

  # Core nodes: On-Demand, r5.2xlarge (8 vCPU, 64 GB).
  # Memory-optimised for Spark shuffle operations.
  # r5.2xlarge: Spark workloads are RAM-intensive.
  # SAA-C03: "Memory-intensive big data processing" -> R family instances.
  core_instance_group {
    instance_type  = "r5.2xlarge"
    instance_count = 2

    ebs_config {
      size                 = 128
      type                 = "gp3"
      volumes_per_instance = 2
    }
  }

  # Spark configuration overrides.
  # EMR allows configuration classification overrides for each application.
  configurations_json = jsonencode([
    {
      Classification = "spark-defaults"
      Properties = {
        "spark.sql.adaptive.enabled" = "true"
        "spark.hadoop.fs.s3.impl"    = "com.amazon.ws.emr.hadoop.fs.EmrFileSystem"
      }
    }
  ])

  tags = {
    Name         = "${var.project_name}-cluster"
    Lab          = "46"
    ClusterType  = "Transient"
    Purpose      = "Spark/Hadoop cluster with S3 as primary storage (EMRFS)"
    NodeStrategy = "Master+Core=OnDemand; Task=Spot-friendly"
  }

  depends_on = [
    aws_s3_bucket.emr_logs,
    aws_s3_bucket.emr_data,
    aws_iam_role_policy_attachment.emr_service,
    aws_iam_role_policy_attachment.emr_ec2
  ]
}

# === EMR INSTANCE GROUP - TASK NODES (SPOT) ==================================
#
# Task nodes: OPTIONAL compute-only nodes.
#   - Run Spark executors but store NO HDFS data.
#   - Stateless: can be added or removed at any time without data risk.
#   - IDEAL for Spot: if interrupted, tasks are redistributed to core nodes.
#
# SAA-C03: "Use Spot Instances in EMR safely" = Task nodes on Spot.
#           Master + Core must remain On-Demand.
#
# bid_price: max Spot price in USD per instance-hour.
#   Setting this near the On-Demand price maximises availability.

resource "aws_emr_instance_group" "task_spot" {
  cluster_id     = aws_emr_cluster.main.id
  name           = "${var.project_name}-task-spot"
  instance_type  = "r5.2xlarge"
  instance_count = 2

  # bid_price set = Spot Instance.
  # Remove bid_price to run task nodes On-Demand instead.
  bid_price = "0.50"

  ebs_optimized = true

  ebs_config {
    size                 = 64
    type                 = "gp3"
    volumes_per_instance = 1
  }

  # NOTE: aws_emr_instance_group does not support a tags block.
  # Tagging is handled via the parent aws_emr_cluster tags.
}

# === EMR SERVERLESS APPLICATION ===============================================
#
# EMR Serverless removes ALL cluster management. Submit a Spark or Hive job ->
# EMR Serverless automatically provisions workers, runs the job, releases them.
# Pay ONLY for vCPU-seconds and GB-seconds during job execution.
#
# EMR SERVERLESS vs GLUE (SAA-C03 key distinction):
#   EMR Serverless: you bring your own Spark/Hive application code.
#                   Full control over Spark configuration.
#                   Best for teams with existing Spark expertise.
#   AWS Glue:       AWS-managed ETL service built on Spark.
#                   Visual editor + auto-generated PySpark scripts.
#                   Best for serverless ETL without Spark expertise.
#
# EMR SERVERLESS vs EMR ON EC2:
#   EC2 cluster: custom AMIs, HDFS, Kerberos, full Hadoop ecosystem.
#   Serverless:  no cluster management, pay-per-job, supported runtimes only.
#
# initial_capacity: pre-initialize workers to reduce cold-start latency.
#   You are billed for pre-initialized workers even when idle.
#   Trade-off: latency (fast start) vs cost (idle worker billing).
#
# maximum_capacity: hard limit on total resources -- prevents cost explosions.
#
# auto_stop_configuration: stop the application after idle_timeout_minutes.
#   Prevents paying for pre-warmed capacity when no jobs are running.
#   SAA-C03: This is the EMR Serverless equivalent of EMR cluster auto-termination.

resource "aws_emrserverless_application" "spark" {
  name          = "${var.project_name}-serverless-spark"
  release_label = "emr-7.0.0"
  type          = "SPARK"

  # Pre-provision workers to eliminate cold-start latency.
  # "Driver" = Spark driver process (coordinates executors).
  initial_capacity {
    initial_capacity_type = "Driver"

    initial_capacity_config {
      worker_count = 1

      worker_configuration {
        cpu    = "2 vCPU"
        memory = "4 GB"
      }
    }
  }

  initial_capacity {
    initial_capacity_type = "Executor"

    initial_capacity_config {
      worker_count = 3

      worker_configuration {
        cpu    = "4 vCPU"
        memory = "8 GB"
        disk   = "20 GB"
      }
    }
  }

  # Hard cap to prevent runaway job costs.
  maximum_capacity {
    cpu    = "200 vCPU"
    memory = "400 GB"
    disk   = "1000 GB"
  }

  # auto_start: start application automatically when a job is submitted.
  auto_start_configuration {
    enabled = true
  }

  # auto_stop: stop application after 15 min idle. Stops idle worker billing.
  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = 15
  }

  tags = {
    Name         = "${var.project_name}-serverless-spark"
    Lab          = "46"
    Framework    = "Spark"
    ReleaseLabel = "emr-7.0.0"
    Purpose      = "EMR Serverless - no cluster management, pay-per-job execution"
  }
}
