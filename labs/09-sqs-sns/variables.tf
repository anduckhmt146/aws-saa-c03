variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "notification_email" {
  description = "Email for SNS subscription (optional)"
  type        = string
  default     = ""
}
