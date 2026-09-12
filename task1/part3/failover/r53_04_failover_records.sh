#!/usr/bin/env bash
#
# Part 3 / Failover — Step 4: health check + PRIMARY/SECONDARY failover records
# =============================================================================
# Creates a Route 53 health check against the PRIMARY region's /health endpoint,
# then two failover ALIAS A-records for aws.lijeron.net:
#   - PRIMARY   -> us-west-2 custom-domain target, tied to the health check
#   - SECONDARY -> us-east-1 custom-domain target
# When the primary health check fails, Route 53 serves the secondary.
#
set -euo pipefail

[ -f failover_resources.env ] || { echo "ERROR: run steps 2 and 3 first."; exit 1; }
# shellcheck disable=SC1091
source failover_resources.env

PRIMARY_API="${PRIMARY_API:-mtipvxmr4k}"
PRIMARY_HEALTH_FQDN="$PRIMARY_API.execute-api.$PRIMARY_REGION.amazonaws.com"
PRIMARY_HEALTH_PATH="/prod/health"

# 1. Health check on the primary /health (HTTPS GET).
HC_ID=$(aws route53 create-health-check \
  --caller-reference "hc-primary-$(date +%s)" \
  --health-check-config "Type=HTTPS,Port=443,ResourcePath=$PRIMARY_HEALTH_PATH,FullyQualifiedDomainName=$PRIMARY_HEALTH_FQDN,RequestInterval=30,FailureThreshold=3" \
  --query 'HealthCheck.Id' --output text)
echo "health check: $HC_ID  (on https://$PRIMARY_HEALTH_FQDN$PRIMARY_HEALTH_PATH)"
aws route53 change-tags-for-resource --resource-type healthcheck --resource-id "$HC_ID" \
  --add-tags Key=auto-delete,Value=true >/dev/null

# 2. Failover alias records.
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\":[
    {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
      \"Name\":\"$DOMAIN\",\"Type\":\"A\",\"SetIdentifier\":\"primary-uswest2\",
      \"Failover\":\"PRIMARY\",\"HealthCheckId\":\"$HC_ID\",
      \"AliasTarget\":{\"DNSName\":\"$PRIMARY_TARGET\",\"HostedZoneId\":\"$PRIMARY_TARGET_ZONE\",\"EvaluateTargetHealth\":true}}},
    {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
      \"Name\":\"$DOMAIN\",\"Type\":\"A\",\"SetIdentifier\":\"secondary-useast1\",
      \"Failover\":\"SECONDARY\",
      \"AliasTarget\":{\"DNSName\":\"$SECONDARY_TARGET\",\"HostedZoneId\":\"$SECONDARY_TARGET_ZONE\",\"EvaluateTargetHealth\":true}}}
  ]}" >/dev/null

echo "HC_ID=$HC_ID" >> failover_resources.env
echo
echo "=== Failover configured for https://$DOMAIN/generate ==="
echo "Wait ~60s for DNS + health check to settle, then:"
echo "  curl -s -X POST https://$DOMAIN/generate -H 'Content-Type: application/json' \\"
echo "    -d '{\"prompt\":\"What is a 401(k)?\",\"use_case\":\"general\"}' | jq ."
echo
echo "Failover drill: disable the primary /health (e.g. throttle primary Lambda or"
echo "temporarily remove /health), watch health check go Unhealthy in the Route 53"
echo "console, then re-run the curl — it should transparently serve from us-east-1."
