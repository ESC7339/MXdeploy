#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: OpenDKIM Installation + Key Generation + Config Deployment (Phase 3) ===#
log() { echo -e "\033[0;32m[PHASE 3 OPENDKIM_SETUP] $*\033[0m" >&2; }
die() { echo -e "\033[0;31m[PHASE 3 OPENDKIM_SETUP] Error: $*\033[0m" >&2; exit 1; }

CONFIG_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
source <(grep -E '^(MAILDOMAIN|DKIM_SELECTOR)=' "$CONFIG_FILE")

CONFIG_DIR="modules/configs/opendkim"
KEYS_DIR="$CONFIG_DIR/keys"
INSTALL_DIR="/etc/opendkim"

if [[ "${1:-}" == "--revert" ]]; then
  log "Reverting OpenDKIM..."
  systemctl is-active --quiet opendkim && systemctl stop opendkim && log "Service stopped."
  systemctl is-enabled --quiet opendkim && systemctl disable opendkim && log "Service disabled."
  apt-get purge -y opendkim opendkim-tools >/dev/null || true
  apt-get autoremove -y >/dev/null || true
  rm -rf "$INSTALL_DIR"
  rm -rf "$CONFIG_DIR"
  log "OpenDKIM installation and configs fully reverted."
  exit 0
fi

#=== STEP 1: Install Packages ===#
log "Installing OpenDKIM and tools..."
DEBIAN_FRONTEND=noninteractive apt-get install -y opendkim opendkim-tools >/dev/null

#=== STEP 2: Validate Parameters ===#
DOMAIN="${MAILDOMAIN:?MAILDOMAIN not set in parameters.ini}"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain"

SELECTOR="${DKIM_SELECTOR:-default}"

KEYDIR="$KEYS_DIR/$DOMAIN"
mkdir -p "$KEYDIR"

#=== STEP 3: Generate Keypair ===#
log "Generating DKIM keypair for $DOMAIN with selector '$SELECTOR'..."
opendkim-genkey -D "$KEYDIR" -d "$DOMAIN" -s "$SELECTOR"
[[ -f "$KEYDIR/$SELECTOR.private" ]] || die "Key generation failed"

mv "$KEYDIR/$SELECTOR.private" "$KEYDIR/$SELECTOR.key"
[[ -f "$KEYDIR/$SELECTOR.txt" ]] || mv "$KEYDIR/$SELECTOR.txt" "$KEYDIR/${SELECTOR}.txt"

#=== STEP 4: Debug Key ===#
log "Private key contents:"
head -n1 "$KEYDIR/${SELECTOR}.key"

#=== STEP 5: Create Configs ===#
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/opendkim.conf" <<EOF
Syslog                  yes
UMask                   002
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
AutoRestart             yes
AutoRestartRate         10/1h
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256
UserID                  opendkim
Socket                  inet:12301@localhost

KeyTable                $INSTALL_DIR/KeyTable
SigningTable            $INSTALL_DIR/SigningTable
ExternalIgnoreList      refile:$INSTALL_DIR/TrustedHosts
InternalHosts           refile:$INSTALL_DIR/TrustedHosts
EOF

cat > "$CONFIG_DIR/KeyTable" <<EOF
$SELECTOR._domainkey.$DOMAIN $DOMAIN:$SELECTOR:$INSTALL_DIR/keys/$DOMAIN/$SELECTOR.key
EOF

cat > "$CONFIG_DIR/SigningTable" <<EOF
*@${DOMAIN} $SELECTOR._domainkey.${DOMAIN}
EOF

cat > "$CONFIG_DIR/TrustedHosts" <<EOF
127.0.0.1
localhost
*.${DOMAIN}
EOF

#=== STEP 6: Deploy Configs ===#
log "Installing configs and keys to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/keys/$DOMAIN"
cp "$KEYDIR/${SELECTOR}.key" "$INSTALL_DIR/keys/$DOMAIN/"
cp "$CONFIG_DIR"/opendkim.conf "$INSTALL_DIR/"
cp "$CONFIG_DIR"/KeyTable "$INSTALL_DIR/"
cp "$CONFIG_DIR"/SigningTable "$INSTALL_DIR/"
cp "$CONFIG_DIR"/TrustedHosts "$INSTALL_DIR/"
chown -R opendkim:opendkim "$INSTALL_DIR"
chmod 600 "$INSTALL_DIR/keys/$DOMAIN/${SELECTOR}.key"

#=== STEP 7: Start Service ===#
log "Restarting and enabling OpenDKIM..."
systemctl enable opendkim
systemctl restart opendkim

log "OpenDKIM is active. Publish the following DNS TXT record:"
cat "$KEYDIR/${SELECTOR}.txt"
