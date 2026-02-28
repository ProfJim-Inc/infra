terraform {
  required_version = ">= 1.5.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }

  # Store state in Linode Object Storage (S3-compatible)
  # Create the bucket manually first: linode-cli obj mb creatium-terraform-state
  backend "s3" {
    bucket                      = "creatium-terraform-state"
    key                         = "linode-us/terraform.tfstate"
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

# -----------------------------------------------
# Cluster
# -----------------------------------------------
module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = "creatium-us"
  k8s_version        = "1.34"
  region             = "us-east"
  default_pool_type  = "g6-standard-2"
  default_pool_count = 1  # TODO: restore to 2 after limit increase
  tags               = ["creatium", "production", "us-east"]
}

# -----------------------------------------------
# Node Pools
# -----------------------------------------------

# General pool: APIs, web services, background workers
module "general_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-4"    # 4 vCPU, 8GB RAM
  autoscaler_enabled = true
  min_nodes          = 1  # TODO: restore to 2 after limit increase
  max_nodes          = 8
  tags               = ["pool:general", "creatium"]
}

# Compute pool: ML inference, heavy processing
module "compute_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-dedicated-8"   # 6 vCPU dedicated, 12GB RAM
  autoscaler_enabled = true
  min_nodes          = 1
  max_nodes          = 5
  tags               = ["pool:compute", "creatium"]
}

# System pool: monitoring, ArgoCD, ingress (fixed size)
module "system_pool" {
  source = "../../modules/node-pool"

  cluster_id         = module.cluster.cluster_id
  instance_type      = "g6-standard-2"    # 2 vCPU, 4GB RAM
  autoscaler_enabled = false
  node_count         = 1  # TODO: restore to 2 after limit increase
  tags               = ["pool:system", "creatium"]
}

# -----------------------------------------------
# Networking
# -----------------------------------------------
module "networking" {
  source = "../../modules/networking"

  cluster_name         = "creatium-us"
  allowed_kube_api_cidrs = var.allowed_kube_api_cidrs
  tags                 = ["creatium", "us-east"]
}

# -----------------------------------------------
# Outputs
# -----------------------------------------------
output "cluster_id" {
  value = module.cluster.cluster_id
}

output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}
