# Lab 07 - ECS & Containers

> Exam weight: **20-25%** of SAA-C03 questions

## What This Lab Creates

- ECS Cluster (Container Insights enabled)
- Fargate Task Definition (nginx)
- ECS Service (desired count 1, deployment circuit breaker)
- ECR Repository (with lifecycle policy + scan on push)
- IAM roles (task execution + task role)
- CloudWatch Log Group

## Run

```bash
terraform init
terraform apply
terraform destroy  # force_delete = true on ECR
```

---

## Key Concepts

### ECS Components

| Component | Description |
|-----------|-------------|
| **Cluster** | Logical grouping of tasks/services |
| **Task Definition** | Blueprint: image, CPU, memory, ports, env vars |
| **Task** | Running instance of a task definition |
| **Service** | Maintains desired count of tasks, integrates with ALB |

### Launch Types

| Feature | EC2 Launch Type | Fargate |
|---------|----------------|---------|
| Infrastructure | You manage EC2 | AWS manages |
| Control | Full | Limited |
| Cost | EC2 pricing | Per task (vCPU + memory) |
| Use case | Cost optimization, GPUs | Simplicity, serverless |

**Exam Tip**: "No infrastructure management" + containers → **Fargate**

### ECS vs EKS vs Fargate

| Feature | ECS | EKS | Fargate |
|---------|-----|-----|---------|
| Orchestrator | AWS proprietary | Kubernetes | N/A (compute) |
| Complexity | Simple | Complex | Simplest |
| Portability | AWS only | Multi-cloud | AWS only |
| Cost | Low | Higher | Per task |

Decision tree:
```
Containers?
├── Kubernetes required? → EKS
├── Serverless containers? → ECS on Fargate
└── Full EC2 control? → ECS on EC2
```

### Task Definition Key Fields

```json
{
  "family": "my-task",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512",
  "containerDefinitions": [{
    "name": "app",
    "image": "nginx:latest",
    "portMappings": [{"containerPort": 80}],
    "essential": true
  }]
}
```

### IAM Roles for ECS

- **Task Execution Role**: ECS agent needs to pull image, write logs
  - `AmazonECSTaskExecutionRolePolicy`
- **Task Role**: What the running container can access (S3, DynamoDB, etc.)

### ECS Service Features

- **Desired count**: Always maintain N running tasks
- **Rolling updates**: Replace tasks gradually
- **Deployment circuit breaker**: Auto-rollback on failure
- **ALB integration**: Register tasks as targets
- **Auto Scaling**: Scale based on CPU/memory/custom metrics

### ECR (Elastic Container Registry)

- Private Docker registry (managed)
- `scan_on_push`: Automated vulnerability scanning
- Lifecycle policies: auto-delete old images
- Cross-account access via resource-based policies

### Docker Commands with ECR

```bash
# Authenticate
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

# Build + push
docker build -t lab-app .
docker tag lab-app:latest 123456789.dkr.ecr.us-east-1.amazonaws.com/lab-app:latest
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/lab-app:latest
```

### AWS Batch vs ECS

| Feature | ECS | AWS Batch |
|---------|-----|-----------|
| Workload | Long-running services | Batch jobs |
| Scheduling | Service (always on) | Job queues |
| Spot support | Yes | Yes (optimized) |
| Use case | Web apps, APIs | ETL, ML training |

### Elastic Beanstalk (PaaS)

Deploy apps without managing infrastructure:
- **Platforms**: Java, .NET, PHP, Node.js, Python, Ruby, Docker
- **Deployment strategies**:

| Strategy | Downtime | Capacity | Rollback |
|----------|----------|---------|---------|
| All at Once | Yes | Full | Manual |
| Rolling | No | Reduced | Manual |
| Rolling + Extra Batch | No | Full | Manual |
| Immutable | No | Full | Easy |
| Blue/Green | No (swap URL) | Full | Instant |
| Traffic Splitting | No | Full | Automatic |

**Exam Tips**:
- "Safest deployment" → Immutable
- "Zero downtime" → Blue/Green
- "Canary testing" → Traffic Splitting
