# =============================================================================
# OUTPUTS — LAB 44: NETWORK FIREWALL
# SAA-C03 Study Lab
# =============================================================================

# =============================================================================
# FIREWALL ARN AND ID
# =============================================================================

output "firewall_arn" {
  description = <<-EOT
    ARN of the AWS Network Firewall.
    SAA-C03 exam tip: The firewall ARN is used to:
      - Associate a logging configuration (aws_networkfirewall_logging_configuration)
      - Reference the firewall in IAM policies for administration access control
      - Identify the firewall in CloudWatch metrics (namespace AWS/NetworkFirewall)
      - Associate with AWS Firewall Manager policies for multi-account enforcement
    Format: arn:aws:network-firewall:<region>:<account-id>:firewall/<name>
    Exam pattern: "Centrally manage Network Firewall across 50 accounts"
    Answer: AWS Firewall Manager (FMS) — requires AWS Organizations + Config enabled.
  EOT
  value       = aws_networkfirewall_firewall.main.arn
}

output "firewall_id" {
  description = <<-EOT
    ID of the Network Firewall resource (same as the ARN for this resource type).
    SAA-C03 exam tip: After the firewall is created and active, retrieve the
    firewall endpoint IDs from the firewall_status attribute. These endpoint IDs
    (format: vpce-XXXXXXXXXXXXXXXXX) are the next-hop targets for route table
    entries in both the protected subnet route tables (egress) and the IGW
    edge-association route table (ingress). Without correct route table entries
    pointing traffic at the firewall endpoints, the firewall inspects nothing.
  EOT
  value       = aws_networkfirewall_firewall.main.id
}

output "firewall_update_token" {
  description = <<-EOT
    Update token for the Network Firewall (used for optimistic locking).
    SAA-C03 exam tip: The update token prevents concurrent conflicting modifications
    to the firewall. If two processes attempt to update simultaneously, the second
    will receive an InvalidToken error and must re-fetch the current token before
    retrying. This is an AWS API-level concept, not typically tested directly, but
    relevant in automation/CI-CD contexts that manage firewall policy updates.
  EOT
  value       = aws_networkfirewall_firewall.main.update_token
}

# =============================================================================
# FIREWALL POLICY ARN
# =============================================================================

output "firewall_policy_arn" {
  description = <<-EOT
    ARN of the Network Firewall Policy.
    SAA-C03 exam tip: The Firewall Policy is the "glue" between rule groups and
    the firewall. Component hierarchy to know for the exam:
      AWS Firewall Manager Policy (org-level, multi-account)
        └── Firewall Policy (per-VPC or per-account)
              ├── Stateless Rule Groups (evaluated first, by priority)
              └── Stateful Rule Groups  (evaluated for forwarded packets)
    One policy can be applied to MULTIPLE firewalls.
    With AWS RAM (Resource Access Manager), policies can be shared across accounts.
    Firewall Manager automates policy deployment across all accounts in an Org.
    FMS requires: AWS Organizations enabled + Config enabled in all member accounts.
  EOT
  value       = aws_networkfirewall_firewall_policy.main.arn
}

# =============================================================================
# RULE GROUP ARNS
# =============================================================================

output "stateless_rule_group_arn" {
  description = <<-EOT
    ARN of the stateless rule group (lab-stateless-allow).
    SAA-C03 exam tip: Stateless rule groups are evaluated FIRST, before stateful
    rules, regardless of policy configuration. Key characteristics:
      - 5-tuple matching: src IP, dst IP, src port, dst port, protocol number
      - No connection state tracking — each packet evaluated independently
      - Priority: LOWER number = evaluated FIRST (opposite of WAF priority)
      - Actions: aws:pass (allow, skip stateful), aws:drop (block immediately),
                 aws:forward_to_sfe (allow AND send to stateful engine)
      - Capacity is FIXED at creation — cannot be increased without replacing group
    This group: forwards TCP 80/443 to stateful engine, drops everything else.
    Exam tip: Using aws:forward_to_sfe (not aws:pass) ensures stateful domain
    rules still evaluate HTTP/HTTPS traffic. aws:pass would bypass them.
  EOT
  value       = aws_networkfirewall_rule_group.stateless_allow.arn
}

