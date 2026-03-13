# =============================================================================
# LAB 28: AWS COST MANAGEMENT & BILLING
# =============================================================================
#
# SAA-C03 COST OPTIMIZATION DOMAIN OVERVIEW
# ------------------------------------------
# The exam tests your ability to recommend the RIGHT pricing model and cost
# management tool for a given scenario. Key services covered here:
#
#   Cost Explorer       → visualize historical and forecasted costs
#   AWS Budgets         → proactive alerts when costs/usage exceed thresholds
#   Cost Allocation Tags → attribute costs to teams/projects/environments
#   Savings Plans       → flexible commitment-based discounts
#   Reserved Instances  → instance-specific commitment-based discounts
#   Spot Instances      → spare capacity at up to 90% discount (interruptible)
#   Trusted Advisor     → automated best-practice recommendations
#   Compute Optimizer   → right-sizing recommendations using ML
#   Cost Anomaly Detection → ML-based alerts on unexpected cost spikes
#
# =============================================================================
# PRICING MODEL DECISION GUIDE (SAA-C03 MUST KNOW)
# =============================================================================
#
#   On-Demand:
#     - No commitment, pay per second/hour.
#     - Use for: unpredictable workloads, short-term needs, development.
#
#   Reserved Instances (RIs):
#     - Commit to a specific instance type + region + OS for 1 or 3 years.
#     - Up to 72% discount vs On-Demand.
#     - Types:
#         Standard RI   → highest discount, cannot change instance family
#         Convertible RI → can change instance family, lower discount (~54%)
#     - Scope: Regional (flexible, can apply to any AZ) or Zonal (specific AZ,
#       capacity reservation).
#     - Payment: All Upfront > Partial Upfront > No Upfront (discount descends)
#     - Use for: steady-state, predictable workloads.
#     - SAA-C03: "Needs to run 24/7 for 1+ years" → Reserved Instance.
#
#   Savings Plans:
#     - Commit to a specific spend ($/hour) rather than a specific instance.
#     - More FLEXIBLE than Reserved Instances.
#     - Types:
#         Compute Savings Plan  → any EC2 instance family/region/OS/tenancy,
#                                 plus Fargate and Lambda. Up to 66% discount.
#         EC2 Instance Savings  → specific instance family + region, any AZ/OS.
#                                 Up to 72% discount.
#         SageMaker Savings     → SageMaker ML instances.
#     - SAA-C03: "Needs flexibility to change instance types" → Savings Plan
#       (especially Compute Savings Plan).
#
#   Spot Instances:
#     - AWS spare capacity, up to 90% discount vs On-Demand.
#     - AWS can INTERRUPT with a 2-minute warning (Spot interruption notice).
#     - Use for: fault-tolerant, stateless, flexible workloads.
#     - Examples: batch processing, CI/CD jobs, data analysis, HPC, rendering.
#     - NOT suitable for: databases, stateful apps, anything that can't be
#       interrupted mid-task.
#     - Spot Fleet / EC2 Fleet: mix of Spot + On-Demand for resilience.
#     - SAA-C03: "Lowest cost, can tolerate interruptions" → Spot Instances.
#
#   Dedicated Hosts:
#     - Physical server dedicated to your use, most control over licensing.
#     - Use for: BYOL (Bring Your Own License) for Windows Server, Oracle, etc.
#     - Most expensive option.
#
#   Dedicated Instances:
#     - EC2 instances on hardware dedicated to a single customer.
#     - Less control than Dedicated Hosts, but simpler.
#     - Use for: compliance/regulatory requirements (hardware isolation).
#
# =============================================================================
# OTHER COST TOOLS
# =============================================================================
#
#   Trusted Advisor:
#     - Inspects your AWS environment against best practices in 6 categories:
#         1. Cost Optimization   (e.g., idle EC2, unused RIs)
#         2. Security            (e.g., open S3 buckets, MFA on root)
#         3. Fault Tolerance     (e.g., EBS snapshots, RDS multi-AZ)
#         4. Performance         (e.g., high utilization EC2)
#         5. Service Limits      (e.g., approaching VPC limit)
#         6. Operational Excellence
#     - Full checks require Business or Enterprise Support plan.
#     - SAA-C03: "Identify underutilized EC2 / cost savings" → Trusted Advisor.
#
#   Compute Optimizer:
#     - Uses ML to analyze CloudWatch metrics and recommend right-sizing.
#     - Covers: EC2 instances, EC2 Auto Scaling Groups, EBS volumes,
#               Lambda functions, ECS services on Fargate.
#     - Provides "over-provisioned", "under-provisioned", "optimized" labels.
#     - SAA-C03: "Right-size EC2 instances based on actual usage" →
#       Compute Optimizer (not Trusted Advisor for detailed ML analysis).
#
# =============================================================================

locals {
  # Notification email for budget alerts.
  # In a real org, use a distribution list or SNS topic.
  alert_email = "aws-billing-alerts@example.com"
}

