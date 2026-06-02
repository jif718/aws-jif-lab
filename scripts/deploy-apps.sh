#!/bin/bash
# deploy-apps.sh - Deploy all ArgoCD Applications found under apps/argocd/apps/.
#
# Convention-based discovery (GitOps style): for every Application manifest
# <name>.yaml that has a matching <name>-imageupdater.yaml, the pair is applied
# together (ImageUpdater CR first since v1.x is CRD-driven), then the script
# waits for that Application to become Synced + Healthy before moving on.
#
# Add a new app (flask-demo-2, html5demo, ...) by dropping two files into the
# directory - no script change needed:
#   apps/argocd/apps/<name>.yaml                 # ArgoCD Application
#   apps/argocd/apps/<name>-imageupdater.yaml    # ImageUpdater CR
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, ARGOCD_NAMESPACE
NAMESPACE="$ARGOCD_NAMESPACE"
APPS_DIR="$ROOT/apps/argocd/apps"

echo "===> [apps] discovering applications in $APPS_DIR"
[ -d "$APPS_DIR" ] || { echo "ERROR: missing $APPS_DIR"; exit 1; }

deployed=0
# Iterate over Application manifests, skipping the *-imageupdater.yaml files.
for app_file in "$APPS_DIR"/*.yaml; do
  [ -e "$app_file" ] || { echo "  no .yaml manifests found"; break; }

  base=$(basename "$app_file" .yaml)
  case "$base" in
    *-imageupdater) continue ;;   # handled alongside its Application
  esac

  app_name="$base"
  iu_file="$APPS_DIR/${app_name}-imageupdater.yaml"
  if [ ! -f "$iu_file" ]; then
    echo "  [skip] $app_name: no matching ${app_name}-imageupdater.yaml"
    continue
  fi

  echo "===> [apps] deploying $app_name"
  # ImageUpdater CR first (v1.x is CRD-driven), then the Application.
  kubectl apply -f "$iu_file"
  kubectl apply -f "$app_file"

  echo "  waiting for $app_name to become Synced + Healthy"
  ready=false
  for i in $(seq 1 30); do
    sync=$(kubectl -n "$NAMESPACE" get application "$app_name" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl -n "$NAMESPACE" get application "$app_name" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    echo "    [$i/30] sync=$sync health=$health"
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      ready=true
      break
    fi
    sleep 10
  done

  if [ "$ready" != true ]; then
    echo "ERROR: $app_name did not reach Synced + Healthy within timeout"
    kubectl -n "$NAMESPACE" get application "$app_name"
    exit 1
  fi
  echo "  $app_name is Synced + Healthy"
  deployed=$((deployed + 1))
done

echo "===> [apps] done, $deployed application(s) deployed"