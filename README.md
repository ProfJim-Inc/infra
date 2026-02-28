# Creatium Infrastructure

GitOps monorepo for all Creatium infrastructure — Kubernetes workloads, Helm charts, ArgoCD applications, and Terraform-managed cloud resources.

## Table of Contents

- [Creatium Infrastructure](#creatium-infrastructure)
  - [Table of Contents](#table-of-contents)
  - [Architecture Overview](#architecture-overview)
  - [Repository Structure](#repository-structure)
  - [Bringing Up the Infrastructure](#bringing-up-the-infrastructure)
    - [Required tools](#required-tools)
    - [Step 1 — Configure credentials](#step-1--configure-credentials)
    - [Step 2 — Provision the cluster with Terraform](#step-2--provision-the-cluster-with-terraform)
    - [Step 3 — Configure kubectl](#step-3--configure-kubectl)
    - [Step 4 — Bootstrap ArgoCD](#step-4--bootstrap-argocd)
    - [Step 5 — Create required secrets](#step-5--create-required-secrets)
    - [Step 6 — Verify the ops stack](#step-6--verify-the-ops-stack)
  - [Services](#services)
  - [Node Pools](#node-pools)
  - [CI/CD — GitHub Actions](#cicd--github-actions)
    - [Terraform Plan (PRs)](#terraform-plan-prs)
    - [Terraform Apply (merge to main)](#terraform-apply-merge-to-main)
    - [Required GitHub Secrets](#required-github-secrets)
  - [Deploying to a New Linode Region](#deploying-to-a-new-linode-region)
    - [Steps](#steps)
  - [Migrating to GCP (GKE)](#migrating-to-gcp-gke)
    - [What stays the same (zero changes needed)](#what-stays-the-same-zero-changes-needed)
    - [What needs to be rewritten](#what-needs-to-be-rewritten)
    - [Migration strategy — blue/green, zero downtime](#migration-strategy--bluegreen-zero-downtime)
  - [Local Development](#local-development)
    - [Prerequisites](#prerequisites)
    - [Installing Terraform](#installing-terraform)
      - [macOS](#macos)
      - [Linux (Ubuntu / Debian)](#linux-ubuntu--debian)
      - [Linux (RHEL / Fedora / Amazon Linux)](#linux-rhel--fedora--amazon-linux)
      - [Windows](#windows)
    - [Running Terraform locally](#running-terraform-locally)
    - [Linting Helm charts](#linting-helm-charts)
    - [Getting the kubeconfig](#getting-the-kubeconfig)

---

## Architecture Overview

```
GitHub (this repo)
    │
    ├── .github/workflows/
    │   ├── terraform-plan.yml    ← runs on PRs, posts plan as comment
    │   └── terraform-apply.yml   ← runs on merge to main, auto-applies
    │
    ├── terraform/                ← cloud infrastructure (Linode LKE)
    │   ├── environments/linode-us/
    │   └── modules/{cluster,node-pool,networking}/
    │
    ├── argocd/                   ← ArgoCD project + application definitions
    └── kubernetes/               ← Helm chart + per-service values
        ├── charts/creatium-service/   ← shared chart used by all services
        └── base/{service}/values.yaml ← per-service overrides
```

**GitOps flow:** Terraform provisions the Kubernetes cluster → ArgoCD is bootstrapped into the cluster → ArgoCD syncs all services from this repo continuously. Any change merged to `main` is automatically reflected in the cluster.

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── helm-lint.yml            # Lints Helm charts on PRs
│   ├── terraform-plan.yml       # Plans Terraform on PRs, comments output to PR
│   └── terraform-apply.yml      # Applies Terraform on merge to main
│
├── argocd/
│   ├── projects/creatium.yaml   # ArgoCD AppProject — namespace + repo allowlist
│   └── applications/
│       ├── agent-backend.yaml
│       ├── agent-frontend.yaml
│       └── tts-microservice.yaml
│
├── kubernetes/
│   ├── charts/creatium-service/ # Shared Helm chart for all services
│   │   ├── Chart.yaml
│   │   ├── values.yaml          # Defaults — override per service
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       ├── hpa.yaml
│   │       ├── pdb.yaml
│   │       ├── configmap.yaml
│   │       ├── serviceaccount.yaml
│   │       └── servicemonitor.yaml
│   └── base/
│       ├── agent-backend/values.yaml
│       ├── agent-frontend/values.yaml
│       └── tts-microservice/values.yaml
│
└── terraform/
    ├── environments/
    │   └── linode-us/            # Active environment — us-east region
    │       ├── main.tf
    │       ├── variables.tf
    │       └── terraform.tfvars.example
    └── modules/
        ├── cluster/              # linode_lke_cluster
        ├── node-pool/            # linode_lke_node_pool (autoscaling)
        └── networking/           # linode_firewall
```

---

## Bringing Up the Infrastructure

Complete steps to provision the cluster from scratch and get all services running.

### Required tools

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- A Linode account with API access
- A Linode Object Storage bucket named `creatium-terraform-state` in `us-ord-1`

Create the state bucket if it doesn't exist:

```bash
linode-cli obj mb creatium-terraform-state --cluster us-ord-1
```

### Step 1 — Configure credentials

```bash
cd terraform/environments/linode-us

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set linode_api_token

# Linode Object Storage keys for the Terraform state backend
export AWS_ACCESS_KEY_ID=<linode-obj-access-key>
export AWS_SECRET_ACCESS_KEY=<linode-obj-secret-key>
```

### Step 2 — Provision the cluster with Terraform

```bash
terraform init
terraform apply
```

This creates:

- LKE cluster (`creatium-us`, `us-east`, k8s 1.34)
- System pool: `g6-standard-2` × 2 nodes (monitoring, logging, ArgoCD)
- Compute pool: `g6-dedicated-8` × 1–5 nodes (ML inference, TTS)
- Firewall rules restricting kube-apiserver access

### Step 3 — Configure kubectl

```bash
terraform output -raw kubeconfig | base64 -d > ~/.kube/creatium-us.yaml
export KUBECONFIG=~/.kube/creatium-us.yaml
kubectl get nodes   # all nodes should show Ready
```

### Step 4 — Bootstrap ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=120s

# Apply the project and all applications
kubectl apply -f argocd/projects/creatium.yaml
kubectl apply -f argocd/applications/
```

### Step 5 — Create required secrets

Grafana admin credentials:

```bash
kubectl create namespace monitoring
kubectl create secret generic grafana-admin \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<your-password>
```

Application secrets (repeat for each service that needs them):

```bash
kubectl create namespace production
# Example: kubectl create secret generic <secret-name> -n production --from-literal=KEY=value
```

### Step 6 — Verify the ops stack

Once ArgoCD syncs (watch progress at `kubectl port-forward svc/argocd-server -n argocd 8080:443`):

```bash
# All ArgoCD apps should show Synced + Healthy
kubectl get applications -n argocd

# Monitoring stack
kubectl get pods -n monitoring

# Logging stack
kubectl get pods -n logging

# Application services
kubectl get pods -n production
```

| Component             | URL                                      | Notes                       |
|-----------------------|------------------------------------------|-----------------------------|
| Grafana               | `https://grafana.creatium.com`           | Dashboards for all services |
| OpenSearch Dashboards | `https://logs.creatium.com`              | Log exploration             |
| ArgoCD                | port-forward `argocd-server:443` locally | GitOps sync status          |

> **Note:** DNS for `grafana.creatium.com` and `logs.creatium.com` must point to the nginx-ingress LoadBalancer IP. Get the IP with `kubectl get svc -n ingress-nginx`.

---

## Services

All services share the `kubernetes/charts/creatium-service` Helm chart and are deployed to the `production` namespace via ArgoCD.

| Service | Image | Port | Ingress | Pool |
|---------|-------|------|---------|------|
| `agent-backend` | `ghcr.io/creatium/agent-backend` | 8000 | `api.creatium.com` | general |
| `agent-frontend` | `ghcr.io/creatium/agent-frontend` | 3000 | `app.creatium.com` | general |
| `tts-microservice` | `ghcr.io/creatium/tts-microservice` | 8000 | none (ClusterIP only) | compute |

**Adding a new service:**
1. Create `kubernetes/base/<service-name>/values.yaml` overriding the chart defaults
2. Create `argocd/applications/<service-name>.yaml` pointing at the shared chart and your values file
3. Merge to `main` — ArgoCD deploys automatically

---

## Node Pools

The cluster runs three purpose-specific node pools on Linode LKE (`us-east`):

| Pool | Label | Instance type | Nodes | Purpose |
|------|-------|---------------|-------|---------|
| General | `pool: general` | g6-standard-4 (4 vCPU / 8GB) | 2–8 (autoscaling) | APIs, web services, background workers |
| Compute | `pool: compute` | g6-dedicated-8 (8 vCPU dedicated / 16GB) | 1–5 (autoscaling) | ML inference, TTS, heavy processing |
| System | `pool: system` | g6-standard-2 (2 vCPU / 4GB) | 2 (fixed) | ArgoCD, monitoring, ingress controllers |

Services target a pool via `nodeSelector` in their `values.yaml`. The `tts-microservice` additionally uses a `NoSchedule` toleration so only compute workloads land on the expensive dedicated nodes.

---

## CI/CD — GitHub Actions

### Terraform Plan (PRs)

Triggered on any PR that modifies files under `terraform/**`.

1. Runs `terraform init`, `validate`, and `plan` for every environment in the matrix
2. Posts the full plan output as a PR comment for review before merge

### Terraform Apply (merge to main)

Triggered on any push to `main` that modifies files under `terraform/**`.

1. Runs `terraform init` and `terraform apply -auto-approve` for every environment
2. Infrastructure changes are applied immediately after merge

### Required GitHub Secrets

Set these at **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `LINODE_TOKEN` | Linode API token (create at cloud.linode.com → API Tokens) |
| `LINODE_OBJ_ACCESS_KEY` | Linode Object Storage access key (for Terraform state backend) |
| `LINODE_OBJ_SECRET_KEY` | Linode Object Storage secret key (for Terraform state backend) |

The Object Storage keys authenticate `terraform init` against the S3-compatible state backend at `us-east-1.linodeobjects.com`. Generate them at **Linode Cloud Manager → Object Storage → Access Keys**.

---

## Deploying to a New Linode Region

The Terraform modules are fully generic — adding a new region is a copy-and-edit operation.

**Effort: ~1–2 hours**

### Steps

**1. Create the new environment directory**

```bash
cp -r terraform/environments/linode-us terraform/environments/linode-eu
```

**2. Edit `terraform/environments/linode-eu/main.tf`**

Change the following values:

| Field | Current (`linode-us`) | New (`linode-eu`) |
|-------|-----------------------|-------------------|
| `region` | `"us-east"` | e.g. `"eu-central"` (Frankfurt), `"eu-west"` (London) |
| `cluster_name` | `"creatium-us"` | `"creatium-eu"` |
| `tags` | `["creatium", "production", "us-east"]` | `["creatium", "production", "eu-central"]` |
| Backend `key` | `"linode-us/terraform.tfstate"` | `"linode-eu/terraform.tfstate"` |

**3. Add the new environment to the GitHub Actions matrix**

In both `.github/workflows/terraform-plan.yml` and `.github/workflows/terraform-apply.yml`:

```yaml
matrix:
  environment: [linode-us, linode-eu]  # ← add new environment here
```

**4. Apply Terraform**

```bash
cd terraform/environments/linode-eu
terraform init
terraform apply
```

Or open a PR — the plan will be posted as a comment, merge to apply.

**5. Bootstrap ArgoCD into the new cluster**

```bash
# Get kubeconfig
terraform output -raw kubeconfig | base64 -d > ~/.kube/creatium-eu.yaml
export KUBECONFIG=~/.kube/creatium-eu.yaml

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply project and applications — services deploy automatically
kubectl apply -f argocd/projects/creatium.yaml
kubectl apply -f argocd/applications/
```

**What transfers automatically:** All Helm charts, service configurations, and ArgoCD applications — they are cloud and region agnostic.

**What you must recreate manually:** Kubernetes Secrets (API keys, database credentials, etc.) and any persistent volume data.

---

## Migrating to GCP (GKE)

A full cloud migration. The Kubernetes/Helm layer is entirely portable — the effort is concentrated in rewriting the Terraform layer.

**Effort: ~1–2 weeks**

### What stays the same (zero changes needed)

| Component | Reason |
|-----------|--------|
| Helm chart templates | Standard Kubernetes — no cloud-specific APIs |
| ArgoCD application manifests | Cloud-agnostic |
| All `values.yaml` files | Cloud-agnostic |
| GHCR container images | Accessible from any cloud |
| Node pool labels (`pool: general/compute/system`) | Applied as GKE node labels |

### What needs to be rewritten

**Terraform provider and resources:**

| Current (Linode) | GCP equivalent |
|------------------|----------------|
| `linode/linode` provider | `hashicorp/google` provider |
| `linode_lke_cluster` | `google_container_cluster` (GKE Standard) |
| `linode_lke_node_pool` | `google_container_node_pool` |
| `linode_firewall` | VPC + Subnet + `google_compute_firewall` + Cloud NAT |
| Linode Object Storage backend | GCS bucket backend |

**New GCP resources required:**

- **VPC + Subnet** — GKE uses VPC-native networking (alias IPs); cannot use the default VPC
- **Service Accounts + IAM** — GCP requires a service account per node pool with specific roles
- **Workload Identity** — replaces credential injection for pods that need GCP API access
- **GCS bucket** — replaces Linode Object Storage for Terraform state

**Instance type mapping (approximate):**

| Current Linode | Closest GCP equivalent |
|----------------|------------------------|
| g6-standard-2 (2 vCPU / 4GB) | `e2-standard-2` |
| g6-standard-4 (4 vCPU / 8GB) | `e2-standard-4` or `n2-standard-4` |
| g6-dedicated-8 (8 vCPU dedicated / 16GB) | `n2-standard-8` or `c2-standard-8` |

**Other changes:**

- **Ingress:** Keep nginx-ingress (no chart changes) or switch to GKE Gateway API with a GCP Load Balancer
- **Secrets:** Wire `externalSecrets` in `values.yaml` to GCP Secret Manager (the stub is already there)
- **GitHub Actions credentials:** Replace `LINODE_TOKEN` with GCP Workload Identity Federation (recommended) or a service account JSON key

### Migration strategy — blue/green, zero downtime

```
Week 1
  └── Build terraform/environments/gcp-us/ with GCP modules
      Stand up GKE cluster in parallel with existing Linode cluster
      Bootstrap ArgoCD on GKE → all services sync automatically from Git

Week 2
  └── Validate all services on GKE
      Migrate secrets to GCP Secret Manager
      Lower DNS TTL to 60 seconds

Week 3
  └── Cut DNS over to GKE load balancer IP
      Monitor for 24–48 hours
      terraform destroy on linode-us
```

The key insight: because ArgoCD syncs from this Git repo, the moment GKE is up and ArgoCD is bootstrapped, all services deploy automatically with no manifest changes. The migration is almost entirely Terraform work.

---

## Local Development

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional)

### Installing Terraform

#### macOS

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Verify
terraform version
```

> No Homebrew? Download the macOS binary directly from [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) and move it to `/usr/local/bin/`.

#### Linux (Ubuntu / Debian)

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install terraform

# Verify
terraform version
```

#### Linux (RHEL / Fedora / Amazon Linux)

```bash
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install terraform

# Verify
terraform version
```

#### Windows

Option 1 — Chocolatey (recommended):

```powershell
choco install terraform
```

Option 2 — Winget:

```powershell
winget install HashiCorp.Terraform
```

Option 3 — Manual: download the Windows zip from [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install), extract `terraform.exe`, and add its folder to your `PATH` environment variable.

```powershell
# Verify (PowerShell or CMD)
terraform version
```

---

### Running Terraform locally

```bash
cd terraform/environments/linode-us

# Copy and fill in secrets
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — never commit this file

# These are Linode Object Storage keys, not AWS keys.
# Terraform's S3 backend uses AWS SDK under the hood, so it reads
# these specific env var names even when the endpoint is Linode Object Storage.
export AWS_ACCESS_KEY_ID=<linode-obj-access-key>
export AWS_SECRET_ACCESS_KEY=<linode-obj-secret-key>

terraform init
terraform plan
terraform apply
```

### Linting Helm charts

```bash
helm lint kubernetes/charts/creatium-service -f kubernetes/base/agent-backend/values.yaml
helm lint kubernetes/charts/creatium-service -f kubernetes/base/agent-frontend/values.yaml
helm lint kubernetes/charts/creatium-service -f kubernetes/base/tts-microservice/values.yaml
```

### Getting the kubeconfig

```bash
cd terraform/environments/linode-us
terraform output -raw kubeconfig | base64 -d > ~/.kube/creatium-us.yaml
export KUBECONFIG=~/.kube/creatium-us.yaml
kubectl get nodes
```