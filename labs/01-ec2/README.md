# Lab 01 - EC2 & Auto Scaling

> Exam weight: **20-25%** of SAA-C03 questions

## What This Lab Creates

- EC2 instance (On-Demand, t3.micro, free tier)
- Security Group (SSH + HTTP)
- Launch Template with Spot instance config
- Auto Scaling Group with Target Tracking + Scheduled Scaling
- Placement Groups (Cluster, Spread, Partition)

## Run

```bash
terraform init
terraform apply
terraform destroy  # Always destroy when done!
```

---

## Key Concepts

### Instance Type Families

| Family | Name | Use Case |
|--------|------|----------|
| T3/T4g | Burstable | Dev/test, web servers |
| M5/M6  | General Purpose | Most balanced workloads |
| C5/C6  | Compute Optimized | CPU-intensive apps |
| R5/R6  | Memory Optimized | In-memory databases |
| X1/X2  | Memory Extreme | SAP HANA, big data |
| P3/P4  | GPU | ML training, HPC |
| G4/G5  | Graphics | Rendering, ML inference |
| I3/I4  | Storage Optimized | High IOPS, NoSQL |
| D2/D3  | Dense Storage | MapReduce, HDFS |

Quick selection:
```
High CPU       → C5/C6
High RAM       → R5/R6
ML training    → P3/P4
High IOPS      → I3/I4
Variable load  → T3/T4g
```

### Pricing Models

| Model | Discount | Commitment | Use Case |
|-------|----------|------------|----------|
| On-Demand | 0% | None | Short-term, unpredictable |
| Reserved | 40-60% | 1-3 years | Steady-state, predictable |
| Spot | 50-90% | None | Fault-tolerant, batch |
| Savings Plans | 40-66% | 1-3 years | Flexible commitment |
| Dedicated Host | 0% | None | Licensing/compliance |

**Exam Tips**:
- "Predictable workload" + "1-3 years" → Reserved Instances
- "Cost-effective" + "fault-tolerant" → Spot Instances
- Standard RI: highest discount, cannot change instance type
- Convertible RI: lower discount, can change instance type
- All Upfront > Partial Upfront > No Upfront (discount order)

### EC2 Storage

| Type | Persistence | IOPS | Use Case |
|------|-------------|------|----------|
| gp3/gp2 (EBS) | Persistent | Moderate | General purpose |
| io2/io1 (EBS) | Persistent | Very high | Databases |
| st1 (EBS HDD) | Persistent | Throughput | Big data |
| sc1 (EBS HDD) | Persistent | Low | Infrequent access |
| Instance Store | Ephemeral | Very high | Cache, temp data |

**Exam Tip**: "Temporary data" + "high IOPS" → Instance Store

### Placement Groups

```
Cluster   → Low latency, 10Gbps, SAME AZ (HPC, big data)
Spread    → HA, different hardware, MAX 7 instances/AZ
Partition → Big data racks, MAX 7 partitions/AZ (Hadoop/Kafka)
```

### Auto Scaling Policies

| Policy | How | Use Case |
|--------|-----|----------|
| Target Tracking | Maintain metric at target | Easiest — CPU at 50% |
| Step Scaling | Different steps per alarm threshold | Granular control |
| Simple Scaling | Single action + cooldown | Basic |
| Scheduled | At specific times | Predictable load patterns |
| Predictive | ML forecast | Proactive, traffic patterns |

- Default cooldown: **300 seconds**
- Health checks: EC2 (instance) or **ELB** (application — recommended)

### Launch Template vs Launch Configuration

| Feature | Launch Template | Launch Configuration |
|---------|----------------|----------------------|
| Versioning | Yes | No |
| Spot + On-Demand mix | Yes | No |
| Multiple instance types | Yes | No |
| Status | Recommended | Legacy |

### Networking

- **ENI** (Elastic Network Interface): Virtual NIC, attach/detach
- **ENA** (Elastic Network Adapter): Up to 100 Gbps
- **EFA** (Elastic Fabric Adapter): HPC/MPI, OS-bypass, lowest latency

### Common Exam Mistakes

- Choosing On-Demand for steady-state → use Reserved
- Using Lambda for long-running tasks (>15 min) → use ECS/Batch
- Forgetting Spot for fault-tolerant workloads (50-90% savings)
- Using EKS when ECS is sufficient (EKS = more complex + expensive)
