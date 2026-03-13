# Lab 05 - IAM & Security

> Exam weight: **30%** — Domain 1 (largest domain)

## What This Lab Creates

- IAM User + Group memberships
- IAM Groups (developers, readonly)
- Customer Managed Policies (S3 read, conditional)
- IAM Roles (EC2, Lambda, cross-account)
- Instance Profile (attach role to EC2)
- KMS Key (CMK with rotation)
- Account Password Policy

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### IAM Components

| Component | Purpose |
|-----------|---------|
| Users | Person or application |
| Groups | Collection of users (no nesting) |
| Roles | For AWS services or external identities |
| Policies | JSON permission documents |

### IAM Policy Structure

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::bucket/*",
    "Condition": {
      "IpAddress": { "aws:SourceIp": "203.0.113.0/24" }
    }
  }]
}
```

### Policy Evaluation Logic

```
Explicit DENY → DENY (always wins)
Explicit ALLOW → ALLOW
Default → DENY (implicit)
```

**Exam Tip**: If no policy allows, access is denied by default (least privilege)

### Policy Types

| Type | Managed By | Reusable |
|------|-----------|---------|
| AWS Managed | AWS | Yes (cannot edit) |
| Customer Managed | You | Yes |
| Inline | Embedded | No (1:1 with identity) |

### IAM Roles

**Trust Policy** = who can assume the role (`sts:AssumeRole`)
**Permission Policy** = what the role can do

Common use cases:
```
EC2 → S3: attach role to EC2 (no access keys needed)
Lambda → DynamoDB: Lambda execution role
Cross-account: one account assumes role in another
Federated: SSO/SAML users assume role
```

**Exam Tip**: "Application needs AWS access" → IAM Role (never hardcode access keys)

### STS (Security Token Service)

- Issues temporary credentials (15 min to 12 hours)
- `AssumeRole` → cross-account or service access
- `AssumeRoleWithWebIdentity` → Cognito, OAuth
- `AssumeRoleWithSAML` → enterprise SSO

### Permissions Boundaries

- Maximum permissions an identity can have
- Does NOT grant permissions — sets upper limit
- Use case: delegate role creation without privilege escalation

### AWS Organizations & SCPs

- **SCP** (Service Control Policy): max permissions for accounts in OU
- Applied at account level, affects ALL users including root
- Does NOT grant permissions — only restricts
- **Exam Tip**: "Restrict all accounts in org from using a service" → SCP

### KMS (Key Management Service)

| Key Type | Managed By | Rotation | Use Case |
|----------|-----------|---------|---------|
| AWS Managed | AWS | Auto (yearly) | Default encryption |
| Customer Managed (CMK) | You | Optional | Full control, audit |
| Customer Provided | You | Manual | S3 SSE-C |

KMS operations:
- `Encrypt` / `Decrypt` (up to 4 KB direct)
- `GenerateDataKey` → encrypt large data (envelope encryption)

**Exam Tips**:
- "Audit key usage" → CMK + CloudTrail
- "Encrypt at rest" → KMS (SSE-KMS)
- KMS keys are **regional** — cannot use across regions directly

### CloudTrail

- Logs ALL API calls (who, what, when, from where)
- 90-day event history (default, free)
- Create Trail → S3 storage (longer retention)
- **Management events**: API calls (default enabled)
- **Data events**: S3 object-level, Lambda invocations (extra cost)

**Exam Tip**: "Who made this API call?" → CloudTrail

### GuardDuty

- Threat detection (machine learning)
- Analyzes: CloudTrail, VPC Flow Logs, DNS logs
- Findings: unauthorized access, crypto mining, account compromise
- Enable with one click — no agents

### Security Hub

- Centralized security findings across services
- Aggregates GuardDuty, Inspector, Macie, etc.
- Compliance standards: CIS, PCI DSS, AWS Foundational

### Macie

- ML-based PII detection in S3
- Finds sensitive data: credit cards, SSNs, passwords

### Inspector

- Automated vulnerability scanning
- EC2 instances + Lambda functions + container images
- Reports CVEs, network reachability

### Cognito

- User pools: authentication (sign-up/sign-in, MFA)
- Identity pools: authorization (exchange token for AWS credentials)
- **Exam Tip**: "Mobile/web app authentication" → Cognito User Pool

### Common Exam Mistakes

- Root account should NEVER be used for daily tasks
- IAM is global — no region selection
- Roles use temporary credentials, no long-term keys
- SCP does NOT affect root user of management account... wait — it does for member accounts
