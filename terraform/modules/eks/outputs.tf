output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider – used to create IRSA roles."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.this.url
}

output "node_security_group_id" {
  value = aws_security_group.nodes.id
}

output "node_iam_role_arn" {
  value = aws_iam_role.node.arn
}

output "cluster_security_group_id" {
  value = aws_security_group.cluster.id
}