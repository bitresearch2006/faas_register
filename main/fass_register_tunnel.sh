#!/usr/bin/env bash
# wsl_tunnel.sh - WSL client: get cert, discover remote port, start autossh, renew cert automatically
#
# Install:
#   mkdir -p ~/bin
#   cp wsl_tunnel.sh ~/bin/wsl_tunnel.sh
#   chmod 700 ~/bin/wsl_tunnel.sh
#
# Configuration (recommended): create a file ~/.wsl_tunnel_env with:
#   DOMAIN="bitone.in"
#   TOKEN="paste_long_token_here"
#   PRINCIPAL="bitresearch"
#   USERNAME="alice"           # logical path /alice
#   LOCAL_PORT=8080
#   RENEW_BEFORE=300           # seconds before expiry to renew
#
# Make env file owner-only:
#   chmod 600 ~/.wsl_tunnel_env
#
# Use with systemd service (examples below) or run manually:
#   ~/bin/wsl_tunnel.sh start
#   ~/bin/wsl_tunnel.sh stop
#   ~/bin/wsl_tunnel.sh status
#
set -euo pipefail

# load env if present
ENVFILE="${HOME}/.wsl_tunnel_env"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
fi

# Defaults (override via ~/.wsl_tunnel_env)
DOMAIN="${DOMAIN:-bitone.in}"
TOKEN="${TOKEN:-}"
PRINCIPAL="${PRINCIPAL:-bitresearch}"
USERNAME="${USERNAME:-alice}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
RENEW_BEFORE="${RENEW_BEFORE:-300}"   # seconds before expiry to renew
KEY="$HOME/.ssh/bitone_key"
PUB="$KEY.pub"
CERT="$KEY-cert.pub"
LOGFILE="${HOME}/wsl_tunnel.log"
AUTOSSH_BIN="$(command -v autossh || true)"
SSH_BIN="$(command -v ssh || true)"
CURL_BIN="$(command -v curl || true)"
JQ_BIN="$(command -v jq || true)"
PY3_BIN="$(command -v python3 || true)"

# sanity checks
for cmd in ssh curl jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd"; exit 2; }
done

# helper: timestamped log
log() {
  echo "[$(date -Is)] $*" | tee -a "$LOGFILE"
}

usage() {
  cat <<USAGE
Usage: $0 {start|daemon|stop|status}
  start   - one-shot: request cert, discover port, start autossh and return
  daemon  - run continuous renew loop (blocking); suitable for systemd
  stop    - stop autossh tunnel process for assigned remote port
  status  - show process, port, cert info
USAGE
  exit 1
}

ensure_key() {
  if [ ! -f "$KEY" ]; then
    log "Generating ed25519 key $KEY"
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "wsl-${USERNAME}" >/dev/null
  fi
}

