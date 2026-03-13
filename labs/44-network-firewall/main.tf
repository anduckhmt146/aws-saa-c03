# =============================================================================
# LAB 44: AWS NETWORK FIREWALL
# SAA-C03 Study Lab — Stateful/Stateless VPC-Level Traffic Inspection
# =============================================================================
#
# WHAT IS AWS NETWORK FIREWALL?
# ─────────────────────────────────────────────────────────────────────────────
# AWS Network Firewall is a MANAGED, STATEFUL network firewall and IDS/IPS
# service operating at the VPC level (Layer 3/4 and limited Layer 7).
# It inspects traffic flowing in, out of, and between VPCs using a combination
# of stateless packet filters and stateful deep-packet inspection engines.
#
# SAA-C03: Network Firewall vs WAF vs Security Groups vs NACLs
# ─────────────────────────────────────────────────────────────────────────────
# ┌──────────────────┬───────────┬────────────────────────────────────────────┐
# │ Service          │ OSI Layer │ Scope / Use Case                           │
# ├──────────────────┼───────────┼────────────────────────────────────────────┤
# │ Security Groups  │ L3/L4     │ Stateful. Attached to ENIs. Allow-only.    │
# │                  │           │ No explicit deny. Instance-level control.   │
# ├──────────────────┼───────────┼────────────────────────────────────────────┤
# │ Network ACLs     │ L3/L4     │ Stateless. Attached to subnets. Allow+deny.│
# │                  │           │ Must configure both inbound AND outbound.   │
# ├──────────────────┼───────────┼────────────────────────────────────────────┤
# │ Network Firewall │ L3–L7     │ Stateful + stateless. VPC-level.            │
# │                  │           │ Suricata IDS/IPS. Domain filtering.         │
# │                  │           │ Deep packet inspection. All protocols.      │
# ├──────────────────┼───────────┼────────────────────────────────────────────┤
# │ AWS WAF          │ L7 only   │ HTTP/HTTPS only. Edge protection.           │
# │                  │           │ CloudFront, ALB, API Gateway, AppSync.      │
# │                  │           │ SQL injection, XSS, rate-based rules.       │
# └──────────────────┴───────────┴────────────────────────────────────────────┘
#
# CENTRALIZED INSPECTION VPC PATTERN (hub-and-spoke with TGW)
# ─────────────────────────────────────────────────────────────────────────────
# The enterprise pattern uses Transit Gateway (TGW) as the routing hub:
#
#   [Spoke VPC 1] ──┐
#   [Spoke VPC 2] ──┼── Transit Gateway ── [Inspection VPC] ── Internet Gateway
#   [Spoke VPC 3] ──┘         │
#                             └── [On-prem via VPN/DirectConnect]
#
# All traffic from ANY spoke VPC headed to the internet is routed through the
# Inspection VPC where Network Firewall inspects it before it exits. This
# avoids deploying a separate firewall in each spoke VPC — one inspection
# point enforces policy for the entire organization.
#
# SAA-C03: "Single point of inspection for all VPCs in an account/org"
# → Network Firewall in a centralized Inspection VPC connected via TGW.
#
# This lab uses a single VPC (simpler for study) but all firewall concepts
# apply identically in the multi-VPC TGW hub-and-spoke pattern.
#
# LOGGING DESTINATIONS — Three options (exam must-know):
# ─────────────────────────────────────────────────────────────────────────────
# 1. Amazon CloudWatch Logs:
#    Best for real-time monitoring, dashboards, metric filters, alarms.
#    Example: alert on spike in DROP actions → potential attack underway.
#    Higher cost at scale; logs available within seconds.
#
# 2. Amazon S3:
#    Best for long-term retention, compliance archival, cost optimization.
#    Query with Athena for security investigations.
#    Lower cost for large volumes; logs available within minutes.
#
# 3. Amazon Kinesis Data Firehose:
#    Best for streaming to third-party SIEMs (Splunk, Datadog, OpenSearch).
#    Can transform logs with Lambda before delivery.
#    SAA-C03 trigger: "Send firewall logs to Splunk" → Kinesis Data Firehose.
# =============================================================================

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# VPC — INSPECTION VPC FOR NETWORK FIREWALL
# =============================================================================
#
# SAA-C03: In a production centralized inspection pattern, this is the
# dedicated "Inspection VPC." All spoke VPC traffic is routed through this
# VPC via Transit Gateway before reaching the internet. In this lab we use
# a single-VPC inline model for simplicity — concepts are identical.

