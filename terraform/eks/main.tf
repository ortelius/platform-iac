terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.3"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "aws_region"   { default = "us-east-1" }
variable "cluster_name" { default = "pdvd-eks" }
variable "vpc_cidr"     { default = "10.0.0.0/16" }

variable "github_org"  { default = "ortelius" }
variable "github_repo" { default = "pdvd-platform" }
variable "github_token" {
  description = "GitHub PAT with repo + admin:public_key scopes"
  type        = string
  sensitive   = true
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}

# EKS auth for the flux kubernetes provider — uses the cluster's CA + token
data "aws_eks_cluster_auth" "flux" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "flux" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    token                  = data.aws_eks_cluster_auth.flux.token
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  }
  git = {
    url = "ssh://git@github.com/${var.github_org}/${var.github_repo}.git"
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }
}

# ── OIDC provider (shared by ALB controller and SOPS IRSA roles) ──────────────
data "aws_iam_openid_connect_provider" "eks" {
  url        = module.eks.cluster_oidc_issuer_url
  depends_on = [module.eks]
}

# ── IAM: AWS Load Balancer Controller ─────────────────────────────────────────
# Download the policy JSON before applying:
#   curl -o alb-controller-iam-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  policy = file("${path.module}/alb-controller-iam-policy.json")
}

data "aws_iam_policy_document" "alb_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ── ACM Certificate ───────────────────────────────────────────────────────────
resource "aws_acm_certificate" "app" {
  domain_name       = "app.deployhub.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ── Flux Bootstrap ────────────────────────────────────────────────────────────
resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "github_repository_deploy_key" "flux_eks" {
  title      = "flux-eks"
  repository = var.github_repo
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

resource "flux_bootstrap_git" "eks" {
  # Flux will install its components into clusters/eks/flux-system/
  # and watch clusters/eks/ for workload kustomizations
  path = "clusters/eks"

  components_extra = ["image-reflector-controller", "image-automation-controller"]

  # Ensure nodes are up and the deploy key exists before bootstrapping
  depends_on = [
    module.eks,
    github_repository_deploy_key.flux_eks,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"            { value = module.eks.cluster_name }
output "cluster_endpoint"        { value = module.eks.cluster_endpoint }
output "cluster_oidc_issuer_url" { value = module.eks.cluster_oidc_issuer_url }
output "vpc_id"                  { value = module.vpc.vpc_id }
output "public_subnet_ids"       { value = module.vpc.public_subnets }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
output "acm_certificate_arn"     { value = aws_acm_certificate.app.arn }
