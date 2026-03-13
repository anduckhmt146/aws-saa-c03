# ============================================================
# LAB 07 - ECS: Cluster, Fargate Task, Service, ECR
# ECS = Docker container orchestration
# Launch types: EC2 (you manage) or Fargate (serverless)
# ============================================================

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# ECS CLUSTER
# Logical grouping of tasks/services
# ============================================================
resource "aws_ecs_cluster" "lab" {
  name = "lab-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ============================================================
# IAM ROLES FOR ECS
# ============================================================
resource "aws_iam_role" "ecs_task_execution" {
  name = "lab-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {

  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role (what the container can DO)
resource "aws_iam_role" "ecs_task" {
  name = "lab-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ============================================================
# CLOUDWATCH LOG GROUP for ECS
# ============================================================
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/lab-task"
  retention_in_days = 7
}

# ============================================================
# ECS TASK DEFINITION
# Task Definition = Blueprint for containers
# Specifies: image, CPU, memory, ports, environment vars, logging
#
# Launch Types:
#   EC2 Launch Type:
#     - You provision/manage EC2 instances
#     - More control, cost optimization
#   Fargate Launch Type (used here):
#     - AWS manages infrastructure (serverless)
#     - No EC2 to manage, pay per task
# ============================================================
resource "aws_ecs_task_definition" "lab" {
  family                   = "lab-task"
  requires_compatibilities = ["FARGATE"] # Serverless
  network_mode             = "awsvpc"    # Required for Fargate
  cpu                      = "256"       # 0.25 vCPU
  memory                   = "512"       # MB

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "lab-container"
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = 80
      protocol      = "tcp"
    }]

    environment = [
      { name = "ENVIRONMENT", value = "lab" }
    ]

    logConfiguration = {

      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"

      }

    }

    healthCheck = {

      command     = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60

    }
  }])
}

# ============================================================
# SECURITY GROUP for ECS Tasks
# ============================================================
resource "aws_security_group" "ecs_tasks" {
  name        = "lab-ecs-tasks-sg"
  description = "Allow HTTP inbound"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# ECS SERVICE
# Service = maintains desired number of running tasks
# Integrates with ALB for load balancing
# Supports rolling updates and circuit breaker
# ============================================================
resource "aws_ecs_service" "lab" {
  name            = "lab-service"
  cluster         = aws_ecs_cluster.lab.id
  task_definition = aws_ecs_task_definition.lab.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true # Required without NAT for Fargate in public subnet
  }

  # Deployment configuration
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # Circuit breaker: rollback if deployment fails
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

# ============================================================
# ECR REPOSITORY (Elastic Container Registry)
# Private Docker registry
# ============================================================
resource "aws_ecr_repository" "lab" {
  name                 = "lab-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # Scan for vulnerabilities on push
  }

  # destroy-safe: force delete even if images exist
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "lab" {

  repository = aws_ecr_repository.lab.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10

      }
      action = { type = "expire" }
    }]
  })
}
