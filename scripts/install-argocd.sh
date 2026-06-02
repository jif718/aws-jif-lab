#!/bin/bash
# install-argocd.sh - Install ArgoCD on EKS with a pinned chart version,
# then create the git-creds secret used for GitOps write-back.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, ARGOCD_*, GITHUB_USERNAME

NAMESPACE="$ARGOCD_NAMESPACE"
RELEASE="$ARGOCD_RELEASE"
CHART_VERSION="$ARGOCD_CHART_VERSION"   # -> app v3.4.3
REPO_NAME="$ARGOCD_REPO_NAME"
VALUES="$ROOT/apps/argocd/values.yaml"

echo "===> [argocd] pre-flight"
[ -f "$VALUES" ] || { echo "ERROR: missing $VALUES"; exit 1; }
# server.insecure is required for port-forward (avoids TLS/gRPC-Web issues).
grep -q "server.insecure: true" "$VALUES" || { echo "ERROR: values.yaml missing server.insecure: true"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable"; exit 1; }

echo "===> [argocd] helm install (chart $CHART_VERSION)"
helm repo add "$REPO_NAME" https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update "$REPO_NAME" >/dev/null
helm upgrade --install "$RELEASE" "$REPO_NAME/argo-cd" \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$CHART_VERSION" \
  --values "$VALUES" \
  --wait --timeout 10m
kubectl -n "$NAMESPACE" rollout status deployment/argocd-server --timeout=5m

echo "===> [argocd] git-creds secret"
# Used by ArgoCD (repo access) and Image Updater (git write-back commits).
[ -n "${GITHUB_PAT:-}" ] || { echo "ERROR: GITHUB_PAT not set"; exit 1; }
kubectl -n "$NAMESPACE" create secret generic git-creds \
  --from-literal=username="$GITHUB_USERNAME" \
  --from-literal=password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "===> [argocd] ready"
echo "  password: kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  access:   kubectl -n $NAMESPACE port-forward svc/argocd-server 8081:80"
