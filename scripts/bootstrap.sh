#!/bin/bash
# bootstrap.sh - Provision EKS cluster and apply baseline configuration
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")

echo "[1/3] Creating EKS cluster (takes 15-20 minutes)..."
eksctl create cluster -f $ROOT/infra/cluster.yaml

echo "[2/3] Configuring gp3 as default StorageClass..."
kubectl apply -f $ROOT/apps/storage/gp3-storageclass.yaml
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true

echo "[3/3] Verifying cluster..."
kubectl get nodes -L role
kubectl get pods -A
kubectl get storageclass

echo "Cluster ready. Next: Step 3 - create ECR repositories"
