terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = "aws-saa-c03-labs", Environment = "lab", Lab = "14-kinesis" } }
}
