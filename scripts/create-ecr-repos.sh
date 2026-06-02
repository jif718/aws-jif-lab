#!/bin/bash
# create-ecr-repos.sh - Create ECR repositories from repos.txt
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/config.sh"   # ROOT, REGION, ... (standalone or via deploy-all)
REPOS_FILE="$ROOT/infra/ecr/repos.txt"

echo "Creating ECR repositories in region $REGION..."

while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    
    if aws ecr describe-repositories --repository-names "$repo" --region $REGION >/dev/null 2>&1; then
        echo "  [skip] $repo already exists"
    else
        aws ecr create-repository \
            --repository-name "$repo" \
            --region $REGION \
            --image-scanning-configuration scanOnPush=true \
            --image-tag-mutability MUTABLE \
            --encryption-configuration encryptionType=AES256 \
            --query 'repository.repositoryUri' \
            --output text
        echo "  [created] $repo"
    fi
done < "$REPOS_FILE"

echo ""
echo "All ECR repositories:"
aws ecr describe-repositories --region $REGION \
    --query 'repositories[].[repositoryName,repositoryUri]' \
    --output table
