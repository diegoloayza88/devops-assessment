variable "repository_names" {
  description = "List of ECR repository names to create."
  type        = list(string)
}

variable "node_iam_role_arn" {
  description = "ARN of the EKS node IAM role that needs pull access."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
