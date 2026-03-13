# Lab 09 - SQS, SNS & EventBridge

> Exam weight: **10-12%** of SAA-C03 questions

## What This Lab Creates

- SQS Standard Queue (with DLQ + long polling)
- SQS FIFO Queue
- Dead Letter Queue (DLQ)
- SNS Topic (standard + FIFO)
- SNS → SQS subscription (fan-out)
- SNS filter policy
- EventBridge custom event bus + rule

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### SQS Queue Types

| Feature | Standard | FIFO |
|---------|----------|------|
| Throughput | Unlimited | 300 TPS (3,000 with batching) |
| Ordering | Best-effort | Strict FIFO |
| Delivery | At-least-once (duplicates possible) | Exactly-once |
| Name | Any | Must end with `.fifo` |
| Use case | High throughput | Order critical, no duplicates |

### SQS Key Settings

| Setting | Default | Range | Purpose |
|---------|---------|-------|---------|
| Visibility Timeout | 30s | 0s - 12hr | Prevent duplicate processing |
| Message Retention | 4 days | 1min - 14 days | How long messages stay |
| Long Polling | 0 (disabled) | 1-20s | Reduce empty API calls |
| Delay Queue | 0 | 0-900s | Delay message delivery |
| Max Message Size | 256 KB | 1 B - 256 KB | |

**Visibility Timeout**: When consumer reads message, it becomes invisible. If not deleted within timeout, becomes visible again (re-delivered). Set >= processing time.

**Long Polling** (`ReceiveWaitTimeSeconds` 1-20s): Wait for messages instead of returning empty response. Reduces cost and latency.

### Dead Letter Queue (DLQ)

- After `maxReceiveCount` failures → move to DLQ
- DLQ: separate queue for failed messages
- Use for debugging, alerting
- Set DLQ message retention higher than source queue

**Exam Tip**: "Messages failing processing" → DLQ

### SNS - Pub/Sub

- **Publisher** → **Topic** → **Subscribers**
- Subscribers: SQS, Lambda, HTTP/S, Email, SMS, Mobile Push

### SNS Fan-out Pattern

```
SNS Topic
├── SQS Queue 1 (process orders)
├── SQS Queue 2 (audit log)
└── Lambda (real-time notification)
```

One publish → multiple consumers receive independently

**Exam Tip**: "Process same message in multiple ways" → SNS Fan-out

### SNS Filter Policy

Subscribe with a filter to only receive relevant messages:
```json
{
  "event_type": ["order_created", "order_updated"]
}
```
Subscribers without filter receive all messages.

### SQS vs SNS

| Feature | SQS | SNS |
|---------|-----|-----|
| Model | Pull (consumer polls) | Push (SNS delivers) |
| Persistence | Yes (up to 14 days) | No (immediate delivery) |
| Consumers | Single consumer per message | Multiple subscribers |
| Use case | Decoupling, async processing | Fan-out, notifications |

### EventBridge (CloudWatch Events)

- Event bus for routing events
- **Sources**: AWS services, custom apps, SaaS (Datadog, Zendesk)
- **Targets**: Lambda, SQS, SNS, ECS, Step Functions, API Gateway
- **Rules**: event pattern matching or schedule

**Event pattern example**:
```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": { "state": ["terminated"] }
}
```

**Exam Tips**:
- "React to AWS service events" → EventBridge
- "Schedule Lambda" → EventBridge (cron/rate)
- "Decouple microservices" → EventBridge event bus

### SQS vs EventBridge

| Feature | SQS | EventBridge |
|---------|-----|-------------|
| Model | Queue (pull) | Event bus (push) |
| Persistence | Yes | No (fire and forget) |
| Routing | Simple | Complex pattern matching |
| Sources | Any producer | AWS services + custom |
| Use case | Work queues | Event-driven architecture |

### Step Functions

- Orchestrate multiple AWS services into workflows
- State machine: sequence, parallel, choice, wait
- **Standard**: long-running (1 year), at-least-once
- **Express**: high-volume, short-duration (5 min)

**Exam Tip**: "Coordinate multiple Lambda functions" → Step Functions
