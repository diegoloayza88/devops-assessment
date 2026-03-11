# ──────────────────────────────────────────────────────────────────────────────
# Module: iam
# Creates IRSA roles for:
#   • AWS Load Balancer Controller
#   • (optional) Cluster Autoscaler
#   • QA service pod (read-only SSM/Secrets Manager access)
# ──────────────────────────────────────────────────────────────────────────────

locals {
  oidc_host = replace(var.oidc_provider_url, "https://", "")
}

# ── Helper: IRSA assume-role policy factory ───────────────────────────────────
data "aws_iam_policy_document" "irsa_assume" {
  for_each = var.irsa_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = var.irsa_roles

  name               = "${var.cluster_name}-${each.key}-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.key].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = {
    for combo in flatten([
      for role_key, role_val in var.irsa_roles : [
        for idx, arn in role_val.policy_arns : {
          key        = "${role_key}-${idx}"
          role       = role_key
          policy_arn = arn
        }
      ]
    ]) : combo.key => combo
  }

  role       = aws_iam_role.irsa[each.value.role].name
  policy_arn = each.value.policy_arn
}

# ── AWS Load Balancer Controller IAM Policy ───────────────────────────────────
# (Inline policy containing the full LBC permissions set)
resource "aws_iam_policy" "lbc" {
  name        = "${var.cluster_name}-aws-lbc-policy"
  description = "IAM policy for the AWS Load Balancer Controller"

  # Minimal policy for demo – in production download the official policy JSON
  # from https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:*",
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "waf-regional:*",
          "wafv2:*",
          "shield:*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

