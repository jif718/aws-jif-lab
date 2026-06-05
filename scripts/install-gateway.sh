#!/bin/bash
# install-gateway.sh - Install the ingress data-plane: AWS Load Balancer
# Controller + external-dns, each with its own IRSA. Idempotent for daily rebuild.
#
# Design principles (consistent with install-jenkins.sh / install-image-updater.sh):
#   - SAs are owned by eksctl (for IRSA), so both Helm charts set
#     serviceAccount.create=false — avoids SSA field-ownership conflicts.
#   - VPC id is discovered LIVE from the cluster (it changes every rebuild);
#     never hard-coded.
#   - IAM policies (AWSLoadBalancerControllerIAMPolicy / ExternalDNSPolicy) are
#     created only if missing — they survive cluster teardown.
#   - Controller images are multi-arch; t4g (arm64) nodes pull arm64 automatically.
#
# Usage:
#   ./scripts/install-gateway.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"

NS="$GATEWAY_NAMESPACE"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

echo "===> [gateway] pre-flight"
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable"; exit 1; }

# Discover VPC id LIVE — it changes on every cluster rebuild.
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] \
  || { echo "ERROR: cannot resolve cluster VPC id"; exit 1; }
echo "  cluster VPC: $VPC_ID"

# Ensure IAM policies exist (created out-of-band / by repo JSON; verify only).
ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_CONTROLLER_POLICY_NAME}"
EXTDNS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${EXTERNAL_DNS_POLICY_NAME}"
for arn in "$ALB_POLICY_ARN" "$EXTDNS_POLICY_ARN"; do
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 \
    || { echo "ERROR: IAM policy missing: $arn (create from infra/iam/*.json)"; exit 1; }
done
echo "  IAM policies present"

# ---------------------------------------------------------------------------
# IRSA: aws-load-balancer-controller
# ---------------------------------------------------------------------------
echo "===> [gateway] IRSA for $ALB_CONTROLLER_SA"
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" --region "$REGION" \
  --namespace "$NS" --name "$ALB_CONTROLLER_SA" \
  --role-name "$ALB_CONTROLLER_ROLE_NAME" \
  --attach-policy-arn "$ALB_POLICY_ARN" \
  --override-existing-serviceaccounts --approve
arn=$(kubectl -n "$NS" get sa "$ALB_CONTROLLER_SA" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
[ -n "$arn" ] || { echo "ERROR: $ALB_CONTROLLER_SA missing role-arn"; exit 1; }
echo "  $ALB_CONTROLLER_SA -> $arn"

# ---------------------------------------------------------------------------
# IRSA: external-dns
# ---------------------------------------------------------------------------
echo "===> [gateway] IRSA for $EXTERNAL_DNS_SA"
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" --region "$REGION" \
  --namespace "$NS" --name "$EXTERNAL_DNS_SA" \
  --attach-policy-arn "$EXTDNS_POLICY_ARN" \
  --override-existing-serviceaccounts --approve
arn=$(kubectl -n "$NS" get sa "$EXTERNAL_DNS_SA" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
[ -n "$arn" ] || { echo "ERROR: $EXTERNAL_DNS_SA missing role-arn"; exit 1; }
echo "  $EXTERNAL_DNS_SA -> $arn"

# ---------------------------------------------------------------------------
# Helm: AWS Load Balancer Controller
# ---------------------------------------------------------------------------
echo "===> [gateway] helm install aws-load-balancer-controller"
helm repo add "$EKS_CHARTS_REPO_NAME" https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update "$EKS_CHARTS_REPO_NAME" >/dev/null
helm upgrade --install "$ALB_CONTROLLER_RELEASE" \
  "$EKS_CHARTS_REPO_NAME/aws-load-balancer-controller" \
  --namespace "$NS" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$ALB_CONTROLLER_SA" \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
# Helm: external-dns (values from repo; SA reused via IRSA)
# ---------------------------------------------------------------------------
echo "===> [gateway] helm install external-dns"
helm repo add "$EXTERNAL_DNS_REPO_NAME" https://kubernetes-sigs.github.io/external-dns >/dev/null 2>&1 || true
helm repo update "$EXTERNAL_DNS_REPO_NAME" >/dev/null
helm upgrade --install "$EXTERNAL_DNS_RELEASE" \
  "$EXTERNAL_DNS_REPO_NAME/external-dns" \
  --namespace "$NS" \
  --values "$ROOT/apps/external-dns/values.yaml" \
  --wait --timeout 5m

echo "===> [gateway] verify"
kubectl -n "$NS" get deploy "$ALB_CONTROLLER_RELEASE" "$EXTERNAL_DNS_RELEASE"
kubectl -n "$NS" rollout status deploy/"$ALB_CONTROLLER_RELEASE" --timeout=2m
echo ""
echo "################################################"
echo "#                                              #"
echo "#          Install Gateway Complete            #"
echo "#                                              #"
echo "################################################"
echo ""