output "stateful_domain_list_arn" {
  description = <<-EOT
    ARN of the stateful domain list rule group (lab-domain-allowlist).
    SAA-C03 exam tip: Domain list rule groups are evaluated AFTER stateless rules
    forward traffic with aws:forward_to_sfe. Key domain list concepts:
      generated_rules_type:
        ALLOWLIST — only listed domains permitted; everything else blocked.
                    Strictest posture — best for compliance environments.
        DENYLIST  — listed domains blocked; everything else permitted.
                    Easier to maintain; needs current threat intelligence.
      target_types:
        HTTP_HOST — inspects HTTP Host header (plaintext, port 80)
        TLS_SNI   — inspects TLS SNI field in ClientHello (HTTPS, NO decryption)
      targets:
        ".amazonaws.com" — dot prefix = domain AND all subdomains
        "example.com"    — exact domain only, no subdomain matching
    Exam pattern: "Block HTTPS to non-approved domains without SSL decryption"
    Answer: Network Firewall domain list with TLS_SNI target type.
  EOT
  value       = aws_networkfirewall_rule_group.stateful_domain_list.arn
}

output "stateful_suricata_rule_group_arn" {
  description = <<-EOT
    ARN of the stateful Suricata IPS rule group (lab-suricata-rules).
    SAA-C03 exam tip: Suricata-compatible rules enable full IDS/IPS capability:
      IDS mode: use "alert" action — traffic passes but is logged
      IPS mode: use "drop" action  — traffic is blocked AND logged
      Suricata rule format:
        <action> <protocol> <src-ip> <src-port> -> <dst-ip> <dst-port> (<options>)
      Key options: msg (description), content (payload match), nocase,
                   sid (unique ID — must be unique per policy), rev (revision),
                   dns.query (match DNS question name)
    Exam pattern: "Deploy managed IDS/IPS for all VPC traffic without appliances"
    Answer: AWS Network Firewall with Suricata-compatible stateful rule group.
    Exam distinction vs WAF:
      WAF        = HTTP/HTTPS Layer 7, attached to ALB/CloudFront/API GW
      Network FW = All protocols/ports, VPC-level, stateful, Suricata IPS
  EOT
  value       = aws_networkfirewall_rule_group.stateful_suricata.arn
}

# =============================================================================
# LOGGING
# =============================================================================

output "alert_log_group_name" {
  description = <<-EOT
    CloudWatch Log Group name for Network Firewall ALERT logs.
    SAA-C03 exam tip: ALERT logs are generated when rule actions fire:
      - Stateless: aws:alert_pass or aws:alert_drop action
      - Stateful:  Suricata "alert" action, or stateful rule ALERT action
    Log entries contain: rule SID, rule message, matched packet 5-tuple,
    timestamp, firewall ARN, availability zone.
    Use alert logs for:
      - Security incident detection and forensics
      - Real-time alerting: CloudWatch metric filter → alarm → SNS → Lambda
      - IDS/IPS rule effectiveness tuning (which rules fire most often)
    SAA-C03 pattern: "Alert on-call team when firewall detects SQL injection"
    Answer: Network Firewall ALERT log → CloudWatch → metric filter → alarm → SNS.
  EOT
  value       = aws_cloudwatch_log_group.firewall_alert.name
}

