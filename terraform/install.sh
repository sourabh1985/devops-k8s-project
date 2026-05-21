#!/bin/bash

yum update -y

# Install Docker
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Install k3s
curl -sfL https://get.k3s.io | sh -

# Allow kubectl without sudo
chmod 644 /etc/rancher/k3s/k3s.yaml

# Set kubeconfig for ec2-user
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml