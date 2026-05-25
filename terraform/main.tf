
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region = "ap-south-1"
}

# -------------------------
# VPC (use default VPC)
# -------------------------
data "aws_vpc" "default" {
  default = true
}


data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -------------------------
# Security Group
# -------------------------
resource "aws_security_group" "k8s_sg" {
  name        = "k8s-sg"
  description = "Allow SSH and NodePort"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NodePort range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------
# Latest Amazon Linux AMI
# -------------------------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-*-x86_64"]
  }
}

# -------------------------
# EC2 Instance
# -------------------------
resource "aws_instance" "k8s_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.small"
  key_name      = "ssva_mumbai_keypair"

  vpc_security_group_ids = [aws_security_group.k8s_sg.id]

  subnet_id = element(data.aws_subnets.default.ids, 0)

  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp2"
  }

  user_data = file("${path.module}/install.sh")

  tags = {
    Name = "k3s-server"
  }
}

# -------------------------
# OUTPUT
# -------------------------
output "public_ip" {
  value = aws_instance.k8s_server.public_ip
}
