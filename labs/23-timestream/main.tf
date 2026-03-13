# =============================================================================
# AWS SAA-C03 Lab 23: Amazon Timestream
# =============================================================================
#
# WHAT IS TIMESTREAM?
# Amazon Timestream is a fully serverless, purpose-built time-series database.
# A time-series is a sequence of data points indexed in time order — think
# sensor readings every second, CPU metrics every minute, stock prices, etc.
#
# WHY NOT JUST USE DYNAMODB?
# DynamoDB is general-purpose NoSQL. You CAN store time-series data in it,
# but you would have to:
#   - Design your own partition key strategy for time-based queries
#   - Write your own time-range scan logic
#   - Implement your own aggregation functions (avg, min, max over time windows)
#
# Timestream gives you all of that built-in:
#   - Native time functions: bin(), ago(), now(), date_trunc()
#   - Automatic data tiering (memory → magnetic) based on age
#   - Optimized storage format for time-series (columnar, compressed)
#   - SQL-like query language with time-series extensions
#
# SAA-C03 KEY DISTINCTION:
#   - Timestream → time-series data (IoT sensors, metrics, monitoring, logs)
#   - DynamoDB   → general-purpose NoSQL (user profiles, session state, catalogs)
#   The exam will often present a scenario: "an IoT application needs to store
#   millions of sensor readings and query trends over time" → answer: Timestream
#
# NO SERVERS TO MANAGE:
# Timestream is fully serverless — no clusters, no instances, no capacity
# planning. It scales reads and writes automatically as your workload grows.
# You pay per query (GB scanned) and per GB stored.
#
# COMMON USE CASES (know these for the exam):
#   - IoT sensor data (temperature, pressure, GPS coordinates over time)
#   - Application metrics (request rates, error rates, latency percentiles)
#   - DevOps monitoring (CPU, memory, disk I/O over time)
#   - Clickstream analytics (user events with timestamps)
#   - Financial tick data (stock prices, trade volumes)
#
# INTEGRATIONS:
#   - Kinesis Data Streams → Timestream (stream ingest pipeline)
#   - AWS IoT Core         → Timestream (direct rule action)
#   - Amazon Grafana       → Timestream (native data source for dashboards)
#   - Lambda               → Timestream (application writes via SDK)
# =============================================================================

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Timestream is not available in all regions. us-east-1 and us-east-2 are
  # safe choices. Always verify regional availability for exam scenarios.
}

# =============================================================================
# TIMESTREAM DATABASE
# =============================================================================
#
# A Timestream DATABASE is a logical container — similar to a database in RDS
# or a keyspace in Keyspaces. It holds one or more tables.
#
# Databases do not have storage settings themselves; retention policies are
# configured per TABLE (because different tables can have different hot/cold
# data lifecycles).
# =============================================================================

resource "aws_timestreamwrite_database" "iot_telemetry" {
  database_name = "iot-telemetry"

  # KMS encryption — best practice for production workloads.
  # If omitted, Timestream uses an AWS-managed key automatically.
  # kms_key_id = aws_kms_key.timestream.arn  # uncomment if you have a CMK

  tags = {
    Name        = "iot-telemetry"
    Environment = "learning"
    Lab         = "23-timestream"
  }
}

# =============================================================================
# TIMESTREAM TABLE: SENSOR READINGS
# =============================================================================
#
# THE TWO-TIER STORAGE MODEL — this is the core Timestream concept:
#
# MEMORY STORE (hot tier):
#   - Stores the most recent data in memory (RAM-backed SSD).
#   - Extremely fast queries — sub-second for recent data.
#   - Configurable retention: 1 hour minimum, up to 8766 hours (~1 year max).
#   - More expensive per GB (you're paying for speed).
#   - Use for real-time dashboards, alerting, live monitoring.
#
# MAGNETIC STORE (cold tier):
#   - Stores older data on magnetic-backed optimized columnar storage.
#   - Lower cost — significantly cheaper per GB than memory store.
#   - Retention up to 73,000 years (effectively unlimited for practical use).
#     The exam sometimes says "up to 200 years" — both values appear in docs.
#   - Queries are slower (seconds to minutes for large scans).
#   - Use for historical analysis, compliance, long-term trends.
#
# DATA FLOW:
#   Write → Memory Store → (after retention period) → Magnetic Store → (after retention) → Deleted
#
# MAGNETIC STORE WRITES:
#   You can also enable direct writes to magnetic store for late-arriving data
#   (data older than the memory store retention). This is important for
#   out-of-order event pipelines (e.g., a sensor that reconnects after being
#   offline for a week).
# =============================================================================

resource "aws_timestreamwrite_table" "sensor_readings" {
  database_name = aws_timestreamwrite_database.iot_telemetry.database_name
  table_name    = "sensor_readings"

  # MEMORY STORE RETENTION
  # How long to keep data in the fast in-memory tier.
  # After this period, data is automatically moved to magnetic store.
  # Unit: HOURS
  retention_properties {
    memory_store_retention_period_in_hours = 24 # Keep last 24 hours in memory (fast queries)

    # MAGNETIC STORE RETENTION
    # How long to keep data in the slow cheap magnetic tier.
    # After this period, data is permanently deleted.
    # Unit: DAYS
    magnetic_store_retention_period_in_days = 365 # Keep 1 year of historical data
  }

  # MAGNETIC STORE WRITE PROPERTIES
  # Enable writes directly to magnetic store for late-arriving data.
  # Critical for IoT scenarios where devices go offline and reconnect.
  magnetic_store_write_properties {
    enable_magnetic_store_writes = true

    # When late data arrives, Timestream can buffer it in S3 before writing
    # to magnetic store (in case of transient errors).
    magnetic_store_rejected_data_location {
      s3_configuration {
        bucket_name       = "your-timestream-error-bucket" # replace with actual bucket
        object_key_prefix = "sensor_readings_errors/"
        # encryption_option = "SSE_KMS"
      }
    }
  }

  tags = {
    Name = "sensor_readings"
    Lab  = "23-timestream"
  }
}

