#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Hostname Configuration with Revert Support (Phase 1) ===#
log() { echo -e "\033[0;32m[PHASE 1 HOSTNAME_MODULE] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 1 HOSTNAME_MODULE] Error: $*\033[0m" >&2; exit 1; }

INI_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
BACKUP_DIR="/var/backups/mxd_autodep/hostname"
HOSTS_BACKUP="$BACKUP_DIR/hosts.bak"
HOSTNAME_BACKUP="$BACKUP_DIR/hostname.bak"

get_ini_value() {
  local key="$1"
  grep -E "^${key}=" "$INI_FILE" | cut -d'=' -f2- | tr -d '[:space:]'
}

if [[ "${1:-}" == "--revert" ]]; then
  if [[ -f "$HOSTS_BACKUP" && -f "$HOSTNAME_BACKUP" ]]; then
    log "Restoring original hostname and /etc/hosts..."
    cp "$HOSTS_BACKUP" /etc/hosts
    ORIGINAL_HOSTNAME=$(<"$HOSTNAME_BACKUP")
    hostnamectl set-hostname "$ORIGINAL_HOSTNAME"
    log "Revert complete. Hostname restored to $ORIGINAL_HOSTNAME"
  else
    die "No backups found to revert hostname configuration."
  fi
  exit 0
fi

FQDN="$(get_ini_value FQDN)"
[[ "$FQDN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid FQDN in INI: $FQDN"

mkdir -p "$BACKUP_DIR"

log "Backing up current hostname and /etc/hosts..."
hostnamectl --static status | awk '{print $NF}' > "$HOSTNAME_BACKUP"
cp /etc/hosts "$HOSTS_BACKUP"

SHORT_HOST="${FQDN%%.*}"

log "Setting hostname to $SHORT_HOST and FQDN to $FQDN"
hostnamectl set-hostname "$FQDN"

log "Updating /etc/hosts..."
if ! grep -q "$FQDN" /etc/hosts; then
  echo "127.0.1.1 $FQDN $SHORT_HOST" >> /etc/hosts
fi

log "Hostname set. Current hostname: $(hostname)"
