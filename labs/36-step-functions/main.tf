# =============================================================================
# LAB 36: AWS STEP FUNCTIONS — SERVERLESS WORKFLOW ORCHESTRATION
# =============================================================================
#
# SAA-C03 EXAM TOPICS COVERED:
#
# WHAT IS STEP FUNCTIONS?
#   - Fully managed serverless orchestration service
#   - Coordinates Lambda functions, ECS tasks, SNS, SQS, DynamoDB, Glue, and
#     many other AWS services into visual, auditable workflows
#   - Workflows defined in Amazon States Language (ASL) — a JSON format
#   - Each step in a workflow is a STATE; states transition based on input,
#     output, or error conditions
#   - SAA-C03 KEY: Use Step Functions instead of chaining Lambda functions
#     (Lambda → Lambda via SDK calls) to get retry logic, error handling,
#     visibility, and audit history without writing that code in Lambda itself
#
# STANDARD vs EXPRESS WORKFLOWS (highest-frequency comparison on exam):
# ┌──────────────────────┬──────────────────────────┬──────────────────────────┐
# │ Feature              │ Standard                 │ Express                  │
# ├──────────────────────┼──────────────────────────┼──────────────────────────┤
# │ Execution semantics  │ Exactly-once             │ At-least-once            │
# │ Max duration         │ 1 year                   │ 5 minutes                │
# │ Execution history    │ 90 days in SF console    │ CloudWatch Logs ONLY     │
# │ Pricing              │ Per state transition      │ Per execution + duration │
# │ Throughput           │ 2,000 executions/sec      │ 100,000+ executions/sec  │
# │ Idempotency required │ No (exactly-once)        │ Yes (at-least-once)      │
# │ Use cases            │ Order processing, ML      │ IoT, streaming, API GW   │
# └──────────────────────┴──────────────────────────┴──────────────────────────┘
# SAA-C03 RULE:
#   "Long-running or needs audit trail" → Standard Workflow
#   "High volume, short duration, events/IoT" → Express Workflow
#
# STATE TYPES (memorize all 8 for the exam):
#   Task     : Calls an AWS service (Lambda, ECS, SQS, DynamoDB, Glue, etc.)
#   Choice   : Conditional branching — evaluate rules, route to different states
#              (no Retry, no Catch, no Next field — uses Rules + Default)
#   Wait     : Pause execution for a fixed duration or until a timestamp
#   Parallel : Run multiple branches simultaneously; waits for ALL to complete
#   Map      : Iterate over an array; run the same states for each element
#   Pass     : Pass input to output unchanged; inject static data; no service call
#   Succeed  : Terminal state — marks execution as successful
#   Fail     : Terminal state — marks execution as failed with error + cause
#
# ERROR HANDLING IN STEP FUNCTIONS:
#   Retry block (on a Task/Parallel/Map state):
#     - IntervalSeconds : initial wait before first retry (default: 1)
#     - MaxAttempts     : how many times to retry (default: 3; 0 = no retry)
#     - BackoffRate     : multiply wait time by this factor each retry (default: 2)
#     - MaxDelaySeconds : cap on the wait between retries
#     - ErrorEquals     : which error codes trigger this retry rule
#     SAA-C03: Step Functions handles retry/backoff — Lambda code stays clean
#   Catch block (on a Task/Parallel/Map state):
#     - ErrorEquals : which errors trigger this catch
#     - Next        : which state to transition to for error handling
#     - ResultPath  : where to store the error info in the execution input
#     SAA-C03: Catch allows routing failures to compensation/notification states
#   Error codes:
#     States.ALL           : matches any error (wildcard catch-all)
#     States.TaskFailed    : task threw an unhandled error
#     States.Timeout       : execution exceeded TimeoutSeconds
#     States.HeartbeatTimeout : heartbeat not received within HeartbeatSeconds
#     Lambda.TooManyRequestsException : Lambda throttling
#
# ACTIVITY WORKERS vs LAMBDA:
#   Lambda (most common): Step Functions invokes Lambda synchronously or async
#   Activity Workers: poll for tasks from Step Functions using GetActivityTask API;
#     worker can be on-premises, EC2, or any compute; no direct invocation needed
#     SAA-C03: Activity workers = "pull model" for on-premises or legacy systems
#
# INTEGRATION PATTERNS:
#   RequestResponse (default):
#     - Call the service, receive HTTP 202 (accepted), move to next state
#     - Does NOT wait for the underlying job to complete
#     - Use for: fire-and-forget (e.g., start a Glue job, do not wait)
#   .sync (Optimistic Locking):
#     - Start a long-running job AND wait for it to fully complete
#     - Step Functions polls for job status automatically
#     - Use for: Glue ETL jobs, ECS tasks, SageMaker training, Athena queries
#     - Resource ARN suffix: arn:aws:states:::glue:startJobRun.sync
#   .waitForTaskToken:
#     - Step Functions sends a unique task token to an external system
#     - Workflow PAUSES until that token is returned via SendTaskSuccess/Failure
#     - Use for: human approval steps, external system callbacks, async integration
#     - Token lifetime: up to 1 year (Standard); up to 5 minutes (Express)
#     - SAA-C03: "Human approval in automated workflow" → waitForTaskToken
#
# X-RAY TRACING:
#   - Enable tracing_configuration { enabled = true } on the state machine
#   - X-Ray traces individual state transitions and Lambda invocations
#   - Provides end-to-end latency visibility across the entire workflow
#   - SAA-C03: Enable X-Ray on Step Functions for distributed tracing of workflows
#
# IAM EXECUTION ROLE:
#   - Step Functions assumes this role at runtime to call integrated services
#   - Must include permissions for every service called in the state machine:
#     lambda:InvokeFunction, sns:Publish, sqs:SendMessage, logs:* (Express), etc.
#   - Trust policy: principal = states.amazonaws.com
#   - SAA-C03: Least-privilege — only grant actions for services actually used
#
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "lab36"
}