request_cert() {
  if [ -z "$TOKEN" ]; then
    log "ERROR: TOKEN not set. Put TOKEN in $ENVFILE or export it."
    return 10
  fi
  PUB_CONTENT=$(cat "$PUB")
  PAYLOAD=$(jq -n --arg pub "$PUB_CONTENT" --arg prin "$PRINCIPAL" --argjson ttl 3600 '{pubkey:$pub, principal:$prin, ttl:$ttl}')
  log "Requesting certificate from https://${DOMAIN}/sign-cert"
  RESP=$("$CURL_BIN" -s -w "\n%{http_code}" -X POST "https://${DOMAIN}/sign-cert" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$PAYLOAD") || { log "curl failed"; return 3; }
  BODY=$(echo "$RESP" | sed '$d')
  CODE=$(echo "$RESP" | tail -n1)
  if [ "$CODE" != "200" ]; then
    log "Cert request failed: HTTP $CODE"
    log "$BODY"
    return 4
  fi
  CERT_CONTENT=$(echo "$BODY" | jq -r '.cert // empty')
  if [ -z "$CERT_CONTENT" ]; then
    log "No cert field in response"
    log "$BODY"
    return 5
  fi
  echo "$CERT_CONTENT" > "$CERT"
  chmod 600 "$CERT"
  log "Saved cert to $CERT"
  return 0
}

discover_remote_port() {
  log "Querying whoami: https://${DOMAIN}/whoami"
  RESP=$("$CURL_BIN" -s -w "\n%{http_code}" -X GET "https://${DOMAIN}/whoami" -H "Authorization: Bearer $TOKEN") || { log "curl whoami failed"; return 6; }
  BODY=$(echo "$RESP" | sed '$d')
  CODE=$(echo "$RESP" | tail -n1)
  if [ "$CODE" != "200" ]; then
    log "whoami failed: HTTP $CODE"
    log "$BODY"
    return 7
  fi
  REMOTE_PORT_VAL=$(echo "$BODY" | jq -r '.port // empty')
  REMOTE_NAME=$(echo "$BODY" | jq -r '.name // empty')
  if [ -z "$REMOTE_PORT_VAL" ] || [ "$REMOTE_PORT_VAL" = "null" ]; then
    log "No port assigned for token. name=$REMOTE_NAME"
    return 8
  fi
  REMOTE_PORT="$REMOTE_PORT_VAL"
  log "Discovered remote port: $REMOTE_PORT (username=$REMOTE_NAME)"
  return 0
}

start_autossh() {
  if [ -z "$AUTOSSH_BIN" ]; then
    log "autossh not installed. Install with: sudo apt install -y autossh"
    return 20
  fi
  # kill any existing autossh for same remote port
  pkill -f "autossh.*-R .*:${REMOTE_PORT}:localhost:${LOCAL_PORT}" || true
  sleep 1
  log "Starting autossh: remote 127.0.0.1:${REMOTE_PORT} -> local localhost:${LOCAL_PORT}"
  "$AUTOSSH_BIN" -M 0 -f -N -o "ExitOnForwardFailure=yes" -i "$KEY" -o "CertificateFile=$CERT" \
    -R 127.0.0.1:${REMOTE_PORT}:localhost:${LOCAL_PORT} "${PRINCIPAL}@${DOMAIN}"
  sleep 1
  if pgrep -f "autossh.*-R .*:${REMOTE_PORT}:localhost:${LOCAL_PORT}" >/dev/null; then
    log "autossh started successfully"
    return 0
  else
    log "autossh failed to start"
    return 21
  fi
}

stop_autossh() {
  pkill -f "autossh.*-R .*:${REMOTE_PORT}:localhost:${LOCAL_PORT}" || true
  log "Stopped autossh for remote port ${REMOTE_PORT} (if any)"
}

cert_ttl_remaining() {
  # return seconds remaining until cert expiry (0 if unreadable/expired)
  if [ ! -f "$CERT" ]; then echo 0; return; fi
  # parse ssh-keygen -L output to find "Valid: from ... to <ts>"
  OUT=$("$SSH_BIN" -Q >/dev/null 2>&1 || true)  # ensure ssh exists
  INFO=$("$SSH_BIN" -L -f /dev/null 2>/dev/null || true) || true
  # use ssh-keygen to decode cert
  TTL_LINE=$("$SSH_BIN" -G 2>/dev/null || true)
  # safer: use ssh-keygen -L -f "$CERT" and parse the Valid: line
  RAW=$("$SSH_BIN" -v 2>/dev/null || true)
  # Use ssh-keygen -L
  RAW2=$(ssh-keygen -L -f "$CERT" 2>/dev/null || true)
  # find "Valid: from ... to ..."
  LINE=$(echo "$RAW2" | awk '/Valid: /{print; exit}' || true)
  if [ -z "$LINE" ]; then
    # fallback: return 0
    echo 0; return
  fi
  # Extract the 'to' ISO timestamp
  # Example: Valid: from 2025-12-01T12:00:00 to 2025-12-01T13:00:00
  TO=$(echo "$LINE" | sed -E 's/.* to ([0-9T:\-+.]+).*/\1/')
  if [ -z "$TO" ]; then echo 0; return; fi
  # Use python to compute seconds remaining
  REM=$("$PY3_BIN" - <<PY
import datetime,sys
s="$TO"
try:
  # parse using fromisoformat (handles timezone if present)
  exp=datetime.datetime.fromisoformat(s)
  now=datetime.datetime.now(exp.tzinfo) if exp.tzinfo else datetime.datetime.utcnow()
  rem=(exp - now).total_seconds()
  print(int(rem) if rem>0 else 0)
except Exception as e:
  print(0)
PY
)
  echo "$REM"
}

# Main actions
case "${1:-}" in
  start)
    ensure_key
    request_cert
    discover_remote_port
    start_autossh
    ;;
  daemon)
    ensure_key
    # loop forever: get cert, start autossh, sleep until (expiry - RENEW_BEFORE), then renew
    while true; do
      if ! request_cert; then
        log "request_cert failed; sleeping 60s before retry"
        sleep 60
        continue
      fi
      if ! discover_remote_port; then
        log "discover_remote_port failed; sleeping 60s"
        sleep 60
        continue
      fi
      if ! start_autossh; then
        log "start_autossh failed; sleeping 60s"
        sleep 60
        continue
      fi
      TTL=$(cert_ttl_remaining)
      if [ "$TTL" -le 0 ]; then
        log "Could not determine cert TTL; defaulting to 3600s sleep"
        sleep 3600
        continue
      fi
      # compute sleep time
      SLEEP_TIME=$(( TTL - RENEW_BEFORE ))
      if [ "$SLEEP_TIME" -le 60 ]; then SLEEP_TIME=60; fi
      log "Cert TTL: ${TTL}s; sleeping ${SLEEP_TIME}s until renewal"
      sleep "$SLEEP_TIME"
      log "Renewal: stopping autossh and renewing cert"
      stop_autossh
      # loop will re-request cert and start autossh again
    done
    ;;
  stop)
    # if REMOTE_PORT unknown, try to discover; ignore errors
    if ! discover_remote_port >/dev/null 2>&1; then
      log "Could not discover remote port; attempting to kill autossh by pattern"
      pkill -f "autossh" || true
    else
      stop_autossh
    fi
    ;;
  status)
    echo "Log: $LOGFILE"
    ps aux | egrep 'ssh|autossh' | egrep -v 'egrep' || true
    echo
    echo "Remote port (discovered if possible):"
    if discover_remote_port >/dev/null 2>&1; then
      echo "  REMOTE_PORT=$REMOTE_PORT"
      ss -tlnp | egrep ":${REMOTE_PORT}" || true
    else
      echo "  Could not discover remote port (token invalid or not registered)"
    fi
    echo
    if [ -f "$CERT" ]; then
      echo "Cert info:"
      ssh-keygen -L -f "$CERT" || true
    else
      echo "No cert present at $CERT"
    fi
    ;;
  *)
    usage
    ;;
esac

exit 0
