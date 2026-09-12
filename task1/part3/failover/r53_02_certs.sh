#!/usr/bin/env bash
#
# Part 3 / Failover — Step 2: regional ACM certs for aws.lijeron.net (both regions)
# =================================================================================
# API Gateway REGIONAL custom domains require a REGIONAL ACM cert in the SAME
# region. So we request one cert in us-west-2 and one in us-east-1, both for
# aws.lijeron.net, and DNS-validate them via the aws.lijeron.net hosted zone
# (work account). ACM uses the same validation CNAME for the same domain, so a
# single validation record typically covers both certs.
#
# Writes cert ARNs to failover_resources.env.
#
set -euo pipefail

DOMAIN="aws.lijeron.net"
PRIMARY_REGION="us-west-2"
SECONDARY_REGION="us-east-1"
ENV_OUT="failover_resources.env"

# Discover the work-account hosted zone id for aws.lijeron.net.
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='$DOMAIN.'].Id" --output text | sed 's|/hostedzone/||')
[ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || { echo "ERROR: hosted zone for $DOMAIN not found in this account"; exit 1; }
echo "Zone for $DOMAIN: $ZONE_ID"

request_cert() {  # $1 = region ; echoes cert ARN
  aws acm request-certificate --domain-name "$DOMAIN" \
    --validation-method DNS --region "$1" \
    --tags Key=auto-delete,Value=true \
    --query CertificateArn --output text
}

PRIMARY_CERT=$(request_cert "$PRIMARY_REGION")
SECONDARY_CERT=$(request_cert "$SECONDARY_REGION")
echo "primary cert   ($PRIMARY_REGION): $PRIMARY_CERT"
echo "secondary cert ($SECONDARY_REGION): $SECONDARY_CERT"

# Give ACM a moment to populate the DNS validation records.
sleep 8

upsert_validation() {  # $1 = cert ARN ; $2 = region
  local name value
  name=$(aws acm describe-certificate --certificate-arn "$1" --region "$2" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text)
  value=$(aws acm describe-certificate --certificate-arn "$1" --region "$2" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text)
  [ -n "$name" ] && [ "$name" != "None" ] || { echo "  (validation record not ready yet for $1)"; return 1; }
  echo "  validation CNAME: $name -> $value"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
    \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
      \"Name\":\"$name\",\"Type\":\"CNAME\",\"TTL\":300,
      \"ResourceRecords\":[{\"Value\":\"$value\"}]}}]}" >/dev/null
}

echo "Creating DNS validation records in $ZONE_ID ..."
upsert_validation "$PRIMARY_CERT" "$PRIMARY_REGION" || true
upsert_validation "$SECONDARY_CERT" "$SECONDARY_REGION" || true

echo "Waiting for both certs to be ISSUED (this can take several minutes) ..."
aws acm wait certificate-validated --certificate-arn "$PRIMARY_CERT" --region "$PRIMARY_REGION"
aws acm wait certificate-validated --certificate-arn "$SECONDARY_CERT" --region "$SECONDARY_REGION"
echo "Both certificates ISSUED."

# Persist for later steps (append-safe).
{
  echo "ZONE_ID=$ZONE_ID"
  echo "DOMAIN=$DOMAIN"
  echo "PRIMARY_REGION=$PRIMARY_REGION"
  echo "SECONDARY_REGION=$SECONDARY_REGION"
  echo "PRIMARY_CERT=$PRIMARY_CERT"
  echo "SECONDARY_CERT=$SECONDARY_CERT"
} > "$ENV_OUT"
echo "Wrote $ENV_OUT. Next: bash r53_03_custom_domains.sh"
