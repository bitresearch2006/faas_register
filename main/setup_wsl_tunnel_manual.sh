#!/usr/bin/env bash
set -euo pipefail

DOMAIN="bitone.in"
VM_USER="bitresearch"
TOKEN="387418eca6dad4b9a704141675bf8fa3b7a95fa7a8b846ee"
PRINCIPAL="bitresearch"
NAME="alice"
KEY="$HOME/.ssh/bitone_key"
LOCAL_PORT=8080

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "${KEY}" ]; then
  ssh-keygen -t ed25519 -f "${KEY}" -N "" -C "faas-tunnel-${NAME}@${DOMAIN}"
fi

echo "Requesting certificate..."
curl -sS -X POST "https://${DOMAIN}/sign-cert" \
  -F "token=${TOKEN}" \
  -F "name=${NAME}" \
  -F "principals=${PRINCIPAL}" \
  -F "pubkey=$(cat ${KEY}.pub)" \
  -o "${KEY}-cert.pub"

echo "Verifying cert..."
ssh-keygen -Lf "${KEY}-cert.pub"

echo "Querying assigned remote port..."
WHOAMI_JSON="$(curl -sS -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/whoami")"
REMOTE_PORT="$(printf "%s" "$WHOAMI_JSON" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' || true)"

if [ -z "$REMOTE_PORT" ]; then
  echo "ERROR: could not determine REMOTE_PORT from whoami response:"
  printf "%s\n" "$WHOAMI_JSON"
  exit 1
fi

echo "Remote port is: $REMOTE_PORT"
echo "Starting ssh reverse tunnel (foreground). Press Ctrl-C to stop."
ssh -i "${KEY}" -o CertificateFile="${KEY}-cert.pub" -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
    -N -R "127.0.0.1:${REMOTE_PORT}:localhost:${LOCAL_PORT}" "${VM_USER}@${DOMAIN}"