# ===========================================================================================
# SECTION 1: IAM — LAMBDA EXECUTION ROLE
# ===========================================================================================

# SAA-C03: Lambda needs an IAM execution role to:
#   1. Write logs to CloudWatch Logs (AWSLambdaBasicExecutionRole)
#   2. Access any other AWS services the function uses
# Keep Lambda roles minimal — Step Functions handles orchestration permissions separately.

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-lambda-exec-role"
  }
}

# AWSLambdaBasicExecutionRole: grants logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ===========================================================================================
# SECTION 2: IAM — STEP FUNCTIONS EXECUTION ROLE
# ===========================================================================================

# SAA-C03: Step Functions assumes this role to call integrated services.
# The trust policy must list states.amazonaws.com as the principal.
# Grant only the permissions needed by services called in your state machines.
# If a state machine calls Lambda + SNS + logs (for Express), all three must be here.

resource "aws_iam_role" "sfn_exec" {
  name = "${local.name_prefix}-sfn-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-sfn-exec-role"
  }
}

resource "aws_iam_role_policy" "sfn_permissions" {
  name = "${local.name_prefix}-sfn-permissions"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SAA-C03: InvokeFunction needed for every Lambda Task state.
        # Scope to specific function ARN patterns using name prefix.
        Sid    = "InvokeLambdaFunctions"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.name_prefix}-*"
        ]
      },
      {
        # SAA-C03: SNS Publish needed for waitForTaskToken human approval pattern
        # where the task token is sent to an SNS topic for human review
        Sid    = "PublishToSNS"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          "arn:aws:sns:${local.region}:${local.account_id}:${local.name_prefix}-*"
        ]
      },
      {
        # SAA-C03: Express workflows REQUIRE CloudWatch Logs permissions —
        # they have NO built-in 90-day execution history like Standard workflows.
        # Standard workflows also benefit from logging for debugging.
        Sid    = "CloudWatchLogsForExpressWorkflow"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:DescribeResourcePolicies",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:UpdateLogDelivery"
        ]
        Resource = ["*"]
      },
      {
        # SAA-C03: X-Ray permissions allow Step Functions to send trace segments
        # for end-to-end distributed tracing across state transitions and Lambda calls
        Sid    = "XRayTracingAccess"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ===========================================================================================
# SECTION 3: LAMBDA FUNCTIONS (INLINE PYTHON — NO EXTERNAL ZIP NEEDED)
# ===========================================================================================
#
# SAA-C03: Each Lambda here represents one Task state in the state machines.
# In production these would be separate function repos/files.
# Key exam point: Lambda code is SIMPLE because Step Functions owns:
#   - Retry logic (Retry block in ASL)
#   - Error routing (Catch block in ASL)
#   - Sequencing and branching (Next / Choice states)
#   - Execution audit trail (90-day history or CloudWatch Logs)

# ── ARCHIVE FILE DATA SOURCES (inline Python — no zip files on disk needed) ──

data "archive_file" "validate_order" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-validate-order.zip"
  source {
    content  = <<-PYTHON
      import json, random

      def handler(event, context):
          """
          SAA-C03: Task state calls this Lambda synchronously.
          Step Functions waits for the return value before advancing.
          Lambda keeps business logic only — no retry/error-routing code.
          """
          print(f"Validating order: {json.dumps(event)}")
          return {
              "orderId": event.get("orderId", f"ORD-{random.randint(1000,9999)}"),
              "orderValue": event.get("orderValue", 150.00),
              "customerId": event.get("customerId", "CUST-001"),
              "items": event.get("items", [{"sku": "ITEM-A", "qty": 2, "price": 75.00}]),
              "status": "validated"
          }
    PYTHON
    filename = "index.py"
  }
}

data "archive_file" "charge_payment" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-charge-payment.zip"
  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          """
          SAA-C03: Payment processing step.
          In a real system this calls an external payment gateway.
          The waitForTaskToken pattern would pause here until gateway confirms.
          Raises PaymentDeclined for Catch block demonstration.
          """
          order_value = event.get("orderData", {}).get("orderValue", 0)
          print(f"Charging payment for order value: {order_value}")
          # Simulate rare payment decline for Catch block demonstration
          if order_value < 0:
              raise Exception("PaymentDeclined: Card rejected by issuing bank")
          return {
              "transactionId": "TXN-" + str(abs(hash(str(order_value))))[:8],
              "status": "charged",
              "amount": order_value
          }
    PYTHON
    filename = "index.py"
  }
}

data "archive_file" "fulfill_order" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-fulfill-order.zip"
  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          """
          SAA-C03: Fulfillment step — runs after payment succeeds.
          In a parallel branch scenario, this runs concurrently with notify_customer.
          """
          print(f"Fulfilling order: {json.dumps(event)}")
          return {
              "warehouseId": "WH-EAST-1",
              "trackingNumber": "TRK-" + str(abs(hash(str(event))))[:10],
              "status": "fulfillment_initiated"
          }
    PYTHON
    filename = "index.py"
  }
}

