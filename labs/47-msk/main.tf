# =============================================================================
# LAB 47: MSK (Managed Streaming for Apache Kafka) + Kinesis Data Analytics
# AWS SAA-C03 Study Lab
# =============================================================================
#
# WHAT THIS LAB COVERS:
#   - Apache Kafka fundamentals: topics, partitions, producers, consumers
#   - MSK provisioned cluster with multi-AZ brokers
#   - MSK authentication options: TLS, SASL/SCRAM, IAM
#   - MSK encryption: in-transit (TLS) and at-rest (KMS)
#   - MSK Serverless (no broker management, auto-scales)
#   - MSK Connect concept (commented)
#   - Kinesis Data Analytics v2 with Apache Flink runtime
#   - Real-time stream processing architecture
#
# =============================================================================
# APACHE KAFKA CORE CONCEPTS (SAA-C03 background knowledge)
# =============================================================================
#
# Kafka is a distributed, fault-tolerant event streaming platform.
# Key concepts you must know for the exam:
#
#   TOPIC
#     A named feed/category to which records are published.
#     Think of it like an S3 bucket for event streams.
#     Example topics: "orders", "user-clicks", "sensor-readings"
#
#   PARTITION
#     A topic is split into N partitions, each an ordered, immutable log.
#     Partitions enable parallelism — more partitions = more throughput.
#     Records within a partition are ordered by offset; across partitions, no order.
#     Replication factor: each partition is copied to multiple brokers for fault tolerance.
#
#   PRODUCER
#     An application that publishes (writes) records to a topic.
#     Producers choose which partition to write to (round-robin or by key).
#     Key-based routing ensures all records with the same key go to the same partition
#     (useful for ordered processing per entity, e.g., all events for user-123).
#
#   CONSUMER
#     An application that subscribes to a topic and reads records.
#     Consumers track their position using an OFFSET (integer index per partition).
#     Consumers can replay events by resetting their offset.
#
#   CONSUMER GROUP
#     A set of consumers that jointly consume a topic.
#     Each partition is assigned to exactly ONE consumer in the group.
#     Enables horizontal scaling: add more consumers to process faster.
#     Multiple independent groups can each consume the full topic independently.
#
#   BROKER
#     A Kafka server node. Stores partitions and serves producers/consumers.
#     MSK manages broker EC2 instances for you.
#
#   ZOOKEEPER / KRAFT
#     Old: Kafka used ZooKeeper for cluster metadata (port 2181).
#     New: Kafka 3.x uses KRaft (Kafka Raft) — no ZooKeeper dependency.
#     MSK still exposes ZooKeeper endpoints for legacy compatibility.
#
# =============================================================================
# MSK vs KINESIS DATA STREAMS (SAA-C03 decision guide)
# =============================================================================
#
#   MSK (Managed Kafka):
#     + Open-source Kafka — any language/framework that speaks Kafka protocol
#     + Large messages: up to 1 MB default (configurable higher)
#     + Consumer groups with independent offset tracking per group
#     + Replay data any time within retention period
#     + Rich ecosystem: Kafka Connect, Kafka Streams, ksqlDB
#     + More operational control (broker count, instance type, storage)
#     - More complex to set up and manage than Kinesis
#     - Must provision broker capacity upfront (unless using Serverless)
#
#   Kinesis Data Streams:
#     + AWS-native, simpler API (PutRecord, GetRecords)
#     + Tight integration: Firehose, Lambda, KDA, Glue
#     + Serverless capacity via On-Demand mode
#     + Shard-based scaling (easy to reason about throughput)
#     - 1 MB record size limit (hard limit)
#     - Kinesis-specific SDK (not portable to non-AWS)
#     - No consumer groups concept (use enhanced fan-out instead)
#
#   SAA-C03 RULE:
#     "Need Apache Kafka / open-source compatibility"  → MSK
#     "Need Firehose / Lambda / tight AWS integration" → Kinesis
#     "Lift-and-shift existing Kafka workload to AWS"  → MSK
#     "Simplest managed streaming, AWS-only"           → Kinesis
#
# =============================================================================

# Pull current account/region for ARN construction and tagging
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# NETWORKING: VPC + 3 PRIVATE SUBNETS (one per AZ)
# =============================================================================
# MSK best practice: deploy brokers in PRIVATE subnets, one broker per AZ.
# Rule: number of broker nodes MUST be a multiple of the number of AZs.
# Example: 3 AZs → 3, 6, or 9 brokers. 2 AZs → 2, 4, or 6 brokers.
# MSK distributes brokers evenly across the subnets you specify.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true # Required for MSK broker DNS resolution
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Lab     = "47-msk"
    Purpose = "MSK cluster networking"
  }
}

