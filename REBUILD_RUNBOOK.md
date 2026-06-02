# AWS EKS Cluster Rebuild Runbook

> Project repo: `jif718/aws-jif-lab` (前身 `aws-migration`)
> Chart repo:   `jif718/flask-demo-1-chart` (GitOps 写回目标)
> Region: `ap-east-1` (Hong Kong) · Account: `445529239852`
> Estimated total time: **~50 minutes**

---

## Overview

```
Step 0  Prerequisites + env vars       (~1 min)
Step 1  Bootstrap EKS cluster          (~20 min)   deploy-k8s-cluster.sh
Step 2  Create ECR repos               (~2 min)    create-ecr-repos.sh
Step 3  Install Jenkins + IRSA         (~8 min)    install-jenkins.sh
Step 4  Jenkins post-install (UI)      (~3 min)    manual
Step 5  Install ArgoCD + git-creds     (~5 min)    install-argocd.sh
Step 6  Install Image Updater + IRSA   (~5 min)    install-image-updater.sh
Step 7  Deploy apps via ArgoCD         (~5 min)    deploy-apps.sh
Step 8  End-to-end verify              (~3 min)    manual
```

> StorageClass 不再是独立一步:它是集群级基础设施,已并入 Step 1
> (`deploy-k8s-cluster.sh` 在建集群后顺带 apply `infra/storage/gp3-storageclass.yaml`)。

**一键重建**:`deploy-all.sh` 编排全部步骤(Step 1→7),Step 4/8 为脚本无法覆盖的手动环节。
```bash
chmod +x scripts/*.sh
export GITHUB_PAT='ghp_xxxx'
./scripts/deploy-all.sh
```

---

## Step 0: Prerequisites (run on Mac before starting)

```bash
# Tools
eksctl version; kubectl version --client; helm version; aws --version

# AWS identity
aws sts get-caller-identity --query Account --output text   # Expect: 445529239852

# Helm repos (官方惯例名 jenkins,勿用 jenkinsci —— 见 Known Issue)
helm repo list | grep -E 'jenkins|argo|eks'
# 缺则补:
helm repo add jenkins https://charts.jenkins.io
helm repo add argo    https://argoproj.github.io/argo-helm
helm repo add eks     https://aws.github.io/eks-charts
helm repo update
```

**环境变量**(deploy-all.sh 会 export 默认值,单独跑子脚本时按需 export):
```bash
export GITHUB_PAT='ghp_xxxxxxxxxxxx'   # 必须
export GITHUB_USERNAME='jif718'        # 可选
export AWS_ACCOUNT_ID='445529239852'
export REGION='ap-east-1'
export CLUSTER_NAME='jif-lab'
```

> **PAT 权限**:Image Updater 的 git 写回是 push 到 GitHub,其 PAT 必须对
> `flask-demo-1-chart` 有 **Contents: Read and write**。只读 PAT 会让 secret
> 建对了仍 push 403。各组件用独立 fine-grained PAT(最小权限),勿复用 Jenkins PAT。

---

## Step 1: Bootstrap EKS Cluster + StorageClass (~20 min)

```bash
cd ~/code/aws-jif-lab
./scripts/deploy-k8s-cluster.sh
#   1. eksctl create cluster -f infra/cluster.yaml
#      (2x t4g.large On-Demand, arm64, EKS 1.35, ap-east-1)
#   2. apply infra/storage/gp3-storageclass.yaml,并把 gp2 降级为非默认
#   集群已存在则跳过创建(幂等)

# Verify
kubectl get nodes                          # Expect: 2 nodes, Ready
kubectl get nodes -o wide | grep arm64     # Expect: arm64 confirmed
kubectl get storageclass                   # Expect: gp3 = default
```

> 集群定义唯一 source 是 `infra/cluster.yaml`(旧 `eks/cluster.yaml` 已删,歧义消除)。

---

## Step 2: Create ECR Repos (~2 min)

```bash
./scripts/create-ecr-repos.sh
# 幂等:逐行读 infra/ecr/repos.txt,已存在跳过
#   myapp/flask-demo-1
#   myapp/flask-demo-1/cache
#   library/kaniko-executor:v1.24.0-debug   (arm64, 从 gcr.io 迁入)
#   devops/python-agent                     (lab 残留;AWS 用 Docker Hub python:3.12-slim)
#   library/spring-petclinic                (预留)

# Verify
aws ecr describe-repositories --region ap-east-1 \
  --query 'repositories[].repositoryName' --output table
```

> cleanup 后 ECR 通常保留,此步多为 no-op。

---

## Step 3: Install Jenkins + IRSA (~8 min)

