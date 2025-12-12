
#!/usr/bin/env bash
# test_faas_commands.sh
# Build and print the curl + autossh commands that faas_register_tunnel.sh would run.
# Safe by default: use --exec to actually run the HTTP calls (not recommended on CI).

set -euo pipefail
IFS=$'\n\t'

# config sources (choose one)
ENV_CANDIDATES=(/etc/faas_register_tunnel.env "$HOME/.wsl_tunnel_env")
ENVFILE=""
for f in "${ENV_CANDIDATES[@]}"; do
  if [ -f "$f" ]; then ENVFILE="$f"; break; fi
done
if [ -z "$ENVFILE" ]; then
  echo "No env file found in /etc/faas_register_tunnel.env or ~/.wsl_tunnel_env"
  exit 2
fi

# shellcheck disable=SC1090
. "$ENVFILE"

# defaults (fall back if env didn't provide)
DOMAIN="${DOMAIN:-bitone.in}"
TOKEN="${TOKEN:-}"
PRINCIPAL="${PRINCIPAL:-$(id -un)}"
USERNAME="${USERNAME:-${PRINCIPAL}}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
REQUEST_TTL="${REQUEST_TTL:-3600}"
INSECURE="${INSECURE:-0}"

# key/cert locations (matches your script conventions)
KEY="${HOME}/.ssh/bitone_key"
PUB="${KEY}.pub"
CERT="${KEY}-cert.pub"

CURL="$(command -v curl || true)"
AUTOSSH="$(command -v autossh || true)"
SSH="$(command -v ssh || true)"
JQ="$(command -v jq || true)"

if [ -z "$CURL" ]; then
  echo "curl not found in PATH"
  exit 3
fi

# build protocol and extra curl options
_build_request_params() {
  if printf '%s\n' "$DOMAIN" | grep -Eq '^localhost$|^127\.0\.0\.1$|^\[::1\]$'; then
    PROTO="http"
  else
    PROTO="https"
  fi

  if [ "${PROTO}" = "https" ] && [ "${INSECURE}" = "1" ]; then
    EXTRA_CURL_OPTS="-k"
  else
    EXTRA_CURL_OPTS=""
  fi

  BASE_URL="${PROTO}://${DOMAIN}"
}

# decide --resolve for local nginx SNI preservation (like your script)
determine_resolve_opt() {
  RESOLVE_OPT=""
  if printf '%s\n' "$DOMAIN" | grep -Eq '^localhost$|^127\.0\.0\.1$|^\[::1\]$'; then
    RESOLVE_OPT=""
    return
  fi
  if ss -ltnp 2>/dev/null | grep -q '127.0.0.1:443'; then
    RESOLVE_OPT="--resolve ${DOMAIN}:443:127.0.0.1"
    return
  fi
  if grep -Eq "^\s*127\.0\.0\.1\s+${DOMAIN}(\s|\$)" /etc/hosts 2>/dev/null; then
    RESOLVE_OPT="--resolve ${DOMAIN}:443:127.0.0.1"
    return
  fi
  RESOLVE_OPT=""
}

