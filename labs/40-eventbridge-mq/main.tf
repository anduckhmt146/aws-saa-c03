###############################################################################
# LAB 40 - Amazon EventBridge + Amazon MQ
# AWS SAA-C03 Exam Prep
###############################################################################
#
# AMAZON EVENTBRIDGE
# ===================
# Serverless event bus that connects application components together using events.
# Replaces the older CloudWatch Events service (same API, extended capabilities).
#
# EVENT BUS TYPES:
#   1. Default Bus  - receives events from AWS services automatically (EC2, S3, etc.)
#   2. Custom Bus   - for your own application events; enables cross-account delivery
#   3. Partner Bus  - ingests events from SaaS partners (Datadog, Zendesk, etc.)
#
# RULES:
#   - Attached to an event bus; define WHAT events to catch and WHERE to route them
#   - Two trigger types:
#       a) Event Pattern  - JSON filter matching specific event fields (source, detail-type, etc.)
#       b) Schedule       - cron expression ("cron(0 12 * * ? *)") or rate ("rate(5 minutes)")
#   - Up to 5 targets per rule; EventBridge fan-outs to all matched targets
#
# TARGETS (partial list - SAA-C03 favourites):
#   Lambda, SQS, SNS, Step Functions, API Gateway, Kinesis Data Streams,
#   Kinesis Firehose, ECS task, CodeBuild, CodePipeline, EC2 Run Command
#
# PIPES (EventBridge Pipes):
#   Point-to-point integration with a single SOURCE → optional FILTER
#   → optional ENRICHMENT (Lambda/Step Functions) → single TARGET.
#   Useful for: DynamoDB Streams → Lambda → EventBridge target (cleaner than raw triggers)
#
# SCHEMA REGISTRY:
#   Discovers and stores event schemas. Enables IDE code-completion for events.
#   Can auto-discover schemas from traffic on a bus.
#
# ARCHIVE & REPLAY:
#   Archive: capture all (or filtered) events on a bus indefinitely or for N days.
#   Replay: re-process archived events into the same or a different bus/rule.
#   SAA-C03 use case: "replay events after a bug fix" = EventBridge archive + replay.
#
# SAA-C03 KEY DIFFERENTIATORS:
#   EventBridge vs SQS vs SNS:
#     SQS    = decoupled queue; consumers PULL; point-to-point; good for work queues
#     SNS    = pub/sub push; fan-out to many subscribers; no filtering (except filter policies)
#     EventBridge = event routing; content-based filtering; schema registry; cross-account;
#                   SaaS integrations; replaces CloudWatch Events
#   "Modernise event-driven architecture" or "route AWS service events" → EventBridge
#
# AMAZON MQ
# ==========
# Fully managed message broker service running Apache ActiveMQ or RabbitMQ.
#
# WHY MQ EXISTS (SAA-C03 context):
#   If an on-premises application uses industry-standard protocols:
#     JMS, AMQP, MQTT, STOMP, OpenWire, NMS
#   ...you CANNOT easily refactor it to use SQS/SNS (different API).
#   Amazon MQ lets you LIFT-AND-SHIFT without changing application code.
#
# DEPLOYMENT MODES:
#   Single-instance   - one broker; for dev/test; no HA
#   Active/Standby    - two brokers across AZs; automatic failover; for production
#
# STORAGE:
#   ActiveMQ: Amazon EFS (active/standby) or EBS (single-instance)
#   RabbitMQ: EBS
#
# NETWORKING:
#   Lives inside a VPC; accessed via private endpoints (not public by default)
#   Supports TLS in-transit; at-rest encryption via KMS
#
# SAA-C03 DECISION TREE:
#   New cloud-native app                 → SQS / SNS / EventBridge
#   Migrate on-prem JMS/AMQP app        → Amazon MQ (ActiveMQ)
#   Migrate on-prem RabbitMQ            → Amazon MQ (RabbitMQ)
#   "Can't change application code"     → Amazon MQ
#   "Serverless, no broker management"  → SQS / SNS / EventBridge
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

variable "project" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "saa-lab40"
}

