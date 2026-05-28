# AWS EKS Cluster Rebuild Runbook

> Project: `jif718/aws-migration`  
> Region: `ap-east-1` (Hong Kong)  
> Account: `445529239852`  
> Estimated total time: **~50 minutes**

---

## Overview

```
Step 1  Bootstrap EKS cluster          (~20 min)
Step 2  Create ECR repos               (~2 min)
Step 3  Install StorageClass           (~1 min)
Step 4  Install Jenkins + IRSA         (~8 min)
Step 5  Jenkins post-install config    (~3 min)
Step 6  Install ArgoCD                 (~5 min)
Step 7  Install Image Updater + IRSA   (~5 min)
Step 8  Deploy apps via ArgoCD         (~5 min)
Step 9  End-to-end verify              (~3 min)
```

---

## Prerequisites (run on Mac before starting)

```bash
# Confirm tools are available
eksctl version
kubectl version --client
helm version
aws --version

# Confirm AWS identity is correct
aws sts get-caller-identity
# Expect: Account=445529239852

# Confirm Helm repos are added
helm repo list | grep -E 'jenkins|argo|eks'
# If missing, re-add:
helm repo add jenkins https://charts.jenkins.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

---

## Step 1: Bootstrap EKS Cluster (~20 min)

```bash
cd ~/code/aws-migration
./scripts/bootstrap.sh
# Creates: 2x t4g.large On-Demand, arm64, EKS 1.35, ap-east-1
# Configures: gp3 default StorageClass, kubeconfig

# Verify cluster is ready before continuing
kubectl get nodes
# Expect: 2 nodes, STATUS=Ready

kubectl get nodes -o wide | grep -E 'ARCH|arm64'
# Expect: arm64 architecture confirmed
```

---

## Step 2: Create ECR Repos (~2 min)

```bash
./scripts/create-ecr-repos.sh
# Idempotent: existing repos are skipped, not overwritten.
# Creates repos defined in infra/ecr/repos.txt:
#   myapp/flask-demo-1
#   myapp/flask-demo-1/cache
#   library/kaniko-executor
#   devops/python-agent
#   library/spring-petclinic (reserved)

# Verify
aws ecr describe-repositories --region ap-east-1 \
  --query 'repositories[].repositoryName' --output table
```

---

## Step 3: Install gp3 StorageClass (~1 min)

```bash
kubectl apply -f apps/storage/gp3-storageclass.yaml

# Verify
kubectl get storageclass
# Expect: gp3 with PROVISIONER=ebs.csi.aws.com, DEFAULT=true (or set it)
kubectl patch storageclass gp3 \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## Step 4: Install Jenkins + IRSA (~8 min)

> KNOWN ISSUE: chart 5.9.22 + image 2.555.2-lts defaults to
> `readOnlyRootFilesystem: true`, which breaks the init container that
> runs jenkins-plugin-cli (writes to /usr/share/jenkins/ref/plugins).
> The values.yaml already sets `readOnlyRootFilesystem: false` to fix this.

```bash
# Set your GitHub PAT before running (needs read access to flask-demo-1 repo)
export GITHUB_PAT='ghp_xxxxxxxxxxxxxxxxxxxx'

./scripts/install-jenkins.sh
# This script handles:
#   1. kubectl apply apps/jenkins/00-namespace.yaml
#   2. eksctl create iamserviceaccount (IRSA for ECR push + pull)
#   3. IAM policy from apps/jenkins/iam-ecr-policy.json
#   4. helm upgrade --install jenkins jenkins/jenkins -f apps/jenkins/values.yaml
#   5. Sanity checks: webSocket=true, readOnlyRootFilesystem=false
#   6. Waits for jenkins-0 pod to be Running

# Verify
kubectl get pods -n jenkins
# Expect: jenkins-0 Running 1/1

kubectl -n jenkins get svc jenkins
# Expect: ClusterIP (access via port-forward)
```

---

## Step 5: Jenkins Post-Install Config (~3 min)

> These steps cannot be scripted (UI interaction + secret sync required).

```bash
# 1. Get initial admin password
kubectl -n jenkins exec jenkins-0 -- \
  cat /var/jenkins_home/secrets/initialAdminPassword

# 2. Port-forward and open UI
kubectl -n jenkins port-forward svc/jenkins 8080:8080 &
open http://localhost:8080
# Login with: admin / <password from above>

# 3. Change password in UI: Admin → Configure → Password
#    Then sync the new password back to the K8s secret:
NEW_PASS='your-new-password'
kubectl -n jenkins patch secret jenkins \
  -p "{\"data\":{\"jenkins-admin-password\":\"$(echo -n $NEW_PASS | base64)\"}}"

# 4. Create Jenkins job in UI:
#    New Item → flask-demo-1 → Pipeline
#    Pipeline: SCM → Git
#    Repository URL: https://github.com/jif718/flask-demo-1.git  (business repo)
#    Credentials: github-token (PAT with read access)
#    Branch: */main
#    Script Path: Jenkinsfile

# 5. Kill port-forward when done
kill %1
```