# Three private subnets, one per Availability Zone.
# MSK will place one broker node in each subnet.
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${var.project_name}-private-a"
    Tier = "private"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${var.project_name}-private-b"
    Tier = "private"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}c"

  tags = {
    Name = "${var.project_name}-private-c"
    Tier = "private"
  }
}

# =============================================================================
# SECURITY GROUP: MSK Broker ports
# =============================================================================
# Kafka uses several ports depending on authentication method:
#
#   2181  - ZooKeeper (legacy, used by older Kafka clients)
#   9092  - Plaintext (no encryption, no auth) — NOT for production
#   9094  - TLS (encryption + optional mutual TLS client auth)
#   9096  - SASL/SCRAM (username/password over TLS)
#   9098  - SASL/IAM (AWS IAM-based authentication)
#
# SAA-C03 tip: You don't need to memorize all ports, but know that
# different auth methods use different ports. The exam may describe
# a port and ask you to identify the auth mechanism.

resource "aws_security_group" "msk_brokers" {
  name        = "${var.project_name}-msk-sg"
  description = "Security group for MSK broker nodes"
  vpc_id      = aws_vpc.main.id

  # ZooKeeper port — needed by some legacy Kafka clients and tools
  ingress {
    description = "ZooKeeper"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    self        = true # Only allow traffic from within this SG (broker-to-broker + clients in same SG)
  }

  # Plaintext broker port — disabled in production, shown here for completeness
  # In a real cluster you would NOT open this; use TLS or IAM instead
  ingress {
    description = "Kafka plaintext (dev only)"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    self        = true
  }

  # TLS broker port — clients using mutual TLS certificates connect here
  ingress {
    description = "Kafka TLS"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    self        = true
  }

  # SASL/SCRAM port — clients using username/password (Secrets Manager) connect here
  ingress {
    description = "Kafka SASL/SCRAM"
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    self        = true
  }

  # IAM/SASL port — clients using AWS IAM authentication connect here
  ingress {
    description = "Kafka SASL/IAM"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-msk-sg"
  }
}

# =============================================================================
# KMS KEY: Encryption at rest for MSK
# =============================================================================
# MSK encrypts broker EBS volumes at rest using AES-256.
# By default it uses an AWS-managed key; for compliance you supply your own CMK.
# SAA-C03: "customer-managed KMS key" = CMK = you control rotation and policy.

resource "aws_kms_key" "msk" {
  description             = "CMK for MSK broker EBS encryption at rest"
  deletion_window_in_days = 7 # Minimum 7 days; production should be 30

  # Automatic annual rotation — AWS creates a new key version each year.
  # Old versions are kept for decrypting existing data.
  enable_key_rotation = true

  tags = {
    Name = "${var.project_name}-msk-kms"
  }
}

resource "aws_kms_alias" "msk" {
  name          = "alias/${var.project_name}-msk"
  target_key_id = aws_kms_key.msk.key_id
}

# =============================================================================
# CLOUDWATCH LOG GROUP: MSK Broker logs
# =============================================================================
# MSK can ship broker logs to CloudWatch, S3, or Kinesis Firehose.
# Useful for debugging consumer lag, authentication failures, rebalancing events.

resource "aws_cloudwatch_log_group" "msk_broker_logs" {
  name              = "/aws/msk/${var.project_name}/broker"
  retention_in_days = 7 # Keep logs for 7 days (reduce cost in lab)

  tags = {
    Name = "${var.project_name}-msk-broker-logs"
  }
}

# =============================================================================
# MSK CONFIGURATION: Custom Kafka broker settings
# =============================================================================
# MSK allows you to specify a subset of Kafka broker configuration properties.
# You can change: default.replication.factor, num.partitions, log.retention.hours, etc.
# Some settings are locked by MSK (e.g., zookeeper.connect is managed by AWS).

resource "aws_msk_configuration" "main" {
  name           = "${var.project_name}-config"
  kafka_versions = ["3.5.1"] # Must match the Kafka version used by the cluster

  # Multi-line Kafka properties (standard Java .properties format)
  server_properties = <<-EOT
    # Default number of partitions for auto-created topics
    # More partitions = higher throughput but more overhead
    num.partitions=3

    # How many replicas each partition has across brokers
    # 3-broker cluster: replication factor of 3 = full redundancy
    # SAA-C03: min.insync.replicas + replication.factor determine durability
    default.replication.factor=3

    # Minimum replicas that must acknowledge a write before it's considered committed
    # With 3 replicas and min.insync=2, one broker can fail without data loss
    min.insync.replicas=2

    # How long Kafka retains log segments (hours)
    # After this window, old segments are eligible for deletion
    log.retention.hours=168

    # Maximum message size (bytes). Default is 1 MB.
    # MSK supports larger values than Kinesis (Kinesis is hard-capped at 1 MB)
    message.max.bytes=1048576

    # Automatically create topics when a producer writes to a non-existent topic
    # Set to false in production to prevent accidental topic creation
    auto.create.topics.enable=false

    # Compression type for log segments stored on disk
    # Possible values: uncompressed, gzip, snappy, lz4, zstd, producer
    # "producer" means MSK honours whatever compression the producer used
    compression.type=producer
  EOT

  description = "Custom MSK broker configuration for ${var.project_name}"
}

