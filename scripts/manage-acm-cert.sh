#!/bin/bash
# manage-acm-cert.sh - Idempotently ensure a wildcard ACM cert for BASE_DOMAIN
# exists and is ISSUED, using Route53 DNS validation. Exports ACM_CERT_ARN.
#
# Why this is its own script (not in install-gateway.sh):
#   - ACM certs are NOT cluster resources; cleanup.sh does not delete them, so
#     a cert survives the daily cluster rebuild. We must therefore look up and
#     REUSE an existing cert rather than re-request one every day.
#   - DNS validation (vs email) is fully automatable: we upsert the validation
#     CNAME into the delegated Route53 zone, which we already confirmed resolves.
#
# Usage (standalone):  source scripts/manage-acm-cert.sh   # to capture ACM_CERT_ARN
#        (orchestrated): called by deploy-all.sh before install-gateway.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config.sh"   # REGION, ACM_DOMAIN, BASE_DOMAIN, HOSTED_ZONE_ID

echo "===> [acm] ensuring wildcard cert for $ACM_DOMAIN in $REGION"

# Cert MUST be in the ALB's region (ap-east-1). This is unlike CloudFront,
# which requires us-east-1. ALB consumes a same-region ACM cert only.
# 1) Reuse an existing ISSUED (or still-validating) cert if one matches.
EXISTING_ARN=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='${ACM_DOMAIN}'].CertificateArn | [0]" \
  --output text 2>/dev/null || true)

if [ -n "$EXISTING_ARN" ] && [ "$EXISTING_ARN" != "None" ]; then
  echo "  found existing cert: $EXISTING_ARN (reusing)"
  CERT_ARN="$EXISTING_ARN"
else
  echo "  no existing cert, requesting new one"
  CERT_ARN=$(aws acm request-certificate \
    --region "$REGION" \
    --domain-name "$ACM_DOMAIN" \
    --validation-method DNS \
    --query 'CertificateArn' --output text)
  echo "  requested: $CERT_ARN"
  # ACM needs a moment to populate the DNS validation record fields.
  sleep 8
fi

# 2) If not yet ISSUED, push the DNS validation CNAME into Route53.
STATUS=$(aws acm describe-certificate --region "$REGION" \
  --certificate-arn "$CERT_ARN" \
  --query 'Certificate.Status' --output text)

if [ "$STATUS" != "ISSUED" ]; then
  echo "  status=$STATUS — writing DNS validation record to Route53"

  # Resolve hosted zone id dynamically if not pinned in config.
  ZONE_ID="${HOSTED_ZONE_ID:-}"
  if [ -z "$ZONE_ID" ]; then
    ZONE_ID=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id | [0]" --output text \
      | sed 's#/hostedzone/##')
  fi
  [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] \
    || { echo "ERROR: cannot resolve hosted zone for $BASE_DOMAIN"; exit 1; }

  # Extract the CNAME name/value ACM wants for validation.
  RR_NAME=$(aws acm describe-certificate --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text)
  RR_VALUE=$(aws acm describe-certificate --region "$REGION" \
    --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)

  cat > /tmp/acm-validation.json <<JSON
{
  "Comment": "ACM DNS validation for ${ACM_DOMAIN}",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${RR_NAME}",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{ "Value": "${RR_VALUE}" }]
    }
  }]
}
JSON

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch file:///tmp/acm-validation.json >/dev/null
  echo "  validation CNAME upserted; waiting for ACM to issue (up to 5 min)"

  aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN"
  echo "  cert ISSUED"
fi

export ACM_CERT_ARN="$CERT_ARN"
echo "===> [acm] ACM_CERT_ARN=$ACM_CERT_ARN"