# ============================================================
# LAB 03 - RDS: MySQL, Multi-AZ, Read Replica, Subnet Group
# All resources are destroy-safe (no deletion_protection)
# ============================================================

data "aws_availability_zones" "available" {

  state = "available"
}

data "aws_vpc" "default" {

  default = true
}

data "aws_subnets" "default" {

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# SECURITY GROUP for RDS
# ============================================================
resource "aws_security_group" "rds" {
  name        = "lab-rds-sg"
  description = "Allow MySQL from within VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MySQL"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# DB SUBNET GROUP (required for RDS)
# Best practice: deploy in private subnets across multiple AZs
# ============================================================
resource "aws_db_subnet_group" "lab" {
  name       = "lab-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "lab-db-subnet-group"
  }
}

# ============================================================
# RDS PARAMETER GROUP
# ============================================================
resource "aws_db_parameter_group" "mysql" {
  name   = "lab-mysql-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
}

# ============================================================
# RDS INSTANCE - MySQL (Primary)
# Engines: MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, Aurora
#
# Key Features:
#   - Automated Backups: 1-35 days retention, Point-in-Time Recovery
#   - Manual Snapshots: Retained until deleted, cross-account share
#   - Multi-AZ: Synchronous replication, auto-failover (60-120s)
#   - Read Replicas: Async replication, up to 5 (MySQL), offload reads
# ============================================================
resource "aws_db_instance" "primary" {
  identifier        = "lab-mysql-primary"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "labdb"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.lab.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.mysql.name

  # Automated backups
  backup_retention_period = 7             # Days (0 = disabled)
  backup_window           = "03:00-04:00" # UTC
  maintenance_window      = "sun:04:00-sun:05:00"

  # Multi-AZ: Synchronous standby replica in another AZ
  # Use case: High availability, automatic failover
  # NOTE: Standby is NOT readable (use Read Replica for reads)
  multi_az = false # Set true for HA (costs more in lab)

  # destroy-safe settings
  deletion_protection      = false # No deletion protection
  skip_final_snapshot      = true  # No snapshot on destroy
  delete_automated_backups = true

  publicly_accessible = false

  tags = {
    Name = "lab-mysql-primary"
    Role = "primary"
  }
}

# ============================================================
# READ REPLICA
# - Asynchronous replication (eventual consistency)
# - Readable (offload read traffic, analytics)
# - Can be promoted to standalone DB (DR)
# - Cross-region possible
# - Up to 15 replicas (Aurora), 5 (MySQL)
#
# Multi-AZ vs Read Replica:
#   Multi-AZ    = HA (synchronous, automatic failover, NOT readable)
#   Read Replica = Performance (async, readable, manual failover)
# ============================================================
resource "aws_db_instance" "read_replica" {
  identifier          = "lab-mysql-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.db_instance_class
  storage_type        = "gp3"

  # Read replica inherits most settings from primary
  skip_final_snapshot      = true
  deletion_protection      = false
  delete_automated_backups = true
  publicly_accessible      = false

  tags = {
    Name = "lab-mysql-replica"
    Role = "read-replica"
  }
}

# ============================================================
# DB SNAPSHOT (Manual)
# - User-initiated, no expiration
# - Can share across accounts
# - Can copy across regions
# ============================================================
resource "aws_db_snapshot" "lab" {
  db_instance_identifier = aws_db_instance.primary.identifier
  db_snapshot_identifier = "lab-mysql-manual-snapshot"
}
