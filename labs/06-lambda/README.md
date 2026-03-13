# Lab 06 - Lambda & Serverless

> Exam weight: **20-25%** of SAA-C03 questions

## What This Lab Creates

- Lambda function (Python) with environment variables
- IAM execution role
- CloudWatch Log Group
- EventBridge scheduled trigger (every 5 min)
- SQS event source mapping
- S3 object-created trigger
- Dead Letter Queue (DLQ)
- Lambda Alias

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### Lambda Limits

| Property | Limit |
|----------|-------|
| Max execution time | **15 minutes** (900s) |
| Memory | 128 MB – 10 GB |
| /tmp storage | 512 MB – 10 GB |
| Environment variables | 4 KB |
| Deployment package | 50 MB (zip), 250 MB (unzipped) |
| Concurrent executions | 1,000/region (default) |
| Free tier | 1M requests/month + 400K GB-seconds |

### Invocation Types

| Type | Trigger Examples | Behavior |
|------|-----------------|---------|
| **Synchronous** | API Gateway, ALB, CLI | Waits for response |
| **Asynchronous** | S3, SNS, EventBridge | Queued, retries 2x |
| **Event Source Mapping** | SQS, Kinesis, DynamoDB Streams | Lambda polls source |

### Supported Runtimes

Python, Node.js, Java, Go, Ruby, C#, PowerShell, Custom Runtime (any)

### Concurrency

```
Reserved Concurrency   = guaranteed capacity (cap at N)
Provisioned Concurrency = pre-warmed instances → no cold start
Default limit          = 1,000 concurrent/region
```

- **Cold start**: Lambda initializes a new container (~100ms-10s)
- **Warm start**: reuses existing container (fast)
- Provisioned concurrency eliminates cold starts (costs more)

### Lambda Storage

| Storage | Size | Persistence |
|---------|------|------------|
| /tmp | 512 MB - 10 GB | Ephemeral (per invocation) |
| EFS | Unlimited | Persistent |
| S3 | Unlimited | Persistent |
| Environment variables | 4 KB | Function config |

### Lambda@Edge

- Run Lambda at CloudFront edge locations
- 4 trigger points: Viewer Request/Response, Origin Request/Response
- Use cases: A/B testing, auth, redirects, headers
- Limits: 5s timeout (viewer), 30s (origin)

### Lambda Layers

- Shared code/libraries across functions
- Max 5 layers per function, 250 MB total
- Good for: numpy, pandas, custom runtimes, shared utils

### Use Case Patterns

```
S3 upload → Lambda               = File processing
EventBridge schedule → Lambda    = Cron jobs / automation
API Gateway → Lambda             = Serverless REST API
SQS → Lambda                     = Message processing
DynamoDB Streams → Lambda        = Change data capture
Kinesis → Lambda                 = Real-time stream processing
SNS → Lambda                     = Fan-out notifications
```

### Lambda vs ECS vs Batch

| Feature | Lambda | ECS/Fargate | AWS Batch |
|---------|--------|-------------|-----------|
| Max runtime | 15 min | Unlimited | Unlimited |
| Containers | No | Yes | Yes |
| Billing | Per ms | Per task | Per instance |
| Use case | Short events | Long-running | Batch jobs |

**Exam Tips**:
- "Serverless" → Lambda
- "Event-driven" → Lambda
- Task >15 minutes → ECS/Fargate or AWS Batch
- "No infrastructure management" → Lambda or Fargate

### Dead Letter Queue (DLQ)

- For async invocations: if Lambda fails after retries, send to DLQ
- Destinations: SQS or SNS
- `maximum_retry_attempts`: 0, 1, or 2

### VPC Integration

- Lambda can access VPC resources (RDS, ElastiCache)
- Requires VPC config (subnet IDs, security group)
- Uses ENI — assign sufficient IPs in subnets
- For AWS services: use VPC endpoints (avoid NAT Gateway costs)

### RDS Proxy with Lambda

- Lambda opens/closes DB connections per invocation
- RDS Proxy pools connections → avoids "too many connections"
- **Exam Tip**: "Lambda + RDS connection exhaustion" → RDS Proxy
