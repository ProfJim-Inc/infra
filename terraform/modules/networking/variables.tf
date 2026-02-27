variable "cluster_name" {
  description = "Name prefix for networking resources"
  type        = string
}

variable "allowed_kube_api_cidrs" {
  description = "CIDR blocks allowed to access the Kubernetes API"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict this in production
}

variable "tags" {
  description = "Tags for networking resources"
  type        = list(string)
  default     = []
}
