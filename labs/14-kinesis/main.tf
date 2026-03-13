# ============================================================
# LAB 14 - Kinesis: Data Streams, Firehose, Analytics
# + Athena (S3 serverless SQL)
# Real-time data streaming and analytics
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# KINESIS DATA STREAMS
# Real-time ingestion (~200ms latency)
# Capacity: shards (1MB/s in, 2MB/s out per shard)
# Retention: 24hrs default (up to 365 days)
# Use case: real-time analytics, log processing, CDC
# ============================================================
resource "aws_kinesis_stream" "lab" {
  name             = "lab-data-stream"
  shard_count      = 2  # Each shard: 1 MB/s write, 2 MB/s read
  retention_period = 24 # Hours (24 - 8760)

  # Shard-level metrics (additional cost)
  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
    "WriteProvisionedThroughputExceeded",
    "ReadProvisionedThroughputExceeded"
  ]

  # Encryption
  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  tags = { Name = "lab-data-stream" }
}

# ============================================================
# S3 DESTINATION for Firehose
# ============================================================
resource "aws_s3_bucket" "firehose_dest" {
  bucket        = "lab-firehose-dest-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "firehose_dest" {

  bucket                  = aws_s3_bucket.firehose_dest.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# IAM ROLE for Firehose
# ============================================================
resource "aws_iam_role" "firehose" {
  name = "lab-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {

  name = "lab-firehose-policy"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.firehose_dest.arn}", "${aws_s3_bucket.firehose_dest.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:GetRecords", "kinesis:GetShardIterator", "kinesis:DescribeStream", "kinesis:ListStreams"]
        Resource = aws_kinesis_stream.lab.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "*"

      }
    ]
  })
}

# ============================================================
# KINESIS FIREHOSE (Data Firehose)
# Near real-time (~60s latency, or when buffer fills)
# Serverless + Auto-scaling
# Destinations: S3, Redshift, OpenSearch, Splunk, HTTP
# Transformations: Lambda
# Use case: load data to data lake/warehouse
# ============================================================
resource "aws_kinesis_firehose_delivery_stream" "lab" {
  name        = "lab-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.lab.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {

    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.firehose_dest.arn
    prefix              = "year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/"

    # Buffer conditions (deliver when either is met first)
    buffering_size     = 5  # MB
    buffering_interval = 60 # seconds (60-900)

    compression_format = "GZIP"

    # Data format conversion (Parquet for Athena)
    # data_format_conversion_configuration { ... }

    cloudwatch_logging_options {

      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/lab-firehose"
      log_stream_name = "S3Delivery"

    }
  }

  tags = { Name = "lab-firehose" }
}

# ============================================================
# CLOUDWATCH LOG GROUP for Firehose
# ============================================================
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/lab-firehose"
  retention_in_days = 7
}

# ============================================================
# ATHENA - Serverless SQL on S3
# Pay per query (per TB scanned)
# Formats: CSV, JSON, Parquet, ORC, Avro
# Use case: ad-hoc analysis, log analysis, data lake query
# ============================================================

# Athena needs a results bucket
resource "aws_s3_bucket" "athena_results" {
  bucket        = "lab-athena-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {

  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_athena_workgroup" "lab" {

  name = "lab-workgroup"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"

    }

    engine_version {

      selected_engine_version = "Athena engine version 3"

    }
  }

  force_destroy = true # destroy-safe
}

resource "aws_athena_database" "lab" {

  name   = "lab_database"
  bucket = aws_s3_bucket.firehose_dest.bucket

  force_destroy = true # destroy-safe
}

# ============================================================
# GLUE DATA CATALOG (used by Athena)
# Metadata: database, tables, schemas
# Glue Crawler: auto-discover schema from S3
# ============================================================
resource "aws_glue_catalog_database" "lab" {
  name = "lab-glue-db"
}

resource "aws_iam_role" "glue" {

  name = "lab-glue-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "glue.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "glue" {

  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {

  name = "lab-glue-s3-policy"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = ["${aws_s3_bucket.firehose_dest.arn}", "${aws_s3_bucket.firehose_dest.arn}/*"]
    }]
  })
}

# Glue Crawler: discover schema from S3
resource "aws_glue_crawler" "lab" {
  name          = "lab-s3-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.lab.name

  s3_target {
    path = "s3://${aws_s3_bucket.firehose_dest.bucket}/"
  }

  schedule = "cron(0 1 * * ? *)" # Daily at 1 AM
}
