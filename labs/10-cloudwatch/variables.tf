variable "aws_region" {
  type    = string
  default = "us-east-1"
}


variable "alarm_email" {


  description = "Email for CloudWatch alarm notifications"
  type        = string
  default     = ""
}