# Lab 16 - Migration & Transfer

> Exam weight: **5-7%** of SAA-C03 questions

## What This Lab Creates

- DMS Replication Instance + Source/Target Endpoints + Task
- DataSync S3 location
- Transfer Family SFTP server + user
- AWS Backup vault + plan + tag-based selection

## Run

```bash
terraform init
terraform apply
terraform destroy
```

> Note: DMS endpoints point to placeholder hostnames. Replace with real DB endpoints before running tasks.

---

## Key Concepts

### Migration Services Overview

| Service | Purpose | Keyword |
|---------|---------|---------|
| **DMS** | Database migration | "Migrate database" |
| **Snow Family** | Physical large data transfer | "Limited bandwidth", "petabytes" |
| **DataSync** | Automated file sync | "Automated sync", "on-prem to AWS" |
| **Transfer Family** | SFTP/FTP to S3/EFS | "SFTP", "legacy FTP" |
| **MGN (Application Migration)** | Lift-and-shift servers | "Rehost servers" |
| **Migration Hub** | Track all migrations | "Central migration dashboard" |

### DMS (Database Migration Service)

#### Migration Types

| Type | Description | Use Case |
|------|-------------|---------|
| Full Load | One-time copy | Small DB, acceptable downtime |
| CDC Only | Capture ongoing changes | Already migrated data |
| Full Load + CDC | Copy then sync | Minimal downtime (most common) |

#### Homogeneous vs Heterogeneous

```
Homogeneous:  MySQL → MySQL (no SCT needed)
              PostgreSQL → Aurora PostgreSQL
              Oracle → Oracle on RDS

Heterogeneous: Oracle → Aurora MySQL  ← needs SCT
               SQL Server → PostgreSQL
               (Schema Conversion Tool converts DDL/stored procs)
```

**Exam Tips**:
- "Minimal downtime database migration" → DMS with Full Load + CDC
- "Different DB engines" → DMS + SCT
- DMS Replication Instance = EC2 that runs migration task

### Snow Family (Physical Data Transfer)

| Device | Storage | Use Case |
|--------|---------|---------|
| **Snowcone** | 8-14 TB | Edge locations, small transfers |
| **Snowball Edge Storage** | 80 TB | Large data migration, edge storage |
| **Snowball Edge Compute** | 42 TB + compute | Edge computing + storage |
| **Snowmobile** | 100 PB | Entire data center migration |

**When to use Snow vs network transfer**:
```
Rule of thumb: if transfer > 1 week over existing bandwidth → Snow
100 TB over 1 Gbps = ~9 days → consider Snowball Edge
```

**Exam Tip**: "Limited bandwidth" + "large data" + "offline" → Snow Family

### DataSync

- **Agent-based** for on-premises (NFS, SMB, HDFS)
- **Agentless** for cloud (S3, EFS, FSx, Azure Blob)
- Features: scheduling, bandwidth throttling, data integrity verification
- Destinations: **S3, EFS, FSx for Windows, FSx for Lustre, FSx for OpenZFS**

**Exam Tip**: "Automated periodic sync from on-prem to S3/EFS" → DataSync

### Transfer Family

- Managed **SFTP/FTPS/FTP/AS2** service
- Backend: **S3** or **EFS**
- Identity: Service-managed (SSH keys), Microsoft AD, or custom (API Gateway)
- **Endpoint**: Public (internet) or VPC (private)

**Exam Tip**: "Legacy SFTP application migrating to AWS" → Transfer Family

### Application Migration Service (MGN)

- Formerly CloudEndure Migration
- **Continuous replication** of servers (block-level)
- **Minimal downtime**: cutover when ready
- Supports: physical, VMware, Hyper-V, other clouds
- **Exam Tip**: "Lift-and-shift" + "minimal downtime" → MGN

### AWS Backup

Centralized backup service across:
- EC2 instances + EBS volumes
- RDS + Aurora
- DynamoDB
- EFS + FSx
- S3 (object-level)
- DocumentDB, Neptune, SAP HANA

**Key concepts**:
- **Backup Plan**: rules for frequency + retention
- **Backup Vault**: encrypted storage location
- **Tag-based selection**: auto-include resources with specific tags
- **Cross-region/account copy**: DR compliance

**Lifecycle**:
```
Backup created → Warm storage (fast restore)
After N days   → Cold storage (cheaper, slower)
After M days   → Delete
```

**Exam Tip**: "Centralized backup policy" + "multiple AWS services" → AWS Backup

### Storage Gateway (On-prem → AWS Storage)

| Type | Protocol | Backend | Use Case |
|------|----------|---------|---------|
| **S3 File Gateway** | NFS/SMB | S3 | File shares backed by S3 |
| **FSx File Gateway** | SMB | FSx for Windows | Windows file shares |
| **Volume Gateway (Cached)** | iSCSI | S3 + local cache | Primary in S3, cache locally |
| **Volume Gateway (Stored)** | iSCSI | S3 (async backup) | Primary locally, backup to S3 |
| **Tape Gateway** | iSCSI VTL | S3/Glacier | Replace physical tapes |

**Exam Tip**: "On-premises apps need cloud storage" → Storage Gateway
