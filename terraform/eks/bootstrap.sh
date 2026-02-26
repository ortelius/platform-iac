#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$REPO_ROOT"

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH_AMD="amd64" ;;
  arm64|aarch64) ARCH_AMD="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ── Banner ────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           pdvd-platform EKS Bootstrap                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Cluster : pdvd-eks                                      ║"
echo "║  Region  : us-east-1                                        ║"
echo "║  Repo    : ortelius/pdvd-platform                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Steps:                                                      ║"
echo "║   1. Validate secrets.enc.yaml                               ║"
echo "║   2. Create VPC + subnets (if not exists)                    ║"
echo "║   3. Create EKS cluster + node group (if not exists)         ║"
echo "║   4. Create ALB controller IAM role + policy                 ║"
echo "║   5. Request ACM certificate                                 ║"
echo "║   6. Git pull --rebase                                       ║"
echo "║   7. Write clusters/eks/pdvd/values.yaml                     ║"
echo "║   8. Install missing CLI tools (aws/kubectl/flux/helm/age)   ║"
echo "║   9. Commit + push values.yaml                               ║"
echo "║  10. Update kubeconfig                                       ║"
echo "║  11. Wait for nodes ready                                    ║"
echo "║  12. Flux bootstrap                                          ║"
echo "║  13. Generate age keypair + create sops-age k8s secret       ║"
echo "║  14. Write + commit .sops.yaml                               ║"
echo "║  15. Patch kustomize-controller for age decryption           ║"
echo "║  16. Flux reconciles pdvd + ALB                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Validate secrets.enc.yaml ─────────────────────────────────────────
SECRETS_FILE="$REPO_ROOT/clusters/eks/pdvd/secrets.enc.yaml"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "ERROR: $SECRETS_FILE not found."
  echo "       Create and encrypt it before deploying:"
  echo "       cp clusters/eks/pdvd/secrets.yaml clusters/eks/pdvd/secrets.enc.yaml"
  echo "       sops --encrypt --in-place clusters/eks/pdvd/secrets.enc.yaml"
  exit 1
fi

if ! grep -q "^sops:" "$SECRETS_FILE"; then
  echo "ERROR: $SECRETS_FILE exists but does not appear to be SOPS-encrypted."
  echo "       Encrypt it with: sops --encrypt --in-place $SECRETS_FILE"
  exit 1
fi

if sops --decrypt "$SECRETS_FILE" 2>/dev/null | grep -qE ':[ ]+""'; then
  echo "ERROR: $SECRETS_FILE contains empty values after decryption."
  echo "       Fill in all secret values before encrypting."
  exit 1
fi

echo "✓ secrets.enc.yaml validated"
echo ""

# ── Install missing CLI tools ─────────────────────────────────────────
echo "Platform: $OS/$ARCH_AMD"

if ! command -v aws &>/dev/null; then
  echo "Installing aws CLI..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-$OS-$ARCH_AMD.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
else
  echo "aws CLI already installed: $(aws --version)"
fi

if ! command -v kubectl &>/dev/null; then
  echo "Installing kubectl..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH_AMD/kubectl" -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
else
  echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null || true)"
fi

if ! command -v flux &>/dev/null; then
  echo "Installing flux CLI..."
  FLUX_VERSION=$(curl -fsSL https://api.github.com/repos/fluxcd/flux2/releases/latest | grep tag_name | cut -d '"' -f4 | tr -d v)
  curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v$FLUX_VERSION/flux_${FLUX_VERSION}_${OS}_${ARCH_AMD}.tar.gz" -o /tmp/flux.tar.gz
  tar -xzf /tmp/flux.tar.gz -C /tmp flux
  sudo mv /tmp/flux /usr/local/bin/flux
  rm /tmp/flux.tar.gz
  export PATH="$PATH:/usr/local/bin"
else
  echo "flux CLI already installed: $(flux version --client 2>/dev/null || true)"
fi

if ! command -v helm &>/dev/null; then
  echo "Installing helm..."
  HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | grep tag_name | cut -d '"' -f4)
  curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH_AMD.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  sudo mv /tmp/$OS-$ARCH_AMD/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/$OS-$ARCH_AMD
else
  echo "helm already installed: $(helm version --short 2>/dev/null || true)"
fi

# ── Commit and push values.yaml ───────────────────────────────────────
# Note: git pull --rebase already done before values.yaml was written
git add .

if git diff --cached --quiet; then
  echo "nothing to commit"
else
  git commit -m "chore(eks): update pdvd values with infrastructure outputs"
  git push origin main
  echo "Pushed"
fi

# ── Update kubeconfig ─────────────────────────────────────────────────
aws eks update-kubeconfig \
  --name pdvd-eks \
  --region us-east-1

# ── Wait for nodes ────────────────────────────────────────────────────
echo "Waiting for nodes to be ready..."
for i in $(seq 1 30); do
  if aws eks update-kubeconfig --name pdvd-eks --region us-east-1 &>/dev/null && \
     kubectl wait --for=condition=Ready nodes --all --timeout=30s 2>/dev/null; then
    echo "Nodes ready."
    break
  fi
  echo "Attempt $i/30 — nodes not ready yet, retrying in 10s..."
  sleep 10
done

# ── Bootstrap Flux ────────────────────────────────────────────────────
flux bootstrap github \
  --owner=ortelius \
  --repository=pdvd-platform \
  --branch=main \
  --path=clusters/eks \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
