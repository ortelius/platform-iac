/*
  sops.tf — GKE SOPS decryption infrastructure

  Provisions the Cloud KMS key and Workload Identity binding that allow
  kustomize-controller to decrypt SOPS secrets without static credentials.

  These resources back the live secrets already encrypted in this repo.
  If the KMS key and service account were created outside Terraform, import them:

    terraform import google_kms_key_ring.flux \
      projects/eighth-physics-169321/locations/global/keyRings/flux-sops

    terraform import google_kms_crypto_key.sops \
      projects/eighth-physics-169321/locations/global/keyRings/flux-sops/cryptoKeys/sops-key

    terraform import google_service_account.flux_sops \
      projects/eighth-physics-169321/serviceAccounts/flux-sops@eighth-physics-169321.iam.gserviceaccount.com

  After apply, copy the outputs into:
    clusters/gke/flux-system/kustomization.yaml
      → patches: kustomize-controller SA annotation
        iam.gke.io/gcp-service-account: <flux_sops_sa output>
*/

# ── Cloud KMS ─────────────────────────────────────────────────────────────────
resource "google_kms_key_ring" "flux" {
  name     = "flux-sops"
  location = "global"
}

resource "google_kms_crypto_key" "sops" {
  name     = "sops-key"
  key_ring = google_kms_key_ring.flux.id

  lifecycle {
    prevent_destroy = true
  }
}

# ── Service Account (Workload Identity) ───────────────────────────────────────
resource "google_service_account" "flux_sops" {
  account_id   = "flux-sops"
  display_name = "Flux SOPS decryption (kustomize-controller)"
}

resource "google_kms_crypto_key_iam_member" "flux_decrypt" {
  crypto_key_id = google_kms_crypto_key.sops.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.flux_sops.email}"
}

# Allows kustomize-controller's k8s SA to impersonate the GCP SA via Workload Identity
resource "google_service_account_iam_member" "flux_wi" {
  service_account_id = google_service_account.flux_sops.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[flux-system/kustomize-controller]"

  # kustomize-controller's SA is created during Flux bootstrap
  depends_on = [flux_bootstrap_git.gke]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "flux_sops_sa" {
  description = "Annotate kustomize-controller SA with: iam.gke.io/gcp-service-account"
  value       = google_service_account.flux_sops.email
}
output "kms_key_id" {
  description = "Use in .sops.yaml gcp_kms field"
  value       = google_kms_crypto_key.sops.id
}
