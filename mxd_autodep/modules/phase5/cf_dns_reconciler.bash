#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Cloudflare DNS Reconciler with Full Reset ===#
log() { echo -e "\033[0;32m[PHASE 5 CF_DNS_RECONCILER] $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 5 CF_DNS_RECONCILER] Error: $*\033[0m" >&2; exit 1; }

INI="/tmp/mxd_autodep/modules/configs/parameters.ini"
TMP_JSON="/tmp/cf_dns_records.json"
CF_CREDS_FILE="/etc/cloudflare.creds"

source <(grep -E '^(DOMAIN|MAIL_IP|DKIM_PUB|MX_PRIO)=' "$INI")

[[ "$DOMAIN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain"
MAIL_HOSTNAME="mail.$DOMAIN"
DKIM_SELECTOR="default"

if [[ -f "$CF_CREDS_FILE" ]]; then
  source "$CF_CREDS_FILE"
fi

[[ -n "${CF_API_TOKEN:-}" ]] || die "CF_API_TOKEN must be exported in the environment or defined in $CF_CREDS_FILE"
[[ -n "${CF_ZONE_ID:-}" ]] || die "CF_ZONE_ID must be exported in the environment or defined in $CF_CREDS_FILE"

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq -qq

curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" > "$TMP_JSON"

[[ "$(jq -r .success "$TMP_JSON")" == "true" ]] || { cat "$TMP_JSON"; die "API call failed"; }

log "Fetched current DNS state. Purging old records..."

jq -r '.result[] | .id' "$TMP_JSON" | while read -r rid; do
  curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$rid" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" > /dev/null
  log "Deleted record ID: $rid"
done

log "Old records purged. Creating new DNS entries..."

declare -A RECORD_TYPES
declare -A RECORD_VALUES
declare -A RECORD_EXTRAS

RECORD_TYPES["$MAIL_HOSTNAME"]="A"
RECORD_VALUES["$MAIL_HOSTNAME"]="$MAIL_IP"

RECORD_TYPES["$DOMAIN"]="MX"
RECORD_VALUES["$DOMAIN"]="$MAIL_HOSTNAME"
RECORD_EXTRAS["$DOMAIN"]='"priority": '"${MX_PRIO:-10}"

RECORD_TYPES["txtspf.$DOMAIN"]="TXT"
RECORD_VALUES["txtspf.$DOMAIN"]="v=spf1 mx a:$MAIL_HOSTNAME ~all"

RECORD_TYPES["$DKIM_SELECTOR._domainkey.$DOMAIN"]="TXT"
RECORD_VALUES["$DKIM_SELECTOR._domainkey.$DOMAIN"]="v=DKIM1; k=rsa; p=$DKIM_PUB"

RECORD_TYPES["_dmarc.$DOMAIN"]="TXT"
RECORD_VALUES["_dmarc.$DOMAIN"]="v=DMARC1; p=none; rua=mailto:dmarc@$DOMAIN"

for NAME in "${!RECORD_TYPES[@]}"; do
  TYPE="${RECORD_TYPES[$NAME]}"
  CONTENT="${RECORD_VALUES[$NAME]}"
  EXTRA="${RECORD_EXTRAS[$NAME]:-}"

  PAYLOAD=$(jq -n --arg type "$TYPE" --arg name "$NAME" --arg content "$CONTENT" \
    --argjson extra "{${EXTRA:-}}" '
    {
      type: $type,
      name: $name,
      content: $content,
      ttl: 3600,
      proxied: false
    } + $extra')

  log "Creating $TYPE $NAME..."
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD" | jq .
done

log "DNS reconciliation complete."
