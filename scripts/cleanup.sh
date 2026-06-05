#!/bin/bash
# cleanup.sh - Tear down the entire EKS environment
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Honor the same overridable config as deploy-all.sh (single source of truth)
# so a custom-named cluster or non-default region is torn down correctly.
source "$SCRIPT_DIR/config.sh"

echo "WARNING: About to delete EKS cluster $CLUSTER_NAME in $REGION. All PVC data will be lost."
read -p "Confirm deletion? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Pre-flight: this script is irreversible AND deletes EBS volumes, so refuse to
# run against the wrong AWS account (e.g. a mis-set profile).
CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER_ACCOUNT" = "$AWS_ACCOUNT_ID" ] \
    || { echo "ERROR: AWS account $CALLER_ACCOUNT != expected $AWS_ACCOUNT_ID"; exit 1; }

# Point kubectl at THIS cluster before touching PVCs/Ingresses, so the deletes
# below can never hit whatever cluster the current kubeconfig context happens to be.
echo "[0/3] Targeting kubeconfig at cluster $CLUSTER_NAME..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Delete Ingresses FIRST, while the ALB controller is still alive, so it can
# release the ALB/TargetGroup/SG it created. eksctl delete cluster (step [2/3])
# kills the controller, after which those AWS resources would orphan and bill.
echo "[1/3] Deleting Ingresses so the ALB controller tears down ALBs/TGs/SGs..."
kubectl delete ingress --all --all-namespaces --wait=false 2>/dev/null || true

# Poll until the controller has actually deleted every ALB it tagged for this
# cluster, instead of a fixed sleep. A surviving ALB keeps an ENI that references
# the controller SG, which blocks VPC deletion in [2/3] (CFN DELETE_FAILED).
# Bounded wait: if it times out we still proceed — the [3/3] sweep is the safety
# net. count_cluster_albs echoes how many cluster-owned ALBs remain.
count_cluster_albs() {
    local n=0 arn owner
    for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true); do
        owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
            --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
            --output text 2>/dev/null || true)
        [ "$owner" = "$CLUSTER_NAME" ] && n=$((n + 1))
    done
    echo "$n"
}

echo "  waiting for ALB controller to tear down cluster-owned ALBs..."
alb_gone=false
for attempt in $(seq 1 12); do   # 12 x 15s = up to 3 min
    remaining=$(count_cluster_albs)
    if [ "$remaining" -eq 0 ]; then
        echo "  no cluster-owned ALBs remain"
        alb_gone=true
        break
    fi
    echo "  [$attempt/12] $remaining ALB(s) still present, retry in 15s"
    sleep 15
done
if [ "$alb_gone" = true ]; then
    # ALBs gone; give the ENIs a short grace to release before deleting the cluster.
    sleep 20
else
    echo "  WARN: ALBs still present after timeout; proceeding (the [3/3] sweep will clean up)"
fi

# NOTE: PVCs are intentionally NOT deleted individually. With a full cluster
# teardown, eksctl delete cluster removes the VPC/nodes and the EBS CSI driver
# releases the backing volumes; the orphan-volume sweep in [3/3] catches any it
# missed. Deleting PVCs here used to leave them stuck Terminating (pvc-protection
# finalizer, pod still attached) if the cluster delete below was then interrupted,
# blocking the next helm upgrade (the 06-04 incident).

echo "[2/3] Deleting EKS cluster..."
# Tolerate eksctl errors so the orphan sweep in [3/3] still runs. A leftover
# ALB SG can block VPC deletion, leaving the CFN stack in DELETE_FAILED; the
# sweep below removes the SG and retries the stack deletion.
eksctl delete cluster -f "$ROOT/infra/cluster.yaml" --wait \
    || echo "  WARN: eksctl delete reported errors; continuing to orphan sweep below"

echo "[3/3] Sweeping orphan EBS volumes, ALBs, TargetGroups, SGs, and CFN stack..."

# --- orphan EBS volumes ---
ORPHAN_VOLUMES=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text)
if [ -n "$ORPHAN_VOLUMES" ]; then
    echo "Found orphan volumes: $ORPHAN_VOLUMES"
    for vol in $ORPHAN_VOLUMES; do
        aws ec2 delete-volume --region "$REGION" --volume-id "$vol"
        echo "  Deleted volume: $vol"
    done
else
    echo "No orphan volumes found."
fi

# --- orphan ALBs ---
# The ALB controller tags every LB it creates with elbv2.k8s.aws/cluster=<name>.
# Catch any that survived step [1/3] (e.g. controller was mid-restart).
# NOTE: delete-load-balancer removes only the ALB itself, NOT its TargetGroups
# or the controller-managed SG — those are swept separately below.
ORPHAN_ALBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
found_alb=false
for alb_arn in $ORPHAN_ALBS; do
    owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$alb_arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
        --output text 2>/dev/null || true)
    if [ "$owner" = "$CLUSTER_NAME" ]; then
        echo "  Deleting orphan ALB owned by $CLUSTER_NAME: $alb_arn"
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$alb_arn"
        found_alb=true
    fi
