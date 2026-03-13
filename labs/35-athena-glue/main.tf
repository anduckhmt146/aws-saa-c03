# =============================================================================
# Lab 35: Amazon Athena + AWS Glue + Lake Formation
# AWS SAA-C03 Exam Prep
# =============================================================================
#
# CORE CONCEPT — SERVERLESS DATA LAKE PATTERN
# ─────────────────────────────────────────────
# S3 (raw data) → Glue Crawler (auto-discover schema)
#              → Glue Data Catalog (central metadata store)
#              → Athena (ad-hoc SQL queries)
#              → Redshift Spectrum (run warehouse queries on S3)
#              → EMR (big data processing)
#
# SAA-C03 EXAM KEY FACTS — ATHENA
# ─────────────────────────────────
# - Serverless: no infrastructure to manage, no clusters to spin up
# - Query data directly in S3 using standard SQL (Presto/Trino engine)
# - Pricing: $5 per TB of data scanned (only pay for what you query)
# - COST REDUCTION STRATEGIES (exam favorite):
#     1. Columnar formats  → Parquet or ORC (only read relevant columns)
#     2. Compression       → gzip, Snappy, ZSTD (less data to scan)
#     3. Partitioning      → e.g., s3://bucket/year=2024/month=01/ (skip partitions)
#     All three combined can reduce costs by 30–90%
# - Query results are stored in a separate S3 location
# - Federated Queries: connect to DynamoDB, RDS, Redshift, CloudWatch Logs,
#   etc. via Lambda-based data source connectors
# - Athena for Apache Spark: run Spark notebooks without clusters
# - NOT for: OLTP workloads, frequent small queries (cost), row-level updates
#
# SAA-C03 EXAM KEY FACTS — AWS GLUE
# ────────────────────────────────────
# - Fully managed, serverless ETL service (no servers to manage)
# - DATA CATALOG: central metadata repository
#     → Integrates natively with Athena, Redshift Spectrum, EMR, Lake Formation
#     → Replaces Apache Hive Metastore
#     → Tables = schemas pointing to S3 locations (not the data itself)
# - CRAWLERS: auto-discover and catalog data from S3, RDS, DynamoDB, JDBC
#     → Infer schema, detect new partitions, update catalog automatically
#     → Run on schedule or on-demand
# - JOBS: Spark ETL jobs (Scala or Python), Python shell scripts
#     → DPU (Data Processing Unit) = compute unit for Glue jobs
#     → Auto-scaling available
# - TRIGGERS: start jobs on schedule (cron), on-demand, or on job completion
# - GLUE DATABREW: visual, no-code data preparation and transformation
#     → Target audience: data analysts who don't write code
# - GLUE STUDIO: visual ETL job builder (drag-and-drop)
#
# SAA-C03 EXAM KEY FACTS — LAKE FORMATION
# ─────────────────────────────────────────
# - Service to build, secure, and manage a data lake on S3
# - Built ON TOP of Glue Data Catalog — adds security layer
# - FINE-GRAINED ACCESS CONTROL:
#     → Column-level security: restrict specific columns
#     → Row-level security: filter rows based on user/role
#     → Cell-level security (combination of both)
# - Grant/revoke permissions using IAM-style grants
# - Cross-account data sharing
# - Blueprint templates for ingesting data into the lake
#
# SAA-C03 SCENARIO → ANSWER PATTERN
# ────────────────────────────────────
# "Analyze log files stored in S3 without provisioning servers" → Athena
# "Auto-catalog new data arriving in S3"                        → Glue Crawler
# "Reduce Athena query costs on large datasets"                 → Parquet + partitioning
# "Real-time logs → queryable data lake"                        → Kinesis Firehose → S3 → Glue → Athena
# "Column-level access control on data lake"                    → Lake Formation
# "Visual data prep, no code"                                   → Glue DataBrew
# "Central metadata for Athena + Redshift Spectrum + EMR"       → Glue Data Catalog
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# LOCAL VALUES
# =============================================================================

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "saa-lab35"

  # Common tags applied to all resources
  common_tags = {
    Lab  = "35-athena-glue"
    Exam = "SAA-C03"
  }
}

