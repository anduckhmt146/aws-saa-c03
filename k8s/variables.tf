###############################################################################
# VARIABLES - Lab 50: K8s Microservices + Helm
###############################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (must already exist — created in lab 37-eks)"
  type        = string
  default     = "saa-c03-eks-lab"
}

variable "domain_name" {
  description = "Base domain name for ingress/TLS (e.g. example.com)"
  type        = string
  default     = "example.com"
  # In production: point your Route53 hosted zone here.
  # NLB hostname from ingress-nginx → CNAME or alias record in Route53.
}

variable "app_image_tag" {
  description = "Container image tag to deploy for all microservices"
  type        = string
  default     = "latest"
  # In CI/CD: override with git SHA or semantic version.
  # Pattern: image tag = git commit SHA for immutable, traceable deployments.
  # Never use 'latest' in production — you lose rollback and audit trail.
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "changeme-use-secrets-manager"
  # In production: inject from AWS Secrets Manager via:
  # 1. external-secrets-operator (K8s Secret synced from Secrets Manager)
  # 2. Or Terraform var from AWS SSM Parameter Store:
  #    data "aws_ssm_parameter" "grafana_pw" { name = "/k8s/grafana/admin-password" }
}
