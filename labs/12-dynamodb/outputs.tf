output "orders_table_name" {
  value = aws_dynamodb_table.orders.name
}
output "orders_table_arn" {
  value = aws_dynamodb_table.orders.arn
}
output "orders_stream_arn" {
  value = aws_dynamodb_table.orders.stream_arn
}
output "products_table_name" {
  value = aws_dynamodb_table.products.name
}
output "global_table_name" {
  value = aws_dynamodb_table.global.name
}
output "global_table_arn" {
  value = aws_dynamodb_table.global.arn
}
output "archive_table_name" {
  value = aws_dynamodb_table.archive.name
}
