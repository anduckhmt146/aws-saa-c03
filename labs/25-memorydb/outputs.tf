output "cluster_endpoint" {
  description = "MemoryDB cluster endpoint"
  value       = aws_memorydb_cluster.lab_cluster.cluster_endpoint[0].address
}
output "cluster_port" {
  value = aws_memorydb_cluster.lab_cluster.cluster_endpoint[0].port
}
output "cluster_arn" {
  value = aws_memorydb_cluster.lab_cluster.arn
}
output "acl_name" {
  value = aws_memorydb_acl.lab_acl.name
}
output "subnet_group_name" {
  value = aws_memorydb_subnet_group.lab_subnet_group.name
}
