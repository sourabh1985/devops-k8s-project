#!/bin/bash

# Don't use -e (exit on error) — we need the retry loops to keep running
set -x

MASTER_IP="${master_private_ip}"

# ── Get region using IMDSv2 (required on Amazon Linux 2023) ───
TOKEN_IMDS=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || echo "")

if [ -n "$TOKEN_IMDS" ]; then
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN_IMDS" \
    "http://169.254.169.254/latest/meta-data/placement/region")
else
  # Fallback: try IMDSv1
  REGION=$(curl -sf "http://169.254.169.254/latest/meta-data/placement/region" || echo "ap-south-1")
fi

echo "Region: $REGION"
echo "Master IP: $MASTER_IP"

# ── Install AWS CLI if missing ─────────────────────────────────
yum install -y aws-cli 2>/dev/null || true

# ── Wait for master to publish token to SSM ───────────────────
K3S_TOKEN=""
echo "Waiting for k3s node token in SSM..."
for i in $(seq 1 40); do
  K3S_TOKEN=$(aws ssm get-parameter \
    --name "/k3s/node-token" \
    --region "$REGION" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

  if [ -n "$K3S_TOKEN" ] && [ "$K3S_TOKEN" != "None" ]; then
    echo "Got token from SSM (attempt $i)"
    break
  fi
  echo "Attempt $i/40 — token not ready yet, waiting 15s..."
  sleep 15
done

if [ -z "$K3S_TOKEN" ] || [ "$K3S_TOKEN" = "None" ]; then
  echo "ERROR: Could not get k3s token from SSM after 10 minutes"
  exit 1
fi

# ── Wait for master API server to be reachable ────────────────
echo "Waiting for master API at https://$MASTER_IP:6443 ..."
for i in $(seq 1 30); do
  if curl -sk --max-time 5 "https://$MASTER_IP:6443/ping" 2>/dev/null; then
    echo "Master API reachable (attempt $i)"
    break
  fi
  echo "Attempt $i/30 — master not reachable yet, waiting 10s..."
  sleep 10
done

# ── Join the k3s cluster as an agent (worker) ─────────────────
echo "Joining cluster..."
curl -sfL https://get.k3s.io | \
  K3S_URL="https://$MASTER_IP:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh -s - agent \
  --node-label "role=worker"

echo "Worker joined the k3s cluster successfully"
