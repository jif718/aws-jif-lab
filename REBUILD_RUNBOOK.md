# AWS EKS Cluster Rebuild Runbook

> Project repo: `jif718/aws-jif-lab` (前身 `aws-migration`)
> Chart repo:   `jif718/flask-demo-1-chart` (GitOps 写回目标)
> Region: `ap-east-1` (Hong Kong) · Account: `445529239852`
> Estimated total time: **~55 minutes** (含 Step 8 gateway + Ingress)

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
Step 8a Ensure ACM wildcard cert       (~1 min*)   manage-acm-cert.sh
Step 8b Install Gateway (ALB+ext-dns)  (~5 min)    install-gateway.sh
Step 8c Lock shared ALB to my IP       (~1 min)    lock-alb.sh
Step 9  End-to-end verify              (~3 min)    manual
```

> *Step 8a 仅首次签发证书需等 ~5 min DNS 验证；后续重建复用已 ISSUED 的证书,秒过。
>
> StorageClass 不是独立一步:它是集群级基础设施,已并入 Step 1
> (`deploy-k8s-cluster.sh` 在建集群后顺带 apply `infra/storage/gp3-storageclass.yaml`)。

**一键重建**:`deploy-all.sh` 编排全部步骤(Step 1→8),Step 4/9 为脚本无法覆盖的手动环节。
```bash
chmod +x scripts/*.sh
export GITHUB_PAT='ghp_xxxx'
./scripts/deploy-all.sh
```

deploy-all.sh 的 STEPS 顺序(gateway 在 deploy-apps 之前,这样 app 的 Ingress 同步时 ALB Controller 已就位、立刻能建 ALB):
```
deploy-k8s-cluster.sh → create-ecr-repos.sh → install-jenkins.sh →
install-argocd.sh → install-image-updater.sh →
manage-acm-cert.sh (8a) → install-gateway.sh (8b) → deploy-apps.sh
```
> lock-alb.sh (8c) 由 install-jenkins / install-argocd / deploy-apps 各自末尾调用,
> 每次可能触发 ALB Controller reconcile 的部署后都重锁一次(见 Step 8c 竞态说明)。

---

## Step 0: Prerequisites (run on Mac before starting)

```bash
# Tools
eksctl version; kubectl version --client; helm version; aws --version

# AWS identity
aws sts get-caller-identity --query Account --output text   # Expect: 445529239852

# Helm repos (官方惯例名 jenkins,勿用 jenkinsci —— 见 Known Issues)
helm repo list | grep -E 'jenkins|argo|eks|external-dns'
# 缺则补:
helm repo add jenkins      https://charts.jenkins.io
helm repo add argo         https://argoproj.github.io/argo-helm
helm repo add eks          https://aws.github.io/eks-charts
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
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
#   6. 末尾调用 lock-alb.sh(锁共享 ALB 到当前出口 IP)
#   sanity checks: webSocket=true, readOnlyRootFilesystem=false

# Verify
kubectl get pods -n jenkins                # Expect: jenkins-0 Running 1/1
kubectl -n jenkins get sa jenkins jenkins-agent \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
# Expect: 两个 SA 都有 role-arn 注解
```

> **Step 8 相关改动**:Jenkins values 现含 `controller.ingress`(ALB Ingress)、
> `jenkinsUrl: https://jenkins.aws.ololol.lol/`(对外域名)。但 **agent 回连用内部地址**
> (cloud 配置 `jenkinsUrl: http://jenkins.jenkins.svc.cluster.local:8080/`),
> 否则锁 IP 后 agent 出口 IP 被 SG 挡 → CI 构建失败。详见 Known Issues。

---

## Step 4: Jenkins Post-Install Config (~3 min, manual)

> UI 交互 + secret 同步,脚本无法覆盖。

```bash
# 1. 初始密码
kubectl -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d && echo

# 2. 访问 UI:Step 8 后走 ALB 域名(你的 IP 已被 lock-alb 放行)
open https://jenkins.aws.ololol.lol   # 登录 admin / <上面的密码>
# (port-forward 仍可作为后备:kubectl -n jenkins port-forward svc/jenkins 8080:8080)

# 3. UI 改密码后,同步回 K8s secret
NEW_PASS='your-new-password'
kubectl -n jenkins patch secret jenkins \
  -p "{\"data\":{\"jenkins-admin-password\":\"$(echo -n $NEW_PASS | base64)\"}}"

# 4. UI 建 Pipeline job:
#    New Item → flask-demo-1 → Pipeline
#    Repo: https://github.com/jif718/flask-demo-1.git  (业务 repo)
#    Credentials: github-token · Branch: */main · Script Path: Jenkinsfile
```

> Jenkinsfile tag 方案见末尾「镜像 Tag 方案」一节(SHA+时间戳,已弃用 build-N)。

---

## Step 5: Install ArgoCD + git-creds (~5 min)

```bash
export GITHUB_PAT='ghp_xxxx'
./scripts/install-argocd.sh
#   1. helm upgrade --install argocd argo/argo-cd -f apps/argocd/values.yaml (chart 9.5.16 → app v3.4.3)
#   2. 等 argocd-server rollout
#   3. 建 git-creds secret(★已固化进脚本,见 Known Issues #git-creds)
#   4. 末尾调用 lock-alb.sh

