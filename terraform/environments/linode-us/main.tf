# =============================================================================
# Creatium US — Linode LKE cluster (us-ord / Chicago)
#
# How to read this file:
#   This file declares the Kubernetes cluster and all its node pools using
#   reusable modules defined under terraform/modules/. Think of modules like
#   functions — you call them with different arguments to create similar resources
#   without repeating yourself.
#
# How to apply:
#   1. Export Linode Object Storage keys as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#      (Terraform's S3 backend uses AWS SDK under the hood — it reads these specific
#       env var names even when the endpoint is Linode Object Storage)
#   2. Copy terraform.tfvars.example → terraform.tfvars and set linode_api_token
#   3. terraform init     → downloads the Linode provider plugin
#   4. terraform plan     → shows what will be created (safe, read-only)
#   5. terraform apply    → creates the actual resources (~5-10 min)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state backend: Linode Object Storage (S3-compatible)
  #
  # Terraform needs to track what it has already created in a "state file."
  # Storing this in Object Storage (instead of locally) means:
  #   - Everyone on the team shares the same state — no conflicts
  #   - CI/CD can apply Terraform without checking out state from Git
  #   - State is never accidentally committed to the repo (it contains sensitive IDs)
  #
  # Create the bucket once before running terraform init:
  #   linode-cli obj mb creatium-terraform-state --cluster us-ord-1
  #
  # The skip_* flags are required because Linode Object Storage is S3-compatible
  # but not AWS — it doesn't support all AWS-specific validation checks.
  # ---------------------------------------------------------------------------
  backend "s3" {
    bucket                      = "creatium-terraform-state"
    key                         = "linode-us/terraform.tfstate"  # path within the bucket
    region                      = "us-ord-1"                     # Linode region ID for Object Storage
    endpoints = {
      s3 = "https://us-ord-1.linodeobjects.com"                  # Linode's S3-compatible endpoint
    }
    use_path_style              = true   # required for non-AWS S3 providers
    skip_credentials_validation = true   # Linode doesn't support AWS STS for cred validation
    skip_metadata_api_check     = true   # no EC2 metadata API on Linode
    skip_region_validation      = true   # "us-ord-1" isn't a real AWS region
    skip_requesting_account_id  = true   # no AWS account ID concept
    skip_s3_checksum            = true   # Linode doesn't support AWS checksum headers
  }
}

# The Linode provider authenticates via API token (set in terraform.tfvars).
# Never hardcode the token here — always read from a variable.
provider "linode" {
  token = var.linode_api_token
}

# =============================================================================
# Cluster
#
# This creates the managed Kubernetes control plane on Linode LKE.
# "Managed" means Linode runs the master nodes (API server, etcd, scheduler).
# We only pay for and manage the worker nodes.
#
# Note: the "default pool" here is the minimum required by Linode LKE to create
# the cluster. We immediately supplement it with purpose-specific pools below.
# The default pool runs alongside the system_pool and should ideally be removed
# (or kept minimal) to avoid paying for unused capacity.
# =============================================================================
module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = "creatium-us"
  k8s_version        = "1.34"
  region             = "us-ord"              # Chicago — good latency for US-East users
  default_pool_type  = "g6-standard-2"       # 2 vCPU, 4 GB RAM
  default_pool_count = 1                     # TODO: restore to 2 after Linode limit increase
  tags               = ["creatium", "production", "us-ord"]
}

# =============================================================================
# Node Pools
#
# Why separate pools?
#   - COST: GPU nodes are expensive ($X/hr). By using a separate pool with a taint,
#     only the TTS microservice can be scheduled there — no accidental GPU waste.
#   - ISOLATION: Ops tools (Prometheus, ArgoCD) don't share nodes with business services.
#     If a business service has a memory leak or CPU spike, it can't affect monitoring.
#   - PREDICTABILITY: Dedicated vs. shared instance types matter for ML workloads.
#     CPU-heavy ML inference gets dedicated cores on the compute pool, not shared vCPUs.
#   - SCALING: Each pool autoscales independently. A traffic spike on the API scales
#     general_pool, not compute_pool (which is reserved for ML jobs).
#
# Pods target a specific pool via nodeSelector in their Helm values:
#   nodeSelector:
#     pool: general    ← this label is set on every node in the general pool
# =============================================================================

