variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}
