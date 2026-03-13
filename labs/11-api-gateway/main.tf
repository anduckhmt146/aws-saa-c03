# ============================================================
# LAB 11 - API Gateway (REST) + Lambda Integration
# API Types: REST (full), HTTP (simpler/cheaper), WebSocket
# ============================================================

data "archive_file" "lambda_zip" {

  type        = "zip"
  source_file = "${path.module}/function.py"
  output_path = "${path.module}/function.zip"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda" {
  name = "lab-api-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {

  name              = "/aws/lambda/lab-api-function"
  retention_in_days = 7
}

# Lambda function
resource "aws_lambda_function" "api" {
  function_name    = "lab-api-function"
  role             = aws_iam_role.lambda.arn
  handler          = "function.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 29 # API GW max integration timeout = 29s
  depends_on       = [aws_cloudwatch_log_group.lambda]
}

# ============================================================
# REST API GATEWAY
# Throttling: 10,000 RPS (default), burst 5,000
# Caching: 0.5 GB - 237 GB
# Stages: dev, test, prod
# ============================================================
resource "aws_api_gateway_rest_api" "lab" {
  name        = "lab-rest-api"
  description = "SAA Lab 11 - REST API"

  endpoint_configuration {
    types = ["REGIONAL"] # REGIONAL, EDGE (CloudFront), PRIVATE (VPC)
  }
}

# Resource: /items
resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  parent_id   = aws_api_gateway_rest_api.lab.root_resource_id
  path_part   = "items"
}

# Resource: /items/{id}
resource "aws_api_gateway_resource" "item" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  parent_id   = aws_api_gateway_resource.items.id
  path_part   = "{id}"
}

# GET /items
resource "aws_api_gateway_method" "get_items" {
  rest_api_id   = aws_api_gateway_rest_api.lab.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "GET"
  authorization = "NONE" # NONE, AWS_IAM, COGNITO_USER_POOLS, CUSTOM
}

resource "aws_api_gateway_integration" "get_items" {

  rest_api_id             = aws_api_gateway_rest_api.lab.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.get_items.http_method
  integration_http_method = "POST"      # Lambda always uses POST
  type                    = "AWS_PROXY" # Lambda proxy = full event passthrough
  uri                     = aws_lambda_function.api.invoke_arn
}

# POST /items
resource "aws_api_gateway_method" "post_items" {
  rest_api_id   = aws_api_gateway_rest_api.lab.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_items" {

  rest_api_id             = aws_api_gateway_rest_api.lab.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.post_items.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

# Lambda permission for API GW
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lab.execution_arn}/*/*"
}

# ============================================================
# DEPLOYMENT + STAGE
# ============================================================
resource "aws_api_gateway_deployment" "lab" {
  rest_api_id = aws_api_gateway_rest_api.lab.id

  depends_on = [
    aws_api_gateway_integration.get_items,
    aws_api_gateway_integration.post_items
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "api_gw" {

  name              = "/aws/api-gateway/lab-api"
  retention_in_days = 7
}

resource "aws_api_gateway_stage" "prod" {

  rest_api_id   = aws_api_gateway_rest_api.lab.id
  deployment_id = aws_api_gateway_deployment.lab.id
  stage_name    = "prod"

  # Enable access logging
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format          = jsonencode({ requestId = "$context.requestId", ip = "$context.identity.sourceIp", requestTime = "$context.requestTime", httpMethod = "$context.httpMethod", path = "$context.path", status = "$context.status", protocol = "$context.protocol", responseLength = "$context.responseLength" })
  }

  # Cache settings (disabled - costs money)
  # cache_cluster_enabled = true
  # cache_cluster_size    = "0.5"

  tags = { Name = "lab-api-prod-stage" }
}

# Stage-level throttling
resource "aws_api_gateway_method_settings" "prod" {
  rest_api_id = aws_api_gateway_rest_api.lab.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = 1000 # RPS
    throttling_burst_limit = 2000
    logging_level          = "INFO"
    metrics_enabled        = true
  }
}

# ============================================================
# USAGE PLAN + API KEY
# Rate limiting per client
# ============================================================
resource "aws_api_gateway_usage_plan" "lab" {
  name = "lab-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.lab.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {

    rate_limit  = 100 # RPS per API key
    burst_limit = 200
  }

  quota_settings {

    limit  = 10000 # requests per period
    period = "MONTH"
  }
}

resource "aws_api_gateway_api_key" "lab" {

  name    = "lab-api-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan_key" "lab" {

  key_id        = aws_api_gateway_api_key.lab.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.lab.id
}
