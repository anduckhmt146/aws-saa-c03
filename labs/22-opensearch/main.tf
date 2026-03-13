# =============================================================================
# LAB 22: Amazon OpenSearch Service
# =============================================================================
#
# WHAT IS OPENSEARCH SERVICE?
# ----------------------------
# Amazon OpenSearch Service (formerly Amazon Elasticsearch Service) is a
# managed service for deploying, operating, and scaling OpenSearch (and
# legacy Elasticsearch) clusters. It is purpose-built for:
#   - Full-text search (e-commerce product search, site search)
#   - Log analytics (centralized logging, security event analysis)
#   - Application performance monitoring (APM)
#   - Business intelligence and analytics dashboards
#
# OPENSEARCH vs ELASTICSEARCH:
# AWS rebranded the service in 2021 after forking from Elasticsearch 7.10.
# OpenSearch is open-source and maintained by AWS + community.
# The service supports both OpenSearch and legacy Elasticsearch engine versions.
#
# KEY TERMINOLOGY FOR SAA-C03:
# - DOMAIN: the AWS term for an OpenSearch/ES cluster. When AWS says "domain",
#   think "OpenSearch cluster". Confusingly, "domain" in OpenSearch ≠ DNS domain.
# - INDEX: a collection of documents (analogous to a table in SQL).
# - DOCUMENT: a JSON object stored in an index (analogous to a row).
# - SHARD: a Lucene index; each index is split into shards distributed across
#   data nodes for parallelism and scale.
#
# NODE TYPES:
# - DATA NODES: store data and execute search/aggregation queries.
#   You must provision at least 1 data node (2+ recommended for HA).
# - DEDICATED MASTER NODES: manage cluster state, track nodes/shards, handle
#   index creation/deletion. Offloading this from data nodes improves stability.
#   Recommended for production. Always provision an ODD number (3 or 5) to
#   avoid split-brain scenarios during elections.
# - ULTRAWARM NODES: S3-backed warm tier. Store older, less-frequently accessed
#   data at lower cost. Read-only; data must be migrated from hot storage.
# - COLD STORAGE: even cheaper tier for archived data (OpenSearch 1.x+).
#
# ULTRAWARM — EXAM KEY CONCEPT:
# - UltraWarm stores index data in Amazon S3 instead of EBS volumes.
# - Data in UltraWarm is read-only and uses a cache for performance.
# - Cost is ~90% cheaper per GB than hot (EBS-backed) storage.
# - Ideal for log data older than 30 days, audit records, historical metrics.
# - SAA-C03 scenario: "store 90 days of logs cheaply with search capability"
#   → OpenSearch with UltraWarm.
#
# USE CASES ON THE EXAM:
# 1. Full-text search on a product catalog → OpenSearch
# 2. Centralized log analytics → OpenSearch (often with Kinesis Firehose or
#    CloudWatch Logs subscription filter as the ingestion path)
# 3. Security analytics / SIEM → OpenSearch Security Analytics plugin
# 4. Clickstream analytics → Kinesis → OpenSearch
# 5. Near-real-time dashboards → OpenSearch Dashboards (Kibana fork)
#
# COMMON ARCHITECTURE (SAA-C03 EXAM PATTERN):
# CloudWatch Logs → Subscription Filter → Lambda (or Firehose) → OpenSearch
# This is the canonical "ship logs to OpenSearch" pattern. Know it cold.
#
# VPC vs PUBLIC ACCESS:
# - VPC access: domain is only reachable within the VPC. More secure.
#   Requires VPN/DirectConnect for external access. Cannot change after creation.
# - Public access: domain has a public endpoint. Protected by access policy
#   and optionally fine-grained access control. Easier for development.
# EXAM NOTE: For any scenario mentioning security or compliance, choose VPC.
#
# ENCRYPTION OPTIONS:
# - Encryption at rest: KMS-managed, encrypts data on EBS and S3 (UltraWarm).
# - Encryption in transit (HTTPS): enforces TLS for all HTTP connections.
# - Node-to-node encryption: encrypts traffic between cluster nodes internally.
#   Recommended when running in a VPC (prevents internal network eavesdropping).
#
# FINE-GRAINED ACCESS CONTROL (FGAC):
# - Provides document-level and field-level security.
# - Can use IAM roles OR an internal OpenSearch user database.
# - Required for some compliance use cases (HIPAA, PCI).
# - When FGAC is enabled, an "admin user" with master credentials is created.
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG GROUPS FOR OPENSEARCH
# -----------------------------------------------------------------------------
# OpenSearch can publish several types of logs to CloudWatch Logs:
#
# 1. INDEX_SLOW_LOGS: queries/indexing that exceed a configurable threshold.
#    Useful for diagnosing performance issues.
# 2. SEARCH_SLOW_LOGS: search requests that take too long.
# 3. ES_APPLICATION_LOGS: OpenSearch application logs (errors, warnings).
#    Essential for diagnosing cluster health issues.
# 4. AUDIT_LOGS: records all requests for compliance/security auditing.
#    Requires fine-grained access control to be enabled.
#
# EXAM NOTE: These log groups are where OPENSEARCH WRITES ITS OWN LOGS.
# This is different from the pattern where OpenSearch RECEIVES logs from
# other services. Both directions exist and are commonly tested.

