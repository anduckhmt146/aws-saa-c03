# AWS SAA-C03 Terraform Labs

Hands-on labs using Terraform to provision and destroy AWS resources for each SAA-C03 exam domain.

---

## Prerequisites

```bash
# 1. Install Terraform
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# 2. Install AWS CLI + jq
brew install awscli jq

# 3. Configure your base IAM user
aws configure
```

---

## One-Time Setup — Create IAM Lab Roles

Run this **once** to create scoped IAM roles for all 50 labs:

```bash
cd labs/
./create-lab-roles.sh setup
```

> Each role has only the permissions needed for that lab (least-privilege).
> If a role already exists it will be skipped and its trust policy updated.

---

## How to Run Any Lab

```bash
# Step 1 — assume the scoped IAM role for the lab
source ./create-lab-roles.sh session <lab-name>

# Step 2 — go into the lab folder
cd <lab-name>

# Step 3 — initialize Terraform (download providers)
terraform init

# Step 4 — preview what will be created
terraform plan

# Step 5 — deploy
terraform apply

# Step 6 — ALWAYS destroy when done (avoids AWS charges)
terraform destroy
```

### Example — Lab 01 EC2

```bash
source ./create-lab-roles.sh session 01-ec2
cd 01-ec2
terraform init && terraform plan
terraform apply
terraform destroy
```

---

## Switching Between Labs

The `session` command automatically clears previous credentials before assuming the new role:

```bash
# Switch from one lab to another — no manual unset needed
source ./create-lab-roles.sh session 04-vpc
```

---

## Useful Commands

```bash
# List all roles and whether they exist in AWS
./create-lab-roles.sh list

# Delete all lab roles (cleanup)
./create-lab-roles.sh cleanup

# Check current AWS identity
aws sts get-caller-identity

# See all running lab resources (by tag)
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Environment,Values=lab \
  --query 'ResourceTagMappingList[].ResourceARN'
```

---

## All 50 Labs

