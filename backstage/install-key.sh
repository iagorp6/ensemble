#!/usr/bin/env bash
# =============================================================================
# backstage / install-key.sh — put the decryption key where ArgoCD can reach it
# =============================================================================
#
# THE SEAM, ONE LEVEL DOWN FROM LAYER 4
#
# conductor/bootstrap/install.sh had to exist because something must install the
# thing that watches Git. This exists for the same reason, one turn deeper:
# something must deliver the key that decrypts Git, and that key obviously
# cannot come from Git.
#
# Every secrets-in-GitOps design has this bottom turtle. SOPS puts it here, as
# one age key you hand over once. Sealed Secrets puts it in a controller-
# generated keypair you have to back up. External Secrets pushes it out to a
# cloud KMS and replaces it with an IAM role — which is genuinely better, and
# is also just moving the trust root somewhere with its own bootstrap.
#
# What matters is that there is exactly ONE of them, it is named, and it is the
# only thing that ever needs to travel outside the repository.
#
# IDEMPOTENT: re-running replaces the Secret in place, which is also how you
# rotate the key.
# =============================================================================

set -euo pipefail

NAMESPACE="argocd"
SECRET_NAME="sops-age-key"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="${SOPS_AGE_KEY_FILE:-${SCRIPT_DIR}/age.key}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found."

[ -f "${KEY_FILE}" ] || die "No age key at ${KEY_FILE}.
       Generate one with:  age-keygen -o backstage/age.key
       Then add its public half to backstage/.sops.yaml and re-encrypt.
       Or point SOPS_AGE_KEY_FILE at an existing key."

# A public key in this file would mean the wrong half got copied — and the
# failure would surface much later as an opaque decryption error during a sync.
grep -q 'AGE-SECRET-KEY-' "${KEY_FILE}" \
  || die "${KEY_FILE} does not contain an AGE-SECRET-KEY- line.
       That looks like a public key. This script needs the PRIVATE half."

kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach the cluster. Check KUBECONFIG."

info "Installing the age private key as ${NAMESPACE}/${SECRET_NAME}"

# The key inside the Secret must be named keys.txt, because that is what
# SOPS_AGE_KEY_FILE points at in conductor/bootstrap/values.yaml.
#
# --dry-run=client | kubectl apply is the idiom for "create or replace":
# `kubectl create secret` alone fails if it already exists, and `apply` alone
# cannot build a Secret from a file. Piping one into the other gets both.
kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-file=keys.txt="${KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# The repo-server reads the key at startup, so an existing pod has to be
# recycled to pick up a new one. Skipped silently if ArgoCD isn't installed yet
# — running this before conductor is a valid order.
if kubectl -n "${NAMESPACE}" get deployment argocd-repo-server >/dev/null 2>&1; then
  info "Restarting the repo-server so it picks the key up"
  kubectl -n "${NAMESPACE}" rollout restart deployment argocd-repo-server
  kubectl -n "${NAMESPACE}" rollout status deployment argocd-repo-server --timeout=180s
fi

echo
info "Done. Verify a decrypt actually happens:"
echo
echo "    kubectl -n argocd logs deploy/argocd-repo-server -c install-ksops"
echo "    kubectl -n overture get secret overture-secrets"
echo
echo "  And that the value reached the app — without printing it:"
echo
echo "    kubectl -n overture exec deploy/overture -- wget -qO- localhost:9898/ | grep tokenConfigured"
echo
