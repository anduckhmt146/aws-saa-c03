###############################################################################
# LAB 37 - Amazon EKS (Elastic Kubernetes Service)
# AWS SAA-C03 Exam Prep
###############################################################################
#
# CORE CONCEPT: EKS = AWS-managed Kubernetes
#   - AWS manages the CONTROL PLANE (API server, etcd, scheduler, controller
#     manager). You never see those EC2 instances; AWS keeps them HA across
#     multiple AZs automatically.
#   - You manage (or let AWS manage) the DATA PLANE = worker nodes.
#
# EKS vs ECS (VERY common SAA-C03 question):
#   ECS  = AWS-proprietary orchestrator. Simpler to operate. Deep AWS
#          integration out of the box. Good when the team doesn't know K8s.
#   EKS  = Kubernetes standard. Portable workloads. More complex. Good when
#          the team already uses K8s or needs Helm/K8s ecosystem tools.
#   Both support FARGATE (serverless compute - no nodes to manage).
#   Both support EC2 launch type for cost/performance control.
#
# NODE GROUP TYPES:
#   1. Managed node groups  - AWS provisions EC2, applies security patches,
#                             handles node drain on termination. Still EC2.
#   2. Self-managed nodes   - You own the ASG, AMI, lifecycle entirely.
#   3. Fargate profiles     - Serverless; no nodes at all. AWS allocates
#                             vCPU/memory per pod. Pay per pod-second.
#                             Limitations: no DaemonSets, no privileged pods,
#                             no GPU, max 4 vCPU / 30 GB per pod.
#
# AUTOSCALING:
#   Cluster Autoscaler  - traditional K8s project; talks to AWS ASG API.
#                         Scales node groups up when pods are unschedulable.
#   Karpenter           - AWS-built, faster, more cost-aware. Provisions nodes
#                         directly (bypasses ASG). Can right-size node type per
#                         pod requirements. SAA-C03 tip: Karpenter = newer,
#                         preferred for flexibility and speed.
#
# IRSA (IAM Roles for Service Accounts):
#   Pods need AWS permissions (e.g., read S3). IRSA lets a Kubernetes
#   ServiceAccount assume an IAM role via OIDC federation. Fine-grained,
#   per-pod IAM - no need to attach broad permissions to the node role.
#   Mechanism: EKS OIDC provider -> IAM trust policy -> pod gets temp creds.
#
# EKS ADD-ONS (managed by AWS, version-upgraded independently):
#   - vpc-cni      : AWS VPC CNI plugin; assigns VPC IPs directly to pods.
#                    Each pod gets a real VPC IP (from ENI secondary IPs).
#   - coredns      : Cluster-internal DNS; resolves Service names to ClusterIPs.
#   - kube-proxy   : Manages iptables/ipvs rules for Service -> Pod routing.
#   - aws-ebs-csi-driver: Allows PersistentVolumes backed by EBS. Required for
#                    stateful workloads on EKS 1.23+.
#
# NETWORKING:
#   - Private subnets: tag kubernetes.io/role/internal-elb = 1
#   - Public subnets : tag kubernetes.io/role/elb = 1
#   - These tags are required for AWS Load Balancer Controller to
#     auto-discover subnets when creating ALBs/NLBs for K8s Services/Ingresses.
#
# SECURITY:
#   - Cluster endpoint can be public, private, or both.
#   - Enable envelope encryption with KMS for Kubernetes Secrets at rest.
#   - aws-auth ConfigMap (or newer EKS Access Entries) maps IAM -> K8s RBAC.
#
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# VARIABLES
###############################################################################

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "saa-c03-eks-lab"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = "EC2 instance type for managed node group"
  type        = string
  default     = "t3.medium"
  # t3.medium = 2 vCPU, 4 GB RAM. Minimum practical size for running
  # system add-ons (CoreDNS, kube-proxy, VPC CNI) plus app pods.
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

# Caller identity - used to build ARN references
data "aws_caller_identity" "current" {}

# EKS optimized AMI for the managed node group (informational)
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2/recommended/image_id"
  # SAA-C03: EKS managed node groups use EKS-optimized Amazon Linux 2 AMIs
  # by default. These include kubelet, containerd, and AWS VPC CNI pre-installed.
}

###############################################################################
# VPC AND NETWORKING
# EKS requires subnets in at least 2 AZs for control plane HA.
###############################################################################

