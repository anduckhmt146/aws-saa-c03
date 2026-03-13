###############################################################################
# LAB 45 - RDS Proxy
# AWS SAA-C03 Exam Prep
###############################################################################
#
# RDS PROXY — WHAT IT IS
# =======================
# RDS Proxy sits between your application and an RDS or Aurora database.
# It maintains a pool of connections to the database and multiplexes many
# application connections onto a smaller number of actual DB connections.
#
# THE CORE PROBLEM RDS PROXY SOLVES
# -----------------------------------
# Relational databases have a hard limit on concurrent connections.
# MySQL RDS: max_connections ≈ (DBInstanceClassMemory / 12582880)
# A db.t3.micro has ~1 GB RAM → roughly 80 connections maximum.
#
# Lambda + RDS (without proxy):
#   - Every Lambda invocation opens a NEW TCP connection to the DB.
#   - Lambda can scale to thousands of concurrent invocations.
#   - 1000 concurrent Lambdas = 1000 simultaneous DB connections.
#   - Result: "too many connections" errors, throttling, DB crashes.
#
# Lambda + RDS Proxy:
#   - Lambda connects to the proxy endpoint (fast, cheap).
#   - Proxy holds a warm pool of ~20 real DB connections.
#   - 1000 concurrent Lambdas → 20 DB connections via multiplexing.
#   - SAA-C03 KEY: Lambda + RDS = ALWAYS recommend RDS Proxy.
#
# MULTIPLEXING vs PINNING
# ------------------------
# Multiplexing: proxy can reuse one DB connection for multiple client
#   sessions when those sessions are idle between queries. This is the
#   primary efficiency gain.
# Pinning: when a client uses session-level state (SET statements,
#   temporary tables, stored procedures, multi-statement transactions),
#   the proxy "pins" that client to one DB connection for the duration.
#   Pinned connections reduce the multiplexing benefit — avoid session
#   state where possible to maximise proxy efficiency.
#
# IAM AUTHENTICATION
# -------------------
# Traditional auth: app knows the DB username + password → credential
#   rotation requires app restarts or config deploys.
# RDS Proxy IAM auth: app authenticates to the proxy using an IAM role.
#   The proxy itself retrieves the actual DB credentials from Secrets Manager.
#   Benefits:
#     - No DB password ever touches application code or environment vars.
#     - Secrets Manager rotates credentials automatically; proxy picks up
#       the new secret without any app change or restart.
#     - IAM auth = short-lived tokens (15 min) → reduced exposure window.
#   SAA-C03: "Rotate DB credentials without app downtime" = Proxy + Secrets Manager.
#
# FAILOVER BEHAVIOUR
# -------------------
# Without proxy: app holds connections to the primary DB. On failover,
#   all connections drop. App must retry/reconnect. Failover feels like
#   30–120 seconds of errors.
# With proxy: proxy buffers/queues connections during the failover window.
#   It reconnects to the new primary transparently. Applications see only
#   a brief pause. Failover time typically reduced to under 30 seconds.
#   SAA-C03: "Reduce RDS failover impact on application" = RDS Proxy.
#
# ENDPOINTS
# ----------
# Default endpoint:  read/write → always routes to the primary DB instance.
# Read-only endpoint: routes to read replicas (Aurora) or a specified
#   read-only target group. Use this for read-heavy analytics queries to
#   offload the primary.
# Custom endpoints: you can create additional named endpoints with custom
#   target groups for specific routing logic.
#
# VPC-ONLY (IMPORTANT SAA-C03 DISTRACTOR)
# -----------------------------------------
# RDS Proxy is NOT publicly accessible. It only has a private IP inside
# your VPC. This is a security feature — database proxies must never be
# reachable from the internet. If your application is outside the VPC,
# use VPN, Direct Connect, or PrivateLink — never expose the proxy publicly.
#
# SUPPORTED ENGINES (SAA-C03 must-know list)
# -------------------------------------------
#   MySQL 5.6, 5.7, 8.0
#   PostgreSQL 10.x, 11.x, 12.x, 13.x, 14.x, 15.x
#   MariaDB 10.x
#   SQL Server 2019
#   Aurora MySQL-compatible
#   Aurora PostgreSQL-compatible
#   NOT supported: Oracle, DB2, or any engine not listed above.
#
# COST
# -----
# Billed per vCPU-hour of the underlying DB instance(s) the proxy fronts.
# Typically 1.5× the cost of the DB itself — justified by connection savings
# and reduced need to over-provision DB instance size just for connections.
#
###############################################################################