# values.yaml 关键项(勿改):
#   server.insecure: true   (ALB 终结 TLS,到 argocd-server 走 HTTP;Step 8 注释已预判)
#   dex / notifications / applicationSet: disabled

# Verify
kubectl get pods -n argocd                 # all Running
kubectl -n argocd get secret git-creds -o jsonpath='{.data}' | jq 'keys'
# Expect: ["password","username"]
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

> ArgoCD values 现含 `server.ingress`(ALB Ingress,host `argocd.aws.ololol.lol`,
> healthcheck `/healthz`)。`server.insecure: true` 配合 ALB 终结 TLS,无需改。

---

## Step 6: Install Image Updater + IRSA (~5 min)

```bash
./scripts/install-image-updater.sh
#   1. ECR 只读 IAM policy ArgoCDImageUpdaterECRRead(policy JSON 内联,不落临时文件)
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
```

---

## Step 7: Deploy Apps via ArgoCD (~5 min)

```bash
./scripts/deploy-apps.sh
# 约定目录自动发现:扫 apps/argocd/apps/,凡 <name>.yaml + <name>-imageupdater.yaml
# 成对出现即部署。先 apply ImageUpdater CR(v1.x CRD-driven),再 apply Application,
# 逐个轮询等 Synced + Healthy(最多 30×10s)。末尾调用 lock-alb.sh。

# Verify
kubectl get imageupdater -n argocd            # Expect: APPS=1 IMAGES=1 READY=True
kubectl -n argocd get application             # Synced + Healthy
```

> flask-demo-1 的 **Ingress 在 chart repo 的 `templates/ingress.yaml`**(helm create 默认模板),
> 随 chart 被 ArgoCD 同步。chart values 的 `ingress` 段:`enabled: true`、`className: alb`、
> host `flask-demo-1.aws.ololol.lol`、`group.name: jif-lab`、`tls: []`(ALB 经 ACM 终结 TLS)。
> **不写 certificate-arn** —— 走证书自动发现(见 Step 8 证书方案)。

---

## Step 8: Ingress / HTTPS / 外网入口

替代 lab 的 port-forward / MetalLB,建立企业级入口:**一个共享 ALB 服务三个服务,
ACM 通配符证书做 HTTPS,external-dns 自动写 DNS,ALB 安全组锁定到我的出口 IP。**

### 架构

```
                         Internet
                            │ HTTPS (ACM *.aws.ololol.lol)
                            ▼
              ALB (group=jif-lab, internet-facing)
              SG 入站只放行我的出口 IP (lock-alb.sh)
        ┌───────────────────┼───────────────────┐
        ▼                    ▼                   ▼
 jenkins.aws...       argocd.aws...      flask-demo-1.aws...
   jenkins svc        argocd-server svc   flask-demo-1 svc
        ▲                    ▲                   ▲
        └──── external-dns 自动写三条 Route53 A/AAAA 记录 ────┘
```

三个服务共享同一个 ALB(都标 `group.name: jif-lab`),ALB 按 host 分流。
比每服务一个 NLB 便宜 2/3(一个 ALB 固定费 vs 三个)。

### Step 8a: ACM 通配符证书 (manage-acm-cert.sh)

