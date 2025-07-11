#!/usr/bin/env bash
set -euo pipefail

#=== CONTROLLER SCRIPT ===#
log() { echo -e "\033[0;32m[CONTROLLER] $*\033[0m" >&2; }
warn() { echo -e "\033[0;33m[CONTROLLER] Warning: $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[CONTROLLER] Error: $*\033[0m" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
INI_FILE="$MODULES_DIR/configs/parameters.ini"
CF_CREDS_FILE="/etc/cloudflare.creds"

[[ -d "$MODULES_DIR" ]] || die "Missing modules directory: $MODULES_DIR"
[[ -f "$INI_FILE" ]] || die "Missing required config file: $INI_FILE"
source <(grep -vE '^\s*#' "$INI_FILE" | sed 's/^/export /')

if [[ "$*" == *"--cfreset"* ]]; then
  rm -f "$CF_CREDS_FILE"
  unset CF_API_TOKEN CF_ZONE_ID
  log "Cleared Cloudflare credentials from current environment"
fi

if [[ -f "$CF_CREDS_FILE" ]]; then
  source "$CF_CREDS_FILE"
fi

if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ZONE_ID:-}" ]]; then
  read -rp "Enter your Cloudflare API Token: " CF_API_TOKEN
  read -rp "Enter your Cloudflare Zone ID: " CF_ZONE_ID
  export CF_API_TOKEN CF_ZONE_ID
  echo "export CF_API_TOKEN='$CF_API_TOKEN'" > "$CF_CREDS_FILE"
  echo "export CF_ZONE_ID='$CF_ZONE_ID'" >> "$CF_CREDS_FILE"
  chmod 600 "$CF_CREDS_FILE"
fi

PHASES=(
  "$MODULES_DIR/phase1/ufwsetup.bash"
  "$MODULES_DIR/phase1/hostname.bash"
  "$MODULES_DIR/phase2/mailuser_setup.bash"
  "$MODULES_DIR/phase3/postfix_setup.bash"
  "$MODULES_DIR/phase3/dovecot_setup.bash"
  "$MODULES_DIR/phase3/opendkim_setup.bash"
  "$MODULES_DIR/phase5/cf_dns_reconciler.bash"
  "$MODULES_DIR/phase5/letsencrypt.bash"
  "$MODULES_DIR/phase4/postfix_config.bash"
  "$MODULES_DIR/phase4/dovecot_config.bash"
  "$MODULES_DIR/phase5/system_reboot_check.bash"
)

kill_dpkg_lock_holders() {
  local lockfile="/var/lib/dpkg/lock-frontend"
  if [[ -f "$lockfile" ]]; then
    local pid
    pid=$(lsof -t "$lockfile" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      warn "Killing process $pid holding dpkg lock..."
      kill -9 "$pid" || true
      sleep 1
    fi
  fi
}

resolve_dpkg_interrupt() {
  if fgrep -Rq "dpkg was interrupted" /var/log/apt/ /var/log/dpkg.log 2>/dev/null || [[ -f /var/lib/dpkg/lock-frontend ]]; then
    warn "Detected dpkg interruption. Attempting auto-repair with dpkg --configure -a"
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a || warn "dpkg repair failed"
  fi
}

rollback() {
  local rollback_index="${1:-${#PHASES[@]}}"
  warn "Forcefully initiating rollback from phase $rollback_index back to 1"
  for ((i=rollback_index-1; i>=0; i--)); do
    PHASE_PATH="${PHASES[i]}"
    if [[ "$PHASE_PATH" == *"/ufwsetup.bash" || "$PHASE_PATH" == *"/letsencrypt.bash" ]]; then
      warn "Skipping rollback for: $PHASE_PATH"
      continue
    fi
    if [[ -x "$PHASE_PATH" ]]; then
      warn "Rolling back: $PHASE_PATH"
      kill_dpkg_lock_holders
      resolve_dpkg_interrupt
      "$PHASE_PATH" --revert >/dev/null 2>&1 || true
    fi
  done
  log "Rollback completed."
  exit 0
}

if [[ "$*" == *"--rollback"* ]]; then
  rollback "${#PHASES[@]}"
fi

CURRENT_PHASE_INDEX=-1
trap '[[ $CURRENT_PHASE_INDEX -ge 0 ]] && rollback "$CURRENT_PHASE_INDEX"' INT

for i in "${!PHASES[@]}"; do
  PHASE="${PHASES[$i]}"
  CURRENT_PHASE_INDEX="$i"

  if [[ "$PHASE" == *"/ufwsetup.bash" ]] && ufw status | grep -q "Status: active"; then
    log "UFW already enabled. Skipping: $PHASE"
    continue
  fi

  if [[ "$PHASE" == *"/letsencrypt.bash" ]]; then
    DOMAIN_LINE=$(grep -E '^DOMAIN=' "$INI_FILE" || true)
    DOMAIN="${DOMAIN_LINE#DOMAIN=}"
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
      log "SSL certificate already exists for $DOMAIN. Skipping: $PHASE"
      continue
    fi
    if grep -q '^DEBUG_CERTS=yes' "$INI_FILE"; then
      log "DEBUG_CERTS requested — generating self-signed SSL cert..."
      "$PHASE" --selfsigned || rollback "$i"
      continue
    else
      log "DEBUG_CERTS not enabled — proceeding with Certbot issuance..."
      "$PHASE" --certbot || rollback "$i"
      continue
    fi
  fi

  log "Executing: $PHASE"
  if ! "$PHASE"; then
    rollback "$i"
  fi
done

VALIDATOR="$MODULES_DIR/phase6/validate_config.bash"
if [[ -x "$VALIDATOR" ]]; then
  log "Executing: $VALIDATOR"
  DEBUG_CERTS_LINE=$(grep -E '^DEBUG_CERTS=' "$INI_FILE" || true)
  if [[ "$DEBUG_CERTS_LINE" == "DEBUG_CERTS=yes" ]]; then
    export DEBUG_CERTS="yes"
  else
    export DEBUG_CERTS="no"
  fi
  "$VALIDATOR" || log "Validator script completed with errors"
fi

log "All requested modules have been invoked. Review output for any issues"