data "archive_file" "notify_customer" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-notify-customer.zip"
  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          """
          SAA-C03: Notification step — runs in a Parallel branch alongside fulfill_order.
          Step Functions waits for BOTH branches to complete before advancing.
          """
          print(f"Sending notification for event: {json.dumps(event)}")
          return {
              "channel": "email",
              "status": "sent",
              "recipient": event.get("customerId", "unknown")
          }
    PYTHON
    filename = "index.py"
  }
}

data "archive_file" "process_batch_item" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-process-batch-item.zip"
  source {
    content  = <<-PYTHON
      import json, time

      def handler(event, context):
          """
          SAA-C03: Called by Map state — runs once PER ITEM in the input array.
          Each invocation is independent (can run in parallel via MaxConcurrency).
          Idempotency is important: Map state may retry individual items on failure.
          """
          item = event.get("item", {})
          print(f"Processing batch item: {json.dumps(item)}")
          return {
              "itemId": item.get("id", "unknown"),
              "processedAt": str(time.time()),
              "result": "processed",
              "checksumVerified": True
          }
    PYTHON
    filename = "index.py"
  }
}

data "archive_file" "express_handler" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-express-handler.zip"
  source {
    content  = <<-PYTHON
      import json

      def handler(event, context):
          """
          SAA-C03: Express Workflow handler — designed for high-volume, short-duration events.
          Must be IDEMPOTENT because Express workflows have at-least-once semantics.
          Idempotent: running the same event multiple times produces the same result.
          """
          event_type = event.get("eventType", "UNKNOWN")
          print(f"Express handler processing event type: {event_type}")
          return {
              "eventType": event_type,
              "processed": True,
              "idempotencyNote": "at-least-once — this handler is safe to retry"
          }
    PYTHON
    filename = "index.py"
  }
}

# ── LAMBDA FUNCTION RESOURCES ─────────────────────────────────────────────────

resource "aws_lambda_function" "validate_order" {
  function_name    = "${local.name_prefix}-validate-order"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.validate_order.output_path
  source_code_hash = data.archive_file.validate_order.output_base64sha256
  timeout          = 30

  tags = {
    Name    = "${local.name_prefix}-validate-order"
    Purpose = "Task state: validates incoming order data structure and business rules"
  }
}

resource "aws_lambda_function" "charge_payment" {
  function_name    = "${local.name_prefix}-charge-payment"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.charge_payment.output_path
  source_code_hash = data.archive_file.charge_payment.output_base64sha256
  timeout          = 30

  tags = {
    Name    = "${local.name_prefix}-charge-payment"
    Purpose = "Task state: charges payment; demonstrates Retry + Catch error handling"
  }
}

resource "aws_lambda_function" "fulfill_order" {
  function_name    = "${local.name_prefix}-fulfill-order"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.fulfill_order.output_path
  source_code_hash = data.archive_file.fulfill_order.output_base64sha256
  timeout          = 30

  tags = {
    Name    = "${local.name_prefix}-fulfill-order"
    Purpose = "Task state: initiates warehouse fulfillment; runs in Parallel branch"
  }
}

resource "aws_lambda_function" "notify_customer" {
  function_name    = "${local.name_prefix}-notify-customer"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.notify_customer.output_path
  source_code_hash = data.archive_file.notify_customer.output_base64sha256
  timeout          = 30

  tags = {
    Name    = "${local.name_prefix}-notify-customer"
    Purpose = "Task state: sends confirmation email; runs in Parallel branch alongside fulfill"
  }
}

resource "aws_lambda_function" "process_batch_item" {
  function_name    = "${local.name_prefix}-process-batch-item"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.process_batch_item.output_path
  source_code_hash = data.archive_file.process_batch_item.output_base64sha256
  timeout          = 60

  tags = {
    Name    = "${local.name_prefix}-process-batch-item"
    Purpose = "Map state iterator: processes one item from the batch array per invocation"
  }
}

resource "aws_lambda_function" "express_handler" {
  function_name    = "${local.name_prefix}-express-handler"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.express_handler.output_path
  source_code_hash = data.archive_file.express_handler.output_base64sha256
  timeout          = 30

  tags = {
    Name    = "${local.name_prefix}-express-handler"
    Purpose = "Express workflow task: idempotent event handler for high-volume processing"
  }
}

# ===========================================================================================
# SECTION 4: SUPPORTING RESOURCES
# ===========================================================================================

# -----------------------------------------------------------------------------
# SNS TOPIC — HUMAN APPROVAL (waitForTaskToken PATTERN)
# -----------------------------------------------------------------------------
# SAA-C03: The human approval pattern works as follows:
#   1. Step Functions reaches a Task state with resource ending in .waitForTaskToken
#   2. Step Functions sends $$.Task.Token + payload to SNS (or SQS/Lambda/API GW)
#   3. SNS delivers the message (with the token) to a human via email/Slack/etc.
#   4. The workflow PAUSES — can wait up to 1 year (Standard workflow)
#   5. Human reviews and calls SendTaskSuccess(token, output) to approve
#      OR SendTaskFailure(token, error, cause) to reject
#   6. Workflow resumes from where it paused
# SAA-C03: This is the ONLY native human-in-the-loop pattern in Step Functions.