```bash
./scripts/manage-acm-cert.sh
#   幂等:查 ap-east-1 是否已有 *.aws.ololol.lol 的 ISSUED 证书 → 有则复用 ARN
#   无则 request-certificate(DNS 验证)→ 往 Route53 写验证 CNAME → wait 至 ISSUED
#   export ACM_CERT_ARN
```

- **证书跨集群存活**:cleanup 不删 ACM 证书,每日重建复用同一张,免重签。
- **证书必须在 ap-east-1**(ALB 同 region),不是 us-east-1(那是 CloudFront 的要求)。
- **一张通配符 `*.aws.ololol.lol` 覆盖 jenkins./argocd./flask-demo-1. 全部子域**。
- DNS 验证全自动依赖 `aws.ololol.lol` zone 委派已生效(Route53 子域,父域已配 NS)。

### Step 8b: Gateway — ALB Controller + external-dns (install-gateway.sh)

```bash
./scripts/install-gateway.sh
#   1. 动态取 VPC id(LIVE from cluster,每次重建都变,绝不硬编码)
#   2. 校验 IAM policy 存在(AWSLoadBalancerControllerIAMPolicy / ExternalDNSPolicy)
#   3. IRSA: aws-load-balancer-controller + external-dns(均 kube-system,serviceAccount.create=false)
#   4. helm install aws-load-balancer-controller(--set vpcId 动态)
#   5. helm install external-dns(-f apps/external-dns/values.yaml)

# Verify
kubectl -n kube-system get deploy aws-load-balancer-controller external-dns
kubectl -n kube-system get sa aws-load-balancer-controller external-dns \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
# Expect: 两个 SA 都有 role-arn(这是 cluster-info.md 第五节的 Step 8 IRSA 缺口)
```

> external-dns values:`domainFilters: [aws.ololol.lol]`、`policy: upsert-only`、
> `txtOwnerId: jif-lab-eks`(跨重建不变,新 external-dns 用同 owner id 认领旧记录)、
> `serviceAccount.create: false`(复用 eksctl IRSA SA)。

### Step 8 证书方案:Controller 自动发现(方向 B,无硬编码 ARN)

**三个 Ingress 都不写 `certificate-arn` annotation。** ALB Controller 在 443 listener
无显式证书时,会按 rule host 去 ACM 匹配 ISSUED 证书的 CN/SAN —— 通配符
`*.aws.ololol.lol` 自动匹配三个子域。

- 依赖 Controller IAM policy 含 `acm:ListCertificates` + `acm:DescribeCertificate`
  (`infra/iam/aws-lb-controller-policy.json` 已含)。
- 优点:chart / values 与具体证书 ARN 解耦;证书重签 ARN 变也自动适配;
  多 app 零证书配置(都靠 host 匹配同一张通配符证书)。
- 验证自动发现生效:Ingress annotation **无** certificate-arn,但 443 listener **仍绑着**证书。

```bash
# 确认 443 listener 自动绑上了通配符证书
ALB_ARN=$(aws elbv2 describe-load-balancers --region ap-east-1 \
  --query "LoadBalancers[?contains(DNSName,'k8s-jiflab')].LoadBalancerArn | [0]" --output text)
HTTPS_L=$(aws elbv2 describe-listeners --region ap-east-1 --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text)
aws elbv2 describe-listener-certificates --region ap-east-1 --listener-arn "$HTTPS_L" \
  --query 'Certificates[].CertificateArn' --output text
# Expect: *.aws.ololol.lol 证书的 ARN(虽然没在 Ingress 写它)
```

### Step 8c: 锁定共享 ALB 到我的出口 IP (lock-alb.sh)

**目的**:Jenkins/ArgoCD 是高价值攻击目标(暴露的它们会被扫描器/CVE 利用),
flask 现也无真实用户。把整个共享 ALB 的安全组入站锁到我的家宽出口 IP,
扫描器/bot 连 ALB 都连不上(SG 层拒绝),同时根除 DDoS 涨 LCU 费的尾部风险。