---

## Step 6: Install ArgoCD (~5 min)

```bash
./scripts/install-argocd.sh
# This script handles:
#   1. helm upgrade --install argo-cd argo/argo-cd -f apps/argocd/values.yaml
#   2. Waits for argocd-server to be Running
#   3. Applies flask-demo-1 Application manifest

# Key values.yaml settings (already configured, do not change):
#   server.insecure: true        (port-forward over HTTP, no TLS termination needed)
#   dex.enabled: false
#   notifications.enabled: false
#   applicationSet.enabled: false

# Verify ArgoCD is up
kubectl get pods -n argocd
# Expect: all pods Running

# Verify flask-demo-1 Application exists
kubectl -n argocd get application flask-demo-1
# Initial state will be OutOfSync until Image Updater writes the first tag

# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## Step 7: Install Image Updater + IRSA (~5 min)

### 7a. Create IRSA for Image Updater (ECR read-only)

```bash
# Create the IAM policy for ECR read access
cat > /tmp/image-updater-ecr-policy.json <<'EOF'
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
  --policy-name ArgoCDImageUpdaterECRRead \
  --policy-document file:///tmp/image-updater-ecr-policy.json \
  --region ap-east-1 2>/dev/null || echo "Policy already exists, skipping."

# Get your cluster name from bootstrap output (or check it)
CLUSTER_NAME=$(eksctl get cluster --region ap-east-1 -o json | jq -r '.[0].Name')
echo "Cluster: $CLUSTER_NAME"

# Create IRSA-annotated ServiceAccount
# IMPORTANT: serviceAccount.create=false in values.yaml so Helm does NOT
# create its own SA — this SA (created by eksctl) is the one used.
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace argocd \
  --name argocd-image-updater \
  --attach-policy-arn arn:aws:iam::445529239852:policy/ArgoCDImageUpdaterECRRead \
  --approve \
  --region ap-east-1 2>/dev/null || echo "SA already exists, skipping."

# Verify IRSA annotation landed
kubectl -n argocd get sa argocd-image-updater \
  -o jsonpath='{.metadata.annotations}' && echo
# Expect: {"eks.amazonaws.com/role-arn":"arn:aws:iam::445529239852:role/..."}
```

### 7b. Create GitHub PAT Secret for git write-back

```bash
# Fine-grained PAT: Contents read+write on flask-demo-1-chart repo ONLY
# (do NOT reuse the Jenkins PAT — minimum privilege per component)
GIT_PAT='ghp_xxxxxxxxxxxxxxxxxxxx'

kubectl -n argocd create secret generic git-creds \
  --from-literal=username=jif718 \
  --from-literal=password="$GIT_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
# Using --dry-run + apply makes this idempotent
```

### 7c. Install Image Updater via Helm

```bash
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  -n argocd \
  -f apps/argocd/image-updater-values.yaml
# Key settings already in values.yaml:
#   serviceAccount.create: false    (reuse eksctl-created IRSA SA)
#   extraEnv: HOME=/tmp             (AWS CLI writes to /tmp, not read-only /app)
#   DO NOT add volumeMounts for /tmp — chart already mounts emptyDir there,
#   adding another causes "duplicate mountPath=/tmp" error in SSA patch.
#   authScripts.ecr-login.sh: ecr get-authorization-token | base64 -d | tr -d '\n'
#     outputs single-line "AWS:<password>" as required by controller.

# Verify pod is running
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater
# Expect: Running

# Quick ECR auth test (after pod is running)
kubectl -n argocd exec -it deploy/argocd-image-updater-controller -- sh -c '
  export HOME=/tmp
  aws ecr get-authorization-token --region ap-east-1 --output text \
    --query "authorizationData[0].authorizationToken" \
  | base64 -d | tr -d "\n" | cut -c1-20
'
# Expect single line starting with: AWS:eyJ
```

### 7d. Apply ImageUpdater CR

```bash
kubectl apply -f apps/argocd/apps/flask-demo-1-imageupdater.yaml
# This CR tells Image Updater:
#   - Watch ArgoCD Application "flask-demo-1"
#   - Track ECR repo: 445529239852.dkr.ecr.ap-east-1.amazonaws.com/myapp/flask-demo-1
#   - Allow tags matching regexp: ^build-[0-9]+$
#   - Strategy: newest-build (picks highest build-N)
#   - Write back: git commit to flask-demo-1-chart repo, values.yaml
#     helm keys: image.repository + image.tag

# Verify CR matched the Application
kubectl get imageupdater -n argocd
# Expect: APPS=1  IMAGES=1  READY=True

# Watch first reconcile cycle (up to 2min interval)
kubectl -n argocd logs deploy/argocd-image-updater-controller -f
# Look for: images_considered=1 images_updated=1 errors=0
#           git push origin main
#           Successfully updated the live application spec
```

---

## Step 8: Deploy Apps via ArgoCD (~5 min)

```bash
# flask-demo-1 Application manifest should already be applied by install-argocd.sh
# If not, apply manually:
kubectl apply -f apps/argocd/apps/flask-demo-1.yaml