resource "aws_vpc" "inspection" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-inspection-vpc"
    Purpose = "network-firewall-lab"
    Lab     = "44-network-firewall"
  }
}

# =============================================================================
# SUBNETS — FIREWALL SUBNETS (one per AZ, count=2)
# =============================================================================
#
# SAA-C03: FIREWALL SUBNET RULES
# ─────────────────────────────────────────────────────────────────────────────
# Firewall subnets are DEDICATED subnets that host the Network Firewall
# endpoint ENIs. Important rules:
#   1. One dedicated firewall subnet per AZ — mandatory for HA
#   2. Each AZ creates ONE firewall endpoint ENI in its subnet
#   3. Protected subnets must route to the endpoint in the SAME AZ
#   4. Minimum /28 subnet size (/24 recommended)
#   5. Do NOT place other resources (EC2, NAT GW) in firewall subnets
#
# AZ SYMMETRY EXAM TRAP:
#   If AZ1 protected traffic routes to AZ2 firewall endpoint:
#   - Cross-AZ data transfer charges accrue
#   - If AZ2 endpoint is unhealthy, AZ1 traffic also fails
#   - Asymmetric routing can cause connection state issues
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "firewall" {
  count = 2

  vpc_id            = aws_vpc.inspection.id
  cidr_block        = count.index == 0 ? var.firewall_subnet_cidr_az1 : var.firewall_subnet_cidr_az2
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Firewall subnets do not need public IPs — endpoints are private ENIs
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-firewall-subnet-az${count.index + 1}"
    Type = "firewall-endpoint"
    Lab  = "44-network-firewall"
  }
}

# =============================================================================
# SUBNETS — PROTECTED WORKLOAD SUBNETS (one per AZ, count=2)
# =============================================================================
#
# SAA-C03: Protected subnets host the workloads whose traffic is inspected.
# Their route tables send 0.0.0.0/0 to the firewall endpoint (not directly
# to the IGW). The firewall endpoint's route table sends inspected traffic
# onward to the IGW. EC2 instances, ECS tasks, Lambda VPC attachments, and
# RDS instances all belong in protected subnets.

resource "aws_subnet" "protected" {
  count = 2

  vpc_id            = aws_vpc.inspection.id
  cidr_block        = count.index == 0 ? var.protected_subnet_cidr_az1 : var.protected_subnet_cidr_az2
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-protected-subnet-az${count.index + 1}"
    Type = "protected-workload"
    Lab  = "44-network-firewall"
  }
}

# =============================================================================
# INTERNET GATEWAY
# =============================================================================
#
# SAA-C03: In the inspection VPC pattern the IGW gets an "edge association"
# route table (aws_route_table_association with gateway_id, not subnet_id).
# This forces inbound traffic to pass through the firewall endpoint BEFORE
# reaching the protected subnets — ensuring symmetric inspection.
# Without ingress routing: outbound is inspected but inbound bypasses the
# firewall entirely, creating a security blind spot.

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.inspection.id

  tags = {
    Name = "${var.project_name}-igw"
    Lab  = "44-network-firewall"
  }
}

