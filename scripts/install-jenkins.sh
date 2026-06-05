#!/bin/bash
# install-jenkins.sh - Install Jenkins on EKS with IRSA + JCasC
#
# Design principles (lessons from real-world setup):
#   - ServiceAccounts (jenkins, jenkins-agent) are owned by eksctl, NOT Helm.
#     This avoids Server-Side Apply field-ownership conflicts on subsequent
#     helm upgrades (eksctl writes IRSA annotations, Helm wants to manage SA labels).
#   - Both SAs are created BEFORE helm install. values.yaml sets:
#       serviceAccount.create: false
#       serviceAccountAgent.create: false
#   - JCasC credentials secret (GitHub PAT) is created BEFORE helm install so
#     JCasC can resolve ${jenkins-credentials-XXX} references at startup.
#   - WebSocket protocol enabled for agent <-> controller (no TCP 50000 needed).
#   - CFN stack drift recovery: if eksctl reports SA exists but K8s shows it
#     missing, fall back to manual SA creation reusing the existing IAM Role.
#
# Usage:
#   export GITHUB_PAT='ghp_xxx'         # required
#   export GITHUB_USERNAME='jif718'     # optional, defaults to jif718
#   ./scripts/install-jenkins.sh

set -euo pipefail

# ------------------------- Configuration --------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, JENKINS_*, CLUSTER_NAME, REGION, GITHUB_USERNAME

NAMESPACE="$JENKINS_NAMESPACE"
RELEASE="$JENKINS_RELEASE"
CLUSTER="$CLUSTER_NAME"
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

# values.yaml sanity: webSocket must be enabled (we disabled agentListener)
if ! grep -q "webSocket: true" "$ROOT/apps/jenkins/values.yaml"; then
  echo "ERROR: values.yaml missing 'webSocket: true' in kubernetes cloud config"
  echo "  Without it agents cannot connect (no TCP 50000 listener either)"
  exit 1
fi
echo "  values.yaml: webSocket protocol confirmed"

# In install-jenkins.sh pre-flight section
# Sanity check #3: containerSecurityContext override
# Chart 5.9.22 has no separate initContainerSecurityContext, so the default
# readOnlyRootFilesystem: true is inherited by init container and breaks
# apply_config.sh (which writes to /usr/share/jenkins/ref/plugins during
# plugin install). values.yaml must override to false.
if ! grep -q "readOnlyRootFilesystem: *false" "$ROOT/apps/jenkins/values.yaml"; then
    echo "ERROR: $JENKINS_VALUES missing readOnlyRootFilesystem: false"
    echo "       Without this, init container fails on plugin install (read-only rootfs)."
    exit 1
fi

# ------------------------- Step 1: Namespace ----------------------------------
echo ""
echo "===> [1/6] Creating namespace $NAMESPACE"
kubectl apply -f "$ROOT/apps/jenkins/00-namespace.yaml"

# ------------------------- Step 2: JCasC credentials secret -------------------
echo ""
echo "===> [2/6] Creating jenkins-credentials secret (read by JCasC at startup)"
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
# Helper: create IRSA, then ensure the K8s SA actually exists.
# If CFN stack exists but SA was deleted from K8s (drift), recreate SA manually
# reusing the existing IAM Role ARN.

ensure_irsa_sa() {
  local sa_name=$1

  echo ""
  echo "  --> ensure IRSA for SA: $sa_name"

  # First try the normal eksctl flow
  eksctl create iamserviceaccount \
    --cluster="$CLUSTER" \
    --region="$REGION" \
    --namespace="$NAMESPACE" \
    --name="$sa_name" \
    --attach-policy-arn="$POLICY_ARN" \
    --override-existing-serviceaccounts \
    --approve

  # Verify SA actually exists in K8s now
  if kubectl -n "$NAMESPACE" get sa "$sa_name" >/dev/null 2>&1; then
    return 0
  fi

  # CFN stack drift: stack exists but K8s SA was deleted
  echo "  WARN: SA $sa_name not in K8s after eksctl (CFN stack drift detected)"
  echo "  Recovering: manually recreating SA with existing IAM Role"

  local role_arn
  role_arn=$(eksctl get iamserviceaccount \
    --cluster "$CLUSTER" --region "$REGION" -o json | \
    jq -r ".[] | select(.metadata.name==\"$sa_name\") | .status.roleARN")

  if [ -z "$role_arn" ] || [ "$role_arn" = "null" ]; then
    echo "  ERROR: cannot find IAM Role ARN for $sa_name"
    exit 1
  fi

  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $sa_name
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: $role_arn
  labels:
    app.kubernetes.io/managed-by: eksctl
YAML
}

echo ""
echo "===> [4/6] Creating IRSA for jenkins SA (controller)"
ensure_irsa_sa jenkins

echo ""
echo "===> [5/6] Creating IRSA for jenkins-agent SA (build pods)"
ensure_irsa_sa jenkins-agent

# Final verification: both SAs must have IRSA annotation
echo ""
echo "  Verifying IRSA annotations:"
for sa in jenkins jenkins-agent; do
  role_arn=$(kubectl -n "$NAMESPACE" get sa "$sa" \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
  if [ -z "$role_arn" ]; then
    echo "ERROR: SA $sa missing eks.amazonaws.com/role-arn annotation"
    exit 1
  fi
  echo "    $sa -> $role_arn"
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
echo "################################################"
echo "#                                              #"
echo "#          Install Jenkins Complete            #"
echo "#                                              #"
echo "################################################"
echo ""