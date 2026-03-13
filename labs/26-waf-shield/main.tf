################################################################################
# Lab 26: AWS WAF v2 and AWS Shield
# SAA-C03 Exam Focus: Layer 7 protection, DDoS mitigation
################################################################################
#
# WAF (Web Application Firewall) - Layer 7 Protection
# ----------------------------------------------------
# WAF inspects HTTP/S requests BEFORE they reach your application.
# It operates at Layer 7 (application layer) and can examine:
#   - IP addresses and IP ranges
#   - HTTP headers (User-Agent, Referer, Host, custom headers)
#   - HTTP body (JSON payloads, form fields)
#   - URI strings and query parameters
#   - Geographic origin of the request
#   - Request rate per IP
#
# WAF can be ATTACHED TO (scope determines resource):
#   - REGIONAL scope: ALB, API Gateway REST/HTTP, AppSync GraphQL, Cognito User Pools
#   - CLOUDFRONT scope (must use us-east-1 region): CloudFront distributions
#
# SAA-C03 EXAM TIP: WAF scope=CLOUDFRONT resources must be created in us-east-1
# regardless of where your application runs. All other targets use REGIONAL scope.
#
# Web ACL Rule Types:
#   1. IP Set rules       - allow/block specific IP addresses or CIDR ranges
#   2. Managed Rule Groups- pre-built rule sets (AWS or marketplace vendors)
#   3. Rate-based rules   - block IPs that exceed a request threshold per 5 minutes
#   4. Geo-match rules    - allow/block by country code
#   5. Regex pattern sets - match URI/body patterns with regular expressions
#   6. SQL injection / XSS- specific attack type detection rules
#
# Managed Rule Groups:
#   - AWS Managed Rules (free): AWSManagedRulesCommonRuleSet, AWSManagedRulesKnownBadInputsRuleSet, etc.
#   - AWS Marketplace (paid):   Fortinet, F5, Imperva, etc.
#   - Custom rule groups:       you build and maintain
#
# EXAM PATTERN: "Protect ALB from SQL injection and XSS" = WAF with managed rules
#
# WAF vs NACLs vs Security Groups (Layer comparison):
# +-----------------+----------+------------------------------------+
# | Control         | Layer    | Inspects                           |
# +-----------------+----------+------------------------------------+
# | Security Group  | Layer 4  | IP + Port (stateful)               |
# | NACL            | Layer 3/4| IP + Port (stateless)              |
# | WAF             | Layer 7  | HTTP headers, body, URI, rate, geo |
# +-----------------+----------+------------------------------------+
# Use NACLs/SGs to block unwanted ports/IPs; use WAF to block malicious HTTP patterns.
#
# AWS Shield - DDoS Protection
# ----------------------------
# Shield Standard (FREE - enabled automatically for ALL AWS accounts):
#   - Protects against common Layer 3/4 DDoS attacks:
#     SYN/ACK floods, UDP reflection attacks, volumetric attacks
#   - Automatic, always-on, no configuration required
#   - Applies to all AWS services by default
#
# Shield Advanced ($3,000/month + data transfer fees, 1-year commitment):
#   - Enhanced protection for: EC2, ELB, CloudFront, Global Accelerator, Route 53
#   - DDoS cost protection: AWS credits EC2/data-transfer charges caused by DDoS
#   - 24/7 access to AWS DDoS Response Team (DRT) - experts who help mitigate attacks
#   - Advanced attack diagnostics and real-time attack visibility in AWS Console
#   - Integration with WAF (at no additional WAF cost) for Layer 7 DDoS mitigation
#   - SLA-backed protection (uptime guarantees during DDoS events)
#
# SAA-C03 EXAM PATTERN:
#   "Automatically protect against common DDoS attacks at no cost" = Shield Standard
#   "Need SLA guarantee and DRT support during DDoS"               = Shield Advanced
#   "Protect Route 53 from DDoS with cost protection"              = Shield Advanced
#   "Block HTTP floods / Layer 7 DDoS"                             = WAF rate-based rules
#
################################################################################

################################################################################
# CLOUDWATCH LOG GROUP FOR WAF LOGS
# WAF logging destination: CloudWatch Logs, S3, or Kinesis Data Firehose.
# Log group name MUST start with "aws-waf-logs-" for WAF to accept it.
################################################################################

resource "aws_cloudwatch_log_group" "waf_logs" {
  # The prefix "aws-waf-logs-" is REQUIRED by the WAF logging configuration API
  name              = "aws-waf-logs-lab-waf-acl"
  retention_in_days = 30

  tags = {
    Name = "waf-lab-logs"
  }
}

################################################################################
# WAF IP SET
# A reusable list of IP addresses/CIDR ranges that rules can reference.
# Use cases:
#   - Block known malicious IPs / botnets
#   - Allow only your corporate IP ranges (allowlist)
#   - Block a specific attacking IP during an incident
#
# ip_address_version: IPV4 or IPV6
# addresses: list of CIDRs (/32 for single IP, /24 for a subnet, etc.)
################################################################################