# =============================================================================
# S3 — DATA LAKE BUCKET
# =============================================================================
#
# SAA-C03: S3 is the foundation of every AWS data lake.
# Raw data lands here; Glue crawlers discover the schema;
# Athena queries the data in-place without copying it.
#
# Partitioning convention:  s3://bucket/dataset/year=YYYY/month=MM/day=DD/
# Using Hive-style partitions lets Athena skip entire date ranges,
# dramatically reducing bytes scanned and cost.

resource "aws_s3_bucket" "data_lake" {
  bucket        = "${local.name_prefix}-data-lake-${local.account_id}"
  force_destroy = true

  tags = {
    Purpose = "Data lake — raw + processed data for Athena queries"
    Note    = "SAA-C03: S3 is the storage layer; Athena queries in-place"
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Athena query results bucket
# SAA-C03: Athena always writes results to a separate S3 location.
# You can enforce this per-workgroup to control costs and access.

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${local.name_prefix}-athena-results-${local.account_id}"
  force_destroy = true

  tags = {
    Purpose = "Athena query result output location"
    Note    = "SAA-C03: Every Athena query writes output here; encrypted at rest"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Glue scripts bucket — stores Python ETL scripts for Glue Jobs
resource "aws_s3_bucket" "glue_scripts" {
  bucket        = "${local.name_prefix}-glue-scripts-${local.account_id}"
  force_destroy = true

  tags = {
    Purpose = "Stores Glue ETL job scripts"
  }
}

resource "aws_s3_bucket_public_access_block" "glue_scripts" {
  bucket = aws_s3_bucket.glue_scripts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload a sample Glue Python shell script
# SAA-C03: Glue Python shell jobs are for lightweight ETL (pandas, boto3).
# For heavy Spark jobs, use Glue ETL (Spark) job type instead.

resource "aws_s3_object" "glue_etl_script" {
  bucket = aws_s3_bucket.glue_scripts.id
  key    = "scripts/convert_to_parquet.py"

  # Inline script: reads CSV from S3, converts to Parquet, writes back.
  # In production this would be a real file reference.
  content = <<-PYTHON
    import sys
    import boto3

    # SAA-C03: Parquet is columnar — Athena reads only queried columns.
    # This reduces bytes scanned and thus reduces cost ($5/TB scanned).
    # Combined with Snappy compression, can cut scan costs by 70-90%.

    def main():
        print("Converting CSV to Parquet for Athena cost optimization")
        print("Columnar format: Athena reads only selected columns")
        print("Compression: reduces bytes scanned -> lower cost")
        print("Partitioning: Athena skips entire date partitions")

    if __name__ == "__main__":
        main()
  PYTHON

  tags = {
    Note = "In production, reference local file with source attribute"
  }
}

# =============================================================================
# IAM — GLUE SERVICE ROLE
# =============================================================================
#
# SAA-C03: Glue needs permissions to:
# 1. Read source data (S3, RDS, DynamoDB)
# 2. Write to Glue Data Catalog
# 3. Write processed output back to S3
# AWS provides AWSGlueServiceRole managed policy as the baseline.

resource "aws_iam_role" "glue_role" {
  name = "${local.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Note = "SAA-C03: Glue service role needs S3 + Catalog permissions"
  }
}

# AWS managed policy for Glue — covers CloudWatch Logs, Glue API, and basic S3
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Additional S3 policy scoped to the data lake and scripts buckets
resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${local.name_prefix}-glue-s3-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SAA-C03: Principle of least privilege — scope to specific buckets only
        Sid    = "DataLakeAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*",
          aws_s3_bucket.glue_scripts.arn,
          "${aws_s3_bucket.glue_scripts.arn}/*",
          aws_s3_bucket.athena_results.arn,
          "${aws_s3_bucket.athena_results.arn}/*"
        ]
      }
    ]
  })
}

