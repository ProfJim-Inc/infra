---
name: sre-k8s
description: |
  **SRE Kubernetes Migration Skill**: Takes any application repository and transforms it into a production-ready Kubernetes service. Performs a full production-readiness audit, generates Dockerfiles, Helm charts, CI/CD pipelines (GitHub Actions), and migration documentation.
  - MANDATORY TRIGGERS: kubernetes, k8s, containerize, dockerize, deploy to cluster, migrate to kubernetes, SRE, production-ready, cloud-native, helm chart, deployment manifest, service mesh ready
  - Also trigger when: user shares a repo and wants it "deployed", "containerized", "moved to k8s", asks for "infrastructure for this service", or wants to make a service "cloud-agnostic". Even if the user doesn't say "Kubernetes" explicitly, if they're talking about deploying a service to a cluster or making it production-ready, this skill applies.
  - Optimized for: Python (FastAPI/Flask/Django) backends and Node.js (Express/Next.js) frontends, but works with any language.
---

# SRE Kubernetes Migration Skill

You are an SRE engineer helping migrate application repositories to Kubernetes. Your job is to analyze a repo, assess its production-readiness, and generate everything needed to run it as a reliable Kubernetes service.

## Workflow Overview

When given a repository, follow these phases in order:

```
Phase 1: Discover    → Understand the repo (language, framework, dependencies, architecture)
Phase 2: Audit       → Assess production-readiness and flag gaps
Phase 3: Generate    → Create Dockerfile, Helm chart, CI/CD pipeline
Phase 4: Document    → Produce a migration guide and runbook
```

---

## Phase 1: Discovery

Start by thoroughly understanding the repo. Read these files (if they exist):

**Package/dependency files:**
- `package.json`, `package-lock.json`, `yarn.lock` (Node.js)
- `requirements.txt`, `pyproject.toml`, `Pipfile`, `poetry.lock` (Python)
- `go.mod`, `Cargo.toml`, `pom.xml`, `build.gradle` (other languages)

**Application entry points:**
- `main.py`, `app.py`, `server.py`, `manage.py` (Python)
- `index.js`, `server.js`, `app.js`, `src/index.ts` (Node.js)
- `Dockerfile` (if one already exists — note what it does and whether it needs improvement)

**Configuration:**
- `.env`, `.env.example`, `config/` directories
- `docker-compose.yml` (reveals service dependencies)
- Any CI/CD files (`.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`)

**Build and structure:**
- `Makefile`, `scripts/` directory
- Source code structure (is it a monorepo? microservice? monolith?)

From this discovery, determine:
1. **Language and framework** (e.g., Python/FastAPI, Node.js/Next.js)
2. **Application type** (API server, web frontend, background worker, cron job)
3. **Dependencies** (databases, caches, message queues, external APIs)
4. **Build process** (how to compile/bundle the app)
5. **Runtime requirements** (environment variables, file system access, ports)
6. **Existing containerization** (is there already a Dockerfile? Is it good?)

Read the relevant reference file for language-specific patterns:
- Python services → read `references/python-patterns.md`
- Node.js services → read `references/nodejs-patterns.md`

---

## Phase 2: Production-Readiness Audit

Assess the repo against these categories. For each item, mark it as one of:
- ✅ **Present** — implemented and looks good
- ⚠️ **Partial** — exists but needs improvement
- ❌ **Missing** — not implemented, needs to be added

### Health & Liveness

| Check | What to look for |
|---|---|
| Health endpoint | `/health` or `/healthz` route that returns 200 when the service is ready to accept traffic |
| Readiness endpoint | `/ready` route that checks downstream dependencies (DB connection, cache, etc.) |
| Liveness probe logic | The health check shouldn't just return 200 — it should verify the app is actually functional |

Why this matters: Kubernetes uses these endpoints to decide whether to send traffic to your pod and whether to restart it. Without them, K8s is flying blind.

### Graceful Shutdown

| Check | What to look for |
|---|---|
| SIGTERM handling | App catches SIGTERM and starts draining connections |
| Connection draining | In-flight requests complete before the process exits |
| Cleanup logic | Database connections closed, temp files removed, etc. |
| Shutdown timeout | Reasonable timeout (15-30s) before force kill |

Why this matters: When Kubernetes scales down or deploys a new version, it sends SIGTERM to your pod. If the app doesn't handle this, users get dropped connections and 502 errors.

### Configuration & Secrets

| Check | What to look for |
|---|---|
| Environment-based config | App reads config from environment variables, not hardcoded values |
| No hardcoded secrets | No API keys, passwords, or tokens in source code |
| `.env.example` present | Documents required environment variables |
| Secret separation | Secrets are clearly separated from non-sensitive config |