> KNOWN ISSUE: chart 5.9.22 + image 2.555.2-lts 默认 `readOnlyRootFilesystem: true`,
> 会让跑 jenkins-plugin-cli 的 init container 失败(写 /usr/share/jenkins/ref/plugins)。
> 该 chart 无独立 initContainerSecurityContext,values.yaml 已在
> controller.containerSecurityContext 设 `readOnlyRootFilesystem: false` 修复。

```bash
export GITHUB_PAT='ghp_xxxx'    # 需对 flask-demo-1 业务 repo 有读权限
./scripts/install-jenkins.sh
#   1. apply apps/jenkins/00-namespace.yaml
#   2. 建 jenkins-credentials secret(JCasC 启动时解析,先于 helm install)
#   3. 确保 ECR push IAM policy(apps/jenkins/iam-ecr-policy.json)
#   4. IRSA for jenkins + jenkins-agent SA(含 CFN drift 恢复)
#   5. helm upgrade --install jenkins jenkins/jenkins -f apps/jenkins/values.yaml
#   sanity checks: webSocket=true, readOnlyRootFilesystem=false

# Verify
kubectl get pods -n jenkins                # Expect: jenkins-0 Running 1/1
kubectl -n jenkins get sa jenkins jenkins-agent \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
# Expect: 两个 SA 都有 role-arn 注解
```

---

## Step 4: Jenkins Post-Install Config (~3 min, manual)

> UI 交互 + secret 同步,脚本无法覆盖。

```bash
# 1. 初始密码
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d && echo

# 2. port-forward + 打开 UI
kubectl -n jenkins port-forward svc/jenkins 8080:8080 &
open http://localhost:8080            # 登录 admin / <上面的密码>

# 3. UI 改密码后,同步回 K8s secret
NEW_PASS='your-new-password'
kubectl -n jenkins patch secret jenkins \
  -p "{\"data\":{\"jenkins-admin-password\":\"$(echo -n $NEW_PASS | base64)\"}}"

# 4. UI 建 Pipeline job:
#    New Item → flask-demo-1 → Pipeline
#    Pipeline: SCM → Git
#    Repo: https://github.com/jif718/flask-demo-1.git  (业务 repo)
#    Credentials: github-token (读权限 PAT)
#    Branch: */main · Script Path: Jenkinsfile

kill %1                                # 收尾关 port-forward
```

> Jenkinsfile tag 方案见末尾「镜像 Tag 方案」一节(SHA+时间戳,已弃用 build-N)。

---

## Step 5: Install ArgoCD + git-creds (~5 min)

```bash
export GITHUB_PAT='ghp_xxxx'
./scripts/install-argocd.sh
#   1. helm upgrade --install argocd argo/argo-cd -f apps/argocd/values.yaml (chart 9.5.16 → app v3.4.3)
#   2. 等 argocd-server rollout
#   3. 建 git-creds secret(★已固化进脚本,见 Known Issue #git-creds)

# values.yaml 关键项(勿改):
#   server.insecure: true   (port-forward over HTTP,免 TLS/gRPC-Web 问题)
#   dex / notifications / applicationSet: disabled

# Verify
kubectl get pods -n argocd                 # all Running
kubectl -n argocd get secret git-creds -o jsonpath='{.data}' | jq 'keys'
# Expect: ["password","username"]
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

> 注:原始脚本写死 chart 9.5.15;已统一到 9.5.16/v3.4.3。建议脚本里
> `CHART_VERSION="${ARGOCD_CHART_VERSION:-9.5.16}"` 以便父脚本覆盖。

---

## Step 6: Install Image Updater + IRSA (~5 min)

```bash
./scripts/install-image-updater.sh
#   1. ECR 只读 IAM policy ArgoCDImageUpdaterECRRead(policy JSON 内联在脚本,不落临时文件)
#   2. IRSA for SA argocd-image-updater(serviceAccount.create=false,复用 eksctl SA)
#   3. helm upgrade --install argocd-image-updater argo/argocd-image-updater
#        -f apps/argocd/image-updater-values.yaml

# values.yaml 关键项:
#   serviceAccount.create: false   (复用 eksctl 建的 IRSA SA)
#   extraEnv: HOME=/tmp            (AWS CLI 写 /tmp,非只读 /app)
#   勿为 /tmp 加 volumeMounts —— chart 已挂 emptyDir,重复会触发 SSA duplicate mountPath
#   authScripts ecr-login.sh: ... | base64 -d | tr -d '\n'  输出单行 AWS:<pass>

# Verify
kubectl -n argocd get sa argocd-image-updater \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' && echo
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater   # Running

