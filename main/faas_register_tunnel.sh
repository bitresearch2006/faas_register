#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Load user configuration
###############################################################################
ENV_FILE="/etc/faas_register_tunnel.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "[FATAL] Env file missing: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

KEY="$HOME/.ssh/bitone_key"
CERT="$KEY-cert.pub"

TTL_DEFAULT=3600
RENEW_BEFORE="${RENEW_BEFORE:-300}"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

###############################################################################
log() {
  printf "[%s] %s\n" "$(date -Is)" "$*"
  logger -t faas_tunnel "$*" || true
}
###############################################################################



###############################################################################
# Request certificate from server
###############################################################################
request_certificate() {
  log "Requesting new certificate..."

  PUBKEY=$(cat "${KEY}.pub")

  RESPONSE=$(curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "https://${DOMAIN}/sign-cert" \
    -d "{\"pubkey\":\"${PUBKEY}\",\"principal\":\"${PRINCIPAL}\",\"ttl\":${TTL_DEFAULT}}"
  )

  if ! printf "%s" "$RESPONSE" | jq -e '.cert' >/dev/null; then
    log "ERROR: Certificate request failed: $RESPONSE"
    return 1
  fi

  # Extract raw certificate (may contain extra newlines)
  CERT_CLEAN=$(printf "%s" "$RESPONSE" | jq -r '.cert' | tr -d '\\')
  echo "$CERT_CLEAN" > "$CERT"

  chmod 600 "$CERT"

  log "Certificate renewed successfully: $CERT"
  return 0
}



###############################################################################
# Determine assigned remote port
###############################################################################
get_remote_port() {
  local W
  W=$(curl -sS -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/whoami")

  PORT=$(printf "%s" "$W" | jq -r '.port')

  if [ "$PORT" = "null" ] || [ -z "$PORT" ]; then
    log "ERROR: /whoami returned invalid: $W"
    return 1
  fi
  echo "$PORT"
}



###############################################################################
# Start SSH reverse tunnel
###############################################################################
start_tunnel() {
  local PORT=$1

  log "Starting tunnel: local:$LOCAL_PORT → remote:$PORT"

  ssh -N \
    -i "$KEY" \
    -o CertificateFile="$CERT" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -R "127.0.0.1:${PORT}:localhost:${LOCAL_PORT}" \
    "${PRINCIPAL}@${DOMAIN}"
}



###############################################################################
# MAIN LOOP: Renew cert + restart SSH tunnel
###############################################################################
if [ ! -f "${KEY}" ]; then
  log "Key does not exist. Generate manually first!"
  exit 1
fi

while true; do
  # 1) Ensure certificate exists
  if [ ! -f "$CERT" ]; then
    request_certificate || { sleep 30; continue; }
  fi

  # 2) Check certificate expiry
  EXPIRY=$(ssh-keygen -Lf "$CERT" | awk '/Valid:/ {print $5}')
  EXP_SECONDS=$(date -d "$EXPIRY" +%s)
  NOW_SECONDS=$(date +%s)

  if (( EXP_SECONDS - NOW_SECONDS < RENEW_BEFORE )); then
    log "Certificate expiring soon → renewing now"
    request_certificate || { sleep 30; continue; }
  fi

  # 3) Determine assigned tunnel port
  PORT=$(get_remote_port) || { sleep 10; continue; }

  # 4) Start SSH tunnel (blocking until disconnect)
  start_tunnel "$PORT"

  log "SSH tunnel exited — retrying in 5 seconds"
  sleep 5
done
