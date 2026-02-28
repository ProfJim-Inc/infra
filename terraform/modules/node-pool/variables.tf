variable "cluster_id" {
  description = "ID of the LKE cluster to add this pool to"
  type        = number
}

variable "instance_type" {
  description = "Linode instance type (e.g., g6-standard-4, g6-dedicated-8)"
  type        = string
}

variable "node_count" {
  description = "Fixed number of nodes (used when autoscaler is disabled)"
  type        = number
  default     = 2
}

variable "autoscaler_enabled" {
  description = "Whether to enable autoscaling for this pool"
  type        = bool
  default     = false
}

variable "min_nodes" {
  description = "Minimum nodes when autoscaling is enabled"
  type        = number
  default     = 2
}



variable "max_nodes" {
  description = "Maximum nodes when autoscaling is enabled"
  type        = number
  default     = 4
}

variable "tags" {
  description = "Tags to apply to the node pool"
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Kubernetes node labels to apply to all nodes in the pool"
  type        = map(string)
  default     = {}
}
