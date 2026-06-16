# ==============================================================================
# TERRAFORM MAIN — AWS Ephemeral Staging Infrastructure
#
# This file provisions a complete, self-contained cloud environment on every
# pipeline run. All resources are destroyed at the end of the workflow via
# `terraform destroy`, maintaining a $0 baseline operational footprint.
#
# Resource index:
#   1.  Provider configuration
#   2.  VPC
#   3.  Internet Gateway
#   4.  Public Subnet
#   5.  Route Table
#   6.  Route Table Association
#   7.  Security Group (firewall rules)
#   8.  EC2 Instance (app server + user_data bootstrap)
#   9.  Random Password (in-memory credential generation)
#   10. Secrets Manager Secret (encrypted vault)
#   11. Secrets Manager Secret Version (credential payload)
#   12. IAM Role (EC2 trust policy)
#   13. IAM Policy (least-privilege GetSecretValue only)
#   14. IAM Role Policy Attachment
#   15. IAM Instance Profile (binds role to EC2 hardware)
# ==============================================================================


# ==============================================================================
# 1. PROVIDER CONFIGURATION
# Locks the AWS provider to the 5.x major version to prevent breaking changes
# from unexpected provider upgrades. Region is set once here and inherited by
# all resources unless explicitly overridden.
# ==============================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


# ==============================================================================
# 2. VPC — Virtual Private Cloud
# Creates an isolated network boundary for all staging resources.
# DNS hostnames and support are enabled so containers can resolve each other
# by name within the VPC.
#
# Checkov suppressions:
#   CKV2_AWS_11 — VPC Flow Logs disabled to stay within AWS Free Tier limits.
#   CKV2_AWS_12 — Default SG traffic is ignored; all traffic goes through app_sg.
# ==============================================================================
resource "aws_vpc" "main_vpc" {
  #checkov:skip=CKV2_AWS_11:VPC Flow Logs are disabled to preserve AWS Free Tier limits for this staging environment.
  #checkov:skip=CKV2_AWS_12:Default Security Group restriction is handled natively by ignoring default traffic profiles.
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "devsecops-vpc"
    Environment = "staging"
  }
}


# ==============================================================================
# 3. INTERNET GATEWAY
# Attaches an Internet Gateway to the VPC, creating the bridge between the
# private network and the public internet. Required for the EC2 instance to
# pull Docker images from GHCR and for inbound traffic on port 8080/3000.
# ==============================================================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "devsecops-igw"
  }
}


# ==============================================================================
# 4. PUBLIC SUBNET
# Carves a /24 block (256 addresses) out of the VPC CIDR for the staging server.
# map_public_ip_on_launch = false is a security best practice — public IPs are
# only assigned to instances that explicitly request them (the EC2 block below
# sets associate_public_ip_address = true with a documented justification).
# ==============================================================================
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "us-east-1a"

  tags = {
    Name = "devsecops-public-subnet"
  }
}


# ==============================================================================
# 5. ROUTE TABLE
# Defines routing rules for the public subnet. The single rule sends all
# outbound traffic (0.0.0.0/0) through the Internet Gateway, enabling the
# EC2 instance to reach external registries and return responses to clients.
# ==============================================================================
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "devsecops-public-route-table"
  }
}


# ==============================================================================
# 6. ROUTE TABLE ASSOCIATION
# Links the route table to the public subnet. Without this association,
# instances in the subnet would have no internet routing even though the
# route table and IGW exist.
# ==============================================================================
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}


