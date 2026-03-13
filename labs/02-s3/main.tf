# ============================================================
# LAB 02 - S3 Storage: Buckets, Storage Classes, Lifecycle,
#          Versioning, Encryption, Replication, Static Website
# All resources are destroy-safe
# ============================================================

locals {
  bucket_name        = "${var.bucket_prefix}-main-${random_id.suffix.hex}"
  bucket_logs        = "${var.bucket_prefix}-logs-${random_id.suffix.hex}"
  bucket_replication = "${var.bucket_prefix}-replica-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {

  byte_length = 4
}

# ============================================================
# MAIN BUCKET (Standard storage class, versioning, encryption)
# S3 bucket naming rules:
#   - Globally unique, 3-63 chars
#   - Lowercase, numbers, hyphens only
#   - No IP format
# ============================================================
resource "aws_s3_bucket" "main" {
  bucket        = local.bucket_name
  force_destroy = true # destroy-safe: deletes all objects on terraform destroy
}

# Versioning — keeps multiple versions of objects
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption (SSE-S3 = AWS managed keys)
# SSE-KMS = Customer managed keys via KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3

    }
  }
}

# Block all public access (security best practice)
resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# LIFECYCLE POLICY
# Automates movement between storage classes:
#
# Standard → Standard-IA (after 30 days, infrequent access)
# Standard-IA → Glacier Flexible (after 90 days, archive)
# Glacier Deep Archive (after 180 days, long-term)
# Expire (delete after 365 days)
#
# Storage Classes (cost order, high to low):
#   S3 Standard           = Frequently accessed
#   S3 Intelligent-Tiering = Unknown access pattern
#   S3 Standard-IA        = Infrequent access (min 30 days, min 128 KB)
#   S3 One Zone-IA        = Infrequent, non-critical (single AZ)
#   S3 Glacier Instant    = Archive, instant retrieval
#   S3 Glacier Flexible   = Archive, 1-5min/3-5hr/5-12hr retrieval
#   S3 Glacier Deep       = Archive, 12-48hr retrieval, cheapest
# ============================================================
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "transition-to-cheaper-storage"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"

    }

    transition {

      days          = 90
      storage_class = "GLACIER"

    }

    transition {

      days          = 180
      storage_class = "DEEP_ARCHIVE"

    }

    expiration {

      days = 365

    }
  }

  rule {

    id     = "intelligent-tiering-example"
    status = "Enabled"

    filter {
      prefix = "auto/"

    }

    transition {

      days          = 0
      storage_class = "INTELLIGENT_TIERING"

    }
  }

  # Clean up old versions
  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90

    }
  }
}

# ============================================================
# CORS Configuration (for web app access)
# ============================================================
resource "aws_s3_bucket_cors_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

# ============================================================
# STATIC WEBSITE HOSTING
# ============================================================
resource "aws_s3_bucket" "website" {
  bucket        = "${var.bucket_prefix}-website-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_website_configuration" "website" {

  bucket = aws_s3_bucket.website.id

  index_document {
    suffix = "index.html"
  }

  error_document {

    key = "error.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website" {

  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website" {

  bucket     = aws_s3_bucket.website.id
  depends_on = [aws_s3_bucket_public_access_block.website]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.website.arn}/*"
    }]
  })
}

resource "aws_s3_object" "index" {

  bucket       = aws_s3_bucket.website.id
  key          = "index.html"
  content      = "<h1>SAA Lab 02 - S3 Static Website</h1>"
  content_type = "text/html"
}

# ============================================================
# S3 ACCESS LOGS BUCKET
# ============================================================
resource "aws_s3_bucket" "logs" {
  bucket        = local.bucket_logs
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {

  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "main" {

  bucket        = aws_s3_bucket.main.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access-logs/"
}

# ============================================================
# REPLICATION (Cross-Region Replication)
# Requires versioning on both source and destination
# Use case: Disaster recovery, compliance, latency reduction
# ============================================================
resource "aws_s3_bucket" "replica" {
  provider      = aws.replica
  bucket        = local.bucket_replication
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "replica" {

  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role" "replication" {

  name = "lab-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication" {

  name = "lab-s3-replication-policy"
  role = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersion", "s3:GetObjectVersionAcl"]
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete"]
        Resource = "${aws_s3_bucket.replica.arn}/*"

      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "main" {

  bucket = aws_s3_bucket.main.id
  role   = aws_iam_role.replication.arn

  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "replicate-all"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD_IA"

    }
  }
}