```bash
./scripts/lock-alb.sh
#   1. curl https://checkip.amazonaws.com 取当前出口 IP(家宽 IP 会变,每次动态取)
#   2. 按 elbv2.k8s.aws/cluster=jif-lab tag 找本集群 ALB,等其 active
#   3. 清空该 ALB 的 SG 入站规则,只放行 <my-ip>/32 对 80/443
#   4. apply + verify 重试 3 次(缓解与 Controller reconcile 的竞态)

# Verify
ALB_ARN=$(aws elbv2 describe-load-balancers --region ap-east-1 \
  --query "LoadBalancers[?contains(DNSName,'k8s-jiflab')].LoadBalancerArn | [0]" --output text)
SG_ID=$(aws elbv2 describe-load-balancers --region ap-east-1 --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
aws ec2 describe-security-group-rules --region ap-east-1 \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'SecurityGroupRules[?!IsEgress].[CidrIpv4,FromPort,ToPort]' --output table
# Expect: 只有 <my-ip>/32 对 80/443,无 0.0.0.0/0
```

> **设计决策(为何用脚本而非 Ingress annotation 锁)**:
> - 要"任何单独部署都锁、且 IP 动态",而 flask 走 GitOps 无法 shell 注入 IP;
> - inbound-cidrs annotation 由 Controller 按 group 内全部 Ingress 重算 SG,
>   单点设置撑不住每次 reconcile(只 jenkins 设 → 重部署 flask 触发 reconcile 时锁丢);
> - 故锁交给独立的 lock-alb.sh **独占**管理 SG,三个 Ingress 均**不设** inbound-cidrs。
> - 三个部署脚本(install-jenkins / install-argocd / deploy-apps)末尾各调一次,
>   保证任何单独部署后都重锁。

> **★ 竞态(必读)**:lock-alb.sh 与 ALB Controller 都管这个 SG。Controller reconcile
> 时会把 SG 重置(常变回 0.0.0.0/0),lock-alb.sh 再收窄 —— 存在竞态。
> 任何触发 Ingress reconcile 的操作(改 Ingress / ArgoCD selfHeal / 重部署)**之后**
> 需重跑 `./scripts/lock-alb.sh`。lock-alb.sh 内置 apply+verify 重试缓解,但非根治。
> 若部署后发现 SG 又出现 0.0.0.0/0,手动重跑 lock-alb.sh。

> **家宽 IP 会变**:实测同一天内出口 IP 可从 120.231.x 变成 120.229.x。lock-alb.sh
> 每次 curl 动态取,故 IP 变了重跑即可 —— 这正是不写死 IP 的原因。

---

## Step 9: End-to-End Verify (~3 min)

> 本地 curl 经 OpenClash 代理可能被劫持(见 Known Issues),验证优先用集群内 pod
> (绕过本地网络)或确认 OpenClash 对 aws.ololol.lol 直连。

```bash
# 1. 三个 Ingress 共享同一个 ALB(ADDRESS 相同)
kubectl get ingress -A
# Expect: 三个 host 不同,ADDRESS 同一个 k8s-jiflab-...elb 域名

# 2. external-dns 写了三条记录,DNS 解析(DoH 绕过本地 53 拦截)
for h in flask-demo-1 jenkins argocd; do
  echo "=== $h ==="
  curl -s "https://dns.google/resolve?name=$h.aws.ololol.lol&type=A" | jq -r '.Answer[]?.data'
done

# 3. HTTPS 端到端 —— 从集群内 pod 发起(绕过本地 OpenClash,最可靠)
kubectl run t --rm -it --restart=Never --image=curlimages/curl -- \
  curl -skI https://flask-demo-1.aws.ololol.lol/health   # Expect: HTTP/2 200
# (你本地直连也应 200;集群内 pod 因出口 IP 不在白名单,锁生效时反而应被挡 —— 见下)

# 4. 锁生效双向验证:你能进,非你 IP 被挡
curl -skI https://jenkins.aws.ololol.lol/login           # 你本地直连 → 200
kubectl run t --rm -it --restart=Never --image=curlimages/curl -- \
  curl -m10 -skI https://flask-demo-1.aws.ololol.lol/health
# 集群内 pod(出口 IP 非你的)→ 超时/terminated(Error) = 锁精准生效
```

---

## 镜像 Tag 方案(SHA + 时间戳) ★ 已弃用 build-N

