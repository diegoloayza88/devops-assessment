variable "name" {
  description = "Name prefix applied to all resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to use (creates one public + one private subnet per AZ)."
  type        = number
  default     = 3
}

variable "cluster_name" {
  description = "EKS cluster name – used for subnet auto-discovery tags."
  type        = string
}

variable "tags" {
  description = "Map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}
