# 00 - Provider Configuration

Shared provider configuration reference. Each lab includes its own `provider.tf` copied from this template.

## Provider Block

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

## Authentication (pick one)

```bash
# Option 1: AWS CLI profile
aws configure

# Option 2: Environment variables
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"

# Option 3: IAM Role (recommended for EC2/CI)
# Attach role to instance — no keys needed
```

## State (local for labs)

Each lab uses **local state** (`terraform.tfstate`) for simplicity.
Do NOT commit `terraform.tfstate` to git — it may contain secrets.

```bash
# .gitignore
*.tfstate
*.tfstate.backup
.terraform/
```