**新格式**:`<UTC时间戳14位>-<git短SHA7位>`,例 `20260602052039-4ec1963`
- 时间戳定宽 14 位(`yyyyMMddHHmmss`)→ 字典序==时间序,`newest-build` 正确排序,不依赖 build number
- git 短 SHA 7 位 → 反查代码(GitHub `/commit/<sha>`)
- **时区固定 UTC**:与基础设施日志对齐;勿用变长时间格式(字典序会与时间序错位)

**Jenkinsfile 要点**(declarative + `agent none`):
- tag 不能放 `environment{}`(checkout 前求值,拿不到 GIT_COMMIT,也不能跑 sh)
- build stage 内:`def scmVars = checkout scm; def gitSha = scmVars.GIT_COMMIT.take(7)`
- 时间戳:`new Date().format('yyyyMMddHHmmss', TimeZone.getTimeZone('UTC'))`
  (Groovy 沙箱默认放行;**勿用** `java.time.ZoneOffset.UTC`,被沙箱拦)
- 赋值用 `env.TAG`(非 def),才能跨 stage 持久 + 被 kaniko sh 单引号块读到

**对应 ImageUpdater CR**:
```yaml
updateStrategy: "newest-build"
allowTags: "regexp:^[0-9]{14}-[0-9a-f]{7}$"
writeBackConfig:
  method: "git:secret:argocd/git-creds"
  gitConfig:
    repository: "https://github.com/jif718/flask-demo-1-chart.git"
    branch: "main"
    writeBackTarget: "helmvalues:/values.yaml"
```

**写回所有权唯一**:Image Updater 接管 git 写回后,必须移除 Jenkinsfile 里
同样 commit chart repo 的 stage,否则双写冲突。

---

## Known Issues & Workarounds

| Issue | Symptom | Fix |
|---|---|---|
| Jenkins init container fails | Pod stuck Init:Error | `readOnlyRootFilesystem: false` in values.yaml(已设) |
| Jenkins webSocket | Agents 连不上 | `webSocket: true`(已设);agentListener 关闭,无 TCP 50000 |
| eksctl SA 与 Helm 冲突 | SSA field manager error | `serviceAccount.create: false`(Jenkins/Image Updater/gateway 均适用) |
| Image Updater `/app/.aws` 只读 | `[Errno 30] Read-only file system` | `extraEnv: HOME=/tmp`(已设);勿加 /tmp volumeMount |
| Image Updater 无 CR | `No ImageUpdater CRs to process` | v1.x 用 CRD 非 annotation;apply flask-demo-1-imageupdater.yaml |
| **git-creds 缺失** ★ | `secrets "git-creds" not found`,`images_updated=0 errors=1` | argocd ns 需有 git-creds(username/password),PAT 对 chart repo 有写权限。已固化进 install-argocd.sh。 |
| PAT 写权限不足 | git-creds 建对了仍 push 403 | Image Updater PAT 需 chart repo Contents read/write |
| helm repo 名撞车 | `helm repo add` 静默失败 | 同 URL 不能两名;统一官方名 jenkins,删残留 jenkinsci |
| Groovy 沙箱拦时区 | `Scripts not permitted to use staticField java.time.ZoneOffset UTC` | 改用 `TimeZone.getTimeZone('UTC')` |
| **证书自动发现未生效** | 443 listener 无证书 / HTTPS 失败 | Ingress 不写 certificate-arn 时 Controller 按 host 匹配 ACM;需 manage-acm-cert.sh 先确保证书 ISSUED,且 Controller IAM 有 acm:List/DescribeCertificate。证书必须在 ap-east-1。 |
| **ALB 锁竞态** ★ | lock-alb.sh 锁完 SG 又变 0.0.0.0/0 | Controller reconcile 重置 SG;与 lock-alb.sh 双管同一 SG。任何触发 Ingress reconcile 的操作后重跑 ./scripts/lock-alb.sh。三个部署脚本末尾已各调一次。Ingress 不设 inbound-cidrs。 |
| **Jenkins agent 被 SG 挡** | 锁 IP 后 CI 构建 agent 连不上 controller | agent 回连必须走内部地址 `http://jenkins.jenkins.svc.cluster.local:8080/`(cloud 配置 jenkinsUrl),不经 ALB;`unclassified.location.url` 才用外部域名。 |
| **OpenClash 干扰本地验证** | 本地 curl 空白 / TLS SSL_ERROR_SYSCALL;nslookup 返回 198.18.x.x | OpenClash fake-ip 劫持 + 透明代理切 TLS。AWS 侧正常。用集群内 pod 验证,或 OpenClash 对 aws.ololol.lol 设 DIRECT。 |
| 家宽 IP 漂移 | 锁 IP 后突然自己也进不去 | 出口 IP 变了。重跑 ./scripts/lock-alb.sh(动态取当前 IP)。 |
| **eksctl delete 失败** ★ | `1 error(s) occurred while deleting cluster` / `waiter state transitioned to Failure` | ALB controller 的 SG 卡住 VPC 删除 → CFN stack DELETE_FAILED。cleanup `[4/4]` 已自动:删 SG(ENI 释放后重试)+ 重试 delete-stack。详见下方 playbook。 |
| 孤儿 SG 删除 DependencyViolation | `delete-security-group` 报 still referenced | ALB 删后 ENI 释放有 1-2 分钟延迟。cleanup `[4/4]` 已加 6×30s 重试;仍失败则稍后重跑 cleanup。 |
| 孤儿 TG / SG 累积 | 每日重建后 region TG/SG 越来越多撞配额 | `delete-load-balancer` 只删 ALB 本体。cleanup `[4/4]` 已按 elbv2.k8s.aws/cluster tag 兜底清 TG/SG。 |

