#!/bin/bash
# pre-delete-check.sh - Verify state before deleting cluster
set -e

echo "=== Git status ==="
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
    echo "WARNING: uncommitted changes found"
    git status --short
else
    echo "Git working tree clean"
fi

echo ""
echo "=== Unpushed commits ==="
UNPUSHED=$(git log origin/main..HEAD --oneline 2>/dev/null || echo "")
if [ -n "$UNPUSHED" ]; then
    echo "WARNING: unpushed commits"
    echo "$UNPUSHED"
else
    echo "All commits pushed to origin"
fi

echo ""
echo "=== Persistent AWS resources (will survive cluster deletion) ==="
echo ""
echo "ECR repositories:"
aws ecr describe-repositories --region ap-east-1 \
    --query 'repositories[].[repositoryName,createdAt]' --output table 2>/dev/null || echo "  none"

echo ""
echo "Route 53 zones:"
aws route53 list-hosted-zones \
    --query 'HostedZones[?contains(Name, `aws.ololol.lol`)].[Id,Name]' --output table

echo ""
echo "IAM policies created for the lab:"
for p in AWSLoadBalancerControllerIAMPolicy ExternalDNSPolicy; do
    aws iam list-policies --query "Policies[?PolicyName=='$p'].[PolicyName]" --output text 2>/dev/null
done

echo ""
echo "=== Secrets you must back up to a password manager ==="
echo "  [ ] GitHub PAT (ghp_xxx)"
echo "  [ ] AWS Access Key ID + Secret for devops-admin"
echo ""
echo "If all OK, run: ./scripts/cleanup.sh"
