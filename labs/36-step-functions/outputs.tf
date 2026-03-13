# =============================================================================
# LAB 36: OUTPUTS — AWS STEP FUNCTIONS
# =============================================================================

# ===========================================================================================
# SECTION 1: STATE MACHINE ARNs (PRIMARY OUTPUTS)
# ===========================================================================================

# SAA-C03: order_workflow_arn — Standard Workflow (exactly-once, 1-year max).
# Use this ARN to start an execution via the AWS CLI:
#   aws stepfunctions start-execution \
#     --state-machine-arn <order_workflow_arn> \
#     --input '{"orderId":"ORD-001","orderValue":150,"customerId":"C-001","items":[]}'
output "order_workflow_arn" {
  description = "ARN of the Standard order processing workflow (exactly-once, 1-year max, 90-day history)"
  value       = aws_sfn_state_machine.order_workflow.arn
}

# SAA-C03: express_workflow_arn — Express Workflow (at-least-once, 5-min max).
# Express workflows are invoked the same way as Standard but have different semantics.
# Use this ARN for high-volume event-driven invocations (IoT, streaming, API GW backends).
output "express_workflow_arn" {
  description = "ARN of the Express event-processing workflow (at-least-once, 5-min max, CloudWatch Logs only)"
  value       = aws_sfn_state_machine.express_workflow.arn
}

# SAA-C03: batch_workflow_arn — Standard Workflow with Map state for batch processing.
# Invoke with an items array; Map state iterates over each element in parallel.
# Example input: {"items": [{"id":"A"},{"id":"B"},{"id":"C"}]}
output "batch_workflow_arn" {
  description = "ARN of the Standard batch processing workflow with Map state (parallel item iteration)"
  value       = aws_sfn_state_machine.batch_workflow.arn
}

# ===========================================================================================
# SECTION 2: STATE MACHINE NAMES
# ===========================================================================================

output "order_workflow_name" {
  description = "Name of the order processing state machine (use in CloudWatch dimension filters)"
  value       = aws_sfn_state_machine.order_workflow.name
}

output "express_workflow_name" {
  description = "Name of the Express event-processing state machine"
  value       = aws_sfn_state_machine.express_workflow.name
}

output "batch_workflow_name" {
  description = "Name of the batch Map state processing state machine"
  value       = aws_sfn_state_machine.batch_workflow.name
}

# ===========================================================================================
# SECTION 3: IAM OUTPUTS
# ===========================================================================================

# SAA-C03: The Step Functions execution role ARN is useful when writing additional
# inline policies or granting the role access to new services used in state machines.
output "sfn_execution_role_arn" {
  description = "IAM execution role ARN that Step Functions assumes to invoke Lambda, SNS, etc."
  value       = aws_iam_role.sfn_exec.arn
}

output "lambda_execution_role_arn" {
  description = "IAM execution role ARN used by all Lambda functions in this lab"
  value       = aws_iam_role.lambda_exec.arn
}

# ===========================================================================================
# SECTION 4: LAMBDA FUNCTION ARNs
# ===========================================================================================

# SAA-C03: These ARNs are embedded directly in the state machine definitions.
# If you update a Lambda function and redeploy, the ARNs remain stable.
# Use function versions/aliases in production for controlled deployments:
#   FunctionName = "${aws_lambda_function.validate_order.arn}:STABLE"
output "lambda_function_arns" {
  description = "ARNs of all Lambda Task functions used by the state machines"
  value = {
    validate_order     = aws_lambda_function.validate_order.arn
    charge_payment     = aws_lambda_function.charge_payment.arn
    fulfill_order      = aws_lambda_function.fulfill_order.arn
    notify_customer    = aws_lambda_function.notify_customer.arn
    process_batch_item = aws_lambda_function.process_batch_item.arn
    express_handler    = aws_lambda_function.express_handler.arn
  }
}

# ===========================================================================================
# SECTION 5: SUPPORTING RESOURCES
# ===========================================================================================

# SAA-C03: The manual approval SNS topic ARN is where the waitForTaskToken
# task sends the task token for human review. Subscribe an email endpoint to
# receive approval requests: aws sns subscribe --topic-arn <arn> --protocol email
output "manual_approval_topic_arn" {
  description = "SNS topic ARN that receives waitForTaskToken approval requests with embedded task tokens"
  value       = aws_sns_topic.manual_approval.arn
}

output "express_log_group_name" {
  description = "CloudWatch log group name for Express workflow execution logs"
  value       = aws_cloudwatch_log_group.sfn_express.name
}

output "batch_log_group_name" {
  description = "CloudWatch log group name for batch workflow execution logs"
  value       = aws_cloudwatch_log_group.sfn_batch.name
}

# ===========================================================================================
# SECTION 6: SAA-C03 EXAM QUICK REFERENCE
# ===========================================================================================

output "exam_tips" {
  description = "SAA-C03 Step Functions key decision points — run: terraform output exam_tips"
  value       = <<-EOT
    STANDARD vs EXPRESS (most-tested comparison):
      Standard  → exactly-once, 1-year max, 90-day console history, per-transition billing
      Express   → at-least-once, 5-min max, CloudWatch Logs ONLY, per-execution billing
      Choose Standard for: order processing, ETL orchestration, human approvals
      Choose Express for:  IoT events, streaming enrichment, API Gateway backends

    STATE TYPES (memorize all 8):
      Task     → calls AWS service (Lambda, ECS, SQS, DynamoDB, Glue, etc.)
      Choice   → if/else branching; NO Retry/Catch/Next; uses Rules + Default
      Wait     → pause N seconds or until timestamp; no compute cost while waiting
      Parallel → run fixed branches simultaneously; waits for ALL; any fail = all fail
      Map      → iterate over array; one iteration per element; MaxConcurrency controls parallelism
      Pass     → reshape input or inject static data; no AWS service call; instant
      Succeed  → terminal success state
      Fail     → terminal failure state (Error + Cause visible in history)

    ERROR HANDLING:
      Retry block → transient errors (throttling, infra issues); exponential backoff
      Catch block → business/permanent errors; route to fallback state
      Lambda needs NO retry code — Step Functions owns it
      ErrorEquals "States.ALL" → catch-all fallback (use as last Catch entry)

    INTEGRATION PATTERNS:
      RequestResponse  → fire-and-forget (start Glue job, do not wait)
      .sync            → start job AND wait for completion (Glue, ECS tasks, Athena)
      .waitForTaskToken → pause until external system returns task token (human approval)

    MAP vs PARALLEL:
      Map      → dynamic; iterates over array; number of branches = array length
      Parallel → static; branches defined in ASL; always same set of branches

    HUMAN APPROVAL PATTERN (waitForTaskToken):
      1. Task state resource ends in .waitForTaskToken
      2. Step Functions sends $$.Task.Token + payload to SNS/SQS/Lambda
      3. Workflow PAUSES (up to 1 year for Standard)
      4. Human calls SendTaskSuccess(token) to approve or SendTaskFailure(token) to reject
      5. Workflow resumes

    X-RAY TRACING:
      Enable tracing_configuration { enabled = true } for end-to-end distributed tracing
      View traces in X-Ray to find slow states or high-latency Lambda integrations

    IAM EXECUTION ROLE:
      Trust principal: states.amazonaws.com
      Must include: lambda:InvokeFunction, sns:Publish, logs:* (Express), xray:Put*
      Least privilege: only grant services actually used in the state machine definition
  EOT
}
