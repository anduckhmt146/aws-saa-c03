# Lab 04 - VPC & Networking

> Exam weight: **20-25%** — HARDEST domain in SAA-C03

## What This Lab Creates

- Custom VPC (10.0.0.0/16)
- Public subnets × 2 (multi-AZ)
- Private subnets × 2 (multi-AZ)
- Internet Gateway
- NAT Gateway + Elastic IP
- Route tables (public → IGW, private → NAT)
- 3-tier Security Groups (web, app, db)
- Network ACL with rule ordering
- VPC Endpoint for S3 (Gateway type)
- VPC Flow Logs → CloudWatch

## Run

```bash
terraform init
terraform apply   # ~5 minutes
terraform destroy
```

---

## Key Concepts

### VPC Basics

- CIDR: **/16 to /28** (65,536 to 16 IPs)
- Private IP ranges:
  - `10.0.0.0/8` — Class A
  - `172.16.0.0/12` — Class B
  - `192.168.0.0/16` — Class C
- VPC CIDR **cannot be changed** after creation (can add secondary CIDR)

### Subnet Reserved IPs (5 per subnet)

```
x.x.x.0   = Network address
x.x.x.1   = VPC router
x.x.x.2   = DNS server
x.x.x.3   = Reserved (future use)
x.x.x.255 = Broadcast
```
Example: /24 = 256 IPs → **251 usable**

### Internet Gateway (IGW)

- 1 VPC = **1 IGW** (one-to-one)
- Makes subnet **public** (route 0.0.0.0/0 → IGW)
- Horizontally scaled, HA, no bandwidth limit
- Free

### NAT Gateway vs NAT Instance

| Feature | NAT Gateway | NAT Instance |
|---------|------------|--------------|
| Managed | AWS | Customer |
| HA | Within AZ | Manual setup |
| Bandwidth | 5-100 Gbps | Instance type |
| Security Group | No | Yes |
| Cost | Hourly + data | EC2 cost |

- NAT Gateway: deployed in **public subnet**, needs **Elastic IP**
- For HA: create NAT Gateway in **each AZ**

### Security Groups vs NACLs

| Feature | Security Group | NACL |
|---------|---------------|------|
| Level | Instance | Subnet |
| State | Stateful | Stateless |
| Rules | Allow only | Allow + Deny |
| Evaluation | All rules | Numbered order |
| Default | Deny all in, allow all out | Allow all |

**Stateless**: NACL must explicitly allow return traffic (ephemeral ports 1024-65535)

**Exam Tip**: "Block specific IP" → NACL (SG cannot deny)

### Route Tables

```
Public subnet route table:
  10.0.0.0/16  → local
  0.0.0.0/0    → Internet Gateway

Private subnet route table:
  10.0.0.0/16  → local
  0.0.0.0/0    → NAT Gateway
```

### VPC Endpoints (private AWS service access)

| Type | Services | Cost |
|------|----------|------|
| Gateway | S3, DynamoDB | Free |
| Interface | Most others (ECR, SSM, etc.) | Hourly |

**Exam Tip**: "Access S3 without internet" → VPC Gateway Endpoint

### VPC Peering

- Connect 2 VPCs (same or different account/region)
- **Non-transitive**: A↔B, B↔C ≠ A↔C
- CIDRs must not overlap
- Must update route tables in both VPCs

### Transit Gateway

- Hub-and-spoke for connecting many VPCs + on-premises
- **Transitive routing**: A → TGW → B → TGW → C ✓
- **Exam Tip**: "Connect >3 VPCs" → Transit Gateway

### VPN & Direct Connect

| Feature | Site-to-Site VPN | Direct Connect |
|---------|-----------------|----------------|
| Medium | Internet (IPSec) | Dedicated fiber |
| Speed | Up to 1.25 Gbps | 1-100 Gbps |
| Setup | Minutes | Weeks/Months |
| Cost | Low | High |
| Latency | Variable | Consistent |

**Exam Tip**:
- "Fast setup, lower cost" → VPN
- "Consistent latency, high bandwidth" → Direct Connect
- "Backup for Direct Connect" → VPN

### VPC Flow Logs

- Capture IP traffic for VPC, subnet, or ENI
- Traffic types: ACCEPT, REJECT, ALL
- Destinations: CloudWatch Logs, S3, Kinesis Firehose
- Does NOT capture: DNS queries, DHCP, Windows license activation

### Route 53

- DNS service
- Routing policies:
  - **Simple**: Single resource
  - **Weighted**: A/B testing (split traffic by %)
  - **Latency**: Route to lowest-latency region
  - **Failover**: Active-passive DR
  - **Geolocation**: By user's country/continent
  - **Geoproximity**: By distance + bias
  - **Multi-value**: Multiple IPs with health checks

**Exam Tip**: "Route to closest region" → Latency routing

### CloudFront

- CDN: cache at edge locations (400+ globally)
- **Origins**: S3, ALB, EC2, custom HTTP
- **TTL**: 0-31,536,000 seconds
- **Cache Invalidation**: Manual, costs per path
- **OAC** (Origin Access Control): CloudFront-only S3 access
- **Exam Tip**: "Lowest latency globally" → CloudFront
