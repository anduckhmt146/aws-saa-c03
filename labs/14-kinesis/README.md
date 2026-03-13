# Lab 14 - Kinesis, Athena & Analytics

> Exam weight: **8-10%** of SAA-C03 questions

## What This Lab Creates

- Kinesis Data Stream (2 shards, 24hr retention, KMS encrypted)
- Kinesis Firehose → S3 (Kinesis source, GZIP compression)
- Athena Workgroup + Database
- Glue Catalog Database + Crawler
- S3 buckets (Firehose destination + Athena results)

## Run

```bash
terraform init
terraform apply
terraform destroy  # force_destroy = true on all buckets
```

---

## Key Concepts

### Kinesis Services

| Service | Latency | Scaling | Use Case |
|---------|---------|---------|---------|
| **Data Streams** | ~200ms (real-time) | Shards (manual) | Real-time processing |
| **Firehose** | ~60s (near real-time) | Auto | Load to destinations |
| **Data Analytics** | Real-time | Auto | SQL on streams |
| **Video Streams** | Real-time | Auto | Video ingestion |

### Kinesis Data Streams

- **Shard**: unit of capacity
  - Write: 1 MB/s or 1,000 records/s
  - Read: 2 MB/s
- **Retention**: 24 hours (default), up to 365 days
- **Consumer**: EC2, Lambda, KCL app
- **Enhanced Fan-Out**: 2 MB/s per consumer (parallel)

**Exam Tips**:
- "Real-time streaming" → Kinesis Data Streams
- "Process stream with SQL" → Kinesis Data Analytics
- Add shards to scale (resharding)

### Kinesis Firehose

- **Serverless** + **Auto-scaling** (no shards to manage)
- **Near real-time** (60s latency minimum)
- Destinations: **S3**, **Redshift**, **OpenSearch**, Splunk, HTTP
- Transformations: Lambda (before delivery)
- Compression: GZIP, Snappy, Zip, Hadoop-Compatible SNAPPY

**Buffer conditions** (delivers whichever comes first):
- Buffer size: 1-128 MB
- Buffer interval: 60-900 seconds

**Exam Tip**: "Load data to S3/Redshift" → Kinesis Firehose

### Kinesis vs SQS

| Feature | Kinesis Data Streams | SQS |
|---------|---------------------|-----|
| Ordering | Per-shard FIFO | FIFO queue only |
| Replay | Yes (up to 365 days) | No (consumed = gone) |
| Consumers | Multiple concurrent | Competing consumers |
| Routing | None | None |
| Use case | Stream processing | Task queues |

**Exam Tips**:
- "Multiple consumers read same data" → Kinesis
- "Replay messages" → Kinesis
- "Task queue, decouple" → SQS

### Amazon Athena

- **Serverless** SQL queries on **S3**
- **Pay per TB scanned** (~$5/TB)
- Formats: CSV, JSON, **Parquet** (columnar, cheapest), ORC, Avro
- Uses **Glue Data Catalog** for schema
- Federated queries: RDS, DynamoDB, on-premises

**Cost optimization**:
- Use **Parquet/ORC** (columnar) → 30-90% less data scanned
- **Partition** data: `s3://bucket/year=2024/month=01/day=15/`
- Compress files (GZIP, Snappy)

**Exam Tips**:
- "Query S3 with SQL" → Athena
- "Serverless analytics, no cluster" → Athena
- "Cost-effective log analysis" → Athena + S3

### AWS Glue

- **ETL** (Extract, Transform, Load) service
- **Glue Crawler**: auto-discover schema from S3, RDS, etc.
- **Glue Data Catalog**: metadata repository (used by Athena, EMR)
- **Glue ETL Jobs**: Python/Scala Spark jobs

**Exam Tip**: "Discover and catalog data schema" → Glue Crawler

### EMR (Elastic MapReduce)

- Managed **Hadoop/Spark** cluster
- Use case: big data processing, ML at scale
- Cost: Spot instances for task nodes (save 60-90%)
- Storage: HDFS (local) or S3 (EMRFS)

**Exam Tip**: "Hadoop/Spark workloads" → EMR

### Redshift

- **Data warehouse** (OLAP, not OLTP)
- Columnar storage, massively parallel
- **Redshift Spectrum**: query S3 directly from Redshift
- **Copy from S3**: fast bulk load

| Service | Type | Use Case |
|---------|------|---------|
| RDS | OLTP | Transactional apps |
| DynamoDB | NoSQL | Key-value, low latency |
| Redshift | Data Warehouse | Analytics, BI reporting |
| Athena | Serverless SQL | Ad-hoc S3 queries |
| EMR | Big Data | Hadoop/Spark |

### OpenSearch (ElasticSearch)

- **Full-text search** + analytics
- Near real-time indexing
- Visualize with OpenSearch Dashboards (formerly Kibana)
- Input: Kinesis Firehose, Lambda, IoT

**Exam Tip**: "Full-text search" or "log analytics with visualization" → OpenSearch
