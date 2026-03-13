###############################################################################
# LAB 50 - Kubernetes Control Plane for Microservices + Helm
# AWS SAA-C03 / Kubernetes Hands-On
###############################################################################
#
# WHAT THIS LAB BUILDS:
#   A production-style microservices platform on EKS using Helm:
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │  Internet                                                       │
#   │     │                                                           │
#   │  Route 53  ──►  ALB (ingress-nginx)                            │
#   │                      │                                          │
#   │           ┌──────────┴──────────┐                              │
#   │           │                     │                               │
#   │      /api/users           /api/orders                          │
#   │           │                     │                               │
#   │     user-service          order-service                        │
#   │           │                     │                               │
#   │      RDS (Postgres)       DynamoDB                             │
#   │           │                     │                               │
#   │      ElastiCache (Redis)  SQS (async events)                   │
#   └─────────────────────────────────────────────────────────────────┘
#
# CONTROL PLANE CONCEPTS:
#   The K8s control plane is the brain of the cluster.  On EKS, AWS runs
#   and manages it — you never touch these components directly:
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │  K8s Control Plane (AWS-managed, Multi-AZ)                     │
#   │                                                                  │
#   │  kube-apiserver   ← all kubectl/SDK calls land here             │
#   │       │                                                          │
#   │  etcd             ← distributed KV store, source of truth       │
#   │       │                                                          │
#   │  kube-scheduler   ← assigns pods to nodes (affinity, taints)    │
#   │       │                                                          │
#   │  controller-mgr   ← reconciles desired vs actual state          │
#   │       │             (ReplicaSet, Deployment, Job controllers)    │
#   │  cloud-controller ← syncs K8s resources with AWS (ELBs, etc.)  │
#   └─────────────────────────────────────────────────────────────────┘
#
# DATA PLANE (your responsibility):
#   ┌─────────────────────────────────────────────────────────────────┐
#   │  Node 1 (EC2)          Node 2 (EC2)                            │
#   │  ├─ kubelet             ├─ kubelet                              │
#   │  ├─ kube-proxy          ├─ kube-proxy                          │
#   │  ├─ containerd          ├─ containerd                          │
#   │  ├─ vpc-cni             ├─ vpc-cni                             │
#   │  └─ pods...             └─ pods...                             │
#   └─────────────────────────────────────────────────────────────────┘
#
# HELM CONCEPTS:
#   Helm = K8s package manager.  Three core ideas:
#   1. Chart    - a package of K8s templates + defaults (values.yaml)
#   2. Release  - one deployed instance of a chart (helm install)
#   3. Revision - each helm upgrade creates a new revision (rollback possible)
#
#   Chart structure:
#     mychart/
#       Chart.yaml          ← chart metadata (name, version, dependencies)
#       values.yaml         ← default configuration values
#       templates/          ← Go template files rendered into K8s manifests
#         deployment.yaml
#         service.yaml
#         ingress.yaml
#         _helpers.tpl      ← shared template functions (named templates)
#       charts/             ← sub-charts (dependencies)
#
#   Templating:
#     {{ .Values.image.tag }}         ← reference values.yaml
#     {{ .Release.Name }}-api         ← built-in objects (Release, Chart, etc.)
#     {{ include "helpers.name" . }}  ← call a named template
#
# NAMESPACE STRATEGY (multi-tenant cluster):
#   ingress-nginx   ← shared ingress controller
#   cert-manager    ← TLS certificate automation
#   monitoring      ← Prometheus + Grafana
#   production      ← prod microservices
#   staging         ← staging microservices
#   Each namespace gets its own RBAC, NetworkPolicy, ResourceQuota.
#
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
      # Helm provider talks to K8s API to install/upgrade/rollback charts.
      # It uses the same kubeconfig auth as kubectl.
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
      # Kubernetes provider manages raw K8s resources (Namespace, RBAC, etc.)
      # alongside Helm releases in the same Terraform state.
    }
  }
}

