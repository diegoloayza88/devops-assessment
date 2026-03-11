variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "eks_cluster_sg_id" {
  description = "EKS cluster security group ID to allow bastion access."
  type        = string
}