# =============================================================================
# TIMESTREAM TABLE: APPLICATION METRICS
# =============================================================================
#
# A second table demonstrating different retention settings.
# Application metrics (CPU, memory, request counts) are useful for:
#   - Short-term: real-time alerting and dashboards (hours)
#   - Medium-term: capacity planning and trend analysis (weeks to months)
#
# For application metrics, you typically need:
#   - Very recent data (last hour) to be fast for live dashboards.
#   - A few months of history for trend analysis and capacity planning.
#
# Compare to sensor_readings which might need a full year of history.
# Different use cases → different retention configurations.
# =============================================================================

resource "aws_timestreamwrite_table" "app_metrics" {
  database_name = aws_timestreamwrite_database.iot_telemetry.database_name
  table_name    = "app_metrics"

  retention_properties {
    # Keep 6 hours in memory — enough for real-time dashboards and alerting.
    # Shorter than sensor_readings because app metrics are queried more
    # frequently but only over short windows.
    memory_store_retention_period_in_hours = 6

    # Keep 90 days in magnetic store — enough for quarterly trend analysis.
    magnetic_store_retention_period_in_days = 90
  }

  magnetic_store_write_properties {
    # Disable late writes for app metrics — metrics are always current,
    # we don't expect out-of-order data here.
    enable_magnetic_store_writes = false
  }

  tags = {
    Name = "app_metrics"
    Lab  = "23-timestream"
  }
}

# =============================================================================
# IAM ROLE FOR WRITING TO TIMESTREAM
# =============================================================================
#
# Your applications (Lambda functions, EC2 instances, ECS containers) need an
# IAM role to write data to Timestream.
#
# COMMON ARCHITECTURE PATTERN (know this for SAA-C03):
#
#   IoT Devices
#       ↓
#   AWS IoT Core (MQTT broker)
#       ↓ (IoT Rule Action)
#   Amazon Timestream
#
#   OR
#
#   Application → Kinesis Data Streams → Lambda → Timestream
#
# The Lambda (or IoT Rule) needs the permissions below.
# =============================================================================

# Trust policy — which AWS services can assume this role.
data "aws_iam_policy_document" "timestream_writer_trust" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com", # Lambda functions writing metrics/events
        "iot.amazonaws.com"     # IoT Core rules writing sensor data
      ]
    }

    actions = ["sts:AssumeRole"]
  }
}

# The IAM role itself.
resource "aws_iam_role" "timestream_writer" {
  name               = "timestream-writer-role"
  assume_role_policy = data.aws_iam_policy_document.timestream_writer_trust.json

  tags = {
    Lab = "23-timestream"
  }
}

# Permissions policy — what the role can do once assumed.
data "aws_iam_policy_document" "timestream_writer_permissions" {
  statement {
    sid    = "TimestreamWrite"
    effect = "Allow"

    actions = [
      "timestream:WriteRecords",      # Insert new data points
      "timestream:DescribeEndpoints", # Discover the correct regional endpoint
      # Note: DescribeEndpoints is REQUIRED — Timestream uses endpoint discovery,
      # meaning clients must first call DescribeEndpoints to get the actual
      # write endpoint. Forgetting this is a common mistake.
    ]

    resources = [
      aws_timestreamwrite_table.sensor_readings.arn,
      aws_timestreamwrite_table.app_metrics.arn
    ]
  }

  statement {
    sid    = "TimestreamDescribeDatabase"
    effect = "Allow"

    actions = [
      "timestream:DescribeDatabase", # Read database metadata
      "timestream:ListTables"        # Enumerate tables (needed by some SDKs)
    ]

    resources = [
      aws_timestreamwrite_database.iot_telemetry.arn
    ]
  }
}

resource "aws_iam_policy" "timestream_writer" {
  name        = "timestream-writer-policy"
  description = "Allows writing records to Timestream tables"
  policy      = data.aws_iam_policy_document.timestream_writer_permissions.json
}

resource "aws_iam_role_policy_attachment" "timestream_writer" {
  role       = aws_iam_role.timestream_writer.name
  policy_arn = aws_iam_policy.timestream_writer.arn
}

# =============================================================================
# SCHEDULED QUERIES (concept note — not all resources are Terraformable)
# =============================================================================
#
# Timestream Scheduled Queries let you PRE-AGGREGATE data on a schedule and
# store the results in a derived table.
#
# WHY THIS MATTERS:
# Raw time-series data (one row per sensor reading per second) grows fast.
# If your dashboard only needs hourly averages, scanning millions of raw rows
# every time is expensive and slow.
#
# SOLUTION: Create a scheduled query that runs every hour and computes:
#   SELECT bin(time, 1h) as hour,
#          avg(temperature) as avg_temp,
#          max(temperature) as max_temp
#   FROM sensor_readings
#   WHERE time BETWEEN ago(2h) AND now()
#   GROUP BY bin(time, 1h)
#
# Results are written to a separate "derived" table.
# Your dashboard queries the derived table → much cheaper and faster.
#
# SAA-C03 EXAM HINT: If the question mentions "reduce query costs on time-series
# data" or "pre-aggregate metrics", think Timestream Scheduled Queries.
#
# The aws_timestreamquery_scheduled_query resource exists in the AWS provider
# but requires a Timestream Query (read) endpoint and SNS topic for errors,
# which adds significant complexity. It is omitted here for clarity.
# =============================================================================
