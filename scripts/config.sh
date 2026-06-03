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

# ---- Step 8: Gateway (ALB Controller + external-dns + ACM Ingress) ----

# Gateway controllers live in kube-system (cluster infra layer, not GitOps)
export GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-kube-system}"

# AWS Load Balancer Controller
export ALB_CONTROLLER_SA="${ALB_CONTROLLER_SA:-aws-load-balancer-controller}"
export ALB_CONTROLLER_RELEASE="${ALB_CONTROLLER_RELEASE:-aws-load-balancer-controller}"
export ALB_CONTROLLER_POLICY_NAME="${ALB_CONTROLLER_POLICY_NAME:-AWSLoadBalancerControllerIAMPolicy}"
export ALB_CONTROLLER_ROLE_NAME="${ALB_CONTROLLER_ROLE_NAME:-AmazonEKSLoadBalancerControllerRole}"

# external-dns
export EXTERNAL_DNS_SA="${EXTERNAL_DNS_SA:-external-dns}"
export EXTERNAL_DNS_RELEASE="${EXTERNAL_DNS_RELEASE:-external-dns}"
export EXTERNAL_DNS_POLICY_NAME="${EXTERNAL_DNS_POLICY_NAME:-ExternalDNSPolicy}"

# DNS / TLS
# Base domain == the delegated Route53 sub-zone (matches external-dns domainFilters)
export BASE_DOMAIN="${BASE_DOMAIN:-aws.ololol.lol}"
# Wildcard cert covers jenkins./argocd./flask-demo-1. all at once
export ACM_DOMAIN="${ACM_DOMAIN:-*.aws.ololol.lol}"
# Hosted zone id for the sub-zone (used for ACM DNS-validation record upsert).
# Looked up dynamically if left empty; hard-set here only as an override.
export HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

# helm repo for eks-charts (ALB controller). external-dns uses the same 'argo'?
# No — external-dns has its own chart repo.
export EKS_CHARTS_REPO_NAME="${EKS_CHARTS_REPO_NAME:-eks}"
export EXTERNAL_DNS_REPO_NAME="${EXTERNAL_DNS_REPO_NAME:-external-dns}"
