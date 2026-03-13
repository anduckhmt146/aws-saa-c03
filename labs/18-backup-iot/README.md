# Lab 18 - IoT Core, EventBridge Scheduler & Other Services

> Exam weight: **3-5%** of SAA-C03 questions

## What This Lab Creates

- IoT Thing + Certificate + Policy (X.509 device auth)
- IoT Topic Rule (MQTT → DynamoDB + SNS)
- EventBridge Scheduler (recurring + one-time)
- Simple AD Directory (for WorkSpaces)
- SNS/SQS for IoT routing

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### IoT Core

Connect billions of IoT devices to AWS.

**Protocol**: MQTT (lightweight pub/sub), HTTP, WebSocket

**Components**:
```
Device (sensor)
  ↓ MQTT publish to topic
IoT Core Message Broker
  ↓
Rules Engine (SQL-like filter)
  ↓
Actions: Lambda, DynamoDB, S3, SNS, SQS, Kinesis, CloudWatch
```

**Authentication**: X.509 certificates (per device)

**Device Shadow**:
- Virtual state representation stored in IoT Core
- Sync desired vs reported state
- Works even when device is offline
- **Exam Tip**: "Sync device state when offline" → Device Shadow

**Topic structure**:
```
lab/sensors/temperature  (publish)
lab/commands/actuator    (subscribe)
$aws/things/{name}/shadow/update  (shadow)
```

### EventBridge Scheduler

More flexible than CloudWatch Events (cron):

| Feature | EventBridge Scheduler | CloudWatch Events |
|---------|----------------------|-------------------|
| One-time schedules | Yes | No |
| Time zones | Yes | No (UTC only) |
| Flexible window | Yes (±N minutes) | No |
| Target API calls | Any AWS API | Limited |

**Schedule expressions**:
```
rate(5 minutes)              → every 5 min
cron(0 9 * * ? *)            → daily 9 AM UTC
at(2024-12-31T23:59:00)      → one-time
```

**Flexible time window**: execute within ±N minutes of scheduled time (reduces thundering herd)

### WorkSpaces

- **DaaS** (Desktop as a Service)
- Persistent Windows/Linux virtual desktops
- Billed: monthly (always-on) or hourly (AutoStop)
- Requires **AWS Directory Service** (Simple AD, AWS Managed AD, or AD Connector)

**vs AppStream 2.0**:
| Feature | WorkSpaces | AppStream 2.0 |
|---------|-----------|--------------|
| Type | Full virtual desktop | Application streaming |
| Persistence | Yes | No |
| Use case | Remote workers | Deliver specific apps |

**Exam Tip**: "Remote desktop" → WorkSpaces; "Stream one app to browser" → AppStream

### AWS Outposts

- AWS infrastructure installed **on-premises**
- Same APIs, services as AWS cloud
- Latency-sensitive workloads near on-prem
- **Form factors**: 42U rack or 1U/2U servers
- **Exam Tip**: "AWS services on-premises" → Outposts

### AWS Wavelength

- Deploy apps at **5G network edge**
- Ultra-low latency for mobile devices (<10ms)
- Use case: gaming, live streaming, AR/VR, autonomous vehicles
- **Exam Tip**: "5G edge computing" → Wavelength

### AWS Local Zones

- AWS infrastructure in more locations (metros)
- Single-digit ms latency to major cities
- Subset of AWS services
- **vs Wavelength**: Local Zones = city/metro; Wavelength = 5G edge

### AWS Ground Station

- Control satellite communications
- Download and process satellite data
- Use case: weather forecasting, earth observation

### EFS (Elastic File System)

- Managed NFS file system (POSIX-compliant)
- **Multi-AZ**: data stored across multiple AZs
- **Elastic**: auto-scales, no provisioning
- Performance modes: General Purpose, Max I/O
- Throughput modes: Bursting, Provisioned, Elastic
- Storage tiers: Standard, IA (Infrequent Access)
- Use case: shared file storage for EC2, Lambda, ECS

**vs EBS vs S3**:
```
EBS  = Block storage, single EC2, high IOPS
EFS  = File storage, multi-EC2, NFS
S3   = Object storage, unlimited, web-accessible
```

### FSx Options

| FSx Type | Protocol | Use Case |
|----------|---------|---------|
| FSx for Windows | SMB | Windows apps, Active Directory |
| FSx for Lustre | Lustre | HPC, ML training, fast processing |
| FSx for NetApp ONTAP | NFS/SMB/iSCSI | Enterprise, multi-protocol |
| FSx for OpenZFS | NFS | Linux workloads |

**Exam Tips**:
- "Windows SMB file shares" → FSx for Windows
- "HPC / ML training fast storage" → FSx for Lustre
- "Lustre integrates with S3" → FSx for Lustre (lazy load from S3)
