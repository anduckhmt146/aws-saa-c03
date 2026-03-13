output "ecs_cluster_name" { value = aws_ecs_cluster.lab.name }
output "ecs_service_name" { value = aws_ecs_service.lab.name }
output "task_definition_arn" { value = aws_ecs_task_definition.lab.arn }
output "ecr_repository_url" { value = aws_ecr_repository.lab.repository_url }