resource "aws_sns_topic" "manual_approval" {
  name = "${local.name_prefix}-manual-approval"

  tags = {
    Name = "${local.name_prefix}-manual-approval"
  }
}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG GROUP — EXPRESS WORKFLOW LOGGING
# -----------------------------------------------------------------------------
# SAA-C03: Express Workflows have NO execution history in the Step Functions console.
# ALL execution data goes to CloudWatch Logs — you MUST configure logging.
# Without a log group, Express workflow executions produce no observable output.
# logging_configuration.level options: OFF | ERROR | FATAL | ALL
# include_execution_data = true captures input/output at each state (useful for debugging)

resource "aws_cloudwatch_log_group" "sfn_express" {
  name              = "/aws/states/${local.name_prefix}-express-workflow"
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-sfn-express-logs"
  }
}

resource "aws_cloudwatch_log_group" "sfn_batch" {
  name              = "/aws/states/${local.name_prefix}-batch-workflow"
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-sfn-batch-logs"
  }
}

# ===========================================================================================
# SECTION 5: STATE MACHINE 1 — STANDARD WORKFLOW (ORDER PROCESSING)
# ===========================================================================================
#
# SAA-C03: Standard Workflow — choose when you need:
#   - Exactly-once execution semantics (each state runs exactly one time)
#   - Long-running processes (order processing can involve hours of wait time)
#   - 90-day execution history in the Step Functions console for auditing
#   - Human approval steps (waitForTaskToken can pause for up to 1 year)
#
# ORDER PROCESSING PIPELINE:
#   ValidateOrder → ChargePayment → FulfillAndNotify (Parallel) → OrderComplete
#
# STATE TYPES DEMONSTRATED:
#   Task    : ValidateOrder, ChargePayment, FulfillOrder, NotifyCustomer
#   Choice  : RouteByOrderValue (large orders → manual approval)
#   Wait    : WaitForInventory (simulates async inventory check)
#   Parallel: FulfillAndNotify (concurrent fulfillment + notification)
#   Succeed : OrderComplete
#   Fail    : PaymentDeclined, OrderFailed

