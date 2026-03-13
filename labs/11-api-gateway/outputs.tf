output "api_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/items"
}
output "api_id" { value = aws_api_gateway_rest_api.lab.id }
output "lambda_function_name" { value = aws_lambda_function.api.function_name }
output "api_key_value" {
  value     = aws_api_gateway_api_key.lab.value
  sensitive = true
}