# =============================================================================
# STATELESS RULE GROUP — TCP 80/443 FORWARD, ALL ELSE DROP
# =============================================================================
#
# SAA-C03: STATELESS vs STATEFUL RULE GROUPS
# ─────────────────────────────────────────────────────────────────────────────
# STATELESS rules:
#   - Evaluated FIRST, before stateful rules (no exceptions)
#   - No session/connection state — each packet evaluated independently
#   - Like NACLs but more powerful: match protocol, port ranges, CIDR blocks
#   - Actions: aws:pass, aws:drop, aws:forward_to_sfe (send to stateful engine),
#              aws:alert_pass, aws:alert_drop
#   - Priority: LOWER number = evaluated FIRST (opposite of WAF priority)
#   - Fragment handling: stateless_fragment_default_actions in the policy controls
#     TCP/IP fragments — usually drop them (they evade stateless inspection)
#
# STATEFUL rules:
#   - Evaluated AFTER stateless rules forward traffic with aws:forward_to_sfe
#   - Tracks connection state (like Security Groups — return traffic allowed)
#   - Three rule types: domain list, Suricata-compatible IPS, 5-tuple stateful
#   - Can inspect application layer: HTTP Host header, TLS SNI, DNS queries
#
# RULE ORDER in a policy (STRICT_ORDER mode):
#   1. Stateless rule groups (evaluated by priority — lower first)
#   2. Stateless default action (for traffic not matched by any stateless rule)
#   3. Stateful rule groups (evaluated in order declared in policy)
#   4. Stateful default action (for traffic not matched by any stateful rule)
#
# STRICT_ORDER vs DEFAULT_ACTION_ORDER:
#   STRICT_ORDER:          First matching rule wins. Predictable, auditable.
#                          Mirrors traditional firewall behavior.
#   DEFAULT_ACTION_ORDER:  Action priority: pass > drop > alert. All rules
#                          evaluated; highest-priority action type wins.
# ─────────────────────────────────────────────────────────────────────────────
#
# This stateless rule group:
#   Priority 1:   Forward TCP 80 and 443 to the stateful engine for domain filtering
#   Priority 100: Drop everything else (explicit default deny at stateless layer)
#
# SAA-C03 tip: Using aws:forward_to_sfe instead of aws:pass on HTTP/HTTPS
# ensures the stateful domain allowlist still evaluates this traffic.
# If you used aws:pass here, stateful domain rules would be bypassed entirely.

resource "aws_networkfirewall_rule_group" "stateless_allow" {
  name     = "lab-stateless-allow"
  type     = "STATELESS"
  capacity = 100
  # capacity: max rules this group can hold. CANNOT be changed after creation.
  # SAA-C03: Plan capacity ahead of time — resizing requires replacing the group.

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {

        # Priority 1: Forward web traffic (TCP 80 and 443) to the stateful engine
        # aws:forward_to_sfe ensures domain allowlist and Suricata rules still apply
        stateless_rule {
          priority = 1
          rule_definition {
            actions = ["aws:forward_to_sfe"]
            match_attributes {
              protocols = [6] # Protocol number 6 = TCP (not a port number)
              destination_port {
                from_port = 80
                to_port   = 80
              }
              destination_port {
                from_port = 443
                to_port   = 443
              }
            }
          }
        }

        # Priority 100: Drop all traffic not matched above
        # SAA-C03: Explicit deny-all at the stateless layer is defense in depth.
        # The stateless_default_actions in the firewall policy also controls
        # unmatched packets — this rule makes the intent explicit in the group.
        stateless_rule {
          priority = 100
          rule_definition {
            actions = ["aws:drop"]
            match_attributes {}
          }
        }

      }
    }
  }

  tags = {
    Name     = "lab-stateless-allow"
    RuleType = "STATELESS"
    Lab      = "44-network-firewall"
  }
}

# =============================================================================
# STATEFUL RULE GROUP — DOMAIN ALLOWLIST
# =============================================================================
#
# SAA-C03: DOMAIN LIST RULE GROUP
# ─────────────────────────────────────────────────────────────────────────────
# Domain list rules inspect HTTP Host headers and TLS SNI to allow or block
# traffic based on the destination domain name. This is Layer 7 filtering
# without needing to decrypt TLS (no SSL inspection configuration required).
#
# generated_rules_type options:
#   ALLOWLIST: only listed domains are permitted — everything else is blocked
#   DENYLIST:  listed domains are blocked — everything else is permitted
#
# target_types:
#   HTTP_HOST: inspects the HTTP Host header (plaintext HTTP traffic, port 80)
#   TLS_SNI:   inspects TLS SNI field in the ClientHello (HTTPS, no decryption)
#
# targets syntax:
#   ".amazonaws.com"  — dot prefix matches the domain AND all subdomains
#                        e.g., matches s3.amazonaws.com, ec2.amazonaws.com
#   "example.com"     — exact domain match only (no subdomains)
#
# SAA-C03 ALLOWLIST vs DENYLIST decision:
#   ALLOWLIST: high-security environments with controlled outbound destinations.
#              Strictest posture — requires listing every permitted domain.
#              Best for: financial services, healthcare, PCI DSS environments.
#   DENYLIST:  block known malicious domains, permit general internet access.
#              Easier to maintain; requires up-to-date threat intelligence.
#              Integrate with commercial threat intel feeds from AWS Marketplace.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_networkfirewall_rule_group" "stateful_domain_list" {
  name     = "lab-domain-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["HTTP_HOST", "TLS_SNI"]
        targets = [
          ".amazonaws.com", # AWS SDK calls, S3, EC2 metadata, etc.
          ".amazon.com",    # Amazon services and package repos
          ".github.com",    # GitHub (common in dev/build environments)
        ]
      }
    }
  }

  tags = {
    Name     = "lab-domain-allowlist"
    RuleType = "STATEFUL-DOMAIN-LIST"
    Lab      = "44-network-firewall"
  }
}

