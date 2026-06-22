# Architecture & Code Walkthrough
## Multi-Node Kubernetes CI/CD Project on AWS

---

## Table of Contents

1. [Big Picture](#1-big-picture)
2. [Traffic Flow](#2-traffic-flow)
3. [Folder Structure](#3-folder-structure)
4. [Layer by Layer Breakdown](#4-layer-by-layer-breakdown)
   - [Application Code](#41-application-code-backend--frontend)
   - [Docker](#42-docker)
   - [Terraform — Infrastructure](#43-terraform--infrastructure)
   - [Kubernetes Manifests](#44-kubernetes-manifests-k8s)
   - [Helm Chart](#45-helm-chart-backend-chart)
   - [GitHub Actions CI/CD](#46-github-actions-cicd)
5. [How Everything Connects](#5-how-everything-connects)
6. [Key Concepts Explained](#6-key-concepts-explained)
7. [Cost Breakdown](#7-cost-breakdown)
8. [Secrets Reference](#8-secrets-reference)

---

## 1. Big Picture

This project demonstrates a **production-style DevOps pipeline** from code to running app.
The goal is simple: you push code → everything else is automated.

```
Developer
   │
   │  git push (multi-node-k8s branch)
   ▼
GitHub Actions (CI/CD)
   │
   ├── Builds 4 Docker images
   ├── Pushes to Docker Hub
   └── SSHes into AWS EC2 master node
           │
           └── Applies Kubernetes manifests
                    │
           ┌────────┴──────────────────────┐
           │   AWS NLB (Load Balancer)      │
           │   Routes port 80 traffic       │
           └────────┬──────────────────────┘
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
  k3s Master    Worker 1    Worker 2
  (t3.small)   (t3.small)  (t3.small)
       │
  nginx-ingress
       │
  ┌────┼──────────────────┐
  ▼    ▼                  ▼
  /  /api/service1   /api/service2
  │  /api/service3
  │
Frontend       3 Backend Microservices
(2 pods)       (3 pods each = 9 pods total)
```

---

## 2. Traffic Flow

Here is exactly what happens when a user opens the app in a browser:

```
User browser
    │
    │  HTTP request to NLB DNS name
    ▼
AWS Network Load Balancer
    │  Forwards to port 30080 on any healthy EC2 node
    ▼
nginx-ingress controller (NodePort 30080)
    │
    │  Reads the Ingress rules:
    │    /              → frontend-service:80
    │    /api/service1  → service1:5000
    │    /api/service2  → service2:5001
    │    /api/service3  → service3:5002
    ▼
ClusterIP Service (internal Kubernetes routing)
    │
    │  Kubernetes picks one healthy pod via round-robin
    ▼
Pod (one of 2-3 replicas, spread across nodes)
    │
    ▼
Response back to user
```

Key point: **the NLB doesn't know about your services**. It just forwards raw TCP to the nodes.
nginx-ingress is the actual HTTP router inside the cluster.

---

## 3. Folder Structure

```
devops-K8s-CICD-project/
│
├── .github/
│   └── workflows/
│       └── deploy.yml          ← CI/CD pipeline (GitHub Actions)
│
├── backend/
│   ├── service1/               ← Order Service (Flask, port 5000)
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   ├── service2/               ← User Service (Flask, port 5001)
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── service3/               ← Product Service (Flask, port 5002)
│       ├── app.py
│       ├── Dockerfile
│       └── requirements.txt
│
├── frontend/
│   ├── index.html              ← Single page UI (calls all 3 APIs)
│   └── Dockerfile              ← nginx serving the HTML
│
├── k8s/                        ← Raw Kubernetes manifests
│   ├── backend.yaml            ← 3 Deployments (service1/2/3), 3 replicas each
│   ├── backend-service.yaml    ← 3 ClusterIP Services for backend pods
│   ├── frontend.yaml           ← Frontend Deployment, 2 replicas
│   ├── service.yaml            ← ClusterIP Service for frontend
│   └── ingress.yml             ← nginx-ingress routing rules
│
├── backend-chart/              ← Helm chart (used by ArgoCD for GitOps)
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── hpa.yaml
│
└── terraform/                  ← Infrastructure as Code
    ├── main.tf                 ← All AWS resources defined here
    ├── master-install.sh       ← Bootstrap script for master node
    └── worker-install.sh       ← Bootstrap script for worker nodes
```

---

## 4. Layer by Layer Breakdown

---

### 4.1 Application Code (Backend & Frontend)

#### `backend/service1/app.py` — Order Service

```python
from flask import Flask, jsonify
import os, socket

app = Flask(__name__)

@app.route('/api/service1')       # URL path this service handles
def home():
    return jsonify({
        "service": "service1",
        "version": os.environ.get("APP_VERSION", "v1"),   # read from env var
        "message": "Hello from Service 1 - Order Service",
        "host": socket.gethostname()    # shows WHICH pod responded
    })

@app.route('/health')             # used by Kubernetes liveness/readiness probes
def health():
    return jsonify({"status": "healthy", "service": "service1"})
```

**Why `socket.gethostname()`?**
Each pod has a unique hostname. When you call the API multiple times, you'll see different hostnames — this proves load balancing is working across the 3 replicas.

**Why a `/health` endpoint?**
Kubernetes needs a way to know if a pod is alive. It calls `/health` every few seconds. If it returns anything other than 200, Kubernetes restarts that pod.

`service2/app.py` and `service3/app.py` are identical in structure, just with different service names, ports (5001, 5002), and descriptions (User Service, Product Service).

---

#### `frontend/index.html`

A single HTML page with JavaScript that calls all 3 backend APIs using `fetch()`.
When you click a button, it hits `/api/service1` (or 2/3) and shows the JSON response.
This proves end-to-end connectivity: browser → NLB → ingress → pod.

---

### 4.2 Docker

#### `backend/service1/Dockerfile`

```dockerfile
FROM python:3.9-slim      # slim = smaller image (~50MB vs ~900MB for full python)
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt   # install deps first (layer cache)
COPY . .                  # copy app code last (changes more often than deps)
EXPOSE 5000
CMD ["python", "app.py"]
```

**Why copy requirements.txt before the rest of the code?**
Docker builds in layers. If you copy all files first, every code change invalidates the pip install layer and re-downloads all packages. Copying requirements.txt separately means pip only re-runs when dependencies actually change — much faster builds.

`service2/Dockerfile` and `service3/Dockerfile` follow the same pattern, just with ports 5001 and 5002.

#### `frontend/Dockerfile`

```dockerfile
FROM nginx:1.25-alpine    # tiny nginx, just ~7MB
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

nginx serves static files with zero configuration needed. Dead simple.

#### `backend/service*/requirements.txt`

```
flask==3.0.3
```

Pinned to an exact version. This ensures the same version is installed every time — no surprise breakage from a minor update.

---

### 4.3 Terraform — Infrastructure

All AWS resources live in `terraform/main.tf`. Here's what gets created and why.

#### Provider & Region

```hcl
provider "aws" {
  region = "ap-south-1"    # Mumbai — closest to India
}
```

#### IAM Role (SSM access)

```hcl
resource "aws_iam_role" "k3s_role" { ... }
resource "aws_iam_role_policy" "k3s_ssm_policy" { ... }
resource "aws_iam_instance_profile" "k3s_profile" { ... }
```

**Why does this exist?**
The master node needs to write the k3s join token to AWS SSM Parameter Store.
The worker nodes need to read that token to join the cluster.
This IAM role gives EC2 instances permission to do that — without hardcoding any credentials.

The policy grants only the minimum needed:
```
ssm:PutParameter   → master writes the token
ssm:GetParameter   → workers read the token
ssm:DeleteParameter → cleanup
```
Only on path `/k3s/*` — not every SSM parameter in the account.

#### Security Group

```hcl
resource "aws_security_group" "k8s_sg" {
  ingress port 22    → SSH (you connecting to manage the cluster)
  ingress port 80    → HTTP traffic
  ingress port 443   → HTTPS traffic
  ingress port 6443  → k3s API server (workers talk to master here)
  ingress port 8472  → Flannel VXLAN (pod-to-pod traffic across nodes)
  ingress port 10250 → Kubelet (node health reporting)
  ingress port 30000-32767 → NodePort range (nginx-ingress lives here)
  egress  all        → nodes can reach internet (to pull images etc.)
}
```

**Ports 8472 and 6443 are new compared to the original project.**
These are required for multi-node clusters. Pods on Worker 1 need to talk to pods on Worker 2 via Flannel (port 8472). Workers register with the master API (port 6443).

#### EC2 Instances

```hcl
# 1 master
resource "aws_instance" "k3s_master" {
  instance_type    = "t3.small"   # 2 vCPU, 2GB RAM
  user_data        = file("master-install.sh")   # runs on first boot
  iam_instance_profile = aws_iam_instance_profile.k3s_profile.name
}

# 2 workers (count = 2, so Terraform creates both)
resource "aws_instance" "k3s_workers" {
  count     = var.worker_count   # default 2
  user_data = templatefile("worker-install.sh", {
    master_private_ip = aws_instance.k3s_master.private_ip
  })
  depends_on = [aws_instance.k3s_master]   # workers wait for master to exist first
}
```

`templatefile()` is how Terraform injects the master's private IP into the worker script.
`depends_on` ensures Terraform provisions master first — without this, workers might start before the master IP is known.

#### AWS Network Load Balancer

```hcl
resource "aws_lb" "k8s_nlb" {
  load_balancer_type = "network"   # Layer 4, TCP — fast and simple
  subnets            = data.aws_subnets.default.ids   # spans all AZs
}
```

**Why NLB and not ALB (Application Load Balancer)?**
- NLB works at TCP level — lower latency, no HTTP parsing overhead
- Ingress (nginx) handles all the HTTP routing inside the cluster
- NLB is simpler and cheaper (~$0.008/LCU-hr vs ALB's ~$0.008/LCU-hr but with more LCUs)

```hcl
# Target group points to NodePort 30080 (where nginx-ingress listens)
resource "aws_lb_target_group" "http_tg" {
  port     = 30080
  protocol = "TCP"
  health_check { port = "30080" }
}

# All 3 nodes (master + 2 workers) are registered as targets
resource "aws_lb_target_group_attachment" "master_http" { ... }
resource "aws_lb_target_group_attachment" "workers_http" { count = 2 ... }
```

The NLB health-checks each node on port 30080. If a node goes down, it's automatically removed from rotation.

#### Outputs

```hcl
output "master_public_ip" { ... }   # you need this for SSH and ArgoCD
output "worker_public_ips" { ... }  # useful for debugging
output "nlb_dns_name" { ... }       # this is your app's public URL
```

After `terraform apply`, you'll see these values printed. The `nlb_dns_name` is what you share with users.

---

#### `terraform/master-install.sh`

This script runs automatically when the master EC2 instance first boots (via `user_data`).

```bash
# 1. Install k3s in server mode, with traefik disabled
#    (we use nginx-ingress instead of traefik)
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --write-kubeconfig-mode=644

# 2. Wait until k3s is actually ready before proceeding
until kubectl get nodes | grep -q "Ready"; do sleep 5; done

# 3. Publish the join token to SSM so workers can read it
TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
aws ssm put-parameter --name "/k3s/node-token" --value "$TOKEN" --type "SecureString"

# 4. Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 5. Install nginx-ingress on fixed NodePorts
#    30080 = HTTP, 30443 = HTTPS
#    These match what the NLB target groups point to
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443
```

**Why fixed NodePorts (30080, 30443)?**
By default Kubernetes assigns a random NodePort. The NLB target groups are configured to forward to 30080 specifically, so we pin it to avoid mismatch.

---

#### `terraform/worker-install.sh`

```bash
# master_private_ip is injected by Terraform's templatefile()
MASTER_IP="${master_private_ip}"

# 1. Wait for master to publish the token to SSM
TOKEN=""
until [ -n "$TOKEN" ]; do
  TOKEN=$(aws ssm get-parameter --name "/k3s/node-token" --query "Parameter.Value" ...)
  sleep 15
done

# 2. Wait for master API to be reachable
until curl -sk "https://$MASTER_IP:6443/ping"; do sleep 10; done

# 3. Join the cluster as an agent (worker)
curl -sfL https://get.k3s.io | K3S_URL="https://$MASTER_IP:6443" K3S_TOKEN="$TOKEN" sh -s - agent
```

This is why SSM is needed — workers boot in parallel with the master and need a safe, shared place to pick up the join token without any manual intervention.

---

### 4.4 Kubernetes Manifests (`k8s/`)

#### `k8s/backend.yaml` — Deployments

Three separate Deployments, one per service. Here's the key parts explained for service1 (service2 and service3 are identical in structure):

```yaml
spec:
  replicas: 3       # 3 pods running at all times

  # topologySpreadConstraints ensures pods are spread across nodes
  # maxSkew: 1 means no node can have more than 1 extra pod vs others
  # This prevents all 3 replicas landing on the same node
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule

  containers:
    - image: sourabhjha108/service1:latest
      resources:
        requests:           # guaranteed resources
          cpu: "100m"       # 100 millicores = 0.1 CPU
          memory: "128Mi"
        limits:             # hard ceiling — pod killed if exceeded
          cpu: "250m"
          memory: "256Mi"

      livenessProbe:        # if this fails → pod restarted
        httpGet:
          path: /health
          port: 5000
        initialDelaySeconds: 10    # wait 10s before first check (startup time)
        periodSeconds: 15

      readinessProbe:       # if this fails → pod removed from load balancing
        httpGet:            # but NOT restarted (use for warm-up periods)
          path: /health
          port: 5000
```

**Liveness vs Readiness probe — what's the difference?**
- Liveness: "Is this pod alive?" → fail = restart the pod
- Readiness: "Is this pod ready to serve traffic?" → fail = remove from service, but don't restart

#### `k8s/backend-service.yaml` — Services

```yaml
apiVersion: v1
kind: Service
metadata:
  name: service1
spec:
  type: ClusterIP        # internal only, not accessible from outside cluster
  selector:
    app: service1        # targets any pod with this label
  ports:
    - port: 5000         # the port OTHER services use to reach this service
      targetPort: 5000   # the port the pod is actually listening on
```

ClusterIP gives service1 a stable internal IP. Even as pods come and go (restarts, scaling), the service IP stays the same. nginx-ingress uses this stable name `service1:5000` in its routing rules.

#### `k8s/ingress.yml` — Routing Rules

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: "nginx"              # use nginx controller
    nginx.ingress.kubernetes.io/rewrite-target: /     # strip the path prefix

spec:
  rules:
    - http:
        paths:
          - path: /api/service1
            backend:
              service:
                name: service1     # matches the Service name above
                port:
                  number: 5000
          - path: /
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

**Why is ingress separate from the Service?**
The Service handles internal cluster routing. The Ingress handles external HTTP routing. This separation means you can change routing rules without touching the services, and add TLS/auth/rate-limiting at the ingress level without changing pods.

---

### 4.5 Helm Chart (`backend-chart/`)

The Helm chart is a **reusable, parameterized** version of the K8s manifests.
While the raw `k8s/` manifests are applied directly by the CI/CD pipeline, this chart is used by **ArgoCD** for GitOps-style continuous deployment.

#### `Chart.yaml`

```yaml
name: backend-chart
version: 0.1.0        # chart version — bump this when chart structure changes
appVersion: "1.16.0"  # app version — bump this when app code changes
```

#### `values.yaml`

This is the control panel for the chart. Instead of editing YAML templates directly, you change values here:

```yaml
replicaCount: 1           # override to 3 for production
image:
  repository: nginx       # override to sourabhjha108/service1
  tag: ""                 # override to specific version

autoscaling:
  enabled: false          # set true to enable HPA
  minReplicas: 1
  maxReplicas: 100
  targetCPUUtilizationPercentage: 80
```

#### `templates/deployment.yaml`

The Helm template uses `{{ .Values.xxx }}` to inject values:

```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
replicas: {{ .Values.replicaCount }}
```

When ArgoCD deploys using Helm, it renders these templates with the values from `values.yaml` (or overrides you specify) and applies the resulting YAML to Kubernetes.

#### `templates/hpa.yaml` — Horizontal Pod Autoscaler

```yaml
{{- if .Values.autoscaling.enabled }}   # only created if enabled
spec:
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          averageUtilization: 80    # scale up when CPU > 80%
{{- end }}
```

When enabled, Kubernetes automatically adds/removes pods based on CPU load.

---

### 4.6 GitHub Actions CI/CD

#### `.github/workflows/deploy.yml`

Triggered on every push to the `multi-node-k8s` branch.
Three jobs run in sequence:

```
build → deploy → smoke-test
```

**Job 1: build**
```yaml
- name: Build & Push service1
  run: |
    docker build -t $DOCKER_USER/service1:latest \
                 -t $DOCKER_USER/service1:${{ github.sha }} \   # also tag with commit SHA
                 ./backend/service1
    docker push $DOCKER_USER/service1:latest
    docker push $DOCKER_USER/service1:${{ github.sha }}
```

Tagging with `github.sha` (the commit hash) means every build is traceable. You can always roll back to `service1:abc1234` if `latest` breaks.

**Job 2: deploy**

Step 1 — SSH into master, install ArgoCD (if not already installed):
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Wait for ArgoCD to be ready, then expose as NodePort
```

Step 2 — Copy manifests to master via SCP, then apply them:
```bash
kubectl apply -f k8s/backend-service.yaml   # services first
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/backend.yaml           # then deployments
kubectl apply -f k8s/frontend.yaml
kubectl apply -f k8s/ingress.yml            # then ingress

kubectl rollout restart deployment/service1   # force pods to pull latest image
kubectl rollout status deployment/service1    # wait until rollout is complete
```

`rollout restart` is needed because the image tag is `latest`. Kubernetes won't re-pull an image just because the remote changed — you have to tell it to restart.

**Job 3: smoke-test**
```bash
for path in "/" "/api/service1" "/api/service2" "/api/service3"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$NLB_DNS$path")
  echo "$path → HTTP $STATUS"
done
```

A basic sanity check that every endpoint returns HTTP 200 after deployment.

---

## 5. How Everything Connects

Here's a step-by-step of what happens from zero to a running app:

```
Step 1 — terraform apply
  │  Creates: EC2 master + 2 workers, security group, IAM role, NLB
  │  master-install.sh runs on master → installs k3s + nginx-ingress
  │  worker-install.sh runs on workers → reads SSM token → joins cluster
  └─▶ Result: 3-node k3s cluster, NLB ready

Step 2 — git push to multi-node-k8s
  │  GitHub Actions triggers
  │  Job 1: builds 4 Docker images → pushes to Docker Hub
  │  Job 2: SSHes into master
  │    - Installs ArgoCD
  │    - Copies k8s/ manifests
  │    - kubectl apply → Kubernetes creates pods across all 3 nodes
  │    - kubectl rollout restart → pods pull latest images
  └─▶ Result: 11 pods running (3+3+3 backend + 2 frontend)

Step 3 — user opens browser
  │  Request hits NLB DNS name
  │  NLB forwards TCP to port 30080 on a random healthy node
  │  nginx-ingress reads Ingress rules, routes to correct service
  │  ClusterIP service load-balances across pods
  └─▶ Result: response from one of the replicas
```

---

## 6. Key Concepts Explained

### Why k3s instead of full Kubernetes?
k3s is a lightweight Kubernetes distribution. It runs on a single binary, works great on t3.small instances, and starts in seconds. Full Kubernetes (kubeadm) needs more RAM and setup steps. For a 3-node demo cluster, k3s is the right choice.

### Why topologySpreadConstraints?
Without this, Kubernetes might schedule all 3 replicas of service1 on the same node. If that node goes down, all 3 pods are lost at once. `topologySpreadConstraints` forces Kubernetes to spread pods across different nodes (identified by `kubernetes.io/hostname`).

### What is GitOps (ArgoCD)?
Traditional CI/CD: pipeline directly runs `kubectl apply`.
GitOps: ArgoCD watches the Git repo. When manifests change in Git, ArgoCD detects the drift and syncs the cluster to match. The Git repo becomes the single source of truth for cluster state.

### Why SSM Parameter Store for the k3s token?
The worker nodes need the master's join token, but they boot in parallel with the master and can't SSH into it. SSM is a secure, managed key-value store that both can access via IAM. No passwords, no hardcoded tokens, no manual steps.

### ClusterIP vs NodePort vs LoadBalancer service types
| Type         | Accessible from        | Use case                              |
|--------------|------------------------|---------------------------------------|
| ClusterIP    | Inside cluster only    | Service-to-service communication      |
| NodePort     | Outside via node IP    | Direct access, used by nginx-ingress  |
| LoadBalancer | Outside via cloud LB   | AWS ALB/NLB auto-provisioning         |

We use ClusterIP for all app services (internal only) and let nginx-ingress + NLB handle external access. This is cleaner than making every service a LoadBalancer (which would create one AWS LB per service — expensive).

---

## 7. Cost Breakdown (ap-south-1, Mumbai)

| Resource            | Spec           | Count | $/hr    | $/month  |
|---------------------|----------------|-------|---------|----------|
| EC2 t3.small        | 2 vCPU, 2GB    | 3     | $0.023  | ~$50     |
| NLB                 | Network LB     | 1     | $0.008+ | ~$6      |
| EBS gp2             | 20 GB each     | 3     | —       | ~$6      |
| SSM Parameter Store | SecureString   | 1     | Free    | $0       |
| **Total**           |                |       |         | **~$62** |

> Stop your EC2 instances when not testing to avoid charges.
> NLB has a small base charge even when idle (~$0.008/hr = ~$5.76/month).

---

## 8. Secrets Reference

These must be added to GitHub → Settings → Secrets → Actions:

| Secret Name       | What it is                              | How to get it                     |
|-------------------|-----------------------------------------|-----------------------------------|
| `DOCKER_USER`     | Docker Hub username                     | Your Docker Hub account           |
| `DOCKER_PASS`     | Docker Hub password or access token     | Docker Hub → Account Settings     |
| `EC2_MASTER_IP`   | Public IP of the master EC2 instance    | `terraform output master_public_ip` |
| `SSH_KEY`         | Private key content of your key pair    | The `.pem` file content           |

The SSH key is the full content of `ssva_mumbai_keypair.pem` — paste the entire file including `-----BEGIN RSA PRIVATE KEY-----` lines.