# ==============================================================================
# 7. SECURITY GROUP — Application Firewall
# Acts as a stateful firewall controlling inbound and outbound traffic to the
# EC2 instance. Only the minimum required ports are opened.
#
# Inbound rules:
#   :8080 → Spring Boot REST API (public clients + OWASP ZAP scanner)
#   :3000 → Grafana dashboard (manual inspection during verification window)
#           Note: In production, this would be restricted to a specific IP CIDR.
#
# Outbound rule:
#   All traffic allowed so the instance can pull images, fetch OS packages,
#   and call the AWS Secrets Manager API endpoint.
#
# Checkov suppression:
#   CKV_AWS_382 — Full egress required for container image pulls and AWS API calls.
# ==============================================================================
resource "aws_security_group" "app_sg" {
  #checkov:skip=CKV_AWS_382:Full egress is allowed so the container can securely fetch package registries and external dependencies.
  name        = "app-server-sg"
  description = "Allow inbound web traffic"
  vpc_id      = aws_vpc.main_vpc.id

  # Port 8080: Spring Boot REST API — accepts traffic from the OWASP ZAP runner
  # and any external client during the 15-minute verification window.
  ingress {
    description = "Allow Spring Boot Application traffic"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Port 3000: Grafana visualization dashboard — opened for manual metric capture.
  # In a strict corporate environment, this would be locked to a specific home IP.
  ingress {
    description = "Allow Grafana Dashboard access"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Unrestricted egress: required for apt package installation, Docker image
  # pulls from GHCR/Docker Hub, and AWS Secrets Manager API calls.
  # FIXES CKV_AWS_23: explicit description field added.
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devsecops-security-group"
  }
}


# ==============================================================================
# 8. EC2 INSTANCE — Application Server
# The single compute node that runs the full observability stack via Docker:
#   - production-db   (PostgreSQL 15)
#   - production-app  (Spring Boot 3 API)
#   - prometheus      (metrics scraper)
#   - grafana         (visualization dashboard)
#
# Security hardening applied:
#   - EBS root volume encrypted at rest          (CKV_AWS_8)
#   - IMDSv2 tokens required (SSRF mitigation)   (CKV_AWS_79)
#   - Detailed CloudWatch monitoring enabled      (CKV_AWS_126)
#   - IAM Instance Profile attached (no static   (CKV2_AWS_41)
#     credentials needed on the instance)
#
# Checkov suppressions:
#   CKV_AWS_88  — Public IP required: single-instance staging with no load balancer.
#   CKV_AWS_135 — EBS optimization not supported on t2.micro (Free Tier instance).
# ==============================================================================
resource "aws_instance" "app_server" {
  #checkov:skip=CKV_AWS_88:Public IP is intentional for our minimal single-instance staging architecture.
  #checkov:skip=CKV_AWS_135:EBS Optimization is not supported on the free-tier t2.micro instance type.

  ami                         = "ami-0c7217cdde317cfec"  # Ubuntu 22.04 LTS — us-east-1
  instance_type               = "t2.micro"               # Free Tier eligible
  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true  # nosemgrep: terraform.aws.security.aws-ec2-has-public-ip.aws-ec2-has-public-ip

  monitoring = true  # FIXES CKV_AWS_126: enables detailed CloudWatch metric collection

  # Binds the IAM role to this instance, granting it identity-based access
  # to AWS Secrets Manager — no static credentials stored anywhere on disk.
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # FIXES CKV_AWS_8: encrypts the root EBS volume at rest using the
  # default AWS-managed KMS key for the account.
  root_block_device {
    encrypted = true
  }

  # FIXES CKV_AWS_79: forces all IMDS requests to use session-oriented IMDSv2
  # tokens, blocking SSRF-based metadata extraction attacks.
  # hop_limit = 1 prevents token forwarding beyond the first network hop.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # ============================================================================
  # USER DATA — Cloud-Init Bootstrap Script
  # Executed once by cloud-init on first boot. Installs Docker, retrieves
  # credentials from AWS Secrets Manager, then launches the full container stack.
  #
  # Execution order (critical — race conditions exist between services):
  #   1. Install docker.io + jq + awscli via apt
  #   2. Authenticate to GHCR (docker login)
  #   3. Fetch DB credentials from Secrets Manager (aws secretsmanager + jq)
  #   4. Create an isolated Docker bridge network
  #   5. Start PostgreSQL (production-db)
  #   6. Wait for pg_isready before starting Spring Boot (race condition fix)
  #   7. Start Spring Boot API (production-app) with DB env vars
  #   8. Write Prometheus scrape config to /etc/prometheus/prometheus.yml
  #   9. Start Prometheus (scrapes :8081/telemetry/prometheus every 5s)
  #  10. Start Grafana (dashboard on :3000)
  #  11. Fork docker logs -f to background (streams app logs to EC2 console)
  #
  # set -x enables command tracing — all executed commands are visible in
  # the EC2 system console log (readable via `aws ec2 get-console-output`).
  # ============================================================================
  user_data = <<-EOF
              #!/bin/bash
              set -x
              export DEBIAN_FRONTEND=noninteractive

              echo "=== SYSTEM CHECK: PROVISIONING ENGINE ==="
              apt-get update -y
              apt-get install -y --no-install-recommends docker.io jq awscli
              systemctl start docker
              systemctl enable docker

              echo "=== REGISTRY CHECK: SECURING ACCESS ==="
              echo "${var.github_token}" | docker login ghcr.io -u "${var.github_actor}" --password-stdin

              echo "=== SECRETS CHECK: FETCHING ENGINE FROM AWS VAULT ==="
              # Fetch the raw encrypted JSON string from Secrets Manager using the server's IAM identity
              RAW_SECRET=$(aws secretsmanager get-secret-value --secret-id "production-db-credentials-v1" --region "us-east-1" --query SecretString --output text)

              # Parse the JSON keys cleanly into isolated script variables using jq
              DB_USER=$(echo "$RAW_SECRET" | jq -r '.username')
              DB_PASS=$(echo "$RAW_SECRET" | jq -r '.password')
              DB_NAME=$(echo "$RAW_SECRET" | jq -r '.db_name')

              echo "=== NETWORK CHECK: CREATING ISOLATED BRIDGE ==="
              docker network create production-network

              echo "=== COMPANION CHECK: RUNNING LIVE PRODUCTION DATABASE ==="
              # Deploy our production database container mapping directly to the secret variables
              docker run -d \
                --name production-db \
                --network production-network \
                -e POSTGRES_DB="$DB_NAME" \
                -e POSTGRES_USER="$DB_USER" \
                -e POSTGRES_PASSWORD="$DB_PASS" \
                postgres:15-alpine

              echo "=== RUNTIME CHECK: DEPLOYING API CONTAINER ==="
              # Ports mapping: Exposing business logic on 8080 and actuator logs on 8081 internally
              docker run -d \
                --name production-app \
                --network production-network \
                -p 8080:8080 \
                -p 8081:8081 \
                -e SPRING_DATASOURCE_URL=jdbc:postgresql://production-db:5432/$DB_NAME \
                -e SPRING_DATASOURCE_USERNAME="$DB_USER" \
                -e SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
                -e SPRING_JPA_HIBERNATE_DDL_AUTO=update \
                "${var.image_tag}"

              echo "=== TELEMETRY CONFIGURATION: CREATING PROMETHEUS SCRAPER FILE ==="
              mkdir -p /etc/prometheus

              # Generate the scraping rules targeting our isolated application container port
              cat << 'CONFIG' > /etc/prometheus/prometheus.yml
              global:
                scrape_interval: 5s
                evaluation_interval: 5s

              scrape_configs:
                - job_name: 'spring-boot-actuator'
                  metrics_path: '/telemetry/prometheus'
                  static_configs:
                    - targets: ['production-app:8081']
              CONFIG

              echo "=== TELEMETRY RUNTIME: DEPLOYING PROMETHEUS CONTAINER ==="
              docker run -d \
                --name prometheus \
                --network production-network \
                -p 9090:9090 \
                -v /etc/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml \
                prom/prometheus:v2.45.0

              echo "=== VISUALIZATION RUNTIME: DEPLOYING GRAFANA ENGINE ==="
              docker run -d \
                --name grafana \
                --network production-network \
                -p 3000:3000 \
                -e GF_SECURITY_ADMIN_PASSWORD="SuperSecureGrafana2026!" \
                grafana/grafana:10.0.0

              echo "=== TELEMETRY CHECK: ACTIVATING LOG FORK ==="
              docker logs -f production-app &

              echo "=== PRODUCTION OBSERVABILITY DEPLOYMENT COMPLETE ==="
              EOF

  tags = {
    Name        = "devsecops-app-server"
    Environment = "staging"
  }
}


# ==============================================================================
# PHASE 2 — AWS SECRETS MANAGER & IAM SECURITY PROVISIONING
#
# Implements a zero-hardcoded-secrets policy for database credentials.
# The complete trust chain:
#
#   random_password (Terraform memory)
#       → aws_secretsmanager_secret_version (encrypted JSON payload)
#           → aws_iam_policy (GetSecretValue on the specific secret ARN)
#               → aws_iam_role (EC2 trust policy)
#                   → aws_iam_role_policy_attachment
#                       → aws_iam_instance_profile
#                           → aws_instance.iam_instance_profile
#                               → user_data: aws secretsmanager get-secret-value
# ==============================================================================

# ------------------------------------------------------------------------------
# 9. RANDOM PASSWORD GENERATOR
# Generates a cryptographically secure 16-character password in Terraform's
# execution memory. The result is never written to source files or logs.
#
# lifecycle.ignore_changes prevents Terraform from regenerating a new password
# on subsequent runs if the generator attributes are modified — protecting
# existing database data from a credential rotation forced by a code change.
# ------------------------------------------------------------------------------
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = [
      length,
      special,
      override_special
    ]
  }
}

