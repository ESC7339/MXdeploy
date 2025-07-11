#!/usr/bin/env bash
set -euo pipefail

#=== MODULE: Internal Mail Validation ===#
log()  { echo -e "\033[0;32m[MAIL_VALIDATOR] $*\033[0m"; }
fail() { echo -e "\033[0;31m[MAIL_VALIDATOR] FAIL: $*\033[0m" >&2; FAILED=true; }

FAILED=false

INI="/tmp/mxd_autodep/modules/configs/parameters.ini"
source <(grep -E '^(MAILDOMAIN|MAIL_IP|MAILDIR|DOMAIN|MAIL_GROUP|DEBUG_CERTS)=' "$INI")

MAILDIR="${MAILDIR:-/var/mail}"
DOMAIN="${DOMAIN:-$MAILDOMAIN}"

TESTUSER1="mxdtest1"
TESTUSER2="mxdtest2"

create_test_user() {
  local user="$1"
  local pass="TestPass123!"
  
  # Check if user exists, create if not
  if ! id "$user" &>/dev/null; then
    useradd -m -s /usr/sbin/nologin "$user"
    echo "$user:$pass" | chpasswd
    log "Test user '$user' created"
    
    # Create the Maildir structure and set permissions
    mkdir -p "/home/$user/Maildir/new"  # Ensure new directory exists
    mkdir -p "/home/$user/Maildir/cur"  # Ensure cur directory exists
    mkdir -p "/home/$user/Maildir/tmp"  # Ensure tmp directory exists
    
    # Set the proper ownership and permissions
    chown -R "$user:$MAIL_GROUP" "/home/$user/Maildir"
    chmod -R 700 "/home/$user/Maildir"  # Ensure proper permissions
    
    log "Maildir created for '$user'"
  else
    log "Test user '$user' already exists"
  fi
}


check_dns_local() {
  log "Validating local DNS setup..."
  if dig +short "mail.$DOMAIN" A | grep -q "$MAIL_IP" && dig +short "$DOMAIN" MX | grep -q "mail.$DOMAIN"; then
    log "DNS A and MX records resolve correctly"
  else
    fail "DNS A or MX records are missing or incorrect"
  fi
}

check_listeners() {
  log "Verifying that postfix and dovecot are listening..."
  local ok=true
  ss -tln | grep -q ":25 "  || { fail "SMTP port 25 not listening"; ok=false; }
  ss -tln | grep -q ":587 " || { fail "Submission port 587 not listening"; ok=false; }
  ss -tln | grep -q ":993 " || { fail "IMAPS port 993 not listening"; ok=false; }
  $ok && log "All required services are listening"
}

check_ssl_cert() {
  [[ "${DEBUG_CERTS,,}" == "yes" ]] || return 0
  log "Validating SSL cert for mail.$DOMAIN..."
  local cert_cn
  cert_cn=$(echo | openssl s_client -connect mail.$DOMAIN:993 -servername mail.$DOMAIN 2>/dev/null | \
    openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^/]*\).*/\1/p')
  if [[ "$cert_cn" == "mail.$DOMAIN" ]]; then
    log "SSL cert for mail.$DOMAIN is valid"
  else
    fail "SSL cert CN mismatch or retrieval failed (got: $cert_cn)"
  fi
}

check_dovecot_user() {
  for user in "$TESTUSER1" "$TESTUSER2"; do
    if doveadm user "$user" &>/dev/null; then
      log "Dovecot user '$user' is valid"
    else
      fail "Dovecot does not recognize user '$user'"
    fi
  done
}

send_mail() {
  local from="$1"
  local to="$2"
  local body="This is an internal MXD mail test from $from to $to"
  if echo "$body" | mail -s "MXD TEST" "$to"; then
    log "Sent test mail from $from to $to"
  else
    fail "Failed to send mail from $from to $to"
  fi
}

check_local_maildir() {
  local user="$1"
  local dir="/home/$user/Maildir/new"
  if [[ -d "$dir" && "$(ls -A "$dir" 2>/dev/null)" ]]; then
    log "Mail successfully received in $dir"
  else
    fail "Mail not found in $dir"
  fi
}

check_mailbox_permissions() {
  for user in "$TESTUSER1" "$TESTUSER2"; do
    local dir="/home/$user/Maildir"
    [[ -d "$dir" ]] || { fail "Mailbox directory missing: $dir"; continue; }
    [[ $(stat -c '%G' "$dir") == "$MAIL_GROUP" ]] || fail "Mailbox $dir has wrong group"
  done
  log "Mailbox permissions are valid"
}

check_postfix_queue() {
  local qcount
  qcount=$(postqueue -p | grep -c '^[A-F0-9]')
  if (( qcount == 0 )); then
    log "Postfix mail queue is clean"
  else
    fail "Postfix queue has $qcount stuck message(s)"
  fi
}

check_smtp_auth() {
  log "Testing local SMTP AUTH on port 587..."
  RESPONSE=$(timeout 5 openssl s_client -connect 127.0.0.1:587 -starttls smtp -crlf 2>/dev/null <<< "EHLO localhost")
  if [[ "$RESPONSE" == *"250-"* ]]; then
    log "SMTP 587 STARTTLS available"
  else
    fail "SMTP STARTTLS on 587 failed"
  fi
}

check_imap_auth() {
  for user in "$TESTUSER1" "$TESTUSER2"; do
    log "Testing IMAP connectivity for $user on port 993..."
    RESPONSE=$(echo -e "a login $user TestPass123!\na logout" | timeout 5 openssl s_client -connect 127.0.0.1:993 -crlf 2>/dev/null)
    if [[ "$RESPONSE" == *"OK"* ]]; then
      log "IMAP server responds correctly on 993 (auth test for $user successful)"
    else
      fail "IMAP login failed for $user"
    fi
  done
}

check_dkim_in_headers() {
  for user in "$TESTUSER1" "$TESTUSER2"; do
    local dir="/home/$user/Maildir/new"
    local file
    file=$(find "$dir" -type f -exec grep -l "^DKIM-Signature:" {} + 2>/dev/null | head -n 1 || true)
    if [[ -n "$file" ]]; then
      log "DKIM-Signature present in $user mail headers"
    else
      fail "No DKIM-Signature found in mail headers for $user"
    fi
  done
}

log "=== Internal Mail System Validation ==="

create_test_user "$TESTUSER1"
create_test_user "$TESTUSER2"

check_dns_local
check_listeners
check_ssl_cert
check_dovecot_user
send_mail "$TESTUSER1" "$TESTUSER2"
sleep 2
check_local_maildir "$TESTUSER2"
check_dkim_in_headers
send_mail "$TESTUSER2" "$TESTUSER1"
sleep 2
check_local_maildir "$TESTUSER1"
check_mailbox_permissions
check_postfix_queue
check_smtp_auth
check_imap_auth

if $FAILED; then
  log "One or more internal validation tests FAILED"
else
  log "All internal validation tests passed successfully"
fi
