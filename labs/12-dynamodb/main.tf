# ============================================================
# LAB 12 - DynamoDB: NoSQL, Capacity Modes, Streams, Global Tables
#
# Concepts:
#   - Table design: partition key (PK), sort key (SK), attributes
#   - Capacity modes: Provisioned (RCU/WCU) vs On-Demand (PAY_PER_REQUEST)
#   - Read Consistency: Eventually Consistent (default) vs Strongly Consistent
#   - DynamoDB Streams: capture item-level changes, trigger Lambda
#   - Global Tables: multi-region active-active replication
#   - DAX: in-memory cache (microsecond latency)
#   - TTL: auto-expire items by epoch timestamp attribute
#   - GSI / LSI: secondary indexes for alternate query patterns
#   - Table Class: STANDARD vs STANDARD_INFREQUENT_ACCESS
#
# SAA-C03 Key Points:
#   - DynamoDB is serverless, fully managed NoSQL
#   - On-Demand: auto-scales, no capacity planning, higher cost per RCU/WCU
#   - Provisioned: lower cost, but requires capacity estimation + auto-scaling
#   - GSI: different PK/SK, own capacity, eventual consistency only
#   - LSI: same PK, different SK, must be created at table creation
#   - Streams + Lambda = event-driven architecture
#   - Global Tables require On-Demand or auto-scaling
#   - DAX: write-through cache, does NOT reduce write costs
# ============================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ============================================================
# ORDERS TABLE — Provisioned capacity with auto-scaling
# PK: orderId, SK: customerId
# GSI for querying by status, LSI for querying by date
# DynamoDB Streams enabled (Lambda trigger use case)
# ============================================================
resource "aws_dynamodb_table" "orders" {
  name         = "lab-orders"
  billing_mode = "PROVISIONED" # Predictable workload → lower cost
  hash_key     = "orderId"     # Partition key — determines data distribution
  range_key    = "customerId"  # Sort key — enables range queries within partition

  # Provisioned capacity — estimate based on expected RPS
  read_capacity  = 5 # 1 RCU = 1 strongly consistent read OR 2 eventually consistent reads of ≤4KB
  write_capacity = 5 # 1 WCU = 1 write of ≤1KB per second

  # Attribute definitions — only define attributes used as keys/index keys
  attribute {
    name = "orderId"
    type = "S" # S=String, N=Number, B=Binary
  }
  attribute {
    name = "customerId"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }

  # TTL: auto-delete expired items — no RCU/WCU cost, eventual deletion
  ttl {
    attribute_name = "expiresAt" # Store epoch timestamp in this attribute
    enabled        = true
  }

  # DynamoDB Streams: capture INSERT/MODIFY/REMOVE changes
  # Use case: trigger Lambda for order processing, cross-region replication
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES" # Options: KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, NEW_AND_OLD_IMAGES

  # GSI: Global Secondary Index — different partition/sort key, own capacity
  # Use case: query orders by status (e.g., find all PENDING orders)
  global_secondary_index {
    name               = "StatusIndex"
    hash_key           = "status"
    range_key          = "createdAt"
    projection_type    = "INCLUDE"                 # KEYS_ONLY | INCLUDE | ALL
    non_key_attributes = ["orderId", "customerId"] # Only for INCLUDE
    read_capacity      = 2
    write_capacity     = 2
  }

  # LSI: Local Secondary Index — same PK, different SK, MUST be defined at creation
  # Shares table's read/write capacity
  local_secondary_index {
    name            = "CreatedAtIndex"
    range_key       = "createdAt"
    projection_type = "ALL" # Include all attributes
  }

  # Encryption at rest — AWS owned key (free) vs KMS CMK
  server_side_encryption {
    enabled = true # Uses AWS owned key by default (no cost)
  }

  point_in_time_recovery {
    enabled = true # PITR: restore to any second in last 35 days
  }

  tags = {
    Purpose     = "lab-orders"
    BillingMode = "PROVISIONED"
  }
}

# Auto-scaling for orders table
# SAA-C03: use auto-scaling with Provisioned mode for variable traffic
resource "aws_appautoscaling_target" "orders_read" {
  max_capacity       = 20
  min_capacity       = 5
  resource_id        = "table/${aws_dynamodb_table.orders.name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "orders_read_policy" {
  name               = "lab-dynamodb-orders-read-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.orders_read.resource_id
  scalable_dimension = aws_appautoscaling_target.orders_read.scalable_dimension
  service_namespace  = aws_appautoscaling_target.orders_read.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70.0 # Scale up when utilization > 70%
  }
}

# ============================================================
# PRODUCTS TABLE — On-Demand capacity
# Use case: unpredictable or spiky traffic (flash sales)
# SAA-C03: On-Demand = no capacity planning, pay per request
# ============================================================
resource "aws_dynamodb_table" "products" {
  name         = "lab-products"
  billing_mode = "PAY_PER_REQUEST" # On-Demand: auto-scales instantly, no pre-provisioning
  hash_key     = "productId"

  attribute {
    name = "productId"
    type = "S"
  }
  attribute {
    name = "category"
    type = "S"
  }
  attribute {
    name = "price"
    type = "N" # Number type
  }

  global_secondary_index {
    name            = "CategoryPriceIndex"
    hash_key        = "category"
    range_key       = "price"
    projection_type = "ALL"
    # No read/write capacity needed for On-Demand
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Purpose     = "lab-products"
    BillingMode = "ON_DEMAND"
  }
}

# ============================================================
# GLOBAL TABLE — Multi-region active-active replication
# Use case: global apps needing low latency reads/writes worldwide
# SAA-C03: Global Tables = active-active, RPO near-zero, RTO near-zero
#          Requires On-Demand OR Provisioned with auto-scaling enabled
#          Replication lag typically < 1 second
# ============================================================
resource "aws_dynamodb_table" "global" {
  name             = "lab-global-sessions"
  billing_mode     = "PAY_PER_REQUEST" # Required for Global Tables (or Provisioned + auto-scaling)
  hash_key         = "sessionId"
  stream_enabled   = true # Required for Global Tables
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "sessionId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  # Replica in additional regions — adds active-active write capacity
  replica {
    region_name = "us-west-2" # Both regions serve reads AND writes
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Purpose = "lab-global-sessions"
    Type    = "GlobalTable"
  }
}

# ============================================================
# ARCHIVE TABLE — STANDARD_INFREQUENT_ACCESS class
# Use case: data accessed less than once per month
# SAA-C03: STANDARD_IA = lower storage cost, same performance
#          Good for: audit logs, historical data, cold analytics
# ============================================================
resource "aws_dynamodb_table" "archive" {
  name         = "lab-archive-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "eventId"
  range_key    = "timestamp"

  table_class = "STANDARD_INFREQUENT_ACCESS" # Lower storage cost for rarely accessed data

  attribute {
    name = "eventId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Purpose    = "lab-archive"
    TableClass = "STANDARD_IA"
  }
}

# ============================================================
# DYNAMODB RESOURCE POLICY
# Control which principals can access the table
# SAA-C03: resource-based policy vs IAM identity policy
#          Both must allow access (intersection, like S3 + IAM)
# ============================================================
resource "aws_dynamodb_resource_policy" "orders" {
  resource_arn = aws_dynamodb_table.orders.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "dynamodb:*"
        Resource  = aws_dynamodb_table.orders.arn
      }
    ]
  })
}
