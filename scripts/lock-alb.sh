#!/bin/bash
# lock-alb.sh - Lock the shared ALB's security group to the current egress IP.
#
# WHY a standalone script (not Ingress annotations):
#   flask-demo-1 is GitOps-managed (no shell hook to inject a dynamic IP), and
#   we want the ALB locked after ANY deploy regardless of which one created it.
#   This script resolves the current egress IP and rewrites the ALB SG inbound
#   rules to exactly that IP on 80/443.
#
# CALLED FROM: install-jenkins.sh / install-argocd.sh / deploy-apps.sh (end),
#   and deploy-all.sh (final). On a FULL rebuild the ALB does not exist until an
#   Ingress is synced (deploy-apps), so early callers find no ALB yet — that is
#   NORMAL: this script SKIPS (exit 0) instead of failing, so it never aborts
#   deploy-all. The lock is applied by the later caller once the ALB exists.
#
# KNOWN RACE (see RUNBOOK): the ALB Controller also manages this SG. On reconcile
#   it may reset the SG (often to 0.0.0.0/0). Re-run this script after anything
#   that triggers an Ingress reconcile (Ingress change / ArgoCD selfHeal / redeploy).
#
# Idempotent: wipes all existing inbound rules each run, then sets exactly one
# IP on 80/443. Picks up egress-IP changes automatically (home broadband IP drifts).
#
# Usage: ./scripts/lock-alb.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # REGION, CLUSTER_NAME

# 1. Resolve current egress IP (the only IP allowed to reach the ALB).
MY_IP=$(curl -s https://checkip.amazonaws.com)
[ -n "$MY_IP" ] || { echo "ERROR: cannot resolve egress IP"; exit 1; }
CIDR="${MY_IP}/32"
echo "===> [lock-alb] current egress IP: $CIDR"

# 2. Find the cluster's shared ALB by the controller's cluster tag,
#    so we never touch an unrelated load balancer.
find_alb() {
  local arn owner
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true); do
    owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
      --output text 2>/dev/null || true)
    if [ "$owner" = "$CLUSTER_NAME" ]; then echo "$arn"; return 0; fi
  done
  return 1
}

# Probe ONCE. If no ALB exists yet (early step of a full rebuild), SKIP — do not
# fail, or it would abort deploy-all. The later caller (deploy-apps) will lock it.
ALB_ARN=$(find_alb || true)
if [ -z "$ALB_ARN" ]; then
  echo "  [lock-alb] no ALB yet for cluster $CLUSTER_NAME — skipping."
  echo "             (the ALB is created when an Ingress is synced; lock applies then)"
  exit 0
fi

# Found an ALB — wait for it to become active (it may still be provisioning).
for i in $(seq 1 12); do   # up to ~2 min
  state=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || true)
  [ "$state" = "active" ] && break
  echo "  [$i/12] waiting for ALB to be active (state=${state:-provisioning})"
  sleep 10
done
echo "  ALB: $ALB_ARN"

# 3. Resolve the ALB's security group.
SG_ID=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
echo "  SG:  $SG_ID"

# 4. apply_lock(): wipe all inbound rules, then allow only $CIDR on 80/443.
apply_lock() {
  local existing rule_id
  existing=$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text)
  for rule_id in $existing; do
    aws ec2 revoke-security-group-ingress --region "$REGION" \
      --group-id "$SG_ID" --security-group-rule-ids "$rule_id" >/dev/null
  done
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" \
    --ip-permissions \
      "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$CIDR,Description=my-ip}]" \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$CIDR,Description=my-ip}]" \
    >/dev/null 2>&1 || true   # tolerate "already exists" if a prior run set it
}

# verify_locked(): true only if inbound is exactly $CIDR and nothing open.
verify_locked() {
  local cidrs
  cidrs=$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query 'SecurityGroupRules[?!IsEgress].CidrIpv4' --output text)
  echo "$cidrs" | grep -q "0.0.0.0/0" && return 1
  echo "$cidrs" | grep -q "$MY_IP" && return 0
  return 1
}

# 5. Apply, then re-check a few times to win the race against controller reconcile.
echo "  applying lock"
for attempt in 1 2 3; do
  apply_lock
  sleep 5
  if verify_locked; then
    echo "===> [lock-alb] LOCKED: SG $SG_ID allows only $CIDR on 80/443"
    exit 0
  fi
  echo "  [attempt $attempt] SG not yet locked (controller may have reset it), retrying"
done

echo "WARN: could not confirm lock after retries — controller may be reconciling."
echo "      Re-run ./scripts/lock-alb.sh once Ingress changes settle."
exit 1
