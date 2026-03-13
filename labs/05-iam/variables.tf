variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "lab_user_name" {

  description = "IAM user name for the lab"
  type        = string
  default     = "lab-user"
}
