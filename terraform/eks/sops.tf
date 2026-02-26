/*
  sops.tf — EKS SOPS decryption infrastructure

  Provisions the AWS KMS key and IRSA role that allow kustomize-controller
  to decrypt SOPS secrets in clusters/eks/ without static credentials.

  After apply, copy the outputs into:
    .sops.yaml
      → aws_kms: <kms_key_arn output>

    clusters/eks/flux-system/kustomization.yaml
      → patches: kustomize-controller ServiceAccount annotation
        eks.amazonaws.com/role-arn: <flux_sops_role_arn output>
*/

# ── KMS key ───────────────────────────────────────────────────────────────────
resource "aws_kms_key" "sops" {
  description             = "SOPS encryption key for Flux — EKS cluster"
  deletion_window_in_days = 10

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "sops" {
  name          = "alias/${var.cluster_name}-flux-sops"
  target_key_id = aws_kms_key.sops.key_id
}

# ── IRSA role for kustomize-controller ───────────────────────────────────────
# Reuses data.aws_iam_openid_connect_provider.eks declared in main.tf
data "aws_iam_policy_document" "flux_sops_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:flux-system:kustomize-controller"]
    }
  }
}

resource "aws_iam_role" "flux_sops" {
  name               = "${var.cluster_name}-flux-sops"
  assume_role_policy = data.aws_iam_policy_document.flux_sops_assume.json

  # kustomize-controller's SA is created during Flux bootstrap
  depends_on = [flux_bootstrap_git.eks]
}

resource "aws_iam_role_policy" "flux_sops_kms" {
  role = aws_iam_role.flux_sops.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.sops.arn
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "kms_key_arn" {
  description = "Use in .sops.yaml aws_kms field"
  value       = aws_kms_key.sops.arn
}
output "kms_key_alias" {
  value = aws_kms_alias.sops.name
}
output "flux_sops_role_arn" {
  description = "Annotate kustomize-controller SA with: eks.amazonaws.com/role-arn"
  value       = aws_iam_role.flux_sops.arn
}