# =============================================================================
# SASL/SCRAM AUTHENTICATION: Secrets Manager
# =============================================================================
# SASL/SCRAM lets Kafka clients authenticate with a username and password.
# MSK integrates with AWS Secrets Manager to store and rotate these credentials.
#
# How it works:
#   1. Create a secret in Secrets Manager with a JSON payload: {"username":"...","password":"..."}
#   2. Associate the secret with the MSK cluster using aws_msk_scram_secret_association
#   3. Clients use the username/password at Kafka connect time (port 9096)
#
# SAA-C03 tip: SASL/SCRAM is good for apps that cannot use IAM (e.g., on-prem producers).
# IAM auth is preferred for AWS-native workloads (no credential management needed).

resource "aws_secretsmanager_secret" "msk_scram" {
  name        = "${var.project_name}/msk-scram-credentials"
  description = "SASL/SCRAM credentials for MSK cluster authentication"

  # The secret name MUST start with "AmazonMSK_" for MSK SCRAM association to work.
  # Terraform doesn't enforce this naming but MSK API will reject the association otherwise.
  # We use a name_prefix pattern; rename to AmazonMSK_... in production.

  kms_key_id = aws_kms_key.msk.arn # Encrypt the secret itself with our CMK

  tags = {
    Name = "${var.project_name}-msk-scram-secret"
  }
}

# The actual secret value (username/password).
# In production, inject these from a secure pipeline — never hardcode.
resource "aws_secretsmanager_secret_version" "msk_scram" {
  secret_id = aws_secretsmanager_secret.msk_scram.id

  # MSK SCRAM secrets MUST use this exact JSON structure.
  secret_string = jsonencode({
    username = "msk-admin"
    password = "ChangeMe-NotForProduction-123!"
  })
}

# =============================================================================
# MSK PROVISIONED CLUSTER
# =============================================================================
# The main MSK resource. Key configuration blocks:
#   broker_node_group_info — instance type, storage, networking, AZ placement
#   encryption_info        — KMS key at rest, TLS policy in transit
#   client_authentication  — which auth methods are allowed
#   configuration_info     — link to our custom MSK configuration
#   open_monitoring        — Prometheus JMX exporter settings
#   broker_logs            — where to ship broker logs
#
# SAA-C03 CLUSTER SIZING RULES:
#   - number_of_broker_nodes MUST be a multiple of the number of AZs
#   - We have 3 subnets (3 AZs), so 3 brokers is valid
#   - kafka.m5.large is the minimum recommended instance for production
#   - kafka.t3.small is available for dev/test (not HA)

resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project_name}-cluster"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 3 # One broker per AZ (3 AZs = 3 brokers minimum)

  # --- Broker node group configuration ---
  broker_node_group_info {
    # Instance type for each broker node.
    # kafka.m5.large: 2 vCPU, 8 GB RAM — suitable for moderate throughput
    # kafka.m5.4xlarge: 16 vCPU, 64 GB RAM — for high-throughput production
    instance_type = "kafka.m5.large"

    # One subnet per AZ — MSK places one broker in each subnet
    client_subnets = [
      aws_subnet.private_a.id,
      aws_subnet.private_b.id,
      aws_subnet.private_c.id
    ]

    security_groups = [aws_security_group.msk_brokers.id]

    # EBS storage per broker node.
    # Each broker independently stores the partitions assigned to it.
    # Total cluster storage = volume_size * number_of_broker_nodes
    # Example: 100 GB * 3 brokers = 300 GB total (but replicated, so effective = 100 GB usable with RF=3)
    storage_info {
      ebs_storage_info {
        volume_size = 100 # GB per broker

        # Provisioned IOPS for EBS (optional — enables io1/io2 volumes)
        # Uncomment for high-throughput workloads:
        # provisioned_throughput {
        #   enabled           = true
        #   volume_throughput = 250 # MiB/s per broker
        # }
      }
    }
  }

  # --- Encryption configuration ---
  encryption_info {
    # At-rest encryption: use our CMK to encrypt all broker EBS volumes
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn

    # In-transit encryption: controls TLS between clients↔brokers and broker↔broker
    encryption_in_transit {
      # client_broker: encryption policy for client-to-broker traffic
      #   "TLS"           = enforce TLS; reject plaintext connections
      #   "TLS_PLAINTEXT" = allow both TLS and plaintext
      #   "PLAINTEXT"     = plaintext only (dev only, never production)
      client_broker = "TLS"

      # in_cluster: whether broker-to-broker replication traffic is TLS-encrypted
      # Always true in production for compliance
      in_cluster = true
    }
  }

  # --- Client authentication ---
  # MSK supports multiple auth methods simultaneously.
  # Enable only what your clients need to reduce attack surface.
  client_authentication {
    # SASL authentication methods
    sasl {
      # IAM: AWS IAM roles/policies control Kafka access.
      # No passwords or certificates needed. Best for AWS-native clients.
      # SAA-C03: IAM auth = "no credential management" solution.
      iam = true

      # SCRAM: username/password stored in Secrets Manager.
      # Good for on-prem clients or apps that can't use IAM.
      scram = true
    }

    # TLS mutual authentication: clients present X.509 certificates.
    # Requires ACM Private Certificate Authority (PCA) — optional, advanced.
    # Uncomment if you need certificate-based client auth:
    # tls {
    #   certificate_authority_arns = [aws_acmpca_certificate_authority.main.arn]
    # }

    # unauthenticated: allow connections with no credentials.
    # NEVER enable in production. Shown here for completeness.
    unauthenticated = false
  }

  # --- Custom broker configuration ---
  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  # --- Open Monitoring: Prometheus metrics export ---
  # MSK can expose JMX and Node metrics for scraping by Prometheus/Grafana.
  # SAA-C03: CloudWatch is the default monitoring path; Prometheus/Grafana is
  # used for custom dashboards and cross-cluster monitoring.
  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true # Expose Kafka JMX metrics (consumer lag, etc.)
      }
      node_exporter {
        enabled_in_broker = true # Expose OS-level metrics (CPU, disk, network)
      }
    }
  }

  # --- Broker log delivery ---
  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_broker_logs.name
      }

      # Ship logs to S3 for long-term storage / audit
      # Uncomment if you have an S3 bucket:
      # s3_logs {
      #   enabled = true
      #   bucket  = aws_s3_bucket.msk_logs.id
      #   prefix  = "msk-broker-logs/"
      # }

      # Ship logs to Kinesis Firehose for real-time analysis
      # Uncomment if you have a Firehose delivery stream:
      # firehose {
      #   enabled         = true
      #   delivery_stream = aws_kinesis_firehose_delivery_stream.msk_logs.name
      # }
    }
  }

  tags = {
    Name        = "${var.project_name}-cluster"
    Environment = "lab"
    Lab         = "47-msk"
  }

  # MSK cluster creation takes 15-20 minutes — don't be alarmed
  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# =============================================================================
# MSK SCRAM SECRET ASSOCIATION
# =============================================================================
# Links the Secrets Manager secret to the MSK cluster.
# After this association, clients can authenticate with the username/password
# stored in the secret using SASL/SCRAM on port 9096.
#
# IMPORTANT: The secret name in Secrets Manager MUST start with "AmazonMSK_"
# for the association API to accept it. This Terraform resource handles
# the API call but does NOT rename the secret — ensure your secret name
# complies before running `terraform apply`.

resource "aws_msk_scram_secret_association" "main" {
  cluster_arn     = aws_msk_cluster.main.arn
  secret_arn_list = [aws_secretsmanager_secret.msk_scram.arn]

  depends_on = [aws_secretsmanager_secret_version.msk_scram]
}

# =============================================================================
# MSK SERVERLESS CLUSTER
# =============================================================================
# MSK Serverless: no brokers to provision or manage.
# AWS automatically scales compute and storage based on throughput.
#
# KEY DIFFERENCES from provisioned MSK:
#   - Capacity: auto-scales (no broker instance types or counts)
#   - Authentication: IAM ONLY (no TLS mutual-auth, no SASL/SCRAM)
#   - Throughput limits: up to 200 MB/s per topic (soft limit)
#   - Pricing: per-partition-hour + per-GB written/read (vs per-broker-hour)
#   - Use case: unpredictable workloads, event-driven apps, dev/test
#
# SAA-C03 EXAM TIP:
#   "Need Kafka without managing broker capacity" → MSK Serverless
#   "Need SASL/SCRAM or TLS client auth" → MSK Provisioned (Serverless = IAM only)
#   "Unpredictable Kafka workload" → MSK Serverless
#   "Cost-optimize Kafka at variable scale" → MSK Serverless

