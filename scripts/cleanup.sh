#!/bin/bash
# cleanup.sh - Tear down the entire EKS environment
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Honor the same overridable config as deploy-all.sh (single source of truth)
# so a custom-named cluster or non-default region is torn down correctly.
source "$SCRIPT_DIR/config.sh"

echo "WARNING: About to delete EKS cluster $CLUSTER_NAME in $REGION. All PVC data will be lost."
read -p "Confirm deletion? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Pre-flight: this script is irreversible AND deletes EBS volumes, so refuse to
# run against the wrong AWS account (e.g. a mis-set profile).
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
    || { echo "ERROR: AWS account $CALLER_ACCOUNT != expected $AWS_ACCOUNT_ID"; exit 1; }

# Point kubectl at THIS cluster before touching PVCs/Ingresses, so the deletes
# below can never hit whatever cluster the current kubeconfig context happens to be.
echo "[0/4] Targeting kubeconfig at cluster $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Delete Ingresses FIRST, while the ALB controller is still alive, so it can
# release the ALB/TargetGroup/SG it created. eksctl delete cluster (step [2/4])
# kills the controller, after which those AWS resources would orphan and bill.
echo "[1/4] Deleting Ingresses so the ALB controller tears down ALBs/TGs/SGs..."
kubectl delete ingress --all --all-namespaces --wait=false 2>/dev/null || true
sleep 30   # give the controller time to call elbv2:DeleteLoadBalancer

echo "[2/4] Deleting all PVCs to avoid orphan EBS volumes..."
kubectl delete pvc --all --all-namespaces --wait=false || true
# NOTE: --wait=false does not block for the EBS CSI driver to release the
# underlying volumes before the cluster (and the driver) is torn down in [3/4].
# The orphan-volume sweep in [4/4] is the safety net that catches any volumes
# the driver did not get to release in time.

echo "[3/4] Deleting EKS cluster..."
eksctl delete cluster -f "$ROOT/infra/cluster.yaml" --wait

echo "[4/4] Sweeping orphan EBS volumes and ALBs tagged for this cluster..."
# --- orphan EBS volumes ---
ORPHAN_VOLUMES=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text)
if [ -n "$ORPHAN_VOLUMES" ]; then
    echo "Found orphan volumes: $ORPHAN_VOLUMES"
    for vol in $ORPHAN_VOLUMES; do
        aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
        echo "  Deleted volume: $vol"
    done
else
    echo "No orphan volumes found."
fi

# --- orphan ALBs (safety net mirroring the EBS sweep) ---
# The ALB controller tags every LB it creates with elbv2.k8s.aws/cluster=<name>.
# Catch any that survived step [1/4] (e.g. controller was mid-restart).
ORPHAN_ALBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
found_alb=false
for alb_arn in $ORPHAN_ALBS; do
    owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$alb_arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
        --output text 2>/dev/null || true)
    if [ "$owner" = "$CLUSTER_NAME" ]; then
        echo "  Deleting orphan ALB owned by $CLUSTER_NAME: $alb_arn"
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$alb_arn"
        found_alb=true
    fi
done
[ "$found_alb" = false ] && echo "No orphan ALBs found."

echo "Cleanup complete."