variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {

  description = "EC2 instance type (General Purpose M5, Compute C5, Memory R5, etc.)"
  type        = string
  default     = "t3.micro" # Free tier eligible
}

variable "key_name" {

  description = "EC2 Key Pair name (must exist in your account)"
  type        = string
  default     = ""
}

variable "asg_min_size" {

  description = "Auto Scaling Group minimum size"
  type        = number
  default     = 1
}

variable "asg_max_size" {

  description = "Auto Scaling Group maximum size"
  type        = number
  default     = 3
}

variable "asg_desired_capacity" {

  description = "Auto Scaling Group desired capacity"
  type        = number
  default     = 1
}
