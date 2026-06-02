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
export ROOT
ROOT=$(dirname "$SCRIPT_DIR")

# ---------------------------------------------------------------------------
# Shared configuration - exported so every sub-script inherits it.
# Override any of these from the environment before running.
# ---------------------------------------------------------------------------
# AWS / cluster
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-445529239852}"
export REGION="${REGION:-ap-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-jif-lab}"

# GitHub credentials (shared by Jenkins JCasC, ArgoCD repo, Image Updater)
export GITHUB_USERNAME="${GITHUB_USERNAME:-jif718}"
# GITHUB_PAT must come from the caller's environment - never hard-coded.

# Jenkins
export JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-jenkins}"
export JENKINS_RELEASE="${JENKINS_RELEASE:-jenkins}"

# ArgoCD (versions per project spec)
export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
export ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"
export ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.5.16}"   # -> app v3.4.3
export ARGOCD_REPO_NAME="${ARGOCD_REPO_NAME:-argo}"

# ArgoCD Image Updater
export IMAGE_UPDATER_RELEASE="${IMAGE_UPDATER_RELEASE:-argocd-image-updater}"
export IMAGE_UPDATER_SA="${IMAGE_UPDATER_SA:-argocd-image-updater}"
export IMAGE_UPDATER_POLICY_NAME="${IMAGE_UPDATER_POLICY_NAME:-ArgoCDImageUpdaterECRRead}"

# ---------------------------------------------------------------------------
# Global pre-flight checks (sourced so a failed check exits this script
# directly and the checks can read the env vars defined above).
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/preflight-checks.sh"

# ---------------------------------------------------------------------------
# Run steps in order. Any failure aborts (set -e).
# ---------------------------------------------------------------------------
"$SCRIPT_DIR/deploy-k8s-cluster.sh"
"$SCRIPT_DIR/create-ecr-repos.sh"
"$SCRIPT_DIR/install-jenkins.sh"
"$SCRIPT_DIR/install-argocd.sh"
"$SCRIPT_DIR/install-image-updater.sh"
"$SCRIPT_DIR/deploy-apps.sh"

echo ""
echo "===> deploy-all: complete"
echo "  Jenkins: kubectl -n $JENKINS_NAMESPACE port-forward svc/$JENKINS_RELEASE 8080:8080"
echo "  ArgoCD:  kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8081:80"