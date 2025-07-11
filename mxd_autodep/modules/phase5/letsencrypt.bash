#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Let's Encrypt SSL Setup (Phase 5) ===#
log() { echo -e "\033[0;32m[PHASE 5 LETSENCRYPT_MODULE] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 5 LETSENCRYPT_MODULE] Error: $*\033[0m" >&2; exit 1; }

REVERT_FLAG="${1:-}"
CERTBOT_INSTALLED_MARK="/etc/letsencrypt/.mxd_certbot"
INI="/tmp/mxd_autodep/modules/configs/parameters.ini"

safe_dpkg() {
  if fgrep -Rq "dpkg was interrupted" /var/log/apt/ /var/log/dpkg.log 2>/dev/null || [[ -f /var/lib/dpkg/lock-frontend ]]; then
    log "dpkg is in a broken state or lock held, skipping apt operations"
    return 1
  fi
  return 0
}

if [[ "$REVERT_FLAG" == "--revert" ]]; then
  log "Reverting Let's Encrypt SSL setup..."

  if [[ -f "$CERTBOT_INSTALLED_MARK" ]]; then
    if safe_dpkg; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y certbot >/dev/null 2>&1 || log "Certbot purge failed, skipping"
    else
      log "Skipping Certbot purge due to dpkg lock or corruption"
    fi
    rm -f "$CERTBOT_INSTALLED_MARK"
    log "Certbot marked as removed"
  fi

  log "Removing existing SSL certs..."
  rm -rf /etc/letsencrypt
  log "Let's Encrypt configuration reverted"
  exit 0
fi

DOMAIN="$(grep -E '^DOMAIN=' "$INI" | cut -d= -f2 | tr -d '[:space:]')"
DEBUG_CERTS="$(grep -E '^DEBUG_CERTS=' "$INI" | cut -d= -f2 | tr -d '[:space:]')"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
FULLCHAIN="$CERT_DIR/fullchain.pem"
PRIVKEY="$CERT_DIR/privkey.pem"

if [[ "${DEBUG_CERTS,,}" == "yes" ]]; then
  if [[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]]; then
    log "DEBUG_CERTS enabled — cert already exists, skipping generation."
    exit 0
  fi

  log "DEBUG_CERTS enabled — generating self-signed cert for $DOMAIN"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$PRIVKEY" -out "$FULLCHAIN" \
    -subj "/CN=$DOMAIN" >/dev/null 2>&1
  log "Self-signed certificate created:"
  log "Full Chain: $FULLCHAIN"
  log "Private Key: $PRIVKEY"
  exit 0
fi

if [[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]]; then
  log "Certificate already exists for $DOMAIN, skipping issuance."
  exit 0
fi

rm -f "/etc/letsencrypt/renewal/$DOMAIN.conf"

log "Installing Certbot..."
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null
mkdir -p "$(dirname "$CERTBOT_INSTALLED_MARK")"
touch "$CERTBOT_INSTALLED_MARK"

log "Obtaining SSL cert via HTTP challenge..."
certbot certonly --standalone \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  -d "$DOMAIN" || die "Certificate issuance failed"

[[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]] || die "Certificate files not found in $CERT_DIR"

log "Certificates issued for $DOMAIN:"
log "Full Chain: $FULLCHAIN"
log "Private Key: $PRIVKEY"