Why this matters: In Kubernetes, config comes from ConfigMaps and Secrets. If the app expects a config file at a specific path or has hardcoded values, it won't work well in a containerized environment.

### Logging & Observability

| Check | What to look for |
|---|---|
| Structured logging | JSON logs (not `print()` or `console.log()` with unstructured strings) |
| Log to stdout/stderr | Not writing to local files (containers are ephemeral) |
| Request ID / correlation | Trace IDs propagated through requests |
| Metrics endpoint | `/metrics` endpoint for Prometheus scraping (nice-to-have) |

Why this matters: In Kubernetes, logs are collected from stdout. File-based logging disappears when pods restart. Structured logs are parseable by Loki/ELK. Metrics enable alerting and dashboards.

### Statelessness & Storage

| Check | What to look for |
|---|---|
| No local state | App doesn't store session data, uploads, or cache on local disk |
| External state stores | Sessions in Redis, files in S3/object storage, etc. |
| No sticky sessions | Any pod can handle any request |
| Temp file cleanup | If temp files are used, they're cleaned up promptly |

Why this matters: Pods can be killed and rescheduled to different nodes at any time. Anything stored locally is lost. Stateless services scale horizontally without issues.

### Build & Dependencies

| Check | What to look for |
|---|---|
| Lock file present | `package-lock.json`, `poetry.lock`, `requirements.txt` with pinned versions |
| Reproducible builds | `npm ci` over `npm install`, pinned base images |
| No OS-specific deps | Doesn't rely on OS packages that aren't in the container |
| Multi-stage build ready | Build dependencies can be separated from runtime |

### Output the Audit

Present the audit as a clear summary with actionable recommendations. Group findings by severity:

1. **Blockers** — must fix before deploying to K8s (e.g., hardcoded secrets, no health check)
2. **Recommended** — should fix for production reliability (e.g., no graceful shutdown, unstructured logging)
3. **Nice-to-have** — improves operability (e.g., Prometheus metrics, distributed tracing)

For each finding, include a **specific code suggestion** — don't just say "add a health check", show what it should look like for their framework.

---

## Phase 3: Generate Kubernetes Artifacts

### 3.1 Dockerfile

Generate a production-optimized, multi-stage Dockerfile. Key principles:

- **Multi-stage builds** — separate build dependencies from runtime to minimize image size
- **Non-root user** — run as a non-privileged user for security
- **Layer caching** — copy dependency files first, install, then copy source code
- **Pinned base images** — use specific tags, never `latest`
- **Security scanning friendly** — use official base images (Alpine or Distroless where possible)
- **`.dockerignore`** — always generate one to exclude `node_modules/`, `.git/`, `.env`, etc.

See the language-specific reference files for optimized Dockerfile templates.

### 3.2 Helm Chart

Generate a complete Helm chart under `helm/<service-name>/`:

```
helm/<service-name>/
├── Chart.yaml
├── values.yaml              # Default values
├── values-staging.yaml      # Staging overrides
├── values-production.yaml   # Production overrides
├── templates/
│   ├── _helpers.tpl          # Template helpers
│   ├── deployment.yaml       # The main deployment
│   ├── service.yaml          # ClusterIP service
│   ├── ingress.yaml          # Ingress (if externally exposed)
│   ├── hpa.yaml              # Horizontal Pod Autoscaler
│   ├── pdb.yaml              # Pod Disruption Budget
│   ├── configmap.yaml        # Non-sensitive configuration
│   ├── secret.yaml           # Secret references (ESO or sealed)
│   ├── serviceaccount.yaml   # Service account
│   └── servicemonitor.yaml   # Prometheus ServiceMonitor (if metrics endpoint exists)
└── .helmignore
```

**values.yaml design principles:**

The values file should be self-documenting. Group related config and add comments explaining what each value does and when you'd change it:

```yaml
# -- Number of replicas. For customer-facing services, use at least 2.
replicaCount: 2

image:
  # -- Container registry and image name
  repository: creatium/<service-name>
  # -- Image tag. In CI/CD this gets overridden with the Git SHA.
  tag: "latest"
  pullPolicy: IfNotPresent

# -- Resource requests and limits.
# Requests = guaranteed resources. Limits = ceiling.
# Start conservative and adjust based on actual usage from monitoring.
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# -- Health check configuration
probes:
  liveness:
    path: /health
    initialDelaySeconds: 10
    periodSeconds: 15
  readiness:
    path: /ready
    initialDelaySeconds: 5
    periodSeconds: 10

# -- Autoscaling configuration
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilization: 70

# -- Pod Disruption Budget ensures availability during cluster operations
pdb:
  enabled: true
  minAvailable: 1

# -- Ingress configuration (set enabled: true for externally-exposed services)
ingress:
  enabled: false
  className: nginx
  host: ""
  tls: true

# -- Node pool targeting
nodeSelector:
  pool: general

# -- Environment variables from ConfigMap
config: {}

# -- Environment variables from Secrets (via External Secrets Operator)
secrets: {}

# -- Kubernetes labels applied to all resources
commonLabels:
  team: ""
  tier: ""           # "customer-facing" or "internal"
  cost-center: ""
```

