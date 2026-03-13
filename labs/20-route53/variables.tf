variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Set to your real domain to use a public hosted zone (e.g. "example.com")
# Leave empty to skip public zone creation
variable "domain_name" {
  description = "Root domain name for public hosted zone"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  type    = string
  default = "10.99.0.0/16"
}
