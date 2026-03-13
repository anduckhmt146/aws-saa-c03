# Lab 50 — Kubernetes Control Plane for Microservices + Helm

Hands-on lab deploying a production-style microservices platform on EKS using Helm.

## Prerequisites

- Lab 37 (`37-eks`) running — this lab references the EKS cluster it creates
- `kubectl` configured: `aws eks update-kubeconfig --region us-east-1 --name saa-c03-eks-lab`
- `helm` v3 installed: `brew install helm`

## What This Lab Covers

| Topic | Resource |
|-------|----------|
| K8s control plane components | Comments in `main.tf` |
| Helm chart structure | `helm/microservices-app/` |
| Helm templating (Go templates, Sprig) | `templates/_helpers.tpl` |
| Deployment strategy (RollingUpdate) | `templates/deployment.yaml` |
| Service types (ClusterIP, LoadBalancer) | `templates/service.yaml` |
| Ingress + TLS with cert-manager | `templates/ingress.yaml` |
| Horizontal Pod Autoscaler (HPA) | `templates/hpa.yaml` |
| Pod Disruption Budget (PDB) | `templates/pdb.yaml` |
| ConfigMaps + Secrets pattern | `templates/configmap.yaml` |
| IRSA (IAM Roles for Service Accounts) | `main.tf` |
| NetworkPolicy (zero-trust) | `main.tf` |
| RBAC (Role, RoleBinding) | `main.tf` |
| ResourceQuota + LimitRange | `main.tf` |
| Prometheus + Grafana (kube-prometheus-stack) | `main.tf` |
| ingress-nginx + NLB | `main.tf` |
| SQS async communication pattern | `main.tf` |

## Architecture

```
Internet → Route53 → NLB → ingress-nginx → user-service  → RDS / ElastiCache
                                         → order-service → DynamoDB / SQS
```

## Deploy

```bash
# 1. Deploy infrastructure + Helm releases
terraform init
terraform apply -var="cluster_name=saa-c03-eks-lab" -var="domain_name=yourdomain.com"

# 2. Verify
kubectl get pods -n production
kubectl get hpa -n production
kubectl get ingress -n production

# 3. Dry-run the chart (no cluster needed)
helm template microservices ./helm/microservices-app -n production

# 4. Lint the chart
helm lint ./helm/microservices-app
```

## Key Concepts for SAA-C03

- **Control plane**: AWS manages API server, etcd, scheduler, controller-manager on EKS
- **IRSA**: Pods get AWS credentials via OIDC token exchange — no secrets in cluster
- **HPA → Cluster Autoscaler**: HPA adds pods, CA adds nodes when pods are Pending
- **Ingress vs LoadBalancer Service**: One NLB for many services vs one NLB per service
- **NetworkPolicy**: Default-deny + explicit allows = zero-trust pod networking
