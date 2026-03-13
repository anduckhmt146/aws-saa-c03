# AWS SAA-C03 Terraform Labs

Hands-on labs using Terraform (HCL) to provision and destroy AWS resources for each service domain in the SAA-C03 exam.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- AWS CLI configured (`aws configure`)
- AWS account with sufficient permissions

## Structure

```
labs/
├── 00-provider/          # Shared provider config reference
├── 01-ec2/               # EC2, Auto Scaling, Placement Groups
├── 02-s3/                # S3 buckets, storage classes, lifecycle
├── 03-rds/               # RDS MySQL, Multi-AZ, Read Replica
├── 04-vpc/               # VPC, Subnets, IGW, NAT Gateway, SGs
├── 05-iam/               # IAM Users, Groups, Roles, Policies
├── 06-lambda/            # Lambda function, triggers, layers
├── 07-ecs/               # ECS Cluster, Fargate task definition
├── 08-alb-cloudfront/    # ALB + CloudFront distribution
├── 09-sqs-sns/           # SQS queues, SNS topics, subscriptions
├── 10-cloudwatch/        # CloudWatch alarms, log groups, dashboards
├── 11-api-gateway/       # REST API Gateway + Lambda integration
├── 12-dynamodb/          # DynamoDB table, GSI, streams
├── 13-elasticache/       # ElastiCache Redis cluster
└── 14-kinesis/           # Kinesis Data Stream + Firehose
```

## How to Use Each Lab

```bash
cd labs/<lab-name>
terraform init
terraform plan
terraform apply

# When done — destroy everything (no charges left behind)
terraform destroy
```

## Important: terraform destroy

Every lab is designed to be fully destroyable:
- No `deletion_protection = true`
- No `lifecycle { prevent_destroy = true }`
- All resources tagged with `Environment = "lab"` for easy identification
- Use `terraform destroy` after each lab to avoid AWS charges

## Labs Overview

| Lab | Services | Exam Weight |
|-----|----------|-------------|
| 01-ec2 | EC2, ASG, Launch Template | 20-25% |
| 02-s3 | S3, Storage Classes, Lifecycle | 15-20% |
| 03-rds | RDS, Multi-AZ, Read Replica | 15-20% |
| 04-vpc | VPC, Subnets, NAT, SG, NACL | 20-25% |
| 05-iam | IAM, Roles, Policies, MFA | 30% (Domain 1) |
| 06-lambda | Lambda, EventBridge, Layers | 20-25% |
| 07-ecs | ECS, Fargate, Task Definition | 20-25% |
| 08-alb-cloudfront | ALB, Target Groups, CloudFront | 20-25% |
| 09-sqs-sns | SQS, SNS, DLQ | 10-12% |
| 10-cloudwatch | CloudWatch, Alarms, Log Groups | 10-15% |
| 11-api-gateway | API Gateway, Lambda Proxy | 5-7% |
| 12-dynamodb | DynamoDB, GSI, TTL, Streams | 15-20% |
| 13-elasticache | ElastiCache Redis | 15-20% |
| 14-kinesis | Kinesis Streams, Firehose | 8-10% |
