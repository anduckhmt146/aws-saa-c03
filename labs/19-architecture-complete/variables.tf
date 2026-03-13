variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "db_password" {
  type      = string
  sensitive = true
  default   = "LabPassword123!"
}
variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}