### Playbook: ALB SG 卡 VPC 删除 → eksctl/CFN 删除失败

**每日重建场景下会反复出现的连锁故障。cleanup.sh `[4/4]` 已自动化处置;此处记录根因
与手动兜底,供脚本仍失败时排查。**

#### 故障链(根因还原)

```
[1/4] 删 Ingress 后,ALB controller 未在等待窗口内拆完 ALB
  → ALB 的 managed SG(tag elbv2.k8s.aws/cluster=jif-lab)残留在 VPC
  → [3/4] eksctl delete cluster 删 VPC 时,VPC 仍被该 SG 占用 → 删不掉
  → CFN stack eksctl-jif-lab-cluster 进 DELETE_FAILED
  → eksctl 报 "1 error(s) occurred" / waiter Failure
  → VPC/子网/IGW 成孤儿(NAT GW 通常已随 stack 删,需确认 deleted)
```

关键:`delete-load-balancer` 只删 ALB 本体,**不删** controller 建的 SG;而这个 SG
正是卡住 VPC 删除的元凶。删 ALB 后 ENI 释放有 1-2 分钟延迟,SG 在此期间删不掉。

#### 自动处置(cleanup.sh 已实现)

- `[1/4]` 删 Ingress 后 sleep **60s**(原 30s 不够 controller 拆完)。
- `[3/4]` eksctl delete 加 `|| WARN`,失败不中断,继续兜底。
- `[4/4]` 顺序:EBS → ALB → (sleep 15) → TargetGroup → **SG(6×30s 重试等 ENI 释放)**
  → **CFN stack 重删**(SG 清掉后重试 delete-stack 收掉 VPC)。

#### 手动兜底(脚本仍失败时按序执行)

```bash
VPC=<orphan-vpc-id>   # aws ec2 describe-vpcs --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=jif-lab"

# 1. 确认 NAT GW 已 deleted(计费资源,优先)
aws ec2 describe-nat-gateways --region ap-east-1 \
  --filter "Name=vpc-id,Values=$VPC" --query 'NatGateways[].[NatGatewayId,State]' --output text

# 2. 找卡住的 controller SG,确认无 ENI 引用后删
aws ec2 describe-security-groups --region ap-east-1 \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=jif-lab" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text
aws ec2 describe-network-interfaces --region ap-east-1 \
  --filters "Name=group-id,Values=<sg-id>" --query 'NetworkInterfaces[].Status' --output text  # 空即可删
aws ec2 delete-security-group --region ap-east-1 --group-id <sg-id>

# 3. SG 删掉后,重试删 CFN stack(连带清 VPC/子网/IGW)
aws cloudformation describe-stacks --region ap-east-1 \
  --stack-name eksctl-jif-lab-cluster --query 'Stacks[0].StackStatus' --output text
aws cloudformation delete-stack --region ap-east-1 --stack-name eksctl-jif-lab-cluster
aws cloudformation wait stack-delete-complete --region ap-east-1 \
  --stack-name eksctl-jif-lab-cluster && echo "VPC gone"
```