# ---------------------------------------------------------------------------
# General pool — APIs, web services, background workers
#
# This is where most services run: agent-backend, agent-frontend, demo-service.
# Standard shared-CPU instances are sufficient; most services are I/O-bound,
# not CPU-bound, so shared vCPUs work well.
#
# Autoscaling: the Cluster Autoscaler adds nodes when pods are unschedulable
# due to insufficient CPU/memory, and removes idle nodes to save cost.
# ---------------------------------------------------------------------------
module "general_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-4"    # 4 vCPU (shared), 8 GB RAM
  autoscaler_enabled = true
  min_nodes          = 2                  # always keep 2 for HA (one node can drain without downtime)
  max_nodes          = 8                  # cap at 8 to limit surprise cost spikes
  tags               = ["pool:general", "creatium"]
  labels             = { pool = "general" }   # applied to every node — used by nodeSelector
}

# ---------------------------------------------------------------------------
# Compute pool — CPU-intensive ML inference, heavy data processing
#
# Dedicated CPU instances guarantee consistent performance for latency-sensitive
# ML workloads. Shared vCPUs can be throttled under contention on busy hosts.
# ---------------------------------------------------------------------------
module "compute_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-dedicated-8"   # 6 vCPU (dedicated), 12 GB RAM
  autoscaler_enabled = true
  min_nodes          = 2                  # keep 2 warm to avoid cold-start latency on ML requests
  max_nodes          = 5
  tags               = ["pool:compute", "creatium"]
  labels             = { pool = "compute" }
}

# ---------------------------------------------------------------------------
# GPU pool — TTS inference (NVIDIA RTX 6000 Ada)
#
# Fixed size (no autoscaler) because:
#   1. GPU nodes are expensive — autoscaling to 0 would cause unacceptable cold start
#   2. Only one service (tts-microservice) uses this pool
#   3. Linode's GPU node provisioning is slow (~10 min), not suitable for autoscaling
#
# TAINT: nvidia.com/gpu=present:NoSchedule
#   This taint repels all pods that don't explicitly declare a matching toleration.
#   Only tts-microservice has:
#     tolerations:
#       - key: "nvidia.com/gpu"
#         operator: "Equal"
#         value: "present"
#         effect: "NoSchedule"
#   This guarantees the GPU node is never wasted on non-GPU workloads.
# ---------------------------------------------------------------------------
module "gpu_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g2-gpu-rtx4000a1-m"   # NVIDIA RTX 6000 Ada, 48 GB VRAM
  autoscaler_enabled = false                   # fixed size — see explanation above
  node_count         = 1
  tags               = ["pool:gpu", "creatium"]
  labels             = { pool = "gpu" }
  taints = [{
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NoSchedule"   # pods without the matching toleration are rejected
  }]
}

# ---------------------------------------------------------------------------
# System pool — monitoring, ArgoCD, ingress, logging
#
# Fixed size (no autoscaler) because:
#   - These workloads must be running for the cluster to be observable
#   - Auto-removing system nodes during "idle" periods could take down monitoring
#   - 2 nodes ensures the ops stack survives a single node failure
#
# All monitoring/logging Helm charts use nodeSelector: { pool: system }
# to ensure they always land here, never on general/compute nodes.
# ---------------------------------------------------------------------------
module "system_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-2"    # 2 vCPU, 4 GB RAM — sufficient for ops workloads
  autoscaler_enabled = false
  node_count         = 2                  # 2 for HA: Prometheus + Grafana can survive node drain
  tags               = ["pool:system", "creatium"]
  labels             = { pool = "system" }
}

# =============================================================================
# Networking
#
# Creates a Linode Cloud Firewall that:
#   - Restricts kube-apiserver access to IP ranges in var.allowed_kube_api_cidrs
#     (your office IPs, VPN CIDRs, CI/CD runner IPs)
#   - Allows all other necessary Kubernetes traffic (pod-to-pod, NodePort, etc.)
#
# Why restrict the API server?
#   The kube-apiserver is the "brain" of Kubernetes. If an attacker gets access,
#   they can do anything in the cluster. Restricting it to known IPs massively
#   reduces the attack surface.
# =============================================================================
module "networking" {
  source = "../../modules/networking"

  cluster_name            = "creatium-us"
  allowed_kube_api_cidrs  = var.allowed_kube_api_cidrs   # set in terraform.tfvars
  tags                    = ["creatium", "us-east"]
}

# =============================================================================
# Outputs
#
# These values are available after `terraform apply` via:
#   terraform output cluster_id
#   terraform output -raw kubeconfig | base64 -d > ~/.kube/creatium-us.yaml
#
# The kubeconfig is marked sensitive so it doesn't print in CI logs.
# =============================================================================
output "cluster_id" {
  description = "Linode LKE cluster ID — useful for linode-cli commands"
  value       = module.cluster.cluster_id
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig — pipe through 'base64 -d' to use with kubectl"
  value       = module.cluster.kubeconfig
  sensitive   = true   # prevents accidental logging of credentials in CI output
}
