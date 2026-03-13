output "kinesis_stream_name" { value = aws_kinesis_stream.lab.name }
output "kinesis_stream_arn" { value = aws_kinesis_stream.lab.arn }
output "firehose_name" { value = aws_kinesis_firehose_delivery_stream.lab.name }
output "s3_destination_bucket" { value = aws_s3_bucket.firehose_dest.id }
output "athena_workgroup" { value = aws_athena_workgroup.lab.name }
output "athena_results_bucket" { value = aws_s3_bucket.athena_results.id }
output "glue_database" { value = aws_glue_catalog_database.lab.name }
