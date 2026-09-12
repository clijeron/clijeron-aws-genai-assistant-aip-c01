#!/usr/bin/env bash
#
# Part 3 / Failover — Step 3: API Gateway regional custom domains for aws.lijeron.net
# ===================================================================================
# Creates a REGIONAL custom domain name (aws.lijeron.net) in each region, backed
# by that region's ACM cert, and maps it (base path = "") to the region's prod
# stage. Captures each custom domain's REGIONAL TARGET hostname + hosted zone id,
# which the failover alias records (Step 4) point at.
#
set -euo pipefail

[ -f failover_resources.env ] || { echo "ERROR: run r53_02_certs.sh first (failover_resources.env missing)."; exit 1; }
# shellcheck disable=SC1091
source failover_resources.env

PRIMARY_API="mtipvxmr4k"     # us-west-2 (Part 2)
SECONDARY_API="95wrutetrf"   # us-east-1 (CFN)
STAGE="prod"

make_domain() {  # $1 region ; $2 certArn ; $3 apiId ; prints "target|zoneid"
  local region="$1" cert="$2" api="$3" target zone
  # Idempotency: create only if missing.
  if ! aws apigateway get-domain-name --domain-name "$DOMAIN" --region "$region" >/dev/null 2>&1; then
    aws apigateway create-domain-name --domain-name "$DOMAIN" \
      --regional-certificate-arn "$cert" \
      --endpoint-configuration types=REGIONAL \
      --tags auto-delete=true \
      --region "$region" >/dev/null
  fi
  # Base-path mapping (root) to the prod stage.
  aws apigateway get-base-path-mapping --domain-name "$DOMAIN" --base-path "(none)" \
    --region "$region" >/dev/null 2>&1 || \
  aws apigateway create-base-path-mapping --domain-name "$DOMAIN" \
    --rest-api-id "$api" --stage "$STAGE" --region "$region" >/dev/null 2>&1 || true

  target=$(aws apigateway get-domain-name --domain-name "$DOMAIN" --region "$region" \
    --query 'regionalDomainName' --output text)
  zone=$(aws apigateway get-domain-name --domain-name "$DOMAIN" --region "$region" \
    --query 'regionalHostedZoneId' --output text)
  echo "$target|$zone"
}

echo "Creating custom domain in $PRIMARY_REGION ..."
P=$(make_domain "$PRIMARY_REGION" "$PRIMARY_CERT" "$PRIMARY_API")
PRIMARY_TARGET="${P%%|*}"; PRIMARY_TARGET_ZONE="${P##*|}"

echo "Creating custom domain in $SECONDARY_REGION ..."
S=$(make_domain "$SECONDARY_REGION" "$SECONDARY_CERT" "$SECONDARY_API")
SECONDARY_TARGET="${S%%|*}"; SECONDARY_TARGET_ZONE="${S##*|}"

for v in PRIMARY_TARGET PRIMARY_TARGET_ZONE SECONDARY_TARGET SECONDARY_TARGET_ZONE; do
  eval "val=\$$v"
  [ -n "$val" ] && [ "$val" != "None" ] || { echo "ERROR: $v resolved empty"; exit 1; }
done

{
  echo "PRIMARY_API=$PRIMARY_API"
  echo "SECONDARY_API=$SECONDARY_API"
  echo "PRIMARY_TARGET=$PRIMARY_TARGET"
  echo "PRIMARY_TARGET_ZONE=$PRIMARY_TARGET_ZONE"
  echo "SECONDARY_TARGET=$SECONDARY_TARGET"
  echo "SECONDARY_TARGET_ZONE=$SECONDARY_TARGET_ZONE"
} >> failover_resources.env

echo "Targets:"
echo "  primary  : $PRIMARY_TARGET (zone $PRIMARY_TARGET_ZONE)"
echo "  secondary: $SECONDARY_TARGET (zone $SECONDARY_TARGET_ZONE)"
echo "Next: bash r53_04_failover_records.sh"
