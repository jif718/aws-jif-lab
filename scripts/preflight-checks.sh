#!/bin/bash
# preflight-checks.sh - Global pre-flight checks shared by the whole deploy.
#
# Designed to be SOURCED by deploy-all.sh (not executed):
#   - a failed check runs `exit 1`, which aborts the parent script
#   - it reads env vars (GITHUB_PAT, AWS_ACCOUNT_ID, ...) already exported
#     by the parent, so nothing needs to be passed in
#
# Scope is GLOBAL prerequisites only. File/content sanity checks (values.yaml
# webSocket, server.insecure, etc.) stay in their own sub-scripts.

echo "===> preflight: global checks"

# Required tools on PATH.
for cmd in kubectl helm eksctl aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done
echo "  tools: kubectl helm eksctl aws jq present"

# GITHUB_PAT must be set: an empty PAT would silently create a broken
# credentials secret and only fail later when ArgoCD/Jenkins hit the repo.
[ -n "${GITHUB_PAT:-}" ] || { echo "ERROR: GITHUB_PAT not set"; exit 1; }
echo "  GITHUB_PAT present"

# Caller AWS identity must match the configured account (avoid wrong-profile deploys).
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER_ACCOUNT" = "${AWS_ACCOUNT_ID}" ] \
  || { echo "ERROR: AWS account $CALLER_ACCOUNT != expected ${AWS_ACCOUNT_ID}"; exit 1; }
echo "  AWS account: ${AWS_ACCOUNT_ID}, region: ${REGION}"