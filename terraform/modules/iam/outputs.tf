output "irsa_role_arns" {
  description = "Map of logical name → IAM role ARN."
  value       = { for k, v in aws_iam_role.irsa : k => v.arn }
}

output "lbc_policy_arn" {
  value = aws_iam_policy.lbc.arn
}