variable "mq_admin_password" {
  description = "Admin password for Amazon MQ broker (min 12 chars, no special leading chars)"
  type        = string
  sensitive   = true
  default     = "ChangeMe12345!"
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Default VPC for lab simplicity (production: use dedicated VPC)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

###############################################################################
# EVENTBRIDGE - CUSTOM EVENT BUS
#
# Custom bus isolates your application events from AWS service events.
# Enables cross-account event delivery (publish from account A, subscribe in B).
# SAA-C03: "central event hub for microservices" = custom EventBridge bus
###############################################################################

resource "aws_cloudwatch_event_bus" "app" {
  # SAA-C03: Custom bus name cannot start with "aws." (reserved for AWS service buses)
  name = "${var.project}-app-events"

  tags = {
    Name    = "${var.project}-app-events"
    Purpose = "Custom event bus for application domain events"
    Lab     = "40-eventbridge-mq"
  }
}

###############################################################################
# EVENTBRIDGE RULES
#
# Rules evaluate EVERY event on the bus.
# Pattern matching uses JSON sub-set matching (prefix, anything, numeric ranges).
# ALL specified fields must match (implicit AND); arrays are OR within a field.
###############################################################################

# RULE 1 - EC2 State Change (Event Pattern on DEFAULT bus)
# Matches EC2 instance state changes to "stopped" or "terminated".
# SAA-C03: AWS service events always land on the DEFAULT bus, not custom buses.
resource "aws_cloudwatch_event_rule" "ec2_state_change" {
  name           = "${var.project}-ec2-state-change"
  description    = "Fires when EC2 instance transitions to stopped or terminated"
  event_bus_name = "default" # AWS service events → default bus

  # Event pattern: JSON filter; all top-level keys are AND; array values are OR
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["stopped", "terminated"] # OR: matches either state
    }
  })

  state = "ENABLED"

  tags = {
    Name = "${var.project}-ec2-state-change"
    Lab  = "40-eventbridge-mq"
  }
}

# RULE 2 - S3 Object Created (Event Pattern on DEFAULT bus)
# Matches S3 PutObject events; note S3 must have EventBridge notifications enabled.
# SAA-C03: S3 → EventBridge is an alternative to S3 Event Notifications (more flexible routing).
resource "aws_cloudwatch_event_rule" "s3_object_created" {
  name           = "${var.project}-s3-object-created"
  description    = "Fires when any S3 object is created (PutObject / CompleteMultipartUpload)"
  event_bus_name = "default"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    # No detail filter = match ALL S3 buckets; add "bucket": {"name": ["my-bucket"]} to narrow
  })

  state = "ENABLED"

  tags = {
    Name = "${var.project}-s3-object-created"
    Lab  = "40-eventbridge-mq"
  }
}

# RULE 3 - Scheduled Cron (no event bus source)
# Runs on a fixed schedule; useful for batch jobs, cleanup tasks, periodic reports.
# Cron syntax: cron(minutes hours day-of-month month day-of-week year)
# AWS uses UTC; day-of-week and day-of-month cannot both be specified (use ? for one).
# SAA-C03: "trigger Lambda every weekday at 8 AM UTC" = EventBridge scheduled rule
resource "aws_cloudwatch_event_rule" "daily_report" {
  name           = "${var.project}-daily-report"
  description    = "Fires at 08:00 UTC Monday-Friday to trigger daily report generation"
  event_bus_name = "default" # Scheduled rules must use the default bus

  # cron(min hour day-of-month month day-of-week year)
  # ? = no specific value; MON-FRI = weekdays; * = every year
  schedule_expression = "cron(0 8 ? * MON-FRI *)"

  state = "ENABLED"

  tags = {
    Name = "${var.project}-daily-report"
    Lab  = "40-eventbridge-mq"
  }
}

###############################################################################
# EVENTBRIDGE TARGETS
#
# Each rule can have up to 5 targets.
# EventBridge delivers events asynchronously; retry policy is configurable.
# Dead-letter queue (DLQ) captures events that fail all delivery retries.
###############################################################################

# Placeholder Lambda ARN (in a real lab this would reference an actual function)
locals {
  # Construct a plausible Lambda ARN for demonstration
  lambda_arn = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project}-processor"
}