# =============================================================================
# STATEFUL RULE GROUP — SURICATA IDS/IPS RULES
# =============================================================================
#
# SAA-C03: SURICATA RULE SYNTAX
# ─────────────────────────────────────────────────────────────────────────────
# AWS Network Firewall uses Suricata-compatible rule syntax for advanced
# stateful inspection. Suricata is an open-source IDS/IPS engine.
#
# Suricata rule format:
#   <action> <protocol> <src-ip> <src-port> -> <dst-ip> <dst-port> (<options>)
#
# Actions in Network Firewall:
#   alert:  generate an alert log entry — traffic is NOT blocked (IDS mode)
#   drop:   block the packet AND generate an alert log entry (IPS mode)
#   pass:   allow the packet, stop further rule evaluation
#   reject: block AND send TCP RST or ICMP unreachable to source
#
# Key rule options:
#   msg:      human-readable description (appears in ALERT logs)
#   content:  match a literal string in the packet payload
#   nocase:   make content match case-insensitive
#   sid:      unique rule ID (required; use 1000000+ range for custom rules)
#   rev:      rule revision number (increment when updating a rule)
#   dns.query: match against DNS query name (requires dns protocol keyword)
#
# SAA-C03 EXAM TIPS:
#   - alert rules log but do NOT block — use drop to actively block
#   - sid values must be unique across ALL rule groups in a single policy
#   - Network Firewall supports a SUBSET of Suricata keywords
#   - For simple domain filtering, use domain list rules (no syntax needed)
#   - Suricata rules enable: payload content, DNS names, protocol anomaly detection
#
# SURICATA vs DOMAIN LIST rule groups:
#   Domain list:   simpler, no syntax to learn, HTTP/HTTPS domain matching only
#   Suricata:      full IPS capability, DNS inspection, payload content, regex,
#                  protocol anomaly detection, custom CVE signatures
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_networkfirewall_rule_group" "stateful_suricata" {
  name     = "lab-suricata-rules"
  type     = "STATEFUL"
  capacity = 200

  rule_group {
    rules_source {
      # rules_string: raw Suricata-compatible rule syntax
      # SAA-C03: Use this block for Suricata IDS/IPS rules.
      # Alternative: use rules_source_list for domain-based filtering.
      rules_string = <<-RULES
        # Block attempted SQL injection patterns in HTTP request payloads
        # alert = IDS mode (log only). Change to 'drop' for IPS blocking.
        alert http any any -> any any (msg:"SQL Injection Attempt"; content:"SELECT"; nocase; sid:1000001; rev:1;)
        # Block DNS queries to cryptocurrency mining pool domains
        # dns.query matches the DNS question section name being resolved
        alert dns any any -> any any (msg:"Crypto Mining DNS"; dns.query; content:"pool."; sid:1000002; rev:1;)
        RULES
    }
  }

  tags = {
    Name     = "lab-suricata-rules"
    RuleType = "STATEFUL-SURICATA"
    Lab      = "44-network-firewall"
  }
}

