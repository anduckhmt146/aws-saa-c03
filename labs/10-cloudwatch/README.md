# Lab 10 - CloudWatch, Systems Manager & Management

> Exam weight: **10-15%** of SAA-C03 questions

## What This Lab Creates

- CloudWatch Log Groups (app + access)
- Log Metric Filter (count errors from logs)
- CloudWatch Alarms (CPU + custom metric + composite)
- CloudWatch Dashboard
- SSM Parameters (SecureString + String)
- EC2 with CloudWatch Agent + SSM Session Manager role

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### CloudWatch Overview

| Feature | Purpose |
|---------|---------|
| Metrics | Numeric time-series data |
| Logs | Application/system log storage |
| Alarms | Trigger actions on metric thresholds |
| Dashboards | Visualize metrics |
| Events/EventBridge | React to changes |
| Insights | Query logs with SQL-like syntax |

### CloudWatch Metrics

- **Built-in metrics**: CPU, Network, Disk I/O (EC2)
- **Custom metrics**: Memory, Disk Used (via CloudWatch Agent)
- **Default resolution**: 1 minute
- **High resolution**: 1 second (custom metrics, higher cost)
- **Namespace**: container for metrics (`AWS/EC2`, `LabApp`)

**Exam Tip**: Memory and Disk utilization = NOT built-in → need CloudWatch Agent

### CloudWatch Alarms

States: `OK` | `ALARM` | `INSUFFICIENT_DATA`

Actions:
- SNS notification
- EC2 action (stop, terminate, reboot, recover)
- Auto Scaling action

**Composite Alarms**: AND/OR conditions across multiple alarms

```
Alarm: CPU > 80% for 5 minutes
Period: 300s, Evaluation periods: 1
Statistic: Average
```

### CloudWatch Logs

- **Log Group**: collection of log streams (e.g., per application)
- **Log Stream**: sequence of events from one source (e.g., per instance)
- **Retention**: 1 day - 10 years (or never expire, charged)
- **Metric Filter**: extract custom metrics from log patterns
- **Subscription Filter**: stream logs to Lambda, Kinesis, OpenSearch

**CloudWatch Logs Insights**: Interactive SQL-like query
```sql
fields @timestamp, @message
| filter @message like /ERROR/
| stats count(*) by bin(5m)
```

### CloudWatch Agent

Extends built-in EC2 metrics:
- Memory utilization
- Disk space used %
- Process-level metrics
- Custom app logs collection

Requires IAM role: `CloudWatchAgentServerPolicy`

### Systems Manager (SSM)

| Feature | Use Case |
|---------|---------|
| **Session Manager** | SSH without key pairs, no inbound ports |
| **Parameter Store** | Config + secrets management |
| **Run Command** | Execute commands on instances remotely |
| **Patch Manager** | Automate OS patching |
| **State Manager** | Maintain desired instance state |
| **OpsCenter** | Operational issues aggregation |

### SSM Parameter Store

| Type | Encryption | Use Case |
|------|-----------|---------|
| String | No | Config values |
| StringList | No | Multiple values |
| SecureString | KMS | Passwords, secrets |

Hierarchy: `/app/prod/db/password`

**vs Secrets Manager**:
- Parameter Store: free for standard, integrated with AWS services
- Secrets Manager: paid, automatic rotation, cross-account

### CloudFormation (IaC)

- Define infrastructure in YAML/JSON templates
- **Stack**: collection of resources from a template
- **Change Set**: preview changes before applying
- **StackSets**: deploy across multiple accounts/regions
- **Drift Detection**: find manual changes

```yaml
Resources:  # REQUIRED
  MyBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: my-bucket
```

**Exam Tips**:
- "Infrastructure as Code" → CloudFormation
- "Rollback on failure" → CloudFormation (automatic)
- "Deploy across accounts" → StackSets

### AWS Config

- Assess, audit, evaluate resource configurations
- Records history of changes
- Compliance rules: "are all S3 buckets encrypted?"
- **Remediation**: auto-fix non-compliant resources
- **vs CloudTrail**: Config = resource state, CloudTrail = API calls

### Trusted Advisor

- Best practice recommendations
- Categories: Cost, Performance, Security, Fault Tolerance, Service Limits
- Free: 7 core checks (Business/Enterprise: all checks)
