variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "db_username" {

  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "db_password" {

  description = "RDS master password"
  type        = string
  sensitive   = true
  default     = "LabPassword123!" # Change in production
}

variable "db_instance_class" {

  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro" # Free tier eligible
}
