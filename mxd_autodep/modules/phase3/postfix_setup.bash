#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Postfix Installation Only (Phase 3) with Revert Support ===#
log() { echo -e "\033[0;32m[PHASE 3 POSTFIX_MODULE] $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 3 POSTFIX_MODULE] Error: $*\033[0m" >&2; exit 1; }

CONFIG_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
source <(grep -E '^(MAILDOMAIN|MAILGROUP|SSL_METHOD)=' "$CONFIG_FILE")

CONFIG_DIR="modules/configs/postfix"
TARGET_DIR="/etc/postfix"
MASTER_CF="$TARGET_DIR/master.cf"
MAIN_CF="$TARGET_DIR/main.cf"
INI="/tmp/mxd_autodep/modules/configs/parameters.ini"

mkdir -p "$CONFIG_DIR"

if [[ "${1:-}" == "--revert" ]]; then
  systemctl stop postfix >/dev/null 2>&1 || true
  systemctl disable postfix >/dev/null 2>&1 || true
  apt-get purge -y postfix mailutils libsasl2-modules >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  [[ -d /etc/postfix ]] && rm -rf /etc/postfix
  log "Postfix reverted."
  exit 0
fi

#=== STEP 1: Install Postfix and Dependencies ===#
install_postfix() {
  log "Installing Postfix and dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils libsasl2-modules >/dev/null 2>&1
  log "Postfix installed."
}

#=== STEP 2: Generate main.cf ===#
generate_main_cf() {
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

smtpd_tls_cert_file=/etc/letsencrypt/live/$MAILDOMAIN/fullchain.pem
smtpd_tls_key_file=/etc/letsencrypt/live/$MAILDOMAIN/privkey.pem
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
}

#=== STEP 3: Generate master.cf ===#
generate_master_cf() {
  log "Generating master.cf..."
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
}

#=== STEP 4: Deploy Config Files ===#
deploy_configs() {
  log "Deploying configuration files..."
  cp "$CONFIG_DIR/main.cf" "$TARGET_DIR/main.cf"
  cp "$CONFIG_DIR/master.cf" "$TARGET_DIR/master.cf"
  postconf -e "mydomain = $MAILDOMAIN"
  postconf -e "myorigin = /etc/mailname"
  echo "$MAILDOMAIN" > /etc/mailname
}

#=== STEP 5: Enable and Restart Postfix ===#
enable_and_restart_postfix() {
  log "Restarting and enabling Postfix..."
  systemctl restart postfix
  systemctl enable postfix
}

#=== EXECUTION ===#
install_postfix
generate_main_cf
generate_master_cf
deploy_configs
enable_and_restart_postfix

log "Postfix installation and configuration completed for domain: $MAILDOMAIN"
