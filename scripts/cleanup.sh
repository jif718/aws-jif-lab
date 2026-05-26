#!/bin/bash
# cleanup.sh - Tear down the entire EKS environment
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

echo "WARNING: About to delete EKS cluster jif-lab. All PVC data will be lost."
read -p "Confirm deletion? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo "[1/3] Deleting all PVCs to avoid orphan EBS volumes..."
kubectl get pvc -A --no-headers 2>/dev/null | awk '{print "kubectl delete pvc "$2" -n "$1" --wait=false"}' | sh || true

echo "[2/3] Deleting EKS cluster..."
eksctl delete cluster -f $ROOT/infra/cluster.yaml --wait

echo "[3/3] Checking for orphan EBS volumes..."
ORPHAN_VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/jif-lab,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text)
if [ -n "$ORPHAN_VOLUMES" ]; then
    echo "Found orphan volumes: $ORPHAN_VOLUMES"
    for vol in $ORPHAN_VOLUMES; do
        aws ec2 delete-volume --volume-id $vol
        echo "  Deleted: $vol"
    done
else
    echo "No orphan volumes found."
fi

echo "Cleanup complete."
