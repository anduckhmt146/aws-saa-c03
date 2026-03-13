variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_runtime" {

  description = "Lambda runtime"
  type        = string
  default     = "python3.12"
}
