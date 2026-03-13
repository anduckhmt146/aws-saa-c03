output "lambda_function_name" {
  value = aws_lambda_function.lab.function_name
}

output "lambda_function_arn" {

  value = aws_lambda_function.lab.arn
}

output "lambda_invoke_arn" {

  value = aws_lambda_function.lab.invoke_arn
}

output "sqs_trigger_url" {

  value = aws_sqs_queue.trigger.url
}

output "dlq_url" {

  value = aws_sqs_queue.dlq.url
}

output "s3_trigger_bucket" {

  value = aws_s3_bucket.trigger.id
}
