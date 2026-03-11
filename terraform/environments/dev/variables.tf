variable "aws_region" {
  description = "AWS region to deploy resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used as a prefix for all resources."
  type        = string
  default     = "ai-qa"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "eks_admin_arns" {
  description = "List of IAM user or role ARNs to grant cluster-admin access."
  type        = list(string)
  default     = []
}