# =============================================================================
# AWS BUDGETS
# =============================================================================
# AWS Budgets lets you set thresholds and receive alerts BEFORE you overspend.
#
# Budget types:
#   COST     → dollar amount (e.g., alert if monthly spend > $100)
#   USAGE    → usage units (e.g., alert if EC2 hours > 500)
#   RI_COVERAGE    → alert if RI coverage drops below X%
#   RI_UTILIZATION → alert if reserved capacity is underused
#   SAVINGS_PLANS_COVERAGE    → alert if Savings Plan coverage drops
#   SAVINGS_PLANS_UTILIZATION → alert if Savings Plan is underused
#
# Alert types:
#   ACTUAL    → triggers when real spend/usage crosses the threshold
#   FORECASTED → triggers when projected end-of-period spend will exceed
#
# SAA-C03 scenario: "Alert the team when monthly AWS spend exceeds $100 or
# is projected to exceed $100 by month end."
# Answer: AWS Budgets with ACTUAL threshold at 80% and FORECASTED at 100%.
# =============================================================================

# Budget 1: Monthly cost budget — $100/month
# Sends alert at 80% actual AND at 100% forecasted spend.
resource "aws_budgets_budget" "monthly_cost" {
  name         = "monthly-cost-budget"
  budget_type  = "COST" # track dollar spend
  limit_amount = "100"  # $100 USD
  limit_unit   = "USD"

  # time_unit options: DAILY, MONTHLY, QUARTERLY, ANNUALLY
  time_unit = "MONTHLY"

  # time_period_start is required; AWS will track from this date onward.
  # Format: YYYY-MM-DD_HH:MM (must be first of the month for MONTHLY budgets)
  time_period_start = "2024-01-01_00:00"
  # time_period_end is optional; omit for ongoing budget.

  # Alert 1: Notify when ACTUAL spend reaches 80% of $100 = $80
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80 # percentage of budget limit
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL" # based on real charges
    subscriber_email_addresses = [local.alert_email]
    # subscriber_sns_topic_arns = ["arn:aws:sns:..."] # also supports SNS
  }

  # Alert 2: Notify when FORECASTED spend is projected to hit 100% ($100)
  # This gives advance warning before the bill arrives.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED" # based on projected spend
    subscriber_email_addresses = [local.alert_email]
  }

  # Optional: filter to only track specific services, tags, accounts, etc.
  # cost_filter {
  #   name   = "Service"
  #   values = ["Amazon EC2"]
  # }
}

# Budget 2: Monthly EC2 usage budget — track instance-hours
# Useful for teams with a fixed compute allocation (e.g., 200 EC2 hours/month).
# This catches runaway instances even if the dollar cost is still low.
resource "aws_budgets_budget" "monthly_ec2_usage" {
  name        = "monthly-ec2-usage-budget"
  budget_type = "USAGE" # track usage units, not dollars

  # Usage unit format depends on the service:
  #   EC2: "$0.0416667/vCPU-Hours" or just use "Hrs" for instance hours
  limit_amount = "200" # 200 vCPU-hours per month
  limit_unit   = "vCPU Hours"

  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  # Filter to EC2 usage only
  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [local.alert_email]
  }
}

# Budget 3: Savings Plans coverage budget
# Alerts when Savings Plans coverage drops below 80% of eligible spend.
# Low coverage means you're not using your commitments efficiently — you may
# be paying On-Demand for workloads that your Savings Plan should cover.
#
# SAA-C03: Savings Plans coverage = what % of your eligible spend is covered
# by a Savings Plan. Target: >80% is generally healthy.
resource "aws_budgets_budget" "savings_plans_coverage" {
  name        = "savings-plans-coverage-budget"
  budget_type = "SAVINGS_PLANS_COVERAGE"

  # For coverage budgets, limit is the MINIMUM coverage % you want.
  # Alert fires when coverage DROPS BELOW this threshold.
  limit_amount = "80" # want at least 80% of eligible spend covered
  limit_unit   = "PERCENTAGE"

  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    # NOTE: For coverage budgets, use "LESS_THAN" — alert when coverage is low
    comparison_operator        = "LESS_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [local.alert_email]
  }
}

# =============================================================================
# COST ALLOCATION TAGS
# =============================================================================
# Cost Allocation Tags let you break down your AWS bill by tag value.
#
# How it works:
#   1. You tag resources (e.g., Environment=Production, Team=Backend).
#   2. You ACTIVATE those tag keys in the Billing Console (or via Terraform).
#   3. Tags appear in Cost Explorer and Cost & Usage Reports.
#   4. You can filter/group costs by tag.
#
# Two tag types:
#   AWS-generated tags: e.g., aws:createdBy (auto-applied by some services)
#   User-defined tags:  your own key/value pairs
#
# SAA-C03: "How do you attribute AWS costs to different departments?"
# Answer: Apply resource tags + enable Cost Allocation Tags in Billing.
#
# NOTE: There is a 24-hour delay before newly activated tags appear in reports.
# Tags only track costs from the activation date forward — not retroactively.
# =============================================================================

resource "aws_ce_cost_allocation_tag" "environment" {
  tag_key = "Environment"
  status  = "Active"
  # Activating this tag means Cost Explorer will track costs split by
  # Environment tag value (e.g., Production vs Development vs Staging).
}