# Index slow logs — captures slow indexing operations
resource "aws_cloudwatch_log_group" "opensearch_index_slow" {
  name              = "/aws/opensearch/domains/opensearch-lab/index-slow-logs"
  retention_in_days = 14 # Keep 14 days of logs; adjust based on compliance needs

  tags = {
    Name    = "opensearch-index-slow-logs"
    Purpose = "OpenSearch index slow log destination"
  }
}

# Search slow logs — captures slow search queries
resource "aws_cloudwatch_log_group" "opensearch_search_slow" {
  name              = "/aws/opensearch/domains/opensearch-lab/search-slow-logs"
  retention_in_days = 14

  tags = {
    Name    = "opensearch-search-slow-logs"
    Purpose = "OpenSearch search slow log destination"
  }
}

# Application logs — OpenSearch engine logs (errors, warnings, cluster events)
resource "aws_cloudwatch_log_group" "opensearch_application" {
  name              = "/aws/opensearch/domains/opensearch-lab/application-logs"
  retention_in_days = 30 # Longer retention for application logs (troubleshooting)

  tags = {
    Name    = "opensearch-application-logs"
    Purpose = "OpenSearch application/error log destination"
  }
}

# Audit logs — all authenticated requests (requires FGAC enabled)
resource "aws_cloudwatch_log_group" "opensearch_audit" {
  name              = "/aws/opensearch/domains/opensearch-lab/audit-logs"
  retention_in_days = 90 # Longer retention for audit/compliance logs

  tags = {
    Name    = "opensearch-audit-logs"
    Purpose = "OpenSearch audit log destination for compliance"
  }
}

# -----------------------------------------------------------------------------
# CLOUDWATCH LOG RESOURCE POLICY
# -----------------------------------------------------------------------------
# By default, OpenSearch Service does NOT have permission to write to
# CloudWatch Logs. You must create a RESOURCE-BASED POLICY on the log group
# that grants the es.amazonaws.com service principal write access.
#
# This is a RESOURCE-BASED POLICY (attached to the log group), not an
# IDENTITY-BASED POLICY (attached to an IAM role). The distinction matters
# for the SAA-C03 exam:
# - Resource-based policies: attached to the resource, define who can access it
# - Identity-based policies: attached to a principal, define what it can access
#
# EXAM NOTE: This pattern (service principal + resource policy) is also used
# for S3 bucket policies, KMS key policies, and SNS topic policies.