resource "aws_vpc" "eks" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  # DNS support is REQUIRED for EKS. CoreDNS resolves internal service names
  # to VPC DNS (169.254.169.253), which then forwards to VPC resolver.

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "eks" {
  vpc_id = aws_vpc.eks.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# PUBLIC SUBNETS - for load balancers (ALB/NLB created by K8s Ingress/Service)
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.eks.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    # EXAM TIP: This tag tells the AWS Load Balancer Controller which
    # subnets to use for internet-facing load balancers created by Ingress
    # resources with annotation: kubernetes.io/ingress.class: alb
  }
}

# PRIVATE SUBNETS - for worker nodes and internal load balancers
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.eks.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                        = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    # This tag is for INTERNAL load balancers (Service type: LoadBalancer
    # with annotation service.beta.kubernetes.io/aws-load-balancer-internal).
  }
}

# NAT GATEWAY - nodes in private subnets need outbound internet for:
#   pulling container images from ECR/DockerHub, calling AWS APIs, etc.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "eks" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  # NAT Gateway lives in a PUBLIC subnet; nodes in PRIVATE subnets route
  # outbound traffic through it. This is the standard EKS network topology.

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# IAM - CLUSTER ROLE
# The EKS control plane assumes this role to call AWS APIs on your behalf:
# describe EC2 instances, manage ENIs for the VPC CNI, create NLBs, etc.
###############################################################################

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = {
    Name = "${var.cluster_name}-cluster-role"
    # EXAM TIP: The cluster role must have AmazonEKSClusterPolicy attached.
    # AWS manages this policy - it grants EKS permission to use EC2, ELB,
    # IAM (for node bootstrap), CloudWatch, etc.
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

###############################################################################
# IAM - NODE GROUP ROLE
# EC2 worker nodes assume this role. Used by:
#   - kubelet to call ECR (pull images)
#   - VPC CNI to manage ENIs / assign IPs to pods
#   - Node bootstrap scripts
###############################################################################

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json

  tags = {
    Name = "${var.cluster_name}-node-role"
  }
}

# These three policies are the MINIMUM required for managed node groups:
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  # Allows nodes to connect to the cluster, describe ASG, etc.
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  # VPC CNI plugin needs to create/delete/describe ENIs and assign IPs.
  # EXAM TIP: With IRSA you can move this to a dedicated ServiceAccount
  # instead of the node role (principle of least privilege).
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  # Allows kubelet to pull images from ECR without explicit credentials.
}

###############################################################################
# IAM - FARGATE POD EXECUTION ROLE
# Fargate runs pods in isolated micro-VMs. This role is assumed by the
# Fargate infrastructure (not your pod) to:
#   - Pull container images from ECR
#   - Write pod logs to CloudWatch
###############################################################################

