#!/usr/bin/env bash
# deploy.sh — Consolidates secret management, infrastructure provisioning, and DNS setup
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
CLUSTER_NAME=$(grep 'cluster_name' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
SECRETS_OUT="$SCRIPT_DIR/../clusters/$CLUSTER/pdvd/secrets.enc.yaml"
KEY_FILE="$HOME/.ssh/${CLUSTER_NAME}.sops.key"

ensure_tools() {
  if ! command -v age-keygen &>/dev/null; then
    echo "Installing age..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | grep tag_name | cut -d'"' -f4)
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/$VERSION/age-$VERSION-$OS-$ARCH.tar.gz" -o /tmp/age.tar.gz
    tar -xzf /tmp/age.tar.gz -C /tmp && sudo mv /tmp/age/age* /usr/local/bin/ && rm -rf /tmp/age*
  fi
  if ! command -v sops &>/dev/null; then
    echo "Installing sops..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)
    sudo curl -fsSL "https://github.com/getsops/sops/releases/download/$VERSION/sops-$VERSION.$OS.$ARCH" -o /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
  fi
}

ensure_flux_cli() {
  if ! command -v flux &>/dev/null; then
    echo "Installing flux CLI..."
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    FLUX_VERSION=$(curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | grep tag_name | cut -d'"' -f4 | tr -d v)
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${OS}_${ARCH}.tar.gz" -o /tmp/flux.tar.gz
    tar -xzf /tmp/flux.tar.gz -C /tmp flux && sudo mv /tmp/flux /usr/local/bin/flux && rm /tmp/flux.tar.gz
  fi
}

ensure_secrets() {
  ensure_tools

  if [ ! -f "$KEY_FILE" ]; then
    echo "Generating age key: $KEY_FILE"
    mkdir -p "$HOME/.ssh" && age-keygen -o "$KEY_FILE" && chmod 600 "$KEY_FILE"
  fi

  AGE_PUBKEY=$(grep "^# public key:" "$KEY_FILE" | awk '{print $4}')

  # Always write .sops.yaml so it stays in sync with the current key
  cat > "$SCRIPT_DIR/../clusters/.sops.yaml" <<SOPS
creation_rules:
  - path_regex: clusters/eks/.*\\.yaml$
    age: $AGE_PUBKEY
  - path_regex: clusters/gke/.*\\.yaml$
    age: $AGE_PUBKEY
SOPS

  if [ ! -f "$SECRETS_OUT" ]; then
    echo "--- Interactive Secret Setup for $CLUSTER ---"

    read -rp "  smtp.username                : " SMTP_USER
    read -rp "  pdvd-arangodb.arangodb_pass  : " DB_PASS
    read -rp "  pdvd-backend.rbac_repo_token : " RBAC_TOKEN
    read -rp "  pdvd-backend.clientSecret    : " GH_SECRET
    read -rp "  pdvd-backend.appId           : " GH_APP_ID
    read -rp "  pdvd-backend.clientId        : " GH_CLIENT_ID
    read -rp "  pdvd-backend.baseUrl         : " BASE_URL
    read -rp "  smtp.password                : " SMTP_PASS
    echo "  pdvd-backend.privateKey (Paste PEM block, then press Ctrl-D on a new line):"
    GH_KEY=$(cat)

    TMP=$(mktemp --suffix=.yaml)

    # 1. Base secrets for the application (always created)
    cat > "$TMP" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: pdvd-secrets
  namespace: flux-system
stringData:
  values.yaml: |
    pdvd-arangodb:
      arangodb_pass: "${DB_PASS}"
    pdvd-backend:
      baseUrl: "${BASE_URL}"
      rbac_repo_token: "${RBAC_TOKEN}"
      github:
        appId: "${GH_APP_ID}"
        clientId: "${GH_CLIENT_ID}"
        clientSecret: "${GH_SECRET}"
        privateKey: |
$(echo "$GH_KEY" | sed 's/^/          /')
    smtp:
      username: "${SMTP_USER}"
      password: "${SMTP_PASS}"
YAML

    # 2. Conditionally append Cloudflare token for ExternalDNS
    DNS_PROVIDER=$(grep 'dns_provider' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2 || echo "route53")

    if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
      cat >> "$TMP" <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: pdvd-secrets
  namespace: kube-system
stringData:
  cloudflare.apiToken: "${TF_VAR_cloudflare_api_token:-}"
YAML
    fi

    # 3. Encrypt the combined file
    sops --encrypt \
      --input-type yaml \
      --output-type yaml \
      --age "$AGE_PUBKEY" \
      --encrypted-regex '^(data|stringData)$' \
      "$TMP" > "$SECRETS_OUT"
    rm "$TMP"

    # Verify the output has plaintext metadata before committing
    echo "Verifying encryption (apiVersion should be plaintext):"
    head -4 "$SECRETS_OUT"

    REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
    cd "$REPO_ROOT"
    git add clusters/.sops.yaml "$SECRETS_OUT"
    if ! git diff --cached --quiet; then
      git commit -m "chore($CLUSTER): add encrypted secrets and sops config"
      git push --set-upstream origin main
      echo "✓ Secrets committed and pushed"
    fi

    echo "✓ Secrets encrypted and written to $SECRETS_OUT"
  fi
}

# ── Pre-destroy: use Flux to cleanly delete all workloads ─────────────────────
#
# Sequence:
#   1. Verify the cluster exists and its API server is reachable.
#   2. Verify Flux is installed — skip gracefully if not.
#   3. Suspend all Kustomizations — stops Flux re-creating things as we delete.
#   4. Delete infrastructure HelmReleases first (ALB controller, external-dns,
#      ingress controllers). Helm runs each chart's uninstall hooks, which fire
#      the controller finalizers that remove ALBs/NLBs/GLBs from the cloud.
#   5. Delete remaining HelmReleases (app workloads).
#   6. Poll until all cloud load balancers are gone — terraform destroy will
#      fail trying to delete the VPC/subnets if any LBs still hold ENIs.
#   7. flux uninstall — removes all Flux CRDs, controllers, and flux-system.
#      Terraform then has a completely clean cluster to tear down.
#
# The entire function runs with errexit disabled (set +e) so that any individual
# step failure — a missing resource, a timed-out API call, a partial Flux
# install — is reported and skipped rather than aborting the whole destroy.
# errexit is restored before returning so the rest of the script stays strict.
drain_flux_workloads() {
  echo ""
  echo "════════ Pre-destroy: draining Flux workloads ($CLUSTER_NAME) ════════"

  # Disable errexit for the entire drain — every error is handled explicitly.
  set +e

  ensure_flux_cli
  local FLUX_CLI_OK=$?
  if [[ $FLUX_CLI_OK -ne 0 ]]; then
    echo "  ⚠  Could not install flux CLI. Skipping Flux drain."
    set -e
    return 0
  fi

  # ── 1. Resolve cloud credentials & verify the cluster exists ────────────────
  local AWS_REGION GCP_REGION GCP_PROJECT
  local CLUSTER_REACHABLE=false

  if [[ "$CLUSTER" == "eks" ]]; then
    AWS_REGION=$(grep 'aws_region' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)

    # Check the cluster even exists in AWS before touching kubeconfig
    local CLUSTER_STATUS
    CLUSTER_STATUS=$(aws eks describe-cluster \
      --name "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --query 'cluster.status' \
      --output text 2>/dev/null)

    if [[ -z "$CLUSTER_STATUS" ]]; then
      echo "  ⚠  EKS cluster '$CLUSTER_NAME' not found in AWS — already destroyed or never created."
      echo "     Skipping Flux drain."
      set -e; return 0
    fi

    if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
      echo "  ⚠  EKS cluster '$CLUSTER_NAME' is in state '$CLUSTER_STATUS' — cannot drain."
      echo "     Skipping Flux drain and proceeding to terraform destroy."
      set -e; return 0
    fi

    echo "  EKS cluster '$CLUSTER_NAME' is ACTIVE. Fetching kubeconfig..."
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo "  ⚠  update-kubeconfig failed (credentials issue?). Skipping Flux drain."
      set -e; return 0
    fi

  else
    GCP_REGION=$(grep 'region'      "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
    GCP_PROJECT=$(grep 'project_id' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)

    local CLUSTER_EXISTS
    CLUSTER_EXISTS=$(gcloud container clusters list \
      --project "$GCP_PROJECT" \
      --filter "name=$CLUSTER_NAME" \
      --format "value(name)" 2>/dev/null)

    if [[ -z "$CLUSTER_EXISTS" ]]; then
      echo "  ⚠  GKE cluster '$CLUSTER_NAME' not found — already destroyed or never created."
      echo "     Skipping Flux drain."
      set -e; return 0
    fi

    echo "  GKE cluster '$CLUSTER_NAME' found. Fetching kubeconfig..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo "  ⚠  get-credentials failed. Skipping Flux drain."
      set -e; return 0
    fi
  fi

  # ── 2. Verify the API server is actually responding ─────────────────────────
  echo "  Verifying Kubernetes API server is reachable..."
  local API_CHECK
  kubectl cluster-info 2>/dev/null | grep -q "Kubernetes control plane"
  if [[ $? -ne 0 ]]; then
    echo "  ⚠  Kubernetes API server is not responding (cluster may be degraded)."
    echo "     Skipping Flux drain and proceeding to terraform destroy."
    set -e; return 0
  fi

  # ── 3. Verify Flux is installed ──────────────────────────────────────────────
  kubectl get namespace flux-system &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "  ⚠  flux-system namespace not found — Flux is not installed or was already removed."
    echo "     Skipping Flux drain and proceeding to terraform destroy."
    set -e; return 0
  fi

  # Confirm the Flux CRDs are present (partial install guard)
  kubectl get crd helmreleases.helm.toolkit.fluxcd.io &>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "  ⚠  Flux CRDs not found — Flux may be only partially installed."
    echo "     Skipping HelmRelease deletion and jumping straight to flux uninstall."
    flux uninstall --namespace=flux-system --keep-namespace=false --silent 2>/dev/null || true
    set -e; return 0
  fi

  # ── 4. Suspend all Kustomizations ───────────────────────────────────────────
  # Stops Flux from reconciling (re-creating resources) while we delete them.
  echo "  Suspending all Kustomizations..."
  flux suspend kustomization --all --namespace flux-system 2>/dev/null
  [[ $? -ne 0 ]] && echo "  ⚠  Could not suspend Kustomizations (may already be suspended or missing)."

  # ── 5. Delete infrastructure HelmReleases first ─────────────────────────────
  # ALB controller, ingress-nginx, external-dns, and cert-manager all own cloud
  # resources via finalizers. Deleting their HelmReleases triggers `helm uninstall`
  # which fires those finalizers and removes the cloud resources cleanly.
  local INFRA_PATTERNS="aws-load-balancer|ingress|external-dns|cert-manager"
  local HR_LIST

  echo "  Deleting infrastructure HelmReleases (ALB controller, ingress, external-dns)..."
  HR_LIST=$(flux get helmreleases --all-namespaces --no-header 2>/dev/null | awk '{print $1, $2}')
  if [[ $? -ne 0 || -z "$HR_LIST" ]]; then
    echo "  No HelmReleases found (or flux get failed) — skipping HelmRelease deletion."
  else
    while read -r NS NAME; do
      if echo "$NAME" | grep -qE "$INFRA_PATTERNS"; then
        echo "    flux delete helmrelease -n $NS $NAME --silent"
        flux delete helmrelease -n "$NS" "$NAME" --silent 2>/dev/null
        [[ $? -ne 0 ]] && echo "    ⚠  Failed to delete $NAME in $NS — continuing."
      fi
    done <<< "$HR_LIST"

    # ── 6. Delete remaining HelmReleases ──────────────────────────────────────
    echo "  Deleting remaining HelmReleases..."
    while read -r NS NAME; do
      if ! echo "$NAME" | grep -qE "$INFRA_PATTERNS"; then
        echo "    flux delete helmrelease -n $NS $NAME --silent"
        flux delete helmrelease -n "$NS" "$NAME" --silent 2>/dev/null
        [[ $? -ne 0 ]] && echo "    ⚠  Failed to delete $NAME in $NS — continuing."
      fi
    done <<< "$HR_LIST"
  fi

  # ── 7. Wait for cloud load balancers to disappear ───────────────────────────
  # The ALB controller deprovisions asynchronously after its pod receives the
  # helm uninstall signal. We must wait before destroying the VPC or the ENIs
  # the LBs hold will prevent subnet deletion.
  echo ""
  echo "  Waiting for cloud load balancers to be fully deprovisioned..."
  local MAX_WAIT=180 INTERVAL=10 ELAPSED=0 TOTAL

  while true; do
    if [[ "$CLUSTER" == "eks" ]]; then
      local LB_COUNT CLB_COUNT
      LB_COUNT=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "length(LoadBalancers[?contains(LoadBalancerName, 'k8s-')])" \
        --output text 2>/dev/null)
      # aws CLI returns "None" if the list is empty rather than 0
      [[ -z "$LB_COUNT"  || "$LB_COUNT"  == "None" ]] && LB_COUNT=0
      CLB_COUNT=$(aws elb describe-load-balancers \
        --region "$AWS_REGION" \
        --query "length(LoadBalancerDescriptions[?contains(LoadBalancerName, '${CLUSTER_NAME}')])" \
        --output text 2>/dev/null)
      [[ -z "$CLB_COUNT" || "$CLB_COUNT" == "None" ]] && CLB_COUNT=0
      TOTAL=$(( LB_COUNT + CLB_COUNT ))
    else
      TOTAL=$(gcloud compute forwarding-rules list \
        --project "$GCP_PROJECT" \
        --filter "description~$CLUSTER_NAME" \
        --format "value(name)" 2>/dev/null | wc -l | tr -d ' ')
      [[ -z "$TOTAL" ]] && TOTAL=0
    fi

    if [[ "$TOTAL" -eq 0 ]]; then
      echo "  ✓ All load balancers removed."
      break
    fi

    if [[ "$ELAPSED" -ge "$MAX_WAIT" ]]; then
      echo ""
      echo "  ⚠  Timed out after ${MAX_WAIT}s — ${TOTAL} load balancer(s) still present."
      echo "     Remove them manually from the cloud console before retrying,"
      echo "     otherwise terraform destroy will fail on VPC/subnet deletion."
      echo ""
      # Re-enable errexit temporarily so the read + exit path works cleanly
      set -e
      read -rp "  Continue with terraform destroy anyway? [y/N] " CONFIRM
      [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
      set +e
      break
    fi

    echo "  ${TOTAL} load balancer(s) still present — retrying in ${INTERVAL}s (${ELAPSED}/${MAX_WAIT}s elapsed)..."
    sleep "$INTERVAL"
    ELAPSED=$(( ELAPSED + INTERVAL ))
  done

  # ── 8. Uninstall Flux itself ─────────────────────────────────────────────────
  # Removes all Flux CRDs, RBAC, controllers, and the flux-system namespace.
  # After this the cluster is a plain EKS/GKE cluster with no Flux footprint.
  echo ""
  echo "  Uninstalling Flux (controllers, CRDs, flux-system namespace)..."
  flux uninstall --namespace=flux-system --keep-namespace=false --silent 2>/dev/null
  [[ $? -ne 0 ]] && echo "  ⚠  flux uninstall reported an error — continuing anyway."

  echo "  ✓ Flux workloads fully drained. Proceeding to terraform destroy."
  echo ""

  # Restore strict error handling for the rest of the script
  set -e
}

if [[ "$ACTION" == "apply" ]]; then
  ensure_secrets
fi

if [[ "$CLUSTER" == "eks" && ! -f "$WORKDIR/alb-controller-iam-policy.json" ]]; then
  echo "Downloading ALB controller IAM policy..."
  curl -fsSL -o "$WORKDIR/alb-controller-iam-policy.json" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

echo "════════ Cluster: $CLUSTER | Action: $ACTION ════════"
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

    if [[ "$CLUSTER" == "eks" ]]; then
      DOMAIN=$(grep 'domain' "$WORKDIR/terraform.tfvars" | cut -d'"' -f2)
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║  DNS & ACM Setup Complete                                    ║"
      echo "╠══════════════════════════════════════════════════════════════╣"
      echo "║  ExternalDNS will now map ALB to: https://$DOMAIN"
      echo "╚══════════════════════════════════════════════════════════════╝"
    fi
    ;;
  destroy)
    drain_flux_workloads

    [[ -f "sops.tf" ]] && sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/' sops.tf || true
    terraform destroy -auto-approve
    [[ -f "sops.tf.bak" ]] && mv sops.tf.bak sops.tf || true
    ;;
  *) usage ;;
esac