###############################################################################
# PROVIDERS
# The Helm and Kubernetes providers authenticate to EKS using the cluster's
# CA cert + a short-lived token from aws eks get-token.
# exec { } block calls the AWS CLI to mint a fresh token — this avoids
# hardcoding credentials and respects IAM role assumption.
###############################################################################

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster" "main" {
  name = var.cluster_name
  # Reference the cluster created in lab 37-eks (or any existing EKS cluster).
  # This data source pulls: endpoint, CA cert, OIDC issuer.
}

data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
  # Returns a short-lived bearer token for the K8s API server.
  # Expires every 15 minutes; Terraform refreshes automatically.
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

###############################################################################
# NAMESPACES
# K8s namespaces provide soft isolation: separate RBAC, NetworkPolicy,
# ResourceQuota, LimitRange.  Not a security boundary like VM isolation —
# a pod CAN reach another namespace unless NetworkPolicy blocks it.
###############################################################################

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
    labels = {
      "app.kubernetes.io/name" = "ingress-nginx"
    }
  }
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    labels = {
      # cert-manager webhook requires this label to exclude itself from
      # its own webhook admission (prevents bootstrapping deadlock).
      "certmanager.k8s.io/disable-validation" = "true"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_namespace" "production" {
  metadata {
    name = "production"
    labels = {
      environment = "production"
    }
  }
}

resource "kubernetes_namespace" "staging" {
  metadata {
    name = "staging"
    labels = {
      environment = "staging"
    }
  }
}

###############################################################################
# RESOURCE QUOTAS
# Prevent a single namespace from starving others.
# K8s admission controller enforces these at pod creation time.
###############################################################################

resource "kubernetes_resource_quota" "production" {
  metadata {
    name      = "production-quota"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"           = "4"    # Total CPU requests across all pods
      "requests.memory"        = "8Gi"  # Total memory requests
      "limits.cpu"             = "8"    # Total CPU limits
      "limits.memory"          = "16Gi" # Total memory limits
      "pods"                   = "50"   # Max number of pods
      "services"               = "20"   # Max number of Services
      "persistentvolumeclaims" = "10"
    }
  }
  # CONCEPT: requests vs limits
  #   requests = what the scheduler uses to PLACE the pod on a node.
  #              Guaranteed to the pod; node must have this much free.
  #   limits   = the MAXIMUM a pod can use. If exceeded: CPU throttled,
  #              memory → OOMKill.
  # Best practice: always set both. requests ~ 50-70% of limits for headroom.
}

###############################################################################
# LIMIT RANGE
# Sets default requests/limits for containers that don't specify them.
# Without LimitRange, unset limits = a pod can consume the entire node.
###############################################################################

resource "kubernetes_limit_range" "production" {
  metadata {
    name      = "production-limits"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m" # 0.5 CPU (500 millicores)
        memory = "256Mi"
      }
      default_request = {
        cpu    = "100m" # 0.1 CPU
        memory = "128Mi"
      }
      max = {
        cpu    = "2"
        memory = "2Gi"
      }
    }

    limit {
      type = "Pod"
      max = {
        cpu    = "4"
        memory = "4Gi"
      }
    }
  }
}

###############################################################################
# NETWORK POLICIES
# By default, all pods in a K8s cluster can reach all other pods — no firewall.
# NetworkPolicy resources implement L3/L4 firewall rules via the CNI plugin.
# AWS VPC CNI supports NetworkPolicy via the Network Policy Controller add-on.
#
# CONCEPT - Default-deny pattern (zero trust networking):
#   1. Apply a default-deny-all policy to the namespace.
#   2. Then explicitly allow only the traffic you need.
#   This is analogous to a Security Group starting with no inbound rules.
###############################################################################

resource "kubernetes_network_policy" "default_deny_production" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    pod_selector {} # Empty = applies to ALL pods in namespace

    policy_types = ["Ingress", "Egress"]
    # No ingress/egress rules = everything is denied.
    # Pods can still reach DNS (kube-dns) because of a separate allow rule.
  }
}

