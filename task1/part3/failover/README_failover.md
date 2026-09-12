# Part 3 — Route 53 Failover on `aws.lijeron.net` (full working build)

End-to-end active/passive failover between the two regional endpoints:

- **PRIMARY**  — us-west-2  (Part 2 CLI API, id `mtipvxmr4k`)
- **SECONDARY** — us-east-1 (CFN stack API, id `95wrutetrf`)

Client hits a single hostname: **`https://aws.lijeron.net/generate`**. Route 53
health-checks the primary; if it goes unhealthy, traffic fails over to us-east-1.

---

## Why this is more than the assignment shows (blog note)

The assignment aliases `aws.lijeron.net` straight at the `execute-api` URLs. That
does **not** work:

1. **Host-header rejection** — the raw `execute-api` endpoint validates the Host
   header against its api-id. A request for `aws.lijeron.net` sends
   `Host: aws.lijeron.net` → **403**. You must put an **API Gateway custom domain**
   (`aws.lijeron.net`) in front of each regional API, which needs a **regional ACM
   certificate** for that name in **each** region.
2. **Health check needs a target** — Route 53 health checks do `GET`/`HEAD`; a
   body-less `POST /generate` yields an empty prompt → Bedrock error → the check
   flaps. So we add a cheap **`GET /health`** (MOCK, returns `{"status":"ok"}`) in
   each region and health-check that.

---

## Run order (there are waits — do them in sequence)

| Step | Script | What it does | Wait? |
|------|--------|--------------|-------|
| 1 | `r53_01_health.sh` | Adds `GET /health` (MOCK 200) to the **us-west-2** API and redeploys `prod`. (us-east-1 gets `/health` from the updated `template.yaml` — redeploy `deploy_crossregion.sh`.) | no |
| 2 | `r53_02_certs.sh` | Requests **regional ACM certs** for `aws.lijeron.net` in **both** regions; auto-creates the DNS validation record(s) in the `aws.lijeron.net` zone; waits for ISSUED. | ~2–10 min (ACM) |
| 3 | `r53_03_custom_domains.sh` | Creates the **regional API Gateway custom domain** `aws.lijeron.net` in each region + base-path mapping to `prod`; writes the two regional target hostnames to `failover_resources.env`. | ~a few min |
| 4 | `r53_04_failover_records.sh` | Creates a **health check** on the primary `/health` and the **PRIMARY/SECONDARY failover alias records** in the zone. | ~1 min DNS |
| 5 | test | `curl https://aws.lijeron.net/generate ...`; then break primary `/health` and watch it fail over. | — |

Teardown: `r53_teardown.sh` (removes records, health check, custom domains, certs).

---

## Prerequisites
- `aws.lijeron.net` delegation is live (done — verified via the parent zone).
- Bedrock `us.amazon.nova-lite-v1:0` enabled in **both** us-west-2 and us-east-1 (done).
- `jq` installed (used to parse ACM/records JSON).

## Cost note (tag everything `auto-delete=true`)
- ACM public certs: **free**.
- Route 53 **health checks: ~$0.50/mo each** — the only meaningful idle cost here.
- Custom domains: no hourly charge.
- Delete via `r53_teardown.sh` when done.
