# ──────────────────────────────────────────────────────────────────────────────
# Module: ecr
# Creates ECR repositories with image scanning, lifecycle policies, and
# an IAM policy that allows the EKS node role to pull images.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = each.value })
}

# ── Lifecycle policy – keep last 20 tagged images, delete untagged after 1 day
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Allow EKS node role to pull images ───────────────────────────────────────
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "AllowEKSNodePull"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.node_iam_role_arn]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_pull.json
}
