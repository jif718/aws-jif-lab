#!/bin/bash
# install-jenkins.sh - Install Jenkins on EKS with JCasC
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
NAMESPACE=jenkins
RELEASE=jenkins
CLUSTER=jif-lab
REGION=ap-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ---- Pre-flight check: GitHub PAT must be set ----
if [ -z "$GITHUB_PAT" ]; then
  echo "ERROR: Please export GITHUB_PAT before running this script:"
  echo "  export GITHUB_PAT=ghp_xxxxxxxxxxxx"
  echo "  export GITHUB_USERNAME=jif718"
  exit 1
fi
GITHUB_USERNAME=${GITHUB_USERNAME:-jif718}

echo "[1/7] Creating namespace..."
kubectl apply -f $ROOT/apps/jenkins/00-namespace.yaml

echo "[2/7] Creating jenkins-credentials secret (for JCasC)..."
kubectl create secret generic jenkins-credentials \
  --namespace $NAMESPACE \
  --from-literal=GITHUB_USERNAME=$GITHUB_USERNAME \
  --from-literal=GITHUB_PAT=$GITHUB_PAT \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/7] Creating IAM policy for ECR access..."
aws iam create-policy \
  --policy-name JenkinsECRPushPolicy \
  --policy-document file://$ROOT/apps/jenkins/iam-ecr-policy.json \
  2>/dev/null || echo "  Policy already exists, skipping"

echo "[4/7] Creating IRSA for jenkins SA..."
eksctl create iamserviceaccount \
  --cluster=$CLUSTER \
  --region=$REGION \
  --namespace=$NAMESPACE \
  --name=jenkins \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/JenkinsECRPushPolicy \
  --override-existing-serviceaccounts \
  --approve

echo "[5/7] Adding Helm repo..."
helm repo add jenkinsci https://charts.jenkins.io
helm repo update

echo "[6/7] Installing Jenkins (this takes 3-5 minutes)..."
helm upgrade --install $RELEASE jenkinsci/jenkins \
  --namespace $NAMESPACE \
  --values $ROOT/apps/jenkins/values.yaml \
  --wait \
  --timeout 10m

echo "[7/7] Creating IRSA for jenkins-agent SA..."
eksctl create iamserviceaccount \
  --cluster=$CLUSTER \
  --region=$REGION \
  --namespace=$NAMESPACE \
  --name=jenkins-agent \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/JenkinsECRPushPolicy \
  --override-existing-serviceaccounts \
  --approve

# Restart jenkins controller pod so it picks up the new agent SA IRSA
# (not strictly necessary for controller, but helps if any cached SA tokens)
# kubectl -n $NAMESPACE rollout restart statefulset/jenkins

echo ""
echo "===== Jenkins ready ====="
echo "Admin password:"
kubectl exec --namespace $NAMESPACE -c jenkins -it \
  svc/jenkins -- /bin/cat /run/secrets/additional/chart-admin-password
echo ""
echo ""
echo "Access via port-forward:"
echo "  kubectl --namespace $NAMESPACE port-forward svc/jenkins 8080:8080"
echo "Then open http://localhost:8080  (user: admin)"