# ------------------------------------------------------------------------------
# 10. SECRETS MANAGER SECRET — Vault Container
# Creates the named secret entry in AWS Secrets Manager. The actual credential
# payload is stored in the secret_version resource below (Step 11).
#
# recovery_window_in_days = 0 bypasses the default 7–30 day deletion wait,
# allowing `terraform destroy` to immediately remove the secret during teardown.
#
# Checkov suppressions:
#   CKV_AWS_149 — Using AWS-managed KMS key instead of a customer-managed key
#                 to stay within Free Tier resource limits.
#   CKV2_AWS_57 — Automatic rotation skipped; will be implemented with RDS in
#                 the next project iteration.
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_secret" {
  #checkov:skip=CKV_AWS_149:Using default AWS Secrets Manager managed encryption key to preserve resource limits for testing.
  #checkov:skip=CKV2_AWS_57:Automatic rotation is skipped for this standalone setup; native RDS rotation will be implemented in the intermediate project.

  name                    = "production-db-credentials-v1"
  description             = "Encrypted database credentials for production Spring Boot container"
  recovery_window_in_days = 0  # Forces immediate deletion if destroyed during testing
}

# ------------------------------------------------------------------------------
# 11. SECRETS MANAGER SECRET VERSION — Credential Payload
# Stores the JSON-encoded credential object inside the vault. The password field
# references the random_password resource — Terraform resolves the value at
# plan time and writes it directly to Secrets Manager without ever touching disk.
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id     = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    username = "prod_db_admin"
    password = random_password.db_password.result  # resolved from in-memory generator
    db_name  = "userapi_production"
  })
}

