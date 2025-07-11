#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Dovecot Installation + Local User Setup (Phase 3) with Revert Support ===#
log() { echo -e "\033[0;32m[PHASE 3 DOVECOT_MODULE] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 3 DOVECOT_MODULE] Error: $*\033[0m" >&2; exit 1; }

CONFIG_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
MAILDIR=$(grep -E '^MAILDIR=' "$CONFIG_FILE" | cut -d= -f2-) || MAILDIR="/var/mail"
MAILGROUP=$(grep -E '^MAIL_GROUP=' "$CONFIG_FILE" | cut -d= -f2-) || MAILGROUP="mail"

if [[ "${1:-}" == "--revert" ]]; then
  systemctl is-active --quiet dovecot && systemctl stop dovecot >/dev/null 2>&1
  systemctl is-enabled --quiet dovecot && systemctl disable dovecot >/dev/null 2>&1

  apt-get purge -y dovecot-core dovecot-imapd dovecot-pop3d >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  if [[ -d /etc/dovecot ]]; then
    rm -rf /etc/dovecot
    log "/etc/dovecot removed."
  fi

  log "Dovecot reverted."
  exit 0
fi

install_dovecot() {
  log "Installing Dovecot core and protocols..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d >/dev/null 2>&1
  systemctl daemon-reexec >/dev/null 2>&1 || true
  log "Dovecot installed. Configuration will be applied in phase 4."
}

create_maildir() {
  local user="$1"
  local homedir
  homedir=$(getent passwd "$user" | cut -d: -f6)
  local mdir="$homedir/Maildir"

  if [[ ! -d "$mdir" ]]; then
    log "Initializing Maildir at $mdir..."
    mkdir -p "$mdir"/{cur,new,tmp}
    chown -R "$user:$MAILGROUP" "$mdir"
    chmod -R 700 "$mdir"
    log "Maildir created and secured."
  else
    log "Maildir already exists for $user at $mdir."
  fi
}

prompt_user_account() {
  read -rp "Enter new mail user name: " NEWUSER
  id "$NEWUSER" &>/dev/null && { log "User $NEWUSER already exists."; create_maildir "$NEWUSER"; return; }

  read -rsp "Enter password for $NEWUSER: " PASSWORD
  echo
  useradd -m -s /usr/sbin/nologin "$NEWUSER"
  echo "$NEWUSER:$PASSWORD" | chpasswd
  log "User $NEWUSER created with local mailbox."

  create_maildir "$NEWUSER"
}

generate_dovecot_configs() {
  log "Generating Dovecot configuration files..."

  # Dovecot main.conf generation
  cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
}
EOF

  # Dovecot auth.conf generation
  cat > /etc/dovecot/conf.d/10-auth.conf <<EOF
disable_plaintext_auth = no
auth_mechanisms = plain login
EOF

  # Dovecot master.conf generation
  cat > /etc/dovecot/conf.d/10-master.conf <<EOF
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

  # Dovecot ssl.conf generation
  cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = yes
ssl_cert = </etc/letsencrypt/live/${MAILDOMAIN}/fullchain.pem
ssl_key = </etc/letsencrypt/live/${MAILDOMAIN}/privkey.pem
EOF

  log "Dovecot configuration files generated."
}

#=== EXECUTION ===#
install_dovecot
generate_dovecot_configs
prompt_user_account
