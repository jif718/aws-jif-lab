#!/bin/bash
# config.sh - Shared, overridable configuration for the whole stack.
#
# SOURCE this (never execute it). It only assigns env vars — no side effects,
# no AWS/kubectl calls — so it is cheap and safe to source from any script,
# whether run standalone or via deploy-all.sh. Every value uses ${VAR:-default},
# so anything already set in the caller's environment wins, and sourcing more
# than once (e.g. deploy-all + a sub-script) is idempotent.

# Resolve repo root relative to THIS file, so sourcing works no matter the CWD.
_CONFIG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export ROOT="${ROOT:-$(cd "$_CONFIG_DIR/.." && pwd)}"

# AWS / cluster
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-445529239852}"
export REGION="${REGION:-ap-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-jif-lab}"

# GitHub credentials (shared by Jenkins JCasC, ArgoCD repo, Image Updater).
# GITHUB_PAT is intentionally NOT defaulted here — it must come from the caller.
export GITHUB_USERNAME="${GITHUB_USERNAME:-jif718}"

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
