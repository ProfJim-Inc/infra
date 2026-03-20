# =============================================================================
# Creatium US Staging — Linode LKE cluster (us-ord / Chicago)
#
# Staging mirror of the production cluster with reduced resources:
#   - No GPU pool (staging doesn't need GPU inference)
#   - Smaller autoscaler limits (cost savings)
#   - Same region and k8s version as production
#
# How to apply:
#   1. Export Linode Object Storage keys as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
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

  backend "s3" {
    bucket                      = "creatium-terraform-state"
    key                         = "linode-us-stage/terraform.tfstate"
    region                      = "us-ord-1"
    endpoints = {
      s3 = "https://us-ord-1.linodeobjects.com"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "linode" {
  token = var.linode_api_token
}

# =============================================================================
# Cluster
# =============================================================================
module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = "creatium-us-stage"
  k8s_version        = "1.34"
  region             = "us-ord"
  default_pool_type  = "g6-standard-2"
  default_pool_count = 1
  tags               = ["creatium", "staging", "us-ord"]
}

# =============================================================================
# Node Pools
#
# Staging runs the same pool types as production minus the GPU pool.
# Autoscaler limits are lower to control cost — staging doesn't need
# the same capacity headroom as production.
# =============================================================================

# ---------------------------------------------------------------------------
# General pool — APIs, web services, background workers
# ---------------------------------------------------------------------------
module "general_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-4"
  autoscaler_enabled = true
  min_nodes          = 1                  # staging: 1 is fine, no HA requirement
  max_nodes          = 2
  tags               = ["pool:general", "creatium", "staging"]
  labels             = { pool = "general" }
}

# ---------------------------------------------------------------------------
# Compute pool — CPU-intensive ML inference
#
# Smaller than production: single node minimum, lower max.
# Staging ML workloads are for validation, not production traffic.
# ---------------------------------------------------------------------------
module "compute_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-dedicated-8"
  autoscaler_enabled = true
  min_nodes          = 1
  max_nodes          = 2
  tags               = ["pool:compute", "creatium", "staging"]
  labels             = { pool = "compute" }
}

# ---------------------------------------------------------------------------
# System pool — monitoring, ArgoCD, ingress, logging
#
# Autoscaling 1-2: staging can tolerate brief monitoring gaps during
# scale-up. Production keeps a fixed 2-node pool for HA.
# ---------------------------------------------------------------------------
module "system_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-2"
  autoscaler_enabled = true
  min_nodes          = 1
  max_nodes          = 2
  tags               = ["pool:system", "creatium", "staging"]
  labels             = { pool = "system" }
}

# =============================================================================
# Networking
# =============================================================================
module "networking" {
  source = "../../modules/networking"

  cluster_name            = "creatium-us-stage"
  allowed_kube_api_cidrs  = var.allowed_kube_api_cidrs
  tags                    = ["creatium", "staging", "us-ord"]
}

# =============================================================================
# Outputs
# =============================================================================
output "cluster_id" {
  description = "Linode LKE staging cluster ID"
  value       = module.cluster.cluster_id
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig for the staging cluster"
  value       = module.cluster.kubeconfig
  sensitive   = true
}