# === DATA SOURCES ============================================================

# Use the default VPC for simplicity in this lab.
# In production, RDS Proxy must be in a VPC — it is never publicly accessible.
data "aws_vpc" "default" {
  default = true
}

# Retrieve caller identity — used to build ARNs for IAM policy conditions.
# Ensures the Secrets Manager resource policy is scoped to this account only.
data "aws_caller_identity" "current" {}

# Retrieve current region — used in Secrets Manager ARN patterns in IAM policy.
data "aws_region" "current" {}

# Fetch the default VPC's subnets so we can pick two for the DB subnet group.
# RDS Proxy requires at least two subnets in different AZs (for Multi-AZ support).
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# === NETWORKING ==============================================================

# Security group for the RDS Proxy itself.
# The proxy accepts connections from application clients (Lambda, ECS, EC2, etc.)
# on the standard DB engine port, then connects outbound to the DB instances.
#
# SAA-C03: Security groups are stateful. Allowing inbound on port 3306/5432
# automatically allows the return traffic. No explicit outbound rule needed
# for the response, but we add an explicit egress for the DB connection.
resource "aws_security_group" "proxy" {
  name        = "${var.project_name}-proxy-sg"
  description = "Security group for RDS Proxy - allows inbound from app tier, outbound to DB tier"
  vpc_id      = data.aws_vpc.default.id

  # Allow application layer (Lambda, ECS, EC2) to connect to MySQL proxy.
  # Port 3306 is the MySQL/MariaDB default port.
  ingress {
    description = "MySQL from app tier"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Allow application layer to connect to PostgreSQL proxy.
  # Port 5432 is the PostgreSQL default port.
  ingress {
    description = "PostgreSQL from app tier"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Allow proxy to establish connections to backend DB instances.
  # Without this egress rule the proxy cannot reach RDS — all client
  # connections would fail at the multiplexing step.
  egress {
    description = "Allow all outbound - proxy needs to reach RDS instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-proxy-sg"
    Lab     = "45"
    Purpose = "RDS Proxy security group"
  }
}

# Security group for the RDS DB instances behind the proxy.
# Only the proxy security group can connect to the DB — no direct app access.
# This enforces the proxy as the single entry point (defence in depth).
resource "aws_security_group" "db" {
  name        = "${var.project_name}-db-sg"
  description = "Security group for RDS instances - only accepts connections from RDS Proxy"
  vpc_id      = data.aws_vpc.default.id

  # Only allow inbound from the proxy SG — not from CIDR blocks.
  # Referencing a security group (not a CIDR) is more dynamic: if the proxy
  # scales or its IP changes, this rule still applies automatically.
  ingress {
    description     = "MySQL from proxy only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
  }

  ingress {
    description     = "PostgreSQL from proxy only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-db-sg"
    Lab     = "45"
    Purpose = "RDS instance security group - locked to proxy SG only"
  }
}

# === DB SUBNET GROUP =========================================================

# RDS and RDS Proxy require a DB subnet group — a named collection of subnets
# that define WHERE in the VPC the DB instances (and proxy ENIs) can be placed.
#
# Must span at least 2 AZs for Multi-AZ deployments.
# RDS Proxy creates Elastic Network Interfaces (ENIs) in these subnets —
# one per AZ that has a participating subnet.
#
# SAA-C03: "RDS in multiple AZs" always requires a multi-AZ subnet group.
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-subnet-group"
  description = "Subnet group for RDS instances and RDS Proxy ENIs - spans multiple AZs"

  # slice() selects the first two subnets from the default VPC.
  # In a real environment these would be private subnets with no internet gateway route.
  subnet_ids = slice(tolist(data.aws_subnets.default.ids), 0, 2)

  tags = {
    Name = "${var.project_name}-subnet-group"
    Lab  = "45"
  }
}

# === SECRETS MANAGER - DB CREDENTIALS ========================================
#
# RDS Proxy requires DB credentials to be stored in AWS Secrets Manager.
# The proxy reads the secret at connection time — your application NEVER sees
# the raw DB password. This is the mechanism that enables IAM authentication:
#
#   App → (IAM token) → RDS Proxy → (reads Secrets Manager) → DB with password
#
# Secret rotation:
#   Secrets Manager can auto-rotate credentials on a schedule (e.g., every 30 days).
#   The proxy seamlessly picks up the new secret — zero application changes needed.
#   SAA-C03: "Automate DB credential rotation without downtime" = Secrets Manager + RDS Proxy.
#
# Secret format for RDS Proxy:
#   Must be a JSON blob with at minimum: {"username": "...", "password": "..."}
#   Optionally includes: engine, host, port, dbname

# --- MySQL credentials secret ---
resource "aws_secretsmanager_secret" "mysql_db" {
  name        = "${var.project_name}/mysql-db-credentials"
  description = "MySQL RDS credentials consumed by RDS Proxy - app never sees this password"

  # Recovery window: 7 days means the secret enters a pending-deletion state
  # for 7 days before permanent deletion. Set to 0 in dev to allow immediate
  # re-creation (avoids name collision errors during destroy/apply cycles).
  recovery_window_in_days = 7

  tags = {
    Name    = "${var.project_name}-mysql-secret"
    Lab     = "45"
    Purpose = "RDS Proxy MySQL auth credential"
  }
}

resource "aws_secretsmanager_secret_version" "mysql_db" {
  secret_id = aws_secretsmanager_secret.mysql_db.id

  # JSON format required by RDS Proxy.
  # In production, use Secrets Manager rotation Lambda to keep this current.
  # NEVER hard-code real credentials — use a secrets management pipeline.
  secret_string = jsonencode({
    username = "admin"
    password = "ChangeMe123!" # placeholder - rotate immediately in real use
    engine   = "mysql"
    port     = 3306
  })
}

# --- PostgreSQL credentials secret ---
resource "aws_secretsmanager_secret" "postgres_db" {
  name                    = "${var.project_name}/postgres-db-credentials"
  description             = "PostgreSQL RDS credentials consumed by RDS Proxy"
  recovery_window_in_days = 7

  tags = {
    Name    = "${var.project_name}-postgres-secret"
    Lab     = "45"
    Purpose = "RDS Proxy PostgreSQL auth credential"
  }
}

resource "aws_secretsmanager_secret_version" "postgres_db" {
  secret_id = aws_secretsmanager_secret.postgres_db.id

  secret_string = jsonencode({
    username = "postgres"
    password = "ChangeMe456!"
    engine   = "postgres"
    port     = 5432
  })
}

# === IAM ROLE FOR RDS PROXY ==================================================
#
# RDS Proxy needs an IAM role to call Secrets Manager on your behalf.
# The trust policy allows the rds.amazonaws.com service to assume the role.
# The permission policy grants GetSecretValue on the specific secrets created above.
#
# WHY AN IAM ROLE (not a user or access key):
#   IAM roles use temporary credentials (STS tokens) — no long-lived keys to rotate.
#   RDS Proxy assumes this role automatically; you never manage the credentials.
#
# SAA-C03: Services that need to "call other AWS services" always use IAM roles,
#   never IAM users with access keys. This pattern appears across many services:
#   Lambda → S3, ECS Task → DynamoDB, RDS Proxy → Secrets Manager.

resource "aws_iam_role" "rds_proxy" {
  name        = "${var.project_name}-proxy-role"
  description = "IAM role assumed by RDS Proxy to read DB credentials from Secrets Manager"

  # Trust policy: only the RDS service can assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSProxyAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-proxy-role"
    Lab  = "45"
  }
}