resource "aws_msk_serverless_cluster" "main" {
  cluster_name = "${var.project_name}-serverless"

  # MSK Serverless requires VPC configuration even though you don't manage brokers.
  # The serverless endpoint is placed in your VPC subnets.
  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id, aws_subnet.private_c.id]
    security_group_ids = [aws_security_group.msk_brokers.id]
  }

  # MSK Serverless ONLY supports IAM authentication
  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = {
    Name = "${var.project_name}-serverless"
    Lab  = "47-msk"
  }
}

# =============================================================================
# MSK CONNECT (CONCEPT — AWS does not provide a Terraform resource for
# the full MSK Connect worker configuration; shown as detailed comments)
# =============================================================================
#
# MSK Connect is a fully managed Apache Kafka Connect service.
# Kafka Connect is a framework for streaming data between Kafka and external systems.
#
# CONNECTORS:
#   Source Connectors: pull data INTO Kafka topics from external systems
#     Examples: Debezium (CDC from RDS/MySQL), S3 Source, JDBC Source
#   Sink Connectors:  push data FROM Kafka topics to external systems
#     Examples: S3 Sink (archive to S3), Elasticsearch Sink, Redshift Sink
#
# COMPONENTS:
#   Connector:        the actual plugin (JAR) that knows how to talk to a system
#   Worker:           JVM process that runs connectors (MSK Connect manages these)
#   Worker Config:    properties that control connector behavior
#   Custom Plugin:    upload your connector JAR to S3, register it with MSK Connect
#
# SAA-C03 USE CASES:
#   "Stream RDS changes to Kafka in real time"         → MSK Connect + Debezium source
#   "Archive all Kafka messages to S3 automatically"   → MSK Connect + S3 sink
#   "Continuously index Kafka data in OpenSearch"      → MSK Connect + OpenSearch sink
#
# Terraform resources (when available):
#   aws_mskconnect_custom_plugin      — registers a connector JAR from S3
#   aws_mskconnect_worker_configuration — defines worker.properties
#   aws_mskconnect_connector          — creates a running connector instance
#
# Example (illustrative, not deployed in this lab):
#
# resource "aws_mskconnect_custom_plugin" "s3_sink" {
#   name         = "confluentinc-kafka-connect-s3"
#   content_type = "ZIP"
#   location {
#     s3 {
#       bucket_arn = aws_s3_bucket.connector_plugins.arn
#       file_key   = "confluentinc-kafka-connect-s3-10.5.0.zip"
#     }
#   }
# }
#
# resource "aws_mskconnect_connector" "s3_archive" {
#   name = "s3-sink-connector"
#   kafkaconnect_version = "2.7.1"
#   capacity {
#     autoscaling {
#       mcu_count        = 1
#       min_worker_count = 1
#       max_worker_count = 2
#       scale_in_policy  { cpu_utilization_percentage = 20 }
#       scale_out_policy { cpu_utilization_percentage = 80 }
#     }
#   }
#   connector_configuration = {
#     "connector.class"        = "io.confluent.connect.s3.S3SinkConnector"
#     "tasks.max"              = "2"
#     "topics"                 = "orders,events"
#     "s3.region"              = "us-east-1"
#     "s3.bucket.name"         = aws_s3_bucket.sink.bucket
#     "s3.part.size"           = "67108864"
#     "storage.class"          = "io.confluent.connect.s3.storage.S3Storage"
#     "format.class"           = "io.confluent.connect.s3.format.parquet.ParquetFormat"
#     "flush.size"             = "1000"
#   }
#   kafka_cluster {
#     apache_kafka_cluster {
#       bootstrap_servers = aws_msk_cluster.main.bootstrap_brokers_tls
#       vpc { subnets = [aws_subnet.private_a.id, aws_subnet.private_b.id] }
#     }
#   }
#   service_execution_role_arn = aws_iam_role.msk_connect.arn
# }