resource "aws_sfn_state_machine" "order_workflow" {
  name     = "${local.name_prefix}-order-workflow"
  role_arn = aws_iam_role.sfn_exec.arn

  # SAA-C03: STANDARD = exactly-once, 1-year max, 90-day history, per-transition billing
  type = "STANDARD"

  # ─────────────────────────────────────────────────────────────────────────
  # AMAZON STATES LANGUAGE (ASL) DEFINITION
  # ─────────────────────────────────────────────────────────────────────────
  # SAA-C03: ASL is a JSON document. Key top-level fields:
  #   Comment : human-readable description of the state machine
  #   StartAt : name of the first state to execute
  #   States  : map of stateName → stateDefinition
  #
  # Each state definition includes:
  #   Type       : one of the 8 state types
  #   Next       : name of the next state (all non-terminal, non-Choice states)
  #   End: true  : marks this state as terminal (alternative to Next)
  #   Retry      : list of retry rules (Task, Parallel, Map only)
  #   Catch      : list of fallback routing rules (Task, Parallel, Map only)
  #   ResultPath : JSONPath where to merge the state's output into execution input

  definition = jsonencode({
    Comment = "SAA-C03 Lab36: Standard Order Processing Workflow. Demonstrates Task, Choice, Wait, Parallel, Retry, Catch, waitForTaskToken."
    StartAt = "ValidateOrder"

    States = {

      # ── TASK STATE WITH RETRY + CATCH ──────────────────────────────────────
      # SAA-C03: Task state calls an AWS service and waits for the response.
      # Resource ARN format for synchronous Lambda invocation:
      #   arn:aws:states:::lambda:invoke
      # The "Payload.$": "$" passes the entire current execution input to Lambda.
      # ResultSelector extracts specific fields from the Lambda response.
      # ResultPath controls where extracted results are placed in execution state.

      ValidateOrder = {
        Type     = "Task"
        Comment  = "SAA-C03: Task state — synchronous Lambda call; waits for response before advancing"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.validate_order.arn
          # ".$" suffix means the value is a JSONPath expression resolved at runtime
          "Payload.$" = "$"
        }
        # Extract specific fields from Lambda's response body ($.Payload)
        ResultSelector = {
          "orderId.$"    = "$.Payload.orderId"
          "orderValue.$" = "$.Payload.orderValue"
          "customerId.$" = "$.Payload.customerId"
          "items.$"      = "$.Payload.items"
        }
        # Merge extracted results into execution state under $.orderData key
        ResultPath = "$.orderData"
        Next       = "RouteByOrderValue"

        # SAA-C03: Retry block — Step Functions retries on transient errors.
        # Lambda itself needs NO retry logic — Step Functions owns this.
        # Retry sequence: wait IntervalSeconds, double (BackoffRate), cap at MaxDelaySeconds.
        # Example: 2s → 4s → 8s (capped at 30s) over MaxAttempts=3 retries.
        Retry = [
          {
            # Retry standard Lambda infrastructure errors
            ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"]
            IntervalSeconds = 2
            MaxAttempts     = 3
            BackoffRate     = 2.0
            MaxDelaySeconds = 30
            Comment         = "SAA-C03: Exponential backoff — 2s, 4s, 8s between retries"
          },
          {
            # Retry throttling separately with shorter intervals
            ErrorEquals     = ["Lambda.TooManyRequestsException"]
            IntervalSeconds = 1
            MaxAttempts     = 5
            BackoffRate     = 1.5
            MaxDelaySeconds = 10
          }
        ]

        # SAA-C03: Catch block — after all retries exhausted, route to fallback state.
        # ResultPath = "$.error" saves error details in execution context for logging.
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "OrderFailed"
            ResultPath  = "$.error"
            Comment     = "SAA-C03: Catch all errors after retries exhausted; route to failure handler"
          }
        ]
      }

      # ── CHOICE STATE ────────────────────────────────────────────────────────
      # SAA-C03: Choice state implements if/else/switch branching.
      # IMPORTANT differences from other states:
      #   - NO "Next" field at the top level (routing is inside Rules/Default)
      #   - NO Retry or Catch blocks
      # Rules are evaluated TOP TO BOTTOM; first matching rule wins.
      # Default is required unless all possible values are covered by rules.
      # Comparison operators: StringEquals, NumericGreaterThan, BooleanEquals,
      #   IsNull, IsPresent, StringMatches (wildcard), And, Or, Not

      RouteByOrderValue = {
        Type    = "Choice"
        Comment = "SAA-C03: Choice state — conditional branching; no Retry/Catch/Next; uses Rules + Default"
        Rules = [
          {
            # Large orders (> $1000) require human manager approval before charging
            Variable           = "$.orderData.orderValue"
            NumericGreaterThan = 1000
            Next               = "RequestManagerApproval"
            Comment            = "High-value orders require manual approval (waitForTaskToken)"
          }
        ]
        # Default: normal-value orders proceed directly to payment
        Default = "WaitForInventoryCheck"
      }

      # ── WAIT STATE ──────────────────────────────────────────────────────────
      # SAA-C03: Wait state pauses execution without consuming compute resources.
      # Options:
      #   Seconds         : wait a fixed number of seconds
      #   Timestamp       : wait until an absolute ISO 8601 timestamp
      #   SecondsPath     : JSONPath to a number in execution input (dynamic duration)
      #   TimestampPath   : JSONPath to a timestamp in execution input (dynamic time)
      # Use case: wait for an external system (inventory, 3PL) to become available
      # before proceeding, without polling in Lambda.

      WaitForInventoryCheck = {
        Type    = "Wait"
        Comment = "SAA-C03: Wait state — pauses execution; no compute charged during wait; can be dynamic via SecondsPath"
        # Wait 5 seconds (simulating async inventory availability check)
        Seconds = 5
        Next    = "ChargePayment"
      }

      # ── waitForTaskToken: HUMAN APPROVAL ────────────────────────────────────
      # SAA-C03: .waitForTaskToken integration pattern.
      # Step Functions embeds $$.Task.Token in the SNS message payload.
      # The workflow PAUSES until someone calls:
      #   SendTaskSuccess(taskToken, output) → resumes at Next state
      #   SendTaskFailure(taskToken, error, cause) → triggers Catch block
      # HeartbeatSeconds: if token holder goes silent for N seconds, TaskTimedOut error.
      # Max wait time: 1 year for Standard workflows (perfect for async human approval).
      # SAA-C03: This is the canonical "human in the loop" pattern in Step Functions.

      RequestManagerApproval = {
        Type    = "Task"
        Comment = "SAA-C03: waitForTaskToken — workflow pauses until manager calls SendTaskSuccess with token"
        # Note the .waitForTaskToken suffix — this changes the integration pattern
        Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
        Parameters = {
          TopicArn = aws_sns_topic.manual_approval.arn
          Message = {
            # $$.Task.Token: special context object reference for the current task token
            # This token MUST be included in the message — approver needs it to resume workflow
            "taskToken.$"  = "$$.Task.Token"
            "orderId.$"    = "$.orderData.orderId"
            "orderValue.$" = "$.orderData.orderValue"
            instruction    = "Please approve or reject this high-value order"
          }
        }
        # SAA-C03: HeartbeatSeconds = timeout if no activity (not just no completion)
        # After 24 hours of silence, the task raises States.HeartbeatTimeout
        HeartbeatSeconds = 86400
        ResultPath       = "$.approvalResult"
        Next             = "ChargePayment"

        Catch = [
          {
            # Catch timeout or explicit rejection
            ErrorEquals = ["States.HeartbeatTimeout", "States.TaskFailed"]
            Next        = "OrderFailed"
            ResultPath  = "$.error"
          }
        ]
      }

      ChargePayment = {
        Type     = "Task"
        Comment  = "SAA-C03: Retry + Catch for payment — transient errors retried; business errors caught"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.charge_payment.arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "transactionId.$" = "$.Payload.transactionId"
          "status.$"        = "$.Payload.status"
        }
        ResultPath = "$.paymentResult"
        Next       = "FulfillAndNotify"

        Retry = [
          {
            # Retry payment gateway timeouts with exponential backoff
            ErrorEquals     = ["Lambda.TooManyRequestsException", "Lambda.ServiceException"]
            IntervalSeconds = 5
            MaxAttempts     = 3
            BackoffRate     = 2.0
            MaxDelaySeconds = 60
          }
        ]

        Catch = [
          {
            # PaymentDeclined is a business error — do NOT retry, route to failure state
            # SAA-C03: Separate business errors (Catch) from transient errors (Retry)
            ErrorEquals = ["PaymentDeclined"]
            Next        = "PaymentDeclined"
            ResultPath  = "$.error"
          },
          {
            # Catch-all for any other payment error
            ErrorEquals = ["States.ALL"]
            Next        = "OrderFailed"
            ResultPath  = "$.error"
          }
        ]
      }

      PaymentDeclined = {
        Type  = "Fail"
        Error = "PaymentDeclined"
        Cause = "Payment was declined by the payment processor; customer should update payment method"
      }

      # ── PARALLEL STATE ───────────────────────────────────────────────────────
      # SAA-C03: Parallel state runs multiple independent branches simultaneously.
      # ALL branches start at the same time with the SAME input.
      # The state does NOT advance to Next until ALL branches complete.
      # If ANY branch fails (after Retry exhausted), the entire Parallel state fails.
      # ResultPath merges each branch's final output into an array.
      # Use case: send notification AND update DB at the same time → faster than sequential.
      # SAA-C03: Parallel ≠ Map. Parallel = fixed set of branches; Map = dynamic array.

      FulfillAndNotify = {
        Type    = "Parallel"
        Comment = "SAA-C03: Parallel state — both branches start simultaneously; Next only when ALL succeed"
        Branches = [
          {
            # Branch 1: Warehouse fulfillment
            StartAt = "FulfillOrder"
            States = {
              FulfillOrder = {
                Type     = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = {
                  FunctionName = aws_lambda_function.fulfill_order.arn
                  "Payload.$"  = "$"
                }
                Retry = [
                  {
                    ErrorEquals     = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"]
                    IntervalSeconds = 2
                    MaxAttempts     = 3
                    BackoffRate     = 2.0
                  }
                ]
                End = true
              }
            }
          },
          {
            # Branch 2: Customer notification — runs concurrently with fulfillment
            StartAt = "NotifyCustomer"
            States = {
              NotifyCustomer = {
                Type     = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = {
                  FunctionName = aws_lambda_function.notify_customer.arn
                  "Payload.$"  = "$"
                }
                Retry = [
                  {
                    ErrorEquals     = ["Lambda.TooManyRequestsException"]
                    IntervalSeconds = 1
                    MaxAttempts     = 3
                    BackoffRate     = 2.0
                  }
                ]
                End = true
              }
            }
          }
        ]
        ResultPath = "$.fulfillmentResults"
        Next       = "OrderComplete"
      }

      # ── SUCCEED STATE ────────────────────────────────────────────────────────
      # SAA-C03: Succeed is an explicit terminal state marking successful completion.
      # It shows "SUCCEEDED" in the execution history with a green indicator.
      # Alternative: End: true on a Task state — functionally equivalent but
      # less visible in the workflow graph visualization.

      OrderComplete = {
        Type    = "Succeed"
        Comment = "SAA-C03: Succeed state — terminal; marks execution SUCCEEDED in 90-day audit history"
      }

      # ── FAIL STATE ───────────────────────────────────────────────────────────
      # SAA-C03: Fail is an explicit terminal state marking failed completion.
      # Error and Cause are visible in the execution history for debugging.
      # Fail states cannot have Retry or Catch — they immediately terminate.

      OrderFailed = {
        Type  = "Fail"
        Error = "OrderProcessingFailed"
        Cause = "Order processing encountered an unrecoverable error — check execution history for details"
      }
    }
  })

  # SAA-C03: X-Ray tracing tracks latency across each state transition and Lambda call.
  # View traces in X-Ray console to find slow states or high-latency Lambda functions.
  tracing_configuration {
    enabled = true
  }

  tags = {
    Name     = "${local.name_prefix}-order-workflow"
    Workflow = "STANDARD"
    Pattern  = "exactly-once, 1-year max, 90-day execution history"
  }
}