output "flow_log_group_name" {
  description = <<-EOT
    CloudWatch Log Group name for Network Firewall FLOW logs.
    SAA-C03 exam tip: FLOW logs capture connection-level records for ALL traffic
    traversing the firewall (allowed and blocked), similar to VPC Flow Logs:
      Fields: src IP, src port, dst IP, dst port, protocol, bytes, packets,
              direction, firewall action (ACCEPT/DROP), timestamp.
    Use flow logs for:
      - Traffic baseline analysis and anomaly detection
      - Compliance auditing (PCI DSS, HIPAA network logging requirements)
      - Capacity planning for bandwidth and connection counts
      - Investigating suspicious traffic patterns with Athena + S3
    Cost tip: For large environments, route FLOW logs to S3 (not CloudWatch)
    to minimize cost. Use Athena for ad-hoc queries on S3 flow log data.
    CloudWatch is better for ALERT logs (smaller volume, real-time alerting).
  EOT
  value       = aws_cloudwatch_log_group.firewall_flow.name
}

# =============================================================================
# VPC AND SUBNET DETAILS
# =============================================================================

output "inspection_vpc_id" {
  description = <<-EOT
    VPC ID of the inspection VPC hosting the Network Firewall.
    SAA-C03 exam tip: In the centralized inspection pattern with Transit Gateway:
      - This "Inspection VPC" is the hub
      - Spoke VPCs connect via TGW attachments
      - All internet-bound and east-west traffic routes through this VPC
      - Network Firewall sits between the TGW attachment subnets and the IGW
    Exam pattern: "Centralized traffic inspection for all VPCs in an account"
    Answer: Inspection VPC + TGW hub-and-spoke + Network Firewall.
    FMS can deploy and manage this pattern across an entire AWS Organization.
  EOT
  value       = aws_vpc.inspection.id
}

output "firewall_subnet_ids" {
  description = <<-EOT
    Subnet IDs of the dedicated firewall subnets (one per AZ).
    SAA-C03 exam tip: Firewall subnet requirements:
      - Dedicated per AZ — no other resources in these subnets
      - /28 minimum size (firewall endpoint uses only 1 IP); /24 recommended
      - One subnet_mapping entry per AZ in the firewall resource
      - Contains only the firewall endpoint ENI (vpce-xxx)
    After creation, the firewall's sync_states attribute maps each subnet to
    its firewall endpoint ID. Those endpoint IDs are the route table next-hops.
  EOT
  value       = aws_subnet.firewall[*].id
}