# Sync the application
kubectl -n argocd patch application flask-demo-1 \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Or use ArgoCD CLI if installed:
# argocd app sync flask-demo-1

# Watch sync status
kubectl -n argocd get application flask-demo-1 -w
# Expect: SYNC STATUS=Synced  HEALTH STATUS=Healthy

# Check the deployed pod is using the correct image tag
APP_NS=$(kubectl -n argocd get application flask-demo-1 \
  -o jsonpath='{.spec.destination.namespace}')
kubectl get pods -n "$APP_NS" -o jsonpath='{.items[*].spec.containers[*].image}' && echo
# Expect: ...flask-demo-1:build-N (latest build number)
```

---

## Step 9: End-to-End Verify (~3 min)

```bash
# 1. Trigger a Jenkins build (or push a commit to flask-demo-1 repo)
#    Build pushes new image build-N+1 to ECR

# 2. Image Updater detects new tag within 2 minutes
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=20
# Expect: Setting new image to ...flask-demo-1:build-N+1
#         git push origin main
#         images_updated=1 errors=0

# 3. ArgoCD detects git change and syncs
kubectl -n argocd get application flask-demo-1 \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.summary.images}{"\n"}'
# Expect: Synced Healthy [...flask-demo-1:build-N+1]

# 4. Check ImageUpdater CR status (v1.x native status)
kubectl get imageupdater flask-demo-1-updater -n argocd \
  -o jsonpath='{.status.recentUpdates}' | python3 -m json.tool

# 5. Curl the app
APP_NS=$(kubectl -n argocd get application flask-demo-1 \
  -o jsonpath='{.spec.destination.namespace}')
kubectl -n "$APP_NS" port-forward svc/flask-demo-1 8080:80 &
curl -s localhost:8080/health
kill %1
```

---

## Known Issues & Workarounds

| Issue | Symptom | Fix |
|---|---|---|
| Jenkins init container fails | Pod stuck in Init:Error | `readOnlyRootFilesystem: false` in values.yaml (already set) |
| Jenkins webSocket | Agents can't connect | `agent.websocket: true` in values.yaml (already set) |
| eksctl SA conflict with Helm | SSA field manager error | `serviceAccount.create: false` for Jenkins + Image Updater (already set) |
| Image Updater `/app/.aws` read-only | `[Errno 30] Read-only file system` | `extraEnv: HOME=/tmp` (already set); do NOT add `/tmp` volumeMount |
| Image Updater `/tmp` duplicate mount | `duplicate entries for key mountPath=/tmp` | chart already mounts emptyDir at /tmp; remove custom volumeMounts |
| Image Updater no CRs found | `No ImageUpdater CRs to process` | v1.x uses CRD not annotations; apply `flask-demo-1-imageupdater.yaml` |
| ECR script output format | `must be single line with syntax <username>:<password>` | `base64 -d \| tr -d '\n'` in ecr-login.sh |
| Jenkins PAT scope | Chart repo write fails | Image Updater needs its own PAT with chart repo Contents write access |

---

## Quick Smoke Test Commands (copy-paste block)

```bash
# Cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed

# Component status
kubectl get pods -n jenkins
kubectl get pods -n argocd
kubectl get imageupdater -n argocd

# ArgoCD app status
kubectl -n argocd get application

# Image Updater last cycle
kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=10

# ECR latest build numbers
aws ecr describe-images \
  --repository-name myapp/flask-demo-1 \
  --region ap-east-1 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-3:].imageTags' \
  --output table
```

---

## File Reference

```
aws-migration/
├── scripts/
│   ├── bootstrap.sh              # Step 1: create EKS cluster
│   ├── cleanup.sh                # Teardown (keeps ECR + IAM policies)
│   ├── create-ecr-repos.sh       # Step 2: create ECR repos
│   ├── install-jenkins.sh        # Step 4: Jenkins + IRSA
│   └── install-argocd.sh         # Step 6: ArgoCD + flask-demo-1 app
├── apps/
│   ├── storage/gp3-storageclass.yaml           # Step 3
│   ├── jenkins/
│   │   ├── 00-namespace.yaml
│   │   ├── iam-ecr-policy.json
│   │   └── values.yaml                         # Step 4 (91 plugins locked)
│   ├── argocd/
│   │   ├── values.yaml                         # Step 6
│   │   ├── image-updater-values.yaml           # Step 7
│   │   └── apps/
│   │       ├── flask-demo-1.yaml               # ArgoCD Application
│   │       └── flask-demo-1-imageupdater.yaml  # ImageUpdater CR
│   └── petclinic/                              # TODO: future step
├── infra/
│   ├── ecr/repos.txt
│   └── iam/
│       ├── aws-lb-controller-policy.json
│       └── external-dns-policy.json
└── eks/cluster.yaml                            # eksctl cluster config
```