resource "aws_wafv2_ip_set" "blocked_ips" {
  name        = "lab-blocked-ip-set"
  description = "IP addresses to explicitly block - add attacker IPs here"
  scope       = "REGIONAL" # REGIONAL for ALB/API GW; CLOUDFRONT requires us-east-1

  ip_address_version = "IPV4"

  addresses = [
    "192.0.2.0/24",    # TEST-NET-1 (RFC 5737) - safe example, not real traffic
    "198.51.100.0/24", # TEST-NET-2 (RFC 5737)
  ]

  tags = {
    Name = "lab-blocked-ip-set"
  }
}

################################################################################
# WAF WEB ACL
# The core WAF resource. Evaluates rules in priority order (lower number = first).
# When a request matches a rule, the action (Allow/Block/Count/CAPTCHA) is taken
# and no further rules are evaluated (unless the rule uses Count action).
#
# default_action: what happens if NO rule matches - usually "allow" for whitelisting
# architectures or "block" for strict allowlist-only deployments.
#
# visibility_config: enables CloudWatch metrics for the ACL and its rules.
# Always enable metrics - they feed into CloudWatch dashboards and alarms.
################################################################################

resource "aws_wafv2_web_acl" "lab_waf_acl" {
  name        = "lab-waf-acl"
  description = "SAA-C03 lab WAF: demonstrates IP block, managed rules, rate limiting, geo-block"
  scope       = "REGIONAL"

  # Default action: ALLOW requests that don't match any rule
  # Flip to block{} for a strict allowlist model
  default_action {
    allow {}
  }

  # ---------------------------------------------------------------------------
  # RULE 1: IP Set Block Rule (Priority 1 - evaluated first)
  # Explicitly block known-bad IP addresses before any other evaluation.
  # Lowest priority number = checked first = most authoritative.
  # ---------------------------------------------------------------------------
  rule {
    name     = "block-specific-ips"
    priority = 1

    # "action" applies when this specific rule matches
    action {
      block {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.blocked_ips.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockSpecificIPsRule"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------
  # RULE 2: AWS Managed Common Rule Group (Priority 2)
  # AWSManagedRulesCommonRuleSet covers OWASP Top 10:
  #   - SQL injection, XSS, path traversal, local file inclusion
  #   - Request size violations, known bad inputs
  #
  # SAA-C03 EXAM TIP:
  #   Managed rules are the fastest way to get broad protection without
  #   writing individual rules. "Protect against OWASP Top 10" = managed rules.
  #
  # override_action: with managed groups you use override_action, not action.
  #   none{} = use the rule group's built-in actions (block/allow as configured by AWS)
  #   count{} = override all actions to Count (useful for testing before blocking)
  # ---------------------------------------------------------------------------
  rule {
    name     = "aws-managed-common-rule-set"
    priority = 2

    # override_action instead of action for managed rule groups
    override_action {
      none {} # respect the managed rule group's built-in block/allow decisions
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        # version: omit to always use the latest; pin a version for stability
        # version = "Version_1.5"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------
  # RULE 3: Rate-Based Rule (Priority 3)
  # Automatically blocks any single IP that sends more than 2000 requests
  # in any rolling 5-minute window.
  #
  # How it works:
  #   WAF tracks request counts per IP over a sliding 5-minute window.
  #   When an IP crosses the threshold, WAF blocks it until the rate drops below
  #   the limit for the next evaluation window.
  #
  # SAA-C03 USE CASES:
  #   - Protect against HTTP flood / Layer 7 DDoS attacks
  #   - Prevent credential stuffing / brute-force login attempts
  #   - Limit scraping bots
  #
  # limit: minimum value is 100; measured per 5-minute period.
  # aggregate_key_type: IP (per source IP) or FORWARDED_IP (use X-Forwarded-For header,
  #   useful when traffic passes through a proxy/CDN).
  # ---------------------------------------------------------------------------
  rule {
    name     = "rate-limit-per-ip"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000 # max requests per IP per 5 minutes
        aggregate_key_type = "IP" # track by source IP address

        # Optional: scope down - only count requests matching this sub-statement
        # scope_down_statement { ... }      # e.g., only count POST /login requests
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  # ---------------------------------------------------------------------------
  # RULE 4: Geo-Match Block Rule (Priority 4)
  # Block traffic originating from specific countries.
  #
  # SAA-C03 USE CASES:
  #   - Compliance: block traffic from embargoed countries
  #   - Reduce attack surface: block regions with no legitimate users
  #   - Combine with rate-based rules for layered defense
  #
  # country_codes: ISO 3166-1 alpha-2 codes (2-letter country codes)
  # NOT_statement: inverts the geo match - use to ALLOW only specific countries.
  #   Example: allow only US traffic by wrapping geo-match US in a NOT_statement
  #   and setting the action to block.
  # ---------------------------------------------------------------------------
  rule {
    name     = "geo-block-rule"
    priority = 4

    action {
      block {}
    }

    statement {
      geo_match_statement {
        # Block traffic from these country codes (examples only)
        country_codes = ["KP", "CU"] # North Korea, Cuba (common compliance examples)
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoBlockRule"
      sampled_requests_enabled   = true
    }
  }

  # Top-level visibility config for the entire Web ACL
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "LabWAFAcl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "lab-waf-acl"
  }
}

################################################################################
# WAF LOGGING CONFIGURATION
# Sends WAF request logs to a destination for analysis and auditing.
#
# Supported destinations:
#   1. CloudWatch Logs (log group name must start with "aws-waf-logs-")
#   2. S3 bucket          (bucket name must start with "aws-waf-logs-")
#   3. Kinesis Data Firehose (delivery stream name must start with "aws-waf-logs-")
#
# Logging captures: timestamp, source IP, country, matched rules, action taken,
# HTTP method, URI, headers, and (optionally) the request body.
#
# redacted_fields: use to omit sensitive data (passwords, auth tokens) from logs.
# logging_filter: send only BLOCK or only ALLOW logs to reduce volume/cost.
################################################################################

resource "aws_wafv2_web_acl_logging_configuration" "lab_waf_logging" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.lab_waf_acl.arn

  # Optional: redact sensitive headers from logs
  # redacted_fields {
  #   single_header {
  #     name = "authorization"
  #   }
  # }

  # Optional: only log blocked requests to reduce CloudWatch cost
  # logging_filter {
  #   default_behavior = "DROP"
  #   filter {
  #     behavior    = "KEEP"
  #     requirement = "MEETS_ANY"
  #     condition {
  #       action_condition { action = "BLOCK" }
  #     }
  #   }
  # }
}

################################################################################
# SHIELD ADVANCED (COMMENTED OUT - $3,000/month)
# Uncomment and apply only if you have a business justification for the cost.
#
# Shield Advanced provides:
#   1. Enhanced DDoS detection and mitigation for EC2, ELB, CloudFront, Route 53
#   2. DDoS cost protection: AWS credits charges caused by scaling during attacks
#   3. 24/7 DDoS Response Team (DRT) access - AWS experts join your war room
#   4. Real-time attack visibility and detailed post-attack forensics
#   5. Proactive engagement: DRT can engage automatically based on Route 53 health checks
#   6. WAF integration at no additional WAF cost (when used with Shield Advanced)
#
# SAA-C03 EXAM TRAPS:
#   - Shield STANDARD is free and automatic - you don't create a Terraform resource for it
#   - Shield ADVANCED requires explicit enrollment and the $3k/month fee
#   - Only Shield Advanced provides DRT access, cost protection, and advanced visibility
#   - Shield Standard covers Layer 3/4 only; Layer 7 DDoS requires WAF + Shield Advanced
#
# aws_shield_protection resource associates Shield Advanced with a specific AWS resource.
# You need one aws_shield_protection per protected resource (ALB, CloudFront, Route 53, etc.)
#
# resource "aws_shield_protection" "alb_shield" {
#   name         = "lab-alb-shield-advanced"
#   resource_arn = aws_lb.my_alb.arn   # ARN of the resource to protect
#
#   tags = {
#     Name     = "lab-alb-shield-advanced"
#     ExamNote = "Shield Advanced: $3k/month, DRT access, DDoS cost protection, Layer 3/4/7"
#   }
# }
#
# To enable Shield Advanced subscription for the entire account (prerequisite):
# resource "aws_shield_subscription" "shield_advanced" {
#   auto_renew = "ENABLED"
# }
################################################################################

################################################################################
# OUTPUTS
################################################################################

output "waf_acl_arn" {
  description = <<-EOT
    ARN of the WAF Web ACL. Use this to associate the ACL with:
      - ALB: aws_alb_target_group association or aws_wafv2_web_acl_association
      - CloudFront: web_acl_id argument in aws_cloudfront_distribution
      - API Gateway: aws_api_gateway_stage with web_acl_arn
  EOT
  value       = aws_wafv2_web_acl.lab_waf_acl.arn
}

output "waf_acl_id" {
  description = "ID of the WAF Web ACL (used alongside ARN for some associations)"
  value       = aws_wafv2_web_acl.lab_waf_acl.id
}

output "waf_acl_capacity" {
  description = "WAF Capacity Units (WCU) consumed by this ACL. Limit is 1500 WCU per Web ACL."
  value       = aws_wafv2_web_acl.lab_waf_acl.capacity
}

output "waf_log_group_name" {
  description = "CloudWatch log group receiving WAF request logs"
  value       = aws_cloudwatch_log_group.waf_logs.name
}

output "exam_reminder" {
  description = "SAA-C03 key distinctions for WAF and Shield"
  value       = <<-EOT
    WAF: Layer 7 (HTTP), attach to ALB/CloudFront/API GW, block IPs/geo/rate/patterns.
    Shield Standard: FREE, auto-enabled, Layer 3/4 DDoS protection only.
    Shield Advanced: $3k/month, DRT access, DDoS cost protection, Layer 7 via WAF integration.
    NACLs/SGs: Layer 3/4 only - cannot inspect HTTP body or headers.
  EOT
}