data "aws_iam_policy_document" "fargate_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks-fargate-pods.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fargate_pod_execution" {
  name               = "${var.cluster_name}-fargate-pod-execution-role"
  assume_role_policy = data.aws_iam_policy_document.fargate_assume_role.json

  tags = {
    Name = "${var.cluster_name}-fargate-pod-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution_policy" {
  role       = aws_iam_role.fargate_pod_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

###############################################################################
# SECURITY GROUPS
###############################################################################

resource "aws_security_group" "eks_cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.eks.id

  # Control plane endpoint: nodes connect to port 443 (K8s API server)
  ingress {
    description = "Allow nodes to communicate with control plane"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eks.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_security_group" "eks_nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.eks.id

  # Node-to-node communication (required for pod-to-pod networking)
  ingress {
    description = "Node to node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Control plane to nodes (kubelet port, webhook ports)
  ingress {
    description     = "Control plane to nodes"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-nodes-sg"
  }
}

###############################################################################
# EKS CLUSTER
###############################################################################

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = true
    endpoint_private_access = true
    # EXAM TIP: endpoint_public_access = true allows kubectl from outside VPC.
    # For production, set to false and use a bastion or VPN.
    # endpoint_private_access = true allows nodes inside the VPC to reach
    # the API server without leaving the VPC (via private DNS).
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
    # KMS envelope encryption for Kubernetes Secrets at rest in etcd.
    # EXAM TIP: Without this, Secrets are base64-encoded (not encrypted)
    # in etcd. Enabling this adds a KMS data key layer.
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
  # Logs ship to CloudWatch Logs under /aws/eks/<cluster>/cluster
  # EXAM TIP: audit logs record all API calls - useful for security analysis.

  tags = {
    Name = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.cluster_name}-kms-key"
  }
}

###############################################################################
# MANAGED NODE GROUP
# AWS provisions and manages the lifecycle of EC2 nodes:
#   - Creates ASG with EKS-optimized AMI
#   - Handles node draining before termination (graceful pod eviction)
#   - Applies security patches and updates
###############################################################################

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-managed-ng"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id
  # Best practice: nodes in PRIVATE subnets. Pods need outbound internet
  # (ECR image pulls, AWS API calls) -> NAT Gateway handles that.

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
    # Cluster Autoscaler or Karpenter will adjust desired_size based on
    # pending pods. Terraform will NOT override changes made by autoscaler
    # if you use lifecycle ignore_changes on desired_size.
  }

  update_config {
    max_unavailable = 1
    # During node group updates (AMI upgrades), at most 1 node is unavailable
    # at a time. Pods are drained before the node is terminated.
  }

  ami_type      = "AL2_x86_64"
  capacity_type = "ON_DEMAND"
  # capacity_type = "SPOT" for cost savings (up to 90% cheaper).
  # EXAM TIP: SPOT nodes can be interrupted. Use mixed node groups or
  # spread across multiple instance types/AZs for resilience.
  disk_size = 20

  remote_access {
    ec2_ssh_key               = null
    source_security_group_ids = []
    # For production, disable SSH. Use SSM Session Manager instead.
    # EXAM TIP: SSM = no inbound port 22, no bastion, full audit trail.
  }

  labels = {
    role        = "worker"
    environment = "lab"
  }

  taint {
    key    = "dedicated"
    value  = "lab"
    effect = "NO_SCHEDULE"
    # Taints prevent pods from being scheduled on a node unless the pod
    # has a matching toleration. Useful for dedicated node groups.
  }

  tags = {
    Name = "${var.cluster_name}-managed-ng"
    # Auto-scaling tags required for Cluster Autoscaler:
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
    # Ignore desired_size so Cluster Autoscaler/Karpenter can manage it
    # without Terraform reverting to the defined value on every apply.
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only
  ]
}

###############################################################################
# FARGATE PROFILE
# Allows specific pods (matched by namespace + labels) to run on Fargate.
# No nodes are provisioned; AWS allocates micro-VM per pod.
#
# EXAM TIP - Fargate limitations on EKS:
#   - No DaemonSets (Fargate doesn't have nodes to place them on)
#   - No privileged containers
#   - No GPU workloads
#   - No persistent volumes via EBS (use EFS instead)
#   - Pods must match a Fargate profile selector to run on Fargate
#   - Max 4 vCPU and 30 GB memory per pod
###############################################################################

resource "aws_eks_fargate_profile" "app" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "${var.cluster_name}-fargate-profile"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = aws_subnet.private[*].id
  # IMPORTANT: Fargate pods can only run in PRIVATE subnets.
  # They need outbound internet via NAT Gateway for ECR image pulls.

  selector {
    namespace = "fargate-apps"
    labels = {
      compute = "fargate"
    }
    # Any pod in the "fargate-apps" namespace with label compute=fargate
    # will be scheduled on Fargate instead of EC2 nodes.
  }

  selector {
    namespace = "kube-system"
    labels = {
      k8s-app = "kube-dns"
    }
    # CoreDNS pods in kube-system can run on Fargate.
    # Requires patching CoreDNS deployment to remove the EC2 node affinity.
  }

  tags = {
    Name = "${var.cluster_name}-fargate-profile"
  }

  depends_on = [
    aws_iam_role_policy_attachment.fargate_pod_execution_policy
  ]
}

