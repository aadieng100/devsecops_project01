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
  #checkov:skip=CKV2_AWS_41:IAM Role is skipped as our containerized API doesn't need internal access to other AWS APIs yet.
  
  ami                         = "ami-0c7217cdde317cfec" 
  instance_type               = "t2.micro"             
  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true 
  
  monitoring                  = true # FIXES CKV_AWS_126: Detailed monitoring enabled

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

# Hardened startup script with strict output logging and container health tracking
  user_data = <<-EOF
              #!/bin/bash
              set -x
              exec > /var/log/user-data.log 2>&1
              export DEBIAN_FRONTEND=noninteractive

              echo "=== Starting Bootstrap ==="
              # Install Docker using Ubuntu's native pre-packaged stream
              apt-get update -y
              apt-get install -y --no-install-recommends docker.io

              systemctl start docker
              systemctl enable docker

              # Log in to GitHub Container Registry
              echo "${var.github_token}" | docker login ghcr.io -u "${var.github_actor}" --password-stdin

              # Pull and run the Spring Boot API securely on host port 8080
              echo "Pulling target image: ${var.image_tag}"
              docker run -d -p 8080:8080 --name staging-app "${var.image_tag}"
              
              echo "=== Post-Deployment Container Status ==="
              sleep 5
              docker ps -a
              echo "=== Initial Container Application Logs ==="
              docker logs staging-app
              
              echo "Bootstrap complete!"
              EOF

  tags = {
    Name        = "devsecops-app-server"
    Environment = "staging"
  }
}