resource "aws_ce_cost_allocation_tag" "team" {
  tag_key = "Team"
  status  = "Active"
  # Track costs by team for internal chargeback/showback.
}

resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
  # Track costs per project — useful for billing clients or tracking ROI.
}

# =============================================================================
# COST ANOMALY DETECTION
# =============================================================================
# Cost Anomaly Detection uses ML to establish a cost baseline and alerts you
# when spending deviates significantly from the expected pattern.
#
# Unlike Budgets (threshold-based), anomaly detection is PATTERN-based:
#   - It learns your spending patterns over time.
#   - It alerts on UNEXPECTED spikes, even if you're under budget.
#   - Example: Your Lambda costs are normally $5/day. If they spike to
#     $200/day, Anomaly Detection fires — even if you're under your $1000
#     monthly budget.
#
# Monitor types:
#   DIMENSIONAL → monitor a single AWS service (e.g., just EC2 costs)
#   CUSTOM      → monitor by linked account, cost category, or tag
#
# SAA-C03: "Alert on unexpected cost increases without setting a fixed
# dollar threshold." → Cost Anomaly Detection.
# =============================================================================

# Anomaly Monitor: watch all services (dimensional monitor type)
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name              = "all-services-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  # This monitors each AWS service independently.
  # If EC2 spikes, you get an EC2 alert. If RDS spikes, a separate RDS alert.
  # This is more useful than one aggregate monitor because it identifies
  # which service caused the anomaly.
}

# Anomaly Subscription: define who gets alerted and when
resource "aws_ce_anomaly_subscription" "alert_on_anomaly" {
  name      = "anomaly-alert-above-20-dollars"
  frequency = "DAILY"
  # frequency options:
  #   DAILY   → send a digest of all anomalies once per day
  #   WEEKLY  → weekly digest
  #   IMMEDIATE → alert as soon as anomaly is detected (for SNS subscribers)

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service_monitor.arn,
  ]

  subscriber {
    type    = "EMAIL"
    address = local.alert_email
    # For immediate alerts, use SNS:
    # type    = "SNS"
    # address = aws_sns_topic.billing_alerts.arn
  }

  # Alert when the total impact of an anomaly exceeds $20
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["20"] # dollar amount
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
  # threshold_expression replaces the older `threshold` field.
  # You can also use ANOMALY_TOTAL_IMPACT_PERCENTAGE for relative thresholds.
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "monthly_cost_budget_name" {
  description = "Name of the monthly cost budget"
  value       = aws_budgets_budget.monthly_cost.name
}

output "monthly_ec2_usage_budget_name" {
  description = "Name of the monthly EC2 usage budget"
  value       = aws_budgets_budget.monthly_ec2_usage.name
}

output "savings_plans_coverage_budget_name" {
  description = "Name of the Savings Plans coverage budget"
  value       = aws_budgets_budget.savings_plans_coverage.name
}

output "anomaly_monitor_arn" {
  description = "ARN of the Cost Anomaly Monitor"
  value       = aws_ce_anomaly_monitor.service_monitor.arn
}

output "anomaly_subscription_arn" {
  description = "ARN of the Cost Anomaly Subscription"
  value       = aws_ce_anomaly_subscription.alert_on_anomaly.arn
}

output "cost_allocation_tags" {
  description = "List of activated cost allocation tag keys"
  value = [
    aws_ce_cost_allocation_tag.environment.tag_key,
    aws_ce_cost_allocation_tag.team.tag_key,
    aws_ce_cost_allocation_tag.project.tag_key,
  ]
}

# =============================================================================
# EXAM QUICK REFERENCE — COST MANAGEMENT SCENARIOS
# =============================================================================
#
# Q: Reduce cost for steady-state EC2 workload running 24/7 for 3 years?
# A: Reserved Instances (All Upfront, 3-year) — maximum discount (~72%)
#
# Q: Reduce cost but need flexibility to change instance type/region?
# A: Compute Savings Plan — up to 66% discount, fully flexible
#
# Q: Batch job that can be interrupted, needs cheapest option?
# A: Spot Instances — up to 90% discount, 2-min interruption notice
#
# Q: Windows Server with existing BYOL licenses?
# A: Dedicated Hosts — physical server control for license compliance
#
# Q: Identify and alert on unexpected cost spike (no fixed threshold)?
# A: Cost Anomaly Detection
#
# Q: Alert when monthly spend exceeds $X?
# A: AWS Budgets (COST type)
#
# Q: Visualize cost trends and forecast next month's bill?
# A: Cost Explorer
#
# Q: Right-size an oversized EC2 instance based on CPU/memory metrics?
# A: Compute Optimizer
#
# Q: Identify idle EC2 and unused Elastic IPs in one dashboard?
# A: Trusted Advisor (Cost Optimization category)
#
# Q: Break down monthly bill by department/project?
# A: Cost Allocation Tags + Cost Explorer
#
# Q: Single bill for multiple accounts + share RIs across accounts?
# A: AWS Organizations with Consolidated Billing
# =============================================================================