# ===========================================================================================
# SECTION 6: STATE MACHINE 2 — EXPRESS WORKFLOW (HIGH-THROUGHPUT EVENT PROCESSING)
# ===========================================================================================
#
# SAA-C03: Express Workflow — choose when you need:
#   - High throughput: 100,000+ executions per second (IoT, streaming)
#   - Short duration: each execution completes in under 5 minutes
#   - Lower per-execution cost (billed per execution + duration, not per transition)
#   - At-least-once semantics (Lambda functions MUST be idempotent)
#
# EXAM TRAP: Express workflows do NOT have 90-day history in the console.
# You MUST configure logging_configuration pointing to a CloudWatch log group.
# Without logging, you have zero visibility into Express executions.
#
# COMMON EXPRESS WORKFLOW USE CASES (exam favorites):
#   - IoT device telemetry processing (millions of events/day)
#   - Streaming data enrichment (Kinesis → Step Functions → DynamoDB)
#   - API Gateway backend orchestration (one Express execution per API call)
#   - High-volume data validation pipelines

resource "aws_sfn_state_machine" "express_workflow" {
  name     = "${local.name_prefix}-express-workflow"
  role_arn = aws_iam_role.sfn_exec.arn

  # SAA-C03: EXPRESS = at-least-once, 5-min max, CloudWatch Logs only, high-throughput billing
  type = "EXPRESS"

  definition = jsonencode({
    Comment = "SAA-C03 Lab36: Express Workflow — high-volume at-least-once event processing. IoT/streaming use case."
    StartAt = "ClassifyEvent"

    States = {

      # ── PASS STATE ────────────────────────────────────────────────────────
      # SAA-C03: Pass state transforms or passes input to output without calling
      # any AWS service. It is instant (no billing, no latency).
      # Use cases:
      #   - Inject static configuration values into the execution context
      #   - Format/reshape input before sending to a Lambda function
      #   - Placeholder state during development (replace with Task later)
      # Parameters: static or JSONPath values to set in the output
      # ResultPath: where to place the Pass output in the execution input

      ClassifyEvent = {
        Type    = "Pass"
        Comment = "SAA-C03: Pass state — no service call; reshapes input; useful for injecting defaults or reformatting"
        Parameters = {
          "eventType.$"  = "$.eventType"
          "payload.$"    = "$.payload"
          "receivedAt.$" = "$$.Execution.StartTime"
          classification = "inbound-event"
          processingTier = "express"
        }
        ResultPath = "$.classified"
        Next       = "RouteByEventType"
      }

      RouteByEventType = {
        Type    = "Choice"
        Comment = "Route event to the appropriate handler based on event type"
        Rules = [
          {
            Variable     = "$.classified.eventType"
            StringEquals = "SENSOR_READING"
            Next         = "ProcessSensorReading"
          },
          {
            Variable     = "$.classified.eventType"
            StringEquals = "ALERT"
            Next         = "ProcessAlert"
          },
          {
            Variable      = "$.classified.eventType"
            StringMatches = "ORDER_*"
            Next          = "ProcessOrderEvent"
          }
        ]
        Default = "DiscardUnknownEvent"
      }

      ProcessSensorReading = {
        Type     = "Task"
        Comment  = "SAA-C03: Express task — idempotent handler for at-least-once semantics"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.express_handler.arn
          "Payload.$"  = "$"
        }
        Retry = [
          {
            # SAA-C03: Short retry intervals for Express (max 5 min total execution time)
            ErrorEquals     = ["Lambda.TooManyRequestsException"]
            IntervalSeconds = 1
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        End = true
      }

      ProcessAlert = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.express_handler.arn
          "Payload.$"  = "$"
        }
        End = true
      }

      ProcessOrderEvent = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.express_handler.arn
          "Payload.$"  = "$"
        }
        End = true
      }

      # SAA-C03: Pass state as a no-op terminal — acknowledges the event
      # without error but discards it (no Lambda call, no cost).
      DiscardUnknownEvent = {
        Type    = "Pass"
        Comment = "SAA-C03: Unknown event type — Pass state discards gracefully without error"
        Result = {
          status = "discarded"
          reason = "Event type not recognized by routing rules"
        }
        End = true
      }
    }
  })

  # SAA-C03: Logging is MANDATORY for Express workflows.
  # level = "ALL" captures every state transition and Lambda I/O.
  # include_execution_data = true records actual input/output values (helpful for debugging).
  # NOTE: CloudWatch Logs pricing applies — use retention_in_days to control cost.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_express.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = {
    Name     = "${local.name_prefix}-express-workflow"
    Workflow = "EXPRESS"
    Pattern  = "at-least-once, 5-min max, CloudWatch Logs only, high-throughput"
  }
}

