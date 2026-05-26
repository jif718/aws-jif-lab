# AWS Load Balancer Controller Installation

Replaces MetalLB from the self-hosted cluster.
Creates AWS ALB/NLB automatically for K8s Service type=LoadBalancer.

## Install

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws eks describe-cluster --name jif-lab --region ap-east-1 \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# 1. Create IAM policy (only first time)
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://../iam/aws-lb-controller-policy.json

# 2. Create IRSA service account
eksctl create iamserviceaccount \
    --cluster=jif-lab \
    --region=ap-east-1 \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --role-name=AmazonEKSLoadBalancerControllerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --approve

# 3. Helm install
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=jif-lab \
    --set region=ap-east-1 \
    --set vpcId=${VPC_ID} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
```

## Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```
