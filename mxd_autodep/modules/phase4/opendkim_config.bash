#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: OpenDKIM Configuration Deployment (Phase 4) ===#
log() { echo -e "\033[0;32m[PHASE 4 OPENDKIM_CONFIG] $*\033[0m"; }
die() { echo -e "\033[0;31m[PHASE 4 OPENDKIM_CONFIG] Error: $*\033[0m" >&2; exit 1; }

CONFIG_FILE="/tmp/mxd_autodep/modules/configs/parameters.ini"
source <(grep -E '^(MAILDOMAIN|DKIM_SELECTOR|SSL_METHOD)=' "$CONFIG_FILE")

CONFIG_DIR="modules/configs/opendkim"
INSTALL_DIR="/etc/opendkim"

# Ensure the existence of the configuration directory
mkdir -p "$CONFIG_DIR"

# Validate DKIM selector and domain
DOMAIN="${MAILDOMAIN:?MAILDOMAIN not set in parameters.ini}"
SELECTOR="${DKIM_SELECTOR:-default}"

# Define paths for DKIM configuration
KEY_DIR="$CONFIG_DIR/keys/$DOMAIN"
mkdir -p "$KEY_DIR"

# Step 1: Validate parameters
log "Validating parameters..."
[[ "$DOMAIN" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]] || die "Invalid domain format"

# Step 2: Create DKIM key if it doesn't exist
if [[ ! -f "$KEY_DIR/$SELECTOR.key" ]]; then
  log "Generating DKIM keypair for $DOMAIN with selector '$SELECTOR'..."
  opendkim-genkey -D "$KEY_DIR" -d "$DOMAIN" -s "$SELECTOR" || die "DKIM key generation failed"
  mv "$KEY_DIR/$SELECTOR.private" "$KEY_DIR/$SELECTOR.key"
  [[ -f "$KEY_DIR/$SELECTOR.key" ]] || die "Key file $KEY_DIR/$SELECTOR.key not found after generation"
  log "DKIM keypair generated for $DOMAIN with selector '$SELECTOR'"
else
  log "DKIM keypair already exists for $DOMAIN with selector '$SELECTOR'"
fi

# Step 3: Create the DKIM config files
log "Creating OpenDKIM config files..."

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

# Step 4: Deploy the configuration files
log "Deploying OpenDKIM config files..."
mkdir -p "$INSTALL_DIR/keys/$DOMAIN"
cp "$KEY_DIR/$SELECTOR.key" "$INSTALL_DIR/keys/$DOMAIN/"
cp "$CONFIG_DIR/opendkim.conf" "$INSTALL_DIR/"
cp "$CONFIG_DIR/KeyTable" "$INSTALL_DIR/"
cp "$CONFIG_DIR/SigningTable" "$INSTALL_DIR/"
cp "$CONFIG_DIR/TrustedHosts" "$INSTALL_DIR/"

# Set the appropriate permissions
chown -R opendkim:opendkim "$INSTALL_DIR"
chmod 600 "$INSTALL_DIR/keys/$DOMAIN/$SELECTOR.key"

# Step 5: Restart and enable OpenDKIM service
log "Restarting and enabling OpenDKIM..."
systemctl enable opendkim
systemctl restart opendkim

log "OpenDKIM configuration applied for domain: $DOMAIN"

# Output the DKIM DNS record for publishing
log "Publish the following DNS TXT record:"
cat "$KEY_DIR/$SELECTOR.txt"

# Step 6: SSL certificate handling based on method
SSL_METHOD="${SSL_METHOD:-certbot}"

if [[ "$SSL_METHOD" == "certbot" ]]; then
  log "Using Certbot SSL certificates."
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    die "SSL certificate or key not found for $DOMAIN under Certbot path."
  fi
else
  log "Using self-signed SSL certificates."
  CERT_PATH="/etc/ssl/certs/selfsigned.pem"
  KEY_PATH="/etc/ssl/private/selfsigned.key"
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    die "Self-signed SSL certificate or key not found."
  fi
fi

log "SSL certificates are ready for use with OpenDKIM."
