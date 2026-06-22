#!/bin/bash

set -x

# ── System setup ──────────────────────────────────────────────
yum install -y git aws-cli

# ── Install k3s server (master) ───────────────────────────────
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --write-kubeconfig-mode=644 \
  --node-label "role=master"

chmod 644 /etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/ec2-user/.bashrc
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /root/.bashrc

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── Wait for k3s to be ready ──────────────────────────────────
echo "Waiting for k3s master to be ready..."
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    echo "k3s master is ready (attempt $i)"
    break
  fi
  echo "Attempt $i/30 — not ready yet, waiting 5s..."
  sleep 5
done

# ── Get region using IMDSv2 (required on Amazon Linux 2023) ───
TOKEN_IMDS=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || echo "")

if [ -n "$TOKEN_IMDS" ]; then
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN_IMDS" \
    "http://169.254.169.254/latest/meta-data/placement/region")
else
  REGION=$(curl -sf "http://169.254.169.254/latest/meta-data/placement/region" || echo "ap-south-1")
fi

echo "Region: $REGION"

# ── Publish node token to SSM so workers can fetch it ─────────
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)

aws ssm put-parameter \
  --name "/k3s/node-token" \
  --value "$K3S_TOKEN" \
  --type "SecureString" \
  --overwrite \
  --region "$REGION"

echo "Token published to SSM successfully"

# ── Install Helm ──────────────────────────────────────────────
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── Install nginx-ingress on fixed NodePorts ──────────────────
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30444 \
  --wait --timeout=180s

echo "k3s master + nginx-ingress ready"
