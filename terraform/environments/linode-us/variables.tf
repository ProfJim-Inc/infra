variable "linode_api_token" {
  description = "Linode API token — set via LINODE_TOKEN env var or terraform.tfvars"
  type        = string
  sensitive   = true
}

variable "allowed_kube_api_cidrs" {
  description = "CIDR blocks allowed to access the Kubernetes API"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # TODO: restrict to office/VPN IPs
}