# SQS Queue as EventBridge target (DLQ for failed deliveries)
resource "aws_sqs_queue" "eventbridge_dlq" {
  # SAA-C03: DLQ captures events that EventBridge couldn't deliver after all retries.
  # Allows investigation and manual reprocessing.
  name                      = "${var.project}-eventbridge-dlq"
  message_retention_seconds = 1209600 # 14 days (maximum)

  tags = {
    Name    = "${var.project}-eventbridge-dlq"
    Purpose = "Dead-letter queue for EventBridge delivery failures"
    Lab     = "40-eventbridge-mq"
  }
}

# SQS Queue as a normal target (event fan-out)
resource "aws_sqs_queue" "ec2_events_queue" {
  name = "${var.project}-ec2-events"

  tags = {
    Name = "${var.project}-ec2-events"
    Lab  = "40-eventbridge-mq"
  }
}

# Allow EventBridge to send messages to the SQS queue
resource "aws_sqs_queue_policy" "ec2_events_queue" {
  queue_url = aws_sqs_queue.ec2_events_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.ec2_events_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.ec2_state_change.arn
          }
        }
      }
    ]
  })
}

# TARGET: EC2 state change → SQS queue
# Input transformer reshapes the raw event JSON into a cleaner message body.
resource "aws_cloudwatch_event_target" "ec2_to_sqs" {
  rule           = aws_cloudwatch_event_rule.ec2_state_change.name
  event_bus_name = "default"
  target_id      = "EC2StateToSQS"
  arn            = aws_sqs_queue.ec2_events_queue.arn

  # Retry policy: how many times to retry on target failure (max 185 attempts over 24 h)
  retry_policy {
    maximum_event_age_in_seconds = 3600 # Give up after 1 hour
    maximum_retry_attempts       = 3    # 3 attempts then → DLQ
  }

  # Dead-letter config: where to send events after all retries fail
  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }

  # Input transformer: extract only the fields we care about
  # <instance-id> and <state> are path references into the event JSON
  input_transformer {
    input_paths = {
      "instance-id" = "$.detail.instance-id"
      "state"       = "$.detail.state"
      "time"        = "$.time"
    }
    # Template must be valid JSON; use the path variable names in angle brackets
    input_template = <<-EOT
      {
        "instanceId": "<instance-id>",
        "newState": "<state>",
        "eventTime": "<time>",
        "message": "EC2 instance <instance-id> transitioned to <state>"
      }
    EOT
  }
}

# TARGET: Daily report schedule → Lambda
# EventBridge assumes a role to invoke Lambda on your behalf (or uses resource policy)
# For Lambda, EventBridge uses the Lambda resource-based policy (no separate IAM role needed)
resource "aws_cloudwatch_event_target" "daily_report_lambda" {
  rule           = aws_cloudwatch_event_rule.daily_report.name
  event_bus_name = "default"
  target_id      = "DailyReportLambda"
  arn            = local.lambda_arn

  # For scheduled rules, you can pass static JSON to the Lambda
  input = jsonencode({
    action     = "generate_report"
    reportType = "daily"
  })
}

###############################################################################
# EVENTBRIDGE ARCHIVE
#
# Archives capture a copy of events flowing through a bus.
# Can archive ALL events or only those matching an event pattern filter.
# Retained for a configurable number of days (0 = indefinitely).
# SAA-C03: "replay past events after bug fix" = archive + replay feature
###############################################################################

resource "aws_cloudwatch_event_archive" "app_events" {
  name             = "${var.project}-app-archive"
  description      = "Archive all events on the custom app bus for 90 days"
  event_source_arn = aws_cloudwatch_event_bus.app.arn

  # Retention: 0 = keep forever; set a value to auto-expire
  retention_days = 90

  # Optional filter: omit event_pattern to archive everything on the bus
  # event_pattern = jsonencode({ source = ["com.myapp.orders"] })

  # SAA-C03: aws_cloudwatch_event_archive does not support a tags argument.
}

###############################################################################
# EVENTBRIDGE SCHEMA REGISTRY
#
# Schema registry stores JSON Schema (or OpenAPI) definitions for event structures.
# EventBridge can AUTO-DISCOVER schemas by sampling events on a bus.
# Use with AWS Toolkit (VSCode/JetBrains) for IDE code completion.
# SAA-C03: Schema registry is a feature detail; know it exists and its purpose.
###############################################################################

