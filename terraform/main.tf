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
# Variables
# -------------------------
variable "key_name" {
  description = "EC2 key pair name"
  default     = "ssva_mumbai_keypair"
}

variable "instance_type" {
  description = "EC2 instance type — t3.small is cheapest that runs k3s reliably"
  default     = "t3.small"
}

variable "worker_count" {
  description = "Number of worker nodes"
  default     = 2
}

# -------------------------
# Default VPC & Subnets
# (no custom VPC needed — saves cost, simpler for learning)
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
# Latest Amazon Linux 2023 AMI
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
# Security Group
# -------------------------
resource "aws_security_group" "k8s_sg" {
  name        = "k8s-multi-node-sg"
  description = "K8s multi-node cluster security group"
  vpc_id      = data.aws_vpc.default.id

  # SSH — for you to connect and debug
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NodePort 30080 — nginx-ingress HTTP prod
  ingress {
    description = "nginx-ingress HTTP NodePort prod"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NodePort 31080 — nginx-ingress HTTP dev
  ingress {
    description = "nginx-ingress HTTP NodePort dev"
    from_port   = 31080
    to_port     = 31080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NodePort 30443 — ArgoCD UI
  ingress {
    description = "ArgoCD UI NodePort"
    from_port   = 30443
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NodePort 30444 — nginx-ingress HTTPS
  ingress {
    description = "nginx-ingress HTTPS NodePort"
    from_port   = 30444
    to_port     = 30444
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # k3s API server — workers register here
  ingress {
    description = "k3s API server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flannel VXLAN — pod-to-pod traffic across nodes (UDP!)
  ingress {
    description = "Flannel VXLAN inter-node"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubelet — node health metrics
  ingress {
    description = "Kubelet"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow ALL traffic between nodes in the same security group
  # This is the key rule for k3s — master ↔ workers communicate freely
  ingress {
    description = "All internal traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true   # means: from/to any instance also in this security group
  }

  # Allow all outbound (pulling images, SSM, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k8s-multi-node-sg" }
}

# -------------------------
# IAM Role — EC2 nodes need SSM access
# Master writes join token → SSM
# Workers read join token ← SSM
# Free — IAM has no charge
# -------------------------
resource "aws_iam_role" "k3s_role" {
  name = "k3s-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "k3s-node-role" }
}

resource "aws_iam_role_policy" "k3s_ssm_policy" {
  name = "k3s-ssm-policy"
  role = aws_iam_role.k3s_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter"
      ]
      # Scoped to only /k3s/* — minimum privilege
      Resource = "arn:aws:ssm:*:*:parameter/k3s/*"
    }]
  })
}

resource "aws_iam_instance_profile" "k3s_profile" {
  name = "k3s-instance-profile"
  role = aws_iam_role.k3s_role.name
}

# -------------------------
# k3s Master Node (1 VM)
# Runs: k3s server + nginx-ingress + ArgoCD + app pods
# Cost: ~$0.023/hr = ~$17/month (stop when not using!)
# -------------------------
resource "aws_instance" "k3s_master" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.k8s_sg.id]
  subnet_id                   = element(data.aws_subnets.default.ids, 0)
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.k3s_profile.name

  root_block_device {
    volume_size = 30  # GB — minimum required by Amazon Linux 2023 AMI snapshot
    volume_type = "gp2"
  }

  # Runs on first boot: installs k3s, nginx-ingress, publishes token to SSM
  user_data = file("${path.module}/master-install.sh")

  tags = { Name = "k3s-master", Role = "master" }
}

# -------------------------
# k3s Worker Nodes (2 VMs)
# Runs: app pods only
# Cost: ~$0.023/hr each = ~$17/month each (stop when not using!)
# -------------------------
resource "aws_instance" "k3s_workers" {
  count                       = var.worker_count
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.k8s_sg.id]
  subnet_id                   = element(data.aws_subnets.default.ids, count.index)
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.k3s_profile.name

  root_block_device {
    volume_size = 30  # GB — minimum required by Amazon Linux 2023 AMI snapshot
    volume_type = "gp2"
  }

  # master_private_ip is injected by Terraform at plan time
  user_data = templatefile("${path.module}/worker-install.sh", {
    master_private_ip = aws_instance.k3s_master.private_ip
  })

  tags = { Name = "k3s-worker-${count.index + 1}", Role = "worker" }

  # Workers must start AFTER master exists (need master's private IP)
  depends_on = [aws_instance.k3s_master]
}

# -------------------------
# Outputs — printed after terraform apply
# -------------------------
output "master_public_ip" {
  description = "k3s master public IP — use for SSH and ArgoCD"
  value       = aws_instance.k3s_master.public_ip
}

output "worker_public_ips" {
  description = "Worker node public IPs"
  value       = aws_instance.k3s_workers[*].public_ip
}

output "app_url" {
  description = "Access your app here (nginx-ingress NodePort)"
  value       = "http://${aws_instance.k3s_master.public_ip}:30080"
}

output "argocd_url" {
  description = "ArgoCD UI"
  value       = "http://${aws_instance.k3s_master.public_ip}:30443"
}

output "cost_reminder" {
  description = "Reminder"
  value       = "STOP EC2 instances when not using to avoid charges (~$0.069/hr for all 3)"
}
