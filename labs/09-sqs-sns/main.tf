# ============================================================
# LAB 09 - SQS & SNS: Queues, Topics, Fan-out, DLQ, FIFO
# Application Integration — decoupling services
# ============================================================

# ============================================================
# SQS - Simple Queue Service
# Types:
#   Standard: unlimited throughput, at-least-once, best-effort order
#   FIFO: 300 TPS (3000 with batching), exactly-once, strict order
# ============================================================

# Standard Queue
resource "aws_sqs_queue" "standard" {
  name = "lab-standard-queue"

  # Message settings
  message_retention_seconds  = 345600 # 4 days (default), max 14 days
  visibility_timeout_seconds = 30     # 30s default (0s - 12hrs)
  max_message_size           = 262144 # 256 KB max
  delay_seconds              = 0      # Delay before message visible (0-900s)
  receive_wait_time_seconds  = 20     # Long polling (1-20s reduces API calls)

  # Redrive policy (DLQ) - after max_receive_count failures
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # After 3 failures → DLQ
  })

  tags = { Name = "lab-standard-queue" }
}

# FIFO Queue (strictly ordered, exactly-once delivery)
resource "aws_sqs_queue" "fifo" {
  name                        = "lab-fifo-queue.fifo" # Must end with .fifo
  fifo_queue                  = true
  content_based_deduplication = true # Auto dedup based on content hash

  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600

  tags = { Name = "lab-fifo-queue" }
}

# Dead Letter Queue
resource "aws_sqs_queue" "dlq" {
  name                      = "lab-dlq"
  message_retention_seconds = 1209600 # 14 days (max) to investigate failures

  tags = { Name = "lab-dlq" }
}

# ============================================================
# SQS QUEUE POLICY
# Allow SNS to send messages to SQS
# ============================================================
resource "aws_sqs_queue_policy" "standard" {
  queue_url = aws_sqs_queue.standard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.standard.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.lab.arn }

      }
    }]
  })
}

# ============================================================
# SNS - Simple Notification Service
# Pub/Sub model: Publishers → Topic → Subscribers
# Protocols: HTTP/S, Email, SQS, Lambda, SMS, mobile push
# Use case: Fan-out (1 message → multiple consumers)
# ============================================================
resource "aws_sns_topic" "lab" {
  name = "lab-topic"
  tags = { Name = "lab-sns-topic" }
}

# SNS FIFO Topic (ordered, dedup)
resource "aws_sns_topic" "fifo" {
  name                        = "lab-topic.fifo"
  fifo_topic                  = true
  content_based_deduplication = true
}

# ============================================================
# SNS SUBSCRIPTIONS
# Fan-out pattern: 1 SNS → multiple SQS queues
# ============================================================

# SNS → SQS (fan-out)
resource "aws_sns_topic_subscription" "sqs_standard" {
  topic_arn = aws_sns_topic.lab.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.standard.arn

  # Message filtering (only receive messages with type=order)
  filter_policy = jsonencode({
    event_type = ["order_created", "order_updated"]
  })
}

# SNS → Email (optional, requires confirmation click)
resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.lab.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ============================================================
# SNS TOPIC POLICY
# Allow S3 to publish to SNS (S3 event notification)
# ============================================================
resource "aws_sns_topic_policy" "lab" {
  arn = aws_sns_topic.lab.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSNSPublish"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.lab.arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id }

        }

      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# ============================================================
# EVENTBRIDGE (CloudWatch Events)
# Event bus for routing events between services
# Rules: pattern-match or schedule
# Use case: microservices decoupling, automation
# ============================================================
resource "aws_cloudwatch_event_bus" "lab" {
  name = "lab-event-bus"
}

resource "aws_cloudwatch_event_rule" "ec2_state" {

  name           = "lab-ec2-state-change"
  description    = "Capture EC2 state changes"
  event_bus_name = aws_cloudwatch_event_bus.lab.name

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["running", "stopped", "terminated"]

    }
  })
}

resource "aws_cloudwatch_event_target" "ec2_to_sns" {

  rule           = aws_cloudwatch_event_rule.ec2_state.name
  event_bus_name = aws_cloudwatch_event_bus.lab.name
  target_id      = "SendToSNS"
  arn            = aws_sns_topic.lab.arn
}
