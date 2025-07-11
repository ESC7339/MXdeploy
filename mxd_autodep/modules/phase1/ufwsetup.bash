#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: UFW Firewall Setup ===#
log() { echo -e "\033[0;32m[PHASE 1 UFW_MODULE] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 1 UFW_MODULE] Error: $*\033[0m" >&2; exit 1; }

INI_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"

get_ini_value() {
  local key="$1"
  grep -E "^${key}=" "$INI_FILE" | cut -d'=' -f2- | tr -d '[:space:]'
}

SSH_IP="$(get_ini_value SSH_IP)"
[[ "$SSH_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IP format in INI: $SSH_IP"

log "Installing ufw..."
apt-get update -qq
apt-get install -y ufw >/dev/null

log "Resetting and applying firewall rules..."
ufw --force reset
ufw default deny incoming
ufw allow from "$SSH_IP" to any port 22 proto tcp
ufw allow 25,465,587,110,995,143,993,80,443/tcp
ufw --force enable

log "UFW configured. SSH allowed from $SSH_IP"
