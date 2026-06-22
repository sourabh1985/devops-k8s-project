# DevOps Multi-Node K8s Project

End-to-end CI/CD pipeline deploying 3 microservices across a multi-node Kubernetes cluster on AWS.

## Architecture

```
                  ┌─────────────────────────────────────┐
  Internet ──────▶│     AWS Network Load Balancer        │
                  │   (port 80 → NodePort 30080)         │
                  └────────────┬────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
       ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
       │ k3s Master  │  │  Worker 1   │  │  Worker 2   │
       │ t3.small    │  │  t3.small   │  │  t3.small   │
       └──────┬──────┘  └─────────────┘  └─────────────┘
              │
       nginx-ingress (NodePort 30080)
              │
    ┌─────────┼──────────────────┐
    ▼         ▼                  ▼
 /            /api/service*      /api/service*
frontend    service1           service2 / service3
(2 pods)    Order Svc          User / Product Svc
            (3 pods)           (3 pods each)
```

## Stack

| Layer          | Technology                          |
|----------------|-------------------------------------|
| Infrastructure | Terraform → AWS EC2 (t3.small × 3) |
| Load Balancer  | AWS Network Load Balancer (NLB)     |
| Cluster        | k3s (1 master + 2 workers)          |
| Ingress        | nginx-ingress (NodePort 30080)      |
| GitOps         | ArgoCD                              |
| CI/CD          | GitHub Actions                      |
| Container      | Docker → Docker Hub                 |
| Backend        | Python Flask (3 services)           |
| Frontend       | nginx serving static HTML           |

## Services

| Service   | Path           | Port | Replicas | Description     |
|-----------|----------------|------|----------|-----------------|
| frontend  | `/`            | 80   | 2        | Static UI       |
| service1  | `/api/service1`| 5000 | 3        | Order Service   |
| service2  | `/api/service2`| 5001 | 3        | User Service    |
| service3  | `/api/service3`| 5002 | 3        | Product Service |

## Getting Started

### 1. Provision infrastructure

```bash
cd terraform
terraform init
terraform apply
# Outputs: master IP, worker IPs, NLB DNS name
```

> Note: Workers auto-join the master via k3s token stored in AWS SSM Parameter Store.

### 2. Add GitHub Secrets

| Secret            | Value                          |
|-------------------|-------------------------------|
| `DOCKER_USER`     | Your Docker Hub username       |
| `DOCKER_PASS`     | Your Docker Hub password/token |
| `EC2_MASTER_IP`   | Master node public IP          |
| `SSH_KEY`         | Private key for ec2-user       |

### 3. Push to trigger deployment

```bash
git push origin multi-node-k8s
```

GitHub Actions will:
1. Build & push all 4 Docker images
2. SSH into master, install ArgoCD, copy and apply all K8s manifests
3. Run a smoke test against all service endpoints

### 4. Access the app

```
http://<NLB_DNS_NAME>/              → Frontend UI
http://<NLB_DNS_NAME>/api/service1  → Order Service
http://<NLB_DNS_NAME>/api/service2  → User Service
http://<NLB_DNS_NAME>/api/service3  → Product Service
```

### 5. ArgoCD UI

```
http://<MASTER_IP>:30443
# Username: admin
# Password: kubectl get secret argocd-initial-admin-secret -n argocd \
#            -o jsonpath="{.data.password}" | base64 -d
```

## Cost Estimate (ap-south-1)

| Resource          | Count | $/hr      | $/month  |
|-------------------|-------|-----------|----------|
| EC2 t3.small      | 3     | ~$0.023   | ~$50     |
| NLB               | 1     | ~$0.008   | ~$6      |
| EBS gp2 20GB      | 3     | —         | ~$6      |
| **Total (approx)**|       |           | **~$62** |

> Tip: Stop instances when not in use to save cost.
