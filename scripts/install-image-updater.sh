#!/bin/bash
# install-image-updater.sh - Install ArgoCD Image Updater with IRSA for
# read-only ECR access (image tag discovery).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, ARGOCD_NAMESPACE, IMAGE_UPDATER_*, CLUSTER_NAME, REGION

NAMESPACE="$ARGOCD_NAMESPACE"
RELEASE="$IMAGE_UPDATER_RELEASE"
SA_NAME="$IMAGE_UPDATER_SA"
POLICY_NAME="$IMAGE_UPDATER_POLICY_NAME"
REPO_NAME="$ARGOCD_REPO_NAME"
VALUES="$ROOT/apps/argocd/image-updater-values.yaml"

echo "===> [image-updater] pre-flight"
[ -f "$VALUES" ] || { echo "ERROR: missing $VALUES"; exit 1; }
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "===> [image-updater] ECR read-only IAM policy"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  # Policy document is inlined (passed directly to --policy-document, no temp file).
  read -r -d '' POLICY_JSON <<'EOF' || true
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "*"
    }
  ]
}
EOF
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_JSON" \
    --region "$REGION" \
    --query 'Policy.Arn' --output text
fi

echo "===> [image-updater] IRSA for SA $SA_NAME"
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" --region "$REGION" \
  --namespace "$NAMESPACE" --name "$SA_NAME" \
  --attach-policy-arn "$POLICY_ARN" \
  --override-existing-serviceaccounts --approve
arn=$(kubectl -n "$NAMESPACE" get sa "$SA_NAME" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
[ -n "$arn" ] || { echo "ERROR: $SA_NAME missing role-arn annotation"; exit 1; }
echo "  $SA_NAME -> $arn"

echo "===> [image-updater] helm install"
helm repo add "$REPO_NAME" https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update "$REPO_NAME" >/dev/null
helm upgrade --install "$RELEASE" "$REPO_NAME/argocd-image-updater" \
  --namespace "$NAMESPACE" \
  --values "$VALUES" \
  --wait --timeout 10m

echo "===> [image-updater] ready"