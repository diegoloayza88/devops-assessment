variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster will be deployed."
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs for cluster nodes."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the EKS API endpoint should be publicly accessible."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (if enabled)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# General node group
variable "general_instance_types" {
  type    = list(string)
  default = ["m6i.large"]
}

variable "general_desired_size" {
  type    = number
  default = 2
}

variable "general_min_size" {
  type    = number
  default = 1
}

variable "general_max_size" {
  type    = number
  default = 5
}

# GPU node group
variable "enable_gpu_nodes" {
  description = "Set to true to create the GPU node group for vLLM."
  type        = bool
  default     = false
}

variable "gpu_instance_types" {
  type    = list(string)
  default = ["g4dn.xlarge"]
}

variable "gpu_capacity_type" {
  description = "ON_DEMAND or SPOT for the GPU node group."
  type        = string
  default     = "ON_DEMAND"
}

variable "gpu_desired_size" {
  type    = number
  default = 1
}

variable "gpu_min_size" {
  type    = number
  default = 0
}

variable "gpu_max_size" {
  type    = number
  default = 3
}

variable "tags" {
  type    = map(string)
  default = {}
}
