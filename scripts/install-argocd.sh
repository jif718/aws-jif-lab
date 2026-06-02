#!/bin/bash
# Install/upgrade ArgoCD on EKS with a pinned chart version.
# Mirrors the hardening style of install-jenkins.sh.

set -euo pipefail

NAMESPACE="argocd"
RELEASE_NAME="argocd"
CHART_VERSION="9.5.15"   # -> app v3.4.2
REPO_NAME="argo"
REPO_URL="https://argoproj.github.io/argo-helm"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
VALUES_FILE="${ROOT}/apps/argocd/values.yaml"
APP_FILE="${ROOT}/apps/argocd/apps/flask-demo-1.yaml"

echo "===> Pre-flight checks"
# Sanity check: values.yaml must enable insecure mode for port-forward access.
if ! grep -q "server.insecure: true" "${VALUES_FILE}"; then
    echo "ERROR: ${VALUES_FILE} missing 'server.insecure: true'"
    echo "       Without it, port-forward to argocd-server hits TLS/gRPC-Web issues."
    exit 1
fi

# Cluster reachable?
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable"; exit 1; }
echo "  Cluster reachable"
echo "  values.yaml: server.insecure confirmed"

echo "===> Adding Helm repo"
helm repo add "${REPO_NAME}" "${REPO_URL}" 2>/dev/null || true
helm repo update "${REPO_NAME}"

echo "===> Resolving app version for chart ${CHART_VERSION}"
APP_VERSION=$(helm search repo "${REPO_NAME}/argo-cd" --version "${CHART_VERSION}" \
  --output json 2>/dev/null | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4)
APP_VERSION="${APP_VERSION:-unknown}"

echo "===> Installing/upgrading ArgoCD (chart ${CHART_VERSION} -> app ${APP_VERSION})"
helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/argo-cd" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 10m

echo "===> Waiting for argocd-server rollout"
kubectl -n "${NAMESPACE}" rollout status deployment/argocd-server --timeout=5m

echo ""
echo "===> ArgoCD ready"
echo "  Initial admin password:"
kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
echo ""
echo "  Access:"
echo "    kubectl -n argocd port-forward svc/argocd-server 8081:80"
echo "    open http://localhost:8081  (user: admin)"
