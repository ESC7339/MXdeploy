#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: System Reboot Eligibility Check (with --revert) ===#
log() { echo -e "\033[0;32m[PHASE 5 REBOOT_CHECK] $*\033[0m"; }
warn() { echo -e "\033[0;33m[PHASE 5 REBOOT_CHECK] Warning: $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 5 REBOOT_CHECK] Error: $*\033[0m" >&2; exit 1; }

INI="/tmp/mxd_autodep/modules/configs/parameters.ini"

if [[ "${1:-}" == "--revert" ]]; then
  log "Reboot eligibility check is informational only. Nothing to revert."
  exit 0
fi

source <(grep -E '^REBOOT_NOW=' "$INI")

log "Checking for system reboot requirements..."

if [[ -f /var/run/reboot-required ]]; then
  warn "System requires a reboot: /var/run/reboot-required exists."
else
  log "No reboot requirement file found."
fi

log "Checking for outdated packages..."

UPGRADES=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." || true)

if [[ -n "$UPGRADES" ]]; then
  warn "The following packages can be upgraded:"
  echo "$UPGRADES"
else
  log "No package upgrades available."
fi

CURRENT_KERNEL=$(uname -r)
LATEST_KERNEL=$(dpkg --list | grep linux-image | grep -vE "dbg|extra" | awk '{print $2}' | sort -V | tail -n1)

if [[ "$LATEST_KERNEL" != *"$CURRENT_KERNEL"* ]]; then
  warn "Newer kernel available: $LATEST_KERNEL (running: $CURRENT_KERNEL)"
else
  log "Kernel is up to date."
fi

if [[ "$REBOOT_NOW" == "yes" ]]; then
  log "Rebooting..."
  reboot
else
  log "Reboot postponed. You may run 'reboot' manually when ready."
fi
