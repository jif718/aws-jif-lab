#!/bin/bash
# deploy-all.sh - Orchestrate the full AWS EKS DevOps stack.
# Orchestration layer ONLY: defines shared config, sources pre-flight checks,
# and calls component sub-scripts in order.
#
# Usage:
#   export GITHUB_PAT='ghp_xxxxxxxxxxxx'   # required
#   ./scripts/deploy-all.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# Shared configuration - sourced (exported) so every sub-script inherits it.
# Override any value from the environment before running. Defaults live in
# config.sh, the single source of truth shared with cleanup.sh.
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/config.sh"

# ---------------------------------------------------------------------------
# Global pre-flight checks (sourced so a failed check exits this script
# directly and the checks can read the env vars defined above).
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/preflight-checks.sh"

# ---------------------------------------------------------------------------
# Run steps in order. Any failure aborts (set -e) and the ERR trap reports
# which step died so the user doesn't have to scroll back to find it.
# ---------------------------------------------------------------------------
STEPS=(
  deploy-k8s-cluster.sh
  create-ecr-repos.sh
  install-jenkins.sh
  install-argocd.sh
  install-image-updater.sh
  deploy-apps.sh
)

# Fail fast if any step is missing before we start mutating cloud state.
for step in "${STEPS[@]}"; do
  [ -f "$SCRIPT_DIR/$step" ] || { echo "ERROR: missing step script: $step"; exit 1; }
done

CURRENT_STEP="preflight"
trap 'echo "===> deploy-all: FAILED at step: $CURRENT_STEP" >&2' ERR

for step in "${STEPS[@]}"; do
  CURRENT_STEP=$step
  echo ""
  echo "===> deploy-all: running $step"
  # Invoke via `bash` so execution does not depend on the file's +x bit.
  bash "$SCRIPT_DIR/$step"
done

trap - ERR

echo ""
echo "===> deploy-all: complete"
echo "  Jenkins: kubectl -n $JENKINS_NAMESPACE port-forward svc/$JENKINS_RELEASE 8080:8080"
echo "  ArgoCD:  kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8081:80"