resource "aws_schemas_registry" "app" {
  name        = "${var.project}-schema-registry"
  description = "Schema registry for application domain events on the custom bus"

  tags = {
    Name = "${var.project}-schema-registry"
    Lab  = "40-eventbridge-mq"
  }
}

###############################################################################
# AMAZON MQ - SECURITY GROUP
#
# Amazon MQ broker lives inside the VPC; control access via security groups.
# Protocol ports:
#   ActiveMQ: 61617 (OpenWire/TLS), 5671 (AMQP/TLS), 61614 (STOMP/TLS),
#             8883 (MQTT/TLS), 443 (HTTPS console)
#   RabbitMQ: 5671 (AMQP/TLS), 443 (HTTPS console)
# SAA-C03: MQ is NOT publicly accessible by default; clients must be in the VPC
#          or connected via VPN/Direct Connect.
###############################################################################

resource "aws_security_group" "mq_broker" {
  name        = "${var.project}-mq-broker"
  description = "Allow ActiveMQ protocol access from application tier"
  vpc_id      = data.aws_vpc.default.id

  # OpenWire (TLS) - primary Java/JMS protocol for ActiveMQ
  ingress {
    description = "ActiveMQ OpenWire TLS"
    from_port   = 61617
    to_port     = 61617
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # AMQP TLS - cross-platform messaging protocol
  ingress {
    description = "AMQP TLS"
    from_port   = 5671
    to_port     = 5671
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # STOMP TLS - simple text-based protocol
  ingress {
    description = "STOMP TLS"
    from_port   = 61614
    to_port     = 61614
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # MQTT TLS - lightweight IoT protocol
  ingress {
    description = "MQTT TLS"
    from_port   = 8883
    to_port     = 8883
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # ActiveMQ Web Console (HTTPS)
  ingress {
    description = "ActiveMQ HTTPS Console"
    from_port   = 8162
    to_port     = 8162
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-mq-broker"
    Lab  = "40-eventbridge-mq"
  }
}

###############################################################################
# AMAZON MQ - BROKER CONFIGURATION
#
# Broker configuration contains ActiveMQ XML config (activemq.xml equivalent).
# Allows customising: persistence adapters, network connectors, plugins, etc.
# SAA-C03: Know that MQ configuration maps to the broker's activemq.xml.
###############################################################################

resource "aws_mq_configuration" "activemq" {
  name           = "${var.project}-activemq-config"
  description    = "Custom ActiveMQ broker configuration for lab"
  engine_type    = "ActiveMQ"
  engine_version = "5.17.6" # Use latest available version in production

  # XML configuration - this is the standard ActiveMQ broker config format
  # Allows setting persistence, memory limits, network connectors, etc.
  data = <<-XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <broker xmlns="http://activemq.apache.org/schema/core">

      <!-- Destination policies control memory/disk limits per queue/topic -->
      <destinationPolicy>
        <policyMap>
          <policyEntries>
            <policyEntry topic="&gt;">
              <!-- Enable slow consumer handling for topics -->
              <pendingMessageLimitStrategy>
                <constantPendingMessageLimitStrategy limit="1000"/>
              </pendingMessageLimitStrategy>
            </policyEntry>
          </policyEntries>
        </policyMap>
      </destinationPolicy>

      <!-- Memory and storage limits for the broker -->
      <systemUsage>
        <systemUsage>
          <memoryUsage>
            <memoryUsage percentOfJvmHeap="70"/>
          </memoryUsage>
          <storeUsage>
            <storeUsage limit="100 gb"/>
          </storeUsage>
          <tempUsage>
            <tempUsage limit="50 gb"/>
          </tempUsage>
        </systemUsage>
      </systemUsage>

      <!-- Transport connectors define which protocols the broker listens on -->
      <transportConnectors>
        <transportConnector name="openwire" uri="ssl://0.0.0.0:61617?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
        <transportConnector name="amqp"     uri="amqp+ssl://0.0.0.0:5671?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
        <transportConnector name="stomp"    uri="stomp+ssl://0.0.0.0:61614?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
        <transportConnector name="mqtt"     uri="mqtt+ssl://0.0.0.0:8883?maximumConnections=1000&amp;wireFormat.maxFrameSize=104857600"/>
      </transportConnectors>

      <!-- Virtual destinations: map a queue to a topic for fan-out -->
      <virtualDestinations>
        <virtualTopic name="VirtualTopic.&gt;" prefix="Consumer.*." selectorAware="false"/>
      </virtualDestinations>

    </broker>
  XML

  tags = {
    Name = "${var.project}-activemq-config"
    Lab  = "40-eventbridge-mq"
  }
}

###############################################################################
# AMAZON MQ - BROKER
#
# DEPLOYMENT MODES:
#   mq.m5.large (or similar) with single-instance = dev/test (no HA)
#   Active/Standby = two brokers across two AZs; automatic failover (~30-60s)
#
# STORAGE (ActiveMQ):
#   Single-instance: Amazon EBS (gp3)
#   Active/Standby:  Amazon EFS (shared persistent storage across AZs)
#
# ENCRYPTION:
#   In-transit: TLS enforced
#   At-rest:    AWS-managed or customer KMS key
#
# SAA-C03: Active/Standby requires TWO subnets in DIFFERENT AZs.
#          Single-instance uses ONE subnet.
###############################################################################

resource "aws_mq_broker" "activemq" {
  broker_name = "${var.project}-activemq"

  # SINGLE-INSTANCE for lab cost savings; use ACTIVE_STANDBY_MULTI_AZ in production
  deployment_mode = "SINGLE_INSTANCE"

  # ActiveMQ engine; alternative is "RabbitMQ"
  engine_type    = "ActiveMQ"
  engine_version = "5.17.6"

  # mq.m5.large is smallest production class; mq.t3.micro is for dev/test
  host_instance_type = "mq.m5.large"

  # Security settings
  publicly_accessible = false # Never expose MQ publicly; access via VPC
  security_groups     = [aws_security_group.mq_broker.id]
  subnet_ids          = [tolist(data.aws_subnets.default.ids)[0]] # Single subnet for single-instance

  # At-rest encryption (omit kms_key_id for AWS-managed key)
  encryption_options {
    use_aws_owned_key = true # Set to false and provide kms_key_id for CMK
  }

  # Attach custom configuration
  configuration {
    id       = aws_mq_configuration.activemq.id
    revision = aws_mq_configuration.activemq.latest_revision
  }

  # Broker admin user; additional users can be created for app-level isolation
  user {
    username = "admin"
    password = var.mq_admin_password
    # console_access = true allows login to the ActiveMQ Web Console
    console_access = true
    # Groups can be used with authorisation plugins in activemq.xml
    groups = ["admin"]
  }

  # Logs: send ActiveMQ general and audit logs to CloudWatch Logs
  logs {
    general = true # Broker-level log messages
    audit   = true # Records all connections and operations (compliance)
  }

  # Maintenance window: when AWS can apply minor version patches
  maintenance_window_start_time {
    day_of_week = "SUNDAY"
    time_of_day = "03:00"
    time_zone   = "UTC"
  }

  tags = {
    Name           = "${var.project}-activemq"
    DeploymentMode = "SINGLE_INSTANCE"
    Protocol       = "ActiveMQ"
    UseCase        = "Legacy app migration - lift and shift"
    Lab            = "40-eventbridge-mq"
  }
}

###############################################################################
# IAM ROLE - EventBridge Scheduler (for scheduled rule targeting Lambda)
#
# EventBridge Scheduler (new) uses an IAM role to invoke targets.
# Classic EventBridge rules use resource-based policies on Lambda/SQS.
# SAA-C03: Understand that EventBridge assumes an IAM role for cross-service calls.
###############################################################################

data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_invoke" {
  name               = "${var.project}-eventbridge-invoke"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json

  tags = {
    Name = "${var.project}-eventbridge-invoke"
    Lab  = "40-eventbridge-mq"
  }
}

data "aws_iam_policy_document" "eventbridge_invoke" {
  # Allow EventBridge to invoke Lambda functions with this project prefix
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project}-*"]
  }

  # Allow EventBridge to send messages to SQS queues
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ec2_events_queue.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_invoke" {
  name   = "${var.project}-eventbridge-invoke"
  role   = aws_iam_role.eventbridge_invoke.id
  policy = data.aws_iam_policy_document.eventbridge_invoke.json
}