# =============================================================================
# MSK REPLICATOR (CONCEPT — Cross-region replication)
# =============================================================================
#
# MSK Replicator continuously replicates Kafka topics from one MSK cluster
# (source) to another MSK cluster (target) in a different AWS Region.
#
# USE CASES:
#   - Disaster recovery: keep a warm standby Kafka cluster in another region
#   - Global data distribution: replicate events to regional consumers
#   - Analytics: replicate production traffic to a separate analytics cluster
#
# SAA-C03 TIP:
#   "Multi-region Kafka" or "Kafka DR" → MSK Replicator
#   "Kafka cross-region replication"   → MSK Replicator
#
# Terraform resource: aws_msk_replicator (available in provider ~> 5.x)
#
# resource "aws_msk_replicator" "dr" {
#   replicator_name             = "prod-to-dr"
#   service_execution_role_arn  = aws_iam_role.msk_replicator.arn
#   kafka_cluster {
#     amazon_msk_cluster {
#       msk_cluster_arn = aws_msk_cluster.source.arn
#     }
#     vpc_config { ... }
#   }
#   kafka_cluster {
#     amazon_msk_cluster {
#       msk_cluster_arn = aws_msk_cluster.target.arn  # In another region
#     }
#     vpc_config { ... }
#   }
#   replication_info_list {
#     source_kafka_cluster_arn = aws_msk_cluster.source.arn
#     target_kafka_cluster_arn = aws_msk_cluster.target.arn
#     target_compression_type  = "NONE"
#     topic_replication {
#       topics_to_replicate = [".*"]  # Replicate all topics
#     }
#     consumer_group_replication {
#       consumer_groups_to_replicate = [".*"]  # Replicate all offsets
#     }
#   }
# }

# =============================================================================
# KINESIS DATA STREAM: Source for Flink application
# =============================================================================
# Kinesis Data Streams is the event ingestion layer.
# Producers (apps, IoT devices, clickstreams) write records to shards.
# The Flink application reads from this stream in real time.
#
# SHARD CAPACITY:
#   Each shard provides: 1 MB/s or 1,000 records/s WRITE
#                        2 MB/s READ (per consumer)
# Provision shards based on your peak write throughput.
#
# ON-DEMAND MODE (alternative):
#   aws_kinesis_stream with stream_mode_details { stream_mode = "ON_DEMAND" }
#   No shard management — auto-scales up to 200 MB/s write throughput.

resource "aws_kinesis_stream" "source" {
  name             = "${var.project_name}-source-stream"
  shard_count      = 2  # 2 shards = 2 MB/s write, 4 MB/s read throughput
  retention_period = 24 # Hours to retain records (24h default, max 8760h = 365 days)

  # Shard-level CloudWatch metrics — enable for production monitoring
  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "OutgoingBytes",
    "OutgoingRecords",
    "IteratorAgeMilliseconds", # Consumer lag — critical metric
    "ReadProvisionedThroughputExceeded",
    "WriteProvisionedThroughputExceeded"
  ]

  # Server-side encryption for records at rest in Kinesis
  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.msk.arn # Reuse our existing CMK

  stream_mode_details {
    stream_mode = "PROVISIONED" # Fixed shards; use ON_DEMAND for variable load
  }

  tags = {
    Name = "${var.project_name}-source-stream"
    Lab  = "47-msk"
  }
}

# =============================================================================
# S3 BUCKET: Output destination for Kinesis Data Analytics Flink app
# =============================================================================
# The Flink application writes processed results to S3.
# From S3, downstream services (Athena, Redshift Spectrum, Glue) can query.

resource "aws_s3_bucket" "analytics_output" {
  bucket = "${var.project_name}-analytics-output-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-analytics-output"
    Purpose = "KDA Flink application output"
  }
}

resource "aws_s3_bucket_versioning" "analytics_output" {
  bucket = aws_s3_bucket.analytics_output.id
  versioning_configuration {
    status = "Enabled"
  }
}

# =============================================================================
# IAM ROLE: Kinesis Data Analytics execution role
# =============================================================================
# The KDA Flink application assumes this role at runtime.
# It needs permissions to:
#   - Read from Kinesis Data Streams (GetRecords, DescribeStream, etc.)
#   - Write output to S3 (PutObject, etc.)
#   - Write CloudWatch logs (for application logging)
#   - Access KMS key for decrypting encrypted stream records

resource "aws_iam_role" "kinesis_analytics" {
  name = "${var.project_name}-kda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "kinesisanalytics.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-kda-role"
  }
}

resource "aws_iam_role_policy" "kinesis_analytics" {
  name = "${var.project_name}-kda-policy"
  role = aws_iam_role.kinesis_analytics.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read from Kinesis Data Streams
      {
        Sid    = "ReadKinesisStream"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:ListShards",
          "kinesis:ListStreams",
          "kinesis:SubscribeToShard" # Required for Enhanced Fan-Out
        ]
        Resource = aws_kinesis_stream.source.arn
      },
      # Write results to S3
      {
        Sid    = "WriteS3Output"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucket",
          "s3:ListMultipartUploadParts",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.analytics_output.arn,
          "${aws_s3_bucket.analytics_output.arn}/*"
        ]
      },
      # CloudWatch Logs for Flink application logging
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      # KMS access to decrypt encrypted Kinesis records
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.msk.arn
      }
    ]
  })
}

