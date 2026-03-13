# ============================================================
# LAB 06 - Lambda: Function, EventBridge Trigger, SQS Trigger,
#          Concurrency, Layers, Lambda@Edge concept
# All resources are destroy-safe
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Zip the Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/function.py"
  output_path = "${path.module}/function.zip"
}

# ============================================================
# IAM ROLE FOR LAMBDA
# ============================================================
resource "aws_iam_role" "lambda" {
  name = "lab-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {

  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {

  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# ============================================================
# CLOUDWATCH LOG GROUP (explicit, so it's deleted on destroy)
# ============================================================
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/lab-function"
  retention_in_days = 7
}

# ============================================================
# LAMBDA FUNCTION
# Runtimes: Python, Node.js, Java, Go, Ruby, C#, PowerShell
# Max execution time: 15 minutes
# Memory: 128 MB - 10 GB
# Pricing: pay per request + compute (GB-seconds)
# Free tier: 1M requests/month + 400,000 GB-seconds
# ============================================================
resource "aws_lambda_function" "lab" {
  function_name = "lab-function"
  role          = aws_iam_role.lambda.arn
  handler       = "function.handler"
  runtime       = var.lambda_runtime

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = 30  # seconds (max 900 = 15 min)
  memory_size = 256 # MB (128 MB - 10240 MB)

  environment {
    variables = {
      ENVIRONMENT = "lab"
      LOG_LEVEL   = "INFO"

    }
  }

  # Concurrency limits:
  # Reserved Concurrency = guarantee capacity, cap max
  # Provisioned Concurrency = pre-warmed (eliminates cold start)
  reserved_concurrent_executions = 10 # 0 = throttle all, -1 = unrestricted

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_basic
  ]

  tags = { Name = "lab-function" }
}

# ============================================================
# EVENTBRIDGE (CloudWatch Events) TRIGGER
# Use case: scheduled tasks (cron), event-driven workflows
# Invocation type: Asynchronous
# ============================================================
resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "lab-lambda-schedule"
  description         = "Trigger Lambda every 5 minutes"
  schedule_expression = "rate(5 minutes)" # or cron(0 8 * * ? *)
}

resource "aws_cloudwatch_event_target" "lambda" {

  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "LambdaTarget"
  arn       = aws_lambda_function.lab.arn
}

resource "aws_lambda_permission" "eventbridge" {

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lab.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# ============================================================
# SQS QUEUE (Event Source Mapping)
# Invocation type: Event Source Mapping (Lambda polls SQS)
# Use case: async processing, decoupling
# ============================================================
resource "aws_sqs_queue" "trigger" {
  name                       = "lab-lambda-trigger-queue"
  message_retention_seconds  = 86400 # 1 day
  visibility_timeout_seconds = 60    # Must be >= Lambda timeout

  tags = { Name = "lab-lambda-trigger-queue" }
}

# Event Source Mapping: Lambda polls SQS
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.trigger.arn
  function_name    = aws_lambda_function.lab.arn
  batch_size       = 10
  enabled          = true
}

# ============================================================
# S3 TRIGGER (Asynchronous invocation)
# Use case: process uploaded files
# ============================================================
resource "aws_s3_bucket" "trigger" {
  bucket        = "lab-lambda-trigger-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_lambda_permission" "s3" {

  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lab.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.trigger.arn
}

resource "aws_s3_bucket_notification" "trigger" {

  bucket = aws_s3_bucket.trigger.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.lab.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.s3]
}

# ============================================================
# LAMBDA ALIAS + VERSION
# Version = immutable snapshot of function code + config
# Alias = pointer to version (blue/green deployments)
# ============================================================
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.lab.function_name
  function_version = "$LATEST"

  # Traffic shifting (canary deployment)
  # routing_config {
  #   additional_version_weights = {
  #     "2" = 0.1  # 10% to v2, 90% to live
  #   }
  # }
}

# ============================================================
# DEAD LETTER QUEUE for async invocations
# If Lambda fails after retries, send to DLQ
# ============================================================
resource "aws_sqs_queue" "dlq" {
  name                      = "lab-lambda-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = { Name = "lab-lambda-dlq" }
}

resource "aws_lambda_function_event_invoke_config" "lab" {

  function_name = aws_lambda_function.lab.function_name

  maximum_retry_attempts = 2 # 0, 1, or 2 (default 2 for async)

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn

    }
  }
}