# ECR auth 自测(pod Running 后)
kubectl -n argocd exec deploy/argocd-image-updater -- sh -c '
  export HOME=/tmp
  aws ecr get-authorization-token --region ap-east-1 --output text \
    --query "authorizationData[0].authorizationToken" | base64 -d | tr -d "\n" | cut -c1-20'
# Expect 单行: AWS:eyJ...
```

**手动 fallback**(脚本失败时,逐步手动建 IRSA):
```bash
# IAM policy(脚本已内联;手动则用 heredoc)
cat > /tmp/iu-ecr-policy.json <<'EOF'
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":[
  "ecr:GetAuthorizationToken","ecr:BatchGetImage","ecr:DescribeImages",
  "ecr:DescribeRepositories","ecr:ListImages","ecr:GetDownloadUrlForLayer",
  "ecr:BatchCheckLayerAvailability"],"Resource":"*"}]}
EOF
aws iam create-policy --policy-name ArgoCDImageUpdaterECRRead \
  --policy-document file:///tmp/iu-ecr-policy.json --region ap-east-1 \
  2>/dev/null || echo "exists, skip"

eksctl create iamserviceaccount --cluster jif-lab --region ap-east-1 \
  --namespace argocd --name argocd-image-updater \
  --attach-policy-arn arn:aws:iam::445529239852:policy/ArgoCDImageUpdaterECRRead \
  --override-existing-serviceaccounts --approve
```

---

## Step 7: Deploy Apps via ArgoCD (~5 min)

```bash
./scripts/deploy-apps.sh
# 约定目录自动发现:扫 apps/argocd/apps/,凡 <name>.yaml + <name>-imageupdater.yaml
# 成对出现即部署。每个 app:先 apply ImageUpdater CR(v1.x CRD-driven),再 apply
# Application,逐个轮询等 Synced + Healthy(最多 30×10s)。
# 当前成对文件:flask-demo-1.yaml + flask-demo-1-imageupdater.yaml
# 加新 app(flask-demo-2 / html5demo):丢两个文件进目录,脚本不改。

# Verify CR 匹配上 Application
kubectl get imageupdater -n argocd            # Expect: APPS=1 IMAGES=1 READY=True

# 看首轮 reconcile(间隔最多 2min)
kubectl -n argocd logs deploy/argocd-image-updater -f | grep flask-demo-1
# Look for: Successfully updated image ...:<ts>-<sha>
#           images_considered=1 images_updated=1 errors=0
#           Successfully updated the live application spec

# Application 同步状态
kubectl -n argocd get application flask-demo-1     # Synced + Healthy
```

---

## Step 8: End-to-End Verify (~3 min)

```bash
# 1. 触发 Jenkins build(或 push commit 到 flask-demo-1 业务 repo)
#    build 推新镜像 <ts>-<sha> 到 ECR

# 2. Image Updater 2 分钟内检测到新 tag
kubectl -n argocd logs deploy/argocd-image-updater --tail=20
# Expect: Setting new image to ...:<ts>-<sha> / Committing ... / images_updated=1 errors=0

# 3. ArgoCD 检测到 git 变更并同步
kubectl -n argocd get application flask-demo-1 \
  -o jsonpath='{.status.sync.status} {.status.health.status} {.status.summary.images}{"\n"}'
# Expect: Synced Healthy [...flask-demo-1:<ts>-<sha>]

# 4. ImageUpdater CR 原生状态(v1.x)
kubectl get imageupdater flask-demo-1-updater -n argocd \
  -o jsonpath='{.status.recentUpdates}' | python3 -m json.tool

# 5. pod 跑的是最新镜像
APP_NS=$(kubectl -n argocd get application flask-demo-1 \
  -o jsonpath='{.spec.destination.namespace}')
kubectl get pods -n "$APP_NS" \
  -o jsonpath='{.items[*].spec.containers[*].image}' && echo

# 6. 真实流量(不只看 status)
kubectl -n "$APP_NS" port-forward svc/flask-demo-1 8080:80 &
curl -s localhost:8080/health     # probe path:Step 8 待办里计划从 / 改到 /health
kill %1

