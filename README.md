# Creatium Infrastructure

> A production-grade Kubernetes platform on Linode LKE, managed with Terraform and ArgoCD GitOps.
> Includes a complete observability stack (metrics, logs, distributed traces) and a demo service
> that exercises every part of the platform.

---

## Who This Is For

This repository is designed to be readable by anyone who has heard of Kubernetes but has never set up
a production platform from scratch. Every file has comments explaining *why* a decision was made, not
just *what* it does. The goal is that after reading the README and browsing the files, you should be
able to reproduce this platform or adapt it for your own services.

No prior experience with Terraform, ArgoCD, or Helm is assumed. Key concepts are explained in the
[Glossary](#glossary) at the bottom.

---

## Table of Contents

- [What Is This?](#what-is-this)
- [The 4-Layer Architecture](#the-4-layer-architecture)
- [GitOps: The Core Philosophy](#gitops-the-core-philosophy)
- [Repository Structure](#repository-structure)
- [The Stack Components](#the-stack-components)
  - [Layer 1 — Cloud Provisioning (Terraform)](#layer-1--cloud-provisioning-terraform)
  - [Layer 2 — Kubernetes Cluster (Linode LKE)](#layer-2--kubernetes-cluster-linode-lke)
  - [Layer 3 — GitOps Controller (ArgoCD)](#layer-3--gitops-controller-argocd)
  - [Layer 4 — Application Services](#layer-4--application-services)
  - [Observability Stack](#observability-stack)
- [Node Pools: Workload Isolation](#node-pools-workload-isolation)
- [Bringing Up the Infrastructure](#bringing-up-the-infrastructure)
- [Demo Service Walkthrough](#demo-service-walkthrough)
- [Deploying Your Own Service](#deploying-your-own-service)
- [CI/CD Pipeline Explained](#cicd-pipeline-explained)
- [Alerting: End-to-End Flow](#alerting-end-to-end-flow)
- [Day-2 Operations](#day-2-operations)
- [Local Development](#local-development)
- [Cloud Migration Paths](#cloud-migration-paths)
- [Glossary](#glossary)

---

## What Is This?

This repo is the **single source of truth** for everything running in the Creatium production cluster.
It contains:

| Folder | What it contains |
|--------|-----------------|
| `terraform/` | Code that creates the Kubernetes cluster itself on Linode's cloud |
| `argocd/` | Declarations of *what* should run in the cluster and *from where* |
| `kubernetes/` | Helm charts and per-service configuration values |
| `services/` | Source code for services built and maintained in this repo |
| `.github/workflows/` | Automated CI/CD pipelines |

**The fundamental rule:** if something is not in this repository, it does not exist in production.
Want to deploy a new service? Add a file here. Want to change a resource limit? Edit a file here.
The cluster automatically reconciles itself to match whatever is in `main`.

---

## The 4-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Cloud Provisioning                                 │
│  Terraform provisions the raw Kubernetes cluster on Linode.  │
│  Runs once (or when infrastructure changes).                 │
└────────────────────────────┬────────────────────────────────┘
                             │ creates
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Kubernetes Cluster (Linode LKE)                    │
│  A managed Kubernetes cluster with 4 purpose-specific        │
│  node pools (system, general, compute, GPU).                 │
└────────────────────────────┬────────────────────────────────┘
                             │ runs
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: GitOps Controller (ArgoCD)                         │
│  Continuously watches this Git repo. Any change merged to    │
│  main is automatically applied to the cluster.               │
└────────────────────────────┬────────────────────────────────┘
                             │ deploys
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Application Services + Ops Stack                   │
│  Your actual services (FastAPI, Next.js, etc.) plus          │
│  monitoring, logging, tracing, and ingress.                  │
└─────────────────────────────────────────────────────────────┘
```

---

## GitOps: The Core Philosophy

**Traditional deployment:** you run `kubectl apply` or `helm upgrade` from your laptop or CI server.
The cluster state lives in the cluster — hard to audit, easy to drift from what's documented.

**GitOps deployment:** the cluster state lives in *this Git repository*. ArgoCD watches the repo
and continuously applies any differences. Your laptop or CI server only pushes to Git;
it never talks to the cluster directly.

```
Developer                    GitHub                      Cluster
    │                           │                           │
    ├── git push ──────────────►│                           │
    │                           │                           │
    │                           │◄── ArgoCD polls every 3m ─┤
    │                           │                           │
    │                           ├── diff: new image tag ───►│
    │                           │                           ├── kubectl apply
    │                           │                           ├── new pod starts
    │                           │                           └── old pod stops
```

**Why this matters for you:**
- Every change is a Git commit — complete audit trail, easy rollback (`git revert`)
- PR reviews catch infrastructure bugs before they hit production
- No "snowflake" clusters that differ from what's documented
- New team members can understand the entire system by reading this repo

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── helm-lint.yml              # Validates Helm charts on every PR
│   ├── terraform-plan.yml         # Shows what Terraform would change, posts to PR
│   ├── terraform-apply.yml        # Applies Terraform changes after merge to main
│   └── demo-service.yml           # Builds and deploys the demo-service
│
├── argocd/
│   ├── projects/
│   │   └── creatium.yaml          # AppProject: defines what repos/namespaces ArgoCD
│   │                              #   can touch — acts as a security boundary
│   └── applications/
│       ├── kube-prometheus-stack.yaml   # Metrics + Grafana + Alertmanager
│       ├── tempo.yaml                   # Distributed trace storage
│       ├── otel-collector.yaml          # OpenTelemetry gateway
│       ├── opensearch.yaml              # Log storage
│       ├── opensearch-dashboards.yaml   # Log exploration UI
│       ├── fluent-bit.yaml              # Log collector (runs on every node)
│       ├── ingress-nginx.yaml           # HTTP router (public traffic entry point)
│       ├── nvidia-device-plugin.yaml    # Makes GPU visible to Kubernetes
│       ├── argocd-image-updater.yaml    # Auto-updates image tags when new versions push
│       ├── demo-service.yaml            # The demo FastAPI service
│       ├── agent-backend.yaml
│       ├── agent-frontend.yaml
│       └── tts-microservice.yaml
│
├── kubernetes/
│   ├── charts/
│   │   └── creatium-service/      # A single shared Helm chart for ALL services.
│   │       │                      #   Each service provides its own values.yaml.
│   │       │                      #   This avoids copy-pasting Deployment/Service/Ingress
│   │       │                      #   boilerplate for every service.
│   │       ├── Chart.yaml
│   │       ├── values.yaml        # Defaults — safe starting point for any service
│   │       └── templates/
│   │           ├── deployment.yaml     # The main workload
│   │           ├── service.yaml        # ClusterIP service (internal routing)
│   │           ├── ingress.yaml        # Public HTTPS entry point (optional)
│   │           ├── hpa.yaml            # Horizontal Pod Autoscaler
│   │           ├── pdb.yaml            # Pod Disruption Budget (availability guarantee)
│   │           ├── configmap.yaml      # Non-secret environment variables
│   │           ├── serviceaccount.yaml # K8s RBAC identity for the pod
│   │           └── servicemonitor.yaml # Tells Prometheus how to scrape this service
│   │
│   └── base/
│       ├── agent-backend/values.yaml        # Backend API overrides
│       ├── agent-frontend/values.yaml       # Frontend overrides
│       ├── tts-microservice/values.yaml     # TTS (GPU) overrides
│       ├── demo-service/
│       │   ├── values.yaml                  # Demo service overrides
│       │   ├── alerts.yaml                  # PrometheusRule — 4 alert definitions
│       │   └── alertmanager-config.yaml     # Slack routing for those alerts
│       ├── monitoring/
│       │   ├── values.yaml                  # kube-prometheus-stack configuration
│       │   ├── tempo-values.yaml            # Grafana Tempo configuration
│       │   └── otel-collector-values.yaml   # OTeL Collector configuration
│       └── logging/
│           ├── opensearch-values.yaml
│           ├── opensearch-dashboards-values.yaml
│           ├── opensearch-dashboards-ingress.yaml
│           ├── opensearch-setup-job.yaml    # Creates ISM retention policy (runs once)
│           └── fluent-bit-values.yaml
│
├── services/
│   └── demo-service/              # Source code lives here, CI/CD builds it
│       ├── app/
│       │   ├── main.py            # FastAPI endpoints
│       │   ├── telemetry.py       # OpenTelemetry setup
│       │   └── logging_config.py  # Structured JSON logging
│       ├── Dockerfile
│       └── requirements.txt
│
└── terraform/
    ├── environments/
    │   └── linode-us/             # One folder per cloud region/environment.
    │       │                      #   To add a new region: copy this folder, change
    │       │                      #   region + cluster_name + backend key.
    │       ├── main.tf            # Declares the cluster and all node pools
    │       ├── variables.tf       # Input variables (API token, CIDR allowlist, etc.)
    │       └── terraform.tfvars.example
    └── modules/
        ├── cluster/               # Reusable module: creates one LKE cluster
        ├── node-pool/             # Reusable module: creates one node pool
        └── networking/            # Reusable module: creates firewall rules
```

---

## The Stack Components

### Layer 1 — Cloud Provisioning (Terraform)

**What it is:** Terraform is an "infrastructure as code" tool. You write `.tf` files describing the
cloud resources you want (a Kubernetes cluster, firewall rules, etc.) and Terraform figures out how
to create or update them.

**Why we use it instead of clicking in the UI:**
- Reproducible: running `terraform apply` twice produces the same result
- Auditable: every cluster change is a Git commit
- Reversible: `git revert` + `terraform apply` undoes any change

**How it works here:**

```
terraform/environments/linode-us/main.tf
    │
    ├── module "cluster"      → calls terraform/modules/cluster/
    │                           creates: linode_lke_cluster "creatium-us"
    │
    ├── module "system_pool"  → calls terraform/modules/node-pool/
    │                           creates: 2-node fixed pool for ops workloads
    │
    ├── module "general_pool" → creates: 2-8 node autoscaling pool for services
    ├── module "compute_pool" → creates: 1-5 node dedicated pool for ML
    ├── module "gpu_pool"     → creates: 1-node GPU pool for TTS inference
    └── module "networking"   → creates: Linode firewall restricting API access
```

**Terraform state:** Terraform stores what it has created in a "state file." We keep this in
Linode Object Storage (`creatium-terraform-state` bucket) so everyone on the team uses the same
state and changes don't conflict.

**Key file:** [terraform/environments/linode-us/main.tf](terraform/environments/linode-us/main.tf)

---

### Layer 2 — Kubernetes Cluster (Linode LKE)

**What it is:** Kubernetes (K8s) is a container orchestration system. You tell it "I want 3 copies
of this container image running," and it figures out which machines to run them on, restarts them
if they crash, scales them up under load, and routes network traffic between them.

**Why Linode LKE (instead of GKE/EKS/AKS)?**
- Managed control plane — Linode runs the master nodes; we only manage worker nodes
- Simpler and cheaper than GCP/AWS for small-to-medium workloads
- The Helm charts and ArgoCD config are 100% portable to any Kubernetes — migration is just a
  Terraform rewrite (see [Cloud Migration Paths](#cloud-migration-paths))

**Cluster spec:**
- Kubernetes version: 1.34
- Region: `us-ord` (Chicago)
- 4 node pools (see [Node Pools](#node-pools-workload-isolation))

---

### Layer 3 — GitOps Controller (ArgoCD)

**What it is:** ArgoCD is a Kubernetes controller that watches a Git repository and continuously
applies any differences to the cluster. Think of it as `kubectl apply -f .` running in an
infinite loop, but smarter — it knows which resources it manages, shows a diff UI, handles
sync ordering, and can roll back with one click.

**The ArgoCD data model:**

```
AppProject (creatium.yaml)
│   Defines: which repos ArgoCD can pull from,
│            which namespaces it can deploy to,
│            which Kubernetes resource types it can create.
│   Security boundary: prevents applications from escaping their scope.
│
└── Application (one .yaml per service)
        Defines: source (Git repo + path + chart),
                 destination (cluster + namespace),
                 sync policy (auto-sync? prune stale resources?)
```

**Two-source ArgoCD Applications:**

Most of our applications use two sources — the Helm chart (from a public chart repo) and the
values file (from this repo). This pattern is called "multi-source applications":

```yaml
# argocd/applications/demo-service.yaml (simplified)
sources:
  - repoURL: https://github.com/ProfJim-Inc/infra.git
    path: kubernetes/charts/creatium-service    # ← the chart template
    helm:
      valueFiles:
        - $values/kubernetes/base/demo-service/values.yaml
  - repoURL: https://github.com/ProfJim-Inc/infra.git
    ref: values    # ← reference alias used above as "$values"
```

**ArgoCD Image Updater:**

A companion tool that watches container registries for new image tags and automatically commits
an updated image tag back to this repo. Configured via annotations on the Application:

```yaml
annotations:
  # Watch for new semver tags on the demo-service image
  argocd-image-updater.argoproj.io/image-list: demo=ghcr.io/profjim-inc/demo-service
  argocd-image-updater.argoproj.io/demo.update-strategy: semver
  # Tell it which Helm values to update
  argocd-image-updater.argoproj.io/demo.helm.image-tag: image.tag
```

When CI pushes `ghcr.io/profjim-inc/demo-service:v1.2.3`, the Image Updater commits
`image.tag: v1.2.3` to this repo → ArgoCD syncs → new version is live.

**Key files:**
- [argocd/projects/creatium.yaml](argocd/projects/creatium.yaml)
- [argocd/applications/](argocd/applications/)

---

### Layer 4 — Application Services

All services share the `creatium-service` Helm chart at
[kubernetes/charts/creatium-service/](kubernetes/charts/creatium-service/).

**Why a shared chart?**

Writing a Deployment, Service, Ingress, HPA, PDB, ConfigMap, ServiceAccount, and ServiceMonitor
from scratch for every service is 200+ lines of boilerplate. Change one thing (e.g., add a
`preStop` hook) and you have to update every service. Instead:

- One chart template = one place to fix bugs
- Each service provides only the values that differ from the defaults
- Adding a new service = 30 lines in a `values.yaml`, not 200 lines of YAML

**What the chart creates per service:**

| Resource | Purpose |
|----------|---------|
| `Deployment` | Runs the container; handles rolling updates and crash restarts |
| `Service` | Stable ClusterIP address so other pods can reach this service by name |
| `Ingress` | (optional) Routes public HTTPS traffic from the load balancer |
| `HorizontalPodAutoscaler` | Scales replica count based on CPU/memory utilization |
| `PodDisruptionBudget` | Guarantees at least N replicas stay up during node maintenance |
| `ConfigMap` | Non-secret environment variables (pulled from `config:` in values.yaml) |
| `ServiceAccount` | Kubernetes RBAC identity — required for Workload Identity / IRSA |
| `ServiceMonitor` | Tells Prometheus "scrape `/metrics` on this service every 30s" |

**Key files:**
- [kubernetes/charts/creatium-service/values.yaml](kubernetes/charts/creatium-service/values.yaml)
- [kubernetes/charts/creatium-service/templates/deployment.yaml](kubernetes/charts/creatium-service/templates/deployment.yaml)

---

### Observability Stack

A production service without observability is a black box. When something breaks at 3am, you need
to answer three questions fast:

1. **What is broken?** → Metrics (Prometheus + Grafana)
2. **Why is it broken?** → Traces (OTeL Collector + Grafana Tempo)
3. **What happened?** → Logs (Fluent Bit + OpenSearch)

The three pillars are connected: every log line contains a `trace_id` that links it to the
exact trace in Tempo. Every trace can link to the logs from that request. Grafana ties them together.

```
Your Service (FastAPI)
  │
  ├── HTTP request metrics (auto) ──────────────────────────────────────────────┐
  │   (http_requests_total, http_request_duration_seconds)                       │
  │                                                                              ▼
  ├── Manual trace spans (OTeL SDK) ──► OTeL Collector ──► Grafana Tempo    Prometheus
  │   ("list-items", "create-item", etc.)                        │               │
  │                                                              │               │
  └── Structured JSON logs (stdout) ──► Fluent Bit ──► OpenSearch   Grafana ◄───┘
      { "trace_id": "abc123", ... }               │       │        (dashboards,
                                                  └───────┘         alerts,
                                              (linked by trace_id)  explore)
```

#### Metrics: kube-prometheus-stack

**What it is:** A Helm chart that installs Prometheus (metrics database), Grafana (dashboards),
Alertmanager (alert routing), node-exporter (machine metrics), and kube-state-metrics (cluster
metrics) in one shot.

**How scraping works:**
1. Each service exposes a `/metrics` endpoint in Prometheus text format
2. A `ServiceMonitor` CRD tells Prometheus "scrape this service every 30s"
3. Prometheus stores the metrics as time-series data
4. Grafana queries Prometheus to draw dashboards

**Configuration:** [kubernetes/base/monitoring/values.yaml](kubernetes/base/monitoring/values.yaml)

Key configuration decisions:
```yaml
prometheus:
  prometheusSpec:
    # Discover ServiceMonitors from ALL namespaces — picks up any service
    # that has a ServiceMonitor, regardless of which namespace it lives in.
    serviceMonitorNamespaceSelector:
      matchLabels: {}   # empty = match all namespaces
    serviceMonitorSelector:
      matchLabels: {}   # empty = match all ServiceMonitors

    # Same for PrometheusRules (alert definitions)
    ruleNamespaceSelector:
      matchLabels: {}
    ruleSelector:
      matchLabels: {}

    retention: 15d        # Keep 15 days of metrics history
    retentionSize: "10GB" # Cap storage at 10GB (whichever comes first)
```

#### Distributed Traces: Grafana Tempo + OTeL Collector

**What is a trace?** When a user clicks a button, your frontend makes an API call, which queries
a database, which calls another microservice. A *trace* captures this entire chain as a tree of
*spans* — each span is one operation with a start time, duration, and metadata. When something
is slow, you can see exactly which span caused the slowness.

```
Trace: GET /api/v1/items  (total: 145ms)
  │
  ├── span: list-items  (2ms)  ← your code
  │     attributes: items.count=3
  │
  └── span: SELECT * FROM items  (140ms)  ← database call
        attributes: db.system=postgresql, db.rows=3
```

**The OTeL Collector** is a vendor-neutral proxy between your application and the storage backend.
Instead of sending traces directly to Tempo, your application sends to the Collector, which can
fan out to multiple backends, batch efficiently, and add metadata:

```
App ──OTLP gRPC──► OTeL Collector ──► Grafana Tempo  (traces)
                         │
                         └──────────► Prometheus      (metrics via scrape)
```

**Auto-instrumentation:** `FastAPIInstrumentor.instrument()` in `telemetry.py` adds a trace span
for every HTTP request automatically — no manual code needed per endpoint.

**Configurations:**
- [kubernetes/base/monitoring/tempo-values.yaml](kubernetes/base/monitoring/tempo-values.yaml)
- [kubernetes/base/monitoring/otel-collector-values.yaml](kubernetes/base/monitoring/otel-collector-values.yaml)

#### Logs: Fluent Bit → OpenSearch

**What is Fluent Bit?** A lightweight log forwarder that runs as a DaemonSet (one pod per
Kubernetes node). It watches `/var/log/containers/*.log` on each node, enriches the logs with
Kubernetes metadata (pod name, namespace, labels), and ships them to OpenSearch.

**The pipeline:**

```
/var/log/containers/*.log  (raw container output on the node)
         │
         ▼
[INPUT] tail
   Reads log files, handles multi-line logs (docker/CRI format), tags as "kube.*"
         │
         ▼
[FILTER] kubernetes
   Calls the K8s API to attach pod metadata: namespace, pod name, labels, annotations
         │
         ▼
[FILTER] grep  — DROP debug/trace
   Excludes logs where level matches /^(debug|trace)$/i
   Result: ~40-60% volume reduction with no meaningful signal lost
         │
         ▼
[FILTER] lua  — set_index.lua
   Reads record["kubernetes"]["labels"]["app"] → "demo-service"
   Sets record["_index"] = "logs-demo-service"
         │
         ▼
[OUTPUT] opensearch
   Writes to: logs-demo-service-2024.01.15  (daily rolling index per service)
   ISM policy: rollover at 7d or 5GB, delete after 30d
```

**Why per-service indices?**
- Filter logs by service in OpenSearch without touching other services' data
- Apply different retention policies per service (e.g., keep audit logs longer)
- Prevent one chatty service from making it hard to find another service's logs

**Configuration:** [kubernetes/base/logging/fluent-bit-values.yaml](kubernetes/base/logging/fluent-bit-values.yaml)

#### NGINX Ingress Controller

**What it is:** A reverse proxy running inside Kubernetes that receives all external HTTP/HTTPS
traffic and routes it to the correct service based on the hostname and path.

```
Internet
   │
   ▼
NodeBalancer (Linode load balancer — created automatically when ingress-nginx is installed)
   │  :443
   ▼
ingress-nginx controller pod
   │
   ├── grafana.creatium.com  ──►  kube-prometheus-stack-grafana:80
   ├── logs.creatium.com     ──►  opensearch-dashboards:5601
   └── demo.creatium.com     ──►  demo-service:80
```

Each service that wants public access sets `ingress.enabled: true` in its `values.yaml`
and provides a `host`. The `Ingress` resource is created by the Helm chart template.

---

## Node Pools: Workload Isolation

The cluster has four distinct node pools. Workloads are pinned to specific pools using
`nodeSelector` in their `values.yaml`. This gives us:
- **Cost control**: only run expensive GPU nodes when needed
- **Security isolation**: ops tools don't share nodes with business services
- **Performance predictability**: ML jobs don't steal CPU from API servers

| Pool | Label | Machine | Count | What runs here |
|------|-------|---------|-------|----------------|
| **System** | `pool: system` | g6-standard-2 (2 vCPU / 4 GB) | 2 fixed | ArgoCD, Prometheus, Grafana, OpenSearch, Fluent Bit, ingress-nginx |
| **General** | `pool: general` | g6-standard-4 (4 vCPU / 8 GB) | 2–8 autoscaling | API services, web frontends, demo-service |
| **Compute** | `pool: compute` | g6-dedicated-8 (8 vCPU / 16 GB dedicated) | 1–5 autoscaling | ML inference (CPU-only), heavy data processing |
| **GPU** | `pool: gpu` | g2-gpu-rtx4000a1-m (NVIDIA RTX 6000) | 1 fixed | tts-microservice only |

**How node pinning works:**

In `values.yaml`:
```yaml
# Pin this service to the general pool
nodeSelector:
  pool: general
```

The Helm chart puts this directly on the pod spec:
```yaml
# deployment.yaml (simplified)
spec:
  template:
    spec:
      nodeSelector:
        pool: general   # K8s scheduler only places this pod on nodes with this label
```

**GPU taint/toleration:**

The GPU node is *tainted* with `nvidia.com/gpu=present:NoSchedule`. This means no pod will
be scheduled there unless it explicitly declares a matching *toleration*. Only `tts-microservice`
has this toleration, keeping the expensive GPU node reserved for GPU work:

```yaml
# tts-microservice/values.yaml
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Equal"
    value: "present"
    effect: "NoSchedule"
```

**Fluent Bit is the exception:** It runs on ALL nodes (including GPU and system) because it
needs to collect logs from everywhere. It achieves this with `tolerations: [{operator: Exists}]`
— tolerate any taint:

```yaml
# kubernetes/base/logging/fluent-bit-values.yaml
tolerations:
  - operator: Exists    # Match any taint key/value — run on ALL nodes
```

---

## Bringing Up the Infrastructure

Complete steps to provision the cluster from scratch and get all services running.

### Required Tools

Install these before starting:

```bash
# macOS (Homebrew)
brew install terraform kubectl helm linode-cli

# Verify versions
terraform version     # >= 1.5.0
kubectl version       # any recent version
helm version          # >= 3.0
```

- [Terraform install guide](https://developer.hashicorp.com/terraform/install)
- [kubectl install guide](https://kubernetes.io/docs/tasks/tools/)
- [Helm install guide](https://helm.sh/docs/intro/install/)

You also need:
- A Linode account (cloud.linode.com) with API access
- A GitHub account with a personal access token (PAT) for pulling images from GHCR

### Step 1 — Configure Credentials

```bash
cd terraform/environments/linode-us

# Copy the example vars file and fill in your Linode API token
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set linode_api_token = "your-token-here"

# These look like AWS credentials but they're actually Linode Object Storage keys.
# Terraform's S3 backend uses the AWS SDK, so it reads these specific env var names
# even though it's talking to Linode Object Storage (which has an S3-compatible API).
export AWS_ACCESS_KEY_ID="your-linode-obj-access-key"
export AWS_SECRET_ACCESS_KEY="your-linode-obj-secret-key"
```

Create the state bucket if it doesn't exist yet:
```bash
linode-cli obj mb creatium-terraform-state --cluster us-ord-1
```

### Step 2 — Provision the Cluster with Terraform

```bash
# Download the Linode provider plugin
terraform init

# Preview what will be created (safe — no changes made)
terraform plan

# Apply — creates the cluster, node pools, and firewall (~5-10 minutes)
terraform apply
```

This creates:
- LKE cluster `creatium-us` in `us-ord` running Kubernetes 1.34
- System pool: 2 × `g6-standard-2` nodes
- General pool: 2–8 × `g6-standard-4` nodes (autoscaling)
- Compute pool: 1–5 × `g6-dedicated-8` nodes (autoscaling)
- GPU pool: 1 × `g2-gpu-rtx4000a1-m` node
- Firewall restricting `kube-apiserver` access to your allowed CIDRs

### Step 3 — Configure kubectl

```bash
# Extract the kubeconfig from Terraform output
terraform output -raw kubeconfig | base64 -d > ~/.kube/creatium-us.yaml

# Tell kubectl to use this config
export KUBECONFIG=~/.kube/creatium-us.yaml

# Verify — all nodes should show Ready
kubectl get nodes
```

Expected output:
```
NAME                      STATUS   ROLES    AGE   VERSION
lke12345-node-aabbcc      Ready    <none>   2m    v1.34.0
lke12345-node-ddeeff      Ready    <none>   2m    v1.34.0
...
```

### Step 4 — Bootstrap ArgoCD

ArgoCD is the only thing bootstrapped manually — after that, it manages everything else.

```bash
# Create the namespace ArgoCD lives in
kubectl create namespace argocd

# Install ArgoCD from the official manifest
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait until the server is ready (~60-90 seconds)
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=180s

# Register the ArgoCD project (security boundary) — must be applied before applications
kubectl apply -f argocd/projects/creatium.yaml

# Register all applications — ArgoCD will start syncing them immediately
kubectl apply -f argocd/applications/
```

**Get the initial admin password and log in:**

```bash
# Retrieve the auto-generated admin password
kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d && echo

# Forward the ArgoCD UI to localhost (run in a separate terminal)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` → username `admin` → paste the password.

> After first login, change the password via **User Info → Update Password**, then:
> `kubectl delete secret argocd-initial-admin-secret -n argocd`

**Watch sync progress:**
In the ArgoCD UI, you'll see all your application tiles turn from grey (Unknown) to blue
(Progressing) to green (Healthy) as the cluster pulls the Helm charts and deploys each service.

### Step 5 — Create Required Secrets

Kubernetes Secrets are not stored in Git (they contain sensitive data). Create them manually:

```bash
# Grafana admin credentials (used by Grafana to read the admin password from a Secret)
kubectl create namespace monitoring
kubectl create secret generic grafana-admin \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="your-secure-password-here"

# GHCR pull secret (needed to pull private container images from GitHub Container Registry)
kubectl create namespace production
kubectl create secret docker-registry ghcr-pull-secret \
  -n production \
  --docker-server=ghcr.io \
  --docker-username="your-github-username" \
  --docker-password="your-github-pat"

# Alertmanager Slack webhook (for demo-service alert notifications)
# Get a webhook URL at: api.slack.com/apps → Create App → Incoming Webhooks
kubectl create secret generic alertmanager-slack-secret \
  -n production \
  --from-literal=webhook_url="https://hooks.slack.com/services/XXXXX/YYYYY/ZZZZZ"
```

### Step 6 — Verify the Ops Stack

```bash
# All ArgoCD applications should show Synced + Healthy
kubectl get applications -n argocd

# Monitoring stack pods
kubectl get pods -n monitoring

# Logging stack pods
kubectl get pods -n logging

# Application pods
kubectl get pods -n production
```

**Access the UIs:**

```bash
# Grafana (metrics, traces, logs) — http://localhost:3000
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# OpenSearch Dashboards (log exploration) — http://localhost:5601
kubectl port-forward -n logging svc/opensearch-dashboards 5601:5601

# ArgoCD (GitOps status) — https://localhost:8080
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Once DNS is configured:

| Service | URL |
|---------|-----|
| Grafana | `https://grafana.creatium.com` |
| OpenSearch Dashboards | `https://logs.creatium.com` |
| Demo Service API | `https://demo.creatium.com` |

> **DNS setup:** Get the NodeBalancer IP with `kubectl get svc -n ingress-nginx` and create
> A records for `grafana.creatium.com`, `logs.creatium.com`, and `demo.creatium.com`.

---

## Demo Service Walkthrough

The `demo-service` is a FastAPI application at [services/demo-service/](services/demo-service/)
that exercises every part of the observability stack. It is deployed to the `general` pool in
the `production` namespace.

### What It Does

| Endpoint | Purpose | What you'll see in Grafana |
|----------|---------|---------------------------|
| `GET /api/v1/items` | List items from in-memory store | A `list-items` span in Tempo |
| `POST /api/v1/items` | Create a new item | A `create-item` span with item metadata |
| `GET /api/v1/items/{id}` | Fetch one item (404 → error span) | Red error span in Tempo |
| `GET /api/v1/slow?delay=3` | Artificial 3-second delay | Latency spike in Grafana histogram |
| `GET /api/v1/error` | Always returns 500 | Error trace in Tempo, ERROR log in OpenSearch |
| `GET /metrics` | Prometheus metrics | `http_requests_total`, `http_request_duration_seconds` |
| `GET /health` | Liveness probe (K8s uses this) | — |
| `GET /readiness` | Readiness probe (K8s uses this) | — |

### Generating Telemetry — Step by Step

**Step 1:** Forward the service port:
```bash
kubectl port-forward -n production svc/demo-service 8080:80
```

**Step 2:** Generate some traffic:
```bash
# Normal traffic (generates traces + metrics)
for i in {1..10}; do curl -s http://localhost:8080/api/v1/items; done

# Trigger a high-latency alert (P99 > 2s)
for i in {1..50}; do curl -s "http://localhost:8080/api/v1/slow?delay=3"; done

# Trigger a high error-rate alert (>5% errors)
for i in {1..100}; do curl -s http://localhost:8080/api/v1/error; done
```

**Step 3:** View in Grafana (port-forward Grafana if not using DNS):
- **Explore → Tempo** → search for `service.name = demo-service` → click any trace
- **Explore → OpenSearch** → filter `service: demo-service` → see JSON log lines
- **Explore → Prometheus** → query `http_requests_total{namespace="production"}`

**Step 4:** Trigger a pod crash-loop (tests the `DemoServicePodCrashLooping` alert):
```bash
# Set an invalid image tag — the pod will fail to start, creating a crash loop
kubectl set image deployment/demo-service \
  demo-service=ghcr.io/profjim-inc/demo-service:nonexistent-tag \
  -n production
# Wait ~2 minutes, then check Alertmanager
# Restore the correct image:
kubectl rollout undo deployment/demo-service -n production
```

### How Observability Is Wired

**Traces** (`services/demo-service/app/telemetry.py`):
```python
# 1. Create a TracerProvider that sends to the OTeL Collector
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint="otel-collector.monitoring.svc.cluster.local:4317")
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

# 2. Auto-instrument FastAPI — every request gets a span automatically
FastAPIInstrumentor.instrument()
```

**Logs with trace correlation** (`services/demo-service/app/logging_config.py`):
```python
# Every log line includes the current trace_id and span_id.
# This lets Grafana link from a log line directly to the trace in Tempo.
span = trace.get_current_span()
ctx = span.get_span_context()
if ctx.is_valid:
    obj["trace_id"] = format(ctx.trace_id, "032x")
    obj["span_id"]  = format(ctx.span_id, "016x")
```

**Metrics** (`services/demo-service/app/main.py`):
```python
# prometheus-fastapi-instrumentator adds two metrics automatically:
#   http_requests_total{method, handler, status}   (counter)
#   http_request_duration_seconds{handler}         (histogram)
# and exposes them at GET /metrics for Prometheus to scrape.
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
```

---

## Deploying Your Own Service

Here is the complete checklist for adding a new service to this platform.

### Prerequisites in Your Application

Before your service can run on Kubernetes, it needs to be "cloud-native ready":

- [ ] **Health check endpoints** — `GET /health` (liveness) and `GET /ready` or `GET /readiness`
      (readiness). These must return HTTP 200 when the service is healthy.
- [ ] **Read config from environment variables** — no hardcoded URLs, ports, or credentials
- [ ] **Log to stdout** — not to files. Kubernetes captures stdout automatically.
- [ ] **Handle SIGTERM gracefully** — when Kubernetes wants to stop your pod, it sends SIGTERM.
      Your app should finish in-flight requests and exit cleanly within 30 seconds.
- [ ] **Stateless** — don't store session data or files locally. Use Redis/S3/a database instead.

### Step-by-Step: Add a New Service

**1. Write a Dockerfile** (if the service isn't already containerized)

Use a multi-stage build to keep the final image small:
```dockerfile
# Stage 1: install dependencies (this layer is cached between builds)
FROM python:3.12-slim AS deps
WORKDIR /build
COPY requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

# Stage 2: runtime image (only what's needed to run, not to build)
FROM python:3.12-slim AS runtime
RUN useradd -m app                    # never run as root
WORKDIR /app
COPY --from=deps /root/.local /home/app/.local
COPY . .
USER app
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**2. Create the values file**

```bash
mkdir -p kubernetes/base/my-service
```

Create `kubernetes/base/my-service/values.yaml`:
```yaml
# Override only what differs from the chart defaults.
# See kubernetes/charts/creatium-service/values.yaml for all available options.

nameOverride: "my-service"

image:
  repository: ghcr.io/profjim-inc/my-service
  tag: "latest"           # ArgoCD Image Updater will keep this up to date

containerPort: 8000

replicaCount: 2

commonLabels:
  team: platform
  tier: internal

nodeSelector:
  pool: general           # or "compute" for CPU-heavy, "gpu" for NVIDIA GPU

imagePullSecrets:
  - name: ghcr-pull-secret

ingress:
  enabled: true           # set false for internal-only services
  host: "my-service.creatium.com"
  tls:
    enabled: true
    secretName: "my-service-tls"

config:                   # Non-secret environment variables (goes into a ConfigMap)
  LOG_LEVEL: "info"
  REDIS_URL: "redis://redis.production.svc.cluster.local:6379"

serviceMonitor:
  enabled: true           # Only if your service has a /metrics endpoint
```

**3. Create the ArgoCD Application**

Create `argocd/applications/my-service.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  labels:
    team: platform
  annotations:
    # Auto-update the image tag when a new semver image is pushed to GHCR
    argocd-image-updater.argoproj.io/image-list: myservice=ghcr.io/profjim-inc/my-service
    argocd-image-updater.argoproj.io/myservice.update-strategy: semver
    argocd-image-updater.argoproj.io/myservice.helm.image-name: image.repository
    argocd-image-updater.argoproj.io/myservice.helm.image-tag: image.tag
    argocd-image-updater.argoproj.io/write-back-method: git
spec:
  project: creatium
  sources:
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      path: kubernetes/charts/creatium-service
      helm:
        valueFiles:
          - $values/kubernetes/base/my-service/values.yaml
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**4. Write a CI/CD workflow**

Copy `.github/workflows/demo-service.yml` and update the service name. The key jobs are:
- `ci` (runs on PRs): lint, test, `docker build` (validate only)
- `cd` (runs on merge): `docker build + push to GHCR`

**5. Merge to `main`**

ArgoCD detects the new `argocd/applications/my-service.yaml` and deploys it.
ArgoCD Image Updater watches for new image tags and updates `image.tag` automatically.

**6. Create any needed secrets**

```bash
kubectl create secret generic my-service-secrets \
  -n production \
  --from-literal=DATABASE_PASSWORD="..." \
  --from-literal=API_KEY="..."
```

Then reference the secret in `values.yaml`:
```yaml
secretRefs:
  - name: my-service-secrets
    key: DATABASE_PASSWORD
  - name: my-service-secrets
    key: API_KEY
```

---

## CI/CD Pipeline Explained

### How It Works

This repo uses the GitOps pattern: **CI builds the image, Git stores the desired state,
ArgoCD handles the actual deployment.**

```
PR opened
    │
    ▼
ci job runs (parallel):
  ├── helm lint (validate chart templates)
  ├── docker build --push=false (verify it builds)
  └── [language tests if any]
    │
    ▼ (PR approved + merged to main)
    │
cd job runs:
  ├── docker build + push → ghcr.io/profjim-inc/demo-service:v1.2.3
  └── git commit: update image.tag = "v1.2.3" in values.yaml
         │
         ▼
ArgoCD detects the commit (polls every 3 minutes):
  ├── Renders new Helm chart with updated image tag
  ├── Diffs against current cluster state
  └── Applies: new pod starts, old pod stops (rolling update)
```

### Why Not Deploy Directly from CI?

Many teams run `kubectl apply` or `helm upgrade` from their CI pipeline. There are several
problems with this approach:
- CI needs kubectl credentials (security risk)
- The cluster state is only correct right after CI runs — it can drift afterward
- Hard to know what's actually deployed vs. what CI last ran
- Rollback requires re-running CI with a different commit

With GitOps:
- ArgoCD *continuously* reconciles — the cluster is always consistent with Git
- Rollback = `git revert` on the values file
- No kubectl credentials in CI — only Docker registry credentials
- Full audit trail of every change in Git history

### Workflow Files

| File | Triggers | What it does |
|------|----------|-------------|
| `.github/workflows/demo-service.yml` | PR to `main`, push to `main` | Build + push demo-service image |
| `.github/workflows/helm-lint.yml` | PR to `main` | Lint all Helm charts |
| `.github/workflows/terraform-plan.yml` | PR touching `terraform/**` | Post Terraform plan as PR comment |
| `.github/workflows/terraform-apply.yml` | Push to `main` touching `terraform/**` | Apply Terraform changes |

### Required GitHub Secrets

Configure at **Settings → Secrets and variables → Actions**:

| Secret | What it's for |
|--------|--------------|
| `LINODE_TOKEN` | Terraform creates/modifies cloud resources |
| `LINODE_OBJ_ACCESS_KEY` | Terraform reads/writes state file in Object Storage |
| `LINODE_OBJ_SECRET_KEY` | Terraform reads/writes state file in Object Storage |

The Docker build uses `GITHUB_TOKEN` (built-in, no setup needed) to push to GHCR.

---

## Alerting: End-to-End Flow

### The Pipeline

```
PromQL rule fires (e.g., error rate > 5%)
         │
         ▼
Prometheus → PENDING state (waiting for "for:" grace period)
         │
         ▼ (after grace period)
Prometheus → FIRING state → sends to Alertmanager
         │
         ▼
Alertmanager evaluates routes:
  service=demo-service + severity=critical → #alerts-critical (Slack)
  service=demo-service + severity=warning  → #alerts (Slack)
         │
         ▼
Slack message arrives with:
  - Alert name and severity
  - Summary and description from the alert annotation
  - Runbook link (the command to run to investigate)
```

### The Alert Rules

Four alerts are defined in [kubernetes/base/demo-service/alerts.yaml](kubernetes/base/demo-service/alerts.yaml):

| Alert | Condition | Severity | For |
|-------|-----------|----------|-----|
| `DemoServiceDown` | 0 available replicas | critical | 1 minute |
| `DemoServicePodCrashLooping` | >3 restarts in 15 minutes | warning | 0 minutes |
| `DemoServiceHighErrorRate` | >5% HTTP 5xx over 5 minutes | warning | 2 minutes |
| `DemoServiceHighLatencyP99` | P99 latency >2s over 5 minutes | warning | 5 minutes |

The `for:` field is the grace period — Prometheus waits this long in PENDING state before
firing. This prevents flapping on brief transient spikes.

### Routing: AlertmanagerConfig

The [alertmanager-config.yaml](kubernetes/base/demo-service/alertmanager-config.yaml) is a
namespaced CR that Prometheus Operator automatically scopes to alerts carrying
`namespace=production`. This means each team can own their own alert routing without
touching the central Alertmanager config.

```
AlertmanagerConfig (namespace: production)
  Route:
    matchers: [service=demo-service]      ← only demo-service alerts
    receiver: slack-warnings              ← default: #alerts channel
    routes:
      - matchers: [severity=critical]     ← critical: also go to #alerts-critical
        receiver: slack-critical
        continue: true                    ← AND still go to slack-warnings
```

### Setting Up Slack Alerts

1. Go to `api.slack.com/apps` → **Create New App → From scratch**
2. Enable **Incoming Webhooks**, add to your workspace, choose a channel
3. Copy the webhook URL (`https://hooks.slack.com/services/...`)
4. Create the secret:
```bash
kubectl create secret generic alertmanager-slack-secret \
  -n production \
  --from-literal=webhook_url="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```
5. Restart Alertmanager to pick up the new secret:
```bash
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager \
  -n monitoring
```

### Adding a New Alert

1. Add a rule to the `PrometheusRule` in `kubernetes/base/your-service/alerts.yaml`:
```yaml
- alert: MyServiceDatabaseSlowQueries
  expr: |
    histogram_quantile(0.95,
      rate(db_query_duration_seconds_bucket{namespace="production"}[5m])
    ) > 1.0
  for: 3m
  labels:
    severity: warning
    service: my-service
    namespace: production        # ← required for AlertmanagerConfig scoping
  annotations:
    summary: "Database P95 query time above 1 second"
    description: "{{ $value | humanizeDuration }} P95 query latency over 5 minutes"
    runbook: "kubectl exec -it deploy/my-service -n production -- python -c 'import app; app.analyze_slow_queries()'"
```

2. Commit and push — ArgoCD applies the new `PrometheusRule` → Prometheus picks it up
   within ~1 minute (no restart needed).

---

## Day-2 Operations

Things you'll need to do after the initial setup.

### Checking Logs

```bash
# Stream logs from all demo-service pods
kubectl logs -f -l app=demo-service -n production

# Filter for ERROR logs only
kubectl logs -l app=demo-service -n production | grep '"level":"ERROR"'

# Check logs in OpenSearch via Grafana:
# Explore → OpenSearch → query: { "query": { "match": { "kubernetes.labels.app": "demo-service" } } }
```

### Debugging a Failing Pod

```bash
# See pod status and recent events
kubectl describe pod -l app=demo-service -n production

# Check events (scheduling failures, image pull errors, OOM kills)
kubectl get events -n production --sort-by=.lastTimestamp | tail -20

# Exec into a running pod
kubectl exec -it deploy/demo-service -n production -- /bin/sh

# Port-forward to test directly
kubectl port-forward deploy/demo-service -n production 8080:8000
curl http://localhost:8080/health
```

### Scaling

The HPA (Horizontal Pod Autoscaler) handles scaling automatically based on CPU and memory.
To check its status:
```bash
kubectl get hpa -n production
```

To manually override the replica count temporarily:
```bash
kubectl scale deployment/demo-service --replicas=5 -n production
# Note: the HPA will override this back after its next reconcile cycle.
# To permanently change the min/max, edit replicaCount/autoscaling in values.yaml.
```

### Rolling Back a Deployment

**Option 1: ArgoCD rollback** (recommended for most cases)
1. Open the ArgoCD UI → click the application
2. Click **History and Rollback**
3. Select a previous sync and click **Rollback**

**Option 2: Kubectl rollback** (immediate, bypasses GitOps)
```bash
# See deployment history
kubectl rollout history deployment/demo-service -n production

# Roll back to the previous version
kubectl rollout undo deployment/demo-service -n production

# Roll back to a specific revision
kubectl rollout undo deployment/demo-service -n production --to-revision=3
```

> After a kubectl rollback, update the `image.tag` in `values.yaml` to match the rolled-back
> version — otherwise ArgoCD will re-apply the bad version on its next sync.

**Option 3: Git revert** (the GitOps way — also rolls back any config changes)
```bash
git revert HEAD    # creates a new commit that undoes the last commit
git push origin main
# ArgoCD picks up the revert and redeploys the previous version
```

### Updating Configuration

All config changes follow the same pattern:

1. Edit the relevant `values.yaml` or other YAML file
2. Commit and push to `main`
3. ArgoCD applies the change (watch in the UI or with `kubectl get pods -n production -w`)

For changes to ArgoCD projects or the Alertmanager global config, apply manually:
```bash
kubectl apply -f argocd/projects/creatium.yaml
```

### Restarting the Prometheus Operator

If a PrometheusRule or ServiceMonitor isn't being picked up after a restart:
```bash
kubectl rollout restart deployment/kube-prometheus-stack-operator -n monitoring
```

### Checking ArgoCD Sync Status

```bash
# All applications
kubectl get applications -n argocd

# Detailed status for one application
kubectl describe application demo-service -n argocd

# Force a hard refresh (bypasses cache)
kubectl annotate application demo-service -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## Local Development

### Setting Up a Local Environment

For developing and testing infrastructure changes locally:

```bash
# Install tools (macOS)
brew install terraform kubectl helm

# Clone the repo
git clone https://github.com/ProfJim-Inc/infra.git
cd infra

# Set up Terraform credentials
cd terraform/environments/linode-us
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — add your linode_api_token

export AWS_ACCESS_KEY_ID="your-linode-obj-access-key"
export AWS_SECRET_ACCESS_KEY="your-linode-obj-secret-key"
```

### Validate Terraform Changes Without Applying

```bash
terraform init
terraform validate       # syntax check
terraform plan           # shows what would change — read this carefully before applying
```

### Lint Helm Charts

```bash
# Lint the shared chart with each service's values
helm lint kubernetes/charts/creatium-service \
  -f kubernetes/base/demo-service/values.yaml

helm lint kubernetes/charts/creatium-service \
  -f kubernetes/base/agent-backend/values.yaml

# Render the templates and check the output
helm template my-service kubernetes/charts/creatium-service \
  -f kubernetes/base/demo-service/values.yaml
```

### Run the Demo Service Locally

```bash
cd services/demo-service

# Install Python dependencies
pip install -r requirements.txt

# Run without OTeL tracing (set OTLP_ENDPOINT to empty)
OTLP_ENDPOINT="" uvicorn app.main:app --reload

# Test endpoints
curl http://localhost:8000/health
curl http://localhost:8000/api/v1/items
curl -X POST http://localhost:8000/api/v1/items \
  -H "Content-Type: application/json" \
  -d '{"name": "Test Widget", "value": 42, "category": "hardware"}'
```

---

## Cloud Migration Paths

### Deploying to a New Linode Region

Effort: ~1 hour

```bash
# 1. Copy the environment directory
cp -r terraform/environments/linode-us terraform/environments/linode-eu

# 2. Edit main.tf — change region, cluster_name, backend key
#    region = "eu-central"
#    cluster_name = "creatium-eu"
#    key = "linode-eu/terraform.tfstate"

# 3. Add to CI matrix in terraform-plan.yml and terraform-apply.yml:
#    environment: [linode-us, linode-eu]

# 4. Apply
cd terraform/environments/linode-eu
terraform init && terraform apply

# 5. Bootstrap ArgoCD (same as Step 4 in the main guide)
```

Everything in `argocd/` and `kubernetes/` is cloud-agnostic. All services deploy to the
new cluster automatically as soon as ArgoCD is bootstrapped.

### Migrating to GCP (GKE)

Effort: ~1–2 weeks

**What stays the same (zero changes):**
- All Helm chart templates
- All ArgoCD application manifests
- All `values.yaml` files
- Container images (stored in GHCR, accessible from anywhere)
- Node pool labels (`pool: general/compute/system/gpu`)

**What needs to be rewritten (Terraform only):**

| Current (Linode) | GCP equivalent |
|------------------|----------------|
| `linode/linode` provider | `hashicorp/google` provider |
| `linode_lke_cluster` | `google_container_cluster` |
| `linode_lke_node_pool` | `google_container_node_pool` |
| `linode_firewall` | VPC + `google_compute_firewall` |
| Linode Object Storage backend | GCS bucket backend |

**Migration strategy — blue/green, zero downtime:**
```
Week 1: Provision GKE cluster in parallel with Linode
        Bootstrap ArgoCD → all services sync automatically

Week 2: Validate all services on GKE
        Migrate secrets
        Lower DNS TTL to 60 seconds

Week 3: Cut DNS over to GKE load balancer
        Monitor for 48 hours
        terraform destroy linode-us
```

The key advantage: because ArgoCD syncs from this Git repo, the moment GKE is bootstrapped,
all services deploy automatically with no manifest changes.

---

## Glossary

**ArgoCD** — A Kubernetes controller that watches a Git repo and continuously applies any
differences to the cluster. Makes Git the single source of truth for cluster state.

**ClusterIP** — A stable internal IP address assigned to a Kubernetes Service. Other pods
reach the service by name (DNS) rather than by pod IP (which changes on restart).

**CRD (Custom Resource Definition)** — An extension to the Kubernetes API that adds new
resource types. `PrometheusRule`, `AlertmanagerConfig`, and `ServiceMonitor` are all CRDs
added by the Prometheus Operator.

**DaemonSet** — A Kubernetes workload that runs exactly one pod per node. Fluent Bit uses
this to collect logs from every node in the cluster.

**Deployment** — A Kubernetes workload that manages a set of identical pods (replicas).
Handles rolling updates, crash restarts, and scaling.

**GitOps** — An operational model where the desired state of a system is stored in Git,
and an automated process continuously applies that state. Changes are made via pull requests.

**Helm** — A Kubernetes package manager. A "chart" is a template that generates Kubernetes
YAML. "Values" are the per-deployment configuration injected into the template.

**HPA (HorizontalPodAutoscaler)** — Automatically scales the number of pod replicas up
or down based on CPU/memory utilization metrics.

**Ingress** — A Kubernetes resource that configures the NGINX ingress controller to route
external HTTP/HTTPS traffic to a specific service based on hostname and path.

**ISM (Index State Management)** — An OpenSearch feature that automates index lifecycle:
rollover a large/old index, delete indexes older than N days.

**kubectl** — The command-line tool for interacting with a Kubernetes cluster. Like `git`
but for Kubernetes.

**NodeSelector** — A constraint on a Kubernetes pod that limits which nodes it can be
scheduled on. Used to pin pods to specific node pools.

**OTLP (OpenTelemetry Protocol)** — A vendor-neutral wire format for sending traces,
metrics, and logs between systems. OTeL SDK → OTeL Collector → Tempo all use OTLP.

**PDB (PodDisruptionBudget)** — A Kubernetes resource that guarantees at least N replicas
of a pod stay running during voluntary disruptions (node drains, upgrades).

**PromQL** — The query language for Prometheus. Used to write alert conditions and Grafana
dashboard queries. `rate(http_requests_total[5m])` = per-second request rate over 5 minutes.

**PrometheusRule** — A CRD (added by Prometheus Operator) that defines alert rules in
PromQL. Prometheus evaluates these every 30 seconds.

**ServiceMonitor** — A CRD that tells Prometheus which services to scrape for metrics,
how often, and on which endpoint/port.

**Span** — One unit of work within a distributed trace. Spans have a name, start time,
duration, and key-value attributes. A trace is a tree of spans.

**Taint** — A property on a Kubernetes node that repels pods. A pod can only be scheduled
on a tainted node if it has a matching Toleration.

**Terraform** — Infrastructure-as-code tool. Declaratively describe cloud resources in
`.tf` files; Terraform creates/updates/deletes them to match.

**Toleration** — A pod property that allows it to be scheduled on a tainted node.
`tts-microservice` tolerates the GPU taint to run on the GPU node pool.

**Trace** — A record of a request's journey through a distributed system, captured as
a tree of spans. Used to debug latency and errors in microservices.