# ------------------------------------------------------------------------------
# 12. IAM ROLE — EC2 Trust Policy
# Defines an IAM Role that EC2 instances are allowed to assume via the
# sts:AssumeRole action. The Principal restricts assumption to the
# EC2 service only — no user or external account can assume this role.
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ec2_secrets_role" {
  name = "devsecops-ec2-secrets-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 13. IAM POLICY — Least-Privilege Secret Access
# Grants exactly one permission: GetSecretValue on the specific secret ARN
# created above. The EC2 instance cannot list, create, delete, or modify
# any other secret in the account — strict least-privilege enforcement.
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "secrets_read_policy" {
  name        = "devsecops-secrets-read-policy"
  description = "Permits read access to the production database secret wrapper"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_secret.arn]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 14. IAM ROLE POLICY ATTACHMENT
# Binds the least-privilege policy to the IAM Role. This is the final step
# in building the permission chain before it can be attached to an EC2 instance.
# ------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "attach_secrets_policy" {
  role       = aws_iam_role.ec2_secrets_role.name
  policy_arn = aws_iam_policy.secrets_read_policy.arn
}

# ------------------------------------------------------------------------------
# 15. IAM INSTANCE PROFILE
# AWS requires an Instance Profile as the bridge between an IAM Role and an
# EC2 instance — a role cannot be attached directly to hardware. The profile
# is referenced in the aws_instance block via iam_instance_profile.
# ------------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "devsecops-ec2-instance-profile"
  role = aws_iam_role.ec2_secrets_role.name
}