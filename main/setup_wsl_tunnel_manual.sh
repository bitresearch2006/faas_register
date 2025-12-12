#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONFIGURATION  (edit these if needed)
###############################################################################
DOMAIN="bitone.in"
TOKEN="a795166810edffb9c9f098f3aacd9775a002525c2282c99e"     # token from server
PRINCIPAL="bitresearch2006"                                     # Linux login user
NAME="alice"                                                # public tunnel name
KEY="$HOME/.ssh/bitone_key"
LOCAL_PORT=8080                                             # local service port
TTL=3600

###############################################################################
# Dependencies check
###############################################################################
for cmd in curl jq ssh ssh-keygen; do
  if ! command -v "$cmd" >/dev/null; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
done

###############################################################################
# Ensure SSH key exists
###############################################################################
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "${KEY}" ]; then
  echo "Generating ED25519 key..."
  ssh-keygen -t ed25519 -f "${KEY}" -N "" -C "faas-${NAME}@${DOMAIN}"
fi

PUBKEY=$(cat "${KEY}.pub")

###############################################################################
# REQUEST CERTIFICATE
###############################################################################
echo "Requesting certificate from https://${DOMAIN}/sign-cert ..."

CERT_RESPONSE=$(curl -sS -X POST "https://${DOMAIN}/sign-cert" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"pubkey\":\"${PUBKEY}\",\"principal\":\"${PRINCIPAL}\",\"ttl\":${TTL}}" \
)

# Validate
if ! printf "%s" "$CERT_RESPONSE" | jq -e '.cert' >/dev/null 2>&1; then
  echo "ERROR: Server did not return a certificate."
  echo "Server responded:"
  printf "%s\n" "$CERT_RESPONSE"
  exit 1
fi

printf "%s\n" "$(printf "%s" "$CERT_RESPONSE" | jq -r '.cert' | sed '/^$/d')" > "${KEY}-cert.pub"


echo "Certificate saved to ${KEY}-cert.pub"
ssh-keygen -Lf "${KEY}-cert.pub" || true

###############################################################################
# GET REMOTE PORT
###############################################################################
echo "Querying assigned tunnel port from /whoami ..."

WHOAMI_RESPONSE=$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
  "https://${DOMAIN}/whoami")

REMOTE_PORT=$(printf "%s" "$WHOAMI_RESPONSE" | jq -r '.port')

if [ -z "$REMOTE_PORT" ] || [ "$REMOTE_PORT" = "null" ]; then
  echo "ERROR: Could not extract remote port. Response:"
  printf "%s\n" "$WHOAMI_RESPONSE"
  exit 1
fi

echo "Remote assigned port: $REMOTE_PORT"

###############################################################################
# START REVERSE TUNNEL
###############################################################################
echo
echo "Starting SSH reverse tunnel..."
echo "Your public URL will be:"
echo "    https://${DOMAIN}/${NAME}"
echo
echo "Forwarding local port ${LOCAL_PORT} → remote port ${REMOTE_PORT}"
echo "Press Ctrl+C to stop the tunnel."
echo

exec ssh -i "${KEY}" \
  -o CertificateFile="${KEY}-cert.pub" \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -N \
  -R "127.0.0.1:${REMOTE_PORT}:localhost:${LOCAL_PORT}" \
  "${PRINCIPAL}@${DOMAIN}"