# =============================================================================
# IAM — LAKE FORMATION ADMIN ROLE
# =============================================================================
#
# SAA-C03: Lake Formation adds a permissions layer on top of IAM.
# Users/roles need BOTH IAM permissions AND Lake Formation grants
# to access data. This enables column/row-level security.

resource "aws_iam_role" "lakeformation_admin" {
  name = "${local.name_prefix}-lakeformation-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lakeformation.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Note = "SAA-C03: Lake Formation admin manages fine-grained data permissions"
  }
}

resource "aws_iam_role_policy_attachment" "lakeformation_admin" {
  role       = aws_iam_role.lakeformation_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLakeFormationDataAdmin"
}

# =============================================================================
# GLUE DATA CATALOG — DATABASE
# =============================================================================
#
# SAA-C03: The Glue Data Catalog is the central metadata repository for AWS.
# Think of it as Apache Hive Metastore — it stores table definitions
# (column names, data types, S3 locations, partition info) but NOT the data.
#
# Single catalog per AWS account per region.
# Shared automatically with: Athena, Redshift Spectrum, EMR, Lake Formation.
# This is the "schema on read" pattern — data stays in S3, schema lives here.

resource "aws_glue_catalog_database" "main" {
  name        = "${local.name_prefix}_catalog_db"
  description = "Central metadata catalog for the SAA-C03 lab data lake"

  # Optional: set a default S3 location for tables in this database
  # location_uri = "s3://${aws_s3_bucket.data_lake.bucket}/catalog/"

  tags = {
    Note = "SAA-C03: Glue Catalog = shared metadata for Athena + Redshift Spectrum + EMR"
  }
}

# =============================================================================
# GLUE CRAWLER — AUTO-DISCOVER SCHEMA FROM S3
# =============================================================================
#
# SAA-C03: Crawlers are a key exam topic.
# - A crawler connects to a data source (S3, RDS, DynamoDB, JDBC)
# - It samples the data and infers the schema automatically
# - It creates/updates table definitions in the Glue Data Catalog
# - Detects new partitions (e.g., new year=2024/month=02/ prefixes)
# - Can be run on-demand or on a schedule
#
# EXAM SCENARIO: "New CSV files land in S3 daily and analysts want to
# query them with Athena the next morning."
# ANSWER: Schedule a Glue Crawler to run nightly → updates Catalog → Athena sees new data

resource "aws_glue_crawler" "s3_data_lake" {
  name          = "${local.name_prefix}-s3-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.main.name
  description   = "Crawls S3 data lake to auto-discover and catalog schemas"

  # S3 target: specify which S3 paths to crawl
  # The crawler will sample files, infer schema, detect Hive-style partitions
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/raw/"

    # Optional: exclude paths from crawling (e.g., archive or temp folders)
    exclusions = [
      "archive/**",
      "*.tmp"
    ]
  }

  # Recrawl policy: CRAWL_EVERYTHING re-crawls all files on each run.
  # CRAWL_NEW_FOLDERS_ONLY only processes new S3 prefixes (cheaper for large lakes).
  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }

  # Schema change policy: what to do when schema changes are detected
  # UPDATE_IN_DATABASE: update existing catalog table with new schema
  # LOG: only log the change, do not update
  # DEPRECATE_IN_DATABASE: mark old tables as deprecated
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  # Cron schedule: run daily at 2 AM UTC
  # SAA-C03: Triggers run crawlers on a schedule — data lands by midnight,
  # crawler runs at 2 AM, Athena sees fresh data by morning
  schedule = "cron(0 2 * * ? *)"

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      # Tables: groupFiles=InPartition creates one table per Hive partition prefix
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
    Grouping = {
      # TableGroupingPolicy: CombineCompatibleSchemas merges similar files into one table
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = {
    Note = "SAA-C03: Crawler auto-discovers schema → Data Catalog → Athena can query immediately"
  }
}

