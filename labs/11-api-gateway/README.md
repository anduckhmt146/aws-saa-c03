# Lab 11 - API Gateway

> Exam weight: **5-7%** of SAA-C03 questions

## What This Lab Creates

- REST API Gateway with /items resource
- GET + POST methods (Lambda proxy integration)
- Deployment + Stage (prod)
- Access logging + method-level throttling
- Usage Plan + API Key

## Run

```bash
terraform init
terraform apply
# Test: curl $(terraform output -raw api_url)
terraform destroy
```

---

## Key Concepts

### API Gateway Types

| Type | Features | Cost | Use Case |
|------|----------|------|---------|
| **REST API** | Full (caching, usage plans, X-Ray) | Higher | Feature-rich APIs |
| **HTTP API** | Simpler, JWT auth, auto-deploy | ~70% cheaper | Low-latency, cost-conscious |
| **WebSocket** | Two-way, real-time | Per message | Chat, live dashboards |

**Exam Tip**: "Serverless API" → API Gateway + Lambda

### Endpoint Types

| Type | Where | Use Case |
|------|-------|---------|
| Regional | Single region | Default, regional clients |
| Edge-Optimized | CloudFront (global) | Global clients |
| Private | VPC only | Internal APIs |

### Integration Types

| Type | Description |
|------|-------------|
| **AWS_PROXY** | Lambda proxy — full event/response passthrough (recommended) |
| **AWS** | Custom mapping — transform request/response |
| **HTTP_PROXY** | Pass-through to HTTP backend |
| **HTTP** | Custom transform to HTTP backend |
| **MOCK** | Return hardcoded response (testing) |

### Throttling

- Account-level default: **10,000 RPS**, burst **5,000**
- Stage-level throttling: override per stage
- Method-level throttling: per route
- Per-client: Usage Plans

When throttled → `429 Too Many Requests`

### Caching

- TTL: 0 - 3,600s (default 300s)
- Cache size: 0.5 GB - 237 GB
- Per stage setting
- Can be invalidated per request (`Cache-Control: max-age=0`)

**Exam Tip**: "Reduce backend calls" → API Gateway caching

### Security

| Method | Description |
|--------|-------------|
| IAM Auth | AWS_IAM authorization (SigV4) |
| Cognito User Pools | JWT token validation |
| Lambda Authorizer | Custom auth logic (token/request) |
| API Keys | Rate limiting (not authentication) |
| Resource Policy | Allow/deny by IP, VPC, account |

### CORS

Must be enabled for browser-based clients:
- Enable on method or at integration level
- `Access-Control-Allow-Origin` header required

### AppSync (GraphQL)

- Managed GraphQL API
- Real-time subscriptions
- Offline sync
- Data sources: DynamoDB, Lambda, RDS, HTTP
- **Exam Tip**: "GraphQL" → AppSync

### Lambda Authorizer

```
Request → API GW → Lambda Authorizer → IAM Policy → Allow/Deny
```

Types:
- **Token**: JWT/OAuth token in header
- **Request**: Headers, query params, stage variables

Result is cached (TTL 0-3600s) to reduce Lambda invocations.
