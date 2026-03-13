# Lab 15 - CI/CD: CodeCommit, CodeBuild, CodeDeploy, CodePipeline

> Exam weight: **5-8%** of SAA-C03 questions

## What This Lab Creates

- CodeCommit repository (private Git)
- CodeBuild project (build + test + package)
- CodeDeploy app + deployment groups (In-Place + Blue/Green)
- CodePipeline (Source → Build → Approval → Deploy)
- CodeArtifact domain + repository (npm proxy)
- S3 artifact bucket
- IAM roles for each service

## Run

```bash
terraform init
terraform apply
terraform destroy
```

---

## Key Concepts

### Developer Tools Overview

| Service | Purpose | Keyword |
|---------|---------|---------|
| **CodeCommit** | Managed private Git repository | "Private Git" |
| **CodeBuild** | Build, test, package (serverless) | "Build and test" |
| **CodeDeploy** | Automated deployment | "Automated deployment" |
| **CodePipeline** | CI/CD orchestration | "Full CI/CD pipeline" |
| **CodeArtifact** | Artifact/package repository | "Internal packages" |
| **CodeGuru** | ML code review + profiling | "Code quality ML" |

**Full pipeline**: `CodeCommit → CodeBuild → CodeDeploy` orchestrated by `CodePipeline`

### CodeCommit

- Private Git repos, encrypted at rest (KMS) + in transit
- Triggers: Lambda, SNS on push/PR events
- **Note**: AWS deprecated for new customers (2024) — use GitHub/GitLab as source in CodePipeline instead

### CodeBuild

- **Serverless** — no servers to manage
- **Docker-based** — runs in managed containers
- **Pay per build minute**
- `buildspec.yml` defines all build instructions

**buildspec.yml phases**:
```yaml
phases:
  install:    # Install runtimes/tools
  pre_build:  # Setup, login to ECR, run tests
  build:      # Compile, build Docker image
  post_build: # Push to ECR, notify
```

**Compute types**: `BUILD_GENERAL1_SMALL` → `MEDIUM` → `LARGE` → `2XLARGE`

### CodeDeploy

#### Deployment Types

| Type | How | Downtime | Use Case |
|------|-----|---------|---------|
| In-Place | Replace existing | Possible | Simple, cost-effective |
| Blue/Green | New instances, swap | Minimal | Zero-downtime, easy rollback |

#### Deployment Configs (EC2)

| Config | Minimum Healthy | Speed |
|--------|----------------|-------|
| AllAtOnce | 0% | Fastest |
| HalfAtATime | 50% | Medium |
| OneAtATime | ~99% | Safest/Slowest |
| Custom | Your value | Configurable |

#### appspec.yml lifecycle hooks (EC2)
```
ApplicationStop → BeforeInstall → Install → AfterInstall
→ ApplicationStart → ValidateService
```

#### For Lambda deployments:
- `Linear10PercentEvery1Minute` — shift 10% every minute
- `Canary10Percent5Minutes` — 10% for 5 min, then 100%
- `AllAtOnce`

**Auto-rollback**: trigger on CloudWatch alarm or deployment failure

### CodePipeline

- **Orchestrates** the CI/CD workflow
- **Stages**: Source → Build → Test → Approval → Deploy
- At least 2 stages required (Source + one more)
- **Triggers**: CodeCommit push, S3 object change, webhook

**Stage action types**:
- Source: CodeCommit, S3, GitHub, ECR, Bitbucket
- Build: CodeBuild
- Test: CodeBuild, Device Farm
- Deploy: CodeDeploy, CloudFormation, ECS, S3, Elastic Beanstalk
- Invoke: Lambda, Step Functions
- Approval: Manual (blocks pipeline until approved)

### CodeArtifact

- **Package repository**: Maven, npm, PyPI, NuGet, Swift
- **Upstream connections**: proxy public registries
- **Use case**: internal packages, cache public packages, security scanning

### X-Ray (Distributed Tracing)

- Trace requests across services (Lambda, EC2, ECS, API GW)
- Identify bottlenecks, errors, latency
- **Service map**: visual of request flow
- Requires X-Ray SDK in code + IAM permission

**Exam Tip**: "Trace request across microservices" → X-Ray

### Common CI/CD Exam Patterns

```
"Automated deployment to EC2"        → CodeDeploy
"Full CI/CD pipeline"                → CodePipeline
"Build Docker image + push to ECR"   → CodeBuild
"Zero-downtime deployment"           → Blue/Green (CodeDeploy or Elastic Beanstalk)
"Test in staging before production"  → CodePipeline Manual Approval
"Canary deployment Lambda"           → CodeDeploy Linear/Canary config
```