###############################################################################
# EKS ADD-ONS
# Managed add-ons are installed and upgraded by AWS independently of the
# cluster version. They replace self-managed chart installations.
#
# EXAM TIP: Add-on versions must be compatible with the cluster K8s version.
# AWS will block incompatible upgrades. You can configure PRESERVE or OVERWRITE
# conflict resolution (what to do if custom config exists).
###############################################################################

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # vpc-cni: AWS VPC Container Network Interface
  # - Assigns actual VPC IPs to pods (from ENI secondary IPs)
  # - Each node can host N pods = number of secondary IPs across its ENIs
  # - Formula: (number of ENIs) * (IPs per ENI - 1) + 1
  # - t3.medium supports 3 ENIs * 6 IPs each = up to 17 pods per node
  # EXAM TIP: If pods can't be scheduled due to "too many pods", you may
  # be hitting this ENI IP limit. Solution: larger instance type.

  tags = {
    Name = "${var.cluster_name}-vpc-cni-addon"
  }

  depends_on = [aws_eks_cluster.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # CoreDNS provides cluster-internal DNS resolution.
  # Service "my-svc" in namespace "my-ns" resolves to:
  #   my-svc.my-ns.svc.cluster.local
  # Pods use CoreDNS by default (kube-dns Service points to CoreDNS pods).

  tags = {
    Name = "${var.cluster_name}-coredns-addon"
  }

  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  # kube-proxy runs on every node as a DaemonSet.
  # It maintains iptables (or ipvs) rules that implement K8s Services:
  # ClusterIP -> actual pod IP mapping. When you curl a Service ClusterIP,
  # iptables intercepts and redirects to a healthy pod endpoint.

  tags = {
    Name = "${var.cluster_name}-kube-proxy-addon"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  # EXAM TIP: EBS CSI driver is required for PersistentVolumes backed by EBS
  # on EKS 1.23+. The old in-tree EBS plugin was deprecated.
  # The driver needs IAM permissions to create/attach/detach EBS volumes.
  # Best practice: use IRSA (service_account_role_arn) not the node role.

  tags = {
    Name = "${var.cluster_name}-ebs-csi-addon"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi_driver_policy
  ]
}

###############################################################################
# IRSA - IAM Role for EBS CSI Driver Service Account
# This demonstrates the IRSA pattern:
#   1. EKS cluster exposes an OIDC provider endpoint
#   2. IAM role trust policy allows the OIDC provider to assume the role
#      for a specific Kubernetes ServiceAccount
#   3. The add-on/pod's ServiceAccount gets annotated with the role ARN
#   4. AWS SDK in the pod automatically exchanges the K8s token for
#      temporary IAM credentials via STS AssumeRoleWithWebIdentity
###############################################################################

data "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
  # The OIDC issuer URL is output by the EKS cluster resource.
  # You must also create the aws_iam_openid_connect_provider separately
  # (not shown here for brevity, but required in production).
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
      # Only the specific ServiceAccount in the specific namespace can
      # assume this role. This is principle of least privilege for pods.
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.cluster_name}-ebs-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = {
    Name = "${var.cluster_name}-ebs-csi-driver-role"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

###############################################################################
# OUTPUTS
###############################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate data for cluster authentication"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL - used to create IRSA trust policies"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "node_group_arn" {
  description = "ARN of the managed node group"
  value       = aws_eks_node_group.main.arn
}

output "fargate_profile_arn" {
  description = "ARN of the Fargate profile"
  value       = aws_eks_fargate_profile.app.arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN for worker nodes (used in aws-auth ConfigMap)"
  value       = aws_iam_role.eks_node.arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

output "eks_optimized_ami_id" {
  description = "EKS-optimized AMI used by the node group"
  value       = data.aws_ssm_parameter.eks_ami.value
}

###############################################################################
# SAA-C03 EXAM CHEATSHEET - EKS
# ============================================================================
# Q: ECS vs EKS - when to use which?
# A: ECS = simpler, AWS-native, no K8s knowledge needed.
#    EKS = K8s standard, portable, more ecosystem tools (Helm, ArgoCD, etc.)
#    Both support Fargate for serverless compute.
#
# Q: How do EKS pods get AWS permissions?
# A: IRSA - annotate ServiceAccount with IAM role ARN. Pod gets temp creds
#    via OIDC token exchange. Do NOT use node instance role for pods.
#
# Q: What is the EKS control plane?
# A: Managed by AWS. Multi-AZ, highly available. You pay ~$0.10/hr for it.
#    Includes: API server, etcd, controller manager, scheduler.
#
# Q: Cluster Autoscaler vs Karpenter?
# A: Cluster Autoscaler = scales existing node groups via ASG.
#    Karpenter = directly provisions right-sized nodes faster, more flexible.
#
# Q: What are managed add-ons?
# A: AWS-managed components: vpc-cni, coredns, kube-proxy, ebs-csi-driver.
#    AWS handles version compatibility and updates.
#
# Q: EKS Fargate limitations?
# A: No DaemonSets, no privileged containers, no GPU, no EBS volumes,
#    max 4 vCPU / 30 GB per pod. Use EFS for persistent storage on Fargate.
###############################################################################
