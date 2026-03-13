output "sagemaker_notebook_url" { value = aws_sagemaker_notebook_instance.lab.url }
output "sagemaker_endpoint_name" { value = aws_sagemaker_endpoint.lab.name }
output "ml_data_bucket" { value = aws_s3_bucket.ml_data.id }
output "ml_models_bucket" { value = aws_s3_bucket.ml_models.id }
output "lex_bot_id" { value = aws_lexv2models_bot.lab.id }
output "rekognition_project_arn" { value = aws_rekognition_project.lab.arn }