# ===========================================================================================
# SECTION 7: STATE MACHINE 3 — MAP STATE (PARALLEL BATCH PROCESSING)
# ===========================================================================================
#
# SAA-C03: Map state iterates over an input ARRAY and runs the same set of states
# for EACH element, potentially in parallel.
#
# MAP STATE vs PARALLEL STATE — KEY DISTINCTION:
#   Map state:      dynamic — number of iterations = size of the input array
#   Parallel state: static  — number of branches defined at design time in ASL
#   SAA-C03: "Process each item in a list" → Map state
#   SAA-C03: "Run task A and task B concurrently" → Parallel state
#
# MAP STATE PARAMETERS:
#   ItemsPath      : JSONPath to the array in execution input (e.g., "$.items")
#   ItemSelector   : reshape each element + add context before passing to Iterator
#   MaxConcurrency : max simultaneous iterations (0 = unlimited; N = bounded)
#   ResultPath     : where to place the array of all iteration results
#   Iterator       : the sub-state-machine to run for each array element
#
# MAX CONCURRENCY:
#   0  = all iterations run simultaneously (fastest; watch Lambda concurrency limits)
#   N  = at most N iterations at a time (throttle to protect downstream services)
#   SAA-C03: Set MaxConcurrency to match your Lambda reserved concurrency limit
#
# DISTRIBUTED MAP (newer feature — exam awareness):
#   Inline Map (this lab): up to 40 concurrent iterations; input comes from execution
#   Distributed Map: up to 10,000 concurrent iterations; can read from S3 directly
#   SAA-C03: "Process millions of S3 objects in parallel" → Distributed Map state

