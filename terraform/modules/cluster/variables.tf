variable "cluster_name" {
  description = "Name of the LKE cluster"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "region" {
  description = "Linode region for the cluster"
  type        = string
}

variable "default_pool_type" {
  description = "Instance type for the default node pool"
  type        = string
  default     = "g6-standard-2"
}

variable "default_pool_count" {
  description = "Number of nodes in the default pool"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags to apply to the cluster"
  type        = list(string)
  default     = []
}
