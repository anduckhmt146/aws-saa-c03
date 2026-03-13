variable "aws_region" {
  description = "AWS region for lab resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "lab"
}
