#!/usr/bin/env bash
# deploy.sh — deploy GKE or EKS independently
#
# Usage:
#   ./deploy.sh gke [plan|apply|destroy]
#   ./deploy.sh eks [plan|apply|destroy]
#
# Requires:
#   export TF_VAR_github_token="ghp_..."
#
# GKE also requires:  gcloud auth application-default login
# EKS also requires:  aws configure  (or AWS_* env vars set)

set -euo pipefail

CLUSTER="${1:-}"
ACTION="${2:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <gke|eks> [plan|apply|destroy]"
  exit 1
}

[[ -z "$CLUSTER" ]] && usage
[[ "$CLUSTER" != "gke" && "$CLUSTER" != "eks" ]] && usage
[[ -z "${TF_VAR_github_token:-}" ]] && { echo "ERROR: TF_VAR_github_token is not set"; exit 1; }

WORKDIR="$SCRIPT_DIR/$CLUSTER"

# EKS pre-flight: ensure the ALB controller policy JSON is present
if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

echo ""
echo "══════════════════════════════════════════"
echo "  Cluster : $CLUSTER"
echo "  Action  : $ACTION"
echo "  Dir     : $WORKDIR"
echo "══════════════════════════════════════════"
echo ""

cd "$WORKDIR"

terraform init -upgrade

case "$ACTION" in
  plan)
    terraform plan
    ;;
  apply)
    terraform apply -auto-approve
    echo ""
    echo "── Outputs ──────────────────────────────"
    terraform output
    ;;
  destroy)
    echo "WARNING: This will destroy the $CLUSTER cluster and all resources."
    read -r -p "Type the cluster name to confirm: " CONFIRM
    [[ "$CONFIRM" != "$CLUSTER" ]] && { echo "Aborted."; exit 1; }
    terraform destroy
    ;;
  *)
    usage
    ;;
esac