# Second crawler targeting the processed/parquet data
# SAA-C03: Best practice is separate raw and processed zones in the data lake.
# Raw = original format (CSV, JSON). Processed = optimized (Parquet + partitioned).

resource "aws_glue_crawler" "processed_data" {
  name          = "${local.name_prefix}-processed-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.main.name
  description   = "Crawls processed Parquet data for optimized Athena queries"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/processed/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "DEPRECATE_IN_DATABASE"
  }

  # Run after the ETL job completes (triggered separately via aws_glue_trigger)
  # No schedule here — will be triggered by a job completion trigger

  tags = {
    Note = "SAA-C03: Processed zone uses Parquet — columnar + compressed = lower Athena cost"
  }
}

# =============================================================================
# GLUE JOB — ETL: CSV → PARQUET CONVERSION
# =============================================================================
#
# SAA-C03: Glue Jobs are Spark (or Python shell) programs that transform data.
# DPU = Data Processing Unit (4 vCPU, 16 GB RAM). You pay per DPU-hour.
# max_capacity: fractional DPUs allowed for Python shell (0.0625 = 1/16 DPU)
# For Spark jobs: minimum 2 DPUs, can auto-scale.
#
# Job types:
# - glueetl       → Apache Spark (PySpark or Scala Spark)
# - pythonshell   → Python 3.9 script (no Spark, for lightweight transforms)
# - gluestreaming → Continuous Spark Streaming

resource "aws_glue_job" "csv_to_parquet" {
  name         = "${local.name_prefix}-csv-to-parquet"
  role_arn     = aws_iam_role.glue_role.arn
  description  = "Converts raw CSV files to Parquet format for Athena cost optimization"
  glue_version = "4.0"

  command {
    name            = "pythonshell"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/scripts/convert_to_parquet.py"
    python_version  = "3.9"
  }

  default_arguments = {
    # Standard Glue arguments
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"

    # Custom arguments accessible in the script via sys.argv or getResolvedOptions
    "--input_path"  = "s3://${aws_s3_bucket.data_lake.bucket}/raw/"
    "--output_path" = "s3://${aws_s3_bucket.data_lake.bucket}/processed/"

    # SAA-C03: Enabling job bookmarks prevents reprocessing already-processed files.
    # Critical for incremental ETL — only process new data since last run.
    "--job-bookmark-option" = "job-bookmark-enable"
  }

  # Python shell jobs use max_capacity (not number_of_workers + worker_type)
  max_capacity = 0.0625 # 1/16 DPU — minimum for Python shell jobs

  # Retry on failure (up to 3 attempts)
  # SAA-C03: For retries in complex pipelines, Step Functions is preferred
  max_retries = 2

  # Timeout in minutes (default 2880 = 48 hours, keep low to avoid runaway costs)
  timeout = 60

  tags = {
    Note = "SAA-C03: Glue Job converts CSV→Parquet to reduce Athena scan cost by up to 90%"
  }
}

# =============================================================================
# GLUE TRIGGER — SCHEDULE AND EVENT-BASED EXECUTION
# =============================================================================
#
# SAA-C03: Triggers control when Glue jobs and crawlers run.
# Types:
# - SCHEDULED  : cron expression, time-based
# - ON_DEMAND  : manual trigger only
# - CONDITIONAL: starts when previous job/crawler succeeds/fails/completes
#
# EXAM PATTERN: Use conditional triggers to chain jobs:
#   Crawler finishes → ETL job starts → second crawler runs → Athena sees fresh data

# Scheduled trigger: run the ETL job every day at midnight
resource "aws_glue_trigger" "nightly_etl" {
  name        = "${local.name_prefix}-nightly-etl"
  type        = "SCHEDULED"
  description = "Runs CSV-to-Parquet ETL job nightly at midnight UTC"
  schedule    = "cron(0 0 * * ? *)"

  actions {
    job_name = aws_glue_job.csv_to_parquet.name
    # Optional: override default arguments for this trigger
    arguments = {
      "--trigger-name" = "nightly-scheduled"
    }
  }

  tags = {
    Note = "SAA-C03: SCHEDULED trigger runs ETL on a cron; CONDITIONAL chains jobs together"
  }
}

