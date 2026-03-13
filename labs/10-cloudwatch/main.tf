# ============================================================
# LAB 10 - CloudWatch: Alarms, Log Groups, Dashboards,
#          CloudFormation (IaC), Systems Manager
# ============================================================

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# SNS TOPIC FOR ALARMS
# ============================================================
resource "aws_sns_topic" "alarms" {
  name = "lab-cloudwatch-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ============================================================
# CLOUDWATCH LOG GROUPS
# Retention: 1 day to 10 years (or never expire)
# ============================================================
resource "aws_cloudwatch_log_group" "app" {
  name              = "/app/lab-application"
  retention_in_days = 7
  tags              = { Name = "lab-app-logs" }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/app/lab-access"
  retention_in_days = 30
}

# ============================================================
# LOG METRIC FILTER
# Extract metrics from log data
# e.g., count ERROR lines → custom metric
# ============================================================
resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "lab-error-count"
  pattern        = "[timestamp, request_id, level=ERROR, ...]"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "ErrorCount"
    namespace     = "LabApp"
    value         = "1"
    default_value = "0"
  }
}

# ============================================================
# CLOUDWATCH ALARMS
# States: OK, ALARM, INSUFFICIENT_DATA
# Period: 10, 30, or multiple of 60 seconds
# ============================================================

# CPU alarm (EC2 built-in metric)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "lab-cpu-high"
  alarm_description   = "EC2 CPU > 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = 80

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = { Name = "lab-cpu-alarm" }
}

# Custom metric alarm (from log metric filter)
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "lab-error-rate"
  alarm_description   = "Application errors > 10 in 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ErrorCount"
  namespace           = "LabApp"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
}

# Composite alarm (AND/OR conditions)
resource "aws_cloudwatch_composite_alarm" "critical" {
  alarm_name        = "lab-critical-composite"
  alarm_description = "Fires when both CPU high and errors high"

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.cpu_high.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.errors.alarm_name}\")"

  alarm_actions = [aws_sns_topic.alarms.arn]
}

# ============================================================
# CLOUDWATCH DASHBOARD
# ============================================================
resource "aws_cloudwatch_dashboard" "lab" {
  dashboard_name = "lab-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "EC2 CPU Utilization"
          period  = 300
          stat    = "Average"
          metrics = [["AWS/EC2", "CPUUtilization"]]

        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title   = "Application Errors"
          period  = 300
          stat    = "Sum"
          metrics = [["LabApp", "ErrorCount"]]

        }

      }
    ]
  })
}

# ============================================================
# CLOUDWATCH AGENT (SSM Parameter for agent config)
# CloudWatch Agent: collect custom metrics from EC2
# - Memory utilization (not built-in)
# - Disk utilization
# - Custom app metrics
# ============================================================
resource "aws_ssm_parameter" "cw_agent_config" {
  name = "/cloudwatch-agent/config"
  type = "String"
  value = jsonencode({
    metrics = {
      metrics_collected = {
        mem = { measurement = ["mem_used_percent"] }
        disk = {
          measurement = ["disk_used_percent"]
          resources   = ["/"]

        }

      }

    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [{
            file_path       = "/var/log/app/*.log"
            log_group_name  = "/app/lab-application"
            log_stream_name = "{instance_id}"
          }]

        }

      }

    }
  })
}

# ============================================================
# SYSTEMS MANAGER (SSM) PARAMETERS
# Parameter types: String, StringList, SecureString
# Use case: config management, secrets (SecureString)
# ============================================================
resource "aws_ssm_parameter" "db_password" {
  name  = "/lab/db/password"
  type  = "SecureString" # Encrypted with KMS
  value = "ChangeMe123!"
  tags  = { Name = "lab-db-password" }
}

resource "aws_ssm_parameter" "app_config" {
  name  = "/lab/app/config"
  type  = "String"
  value = jsonencode({ environment = "lab", log_level = "INFO" })
}

# ============================================================
# EC2 WITH SSM (Session Manager - no SSH needed)
# ============================================================
resource "aws_iam_role" "ec2_ssm" {
  name = "lab-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "lab-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "monitored" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = "t3.micro"
  subnet_id            = tolist(data.aws_subnets.default.ids)[0]
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum install -y amazon-cloudwatch-agent
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -s -c ssm:/cloudwatch-agent/config
  EOF
  )

  tags = { Name = "lab-monitored-instance" }
}
