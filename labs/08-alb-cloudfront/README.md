# Lab 08 - ALB & CloudFront

> Exam weight: **20-25%** of SAA-C03 questions

## What This Lab Creates

- Application Load Balancer (ALB)
- Target Groups (main + API path-based routing)
- 2 EC2 backend instances
- ALB Listener rules (default + /api/*)
- CloudFront Distribution (ALB as origin)
- S3 access logs bucket for ALB

## Run

```bash
terraform init
terraform apply   # ~5 min for CloudFront
terraform destroy
```

---

## Key Concepts

### ELB Types

| Type | Layer | Protocol | Use Case |
|------|-------|---------|---------|
| **ALB** | Layer 7 | HTTP/HTTPS/gRPC | Web apps, path/host routing |
| **NLB** | Layer 4 | TCP/UDP/TLS | Low latency, static IP |
| **GWLB** | Layer 3 | IP | Network appliances (firewall) |
| CLB (legacy) | 4+7 | HTTP/TCP | Do not use |

**Exam Tips**:
- "Path-based routing" → ALB
- "Static IP" or "extreme performance" → NLB
- "Firewall/virtual appliances" → GWLB

### ALB Features

- **Host-based routing**: `api.example.com` → Target Group A
- **Path-based routing**: `/api/*` → Target Group B
- **Header routing**: route by User-Agent, cookie, etc.
- **Query string routing**: `?version=2` → Target Group C
- **Weighted target groups**: canary deployments
- **WebSocket** support
- **HTTP/2** support
- Target types: EC2 instances, IP addresses, Lambda, ECS

### Target Group Health Checks

```hcl
health_check {
  healthy_threshold   = 2   # consecutive successes
  unhealthy_threshold = 3   # consecutive failures
  interval            = 30  # seconds between checks
  timeout             = 5   # seconds to wait
  path                = "/"
  matcher             = "200-299"
}
```

### Sticky Sessions (Session Affinity)

- ALB: application-based cookies or duration-based
- NLB: source IP
- Use case: stateful apps (shopping cart in memory)

### CloudFront

CDN — cache content at 400+ edge locations globally

**Key settings**:

| Setting | Description |
|---------|-------------|
| Origin | S3, ALB, EC2, API Gateway, custom HTTP |
| TTL | Time-to-live for cached objects |
| Invalidation | Force-expire cached objects (cost per path) |
| Price Class | 100 (US/EU), 200 (+Asia), All |
| OAC | Origin Access Control — S3 accessible ONLY via CloudFront |

**Viewer Protocol Policy**:
- `allow-all` — HTTP + HTTPS
- `https-only` — HTTPS only
- `redirect-to-https` — redirect HTTP → HTTPS (recommended)

### CloudFront Cache Behaviors

- **Default**: applies to all requests (`*`)
- **Ordered**: path-specific (`/api/*`, `/images/*`)
- More specific path patterns take priority

### CloudFront Functions vs Lambda@Edge

| Feature | CloudFront Functions | Lambda@Edge |
|---------|---------------------|-------------|
| Triggers | Viewer req/res only | All 4 events |
| Runtime | JavaScript | Python/Node |
| Max exec | 1ms | 5s / 30s |
| Cost | 1/6th of Lambda@Edge | Higher |
| Use case | Header manipulation, URL rewrites | Complex logic, auth |

### Global Accelerator

- Routes users to nearest AWS edge
- Uses AWS backbone network (not public internet)
- 2 **static anycast IPs** (global)
- Supports TCP, UDP
- **vs CloudFront**:
  - CloudFront = caches content at edge
  - Global Accelerator = improves network path (no caching)

**Exam Tip**: "Static IPs for global app" → Global Accelerator

### ALB vs NLB Decision

```
HTTP/HTTPS app → ALB
Path/host routing → ALB
Static IP needed → NLB
TCP/UDP protocol → NLB
Extreme low latency (<100ms) → NLB
Firewall/IDS/IPS → GWLB
```