resource "aws_sfn_state_machine" "batch_workflow" {
  name     = "${local.name_prefix}-batch-workflow"
  role_arn = aws_iam_role.sfn_exec.arn

  # SAA-C03: Standard workflow for batch processing —
  # batch jobs often run longer than 5 minutes, ruling out Express.
  # Exactly-once semantics ensure each item is processed exactly one time.
  type = "STANDARD"

  definition = jsonencode({
    Comment = "SAA-C03 Lab36: Map State Batch Processing Workflow. Demonstrates Map (parallel iteration), MaxConcurrency, and distributed processing patterns."
    StartAt = "PrepareBatch"

    States = {

      # Inject metadata and normalize the batch before processing
      PrepareBatch = {
        Type    = "Pass"
        Comment = "SAA-C03: Pass state — normalize batch input; inject batch ID and timestamp"
        Parameters = {
          "items.$"   = "$.items"
          "batchId.$" = "$$.Execution.Name"
          metadata = {
            source    = "lab36-batch-workflow"
            batchSize = "dynamic — determined at runtime from items array length"
          }
        }
        Next = "ProcessAllItems"
      }

      # ── MAP STATE ────────────────────────────────────────────────────────────
      # SAA-C03: This Map state calls process_batch_item Lambda ONCE PER ITEM.
      # If items = [A, B, C, D, E] and MaxConcurrency = 3:
      #   Iteration 1: A, B, C run in parallel
      #   Iteration 2: D, E run (after A, B, or C completes to free a slot)
      # All iteration results are collected into an array at $.batchResults.

      ProcessAllItems = {
        Type      = "Map"
        Comment   = "SAA-C03: Map state — runs Lambda once per array element; MaxConcurrency bounds parallelism"
        ItemsPath = "$.items"

        # ItemSelector: called for each element to build the input passed to Iterator
        # $$.Map.Item.Value: the current array element value
        # $$.Map.Item.Index: the current 0-based index (useful for logging)
        ItemSelector = {
          "item.$"      = "$$.Map.Item.Value"
          "itemIndex.$" = "$$.Map.Item.Index"
          "batchId.$"   = "$.batchId"
        }

        # SAA-C03: MaxConcurrency = 5 means at most 5 Lambda invocations at once.
        # Set this to your Lambda function's reserved concurrency to avoid throttling.
        # MaxConcurrency = 0 means "no limit" — use carefully with large arrays.
        MaxConcurrency = 5

        # ResultPath: the array of all iteration outputs is stored here
        ResultPath = "$.batchResults"

        # Iterator: the sub-state-machine run for each item
        # Each iteration is independent — failures in one do NOT stop others
        # (unless ToleratedFailurePercentage is set — a newer Distributed Map feature)
        Iterator = {
          StartAt = "ProcessItem"
          States = {
            ProcessItem = {
              Type     = "Task"
              Comment  = "SAA-C03: Iterator task — runs once per array element; idempotent for safety"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.process_batch_item.arn
                "Payload.$"  = "$"
              }
              ResultSelector = {
                "itemId.$"      = "$.Payload.itemId"
                "result.$"      = "$.Payload.result"
                "processedAt.$" = "$.Payload.processedAt"
              }
              Retry = [
                {
                  # SAA-C03: Retry each item independently on transient Lambda errors
                  ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.TooManyRequestsException"]
                  IntervalSeconds = 2
                  MaxAttempts     = 3
                  BackoffRate     = 2.0
                }
              ]
              Catch = [
                {
                  # On permanent failure, store error and end this iteration gracefully
                  # Other iterations continue — one bad item does not cancel the batch
                  ErrorEquals = ["States.ALL"]
                  Next        = "ItemFailed"
                  ResultPath  = "$.itemError"
                }
              ]
              End = true
            }

            # Mark this individual item as failed without stopping the entire Map state
            ItemFailed = {
              Type    = "Pass"
              Comment = "SAA-C03: Use Pass (not Fail) in iterator to mark item as failed without aborting the entire Map"
              Result = {
                result = "failed"
                reason = "Item processing failed after all retries"
              }
              End = true
            }
          }
        }

        Next = "SummarizeBatch"
      }

      # After all items are processed, aggregate results and report
      SummarizeBatch = {
        Type     = "Task"
        Comment  = "SAA-C03: Post-Map aggregation task — $.batchResults contains array of all iteration outputs"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.notify_customer.arn
          # Pass batch results array to summary Lambda for aggregation
          Payload = {
            "batchId.$"     = "$.batchId"
            "results.$"     = "$.batchResults"
            summaryRequired = true
          }
        }
        ResultPath = "$.summaryResult"
        Next       = "BatchComplete"
      }

      BatchComplete = {
        Type    = "Succeed"
        Comment = "SAA-C03: Succeed state — all batch items processed; results available in $.batchResults"
      }
    }
  })

  # SAA-C03: X-Ray enabled for batch workflows helps trace individual
  # Lambda invocations within the Map state iterations
  tracing_configuration {
    enabled = true
  }

  tags = {
    Name     = "${local.name_prefix}-batch-workflow"
    Workflow = "STANDARD"
    Pattern  = "Map state parallel batch processing with MaxConcurrency"
  }
}

# ===========================================================================================
# SECTION 8: CLOUDWATCH ALARM — OPERATIONAL MONITORING
# ===========================================================================================

# SAA-C03: Step Functions publishes metrics to CloudWatch under the AWS/States namespace.
# Key metrics:
#   ExecutionsFailed   : number of failed executions (alert on > 0 for production)
#   ExecutionsTimedOut : executions that exceeded TimeoutSeconds
#   ExecutionThrottled : executions throttled by Step Functions service limits
#   ExecutionsStarted  : total executions started (useful for throughput monitoring)

resource "aws_cloudwatch_metric_alarm" "order_workflow_failures" {
  alarm_name          = "${local.name_prefix}-order-workflow-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alert on any failed Standard order workflow execution"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.order_workflow.arn
  }

  tags = {
    Name = "${local.name_prefix}-order-workflow-failures-alarm"
  }
}
