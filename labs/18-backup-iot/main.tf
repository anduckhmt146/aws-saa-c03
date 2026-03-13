# ============================================================
# LAB 18 - IoT Core, EventBridge Scheduler, WorkSpaces concepts
# Other services from 13-other-services.md
# ============================================================

data "aws_caller_identity" "current" {}

# ============================================================
# IOT CORE
# Connect IoT devices to AWS
# Protocol: MQTT (lightweight, pub/sub), HTTP, WebSocket
# Components:
#   Device → IoT Core → Rules Engine → Actions (Lambda, S3, DynamoDB, SNS...)
#   Device Shadow: virtual state representation (sync device state)
# ============================================================

# IoT Policy (device permissions)
resource "aws_iot_policy" "lab" {
  name = "lab-iot-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iot:Connect"]
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:client/lab-*"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Publish"]
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/lab/sensors/*"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Subscribe"]
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topicfilter/lab/commands/*"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Receive"]
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/lab/commands/*"

      }
    ]
  })
}

# IoT Thing (represents a physical device)
resource "aws_iot_thing" "sensor" {
  name = "lab-temperature-sensor"

  attributes = {
    location = "server-room-1"
    type     = "temperature"
  }
}

# IoT Certificate (device auth — X.509)
resource "aws_iot_certificate" "sensor" {
  active = true
}

resource "aws_iot_policy_attachment" "sensor" {

  policy = aws_iot_policy.lab.name
  target = aws_iot_certificate.sensor.arn
}

resource "aws_iot_thing_principal_attachment" "sensor" {

  thing     = aws_iot_thing.sensor.name
  principal = aws_iot_certificate.sensor.arn
}

# IoT Thing Type (template for similar devices)
resource "aws_iot_thing_type" "sensor" {
  name = "TemperatureSensor"

  properties {
    description           = "Temperature sensor IoT device"
    searchable_attributes = ["location", "type"]
  }
}

# IoT Topic Rule (Rules Engine)
# Route MQTT messages to AWS services
resource "aws_iot_topic_rule" "lab" {
  name        = "lab_iot_rule"
  description = "Route temperature readings to DynamoDB and Lambda"
  enabled     = true
  sql         = "SELECT * FROM 'lab/sensors/temperature'"
  sql_version = "2016-03-23"

  # Action 1: Store in DynamoDB
  dynamodbv2 {
    role_arn = aws_iam_role.iot_rules.arn

    put_item {
      table_name = "iot-readings"

    }
  }

  # Action 2: Send to SNS for alerts
  sns {
    role_arn       = aws_iam_role.iot_rules.arn
    target_arn     = aws_sns_topic.iot_alerts.arn
    message_format = "RAW"
  }

  # Error action: send failures to SQS
  error_action {
    sqs {
      role_arn   = aws_iam_role.iot_rules.arn
      queue_url  = aws_sqs_queue.iot_errors.url
      use_base64 = false

    }
  }
}

resource "aws_sns_topic" "iot_alerts" {

  name = "lab-iot-alerts"
}

resource "aws_sqs_queue" "iot_errors" {

  name                      = "lab-iot-errors"
  message_retention_seconds = 86400
}

resource "aws_iam_role" "iot_rules" {

  name = "lab-iot-rules-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "iot_rules" {

  name = "lab-iot-rules-policy"
  role = aws_iam_role.iot_rules.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.iot_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.iot_errors.arn

      }
    ]
  })
}

# ============================================================
# EVENTBRIDGE SCHEDULER
# Schedule tasks with more flexibility than CloudWatch Events
# Supports: one-time, recurring (rate/cron), time zones
# Targets: Lambda, SQS, SNS, ECS, Step Functions, API calls
# ============================================================

resource "aws_iam_role" "scheduler" {

  name = "lab-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {

  name = "lab-scheduler-policy"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = aws_sns_topic.iot_alerts.arn
    }]
  })
}

# Recurring schedule (every hour)
resource "aws_scheduler_schedule" "hourly_report" {
  name       = "lab-hourly-report"
  group_name = "default"

  flexible_time_window {
    mode = "OFF" # Execute exactly at scheduled time
  }

  schedule_expression          = "rate(1 hour)"
  schedule_expression_timezone = "Asia/Ho_Chi_Minh"

  target {

    arn      = aws_sns_topic.iot_alerts.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      message = "Hourly IoT report triggered"
      source  = "EventBridge Scheduler"
    })
  }
}

# One-time schedule
resource "aws_scheduler_schedule" "one_time" {
  name       = "lab-one-time-task"
  group_name = "default"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15 # Execute within 15 min window
  }

  schedule_expression = "at(2030-01-01T00:00:00)" # Far future for lab

  target {

    arn      = aws_sns_topic.iot_alerts.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ message = "One-time task executed" })
  }
}

# ============================================================
# WORKSPACES DIRECTORY (Virtual Desktops - DaaS)
# Note: Requires AWS Directory Service — using Simple AD for lab
# WorkSpaces: persistent virtual desktops (Windows/Linux)
# AppStream 2.0: stream applications to browser (no desktop)
# ============================================================

# Simple AD directory for WorkSpaces
resource "aws_directory_service_directory" "lab" {
  name     = "lab.example.com"
  password = "LabPassword1!"
  size     = "Small" # Small (up to 500 users), Large (up to 5000)
  type     = "SimpleAD"

  vpc_settings {
    vpc_id     = data.aws_vpc.default.id
    subnet_ids = slice(tolist(data.aws_subnets.default.ids), 0, 2)
  }
}

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# WorkSpaces is registered to a directory
# Actual WorkSpaces instances are created per user
# Uncomment if you want to provision a workspace (has hourly cost)
# resource "aws_workspaces_workspace" "lab" {
#   directory_id = aws_directory_service_directory.lab.id
#   bundle_id    = "wsb-bh8rsxt14"  # Standard Windows bundle
#   user_name    = "lab-user"
#   root_volume_encryption_enabled = false
#   user_volume_encryption_enabled = false
#   workspace_properties {
#     compute_type_name             = "VALUE"
#     user_volume_size_gib          = 10
#     root_volume_size_gib          = 80
#     running_mode                  = "AUTO_STOP"
#     running_mode_auto_stop_timeout_in_minutes = 60
#   }
# }