# Permission policy attached to the proxy IAM role.
# Scoped to only the two secrets used by this lab — principle of least privilege.
# SAA-C03: Always scope IAM policies to specific resources, not "*".
resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "${var.project_name}-proxy-secrets-policy"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecretsForProxy"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.mysql_db.arn,
          aws_secretsmanager_secret.postgres_db.arn
        ]
      },
      {
        # KMS decrypt permission needed if the secrets are encrypted with a
        # customer-managed KMS key (CMK). If using the default AWS-managed key,
        # this is not strictly required but is included for completeness.
        Sid    = "DecryptSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        # In production, replace with the specific CMK ARN.
        Resource = "arn:aws:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# === RDS DB INSTANCES (PROXY TARGETS) ========================================
#
# RDS Proxy sits in front of one or more RDS DB instances or Aurora clusters.
# For this lab we create one MySQL and one PostgreSQL RDS instance as proxy targets.
#
# db.t3.micro is free-tier eligible — smallest instance, only ~80 max connections.
# This perfectly illustrates WHY RDS Proxy is needed: the proxy multiplexes
# potentially hundreds of app connections onto those ~80 DB connections.

# --- MySQL RDS instance ---
resource "aws_db_instance" "mysql" {
  identifier     = "${var.project_name}-mysql"
  engine         = "mysql"
  engine_version = "8.0"

  # db.t3.micro: 1 vCPU, 1 GB RAM → ~80 max_connections.
  # With RDS Proxy: hundreds of Lambda invocations can share those 80 connections.
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp2"

  # These credentials must match what is stored in Secrets Manager above.
  # The proxy uses the secret; the DB still needs them set at creation time.
  db_name  = "appdb"
  username = "admin"
  password = "ChangeMe123!"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  # IAM database authentication — allows connections using IAM tokens instead
  # of passwords. RDS Proxy uses this when iam_auth = "REQUIRED" on the proxy.
  # SAA-C03: IAM DB auth tokens are valid for 15 minutes, scoped to the IAM user/role.
  iam_database_authentication_enabled = true

  # skip_final_snapshot = true: do not create a final backup snapshot on deletion.
  # For lab/dev use only — in production always set to false and specify
  # final_snapshot_identifier to ensure you have a recovery point before deletion.
  skip_final_snapshot = true

  # multi_az = false for cost in this lab.
  # In production: multi_az = true for automatic failover. RDS Proxy works with
  # Multi-AZ — it holds connections during the ~20-30s failover window.
  multi_az = false

  tags = {
    Name    = "${var.project_name}-mysql"
    Lab     = "45"
    Engine  = "MySQL 8.0"
    Purpose = "RDS Proxy MySQL target"
  }
}

# --- PostgreSQL RDS instance ---
resource "aws_db_instance" "postgres" {
  identifier        = "${var.project_name}-postgres"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "appdb"
  username = "postgres"
  password = "ChangeMe456!"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  iam_database_authentication_enabled = true

  skip_final_snapshot = true
  multi_az            = false

  tags = {
    Name    = "${var.project_name}-postgres"
    Lab     = "45"
    Engine  = "PostgreSQL 15.4"
    Purpose = "RDS Proxy PostgreSQL target"
  }
}

# === RDS PROXY — MYSQL =======================================================
#
# The aws_db_proxy resource creates the proxy itself.
#
# KEY SETTINGS:
#
# engine_family: "MYSQL" or "POSTGRESQL" — determines the wire protocol the
#   proxy speaks. A MySQL proxy CANNOT front a PostgreSQL DB and vice versa.
#
# idle_client_timeout: how long (seconds) an idle client connection is kept
#   before the proxy closes it. Frees up proxy capacity for new connections.
#   Default: 1800 (30 min). Tune downward for Lambda workloads (e.g., 300s).
#
# require_tls: forces all connections to the proxy to use SSL/TLS.
#   SAA-C03: "Encrypt data in transit to DB" = enable require_tls on proxy.
#
# iam_auth: "REQUIRED" means clients MUST authenticate using IAM tokens.
#   "DISABLED" means clients use regular DB username/password.
#   "ALLOWED" means either method works.
#   SAA-C03: "Enforce IAM authentication to database" = iam_auth = "REQUIRED".
#
# vpc_subnet_ids: subnets where the proxy places its Elastic Network Interfaces.
#   The proxy endpoint IP comes from these subnets. Must be private subnets.
#
# vpc_security_group_ids: controls what can connect TO the proxy.
#
# auth block: specifies which Secrets Manager secret holds the DB credentials
#   the proxy will use to connect to the backend DB instances.

resource "aws_db_proxy" "mysql" {
  name                   = "${var.project_name}-mysql-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = slice(tolist(data.aws_subnets.default.ids), 0, 2)
  vpc_security_group_ids = [aws_security_group.proxy.id]

  # idle_client_timeout: 1800 seconds (30 minutes).
  # After 30 min of no queries, the proxy drops the client connection and
  # returns the backend DB connection to the pool.
  idle_client_timeout = 1800

  # require_tls: enforce TLS for all connections to the proxy endpoint.
  # The proxy terminates TLS and may reconnect to the DB with or without TLS
  # depending on the DB SSL configuration.
  require_tls = true

  # debug_logging: enable verbose proxy logs to CloudWatch Logs.
  # Useful for diagnosing pinning events (session-state issues).
  # In production, disable after debugging to avoid log costs.
  debug_logging = false

  # auth block: credential set the proxy uses to authenticate to the DB.
  # Multiple auth blocks can be added for different DB users.
  auth {
    auth_scheme = "SECRETS" # proxy reads credentials from Secrets Manager
    secret_arn  = aws_secretsmanager_secret.mysql_db.arn
    iam_auth    = "REQUIRED" # clients connecting TO the proxy must use IAM tokens
    description = "MySQL admin user credentials for proxy authentication"
  }

  tags = {
    Name         = "${var.project_name}-mysql-proxy"
    Lab          = "45"
    EngineFamily = "MYSQL"
    Purpose      = "Connection pooling proxy for MySQL RDS instance"
  }
}

# === RDS PROXY DEFAULT TARGET GROUP — MYSQL ==================================
#
# A target group defines WHICH DB instances the proxy routes connections to.
# Every proxy has a default target group created automatically; this resource
# lets you configure its settings.
#
# connection_pool_config:
#
#   max_connections_percent: the percentage of max_connections on the DB that
#     the proxy can use. 100 = proxy can use ALL available connections.
#     Set lower (e.g., 80) to reserve headroom for direct admin connections.
#
#   max_idle_connections_percent: percentage of max_connections to hold idle
#     in the pool even when not in use. Higher = faster response for bursty
#     workloads. Lower = less DB resource consumption during quiet periods.
#
#   connection_borrow_timeout: seconds a client waits for a connection from
#     the pool before the proxy returns an error. Default: 120 seconds.
#     For Lambda: keep short (e.g., 30s) so failures surface quickly.
#
#   session_pinning_filters: list of conditions that PREVENT pinning.
#     "EXCLUDE_VARIABLE_SETS" tells the proxy: even if the client sends a
#     SET statement, don't pin — safe for many frameworks that issue harmless
#     SET statements at connection start (e.g., SET NAMES utf8).
#
# SAA-C03: The target group is what connects the proxy to the actual DB.
# Without registering a target, the proxy has nowhere to send connections.

resource "aws_db_proxy_default_target_group" "mysql" {
  db_proxy_name = aws_db_proxy.mysql.name

  connection_pool_config {
    # Allow the proxy to use up to 100% of the DB's max_connections.
    max_connections_percent = 100

    # Keep 50% of max_connections warm and idle in the pool.
    # Reduces connection setup latency for Lambda cold starts.
    max_idle_connections_percent = 50

    # Wait up to 120 seconds for a DB connection before erroring.
    connection_borrow_timeout = 120

    # Exclude SET statements from causing pinning.
    # Many ORMs (Django, Rails, SQLAlchemy) issue SET statements at session
    # start — without this filter those sessions would all be pinned,
    # defeating the multiplexing benefit.
    session_pinning_filters = ["EXCLUDE_VARIABLE_SETS"]
  }
}

# === RDS PROXY TARGET — MYSQL ================================================
#
# The proxy target registers the actual RDS instance (or Aurora cluster) as
# the backend that receives proxied connections.
#
# db_instance_identifier: for single RDS instances (what we have here).
# db_cluster_identifier:  for Aurora clusters (use this instead for Aurora).
#
# SAA-C03: For Aurora, point the proxy at the CLUSTER, not individual instances.
# The cluster endpoint automatically handles failover — the proxy + cluster
# combo gives you the fastest possible failover recovery.

resource "aws_db_proxy_target" "mysql" {
  db_proxy_name          = aws_db_proxy.mysql.name
  target_group_name      = aws_db_proxy_default_target_group.mysql.name
  db_instance_identifier = aws_db_instance.mysql.identifier
}

# === RDS PROXY — POSTGRESQL ==================================================

resource "aws_db_proxy" "postgres" {
  name                   = "${var.project_name}-postgres-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = slice(tolist(data.aws_subnets.default.ids), 0, 2)
  vpc_security_group_ids = [aws_security_group.proxy.id]

  idle_client_timeout = 1800
  require_tls         = true
  debug_logging       = false

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.postgres_db.arn
    iam_auth    = "REQUIRED"
    description = "PostgreSQL admin credentials for proxy authentication"
  }

  tags = {
    Name         = "${var.project_name}-postgres-proxy"
    Lab          = "45"
    EngineFamily = "POSTGRESQL"
    Purpose      = "Connection pooling proxy for PostgreSQL RDS instance"
  }
}