resource "aws_cloudwatch_log_resource_policy" "opensearch_log_policy" {
  policy_name = "opensearch-log-publishing-policy"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOpenSearchToWriteLogs"
        Effect = "Allow"
        Principal = {
          # es.amazonaws.com is the OpenSearch Service service principal.
          # This grants the managed service permission to call CloudWatch Logs
          # APIs on your behalf.
          Service = "es.amazonaws.com"
        }
        Action = [
          "logs:PutLogEvents",    # Write log events to log streams
          "logs:CreateLogGroup",  # Create the log group if it doesn't exist
          "logs:CreateLogStream", # Create log streams within the log group
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        # Scope the policy to specific log groups using ARN wildcards.
        # More secure than allowing access to all log groups ("*").
        Resource = [
          "${aws_cloudwatch_log_group.opensearch_index_slow.arn}:*",
          "${aws_cloudwatch_log_group.opensearch_search_slow.arn}:*",
          "${aws_cloudwatch_log_group.opensearch_application.arn}:*",
          "${aws_cloudwatch_log_group.opensearch_audit.arn}:*",
        ]
        # CONDITION: Restrict to the current AWS account to prevent confused
        # deputy attacks (cross-account service misuse).
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# OPENSEARCH DOMAIN
# -----------------------------------------------------------------------------
# The "domain" is the top-level resource — it is the entire OpenSearch cluster
# including all nodes, storage, networking, and configuration.
#
# SIZING GUIDANCE:
# - Data nodes: start with 2 for HA (one per AZ). Scale out for more throughput.
# - Master nodes: always use 3 dedicated masters for production clusters.
#   Master nodes should be a smaller instance class than data nodes.
# - EBS storage: each data node gets its own EBS volume. Total cluster storage
#   = (volume_size per node) × (number of data nodes).
#
# EXAM TRAP: OpenSearch is NOT serverless by default. You must choose instance
# types and storage sizes. (OpenSearch Serverless is a separate offering.)

resource "aws_opensearch_domain" "opensearch_lab" {
  domain_name    = "opensearch-lab"
  engine_version = "OpenSearch_2.11" # Format: "OpenSearch_X.Y" or "Elasticsearch_X.Y"

  # ---------------------------------------------------------------------------
  # CLUSTER CONFIGURATION
  # ---------------------------------------------------------------------------
  cluster_config {
    # DATA NODES: The worker bees — store data and execute queries.
    # Using 2 data nodes allows one per AZ for Multi-AZ redundancy.
    # instance_type options: t3.small/medium, r6g.large, m6g.large, etc.
    # For production: r6g family (memory-optimized) is most common.
    instance_count = 2
    instance_type  = "t3.small.search" # .search suffix is OpenSearch-specific

    # DEDICATED MASTER NODES: Separate instances that only manage cluster state.
    # Benefits of dedicated masters:
    # 1. Data nodes can focus 100% on indexing/searching.
    # 2. Cluster stability improves — master elections don't compete with data ops.
    # 3. Required for clusters larger than 10 nodes.
    # ALWAYS use an ODD number (3 or 5) to achieve quorum and avoid split-brain.
    # master_count=3: can tolerate 1 master failure while maintaining quorum.
    # master_count=5: can tolerate 2 master failures (larger/critical clusters).
    dedicated_master_enabled = true
    dedicated_master_count   = 3 # Must be odd: 3 or 5
    dedicated_master_type    = "t3.small.search"

    # AVAILABILITY ZONE AWARENESS: distribute data nodes across multiple AZs.
    # With 2 data nodes and 2 AZs, each AZ gets one data node.
    # If one AZ fails, the cluster continues operating (with reduced capacity).
    #
    # EXAM NOTE: Zone awareness requires an even number of data nodes (2, 4, 6)
    # when using 2 AZs, or a multiple of 3 when using 3 AZs.
    zone_awareness_enabled = true
    zone_awareness_config {
      # availability_zone_count can be 2 or 3.
      # 2 AZs: simpler, lower cross-AZ data transfer costs.
      # 3 AZs: maximum fault tolerance, costs more for data transfer.
      availability_zone_count = 2
    }

    # WARM NODES (UltraWarm): optional warm tier for cost-effective storage.
    # Uncomment the block below to enable UltraWarm.
    # UltraWarm stores data in S3 with a caching layer.
    # Use case: logs older than 7-30 days that are rarely queried.
    #
    # warm_enabled = true
    # warm_count   = 2                    # min 2 warm nodes
    # warm_type    = "ultrawarm1.medium.search"
    #
    # EXAM SCENARIO: "Store 1 year of security logs for occasional query at
    # lowest cost" → OpenSearch with UltraWarm + Cold storage.
  }

  # ---------------------------------------------------------------------------
  # EBS STORAGE OPTIONS
  # ---------------------------------------------------------------------------
  # Each data node has its own EBS volume. EBS is the "hot" storage tier.
  # Volume size is per-node; total cluster capacity = size × instance_count.
  #
  # VOLUME TYPES:
  # - gp2: general purpose SSD (legacy, still supported)
  # - gp3: newer general purpose SSD, more cost-effective, configurable IOPS
  # - io1: provisioned IOPS SSD for latency-sensitive workloads
  #
  # EXAM NOTE: For most OpenSearch use cases, gp3 is the right answer.
  # Use io1 only if you have specific IOPS requirements for high-throughput
  # indexing workloads.
  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 20   # GB per data node; total = 20 GB × 2 nodes = 40 GB
    iops        = 3000 # Baseline IOPS for gp3 (default is 3000)
    throughput  = 125  # MB/s throughput for gp3 (default is 125)
  }

  # ---------------------------------------------------------------------------
  # ENCRYPTION AT REST
  # ---------------------------------------------------------------------------
  # Encrypts all data stored on EBS volumes and in S3 (UltraWarm/cold tier).
  # Uses AWS KMS. Can specify a CMK or use the AWS-managed key for OpenSearch.
  #
  # EXAM NOTE: Like DocumentDB, encryption at rest must be enabled at domain
  # creation. You cannot enable it on an existing unencrypted domain.
  # To encrypt an existing domain: take a snapshot → restore to a new encrypted
  # domain.
  encrypt_at_rest {
    enabled = true
    # kms_key_id = "arn:aws:kms:..." — omit to use AWS-managed key (aws/es)
    # Specify a CMK ARN for more control over key policy and rotation.
  }

  # ---------------------------------------------------------------------------
  # NODE-TO-NODE ENCRYPTION
  # ---------------------------------------------------------------------------
  # Encrypts all traffic between OpenSearch nodes within the cluster.
  # This is the "internal" encryption — data in transit between data nodes
  # and master nodes.
  #
  # Without node-to-node encryption, traffic between nodes is unencrypted
  # even if encryption at rest and HTTPS are enabled.
  #
  # EXAM NOTE: For a complete encryption posture, you need ALL THREE:
  # 1. encrypt_at_rest    → data stored on disk
  # 2. node_to_node       → data moving between nodes inside the cluster
  # 3. enforce_https      → data moving between clients and the cluster
  node_to_node_encryption {
    enabled = true
  }

  # ---------------------------------------------------------------------------
  # DOMAIN ENDPOINT OPTIONS (HTTPS / TLS)
  # ---------------------------------------------------------------------------
  # Controls encryption in transit between clients and the OpenSearch domain.
  #
  # enforce_https: if true, HTTP requests are rejected with a 301 redirect
  # (and optionally a 403). Clients MUST use HTTPS.
  #
  # tls_security_policy: minimum TLS version accepted.
  # - "Policy-Min-TLS-1-2-2019-07" = TLS 1.2 minimum (recommended)
  # - "Policy-Min-TLS-1-0-2019-07" = TLS 1.0 minimum (legacy, not recommended)
  # For compliance (HIPAA, FedRAMP, PCI): use TLS 1.2 minimum.
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # ---------------------------------------------------------------------------
  # ADVANCED SECURITY OPTIONS (FINE-GRAINED ACCESS CONTROL)
  # ---------------------------------------------------------------------------
  # Fine-Grained Access Control (FGAC) provides:
  # - Role-based access control (RBAC) at index, document, and field level
  # - Integration with IAM (external identity source)
  # - Internal user database (username/password management within OpenSearch)
  # - Kibana/Dashboards multi-tenancy (separate workspaces per user/team)
  #
  # REQUIREMENTS for FGAC:
  # - encrypt_at_rest must be enabled
  # - node_to_node_encryption must be enabled
  # - enforce_https must be enabled
  # All three are required — AWS enforces this.
  #
  # EXAM SCENARIOS for FGAC:
  # - "Different teams should only see their own log indices" → FGAC
  # - "Prevent a read-only user from deleting indices" → FGAC
  # - "Field-level security: hide PII fields from analysts" → FGAC
  # - "Comply with HIPAA access controls for healthcare data" → FGAC
  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false # Never allow anonymous access in production
    internal_user_database_enabled = true  # Enable username/password auth within OpenSearch

    # MASTER USER: the administrative superuser for the OpenSearch cluster.
    # This user can manage indices, roles, and other users via the
    # OpenSearch Dashboards (Kibana) security plugin UI or REST API.
    #
    # In production: use master_user_arn to map an IAM role as the master user
    # instead of a username/password. IAM-based auth is more secure.
    master_user_options {
      master_user_name     = "opensearch-admin"
      master_user_password = "LabPassword123!" # In production: use Secrets Manager!
      # master_user_arn = "arn:aws:iam::123456789012:role/OpenSearchAdminRole"
      # Use master_user_arn for IAM-based master user (mutually exclusive with
      # master_user_name/master_user_password).
    }
  }

  # ---------------------------------------------------------------------------
  # LOG PUBLISHING OPTIONS
  # ---------------------------------------------------------------------------
  # Configure which OpenSearch logs are sent to which CloudWatch Log Groups.
  # Each log type is enabled/disabled independently.
  #
  # LOG TYPE REFERENCE:
  # INDEX_SLOW_LOGS   - indexing operations exceeding slow log threshold
  # SEARCH_SLOW_LOGS  - search requests exceeding slow log threshold
  # ES_APPLICATION_LOGS - OpenSearch engine application logs
  # AUDIT_LOGS        - all authenticated API calls (FGAC required)

  log_publishing_options {
    log_type                 = "INDEX_SLOW_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_index_slow.arn
    enabled                  = true
  }

  log_publishing_options {
    log_type                 = "SEARCH_SLOW_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_search_slow.arn
    enabled                  = true
  }

  log_publishing_options {
    log_type                 = "ES_APPLICATION_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_application.arn
    enabled                  = true
  }

  # AUDIT LOGS require fine-grained access control to be enabled (see above).
  # When enabled, every authenticated request is logged — very verbose.
  # Enable for compliance; use a longer retention period on the log group.
  log_publishing_options {
    log_type                 = "AUDIT_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_audit.arn
    enabled                  = true
  }

  # ---------------------------------------------------------------------------
  # ACCESS POLICY
  # ---------------------------------------------------------------------------
  # The domain access policy is a RESOURCE-BASED POLICY that controls who can
  # make API calls to the OpenSearch HTTP endpoint (not the AWS API).
  #
  # With fine-grained access control enabled, this policy typically grants
  # access broadly (e.g., to the account), and FGAC handles finer permissions.
  #
  # POLICY TYPES:
  # - IP-based: allow specific IPs (useful for public domains)
  # - IAM principal-based: allow specific IAM users/roles
  # - Combined: IP + IAM for defense in depth
  #
  # EXAM NOTE: With FGAC enabled, AWS recommends a permissive domain policy
  # (allowing the account) and relying on FGAC for fine-grained control.
  # Without FGAC, the domain policy IS your primary access control.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "es:*" # es:* covers both ESHttp* (data plane) and es:* (control plane)
        Resource = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/opensearch-lab/*"
      }
    ]
  })

  # ---------------------------------------------------------------------------
  # ADVANCED OPTIONS
  # ---------------------------------------------------------------------------
  # Fine-tune OpenSearch behavior. Key settings for the exam:
  # - rest.action.multi.allow_explicit_index: controls whether requests can
  #   explicitly name an index. Setting to "false" prevents index enumeration.
  # - override_main_response_version: return 7.x version header for legacy
  #   Elasticsearch client compatibility.
  advanced_options = {
    "rest.action.multi.allow_explicit_index" = "true"
    "override_main_response_version"         = "false"
  }

  # ---------------------------------------------------------------------------
  # TAGS
  # ---------------------------------------------------------------------------
  tags = {
    Name    = "opensearch-lab-domain"
    Purpose = "SAA-C03 lab — search and log analytics"
  }

  # Dependencies: ensure log groups and resource policy exist before the
  # domain tries to publish logs.
  depends_on = [
    aws_cloudwatch_log_resource_policy.opensearch_log_policy,
    aws_cloudwatch_log_group.opensearch_index_slow,
    aws_cloudwatch_log_group.opensearch_search_slow,
    aws_cloudwatch_log_group.opensearch_application,
    aws_cloudwatch_log_group.opensearch_audit,
  ]
}

# =============================================================================
# SAA-C03 EXAM ARCHITECTURE PATTERN: CLOUDWATCH LOGS → OPENSEARCH
# =============================================================================
# The most commonly tested OpenSearch integration is shipping CloudWatch Logs
# to OpenSearch for search and analytics. The architecture is:
#
#   Application → CloudWatch Logs Log Group
#                         ↓  (Subscription Filter)
#                   Lambda function
#                         ↓  (HTTP PUT)
#                   OpenSearch Domain
#                         ↓
#                   OpenSearch Dashboards (visualization)
#
# An alternative path (higher throughput, no Lambda needed):
#   CloudWatch Logs → Kinesis Data Firehose → OpenSearch Domain
#
# The subscription filter is the KEY PIECE — it forwards matching log events
# from CloudWatch Logs to a destination (Lambda, Kinesis Streams, or Firehose).
# For OpenSearch, the Lambda path is most common in exam questions.
#
# Terraform for the subscription filter pattern (not deployed here — reference):
#
# resource "aws_cloudwatch_log_subscription_filter" "to_opensearch" {
#   name            = "ship-to-opensearch"
#   log_group_name  = "/aws/lambda/my-app"
#   filter_pattern  = ""                      # "" = all log events
#   destination_arn = aws_lambda_function.log_shipper.arn
# }
#
# resource "aws_lambda_permission" "allow_cloudwatch" {
#   statement_id  = "AllowCWLogsInvoke"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.log_shipper.function_name
#   principal     = "logs.${data.aws_region.current.name}.amazonaws.com"
#   source_arn    = aws_cloudwatch_log_group.app_logs.arn
# }
# =============================================================================