done
[ "$found_alb" = false ] && echo "No orphan ALBs found."

# Give AWS a moment to finish ALB deletion before removing its TargetGroups/SG
# (the SG can't be deleted while still referenced by a live ALB/ENI).
[ "$found_alb" = true ] && sleep 15

# --- orphan TargetGroups ---
# delete-load-balancer leaves TGs behind. They don't bill but consume quota and
# accumulate across daily rebuilds. Controller tags them with the cluster key.
found_tg=false
for tg_arn in $(aws elbv2 describe-target-groups --region "$REGION" \
    --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true); do
    owner=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$tg_arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
        --output text 2>/dev/null || true)
    if [ "$owner" = "$CLUSTER_NAME" ]; then
        echo "  Deleting orphan TargetGroup: $tg_arn"
        aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$tg_arn" 2>/dev/null \
            && found_tg=true \
            || echo "    (still in use or already gone, skip)"
    fi
done
[ "$found_tg" = false ] && echo "No orphan TargetGroups found."

# --- orphan controller-managed SGs (with ENI-release retry) ---
# The ALB controller tags SGs it creates with elbv2.k8s.aws/cluster=<name>
# (e.g. the ManagedLBSecurityGroup that lock-alb.sh edits). delete-load-balancer
# does NOT remove these. The SG can't be deleted while an ENI still references it
# (ENIs take a minute or two to release after the ALB is deleted), so retry.
# Removing these SGs is also what unblocks the CFN stack deletion below.
found_sg=false; failed_sg=false
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)
for sg_id in $SG_IDS; do
    found_sg=true
    ok=false
    for attempt in 1 2 3 4 5 6; do   # ~3 min total; ENI releases after ALB delete
        if aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id" 2>/dev/null; then
            echo "  Deleted orphan ALB SG: $sg_id"
            ok=true; break
        fi
        echo "  [$attempt/6] SG $sg_id still referenced (ENI releasing), retry in 30s"
        sleep 30
    done
    [ "$ok" = false ] && { echo "  WARN: could not delete SG $sg_id (re-run cleanup later)"; failed_sg=true; }
done
[ "$found_sg" = false ] && echo "No orphan ALB SGs found."
[ "$failed_sg" = true ] && echo "  NOTE: some SGs could not be deleted yet; re-run cleanup once their ENIs release."

# --- retry CloudFormation stack deletion (the real fix for the SG-blocks-VPC incident) ---
# eksctl delete fails if the ALB controller SG blocks VPC teardown, leaving the
# cluster CFN stack in DELETE_FAILED and the VPC/subnets/IGW orphaned. Now that
# the SGs are gone (above), retrying delete-stack lets CFN finish removing the
# VPC and everything in it.
CFN_STACK="eksctl-${CLUSTER_NAME}-cluster"
stack_status=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "$CFN_STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "GONE")
case "$stack_status" in
    GONE)
        echo "  CFN stack $CFN_STACK already gone."
        ;;
    DELETE_FAILED|DELETE_IN_PROGRESS)
        echo "  CFN stack $CFN_STACK is $stack_status; retrying deletion to clean up the VPC"
        aws cloudformation delete-stack --region "$REGION" --stack-name "$CFN_STACK"
        if aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$CFN_STACK" 2>/dev/null; then
            echo "  CFN stack deleted; VPC/subnets/IGW removed."
        else
            echo "  WARN: CFN stack still failing to delete."
            echo "        Check the blocking resource in the CloudFormation console events for $CFN_STACK,"
            echo "        remove it, then re-run cleanup (or: aws cloudformation delete-stack --stack-name $CFN_STACK --region $REGION)."
        fi
        ;;
    *)
        echo "  CFN stack $CFN_STACK status: $stack_status (no retry needed)."
        ;;
esac

# --- final assertion: cluster CFN stack must be truly gone ---
# Guards against the 06-04 incident: if [2/3] was interrupted or CFN is still
# stuck, exit non-zero with a clear warning so we never mistake a half-torn-down
# cluster for a clean teardown (and never run deploy-all against it).
final_status=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "$CFN_STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "GONE")
if [ "$final_status" != "GONE" ]; then
    echo "ERROR: cluster CFN stack $CFN_STACK still present (status=$final_status)."
    echo "       Cluster NOT fully deleted. Do NOT run deploy-all until this is resolved."
    exit 1
fi
echo "Verified: cluster CFN stack $CFN_STACK is gone."

echo ""
echo "################################################"
echo "#                                              #"
echo "#          CLEANUP COMPLETE                    #"
echo "#   Cluster fully deleted; ECR + IAM kept.     #"
echo "#                                              #"
echo "################################################"