# =============================================================================
# KINESIS DATA ANALYTICS v2: Apache Flink Application
# =============================================================================
#
# WHAT IS KINESIS DATA ANALYTICS (KDA)?
#   A fully managed service for real-time stream processing.
#   Two runtime modes (SAA-C03 comparison):
#
#   SQL APPLICATION (legacy, "SQLSTREAM" runtime — do not use for new apps):
#     - Simple SQL queries on streaming data
#     - Being deprecated by AWS
#     - Very limited: no stateful operations, no complex windowing
#
#   FLINK APPLICATION (recommended, "FLINK-1_xx" runtime):
#     - Full Apache Flink framework — stateful stream processing
#     - Supports complex event processing: joins, windows, aggregations
#     - Checkpointing for fault tolerance (state survives restarts)
#     - Parallelism: number of parallel tasks = KPUs * parallelism_per_kpu
#     - Auto-scaling: KDA can increase/decrease KPUs based on CPU utilization
#
# KEY CONCEPTS:
#   KPU (Kinesis Processing Unit): 1 vCPU + 4 GB memory
#   Parallelism: number of parallel Flink tasks running concurrently
#   Checkpoints: periodic snapshots of Flink state to S3 (for recovery)
#   Savepoints: manual checkpoints for planned upgrades/restarts
#
# SAA-C03 COMPARISON:
#   KDA Flink         = complex stateful streaming; real-time anomaly detection
#   Glue Streaming    = simpler Spark streaming; micro-batch ETL
#   Lambda            = event-driven; short-lived; no state between invocations
#   Kinesis Firehose  = near-real-time delivery (60s buffer); no processing logic
#
# ARCHITECTURE IN THIS LAB:
#   Kinesis Stream → [KDA Flink Application] → S3 bucket
#   The Flink app reads records, applies transformations, writes results to S3.

resource "aws_kinesisanalyticsv2_application" "flink_app" {
  name                   = "${var.project_name}-flink-app"
  description            = "Real-time stream processing with Apache Flink - SAA-C03 Lab 47"
  runtime_environment    = "FLINK-1_18" # Apache Flink 1.18 — latest stable in KDA
  service_execution_role = aws_iam_role.kinesis_analytics.arn

  # --- Application configuration block ---
  application_configuration {

    # Flink-specific configuration (only used when runtime is FLINK-*)
    flink_application_configuration {

      # Checkpointing: how KDA saves Flink application state to S3
      # If the application crashes, it restarts from the last checkpoint
      checkpoint_configuration {
        # CUSTOM: we define checkpointing parameters ourselves
        # DEFAULT: KDA uses sensible defaults (5-minute intervals)
        configuration_type = "CUSTOM"

        # Enable checkpointing (required for fault tolerance)
        checkpointing_enabled = true

        # How often KDA takes a checkpoint (milliseconds)
        # 60000 ms = 1 minute. Lower = less data loss on failure but more overhead.
        checkpoint_interval = 60000

        # Minimum time between checkpoint completion and next checkpoint start
        # Prevents checkpoint from overlapping with itself under heavy load
        min_pause_between_checkpoints = 5000
      }

      # Monitoring: CloudWatch metrics for the Flink application
      monitoring_configuration {
        configuration_type = "CUSTOM"

        # Metric level controls the granularity of CloudWatch metrics:
        #   APPLICATION: aggregate metrics for the whole app
        #   TASK:        per-task metrics (more detail, higher cost)
        #   OPERATOR:    per-operator metrics (most detailed)
        #   PARALLELISM: per-parallel-instance metrics (most granular)
        metrics_level = "APPLICATION"

        # Log level for Flink application logs sent to CloudWatch
        log_level = "INFO" # Options: DEBUG, INFO, WARN, ERROR
      }

      # Parallelism: controls how many parallel threads Flink uses
      parallelism_configuration {
        configuration_type = "CUSTOM"

        # Total parallelism: number of concurrent Flink tasks
        # KDA allocates: ceil(parallelism / parallelism_per_kpu) KPUs
        # Example: parallelism=4, per_kpu=4 → 1 KPU (1 vCPU, 4 GB)
        parallelism = 4

        # How many parallel tasks each KPU runs
        parallelism_per_kpu = 4

        # Allow KDA to automatically increase KPUs if CPU is high
        # SAA-C03: auto-scaling = don't over-provision; pay per actual use
        auto_scaling_enabled = true
      }
    }

    # Application code configuration: where is the Flink JAR?
    # In production you upload your compiled .jar to S3 and reference it here.
    # For this lab we use a placeholder — in reality you would:
    #   1. Write a Flink job in Java/Scala/Python
    #   2. Compile to a fat JAR (mvn package)
    #   3. Upload the JAR to S3
    #   4. Reference it here
    application_code_configuration {
      code_content_type = "ZIPFILE" # Can be ZIPFILE (JAR in S3) or PLAINTEXT (SQL)

      code_content {
        s3_content_location {
          bucket_arn     = aws_s3_bucket.analytics_output.arn
          file_key       = "flink-app/streaming-job-1.0.jar" # Upload your JAR here
          object_version = null                              # Pin to a specific S3 object version for reproducibility
        }
      }
    }

    # Environment properties: key-value pairs passed to the Flink job at runtime
    # Your Flink code reads these with:
    #   ParameterTool params = ParameterTool.fromMap(getRuntimeContext().getExecutionConfig().getGlobalJobParameters().toMap());
    environment_properties {
      property_group {
        property_group_id = "FlinkApplicationProperties"

        property_map = {
          "source.kinesis.stream.arn" = aws_kinesis_stream.source.arn
          "source.kinesis.region"     = var.aws_region
          "sink.s3.bucket"            = aws_s3_bucket.analytics_output.bucket
          "sink.s3.prefix"            = "flink-output/"
          "processing.window.seconds" = "60" # Tumbling window size for aggregations
        }
      }
    }

    # VPC configuration: run Flink tasks inside your VPC
    # Required if the app needs to connect to MSK (which is in a private VPC)
    vpc_configuration {
      subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
      security_group_ids = [aws_security_group.msk_brokers.id]
    }
  }

  # CloudWatch logging for the KDA application itself
  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.kda_app.arn
  }

  tags = {
    Name = "${var.project_name}-flink-app"
    Lab  = "47-msk"
  }
}