# =============================================================================
# FIREWALL POLICY
# =============================================================================
#
# SAA-C03: FIREWALL POLICY — THE GLUE BETWEEN RULE GROUPS AND THE FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
# A Firewall Policy:
#   1. References stateless and stateful rule groups (by ARN and priority)
#   2. Defines DEFAULT ACTIONS for traffic not matched by any rule
#   3. Configures the stateful engine order (STRICT_ORDER or DEFAULT_ACTION_ORDER)
#   4. Can be shared across accounts via AWS RAM (Resource Access Manager)
#   5. ONE policy per firewall; multiple firewalls can share one policy
#
# When using AWS Firewall Manager (FMS), a single FMS policy can enforce
# the same Firewall Policy across all VPCs in an AWS Organization.
#
# stateless_default_actions:
#   What to do with traffic that NO stateless rule matched.
#   aws:forward_to_sfe (most common) — unmatched traffic still gets stateful check
#   aws:drop — strict mode, unmatched stateless traffic is dropped immediately
#
# stateless_fragment_default_actions:
#   What to do with IP fragments. Fragments may not have L4 header info
#   (only the first fragment contains source/dest ports). Dropping fragments
#   prevents fragment-based IDS/IPS evasion attacks.
#   SAA-C03: Always drop fragments in security-sensitive environments.
#
# stateful_engine_options:
#   STRICT_ORDER:          First matching rule wins. Mirrors traditional firewall.
#   DEFAULT_ACTION_ORDER:  Action priority: pass > drop > alert (less predictable).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "lab-firewall-policy"

  firewall_policy {
    # Default action for stateless unmatched traffic: forward to stateful engine
    # Using forward_to_sfe ensures domain list and Suricata rules still apply
    stateless_default_actions = ["aws:forward_to_sfe"]

    # Drop IP fragments — prevent fragment-based evasion of stateless rules
    stateless_fragment_default_actions = ["aws:drop"]

    # Reference stateless rule group (priority 1 = evaluated first)
    stateless_rule_group_reference {
      priority     = 1
      resource_arn = aws_networkfirewall_rule_group.stateless_allow.arn
    }

    # Stateful rule groups — evaluated in declaration order under STRICT_ORDER
    # Domain allowlist evaluated BEFORE Suricata rules (simpler rules first)
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.stateful_domain_list.arn
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.stateful_suricata.arn
    }

    # STRICT_ORDER: process stateful rules in the order declared above.
    # SAA-C03: Choose STRICT_ORDER for predictable, auditable firewall behavior.
    # First matching stateful rule wins — order most specific rules first.
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name = "lab-firewall-policy"
    Lab  = "44-network-firewall"
  }
}

# =============================================================================
# NETWORK FIREWALL
# =============================================================================
#
# SAA-C03: THE FIREWALL RESOURCE
# ─────────────────────────────────────────────────────────────────────────────
# The aws_networkfirewall_firewall resource:
#   1. Creates firewall ENDPOINT ENIs (one per subnet_mapping entry / per AZ)
#   2. Associates with a Firewall Policy (contains all the rules)
#   3. Traffic is directed TO these endpoints via route table entries
#
# After creation, the firewall_status attribute contains endpoint_id values
# for each AZ. These endpoint IDs (format: vpce-XXXXXXXXXXXXXXXXX) are used
# as the vpc_endpoint_id in route table entries to direct traffic through
# the firewall for inspection.
#
# Protection settings (set to false for lab teardown; true in production):
#   delete_protection:                 Prevent accidental firewall deletion
#   firewall_policy_change_protection: Prevent policy swaps/detachment
#   subnet_change_protection:          Prevent adding/removing AZ subnet mappings
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_networkfirewall_firewall" "main" {
  name                = "lab-network-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn
  vpc_id              = aws_vpc.inspection.id

  # One subnet_mapping per AZ creates one firewall endpoint ENI per AZ
  subnet_mapping {
    subnet_id = aws_subnet.firewall[0].id
  }

  # SAA-C03: In production add a subnet_mapping for each AZ for true HA:
  # subnet_mapping {
  #   subnet_id = aws_subnet.firewall[1].id
  # }

  # Protection flags — all false for lab flexibility; set true in production
  delete_protection                 = false
  firewall_policy_change_protection = false
  subnet_change_protection          = false

  tags = {
    Name = "lab-network-firewall"
    Lab  = "44-network-firewall"
  }
}

