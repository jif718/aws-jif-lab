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

# Point kubectl at THIS cluster before touching PVCs, so step [1/3] can never
# delete PVCs in whatever cluster the current kubeconfig context happens to be.
echo "[0/3] Targeting kubeconfig at cluster $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[1/3] Deleting all PVCs to avoid orphan EBS volumes..."
kubectl delete pvc --all --all-namespaces --wait=false || true
# NOTE: --wait=false does not block for the EBS CSI driver to release the
# underlying volumes before the cluster (and the driver) is torn down in [2/3].
# The orphan-volume sweep in [3/3] is the safety net that catches any volumes
# the driver did not get to release in time.

echo "[2/3] Deleting EKS cluster..."
eksctl delete cluster -f "$ROOT/infra/cluster.yaml" --wait

echo "[3/3] Checking for orphan EBS volumes..."
ORPHAN_VOLUMES=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text)
if [ -n "$ORPHAN_VOLUMES" ]; then
    echo "Found orphan volumes: $ORPHAN_VOLUMES"
    for vol in $ORPHAN_VOLUMES; do
        aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
        echo "  Deleted: $vol"
    done
else
    echo "No orphan volumes found."
fi

echo "Cleanup complete."
