terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

# Firewall for the cluster nodes
resource "linode_firewall" "cluster" {
  label = "${var.cluster_name}-firewall"

  # Allow inbound HTTPS
  inbound {
    label    = "allow-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Allow inbound HTTP (for cert-manager ACME challenges)
  inbound {
    label    = "allow-http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Allow Kubernetes API
  inbound {
    label    = "allow-kube-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443"
    ipv4     = var.allowed_kube_api_cidrs
  }

  # Allow NodePort range (if needed)
  inbound {
    label    = "allow-nodeports"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # Default: allow all outbound
  outbound_policy = "ACCEPT"

  # Default: drop all other inbound
  inbound_policy = "DROP"

  tags = var.tags
}

output "firewall_id" {
  value = linode_firewall.cluster.id
}
