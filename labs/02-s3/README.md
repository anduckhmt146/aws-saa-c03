# Lab 02 - S3 Storage

> Exam weight: **15-20%** of SAA-C03 questions

## What This Lab Creates

- Main S3 bucket (versioning + SSE-S3 encryption + logging)
- Lifecycle policy (Standard → IA → Glacier → Deep Archive → Expire)
- Static website bucket (public read)
- Cross-region replication (us-east-1 → us-west-2)
- Access logs bucket

## Run

```bash
terraform init
terraform apply
terraform destroy  # force_destroy = true deletes all objects
```

---

## Key Concepts

### S3 Basics

- **Object** = file + metadata (max 5 TB)
- **Bucket** = container (globally unique name)
- **Key** = object path (`folder/file.txt`)
- Multipart upload: recommended >100 MB, required >5 GB

### Storage Classes

| Class | Availability | AZs | Retrieval | Cost | Use Case |
|-------|-------------|-----|-----------|------|----------|
| Standard | 99.99% | ≥3 | Instant | $$$$$ | Frequently accessed |
| Intelligent-Tiering | 99.9% | ≥3 | Instant | $$$$ | Unknown access pattern |
| Standard-IA | 99.9% | ≥3 | Instant | $$$ | Infrequent (min 30 days) |
| One Zone-IA | 99.5% | 1 | Instant | $$ | Non-critical infrequent |
| Glacier Instant | 99.9% | ≥3 | Instant | $$ | Archive, instant needed |
| Glacier Flexible | 99.99% | ≥3 | 1min–12hr | $ | Archive |
| Glacier Deep | 99.99% | ≥3 | 12–48hr | $ | Long-term archive |

All classes: **11 9's durability** (99.999999999%)

Glacier Flexible retrieval tiers:
- Expedited: 1-5 min (expensive)
- Standard: 3-5 hours
- Bulk: 5-12 hours (cheapest)

### Lifecycle Rules

Automate transitions between storage classes:
```
Day 0   → Standard (default)
Day 30  → Standard-IA
Day 90  → Glacier Flexible
Day 180 → Glacier Deep Archive
Day 365 → Delete (Expiration)
```

**Exam Tips**:
- "Automatically move old data" → S3 Lifecycle
- "Unknown access pattern" → S3 Intelligent-Tiering
- "Cheapest archive" → Glacier Deep Archive
- "Archive with instant access" → Glacier Instant Retrieval

### S3 Security

#### Bucket Policies (resource-based)
```json
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::bucket-name/*"
}
```

#### Access Control
- **Block Public Access** → best practice, account-level setting
- **ACLs** → legacy, avoid when possible
- **Bucket Policies** → IAM-style JSON, resource-based
- **IAM Policies** → identity-based

#### Encryption
| Type | Key Management | Use Case |
|------|---------------|----------|
| SSE-S3 (AES256) | AWS managed | Default |
| SSE-KMS | Customer managed via KMS | Audit trail, control |
| SSE-C | Customer provided | Full key control |
| Client-side | Customer | Encrypt before upload |

**Exam Tip**: "Encrypt at rest" → SSE-S3 or SSE-KMS

### Versioning

- Keeps all versions of objects
- Once enabled, can only be **suspended** (not disabled)
- Protects against accidental delete
- MFA Delete: requires MFA to delete versions

### Cross-Region Replication (CRR)

Requirements:
1. Versioning enabled on **both** source and destination
2. IAM role with replication permissions
3. Buckets in **different regions**

Use cases: DR, compliance, latency reduction

Same-Region Replication (SRR): same region, different account

### S3 Performance

- **Prefix-based**: 3,500 PUT/COPY/POST/DELETE and 5,500 GET per prefix per second
- **Multipart Upload**: Recommended >100 MB, required >5 GB, parallel uploads
- **Transfer Acceleration**: Uses CloudFront edge locations
- **Byte-Range Fetches**: Parallel downloads of parts

### Static Website Hosting

- Endpoint: `bucket-name.s3-website-region.amazonaws.com`
- Must disable "Block Public Access" + add bucket policy
- Cannot use HTTPS directly → use CloudFront in front

### S3 Event Notifications

Triggers (destinations): Lambda, SQS, SNS, EventBridge
```
s3:ObjectCreated:* → Lambda (process uploads)
s3:ObjectRemoved:* → SQS (audit deletes)
```

### Common Exam Mistakes

- S3 is **object storage**, not block or file storage
- Standard-IA has **minimum storage duration** (30 days) and **minimum size** (128 KB)
- One Zone-IA data is **lost if the AZ fails**
- Cross-region replication does NOT replicate existing objects (only new ones)