# Conditional trigger: after the ETL job succeeds, run the processed-data crawler
# This ensures the Glue Catalog is always up-to-date after new data is processed.

resource "aws_glue_trigger" "post_etl_crawler" {
  name        = "${local.name_prefix}-post-etl-crawler"
  type        = "CONDITIONAL"
  description = "Runs processed-data crawler after ETL job completes successfully"

  # Predicate defines conditions that must be met to fire the trigger
  predicate {
    # LOGICAL: AND (all conditions must be true) or ANY (at least one)
    logical = "AND"

    conditions {
      job_name = aws_glue_job.csv_to_parquet.name
      state    = "SUCCEEDED"
      # SAA-C03: SUCCEEDED fires only on success.
      # You can also trigger on FAILED to send alerts or run cleanup jobs.
    }
  }

  actions {
    crawler_name = aws_glue_crawler.processed_data.name
  }

  tags = {
    Note = "SAA-C03: Conditional trigger chains ETL Job → Crawler for automated pipeline"
  }
}

# =============================================================================
# ATHENA WORKGROUP
# =============================================================================
#
# SAA-C03: Workgroups allow you to:
# 1. SEPARATE query history and results by team/project (billing isolation)
# 2. ENFORCE per-query data scan limits (prevent runaway cost)
# 3. ENFORCE result encryption requirements
# 4. ALLOCATE costs using tags
#
# Use case: separate workgroups for data-science, finance, and ops teams.
# Each workgroup gets its own S3 results location and query history.
#
# EXAM TIP: "How do you prevent analysts from accidentally scanning terabytes?"
# ANSWER: Set bytes_scanned_cutoff_per_query in the workgroup configuration.

resource "aws_athena_workgroup" "main" {
  name        = "${local.name_prefix}-workgroup"
  description = "Primary workgroup for SAA-C03 lab Athena queries"

  configuration {
    # Enforce that all queries in this workgroup use these settings
    # (individual users cannot override)
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # Result configuration: where query output is stored in S3
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"

      # SAA-C03: Encrypt query results at rest using SSE-S3
      # Options: SSE_S3 (default), SSE_KMS (for compliance), CSE_KMS (client-side)
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Cost control: cancel queries that would scan more than this many bytes
    # 1 GB limit prevents accidental full-table scans during development
    # SAA-C03: This is the key cost-control mechanism for Athena
    bytes_scanned_cutoff_per_query = 1073741824 # 1 GB in bytes
  }

  tags = {
    Note = "SAA-C03: Workgroups isolate costs/history and enforce scan limits per team"
  }
}

# Secondary workgroup for high-priority production queries (no scan limit)
resource "aws_athena_workgroup" "production" {
  name        = "${local.name_prefix}-production"
  description = "Production workgroup — no scan limit, separate billing"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/production-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
    # No bytes_scanned_cutoff_per_query — production queries must complete
  }

  tags = {
    Note = "SAA-C03: Separate workgroups = separate cost allocation tags in billing"
  }
}

# =============================================================================
# ATHENA DATABASE
# =============================================================================
#
# SAA-C03: An Athena database is a logical grouping of tables.
# It maps directly to a database in the Glue Data Catalog.
# When you create an Athena database, it creates the corresponding
# Glue Catalog database (and vice versa — they are the same entity).
#
# Tables within this database point to S3 locations.
# Data is NEVER moved or copied — Athena queries it in-place.

resource "aws_athena_database" "main" {
  name   = "${local.name_prefix}_athena_db"
  bucket = aws_s3_bucket.athena_results.bucket

  # Force destroy drops all tables in the database on terraform destroy
  force_destroy = true

  # Optional: encryption for the database itself
  encryption_configuration {
    encryption_option = "SSE_S3"
  }

  # SAA-C03: Athena DB = Glue Catalog DB — same metadata store, unified view.
  # aws_athena_database does not support a tags argument.
}