> 控制面已 404 后 `eksctl delete cluster` 会报 `No cluster found` —— 此时残留的是
> **VPC 层**,只能走 CloudFormation `delete-stack` 清理,不要再用 eksctl。

#### 删除后验证全清(四类均应为空)

```bash
aws elbv2 describe-load-balancers --region ap-east-1 --query 'LoadBalancers[].LoadBalancerName' --output text
aws elbv2 describe-target-groups --region ap-east-1 --query 'TargetGroups[].TargetGroupName' --output text
aws ec2 describe-security-groups --region ap-east-1 \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=jif-lab" --query 'SecurityGroups[].GroupId' --output text
aws cloudformation describe-stacks --region ap-east-1 \
  --stack-name eksctl-jif-lab-cluster --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "stack gone"
```

---

## Teardown (cleanup.sh)

```bash
./scripts/cleanup.sh    # 交互确认 yes
```

清理顺序(为孤儿问题特别设计):
```
[0/4] 指向本集群 kubeconfig
[1/4] 删 Ingress + sleep 60   ← controller 趁活着拆 ALB/TG/SG(主路径)
[2/4] 删 PVC
[3/4] eksctl delete || WARN   ← 失败不中断
[4/4] 兜底:EBS → ALB → TG → SG(重试)→ CFN stack 重删
```

> ECR repos 与 IAM policies 保留(cleanup 不删,跨重建复用)。
> ACM 证书、Route53 zone 同样保留(不属于集群)。
> ALB/TG/SG/VPC 由 cleanup 主路径 + 兜底清理,见上方 playbook。

---

## File Reference

```
aws-jif-lab/
├── scripts/
│   ├── deploy-all.sh             # 编排:env + preflight + 按序调子脚本(含 8a/8b)
│   ├── preflight-checks.sh
│   ├── deploy-k8s-cluster.sh     # Step 1
│   ├── create-ecr-repos.sh       # Step 2
│   ├── install-jenkins.sh        # Step 3(末尾调 lock-alb.sh)
│   ├── install-argocd.sh         # Step 5(末尾调 lock-alb.sh)
│   ├── install-image-updater.sh  # Step 6
│   ├── manage-acm-cert.sh        # Step 8a:ACM 通配符证书(幂等复用)
│   ├── install-gateway.sh        # Step 8b:ALB Controller + external-dns + 2 IRSA
│   ├── lock-alb.sh               # Step 8c:锁共享 ALB SG 到当前出口 IP
│   ├── deploy-apps.sh            # Step 7(末尾调 lock-alb.sh)
│   ├── config.sh                 # 共享配置(含 Step 8 gateway/DNS 变量)
│   └── cleanup.sh                # Teardown(孤儿 EBS/ALB/TG/SG + CFN stack 兜底)
├── apps/
│   ├── jenkins/values.yaml       # 91 plugins;controller.ingress;agent 内部 jenkinsUrl
│   ├── argocd/
│   │   ├── values.yaml           # server.insecure;server.ingress
│   │   ├── image-updater-values.yaml
│   │   └── apps/
│   │       ├── flask-demo-1.yaml
│   │       └── flask-demo-1-imageupdater.yaml
│   ├── external-dns/values.yaml  # domainFilters aws.ololol.lol;Step 8b
│   ├── gateway/aws-lb-controller-install.md  # 手动安装参考(日常走 install-gateway.sh)
│   ├── monitoring/               # 预留未实施
│   └── petclinic/                # 预留未实施
└── infra/
    ├── cluster.yaml              # eksctl cluster config(唯一 source)
    ├── storage/gp3-storageclass.yaml
    ├── ecr/repos.txt
    └── iam/
        ├── aws-lb-controller-policy.json   # 含 acm:List/DescribeCertificate(证书自动发现依赖)
        └── external-dns-policy.json

flask-demo-1-chart/ (chart repo)
├── Chart.yaml
├── values.yaml                   # ingress 段:alb/host/group.name/tls:[];无 certificate-arn
└── templates/
    ├── ingress.yaml              # helm create 默认模板(annotations 走 values)
    ├── deployment.yaml
    ├── service.yaml
    └── _helpers.tpl
```