# 7. GitHub 端:flask-demo-1-chart/values.yaml 的 image.tag 已被 commit 成
#    <ts>-<sha>,author = argocd-image-updater
```

---

## 镜像 Tag 方案(SHA + 时间戳) ★ 已弃用 build-N

**弃用 `build-${BUILD_NUMBER}`**:Jenkins 重置/迁移后 build number 归零,
`newest-build` 排序失效(新 build-1 < 旧 build-247)。

**新格式**:`<UTC时间戳14位>-<git短SHA7位>`,例 `20260602052039-4ec1963`
- 时间戳定宽 14 位(`yyyyMMddHHmmss`)→ 字典序 == 时间序,`newest-build` 正确排序,不依赖 build number
- git 短 SHA 7 位 → 反查代码(GitHub `/commit/<sha>`)
- **时区固定 UTC**:与 agent 时区无关、与基础设施日志(K8s/ECR/CloudWatch 均 UTC)对齐;勿改本地时区
- 勿用变长时间格式(Unix 秒、去前导零):字典序会与时间序错位

**Jenkinsfile 要点**(declarative + `agent none`):
- tag **不能**放 `environment{}`:该块在 checkout 前求值,既拿不到 `GIT_COMMIT`(checkout 后才填充),也不能跑 `sh`(无 FilePath/node context)→ 报 `Required context class hudson.FilePath is missing` 或 `agent none` 下报 node context 缺失
- 在 build stage 内接住 SHA(不依赖可能为空的 `env.GIT_COMMIT`):
  ```groovy
  stage('Build and Push to ECR') {
      agent { label 'kaniko' }
      steps {
          script {
              def scmVars = checkout scm
              def gitSha  = scmVars.GIT_COMMIT.take(7)
              def buildTs = new Date().format('yyyyMMddHHmmss', TimeZone.getTimeZone('UTC'))
              env.TAG = "${buildTs}-${gitSha}"
              echo "Image tag resolved: ${env.TAG}"
          }
          container('kaniko') {
              sh '''
                  /kaniko/executor \
                    --context "${WORKSPACE}" \
                    --dockerfile "${WORKSPACE}/Dockerfile" \
                    --destination "${IMAGE}:${TAG}" \
                    --cache=true \
                    --cache-repo "${ECR_REGISTRY}/${IMAGE_NAME}/cache" \
                    --verbosity info
              '''
          }
      }
  }
  ```
- 时区写法用 `TimeZone.getTimeZone('UTC')`(Groovy 沙箱默认放行);**勿用** `java.time.ZoneOffset.UTC`(被沙箱拦:`Scripts not permitted to use staticField`)
- 赋值用 `env.TAG`(非 `def`):才能跨 stage/pod 持久,并被 kaniko `sh` 单引号块里 `${TAG}` 由 shell 展开读到(`IMAGE`/`ECR_REGISTRY`/`IMAGE_NAME` 同理须为环境变量)

**对应 ImageUpdater CR**(`apps/argocd/apps/flask-demo-1-imageupdater.yaml`):
```yaml
updateStrategy: "newest-build"
allowTags: "regexp:^[0-9]{14}-[0-9a-f]{7}$"
manifestTargets:
  helm:
    name: "image.repository"
    tag: "image.tag"
writeBackConfig:
  method: "git:secret:argocd/git-creds"
  gitConfig:
    repository: "https://github.com/jif718/flask-demo-1-chart.git"
    branch: "main"
    writeBackTarget: "helmvalues:/values.yaml"
```

**写回所有权唯一**:Image Updater 接管 git 写回后,必须移除 Jenkinsfile 里
同样 commit chart repo 的 "Update Helm Chart Repo" stage,否则双写冲突。

---

## Known Issues & Workarounds

| Issue | Symptom | Fix |
|---|---|---|
| Jenkins init container fails | Pod stuck Init:Error | `readOnlyRootFilesystem: false` in values.yaml(已设) |
| Jenkins webSocket | Agents 连不上 | `webSocket: true` in values.yaml(已设);agentListener 关闭,无 TCP 50000 |
| eksctl SA 与 Helm 冲突 | SSA field manager error | `serviceAccount.create: false`(Jenkins + Image Updater,已设) |
| Image Updater `/app/.aws` 只读 | `[Errno 30] Read-only file system` | `extraEnv: HOME=/tmp`(已设);勿加 /tmp volumeMount |
| Image Updater `/tmp` 重复挂载 | `duplicate entries for key mountPath=/tmp` | chart 已挂 emptyDir;移除自定义 volumeMounts |
| Image Updater 无 CR | `No ImageUpdater CRs to process` | v1.x 用 CRD 非 annotation;apply flask-demo-1-imageupdater.yaml |
| ECR 脚本输出格式 | `must be single line with syntax <username>:<password>` | ecr-login.sh 用 `base64 -d \| tr -d '\n'` |
| **git-creds 缺失** ★ | `could not get creds for repo '...flask-demo-1-chart.git': secrets "git-creds" not found`,`images_updated=0 errors=1` | argocd ns 需有 git-creds(username/password),PAT 对 chart repo 有写权限。已固化进 install-argocd.sh。手动补建见下。 |
| PAT 写权限不足 | git-creds 建对了仍 push 403 | Image Updater 的 PAT 需 chart repo Contents read/write |
| helm repo 名撞车 | `helm repo add jenkins` 静默失败 / chart 解析失败 | 同 URL 不能两名;统一官方 `jenkins`,删除残留 `jenkinsci` |
| Jenkinsfile tag 取不到 SHA | tag 变 `<ts>-unknown` | `env.GIT_COMMIT` 为空;改用 `def scmVars = checkout scm; scmVars.GIT_COMMIT.take(7)` |
| Groovy 沙箱拦时区 | `Scripts not permitted to use staticField java.time.ZoneOffset UTC` | 改用 `TimeZone.getTimeZone('UTC')`,或 JCasC script-approval 声明式预批准 |

> **git-creds 隐患为何长期未暴露**:旧 build-N 方案下 values.yaml 的 tag 恰好已是最新,
> Image Updater 判定"无需更新",从不走到 git 写回那步,故凭据缺失一直没显形;
> 换 SHA 方案后每次都触发写回,问题才暴露。

**git-creds 手动补建**:
```bash
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=jif718 \
  --from-literal=password="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd rollout restart deploy/argocd-image-updater