# =============================================================================
# CLOUDWATCH LOG GROUPS FOR FIREWALL LOGGING
# =============================================================================
#
# SAA-C03: NETWORK FIREWALL LOG TYPES
# ─────────────────────────────────────────────────────────────────────────────
# ALERT logs:
#   Generated when a stateless (aws:alert_*) or stateful (alert/drop) rule fires.
#   Contains: rule SID, message, matched packet details (src/dst/protocol).
#   Use for: security incident detection, IDS alerting, rule tuning.
#   Pattern: CloudWatch Logs → metric filter → alarm → SNS → Lambda/PagerDuty
#
# FLOW logs:
#   Connection-level records for ALL traffic traversing the firewall.
#   Contains: 5-tuple (src IP, src port, dst IP, dst port, protocol), bytes,
#             packets, firewall action (ACCEPT/DROP).
#   Similar to VPC Flow Logs but includes firewall rule match context.
#   Use for: traffic analysis, compliance auditing, capacity planning.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "firewall_alert" {
  name              = "/aws/network-firewall/lab/alert"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "network-firewall-alert-logs"
    LogType = "ALERT"
    Lab     = "44-network-firewall"
  }
}

resource "aws_cloudwatch_log_group" "firewall_flow" {
  name              = "/aws/network-firewall/lab/flow"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "network-firewall-flow-logs"
    LogType = "FLOW"
    Lab     = "44-network-firewall"
  }
}

# =============================================================================
# FIREWALL LOGGING CONFIGURATION
# =============================================================================
#
# SAA-C03: LOGGING CONFIGURATION DETAILS
# ─────────────────────────────────────────────────────────────────────────────
# log_destination_type options:
#   CloudWatchLogs:      log_destination = { logGroup = "/aws/..." }
#   S3:                  log_destination = { bucketName = "my-bucket", prefix = "..." }
#   KinesisDataFirehose: log_destination = { deliveryStream = "my-stream" }
#
# You can configure DIFFERENT destinations for ALERT vs FLOW logs.
# Optimal production pattern:
#   ALERT → CloudWatch Logs (real-time alerting) + S3 (long-term retention)
#   FLOW  → S3 (cost-effective; query with Athena for investigations)
#
# SAA-C03 exam scenarios:
#   "Real-time alerting on rule matches" → CloudWatch + metric filter + SNS alarm
#   "Minimize storage cost for log retention" → S3 + lifecycle to Glacier
#   "Stream firewall logs to Splunk" → Kinesis Data Firehose → Splunk HEC
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    # ALERT logs → CloudWatch Logs for real-time security monitoring
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_alert.name
      }
    }

    # FLOW logs → CloudWatch Logs for connection-level visibility
    # SAA-C03: In cost-sensitive production environments, route FLOW logs to S3:
    # log_destination_type = "S3"
    # log_destination      = { bucketName = "my-logs-bucket", prefix = "nfw/flow/" }
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_flow.name
      }
    }
  }
}

# =============================================================================
# SAA-C03 EXAM QUICK REFERENCE — NETWORK FIREWALL
# =============================================================================
#
# TRAFFIC FLOW IN THE INSPECTION VPC PATTERN:
# ─────────────────────────────────────────────────────────────────────────────
# EGRESS (workload → internet):
#   Protected subnet
#     → Protected subnet route table (0.0.0.0/0 → firewall endpoint, same AZ)
#     → Firewall endpoint (stateless rules → stateful rules → allow/drop)
#     → Firewall subnet route table (0.0.0.0/0 → IGW)
#     → Internet Gateway → Internet
#
# INGRESS (internet → workload):
#   Internet → Internet Gateway
#     → IGW edge-association route table (workload CIDR → firewall endpoint)
#     → Firewall endpoint (inspects inbound traffic)
#     → Firewall subnet route table → Protected subnet → Workload
#
# KEY EXAM SCENARIOS:
# ─────────────────────────────────────────────────────────────────────────────
# Q: "Block outbound HTTPS to all domains except specific allowlist"
# A: Network Firewall stateful domain list with ALLOWLIST + TLS_SNI
#
# Q: "Single inspection point for all VPCs in the organization"
# A: Centralized Inspection VPC + Transit Gateway hub-and-spoke + FMS
#
# Q: "IDS/IPS without managing your own appliances"
# A: AWS Network Firewall with Suricata-compatible stateful rule group
#
# Q: "Enforce consistent firewall rules across 50 AWS accounts in an Org"
# A: AWS Firewall Manager (FMS) deploying Network Firewall policies via Organizations
#
# Q: "SQL injection protection for web application via ALB"
# A: AWS WAF (not Network Firewall — WAF is the L7 HTTP/HTTPS tool)
#
# Q: "Block specific domains without decrypting HTTPS traffic"
# A: Network Firewall domain list rule with target_types = ["TLS_SNI"]
# =============================================================================
