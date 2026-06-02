#!/bin/bash
# deploy-k8s-cluster.sh - Provision the EKS cluster and apply baseline config.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, CLUSTER_NAME, ... (standalone or via deploy-all)

echo "===> [cluster] EKS cluster"
# Skip creation if the cluster context is already reachable (idempotent rerun).
if kubectl config current-context 2>/dev/null | grep -q "$CLUSTER_NAME" \
   && kubectl get nodes >/dev/null 2>&1; then
  echo "  cluster '$CLUSTER_NAME' already reachable, skipping create"
else
  echo "  creating cluster (15-20 min)..."
  eksctl create cluster -f "$ROOT/infra/cluster.yaml"
fi

echo "===> [cluster] gp3 default StorageClass"
kubectl apply -f "$ROOT/infra/storage/gp3-storageclass.yaml"
# Demote gp2 so only gp3 is default.
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || true

echo "===> [cluster] verify"
kubectl get nodes -L role
kubectl get storageclass