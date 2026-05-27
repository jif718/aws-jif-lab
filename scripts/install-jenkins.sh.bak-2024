#!/bin/bash
# install-jenkins.sh - Install Jenkins on EKS with IRSA + JCasC
#
# Design principles:
#   - ServiceAccounts (jenkins, jenkins-agent) are owned by eksctl, NOT Helm.
#     This avoids Server-Side Apply field-ownership conflicts on subsequent
#     helm upgrades (eksctl writes IRSA annotations, Helm wants to manage SA labels).
#   - Both SAs are created BEFORE helm install. values.yaml sets:
#       serviceAccount.create: false
#       serviceAccountAgent.create: false
#   - JCasC credentials secret (GitHub PAT) is created BEFORE helm install so
#     JCasC can resolve ${jenkins-credentials-XXX} references at startup.
#
# Usage:
#   export GITHUB_PAT='ghp_xxx'         # required
#   export GITHUB_USERNAME='jif718'     # optional, defaults to jif718
#   ./scripts/install-jenkins.sh

set -euo pipefail

# ------------------------- Configuration --------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

NAMESPACE=jenkins
RELEASE=jenkins
CLUSTER=jif-lab
REGION=ap-east-1
POLICY_NAME=JenkinsECRPushPolicy

# ------------------------- Pre-flight checks ----------------------------------
echo "===> Pre-flight checks"

# Required tools
for cmd in kubectl helm eksctl aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found in PATH"
    exit 1
  fi
done

# Required env vars
if [ -z "${GITHUB_PAT:-}" ]; then
  echo "ERROR: GITHUB_PAT not set. Run:"
  echo "  export GITHUB_PAT='ghp_xxxxxxxxxxxx'"
  echo "  export GITHUB_USERNAME='jif718'   # optional"
  exit 1
fi
GITHUB_USERNAME=${GITHUB_USERNAME:-jif718}

# AWS connectivity
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  AWS account: $ACCOUNT_ID, region: $REGION"

# Cluster connectivity
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach cluster. Check ~/.kube/config"
  exit 1
fi
echo "  Cluster reachable: $(kubectl config current-context)"

# Required files
for f in \
  "$ROOT/apps/jenkins/00-namespace.yaml" \
  "$ROOT/apps/jenkins/iam-ecr-policy.json" \
  "$ROOT/apps/jenkins/values.yaml"
do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file missing: $f"
    exit 1
  fi
done
echo "  All required files present"

# ------------------------- Step 1: Namespace ----------------------------------
echo ""
echo "===> [1/6] Creating namespace $NAMESPACE"
kubectl apply -f "$ROOT/apps/jenkins/00-namespace.yaml"

# ------------------------- Step 2: JCasC credentials secret -------------------
echo ""
echo "===> [2/6] Creating jenkins-credentials secret (read by JCasC at startup)"
# Idempotent: use server-side apply via kubectl create --dry-run | kubectl apply
kubectl create secret generic jenkins-credentials \
  --namespace "$NAMESPACE" \
  --from-literal=GITHUB_USERNAME="$GITHUB_USERNAME" \
  --from-literal=GITHUB_PAT="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

# ------------------------- Step 3: ECR push IAM policy ------------------------
echo ""
echo "===> [3/6] Ensuring IAM policy $POLICY_NAME exists"
if aws iam get-policy \
     --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" \
     >/dev/null 2>&1; then
  echo "  Policy already exists, skipping creation"
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://"$ROOT/apps/jenkins/iam-ecr-policy.json" \
    --query 'Policy.Arn' --output text
  echo "  Policy created"
fi
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# ------------------------- Step 4: IRSA for SAs (BEFORE helm install) ---------
# Critical: SAs must exist before helm install, because values.yaml has
#   serviceAccount.create: false
#   serviceAccountAgent.create: false
# This way Helm never tries to own these SA objects, avoiding SSA field conflicts.

echo ""
echo "===> [4/6] Creating IRSA for jenkins SA (controller)"
eksctl create iamserviceaccount \
  --cluster="$CLUSTER" \
  --region="$REGION" \
  --namespace="$NAMESPACE" \
  --name=jenkins \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

echo ""
echo "===> [5/6] Creating IRSA for jenkins-agent SA (build pods)"
eksctl create iamserviceaccount \
  --cluster="$CLUSTER" \
  --region="$REGION" \
  --namespace="$NAMESPACE" \
  --name=jenkins-agent \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

# Verify both SAs got their IRSA annotation
for sa in jenkins jenkins-agent; do
  role_arn=$(kubectl -n "$NAMESPACE" get sa "$sa" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
  if [ -z "$role_arn" ]; then
    echo "ERROR: SA $sa missing eks.amazonaws.com/role-arn annotation"
    exit 1
  fi
  echo "  $sa -> $role_arn"
done

# ------------------------- Step 6: Helm install -------------------------------
echo ""
echo "===> [6/6] Installing/upgrading Jenkins via Helm"
helm repo add jenkinsci https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install "$RELEASE" jenkinsci/jenkins \
  --namespace "$NAMESPACE" \
  --values "$ROOT/apps/jenkins/values.yaml" \
  --wait \
  --timeout 10m

# ------------------------- Post-install info ----------------------------------
echo ""
echo "============================================================"
echo "  Jenkins installed successfully"
echo "============================================================"
echo ""
echo "Admin password (initial, change via UI then sync back to K8s secret):"
kubectl -n "$NAMESPACE" get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
echo ""
echo ""
echo "Access:"
echo "  kubectl -n $NAMESPACE port-forward svc/jenkins 8080:8080"
echo "  open http://localhost:8080  (user: admin)"
echo ""
echo "After changing the password in UI, sync to K8s secret:"
echo "  NEW_PWD='your-new-password'"
echo "  kubectl -n $NAMESPACE patch secret jenkins \\"
echo "    -p \"{\\\"data\\\":{\\\"jenkins-admin-password\\\":\\\"\$(echo -n \$NEW_PWD | base64)\\\"}}\""
