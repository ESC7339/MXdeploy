#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Postfix Configuration Deployment (Phase 4) ===#
log() { echo -e "\033[0;32m[PHASE 4 POSTFIX_CONFIG] $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 4 POSTFIX_CONFIG] Error: $*\033[0m" >&2; exit 1; }

CONFIG_DIR="/tmp/mxd_autodep/modules/configs/postfix"
TARGET_DIR="/etc/postfix"
MASTER_CF="$TARGET_DIR/master.cf"
MAIN_CF="$TARGET_DIR/main.cf"
INI="/tmp/mxd_autodep/modules/configs/parameters.ini"

mkdir -p "$CONFIG_DIR"

source <(grep -E '^(MAILDOMAIN|MAILDIR|MAIL_USER|MAIL_HOME|MAIL_GROUP|MAIL_EMAIL|MAIL_IP|DKIM_PUB|MX_PRIO|SSL_METHOD)=' "$INI")

[[ -n "${MAILDOMAIN:-}" ]] || die "MAILDOMAIN not defined"
[[ -n "${MAILDIR:-}" ]] || die "MAILDIR not defined"

#=== STEP 1: Install Postfix if missing ===#
log "Installing Postfix and dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils opendkim opendkim-tools >/dev/null

#=== STEP 2: Dynamic SSL Configuration ===#
SSL_METHOD="${SSL_METHOD:-certbot}"

if [[ "$SSL_METHOD" == "certbot" ]]; then
  log "Using Certbot SSL certificates."
  CERT_PATH="/etc/letsencrypt/live/$MAILDOMAIN/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/$MAILDOMAIN/privkey.pem"
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    die "Certbot SSL certificate or key not found for $MAILDOMAIN."
  fi
else
  log "Using self-signed SSL certificates."
  CERT_PATH="/etc/ssl/certs/selfsigned.pem"
  KEY_PATH="/etc/ssl/private/selfsigned.key"
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    die "Self-signed SSL certificate or key not found."
  fi
fi

#=== STEP 3: Create Postfix main.cf ===#
log "Generating main.cf..."
cat > "$CONFIG_DIR/main.cf" <<EOF
myhostname = mail.$MAILDOMAIN
myorigin = /etc/mailname
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost =
mynetworks = 127.0.0.0/8
inet_interfaces = all
inet_protocols = ipv4
home_mailbox = Maildir/
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

smtpd_tls_cert_file=$CERT_PATH
smtpd_tls_key_file=$KEY_PATH
smtpd_use_tls=yes
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_security_options = noanonymous
smtpd_recipient_restrictions = permit_sasl_authenticated, reject_unauth_destination

milter_default_action = accept
milter_protocol = 2
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891

mailbox_size_limit = 0
recipient_delimiter = +
EOF

#=== STEP 4: Create Postfix master.cf ===#
log "Generating master.cf..."
cp "$MASTER_CF" "$CONFIG_DIR/master.cf.bak" || true

cat > "$CONFIG_DIR/master.cf" <<EOF
smtp      inet  n       -       y       -       -       smtpd
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_tls_auth_only=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
  -o syslog_name=postfix/\$service_name
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
EOF

#=== STEP 5: Deploy Configs and Reload ===#
log "Deploying configuration..."
cp "$CONFIG_DIR/main.cf" "$MAIN_CF"
cp "$CONFIG_DIR/master.cf" "$MASTER_CF"
postconf -e "mydomain = $MAILDOMAIN"
postconf -e "myorigin = /etc/mailname"
echo "$MAILDOMAIN" > /etc/mailname

log "Restarting and enabling Postfix..."
systemctl restart postfix
systemctl enable postfix

log "Postfix configuration applied for domain: $MAILDOMAIN"
