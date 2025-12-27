#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${INSTANCE:-default}"
ENV_DIR="/etc/faas_register_tunnel"
ENV_FILE="${ENV_DIR}/${INSTANCE}.env"

log() {
  printf "[%s] [%s] %s\n" "$(date -Is)" "$INSTANCE" "$*"
  logger -t "faas_tunnel[$INSTANCE]" "$*" || true
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "FATAL: Env file not found: $ENV_FILE"
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
# Request certificate from server
###############################################################################
request_certificate() {
  log "Requesting new certificate..."

  [[ -f "${KEY}.pub" ]] || { log "FATAL: Public key missing: ${KEY}.pub"; return 1; }
  PUBKEY=$(cat "${KEY}.pub")

  RESPONSE=$(curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "https://${DOMAIN}/sign-cert" \
    -d "{\"pubkey\":\"${PUBKEY}\",\"principal\":\"${PRINCIPAL}\",\"ttl\":${TTL_DEFAULT}}"
  )

  if ! printf "%s" "$RESPONSE" | jq -e '.cert' >/dev/null; then
    log "ERROR: Cert request failed: $RESPONSE"
    return 1
  fi

  printf "%s" "$RESPONSE" | jq -r '.cert' | tr -d '\\' > "$CERT"
  chmod 600 "$CERT"

  log "Certificate saved: $CERT"
}



###############################################################################
# Determine assigned remote port
###############################################################################
get_remote_port() {
  local W
  W=$(curl -sS -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/whoami")
  PORT=$(printf "%s" "$W" | jq -r '.port')

  if [[ -z "$PORT" || "$PORT" == "null" ]]; then
    log "ERROR: Invalid whoami response: $W"
    return 1
  fi
  echo "$PORT"
}



###############################################################################
# Start SSH reverse tunnel
###############################################################################
start_tunnel() {
  local PORT=$1
  log "Starting tunnel local:${LOCAL_PORT} → remote:${PORT}"

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
if [[ ! -f "${KEY}" ]]; then
  log "Key does not exist. Generate manually first!"
  exit 1
fi

while true; do
  # 1) Ensure certificate exists
  if [[ ! -f "$CERT" ]]; then
    request_certificate || { sleep 30; continue; }
  fi

  # 2) Check certificate validity & expiry
  # If ssh-keygen fails, the cert is corrupted -> delete it and retry
  if ! ssh-keygen -Lf "$CERT" >/dev/null 2>&1; then
    log "Certificate is corrupted or invalid. Deleting and requesting new one..."
    rm -f "$CERT"
    continue
  fi

  EXPIRY=$(ssh-keygen -Lf "$CERT" | awk '/Valid:/ {print $5}')
  
  # Handle case where date parsing fails
  if ! EXP_SECONDS=$(date -d "$EXPIRY" +%s 2>/dev/null); then
     log "Could not parse certificate date. Deleting..."
     rm -f "$CERT"
     continue
  fi

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
