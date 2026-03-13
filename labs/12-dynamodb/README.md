# Lab 12 - DynamoDB

> Exam weight: **15-20%** of SAA-C03 questions

## What This Lab Creates

- DynamoDB table (orders) — On-Demand mode
- LSI (Local Secondary Index) on status
- GSI (Global Secondary Index) on userId + status
- TTL (auto-expire items)
- DynamoDB Streams → Lambda processor
- Second table (products) — Provisioned + Auto Scaling
- Point-in-Time Recovery (PITR)

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### DynamoDB Basics

- **Serverless** NoSQL key-value + document store
- **Single-digit millisecond** performance at any scale
- No JOINs — design for access patterns
- Max item size: **400 KB**

### Primary Key Types

| Type | Keys | When |
|------|------|------|
| Simple | Partition key only | Unique items by one attribute |
| Composite | Partition key + Sort key | Items grouped by partition, sorted |

### Capacity Modes

| Mode | Description | Use Case |
|------|-------------|---------|
| **On-Demand** | Pay per request, auto-scales | Variable/unpredictable traffic |
| **Provisioned** | Set RCU/WCU (+ auto-scaling) | Predictable, cost-optimized |

- **RCU** (Read Capacity Unit): 1 strongly consistent read/s of 4 KB
- **WCU** (Write Capacity Unit): 1 write/s of 1 KB

### Consistency Models

| Model | RCU cost | Latency | Use Case |
|-------|---------|---------|---------|
| **Eventually Consistent** | 0.5 RCU | Lower | Most reads |
| **Strongly Consistent** | 1 RCU | Higher | Must see latest write |
| **Transactional** | 2 RCU | Highest | ACID transactions |

### Indexes

#### LSI (Local Secondary Index)
- Same **partition key**, different sort key
- Must be created **at table creation** time
- Max **5 LSIs** per table
- Shares RCU/WCU with main table
- Max 10 GB per partition key value

#### GSI (Global Secondary Index)
- Different **partition key** AND sort key
- Can be added **after creation**
- Max **20 GSIs** per table
- Has own RCU/WCU (or On-Demand)
- Use case: query by any attribute

**Exam Tips**:
- "Query by non-primary key" → GSI
- "Filter within same partition" → LSI

### Projection Types

| Type | Stored | Cost |
|------|--------|------|
| ALL | All attributes | Most expensive |
| KEYS_ONLY | Primary key + index key | Cheapest |
| INCLUDE | Key + specified attributes | Middle |

### DynamoDB Streams

- Ordered log of changes (INSERT, MODIFY, REMOVE)
- Retention: **24 hours**
- View types: KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, NEW_AND_OLD_IMAGES
- Trigger Lambda (Event Source Mapping)

Use cases: real-time replication, triggers, change data capture

### TTL (Time to Live)

- Set Unix timestamp attribute as expiry
- DynamoDB auto-deletes expired items (within 48h)
- **No RCU/WCU consumed**
- Use case: session data, temporary data, audit logs

### DAX (DynamoDB Accelerator)

- **In-memory cache** for DynamoDB
- **Microsecond** latency (vs millisecond)
- **Write-through** cache
- API-compatible — no code changes
- Use case: read-heavy, latency-sensitive apps

**Exam Tip**: "Microsecond latency for DynamoDB" → DAX

### DynamoDB vs RDS

| Feature | DynamoDB | RDS |
|---------|----------|-----|
| Type | NoSQL | Relational |
| Latency | <10ms | <100ms |
| Schema | Flexible | Fixed |
| JOINs | No | Yes |
| Transactions | Limited | Full ACID |
| Scaling | Horizontal | Vertical |

**Exam Decision**:
- Unstructured/variable schema → DynamoDB
- Complex queries with JOINs → RDS
- Session data, leaderboards, IoT → DynamoDB
- Financial, ERP, complex relationships → RDS

### Global Tables

- Multi-region, multi-active replication
- Low-latency reads/writes globally
- Conflict resolution: last-write-wins
- Requires On-Demand or provisioned with auto-scaling

**Exam Tip**: "Global low-latency reads AND writes" → DynamoDB Global Tables
