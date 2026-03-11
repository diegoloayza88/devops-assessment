# ──────────────────────────────────────────────────────────────────────────────
# Environment: dev
# Consumes the vpc, eks, ecr, and iam modules to build a full
# AI Q&A platform stack.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  env          = "dev"
  cluster_name = "${var.project}-${local.env}"

  common_tags = {
    Project     = var.project
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  name         = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  az_count     = 3
  cluster_name = local.cluster_name
  tags         = local.common_tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  cluster_name           = local.cluster_name
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.private_subnet_ids
  endpoint_public_access = false   # only via VPN / bastion in prod

  # General workload nodes (FastAPI, system add-ons)
  general_instance_types = ["m6i.xlarge"]
  general_desired_size   = 2
  general_min_size       = 1
  general_max_size       = 5

  # CPU-only vLLM works fine for SmolLM2-135M – flip to true + g4dn for GPU
  enable_gpu_nodes = false

  tags = local.common_tags
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  repository_names  = ["qa-service"]
  node_iam_role_arn = module.eks.node_iam_role_arn
  tags              = local.common_tags
}

# ── SSM Bastion ───────────────────────────────────────────────────────────────
module "ssm_bastion" {
  source = "../../modules/ssm-bastion"

  name              = local.cluster_name
  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.private_subnet_ids[0]
  eks_cluster_sg_id = module.eks.cluster_security_group_id
  tags              = local.common_tags
}

# ── IAM / IRSA ────────────────────────────────────────────────────────────────
module "iam" {
  source = "../../modules/iam"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  irsa_roles = {
    # AWS Load Balancer Controller
    "aws-lbc" = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      policy_arns     = [module.iam.lbc_policy_arn]
    }
    # Cluster Autoscaler
    "cluster-autoscaler" = {
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
      policy_arns     = ["arn:aws:iam::aws:policy/AutoScalingFullAccess"]
    }
  }

  tags = local.common_tags
}