```

---

## Quick Smoke Test (copy-paste block)

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

# git-creds 存在性(常见漏建项)
kubectl -n argocd get secret git-creds -o jsonpath='{.data}' | jq 'keys'

# Image Updater 最近一轮
kubectl -n argocd logs deploy/argocd-image-updater --tail=10

# ECR 最近 3 个 tag
aws ecr describe-images --repository-name myapp/flask-demo-1 --region ap-east-1 \
  --query 'sort_by(imageDetails,&imagePushedAt)[-3:].imageTags' --output table
```

---

## Step 8 待办(下次活跃会话)

- AWS Load Balancer Controller + Ingress:一个 ALB 服务 Jenkins/ArgoCD/app
  (比每服务一个 NLB 便宜);external-dns + ACM 证书做 HTTPS 域名访问
- 已就位素材:`apps/gateway/aws-lb-controller-install.md`、`infra/iam/aws-lb-controller-policy.json`、
  `apps/external-dns/values.yaml`、`infra/iam/external-dns-policy.json`
- flask-demo-1 probe path 从 `/` 改到 `/health`(GitOps 实践练习)
- Jenkins 插件安全告警:`pipeline-groovy-lib` SECURITY-3727、`credentials-binding` SECURITY-3790
  (SOP:改 values.yaml 版本 → helm upgrade → 删 PVC 内 initialization-completed flag → 删 pod → 验 MANIFEST.MF)

---

## File Reference

```
aws-jif-lab/
├── scripts/
│   ├── deploy-all.sh             # 编排层:env vars + source preflight + 按序调子脚本
│   ├── preflight-checks.sh       # 全局前置检查(被 deploy-all.sh source)
│   ├── deploy-k8s-cluster.sh     # Step 1: EKS cluster + gp3 StorageClass
│   ├── create-ecr-repos.sh       # Step 2: ECR repos
│   ├── install-jenkins.sh        # Step 3: Jenkins + IRSA
│   ├── install-argocd.sh         # Step 5: ArgoCD + git-creds
│   ├── install-image-updater.sh  # Step 6: Image Updater + IRSA
│   ├── deploy-apps.sh            # Step 7: 约定目录成对部署所有 app
│   └── cleanup.sh                # Teardown(保留 ECR + IAM policies)
├── apps/
│   ├── jenkins/
│   │   ├── 00-namespace.yaml
│   │   ├── iam-ecr-policy.json
│   │   └── values.yaml                         # 91 plugins locked
│   ├── argocd/
│   │   ├── values.yaml
│   │   ├── image-updater-values.yaml
│   │   └── apps/
│   │       ├── flask-demo-1.yaml               # ArgoCD Application
│   │       └── flask-demo-1-imageupdater.yaml  # ImageUpdater CR
│   ├── external-dns/values.yaml                # Step 8
│   ├── gateway/aws-lb-controller-install.md    # Step 8
│   ├── monitoring/                             # 预留未实施
│   └── petclinic/                              # 预留未实施
└── infra/
    ├── cluster.yaml                            # eksctl cluster config(唯一 source)
    ├── storage/gp3-storageclass.yaml           # cluster-scoped,从 apps/ 移入
    ├── ecr/repos.txt
    └── iam/
        ├── aws-lb-controller-policy.json       # Step 8
        └── external-dns-policy.json            # Step 8
```
