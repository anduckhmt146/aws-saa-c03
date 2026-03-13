output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}
output "eks_cluster_arn" {
  value = aws_eks_cluster.main.arn
}
output "eks_cluster_version" {
  value = aws_eks_cluster.main.version
}
output "kubeconfig_certificate_authority" {
  value     = aws_eks_cluster.main.certificate_authority[0].data
  sensitive = true
}
output "node_group_arn" {
  value = aws_eks_node_group.main.arn
}
output "fargate_profile_arn" {
  value = aws_eks_fargate_profile.app.arn
}
