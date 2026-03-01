terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

resource "linode_lke_cluster" "this" {
  label       = var.cluster_name
  k8s_version = var.k8s_version
  region      = var.region

  tags = var.tags

  # Node pools are managed separately via the node-pool module
  # This creates the cluster with a minimal default pool
  pool {
    type  = var.default_pool_type
    count = var.default_pool_count
  }

  lifecycle {
    # Autoscaler changes node counts on this inline pool — ignore to prevent perpetual diffs
    ignore_changes = [pool]
  }
}

output "cluster_id" {
  description = "The ID of the LKE cluster"
  value       = linode_lke_cluster.this.id
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig for the cluster"
  value       = linode_lke_cluster.this.kubeconfig
  sensitive   = true
}

output "api_endpoints" {
  description = "API endpoints for the cluster"
  value       = linode_lke_cluster.this.api_endpoints
}