# CloudWatch log group and stream for KDA Flink application logs
resource "aws_cloudwatch_log_group" "kda_app" {
  name              = "/aws/kinesis-analytics/${var.project_name}"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-kda-logs"
  }
}

resource "aws_cloudwatch_log_stream" "kda_app" {
  name           = "kinesis-analytics-log-stream"
  log_group_name = aws_cloudwatch_log_group.kda_app.name
}

# =============================================================================
# KINESIS DATA ANALYTICS: ARCHITECTURE PATTERNS (SAA-C03 exam tips)
# =============================================================================
#
# PATTERN 1: Real-time dashboard
#   Kinesis Stream → KDA Flink (aggregate per minute) → Kinesis Stream → Lambda → DynamoDB
#   Use case: live leaderboard, real-time metrics on a website
#
# PATTERN 2: Anomaly detection
#   Kinesis Stream → KDA Flink (ML model / threshold check) → SNS → PagerDuty alert
#   Use case: fraud detection, IoT sensor outlier detection
#
# PATTERN 3: ETL on streaming data
#   Kinesis Stream → KDA Flink (filter/enrich/transform) → Kinesis Firehose → S3/Redshift
#   Use case: clickstream enrichment, log parsing
#
# PATTERN 4: MSK as source (instead of Kinesis)
#   MSK Topic → KDA Flink → S3
#   KDA Flink supports MSK as a source connector (Apache Kafka connector)
#   Use this when your producers already use Kafka protocol
#
# vs AWS GLUE STREAMING ETL:
#   KDA Flink:      lower latency (milliseconds), more complex, stateful
#   Glue Streaming: simpler to develop, higher latency (seconds/minutes), Spark-based
#   Exam tip: "lowest latency streaming ETL" → KDA Flink
#             "simplest managed streaming ETL" → Glue Streaming
#
# =============================================================================
# MSK MONITORING STRATEGY (SAA-C03 overview)
# =============================================================================
#
# CloudWatch Metrics (always available):
#   KafkaDataLogsDiskUsed          — disk usage per broker
#   GlobalPartitionCount           — total partitions in cluster
#   UnderReplicatedPartitions      — partitions not fully replicated (ALARM on this)
#   ActiveControllerCount          — should always be 1; 0 = cluster issue
#   OfflinePartitionsCount         — partitions with no leader (ALARM on this)
#   EstimatedMaxTimeLag            — consumer lag in time
#   SumOffsetLag                   — consumer lag in records
#   BytesInPerSec / BytesOutPerSec — throughput per broker
#
# Prometheus (via open_monitoring):
#   All JMX metrics exposed: kafka.server:*, kafka.controller:*, kafka.network:*
#   Node metrics: CPU, disk I/O, network I/O per broker instance
#   Scrape endpoint: port 11001 (JMX) and 11002 (node)
#
# SAA-C03 exam tip:
#   "Monitor consumer lag" → UnderReplicatedPartitions or SumOffsetLag in CloudWatch
#   "Custom Kafka dashboards" → Prometheus + Grafana using open monitoring