resource "kubernetes_network_policy" "allow_dns" {
  metadata {
    name      = "allow-dns-egress"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    pod_selector {} # All pods

    policy_types = ["Egress"]

    egress {
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
      # Allow DNS queries to any destination (kube-dns lives in kube-system).
      # Without this, service name resolution breaks and all HTTP calls fail.
    }
  }
}

resource "kubernetes_network_policy" "user_service" {
  metadata {
    name      = "user-service-policy"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "user-service"
      }
    }

    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        # Only ingress-nginx pods can reach user-service
        namespace_selector {
          match_labels = {
            "app.kubernetes.io/name" = "ingress-nginx"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }

    egress {
      # user-service → RDS (Postgres)
      ports {
        protocol = "TCP"
        port     = "5432"
      }
    }

    egress {
      # user-service → ElastiCache (Redis)
      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }
  }
}

###############################################################################
# RBAC - ROLE-BASED ACCESS CONTROL
# K8s RBAC has four objects:
#   Role          - namespaced permissions (verbs on resources)
#   ClusterRole   - cluster-wide permissions
#   RoleBinding   - binds Role to subjects (users, groups, ServiceAccounts)
#   ClusterRoleBinding - binds ClusterRole to subjects
#
# EXAM TIP: IRSA = IAM role attached to a K8s ServiceAccount.
#   The pod uses the ServiceAccount; K8s RBAC controls what the pod can DO
#   inside the cluster.  IAM controls what the pod can DO with AWS APIs.
#   They are orthogonal systems.
###############################################################################

resource "kubernetes_service_account" "user_service" {
  metadata {
    name      = "user-service"
    namespace = kubernetes_namespace.production.metadata[0].name
    annotations = {
      # IRSA annotation: this SA can assume the IAM role below.
      "eks.amazonaws.com/role-arn" = aws_iam_role.user_service.arn
    }
  }
}

resource "kubernetes_role" "user_service" {
  metadata {
    name      = "user-service-role"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["get", "watch", "list"]
    # user-service can read ConfigMaps and Secrets in its own namespace.
    # It cannot create/delete them. Least privilege inside the cluster.
  }
}

resource "kubernetes_role_binding" "user_service" {
  metadata {
    name      = "user-service-role-binding"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.user_service.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.user_service.metadata[0].name
    namespace = kubernetes_namespace.production.metadata[0].name
  }
}

###############################################################################
# IAM ROLES FOR SERVICE ACCOUNTS (IRSA)
# user-service needs to:
#   - Read secrets from Secrets Manager (DB password, JWT secret)
#   - Publish messages to SQS (user events)
#   - Read/write user profile images from S3
###############################################################################

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "user_service_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:production:user-service"]
      # IMPORTANT: the ServiceAccount name and namespace must match exactly.
      # This is the binding between the K8s world and the IAM world.
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "user_service" {
  name               = "${var.cluster_name}-user-service-role"
  assume_role_policy = data.aws_iam_policy_document.user_service_assume.json

  tags = {
    Service = "user-service"
    Lab     = "50-k8s-microservices-helm"
  }
}

