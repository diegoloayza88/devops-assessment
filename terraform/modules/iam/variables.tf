variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "irsa_roles" {
  description = "Map of logical name → IRSA role definition."
  type = map(object({
    namespace       = string
    service_account = string
    policy_arns     = list(string)
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}