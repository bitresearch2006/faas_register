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

# Optional runtime flags (useful for local testing with self-signed certs)
INSECURE="${INSECURE:-0}"       # 1 => curl -k (skip cert verify). Keep 0 in production.
CURL_OPTS="${CURL_OPTS:-}"      # extra curl options, e.g. --cacert /path/to/ca.pem
# TTL requested for new certs (seconds) — can be overridden in env
REQUEST_TTL="${REQUEST_TTL:-3600}"


# Load environment variables
ENVFILE="${HOME}/.wsl_tunnel_env"

# Preferred: user-level env file
if [ -f "$ENVFILE" ]; then
    # shellcheck disable=SC1090
    source "$ENVFILE"
else
    # fallback to system-wide env file installed by install.sh
    if [ -f /etc/faas_register_tunnel.env ]; then
        ENVFILE="/etc/faas_register_tunnel.env"
        # shellcheck disable=SC1091
        source "$ENVFILE"
    fi
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

# Determine protocol and curl options for the DOMAIN
_build_request_params() {
  # choose protocol: use http for localhost / 127.0.0.1, else https
  if printf '%s\n' "$DOMAIN" | grep -Eq '^localhost$|^127\.0\.0\.1$|^\[::1\]$'; then
    PROTO="http"
  else
    PROTO="https"
  fi

  # build EXTRA_CURL_OPTS
  if [ "${PROTO}" = "https" ] && [ "${INSECURE:-0}" = "1" ]; then
    EXTRA_CURL_OPTS="-k ${CURL_OPTS}"
  else
    EXTRA_CURL_OPTS="${CURL_OPTS}"
  fi

  BASE_URL="${PROTO}://${DOMAIN}"
}

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
  if [ ! -f "$PUB" ]; then
    log "ERROR: public key not found at $PUB"
    return 11
  fi

  PUB_CONTENT=$(cat "$PUB")
  PAYLOAD=$(jq -n --arg pub "$PUB_CONTENT" --arg prin "$PRINCIPAL" --argjson ttl "$REQUEST_TTL" '{pubkey:$pub, principal:$prin, ttl:$ttl}')

  _build_request_params
  log "Requesting certificate from ${BASE_URL}/sign-cert (proto=${PROTO})"
  RESP=$("$CURL_BIN" -s $EXTRA_CURL_OPTS -w "\n%{http_code}" -X POST "${BASE_URL}/sign-cert" \
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
  _build_request_params
  log "Querying whoami: ${BASE_URL}/whoami (proto=${PROTO})"

  RESP=$("$CURL_BIN" -s $EXTRA_CURL_OPTS -w "\n%{http_code}" -X GET "${BASE_URL}/whoami" \
    -H "Authorization: Bearer $TOKEN") || { log "curl whoami failed"; return 6; }
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
  # $CERT should be set to the certificate path (e.g. ~/.ssh/id_rsa-cert.pub)
  if [ -z "${CERT:-}" ] || [ ! -f "$CERT" ]; then
    echo 0
    return 0
  fi

  # Grab the 'Valid:' line from ssh-keygen output (first occurrence)
  raw=$(ssh-keygen -L -f "$CERT" 2>/dev/null || true)
  valid_line=$(printf '%s\n' "$raw" | awk '/^[[:space:]]*Valid:/{print; exit}')

  if [ -z "$valid_line" ]; then
    # no valid info
    echo 0
    return 0
  fi

  # Try to extract the expiry timestamp (the 'to' value). Examples of valid_line:
  #   Valid: from 2025-12-11T11:22:33 to 2025-12-11T12:22:33
  #   Valid: from 2025-12-11T11:22:33+05:30 to 2025-12-11T12:22:33+05:30
  #   or "Valid:  from Thu Dec 11 11:22:33 2025"
  # We'll try ISO-like first, then fallback to more generic parsing.

  # 1) try to capture an ISO-like timestamp after ' to '
  to_iso=$(printf '%s\n' "$valid_line" | sed -E 's/.* to ([0-9T:\-+]+).*/\1/')

  # Helper: use python3 if available for robust parsing and timezone handling
  if command -v python3 >/dev/null 2>&1 && [ -n "$to_iso" ]; then
    # python will print integer seconds remaining (>=0), or 0 on error
    secs=$(
      python3 - <<PY
import sys,datetime
s = """$to_iso"""
try:
    # Try isoformat first (handles timezone offsets)
    exp = datetime.datetime.fromisoformat(s)
    # If exp has no tzinfo, treat it as naive local time -> compare to local now
    now = datetime.datetime.now(exp.tzinfo) if exp.tzinfo else datetime.datetime.now()
    rem = int((exp - now).total_seconds())
    print(rem if rem > 0 else 0)
except Exception:
    # Try a more lenient parse using strptime patterns (fallback)
    try:
        for fmt in ("%a %b %d %H:%M:%S %Y", "%Y-%m-%dT%H:%M:%S"):
            try:
                exp = datetime.datetime.strptime(s, fmt)
                now = datetime.datetime.now()
                rem = int((exp - now).total_seconds())
                print(rem if rem > 0 else 0)
                raise SystemExit(0)
            except Exception:
                pass
        print(0)
    except Exception:
        print(0)
PY
    )
    # ensure numeric
    if printf '%s' "$secs" | grep -Eq '^[0-9]+$'; then
      echo "$secs"
      return 0
    fi
  fi

  # 2) Fallback: try parsing a human-readable 'to' date with date -d (GNU date)
  # extract everything after ' to ' up to end-of-line
  to_human=$(printf '%s\n' "$valid_line" | sed -E 's/.* to (.*)/\1/')
  if [ -n "$to_human" ] && command -v date >/dev/null 2>&1; then
    # date -d returns epoch seconds for many common formats
    exp_epoch=$(date -d "$to_human" +%s 2>/dev/null || true)
    if [ -n "$exp_epoch" ] && printf '%s' "$exp_epoch" | grep -Eq '^[0-9]+$'; then
      now_epoch=$(date +%s)
      rem=$((exp_epoch - now_epoch))
      if [ "$rem" -gt 0 ]; then
        echo "$rem"
        return 0
      fi
    fi
  fi

  # 3) If we couldn't parse expiry, return 0
  echo 0
  return 0
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
