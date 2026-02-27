terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

resource "linode_lke_node_pool" "this" {
  cluster_id = var.cluster_id
  type       = var.instance_type
  node_count = var.autoscaler_enabled ? var.min_nodes : var.node_count

  dynamic "autoscaler" {
    for_each = var.autoscaler_enabled ? [1] : []
    content {
      min = var.min_nodes
      max = var.max_nodes
    }
  }

  tags = var.tags
}

output "pool_id" {
  description = "The ID of the node pool"
  value       = linode_lke_node_pool.this.id
}

output "node_count" {
  description = "Current number of nodes"
  value       = linode_lke_node_pool.this.node_count
}