# =============================================================================
# LAKE FORMATION — REGISTER S3 LOCATION
# =============================================================================
#
# SAA-C03: To use Lake Formation security features, you must first register
# your S3 data lake location with Lake Formation.
# After registration:
# - Lake Formation controls access to data at the column/row level
# - IAM permissions alone are NOT sufficient — Lake Formation grants required too
# - This is the "double-gating" security model
#
# EXAM SCENARIO: "Restrict analysts to only see specific columns in a table"
# ANSWER: Use Lake Formation column-level permissions (not just IAM S3 policies)

resource "aws_lakeformation_resource" "data_lake" {
  arn = aws_s3_bucket.data_lake.arn

  # Optional: specify a role for Lake Formation to use when accessing the bucket.
  # If omitted, Lake Formation uses the AWSServiceRoleForLakeFormationDataAccess
  # service-linked role automatically.
  # role_arn = aws_iam_role.lakeformation_admin.arn

  # SAA-C03: Registering S3 with Lake Formation enables column/row-level security.
  # aws_lakeformation_resource does not support a tags argument.
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "data_lake_bucket_name" {
  description = "S3 data lake bucket name — raw and processed data lives here"
  value       = aws_s3_bucket.data_lake.bucket
}

output "athena_results_bucket_name" {
  description = "S3 bucket for Athena query result output files"
  value       = aws_s3_bucket.athena_results.bucket
}

output "glue_catalog_database_name" {
  description = "Glue Data Catalog database — shared with Athena, Redshift Spectrum, EMR"
  value       = aws_glue_catalog_database.main.name
}

output "glue_crawler_name" {
  description = "Glue Crawler that auto-discovers schema from S3 and updates the Catalog"
  value       = aws_glue_crawler.s3_data_lake.name
}

output "glue_job_name" {
  description = "Glue ETL job that converts CSV to Parquet for Athena cost optimization"
  value       = aws_glue_job.csv_to_parquet.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup with 1 GB scan limit for cost control"
  value       = aws_athena_workgroup.main.name
}

output "athena_database_name" {
  description = "Athena database (maps 1-to-1 with the Glue Catalog database)"
  value       = aws_athena_database.main.name
}

output "glue_role_arn" {
  description = "IAM role ARN used by Glue crawlers and jobs"
  value       = aws_iam_role.glue_role.arn
}

output "exam_cheat_sheet" {
  description = "SAA-C03 quick reference for Athena + Glue + Lake Formation"
  value = {
    athena_cost_reduction   = "Parquet/ORC + compression + partitioning = up to 90% less cost"
    glue_catalog            = "Central metadata repo shared by Athena, Redshift Spectrum, EMR"
    glue_crawler_use_case   = "Auto-discover schema from S3/RDS/DynamoDB → catalog tables"
    glue_databrew           = "Visual no-code data prep — for analysts not engineers"
    lake_formation_use_case = "Column-level + row-level security on top of Glue Catalog"
    athena_workgroup        = "Per-team cost isolation + enforce scan limits"
    serverless_etl_pattern  = "S3 → Glue Crawler → Glue Catalog → Athena (no servers)"
    streaming_pattern       = "Kinesis Firehose → S3 → Glue Crawler → Athena"
    federated_query         = "Athena can query DynamoDB, RDS, Redshift via Lambda connectors"
  }
}

# =============================================================================
# SECTION: AMAZON QUICKSIGHT
# =============================================================================
# QuickSight = AWS managed BI (Business Intelligence) service.
# SAA-C03 exam: "dashboards" | "visualizations" | "BI tool" | "business users" = QuickSight
#
# KEY FACTS:
#   - Serverless, fully managed BI
#   - Data sources: S3 (via Athena), RDS, Redshift, DynamoDB, Salesforce, etc.
#   - SPICE: Super-fast, Parallel, In-memory Calculation Engine
#     - Pre-loads data into QuickSight's own in-memory engine
#     - Faster queries than querying source data directly
#     - Billed per GB of SPICE capacity
#   - Standard vs Enterprise edition (Enterprise: encryption, Active Directory, row-level security)
#   - Row-Level Security (RLS): restrict which rows users see based on rules
#   - Column-Level Security: restrict which columns users see (Enterprise)
#   - ML Insights: anomaly detection, forecasting, narrative summaries (Enterprise)
#
# EXAM TIPS:
#   - "Serverless BI" = QuickSight
#   - "Visualize S3 data" = S3 → Athena → QuickSight
#   - "BI dashboard for business users" = QuickSight
#   - "In-memory BI acceleration" = SPICE
#   - "SPICE" = QuickSight's in-memory engine
#
# NOTE: aws_quicksight_* Terraform resources require QuickSight to be enabled
# in the account and a valid QuickSight user. The resources below are documented
# as reference; in real labs they require account-level QuickSight setup.

# QuickSight Data Source — Athena
# resource "aws_quicksight_data_source" "athena" {
#   data_source_id = "lab-athena-source"
#   name           = "Lab Athena Data Source"
#   type           = "ATHENA"
#
#   parameters {
#     athena {
#       work_group = aws_athena_workgroup.main.name
#     }
#   }
#
#   permission {
#     actions   = ["quicksight:DescribeDataSource", "quicksight:PassDataSource"]
#     principal = "arn:aws:quicksight:us-east-1:${data.aws_caller_identity.current.account_id}:user/default/admin"
#   }
#
#   # SAA-C03: QuickSight Athena data source queries S3 data via Athena.
#   # Pattern: S3 data lake → Glue Data Catalog → Athena → QuickSight
#   # SPICE: set import_mode = "SPICE" in dataset to pre-cache results.
# }

# =============================================================================
# SECTION: AWS LAKE FORMATION
# =============================================================================
# Lake Formation = centralized permission management for data lakes.
# SAA-C03: "fine-grained access control on S3 data lake" = Lake Formation
#
# KEY FACTS:
#   - Sits on top of S3 + Glue Data Catalog
#   - Grants column/row level permissions (more granular than S3 bucket policies)
#   - Cross-account data sharing via Lake Formation permissions
#   - Tag-based access control (LF-TBAC) = ABAC for data lake
#   - Blueprint: automated ingestion from JDBC, S3, CloudTrail into the data lake
#   - Governed Tables: ACID transactions on S3 (like Delta Lake / Iceberg)
#
# EXAM TIPS:
#   - "Row/column level security on Glue tables" = Lake Formation
#   - "Share Glue catalog across accounts" = Lake Formation cross-account
#   - "Centralize data lake permissions" = Lake Formation
#   - "ACID transactions on S3" = Lake Formation Governed Tables

# Lake Formation admin settings (registers the data lake S3 location)
resource "aws_lakeformation_data_lake_settings" "main" {
  admins = [data.aws_caller_identity.current.arn]
  # Admins can grant/revoke Lake Formation permissions to other principals.
  # SAA-C03: The IAMAllowedPrincipals group is the default that allows IAM-only control.
  # When you add LF admins, consider removing IAMAllowedPrincipals to enforce LF permissions.
}

# Grant SELECT permission on a Glue database to a principal
# SAA-C03: LF permissions are checked IN ADDITION TO IAM policies (both must allow)
resource "aws_lakeformation_permissions" "analyst_select" {
  principal   = data.aws_caller_identity.current.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = aws_glue_catalog_database.main.name
    wildcard      = true # Grant on ALL tables in the database
    # To grant on a specific table: name = "my_table" (remove wildcard)
  }
  # Column-level security (Enterprise):
  # table_with_columns {
  #   database_name = aws_glue_catalog_database.main.name
  #   name          = "sensitive_table"
  #   column_names  = ["non_sensitive_col1", "non_sensitive_col2"]
  # }
}
