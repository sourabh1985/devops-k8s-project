# K8s Phase 3 — GitOps Deep Dive + Advanced Deployment Strategies

## What Changed: Phase 2 → Phase 3

---

## 1. GitOps — ArgoCD (Previously: Unused)

### Phase 2 (Before)
- ArgoCD was **installed** but **never used**
- GitHub Actions SSHed into EC2 master and ran `kubectl apply` directly
- No GitOps — git and the cluster were not connected
- Manual `kubectl rollout restart` to pull new images

```
git push → GitHub Actions → SSH → kubectl apply → cluster
```

### Phase 3 (Now)
- ArgoCD **Application CRDs** registered — ArgoCD watches this repo
- GitHub Actions only **builds images and registers apps**
- ArgoCD detects git changes and syncs the cluster automatically
- Git is the single source of truth — any manual `kubectl` change gets reverted

```
git push → GitHub Actions (build images) → ArgoCD detects diff → syncs cluster
```

**New files:**
- `argocd/app-dev.yaml` — ArgoCD Application for dev namespace
- `argocd/app-prod.yaml` — ArgoCD Application for prod namespace

---

## 2. Environment Separation (Previously: None)

### Phase 2 (Before)
- Everything in the `default` namespace
- No environment separation — dev and prod were the same thing
- All images used `:latest` tag

```
default/
  service1  (3 replicas)
  service2  (3 replicas)
  service3  (3 replicas)
  frontend  (2 replicas)
```

### Phase 3 (Now)
- Two isolated namespaces: `dev` and `prod`
- Different replica counts per environment (lean in dev, full in prod)
- `ENVIRONMENT` env var injected into each pod

```
dev/
  service1  (1 replica)   ← lightweight, fast feedback
  service2  (1 replica)
  service3  (1 replica)
  frontend  (1 replica)

prod/
  service1  (3 replicas)  ← full HA with topology spread
  service2  (3 replicas)
  service3  (3 replicas)
  frontend  (2 replicas)
```

**New files:**
- `k8s/namespaces.yaml` — creates dev and prod namespaces
- `k8s/dev/` — dev manifests (backend, frontend, services, ingress)
- `k8s/prod/` — prod manifests (backend, frontend, services, ingress)

---

## 3. Sync Policies — Auto vs Manual

### Phase 2 (Before)
- No sync policy concept — every push deployed everywhere
- No approval gate for production

### Phase 3 (Now)

| Environment | Sync Mode | Behavior |
|---|---|---|
| `dev` | **Auto-sync** | Every git push to `k8s/dev/` deploys immediately |
| `prod` | **Manual sync** | Changes wait for human approval in ArgoCD UI |

**dev auto-sync features:**
- `prune: true` — removes k8s resources deleted from git
- `selfHeal: true` — reverts manual kubectl edits back to git state

**prod manual sync:**
- Approve via ArgoCD UI: `http://<MASTER_IP>:30443`
- Or CLI: `argocd app sync app-prod`
- No automated block = intentional gate for production safety

---

## 4. Canary Deployment — service1 (Previously: Rolling Update only)

### Phase 2 (Before)
- Standard Kubernetes rolling update — replaces pods one by one
- No traffic control — all pods get 100% traffic immediately
- No way to test new version with a subset of users

### Phase 3 (Now)
- **Argo Rollouts** Canary strategy on `service1` in prod
- Traffic shifts gradually, with pause windows to observe

```
Deploy new image →
  Step 1: 20% traffic → new version  (pause 1 min)
  Step 2: 50% traffic → new version  (pause 1 min)
  Step 3: 100% traffic → new version (full rollout)
```

- If anything looks wrong during a pause → `argocd app rollback app-prod`
- Old pods kept running during ramp-up (safe rollback at any step)

**Manifest:** `k8s/prod/backend.yaml` → `kind: Rollout` for service1

---

## 5. Blue-Green Deployment — service2 (Previously: Not implemented)

### Phase 2 (Before)
- Not implemented — standard deployment only

### Phase 3 (Now)
- **Argo Rollouts** Blue-Green strategy on `service2` in prod
- Two full deployments run simultaneously during a release:
  - **Blue** = current live version (active service)
  - **Green** = new version (preview service, for QA/testing)

```
New image pushed →
  Green deployment spins up (full 3 replicas)
  Preview service → Green pods  (test here first)
  Active service  → Blue pods   (live traffic unaffected)
  
  → Manual promotion: traffic switches Blue → Green (instant)
  → Blue pods kept for 60s (instant rollback window)
  → Blue pods scale down
```

**Two services for service2:**
- `service2-active` → live traffic (always points to current stable)
- `service2-preview` → green/new version (for pre-promotion testing)

**Manifest:** `k8s/prod/backend.yaml` → `kind: Rollout` for service2

---

## 6. CI/CD Pipeline Changes

### Phase 2 Workflow (4 steps)
```
Job 1: Build & push images
Job 2: SSH → install nginx-ingress + ArgoCD
Job 3: SCP k8s manifests → SSH kubectl apply → rollout restart
Job 4: Smoke test
```

### Phase 3 Workflow (4 jobs, restructured)
```
Job 1: Build & push images (unchanged)
Job 2: Bootstrap cluster — idempotent install of:
         nginx-ingress, ArgoCD, Argo Rollouts, namespaces
Job 3: Register ArgoCD Application CRDs
         → from here ArgoCD owns all deployments
Job 4: Smoke test dev endpoints
```

Key change: **Job 3 is the last human-controlled step for prod.** After apps are registered, ArgoCD drives everything.

---

## New Tools Introduced

| Tool | Purpose | Phase introduced |
|---|---|---|
| Argo Rollouts | Canary + Blue-Green deployment controller | Phase 3 |
| ArgoCD Application CRD | GitOps sync — git → cluster | Phase 3 |
| Namespace isolation | Environment separation (dev/prod) | Phase 3 |

---

## Folder Structure Change

```
Phase 2                          Phase 3
────────────────────────         ────────────────────────────────
k8s/                             k8s/
  backend.yaml                     namespaces.yaml        ← NEW
  frontend.yaml                    dev/                   ← NEW
  backend-service.yaml               backend.yaml
  service.yaml                       frontend.yaml
  ingress.yml                        services.yaml
                                     ingress.yaml
                                   prod/                  ← NEW
                                     backend.yaml  (Rollouts)
                                     frontend.yaml
                                     services.yaml
                                     ingress.yaml
                                 argocd/                  ← NEW
                                   app-dev.yaml
                                   app-prod.yaml
```

---

## How to Promote Prod After a Git Push

1. Push code → GitHub Actions builds images and registers ArgoCD apps
2. Dev syncs automatically — check: `kubectl get pods -n dev`
3. For prod, open ArgoCD UI: `http://<MASTER_IP>:30443`
4. Click **app-prod → Sync** to deploy to prod
5. For service2 Blue-Green: click **Promote** after verifying preview service
6. For service1 Canary: Argo Rollouts auto-advances through steps; abort with `kubectl argo rollouts abort service1 -n prod` if needed

---

## Quick Reference Commands

```bash
# Watch ArgoCD sync status
kubectl get applications -n argocd

# Check dev pods
kubectl get pods -n dev

# Check prod pods + rollout status
kubectl get pods -n prod
kubectl argo rollouts status service1 -n prod
kubectl argo rollouts status service2 -n prod

# Manually promote Blue-Green (service2 prod)
kubectl argo rollouts promote service2 -n prod

# Abort a canary/blue-green rollout
kubectl argo rollouts abort service1 -n prod

# Rollback to previous version
kubectl argo rollouts undo service1 -n prod
```
