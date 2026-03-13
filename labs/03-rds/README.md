# Lab 03 - RDS & Databases

> Exam weight: **15-20%** of SAA-C03 questions

## What This Lab Creates

- RDS MySQL 8.0 instance (primary)
- Read Replica
- DB Subnet Group
- DB Parameter Group
- Security Group (MySQL port 3306)
- Manual Snapshot

## Run

```bash
terraform init
terraform apply   # Takes ~10 minutes for RDS
terraform destroy # skip_final_snapshot = true, no charges left
```

---

## Key Concepts

### RDS Engines

| Engine | Notes |
|--------|-------|
| MySQL | Open-source, widely used |
| PostgreSQL | JSON support, extensions |
| MariaDB | MySQL fork, open-source |
| Oracle | Enterprise, BYOL or included |
| SQL Server | Windows-based |
| Aurora | AWS proprietary, 5x MySQL perf |

### Key Features

#### Automated Backups
- Retention: 1-35 days (default 7)
- **Point-in-Time Recovery**: restore to any second in retention window
- Stored in S3 (managed by AWS)
- Deleted when instance is deleted (unless `delete_automated_backups = false`)

#### Manual Snapshots
- User-initiated, no expiration
- Retained until manually deleted
- Can **share** across accounts
- Can **copy** across regions

#### Multi-AZ Deployment
- **Synchronous replication** to standby in another AZ
- **Automatic failover** in 60-120 seconds (DNS update)
- Standby is **NOT readable**
- Use case: **High availability**, not performance
- Single DNS endpoint — app doesn't need to change connection string

#### Read Replicas
- **Asynchronous replication** (eventual consistency)
- Up to **5 replicas** (MySQL/PostgreSQL), **15** (Aurora)
- **Readable** — offload SELECT queries
- Can be **promoted** to standalone DB (manual, for DR)
- **Cross-region** replication supported
- Use case: **Performance**, read-heavy workloads

### Multi-AZ vs Read Replica

| Feature | Multi-AZ | Read Replica |
|---------|----------|--------------|
| Replication | Synchronous | Asynchronous |
| Readable | No (standby) | Yes |
| Failover | Automatic | Manual (promote) |
| Purpose | High Availability | Performance |
| Cross-region | No | Yes |

**Exam Tip**:
- "Automatic failover" → Multi-AZ
- "Offload read traffic" → Read Replica
- Can have BOTH: Multi-AZ + Read Replica

### RDS Storage Types

| Type | IOPS | Use Case |
|------|------|----------|
| gp3 (SSD) | Up to 16,000 | General purpose (default) |
| io1/io2 (SSD) | Up to 256,000 | I/O intensive databases |
| magnetic | Low | Legacy only |

**Provisioned IOPS (io1/io2)**: exam keyword → "high I/O", "consistent performance"

### Aurora

AWS proprietary, not standard MySQL/PostgreSQL:
- **5x MySQL**, **3x PostgreSQL** performance
- Storage auto-scales: 10 GB → 128 TB
- **6 copies** of data across 3 AZs
- Up to **15 read replicas** (fast failover <30s)
- **Aurora Serverless**: Auto-scales for unpredictable workloads
- **Global Database**: Low-latency reads across regions (<1s replication)

**Exam Tip**: "Highly available database" + "auto-scaling storage" → Aurora

### RDS Proxy

- Connection pooling for Lambda/serverless (avoids connection exhaustion)
- **Exam Tip**: "Lambda + RDS connection issues" → RDS Proxy

### ElastiCache vs RDS

- **RDS**: Persistent, relational, ACID
- **ElastiCache**: In-memory cache, sub-millisecond, NOT persistent

### Common Exam Mistakes

- Multi-AZ standby is NOT readable (use Read Replica for reads)
- Read Replicas have eventual consistency (async replication)
- Aurora is NOT free tier eligible
- `deletion_protection = true` prevents terraform destroy (never set in labs)
