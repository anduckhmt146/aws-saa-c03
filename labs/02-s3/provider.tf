terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"

    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"

    }
  }
}

provider "aws" {

  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-saa-c03-labs"
      Environment = "lab"
      Lab         = "02-s3"

    }
  }
}

# Second provider for cross-region replication destination
provider "aws" {
  alias  = "replica"
  region = "us-west-2"

  default_tags {
    tags = {
      Project     = "aws-saa-c03-labs"
      Environment = "lab"
      Lab         = "02-s3-replica"

    }
  }
}
