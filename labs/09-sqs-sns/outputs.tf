output "standard_queue_url" { value = aws_sqs_queue.standard.url }
output "fifo_queue_url" { value = aws_sqs_queue.fifo.url }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "sns_topic_arn" { value = aws_sns_topic.lab.arn }
output "sns_fifo_arn" { value = aws_sns_topic.fifo.arn }