data "aws_iam_policy_document" "user_service_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:production/user-service/*"
    ]
    # Fine-grained: only secrets under production/user-service/ prefix.
  }

  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes"
    ]
    resources = [aws_sqs_queue.user_events.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.user_profiles.arn}/profiles/*"]
    # Only the /profiles/ prefix — not the entire bucket.
  }
}

resource "aws_iam_role_policy" "user_service" {
  name   = "user-service-policy"
  role   = aws_iam_role.user_service.id
  policy = data.aws_iam_policy_document.user_service_permissions.json
}

###############################################################################
# SQS QUEUE - ASYNC MICROSERVICE COMMUNICATION
# user-service → SQS → order-service (event-driven)
# This decouples services: order-service can be down without losing events.
# Pattern: Outbox → SQS → Consumer (at-least-once delivery).
###############################################################################

resource "aws_sqs_queue" "user_events" {
  name                       = "${var.cluster_name}-user-events"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400 # 24 hours

  # Dead Letter Queue for failed processing
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.user_events_dlq.arn
    maxReceiveCount     = 3 # After 3 failed attempts, move to DLQ
  })

  tags = {
    Service = "user-service"
    Pattern = "async-event"
  }
}

resource "aws_sqs_queue" "user_events_dlq" {
  name                      = "${var.cluster_name}-user-events-dlq"
  message_retention_seconds = 1209600 # 14 days - time to investigate failures
}

###############################################################################
# S3 BUCKET - USER PROFILE IMAGES
###############################################################################

resource "aws_s3_bucket" "user_profiles" {
  bucket = "${var.cluster_name}-user-profiles-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "user_profiles" {
  bucket = aws_s3_bucket.user_profiles.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  # Pods use IRSA credentials to read/write — no public access needed.
}

###############################################################################
# HELM RELEASES
# helm_release = one deployed instance of a Helm chart.
# Terraform tracks it in state; terraform destroy = helm uninstall.
###############################################################################

#------------------------------------------------------------------------------
# ingress-nginx
# The ingress controller is a reverse proxy (Nginx) that:
#   1. Watches K8s Ingress resources
#   2. Dynamically reconfigures Nginx routing rules
#   3. Terminates TLS (with cert-manager providing certificates)
#   4. Sits behind an AWS NLB (Network Load Balancer)
#
# EXAM TIP: Ingress vs Service type LoadBalancer:
#   LoadBalancer Service = one ALB/NLB per Service (expensive, 1:1 ratio)
#   Ingress = one ALB/NLB for MANY services, path/host-based routing (efficient)
#------------------------------------------------------------------------------

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.9.0"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  # Helm provider v3+: set is a list of objects (not blocks). NLB, 2 replicas, metrics.
  set = [
    { name = "controller.service.type", value = "LoadBalancer" },
    { name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type", value = "nlb" },
    { name = "controller.replicaCount", value = "2" },
    { name = "controller.metrics.enabled", value = "true" },
    { name = "controller.podAnnotations.prometheus\\.io/scrape", value = "true" },
  ]

  values = [
    yamlencode({
      controller = {
        resources = {
          requests = { cpu = "100m", memory = "90Mi" }
          limits   = { cpu = "500m", memory = "256Mi" }
        }
        # PodDisruptionBudget: keep at least 1 pod available during node drain.
        podDisruptionBudget = {
          enabled      = true
          minAvailable = 1
        }
        # Topology spread: place replicas in different AZs.
        topologySpreadConstraints = [
          {
            maxSkew           = 1
            topologyKey       = "topology.kubernetes.io/zone"
            whenUnsatisfiable = "DoNotSchedule"
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "ingress-nginx"
              }
            }
          }
        ]
      }
    })
  ]

  depends_on = [kubernetes_namespace.ingress_nginx]
}

#------------------------------------------------------------------------------
# cert-manager
# Automates TLS certificate lifecycle:
#   1. You create a Certificate resource pointing to an Issuer (Let's Encrypt)
#   2. cert-manager requests a cert via ACME protocol (DNS-01 or HTTP-01)
#   3. Stores the signed cert in a K8s Secret
#   4. Renews automatically 30 days before expiry
#
# CONCEPT - Certificate chain in K8s:
#   Issuer/ClusterIssuer → CertificateRequest → Certificate → Secret
#   Ingress resource references the Secret by name for TLS termination.
#------------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.0"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set = [
    { name = "installCRDs", value = "true" },
    { name = "global.leaderElection.namespace", value = "cert-manager" },
  ]

  depends_on = [kubernetes_namespace.cert_manager]
}

#------------------------------------------------------------------------------
# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# Full observability stack. Includes:
#   - Prometheus Operator (manages Prometheus via CRDs: PrometheusRule, etc.)
#   - Grafana with pre-built dashboards for K8s and services
#   - Alertmanager for routing alerts to PagerDuty/Slack/email
#   - node-exporter DaemonSet for node-level metrics
#   - kube-state-metrics for K8s object metrics (pod restarts, etc.)
#------------------------------------------------------------------------------

resource "helm_release" "prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "56.0.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set = [
    { name = "grafana.adminPassword", value = var.grafana_admin_password },
    { name = "prometheus.prometheusSpec.retention", value = "15d" },
  ]

  values = [
    yamlencode({
      grafana = {
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          }
          hosts = ["grafana.${var.domain_name}"]
          tls = [{
            secretName = "grafana-tls"
            hosts      = ["grafana.${var.domain_name}"]
          }]
        }
      }
      prometheus = {
        prometheusSpec = {
          # Scrape all ServiceMonitor CRDs in any namespace.
          # Default is to only scrape the same namespace as Prometheus.
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    helm_release.ingress_nginx,
    helm_release.cert_manager
  ]
}

#------------------------------------------------------------------------------
# Our microservices app — deployed via a custom Helm chart
# The chart lives in ./helm/microservices-app/
# It deploys: user-service, order-service, and their shared ConfigMaps.
#------------------------------------------------------------------------------

resource "helm_release" "microservices" {
  name      = "microservices"
  chart     = "${path.module}/helm/microservices-app"
  namespace = kubernetes_namespace.production.metadata[0].name

  values = [
    yamlencode({
      global = {
        environment  = "production"
        imageTag     = var.app_image_tag
        ecrRegistry  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
        clusterName  = var.cluster_name
        domainName   = var.domain_name
        sqsQueueUrl  = aws_sqs_queue.user_events.url
        s3BucketName = aws_s3_bucket.user_profiles.bucket
      }

      userService = {
        replicaCount       = 2
        serviceAccountName = kubernetes_service_account.user_service.metadata[0].name
        image = {
          repository = "user-service"
          tag        = var.app_image_tag
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        hpa = {
          enabled     = true
          minReplicas = 2
          maxReplicas = 10
          targetCPU   = 70
        }
      }

      orderService = {
        replicaCount = 2
        image = {
          repository = "order-service"
          tag        = var.app_image_tag
        }
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        hpa = {
          enabled     = true
          minReplicas = 2
          maxReplicas = 8
          targetCPU   = 70
        }
      }

      ingress = {
        enabled   = true
        className = "nginx"
        host      = "api.${var.domain_name}"
        tls = {
          enabled    = true
          secretName = "api-tls"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.production,
    helm_release.ingress_nginx,
    helm_release.cert_manager,
    kubernetes_network_policy.user_service,
    kubernetes_role_binding.user_service
  ]
}

###############################################################################
# HORIZONTAL POD AUTOSCALER (HPA)
# HPA watches metrics and adjusts Deployment replica count automatically.
#
# Metrics sources:
#   1. CPU/Memory  - from metrics-server (built into kube-prometheus-stack)
#   2. Custom      - from Prometheus via KEDA or custom metrics API adapter
#   3. External    - SQS queue depth, RDS connections (via KEDA)
#
# CONCEPT - How HPA works:
#   1. metrics-server scrapes kubelet for pod CPU/memory every 15s
#   2. HPA controller polls metrics-server every 15s
#   3. Calculates: desiredReplicas = ceil(currentReplicas * (currentMetric / target))
#   4. Sends scale event to Deployment controller
#   5. Deployment controller creates/deletes ReplicaSet pods
#
# EXAM TIP: HPA scales PODS; Cluster Autoscaler scales NODES.
#   Order of operations: HPA tries to schedule more pods → if no capacity,
#   pods become Pending → Cluster Autoscaler sees Pending pods → adds a node.
###############################################################################

# Note: HPA resources are defined inside the Helm chart templates.
# See helm/microservices-app/templates/hpa.yaml for the template.
# The values above (hpa.enabled, hpa.targetCPU) control the HPA behavior.

###############################################################################
# OUTPUTS
###############################################################################

output "ingress_nginx_lb_hostname" {
  description = "NLB hostname for ingress-nginx (point DNS here)"
  value       = "Run: kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "https://grafana.${var.domain_name}"
}

output "api_url" {
  description = "Microservices API base URL"
  value       = "https://api.${var.domain_name}"
}

output "helm_status_commands" {
  description = "Useful helm commands for this deployment"
  value       = <<-EOT
    # List all releases
    helm list -A

    # Check microservices release status
    helm status microservices -n production

    # View rendered templates (dry-run)
    helm template microservices ./helm/microservices-app -n production

    # Rollback to previous version
    helm rollback microservices -n production

    # Upgrade with new image tag
    helm upgrade microservices ./helm/microservices-app -n production \
      --set global.imageTag=v1.2.3 --atomic --timeout 5m
    # --atomic: rolls back automatically if upgrade fails
    # --timeout: how long to wait for resources to become ready
  EOT
}

output "kubectl_useful_commands" {
  description = "Useful kubectl commands"
  value       = <<-EOT
    # View all pods in production namespace
    kubectl get pods -n production -o wide

    # Stream logs from user-service
    kubectl logs -n production -l app.kubernetes.io/name=user-service -f --tail=100

    # Exec into a pod for debugging
    kubectl exec -n production -it deploy/user-service -- /bin/sh

    # View HPA status (shows current CPU %, current/desired replicas)
    kubectl get hpa -n production

    # Describe a pod (shows events, resource usage, node placement)
    kubectl describe pod -n production -l app.kubernetes.io/name=user-service

    # Port-forward user-service for local testing
    kubectl port-forward -n production svc/user-service 8080:8080

    # View NetworkPolicy
    kubectl get networkpolicy -n production

    # Validate IRSA is working (should show AWS_ROLE_ARN env var)
    kubectl exec -n production -it deploy/user-service -- env | grep AWS
  EOT
}

###############################################################################
# SAA-C03 / K8s EXAM CHEATSHEET
# ============================================================================
# Q: What is the K8s control plane? What does AWS manage in EKS?
# A: API server, etcd, scheduler, controller-manager, cloud-controller.
#    AWS manages ALL of these in EKS — HA across AZs, patched, monitored.
#    You only manage the data plane (nodes + pods).
#
# Q: What is Helm used for?
# A: Package manager for K8s. Charts bundle related K8s manifests + config.
#    Releases are tracked; you can upgrade, rollback, or delete as a unit.
#
# Q: How do pods authenticate to AWS services?
# A: IRSA (IAM Roles for Service Accounts). Pod's ServiceAccount has an
#    annotation with an IAM role ARN. EKS OIDC provider issues tokens that
#    STS accepts to mint temp credentials. No secrets stored in the cluster.
#
# Q: How does HPA work with Cluster Autoscaler?
# A: HPA adds pods (if node has capacity). If not, pods go Pending.
#    Cluster Autoscaler sees Pending pods → provisions new EC2 node.
#    Karpenter does the same but faster and can right-size instance type.
#
# Q: Ingress vs Service LoadBalancer?
# A: LoadBalancer Service = 1 NLB per service (expensive at scale).
#    Ingress = 1 NLB + controller routes to many services by path/hostname.
#    Use Ingress for HTTP/HTTPS; LoadBalancer for non-HTTP (gRPC, MQTT).
#
# Q: What is a NetworkPolicy? Default behavior without one?
# A: Without NetworkPolicy: all pods can reach all pods (flat network).
#    NetworkPolicy = K8s firewall rules (L3/L4). Empty podSelector applies
#    to all pods. Default-deny-all + explicit allows = zero-trust networking.
#
# Q: What are CRDs?
# A: Custom Resource Definitions extend the K8s API.  cert-manager adds
#    Certificate, Issuer objects. Prometheus Operator adds PrometheusRule,
#    ServiceMonitor. You interact with them like built-in resources (kubectl get).
###############################################################################