resource "aws_db_proxy_default_target_group" "postgres" {
  db_proxy_name = aws_db_proxy.postgres.name

  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120

    # PostgreSQL note: pgBouncer (alternative pooler) is sometimes compared
    # to RDS Proxy. Key differences:
    #   RDS Proxy: AWS-managed, IAM auth, Secrets Manager integration, HA built-in.
    #   pgBouncer: self-managed on EC2, more configuration options, no IAM.
    # SAA-C03: "Managed" solution = RDS Proxy; "custom control" = pgBouncer on EC2.
    session_pinning_filters = ["EXCLUDE_VARIABLE_SETS"]
  }
}

resource "aws_db_proxy_target" "postgres" {
  db_proxy_name          = aws_db_proxy.postgres.name
  target_group_name      = aws_db_proxy_default_target_group.postgres.name
  db_instance_identifier = aws_db_instance.postgres.identifier
}

# === RDS PROXY ENDPOINT — READ-ONLY ==========================================
#
# Custom proxy endpoints allow you to create additional named endpoints with
# different routing behaviour. The most common use case is a READ-ONLY endpoint.
#
# target_role = "READ_ONLY":
#   Connections to this endpoint are routed to read replicas.
#   For RDS (not Aurora): requires at least one read replica to be created.
#   For Aurora: routes to Aurora Read Replicas automatically.
#   Use this endpoint for reporting queries, analytics, or any read-heavy
#   workload to offload the primary write instance.
#
# target_role = "READ_WRITE" (default):
#   Routes to the primary DB instance. This is the default proxy endpoint.
#
# SAA-C03 pattern:
#   Write path: app → mysql_proxy default endpoint (READ_WRITE) → primary DB
#   Read path:  app → mysql_proxy read-only endpoint (READ_ONLY) → read replica
#   This pattern scales reads horizontally without application-level logic.
#
# NOTE: For this lab the MySQL instance has no read replica, so the read-only
# endpoint will have no targets. In production, create aws_db_instance with
# replicate_source_db pointing to the primary first, then register both.

resource "aws_db_proxy_endpoint" "mysql_readonly" {
  db_proxy_name          = aws_db_proxy.mysql.name
  db_proxy_endpoint_name = "${var.project_name}-mysql-readonly"

  # Must be in the same or overlapping subnets as the proxy.
  vpc_subnet_ids = slice(tolist(data.aws_subnets.default.ids), 0, 2)

  # READ_ONLY endpoint: direct all traffic on this endpoint to read replicas.
  # Applications use separate connection strings for reads vs writes.
  target_role = "READ_ONLY"

  tags = {
    Name    = "${var.project_name}-mysql-readonly-endpoint"
    Lab     = "45"
    Purpose = "Read-only proxy endpoint for offloading read replicas"
  }
}
