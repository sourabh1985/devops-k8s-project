#!/bin/bash -xe

# Install required tools
yum install -y git docker

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group (optional but good)
usermod -aG docker ec2-user

# Install k3s (includes kubectl)
curl -sfL https://get.k3s.io | sh -

# Set kubeconfig for kubectl access
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Make it persistent for ec2-user
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/ec2-user/.bashrc

# Fix kubectl command availability
ln -s /usr/local/bin/kubectl /usr/bin/kubectl

# Optional: wait for node to be ready (avoids race condition in CI/CD)
sleep 20