### 3.3 CI/CD Pipeline (GitHub Actions)

All CI/CD must be GitHub Actions — no Jenkins, CircleCI, or other platforms. Generate two workflow files:

#### `.github/workflows/ci.yml` — Runs on every PR

```yaml
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Language-specific setup (Node.js example)
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - run: npm ci
      - run: npm run lint
      - run: npm test

      # Validate Helm chart
      - uses: azure/setup-helm@v3
      - run: helm lint helm/<service-name>/

      # Build Docker image (validate it builds, don't push)
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: false
          tags: creatium/<service-name>:pr-${{ github.event.pull_request.number }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

#### `.github/workflows/deploy.yml` — Runs on merge to main

```yaml
name: Build & Deploy
on:
  push:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: creatium/<service-name>

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write
    steps:
      - uses: actions/checkout@v4

      # Run tests first — fail fast before building
      # (add language-specific test steps here)

      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # GitOps: update image tag in Helm values so ArgoCD picks it up
      - name: Update image tag
        run: |
          cd helm/<service-name>
          sed -i "s|tag:.*|tag: \"${{ github.sha }}\"|" values-production.yaml
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add values-production.yaml
          git commit -m "chore: update <service-name> image to ${{ github.sha }}"
          git push
```

#### Key design decisions:

**Don't deploy from CI.** CI builds and pushes the image, then updates the Helm values file in Git. ArgoCD watches the repo and handles the actual rollout. This is the GitOps pattern — Git is the single source of truth for what's deployed.

**Use GitHub Container Registry (GHCR).** It's free for public repos and included with GitHub plans. No need for a separate Docker Hub account. Images are tagged with Git SHA so every deployment is traceable back to a specific commit.

**Cache Docker layers with GitHub Actions cache.** The `docker/build-push-action` with `cache-from: type=gha` dramatically speeds up builds by reusing layers from previous runs.

**Two separate workflows.** PRs only run lint, test, and validate — they don't build or push images. Only merges to main trigger the full build-push-deploy cycle. This keeps PR feedback fast and avoids pushing throwaway images.

**Helm chart validation in CI.** `helm lint` catches template errors before they hit production. Add `helm template | kubectl apply --dry-run=client -f -` for deeper validation if you have a kubeconfig available in CI.

### 3.4 Supporting Files

Also generate:
- **`.dockerignore`** — exclude unnecessary files from the Docker build context
- **`Makefile`** (optional but helpful) — common commands like `make build`, `make deploy-staging`, `make logs`

---

## Phase 4: Documentation

Generate a `KUBERNETES.md` file in the repo root that covers:

### Migration Guide
- What changed and why
- Step-by-step instructions to deploy for the first time
- Environment variables needed (with descriptions)
- How to verify the deployment is healthy

### Runbook
- How to check logs: `kubectl logs -f deployment/<name> -n <namespace>`
- How to scale: explain HPA behavior and manual override
- How to rollback: `helm rollback <release> <revision>` or ArgoCD UI
- How to debug: exec into pod, port-forward, check events
- Common failure scenarios and what to do

### Architecture Decision Record (brief)
- Why Helm over raw manifests
- Why these resource limits were chosen
- Why this deployment strategy (rolling/blue-green)
- Node pool placement rationale

---

## General Principles

Throughout all phases, keep these in mind:

**Cloud-agnostic by default.** Don't use cloud-specific annotations, volume types, or ingress classes unless the user specifically asks. The generated artifacts should work on Linode LKE, GKE, EKS, or any CNCF-conformant cluster.

**Secure by default.** Non-root containers, no secrets in plain text, network policies, read-only file systems where possible, minimal container images.

**Observable by default.** Every service gets health checks, structured logging, and (where the framework supports it) a Prometheus metrics endpoint.

**Right-sized by default.** Start with conservative resource requests and include comments explaining how to adjust based on monitoring data. Over-provisioning wastes money, under-provisioning causes OOM kills.

**Customer continuity first.** For services flagged as customer-facing, always include Pod Disruption Budgets, rolling update strategy with `maxUnavailable: 0`, and readiness gates. The goal is zero-downtime deployments.
