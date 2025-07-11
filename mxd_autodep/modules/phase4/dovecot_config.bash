#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Dovecot Config Generator with Headless Support ===#
log() { echo -e "\033[0;32m[PHASE 4 DOVECOT_CONFIG] $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 4 DOVECOT_CONFIG] Error: $*\033[0m" >&2; exit 1; }

CONFIG_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
source <(grep -E '^(MAILDOMAIN|MAILDIR|ENABLE_SSL|USE_SYSTEM_AUTH|SSL_METHOD)=' "$CONFIG_FILE")

CONFIG_DIR="modules/configs/dovecot"
TARGET_DIR="/etc/dovecot"

if [[ "${1:-}" == "--revert" ]]; then
  log "Reverting Dovecot configuration..."
  systemctl is-active --quiet dovecot && systemctl stop dovecot >/dev/null 2>&1 && log "Dovecot service stopped."
  systemctl is-enabled --quiet dovecot && systemctl disable dovecot >/dev/null 2>&1 && log "Dovecot service disabled."
  [[ -d "$TARGET_DIR" ]] && rm -rf "$TARGET_DIR"/dovecot.conf "$TARGET_DIR"/conf.d/*
  log "Revert complete."
  exit 0
fi

MAILDOMAIN="${MAILDOMAIN:?MAILDOMAIN not set}"
MAILDIR="${MAILDIR:-/var/mail}"
ENABLE_SSL="${ENABLE_SSL:-yes}"
USE_SYSTEM_AUTH="${USE_SYSTEM_AUTH:-yes}"
SSL_METHOD="${SSL_METHOD:-certbot}"  # Add SSL method check
AUTH_METHOD="plain login"

[[ "$MAILDOMAIN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain: $MAILDOMAIN"
[[ "$ENABLE_SSL" =~ ^(yes|no)$ ]] || die "ENABLE_SSL must be yes or no"
[[ "$USE_SYSTEM_AUTH" =~ ^(yes|no)$ ]] || die "USE_SYSTEM_AUTH must be yes or no"

if [[ "$ENABLE_SSL" == "yes" ]]; then
  if [[ "$SSL_METHOD" == "certbot" ]]; then
    CERT_PATH="$(find /etc/letsencrypt/live/ -type f -name fullchain.pem 2>/dev/null | grep "/$MAILDOMAIN/" || true)"
    KEY_PATH="$(find /etc/letsencrypt/live/ -type f -name privkey.pem 2>/dev/null | grep "/$MAILDOMAIN/" || true)"
    [[ -z "$CERT_PATH" ]] && CERT_PATH="$(find /etc/letsencrypt/live/ -type f -name fullchain.pem 2>/dev/null | head -n 1)"
    [[ -z "$KEY_PATH" ]] && KEY_PATH="$(find /etc/letsencrypt/live/ -type f -name privkey.pem 2>/dev/null | head -n 1)"
    [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]] && die "SSL enabled but certificate files not found under /etc/letsencrypt/live/"
  else
    CERT_PATH="/etc/ssl/certs/selfsigned.pem"
    KEY_PATH="/etc/ssl/private/selfsigned.key"
    [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || die "Self-signed SSL certificate or key not found."
  fi
fi

log "Generating config files in $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR/conf.d"

cat > "$CONFIG_DIR/dovecot.conf" <<EOF
!include_try /usr/share/dovecot/protocols.d/*.protocol
dict {
}
!include conf.d/*.conf
!include_try local.conf
EOF

cat > "$CONFIG_DIR/conf.d/10-mail.conf" <<EOF
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
}
EOF

cat > "$CONFIG_DIR/conf.d/10-auth.conf" <<EOF
disable_plaintext_auth = no
auth_mechanisms = $AUTH_METHOD
EOF

[[ "$USE_SYSTEM_AUTH" == "yes" ]] && echo "!include auth-system.conf.ext" >> "$CONFIG_DIR/conf.d/10-auth.conf"

cat > "$CONFIG_DIR/conf.d/10-master.conf" <<EOF
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
  }
}
EOF

cat > "$CONFIG_DIR/conf.d/10-ssl.conf" <<EOF
ssl = ${ENABLE_SSL}
ssl_cert = <${CERT_PATH}
ssl_key = <${KEY_PATH}
EOF

log "Templates generated. Installing config files to $TARGET_DIR..."

for f in "$CONFIG_DIR"/dovecot.conf "$CONFIG_DIR"/conf.d/*.conf; do
  dest="$TARGET_DIR/${f#$CONFIG_DIR/}"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done

log "Validating Dovecot config..."
dovecot -n >/dev/null || die "Configuration invalid"

log "Enabling and restarting Dovecot..."
if ! systemctl enable dovecot >/dev/null 2>&1 || ! systemctl restart dovecot >/dev/null 2>&1; then
  log "Dovecot failed to start. Fetching recent logs..."
  journalctl -xeu dovecot.service --no-pager -n 50 | sed 's/^/[DOVECOT LOG] /'
  die "Failed to start Dovecot"
fi

log "Dovecot is active and ready."
