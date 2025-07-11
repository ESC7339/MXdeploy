#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Mail User & Group Setup with Revert Support ===#
log() { echo -e "\033[0;32m[PHASE 2 MAILUSER_MODULE] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 2 MAILUSER_MODULE] Error: $*\033[0m" >&2; exit 1; }

INI_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"

get_ini_value() {
  local key="$1"
  grep -E "^${key}=" "$INI_FILE" | cut -d'=' -f2- | tr -d '[:space:]'
}

MAIL_GROUP="$(get_ini_value MAIL_GROUP)"
MAIL_USER="$(get_ini_value MAIL_USER)"
MAIL_HOME="$(get_ini_value MAIL_HOME)"
MAIL_FULLNAME="$(get_ini_value MAIL_FULLNAME)"
MAIL_EMAIL="$(get_ini_value MAIL_EMAIL)"

create_maildir() {
  local user="$1"
  local homedir
  homedir=$(getent passwd "$user" | cut -d: -f6)
  local mdir="$homedir/Maildir"

  if [[ ! -d "$mdir" ]]; then
    log "Initializing Maildir for user '$user' at $mdir..."
    mkdir -p "$mdir"/{new,cur,tmp}  # Create Maildir subdirectories
    chown -R "$user:$MAIL_GROUP" "$mdir"  # Set proper ownership
    chmod -R 700 "$mdir"  # Ensure proper permissions
    log "Maildir created for user '$user'."
  else
    log "Maildir already exists for user '$user'."
  fi
}

if [[ "${1:-}" == "--revert" ]]; then
  log "Reverting mail user and group setup..."

  if id "$MAIL_USER" &>/dev/null; then
    userdel -r "$MAIL_USER" && log "User '$MAIL_USER' removed"
  else
    log "User '$MAIL_USER' does not exist"
  fi

  if getent group "$MAIL_GROUP" > /dev/null; then
    groupdel "$MAIL_GROUP" && log "Group '$MAIL_GROUP' removed"
  else
    log "Group '$MAIL_GROUP' does not exist"
  fi

  [[ -d "$MAIL_HOME" ]] && rm -rf "$MAIL_HOME" && log "Home directory $MAIL_HOME deleted"

  exit 0
fi

if ! getent group "$MAIL_GROUP" > /dev/null; then
  groupadd --system "$MAIL_GROUP"
  log "Group '$MAIL_GROUP' created"
else
  log "Group '$MAIL_GROUP' already exists"
fi

if ! id "$MAIL_USER" &>/dev/null; then
  useradd --system --shell /usr/sbin/nologin --gid "$MAIL_GROUP" --home "$MAIL_HOME" -c "$MAIL_FULLNAME <$MAIL_EMAIL>" "$MAIL_USER"
  mkdir -p "$MAIL_HOME"
  chown "$MAIL_USER:$MAIL_GROUP" "$MAIL_HOME"
  chmod 750 "$MAIL_HOME"
  log "User '$MAIL_USER' created with home directory at $MAIL_HOME and sender '$MAIL_FULLNAME <$MAIL_EMAIL>'"
else
  log "User '$MAIL_USER' already exists"
fi

# Create Maildir for the user
create_maildir "$MAIL_USER"

# Create Maildir for test users mxdtest1 and mxdtest2
create_maildir "mxdtest1"
create_maildir "mxdtest2"