| # | Lab | Services | SAA-C03 Domain | Exam Weight |
|---|-----|----------|----------------|-------------|
| 00 | [00-provider](00-provider/) | Provider config template | — | — |
| 01 | [01-ec2](01-ec2/) | EC2, Launch Template, ASG, Placement Groups | Compute | 20-25% |
| 02 | [02-s3](02-s3/) | S3, Storage Classes, Lifecycle, Versioning | Storage | 15-20% |
| 03 | [03-rds](03-rds/) | RDS MySQL, Multi-AZ, Read Replica | Database | 15-20% |
| 04 | [04-vpc](04-vpc/) | VPC, Subnets, IGW, NAT, SG, NACL | Networking | 20-25% |
| 05 | [05-iam](05-iam/) | IAM Users, Groups, Roles, Policies, MFA | Security | 30% |
| 06 | [06-lambda](06-lambda/) | Lambda, EventBridge, Layers, DLQ | Compute | 20-25% |
| 07 | [07-ecs](07-ecs/) | ECS Cluster, Fargate, Task Definition | Containers | 20-25% |
| 08 | [08-alb-cloudfront](08-alb-cloudfront/) | ALB, Target Groups, CloudFront, ACM | Networking | 20-25% |
| 09 | [09-sqs-sns](09-sqs-sns/) | SQS, SNS, DLQ, FIFO | Messaging | 10-12% |
| 10 | [10-cloudwatch](10-cloudwatch/) | CloudWatch Alarms, Log Groups, Dashboards | Monitoring | 10-15% |
| 11 | [11-api-gateway](11-api-gateway/) | API Gateway REST, Lambda proxy | Serverless | 5-7% |
| 12 | [12-dynamodb](12-dynamodb/) | DynamoDB, GSI, TTL, Streams | Database | 15-20% |
| 13 | [13-elasticache](13-elasticache/) | ElastiCache Redis, cluster mode | Database | 15-20% |
| 14 | [14-kinesis](14-kinesis/) | Kinesis Streams, Firehose, Athena | Analytics | 8-10% |
| 15 | [15-cicd](15-cicd/) | CodeCommit, CodeBuild, CodePipeline | DevOps | 5-8% |
| 16 | [16-migration](16-migration/) | DataSync, Backup, Storage migration | Migration | 5-7% |
| 17 | [17-ml-ai](17-ml-ai/) | SageMaker, Rekognition, AI services | ML/AI | 3-5% |
| 18 | [18-backup-iot](18-backup-iot/) | IoT Core, EventBridge Scheduler | IoT | 3-5% |
| 19 | [19-architecture-complete](19-architecture-complete/) | Full 3-tier architecture | All domains | All |
| 20 | [20-route53](20-route53/) | Route 53, Routing Policies, Health Checks | Networking | 10-12% |
| 21 | [21-documentdb](21-documentdb/) | DocumentDB (MongoDB-compatible) | Database | 5-7% |
| 22 | [22-opensearch](22-opensearch/) | OpenSearch Service, Kibana | Analytics | 5-7% |
| 23 | [23-timestream](23-timestream/) | Timestream (time-series database) | Database | 3-5% |
| 24 | [24-neptune](24-neptune/) | Neptune (graph database) | Database | 3-5% |
| 25 | [25-memorydb](25-memorydb/) | MemoryDB for Redis | Database | 3-5% |
| 26 | [26-waf-shield](26-waf-shield/) | WAF, Shield, Firewall Manager | Security | 8-10% |
| 27 | [27-organizations](27-organizations/) | AWS Organizations, SCPs, OUs | Security | 8-10% |
| 28 | [28-cost-billing](28-cost-billing/) | Cost Explorer, Budgets, Cost Allocation Tags | Billing | 5-7% |
| 29 | [29-aurora](29-aurora/) | Aurora MySQL, Global DB, Serverless v2 | Database | 15-20% |
| 30 | [30-efs-fsx](30-efs-fsx/) | EFS, FSx for Windows, FSx for Lustre | Storage | 8-10% |
| 31 | [31-networking-advanced](31-networking-advanced/) | VPC Peering, Transit Gateway, PrivateLink | Networking | 15-20% |
| 32 | [32-security-monitoring](32-security-monitoring/) | GuardDuty, Inspector, Macie, Security Hub | Security | 8-10% |
| 33 | [33-secrets-ssm](33-secrets-ssm/) | Secrets Manager, SSM Parameter Store | Security | 8-10% |
| 34 | [34-redshift](34-redshift/) | Redshift, Spectrum, RA3 | Analytics | 8-10% |
| 35 | [35-athena-glue](35-athena-glue/) | Athena, Glue ETL, Data Catalog | Analytics | 8-10% |
| 36 | [36-step-functions](36-step-functions/) | Step Functions, Express Workflows | Serverless | 5-7% |
| 37 | [37-eks](37-eks/) | EKS, Node Groups, Fargate Profile | Containers | 10-12% |
| 38 | [38-beanstalk-apprunner](38-beanstalk-apprunner/) | Elastic Beanstalk, App Runner | Compute | 5-7% |
| 39 | [39-cloudformation](39-cloudformation/) | CloudFormation, StackSets, Drift Detection | IaC | 5-7% |
| 40 | [40-eventbridge-mq](40-eventbridge-mq/) | EventBridge Pipes, Amazon MQ | Messaging | 5-7% |
| 41 | [41-systems-manager](41-systems-manager/) | SSM Session Manager, Patch Manager, Run Command | Operations | 8-10% |
| 42 | [42-config](42-config/) | AWS Config, Config Rules, Remediation | Governance | 5-7% |
| 43 | [43-storage-gateway](43-storage-gateway/) | Storage Gateway (File, Volume, Tape) | Storage | 5-7% |
| 44 | [44-network-firewall](44-network-firewall/) | Network Firewall, DNS Firewall | Security | 5-7% |
| 45 | [45-rds-proxy](45-rds-proxy/) | RDS Proxy, connection pooling | Database | 5-7% |
| 46 | [46-batch-emr](46-batch-emr/) | AWS Batch, EMR, big data processing | Analytics | 5-7% |
| 47 | [47-msk](47-msk/) | MSK (Managed Kafka), Kafka Connect | Messaging | 5-7% |
| 48 | [48-datasync-snow](48-datasync-snow/) | DataSync, Snowball Edge, Snow Family | Migration | 5-7% |
| 49 | [49-nlb-gwlb-privatelink](49-nlb-gwlb-privatelink/) | NLB, Gateway LB, PrivateLink, VPC Endpoints | Networking | 10-12% |

---

## Important — Avoid AWS Charges

Every lab is destroy-safe:
- No `deletion_protection = true`
- No `lifecycle { prevent_destroy = true }`
- All resources tagged `Environment = lab`

**Always run `terraform destroy` when you finish a lab.**

```bash
# Verify nothing is left running
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Environment,Values=lab \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text
```

---

## .gitignore

```
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl
```
