variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "bucket_prefix" {

  description = "Prefix for S3 bucket names (must be globally unique)"
  type        = string
  default     = "saa-lab-02"
}
