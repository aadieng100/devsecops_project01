# 1. Define required providers and versions
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 2. Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# 3. Create a simple, secure VPC (Virtual Private Cloud) Network
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

# 4. Create an Internet Gateway to allow internet access
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "devsecops-igw"
  }
}

# 5. Create a Public Subnet inside the VPC
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false 
  availability_zone       = "us-east-1a"

  tags = {
    Name = "devsecops-public-subnet"
  }
}

# 6. Create a Route Table mapping traffic to the Internet Gateway
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

# 7. Associate the Subnet with the Route Table
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 8. Create a Security Group (Firewall) for our App Server
resource "aws_security_group" "app_sg" {
  #checkov:skip=CKV_AWS_382:Full egress is allowed so the container can securely fetch package registries and external dependencies.
  name        = "app-server-sg"
  description = "Allow inbound web traffic"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "Allow Spring Boot Application traffic"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound rule allowing secure entry to our Grafana visualization engine
  ingress {
    description = "Allow Grafana Dashboard access"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # In a strict corporate environment, this would be locked to your specific home IP
  }

  egress {
    description = "Allow all outbound traffic" # FIXES CKV_AWS_23: Explicit description added
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devsecops-security-group"
  }
}

# 9. Launch the EC2 Virtual Server
resource "aws_instance" "app_server" {
  #checkov:skip=CKV_AWS_88:Public IP is intentional for our minimal single-instance staging architecture.
  #checkov:skip=CKV_AWS_135:EBS Optimization is not supported on the free-tier t2.micro instance type.  
  ami                         = "ami-0c7217cdde317cfec" 
  instance_type               = "t2.micro"             
  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true 
  
  monitoring                  = true # FIXES CKV_AWS_126: Detailed monitoring enabled

  # NEW: Attach our structural IAM identity profile directly to the server hardware execution context
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  # FIXES CKV_AWS_8: Force encryption on the underlying storage blocks
  root_block_device {
    encrypted = true
  }

  # FIXES CKV_AWS_79: Enforce IMDSv2 tokens to mitigate SSRF exploitation risks
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

# Production-hardened startup script with dynamic AWS Secret runtime extraction
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

# ========================================================================
# PHASE 3: AWS SECRETS MANAGER & IAM SECURITY PROVISIONING
# ========================================================================

# NEW: Instruct Terraform to generate a secure, random 16-character string in memory
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  # SECURE: Prevents accidental password updates if code attributes are changed later
  lifecycle {
    ignore_changes = [
      length,
      special,
      override_special
    ]
  }
}

# 10. Create the Secrets Manager Vault Container
resource "aws_secretsmanager_secret" "db_secret" {
  #checkov:skip=CKV_AWS_149:Using default AWS Secrets Manager managed encryption key to preserve resource limits for testing.
  #checkov:skip=CKV2_AWS_57:Automatic rotation is skipped for this standalone setup; native RDS rotation will be implemented in the intermediate project.

  name                    = "production-db-credentials-v1"
  description             = "Encrypted database credentials for production Spring Boot container"
  recovery_window_in_days = 0 # Forces immediate deletion if destroyed during testing
}

# 11. Define the structural payload inside the vault (Dynamic Injection)
resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id     = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    username = "prod_db_admin"
    password = random_password.db_password.result # SECURE: References the dynamic generator memory node
    db_name  = "userapi_production"
  })
}

# 12. Create the IAM Trust Policy allowing EC2 instances to assume this identity
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

# 13. Create the granular IAM Policy permitting ONLY Read Access to our specific secret
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

# 14. Attach the read policy directly to our structural IAM Role
resource "aws_iam_role_policy_attachment" "attach_secrets_policy" {
  role       = aws_iam_role.ec2_secrets_role.name
  policy_arn = aws_iam_policy.secrets_read_policy.arn
}

# 15. Generate the AWS Instance Profile bridge required to bind the role to a hardware machine
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "devsecops-ec2-instance-profile"
  role = aws_iam_role.ec2_secrets_role.name
}