output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "qa_service_ecr_url" {
  value = module.ecr.repository_urls["qa-service"]
}

output "lbc_irsa_role_arn" {
  value = module.iam.irsa_role_arns["aws-lbc"]
}

output "ssm_bastion_instance_id" {
  value = module.ssm_bastion.instance_id
}