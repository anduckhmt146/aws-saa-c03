# ============================================================
# LAB 04 - VPC: Subnets, IGW, NAT Gateway, Route Tables,
#          Security Groups, NACLs, VPC Peering, Endpoints
# All resources are destroy-safe
# ============================================================

data "aws_availability_zones" "available" {

  state = "available"
}

# ============================================================
# VPC
# CIDR: /16 to /28 (65536 to 16 IPs)
# Private ranges:
#   10.0.0.0/8       (Class A)
#   172.16.0.0/12    (Class B)
#   192.168.0.0/16   (Class C)
# NOTE: Cannot change VPC CIDR after creation
# ============================================================
resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "lab-vpc" }
}

# ============================================================
# SUBNETS
# Each subnet reserves 5 IPs:
#   .0  = Network address
#   .1  = VPC router
#   .2  = DNS server
#   .3  = Reserved (future use)
#   .255 = Broadcast
# Example: /24 = 256 IPs, available = 251
# ============================================================
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.lab.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true # Auto-assign public IP

  tags = { Name = "lab-public-subnet-${count.index + 1}" }
}

resource "aws_subnet" "private" {

  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.lab.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "lab-private-subnet-${count.index + 1}" }
}

# ============================================================
# INTERNET GATEWAY (IGW)
# - 1 VPC = 1 IGW (one-to-one relationship)
# - Enables internet access for PUBLIC subnets
# - Horizontally scaled, HA, no bandwidth constraint
# ============================================================
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "lab-igw" }
}

# ============================================================
# ELASTIC IP for NAT Gateway
# ============================================================
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.lab]
  tags       = { Name = "lab-nat-eip" }
}

# ============================================================
# NAT GATEWAY
# - Allows PRIVATE subnets to access internet (outbound only)
# - Deployed in PUBLIC subnet
# - Requires Elastic IP
# - AWS managed: HA within AZ, 5-100 Gbps
# - NAT Gateway vs NAT Instance:
#   NAT GW  = Managed, HA, 5-100Gbps, no SG management
#   NAT Inst = Self-managed, single point of failure, cheaper
# ============================================================
resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Must be in PUBLIC subnet
  depends_on    = [aws_internet_gateway.lab]
  tags          = { Name = "lab-nat-gw" }
}

# ============================================================
# ROUTE TABLES
# Public: 0.0.0.0/0 → IGW
# Private: 0.0.0.0/0 → NAT Gateway
# ============================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "lab-public-rt" }
}

resource "aws_route_table" "private" {

  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = { Name = "lab-private-rt" }
}

resource "aws_route_table_association" "public" {

  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {

  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# SECURITY GROUPS (Stateful - track connection state)
# - Instance-level firewall
# - ALLOW rules only (no DENY)
# - Rules evaluated as a whole (no order)
# - Changes apply immediately
# ============================================================
resource "aws_security_group" "web" {
  name        = "lab-web-sg"
  description = "Web tier - HTTP/HTTPS"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {

    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-web-sg" }
}

resource "aws_security_group" "app" {

  name        = "lab-app-sg"
  description = "App tier - from web SG only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id] # Reference another SG
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-app-sg" }
}

resource "aws_security_group" "db" {

  name        = "lab-db-sg"
  description = "DB tier - from app SG only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {

    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-db-sg" }
}

# ============================================================
# NETWORK ACL (NACL) - Stateless firewall at subnet level
# - ALLOW and DENY rules
# - Rules evaluated in ORDER (lowest number first)
# - Stateless: must allow inbound AND outbound separately
# - Default NACL: allow all traffic
#
# SG vs NACL:
#   SG   = Stateful, instance-level, allow only
#   NACL = Stateless, subnet-level, allow + deny
# ============================================================
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.lab.id
  subnet_ids = aws_subnet.public[*].id

  # Inbound rules
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {

    protocol   = "tcp"
    rule_no    = 110
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Allow return traffic (ephemeral ports 1024-65535)
  ingress {
    protocol   = "tcp"
    rule_no    = 120
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Deny all else
  ingress {
    protocol   = "-1"
    rule_no    = 32767
    action     = "deny"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  # Outbound rules
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = { Name = "lab-public-nacl" }
}

# ============================================================
# VPC ENDPOINTS
# - Private connection to AWS services without internet
# - Gateway Endpoint: S3, DynamoDB (free)
# - Interface Endpoint: Most other services (hourly cost)
# ============================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "lab-s3-endpoint" }
}

# ============================================================
# VPC FLOW LOGS (network traffic monitoring)
# ============================================================
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/lab-flow-logs"
  retention_in_days = 7 # Minimize cost in lab
}

resource "aws_iam_role" "vpc_flow_logs" {

  name = "lab-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {

  name = "lab-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "lab" {

  vpc_id          = aws_vpc.lab.id
  traffic_type    = "ALL" # ACCEPT, REJECT, or ALL
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = { Name = "lab-vpc-flow-log" }
}
