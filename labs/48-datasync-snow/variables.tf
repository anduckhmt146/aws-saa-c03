variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "lab-datasync-snow"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "lab"
}
