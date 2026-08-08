#!/usr/bin/env bash
# =============================================================================
# conductor / bootstrap / install.sh — the one imperative step in the platform
# =============================================================================
#
# THE CHICKEN-AND-EGG PROBLEM, STATED HONESTLY
#
# Every layer of this platform after this point deploys by merging to Git. But
# something has to install the thing that watches Git, and that something
# cannot itself be GitOps. There is no way around it — every GitOps setup in
# existence has exactly this seam, and most hide it inside a README step that
# nobody writes down properly.
#
# So it lives here, in one script, run once, from a laptop, using the kubeconfig
# that layer 2 fetched. After it completes:
#
#   - ArgoCD is running on the cluster
#   - The `downbeat` root Application is watching conductor/manifests/
#   - Nothing outside the cluster needs a credential that can change it again
#
# The kubeconfig on your laptop stops being load-bearing at that moment. It's
# still useful for looking at things; it is no longer how anything gets
# deployed.
#
# IDEMPOTENT. `helm upgrade --install` and `kubectl apply` both converge rather
# than fail on re-run, so running this twice is safe and is also how you'd apply
# a change to bootstrap/values.yaml.
# =============================================================================

set -euo pipefail

CHART_VERSION="10.3.0"   # appVersion v3.5.0 — see values.yaml for the pin rationale
NAMESPACE="argocd"
RELEASE="argocd"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="${SCRIPT_DIR}/values.yaml"
ROOT_APP="${SCRIPT_DIR}/../application.yaml"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
# Failing here with a sentence is worth more than failing halfway through a
# Helm install with a Go stack trace.

info "Checking prerequisites"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Install it: sudo snap install kubectl --classic"
command -v helm    >/dev/null 2>&1 || die "helm not found. Install it: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

[ -f "${VALUES}" ]   || die "values.yaml not found next to this script (looked at ${VALUES})"
[ -f "${ROOT_APP}" ] || die "application.yaml not found (looked at ${ROOT_APP})"

if [ -z "${KUBECONFIG:-}" ] && [ ! -f "${HOME}/.kube/config" ]; then
  die "No kubeconfig. Layer 2 wrote one to rehearsal/kubeconfig.podium — use it:
       export KUBECONFIG=\$PWD/../../rehearsal/kubeconfig.podium"
fi

kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach the cluster. Check KUBECONFIG, and that the
       node is up and 6443 is open in both the OCI security list and ufw."

NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
info "Cluster reachable — node architecture: ${NODE_ARCH}"

# The constraint layer 1 propagated. Everything deployed here has to have an
# arm64 image, and finding that out now beats finding out from a CrashLoopBackOff.
if [ "${NODE_ARCH}" != "arm64" ]; then
  warn "Node is ${NODE_ARCH}, not arm64. That's fine, but the manifests in this repo"
  warn "are chosen for arm64 because layer 1 provisions an Ampere A1 instance."
fi

# -----------------------------------------------------------------------------
# Install ArgoCD
# -----------------------------------------------------------------------------

info "Adding the argo Helm repository"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null

info "Installing ArgoCD ${CHART_VERSION} into namespace ${NAMESPACE}"
# --wait blocks until the deployments report ready, so a failure here is a real
# failure rather than a success followed by a silently broken cluster.
helm upgrade --install "${RELEASE}" argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  --values "${VALUES}" \
  --wait \
  --timeout 10m

# -----------------------------------------------------------------------------
# Hand over to Git
# -----------------------------------------------------------------------------

info "Applying the downbeat root Application"
# The last kubectl command that will ever be needed to deploy something here.
kubectl apply -n "${NAMESPACE}" -f "${ROOT_APP}"

info "Waiting for the root Application to reach a healthy sync"
# Not fatal if it times out — a first sync can take a few minutes while images
# pull, and the useful next step is to go and look at why rather than to have
# the script exit non-zero.
if ! kubectl wait --namespace "${NAMESPACE}" \
      --for=jsonpath='{.status.health.status}'=Healthy \
      application/downbeat --timeout=300s 2>/dev/null; then
  warn "downbeat is not Healthy yet. Check with:"
  warn "  kubectl -n argocd get application downbeat -o wide"
  warn "  kubectl -n argocd describe application downbeat"
fi

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------

echo
info "ArgoCD is installed and watching Git."
echo
echo "  Reach the UI through a port-forward — there is deliberately no public"
echo "  ingress, because the ArgoCD API can change anything in the cluster:"
echo
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "    open http://localhost:8080"
echo

# The chart writes a generated password into a Secret and expects you to change
# it and delete the Secret. If it's already gone, that's the good outcome.
if kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  ADMIN_PW="$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
              -o jsonpath='{.data.password}' | base64 -d)"
  echo "    username: admin"
  echo "    password: ${ADMIN_PW}"
  echo
  echo "  Change it and delete the bootstrap secret once you're in:"
  echo "    argocd account update-password"
  echo "    kubectl -n argocd delete secret argocd-initial-admin-secret"
else
  echo "    username: admin"
  echo "    password: (initial secret already removed — using the password you set)"
fi

echo
echo "  From here, deploying means committing to conductor/manifests/ and pushing."
echo "  Prove it reconciles:"
echo
echo "    kubectl scale deploy/overture -n overture --replicas=5"
echo "    kubectl get deploy/overture -n overture -w    # watch it revert"
echo
