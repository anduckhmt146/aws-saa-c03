variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "container_image" {

  description = "Docker image to run"
  type        = string
  default     = "nginx:latest"
}