# Build the request_cert curl command string (printed)
build_request_cert_cmd() {
  _build_request_params
  determine_resolve_opt

  local pub
  if [ -f "$PUB" ]; then
    # escape pubkey for JSON payload (basic)
    pub=$(sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$PUB" | tr -d '\n')
  else
    pub="SSH_PUBKEY_CONTENT_HERE"
  fi

  PAYLOAD=$(printf '{"pubkey":"%s","principal":"%s","ttl":%s}' "$pub" "$PRINCIPAL" "$REQUEST_TTL")

  # assemble curl args (as a printable command)
  local args=()
  [ -n "$RESOLVE_OPT" ] && args+=("$RESOLVE_OPT")
  [ -n "$EXTRA_CURL_OPTS" ] && args+=("$EXTRA_CURL_OPTS")
  args+=("-H" "Host: ${DOMAIN}" "-H" "Authorization: Bearer ${TOKEN}" "-H" "Content-Type: application/json")
  args+=("-X" "POST" "--data" "'$PAYLOAD'" "'${BASE_URL}/sign-cert'")

  printf "%s %s\n" "$CURL" "${args[*]}"
}

# Build whoami curl command
build_whoami_cmd() {
  _build_request_params
  determine_resolve_opt

  local args=()
  [ -n "$RESOLVE_OPT" ] && args+=("$RESOLVE_OPT")
  [ -n "$EXTRA_CURL_OPTS" ] && args+=("$EXTRA_CURL_OPTS")
  args+=("-H" "Host: ${DOMAIN}" "-H" "Authorization: Bearer ${TOKEN}" "'${BASE_URL}/whoami'")

  printf "%s %s\n" "$CURL" "${args[*]}"
}

# Build autossh command (print only)
build_autossh_cmd() {
  # remote port unknown until whoami; we print placeholder
  REMOTE_PORT_PLACEHOLDER='REMOTE_PORT_FROM_WHOAMI'
  local cmd
  if [ -z "$AUTOSSH" ]; then
    cmd="(autossh not found) autossh -M 0 -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"$KEY\" -o CertificateFile=\"$CERT\" -R 127.0.0.1:${REMOTE_PORT_PLACEHOLDER}:localhost:${LOCAL_PORT} \"${PRINCIPAL}@${DOMAIN}\""
  else
    cmd="$AUTOSSH -M 0 -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"$KEY\" -o CertificateFile=\"$CERT\" -R 127.0.0.1:${REMOTE_PORT_PLACEHOLDER}:localhost:${LOCAL_PORT} \"${PRINCIPAL}@${DOMAIN}\""
  fi
  printf "%s\n" "$cmd"
}

# print results
echo "Env file used: $ENVFILE"
echo "DOMAIN=$DOMAIN  PRINCIPAL=$PRINCIPAL  USERNAME=$USERNAME  LOCAL_PORT=$LOCAL_PORT"
echo
echo "=== curl command to request cert (dry-run) ==="
build_request_cert_cmd
echo
echo "=== curl command to call whoami ==="
build_whoami_cmd
echo
echo "=== autossh command (placeholder remote port) ==="
build_autossh_cmd
echo
# optional execution: use --exec to actually run the two curl commands (will contact network)
if [ "${1:-}" = "--exec" ]; then
  echo "Running whoami/request_cert for real (INSECURE=${INSECURE})..."
  _build_request_params
  determine_resolve_opt
  # whoami
  set -x
  if [ -n "$RESOLVE_OPT" ]; then
    "${CURL}" $RESOLVE_OPT $EXTRA_CURL_OPTS -H "Host: ${DOMAIN}" -H "Authorization: Bearer ${TOKEN}" -sS "${BASE_URL}/whoami"
  else
    "${CURL}" $EXTRA_CURL_OPTS -H "Host: ${DOMAIN}" -H "Authorization: Bearer ${TOKEN}" -sS "${BASE_URL}/whoami"
  fi
  # request cert (requires real pubkey present)
  if [ -f "$PUB" ]; then
    PAYLOAD=$(jq -n --arg pub "$(cat "$PUB")" --arg prin "$PRINCIPAL" --argjson ttl "$REQUEST_TTL" '{pubkey:$pub, principal:$prin, ttl:$ttl}')
    if [ -n "$RESOLVE_OPT" ]; then
      "${CURL}" $RESOLVE_OPT $EXTRA_CURL_OPTS -H "Host: ${DOMAIN}" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -X POST --data "$PAYLOAD" "${BASE_URL}/sign-cert"
    else
      "${CURL}" $EXTRA_CURL_OPTS -H "Host: ${DOMAIN}" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -X POST --data "$PAYLOAD" "${BASE_URL}/sign-cert"
    fi
  else
    echo "Public key $PUB not found; cannot request cert for real."
  fi
fi