output "protected_subnet_ids" {
  description = <<-EOT
    Subnet IDs of the protected workload subnets (one per AZ).
    SAA-C03 exam tip: Route table configuration for protected subnets:
      0.0.0.0/0 → firewall endpoint in the SAME AZ (not the IGW directly)
    Critical rule — AZ symmetry:
      AZ1 protected subnet → AZ1 firewall endpoint (vpce-xxx)
      AZ2 protected subnet → AZ2 firewall endpoint (vpce-yyy)
    NEVER route cross-AZ through a single firewall endpoint:
      - Breaks HA (if that AZ's endpoint fails, both AZs lose connectivity)
      - Incurs inter-AZ data transfer charges
      - Creates potential for asymmetric routing and connection drops
  EOT
  value       = aws_subnet.protected[*].id
}

# =============================================================================
# EXAM CHEAT SHEET
# =============================================================================

output "exam_cheat_sheet" {
  description = "SAA-C03 quick reference comparing Network Firewall vs WAF vs Security Groups vs NACLs. No sensitive data."
  sensitive   = false
  value       = <<-EOT

  ╔══════════════════════════════════════════════════════════════════════════════╗
  ║    SAA-C03 CHEAT SHEET: Network Firewall vs WAF vs SGs vs NACLs             ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║                                                                              ║
  ║  SERVICE          LAYER    STATEFUL  SCOPE         DENY?  DEEP INSPECT      ║
  ║  ───────────────  ───────  ────────  ────────────  ─────  ──────────────    ║
  ║  Security Group   L3/L4    YES       ENI (instance) NO    No                ║
  ║                                      Allow-only          No explicit deny   ║
  ║                                                                              ║
  ║  Network ACL      L3/L4    NO        Subnet-level   YES   No                ║
  ║                                      Stateless            Must define both  ║
  ║                                                           in AND out rules  ║
  ║                                                                              ║
  ║  Network Firewall L3–L7    BOTH      VPC-level      YES   YES               ║
  ║                                      All protocols        Suricata IDS/IPS  ║
  ║                                                           Domain filtering  ║
  ║                                                           TLS SNI inspect   ║
  ║                                                                              ║
  ║  AWS WAF          L7 only  YES       Edge / HTTP    YES   HTTP/HTTPS only   ║
  ║                                      ALB/CF/APIGW         SQL inj, XSS     ║
  ║                                      AppSync              Rate limiting     ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  STATELESS vs STATEFUL RULES (within Network Firewall)                       ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  Stateless:   Evaluated FIRST. 5-tuple matching. No state tracking.         ║
  ║               Priority: lower number = evaluated first.                     ║
  ║               Actions: pass, drop, forward_to_sfe, alert_pass, alert_drop   ║
  ║               Use forward_to_sfe to send traffic to stateful engine.        ║
  ║                                                                              ║
  ║  Stateful:    Evaluated AFTER stateless. Tracks connection state.           ║
  ║               Three formats: domain list, Suricata IPS, 5-tuple+stateful    ║
  ║               STRICT_ORDER: first match wins (predictable, recommended)     ║
  ║               DEFAULT_ACTION_ORDER: pass > drop > alert (less predictable)  ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  DOMAIN LIST RULES                                                           ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  ALLOWLIST:   only listed domains permitted (strict egress control)         ║
  ║  DENYLIST:    listed domains blocked (threat intel feed approach)            ║
  ║  HTTP_HOST:   inspect HTTP Host header (plaintext)                          ║
  ║  TLS_SNI:     inspect TLS SNI in ClientHello (HTTPS, no decryption needed)  ║
  ║  ".domain.com" prefix = domain AND all subdomains                           ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  SURICATA IPS RULES                                                          ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  alert = IDS mode (log, do NOT block)                                        ║
  ║  drop  = IPS mode (block AND log)                                            ║
  ║  pass  = allow, stop evaluating further rules                               ║
  ║  reject = block + send TCP RST to source                                     ║
  ║  sid values must be unique across ALL rule groups in a policy               ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  LOGGING DESTINATIONS                                                        ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  CloudWatch Logs  = real-time monitoring, metric filters, alarms (costlier) ║
  ║  S3               = long-term cost-effective retention, Athena queries       ║
  ║  Kinesis Firehose = streaming to Splunk, OpenSearch, Datadog, Redshift       ║
  ║  ALERT logs  = rule match events (smaller volume, use CloudWatch)            ║
  ║  FLOW logs   = all connections (high volume, use S3 for cost)                ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  ROUTING REQUIREMENTS (the exam tricky part)                                 ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  Protected subnet RT:  0.0.0.0/0 → firewall endpoint (SAME AZ)             ║
  ║  Firewall subnet RT:   0.0.0.0/0 → Internet Gateway                        ║
  ║  IGW edge-assoc RT:    <protected CIDR> → firewall endpoint (SAME AZ)      ║
  ║  RULE: each AZ must route to its OWN AZ's endpoint — never cross-AZ        ║
  ╠══════════════════════════════════════════════════════════════════════════════╣
  ║  AWS FIREWALL MANAGER (FMS)                                                  ║
  ║  ─────────────────────────────────────────────────────────────────────────  ║
  ║  Purpose: centrally manage WAF + Network Firewall + Shield across accounts  ║
  ║  Requires: AWS Organizations + Config enabled in all member accounts         ║
  ║  Exam trigger: "Enforce consistent firewall policy across 50+ accounts"     ║
  ╚══════════════════════════════════════════════════════════════════════════════╝
  EOT
}
