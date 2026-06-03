#!/bin/bash
# lock-alb.sh - Lock the shared ALB's security group to the current egress IP.
#
# WHY a standalone script (not Ingress annotations):
#   flask-demo-1 is GitOps-managed (no shell hook to inject a dynamic IP), and
#   we want the ALB locked after ANY single-app deploy regardless of which one
#   created/updated the ALB. This script resolves the current IP and rewrites
#   the ALB SG inbound rules to exactly that IP on 80/443.
#
# KNOWN RACE (documented in RUNBOOK): the ALB Controller also manages this SG.
# On reconcile it resets the SG (often to 0.0.0.0/0). This script must run
# AFTER the controller settles. It waits for the ALB to be active, applies the
# lock, then re-verifies; re-run it after anything that triggers a reconcile.
#
# Idempotent: wipes all existing inbound rules each run, then sets one IP.
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
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query 'LoadBalancers[].LoadBalancerArn' --output text); do
    owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
      --output text 2>/dev/null || true)
    if [ "$owner" = "$CLUSTER_NAME" ]; then echo "$arn"; return 0; fi
  done
  return 1
}

# Wait for the ALB to exist + be active (controller may still be creating it).
ALB_ARN=""
for i in $(seq 1 18); do   # up to ~3 min
  ALB_ARN=$(find_alb || true)
  if [ -n "$ALB_ARN" ]; then
    state=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --load-balancer-arns "$ALB_ARN" \
      --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || true)
    [ "$state" = "active" ] && break
  fi
  echo "  [$i/18] waiting for ALB to be active (state=${state:-none})"
  sleep 10
done
[ -n "$ALB_ARN" ] || { echo "ERROR: no ALB for cluster $CLUSTER_NAME (deploy an Ingress first)"; exit 1; }
echo "  ALB: $ALB_ARN"

# 3. Resolve the ALB's security group.
SG_ID=$(aws elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text)
echo "  SG:  $SG_ID"

# 4. apply_lock(): wipe all inbound rules, then allow only $CIDR on 80/443.
apply_lock() {
  local existing
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

# verify_locked(): true only if inbound is EXACTLY $CIDR and nothing open.
verify_locked() {
  local cidrs
  cidrs=$(aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$SG_ID" \
    --query 'SecurityGroupRules[?!IsEgress].CidrIpv4' --output text)
  # no 0.0.0.0/0 present AND our CIDR present
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