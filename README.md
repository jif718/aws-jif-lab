# AWS Migration Lab

Migrate a self-hosted K8s cluster (Jenkins + ArgoCD + Prometheus/Grafana + spring-petclinic) to AWS EKS.

## Architecture

- **EKS**: K8s v1.34, ap-east-1, 3x t4g.large Spot
- **ECR**: private container registry (replaces Harbor)
- **EBS gp3**: persistent storage (replaces hostPath local PV)
- **AWS LoadBalancer**: ingress (replaces MetalLB)
- **GitHub**: source repository

## Quick start

```bash
# Provision cluster
./scripts/bootstrap.sh

# Tear down
./scripts/cleanup.sh
```

## Layout

- `infra/`     - EKS cluster config (eksctl)
- `apps/`      - Application manifests
- `scripts/`   - Automation scripts
