#!/usr/bin/env bash
#
# Part 3 / Failover — Teardown
# ============================
# Removes failover records, health check, custom domains, and ACM certs created
# by the r53_* scripts. Reads failover_resources.env. Safe to re-run.
#
set -uo pipefail

[ -f failover_resources.env ] || { echo "failover_resources.env not found (run from failover/)."; exit 1; }
# shellcheck disable=SC1091
source failover_resources.env

echo "Removing failover alias records ..."
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\":[
    {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
      \"Name\":\"$DOMAIN\",\"Type\":\"A\",\"SetIdentifier\":\"primary-uswest2\",
      \"Failover\":\"PRIMARY\",\"HealthCheckId\":\"${HC_ID:-}\",
      \"AliasTarget\":{\"DNSName\":\"$PRIMARY_TARGET\",\"HostedZoneId\":\"$PRIMARY_TARGET_ZONE\",\"EvaluateTargetHealth\":true}}},
    {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
      \"Name\":\"$DOMAIN\",\"Type\":\"A\",\"SetIdentifier\":\"secondary-useast1\",
      \"Failover\":\"SECONDARY\",
      \"AliasTarget\":{\"DNSName\":\"$SECONDARY_TARGET\",\"HostedZoneId\":\"$SECONDARY_TARGET_ZONE\",\"EvaluateTargetHealth\":true}}}
  ]}" >/dev/null 2>&1 && echo "  records deleted" || echo "  records already gone / mismatch"

if [ -n "${HC_ID:-}" ]; then
  aws route53 delete-health-check --health-check-id "$HC_ID" && echo "  health check deleted" || true
fi

echo "Deleting base-path mappings + custom domains ..."
for region in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
  aws apigateway delete-base-path-mapping --domain-name "$DOMAIN" --base-path "(none)" \
    --region "$region" >/dev/null 2>&1 || true
  aws apigateway delete-domain-name --domain-name "$DOMAIN" --region "$region" \
    >/dev/null 2>&1 && echo "  custom domain deleted in $region" || echo "  custom domain gone in $region"
done

echo "Deleting ACM certs ..."
aws acm delete-certificate --certificate-arn "$PRIMARY_CERT" --region "$PRIMARY_REGION" 2>/dev/null \
  && echo "  primary cert deleted" || echo "  primary cert busy/gone (retry after domains fully removed)"
aws acm delete-certificate --certificate-arn "$SECONDARY_CERT" --region "$SECONDARY_REGION" 2>/dev/null \
  && echo "  secondary cert deleted" || echo "  secondary cert busy/gone (retry after domains fully removed)"

echo "Failover teardown complete. (Validation CNAME in the zone can be removed manually if desired.)"
