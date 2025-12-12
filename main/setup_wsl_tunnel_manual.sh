#!/usr/bin/env bash
# setup_wsl_tunnel.sh
# Full manual setup for WSL client -> bitone.in tunnel
# Usage (recommended): sudo ./setup_wsl_tunnel.sh
# Optional flags: --domain, --token, --principal, --username, --local-port, --no-autossh, --ttl
set -euo pipefail
IFS=$'\n\t'

# Defaults (you can override with flags)
DOMAIN="bitone.in"
TOKEN=""
PRINCIPAL="$(id -un)"
USERNAME="${PRINCIPAL}"
LOCAL_PORT=8080
RENEW_BEFORE=300
TTL=3600
AUTO_START_AUTOSSH=1   # set 0 to only print autossh command
KEY_DIR="/root/.ssh"
KEY_NAME="bitone_key"
KEY_PATH="${KEY_DIR}/${KEY_NAME}"
CERT_PATH="${KEY_PATH}-cert.pub"
ENVFILE="/etc/faas_register_tunnel.env"
CURL="$(command -v curl || true)"
JQ="$(command -v jq || true)"
AUTOSSH="$(command -v autossh || true)"
SSHKEYGEN="$(command -v ssh-keygen || true)"
PYTHON3="$(command -v python3 || true)"

usage(){
  cat <<EOF
Usage: sudo $0 [options]

Options:
  --domain <domain>       Default: ${DOMAIN}
  --token <token>         (required unless already in ${ENVFILE})
  --principal <name>      Default: ${PRINCIPAL}
  --username <name>       Default: ${USERNAME}
  --local-port <port>     Default: ${LOCAL_PORT}
  --ttl <seconds>         Cert TTL (default: ${TTL})
  --no-autossh            Do not start autossh, only print command
  --help                  Show this help
EOF
  exit 1
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --principal) PRINCIPAL="$2"; shift 2;;
    --username) USERNAME="$2"; shift 2;;
    --local-port) LOCAL_PORT="$2"; shift 2;;
    --ttl) TTL="$2"; shift 2;;
    --no-autossh) AUTO_START_AUTOSSH=0; shift;;
    --help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs to run as root (it writes ${ENVFILE} and keys to ${KEY_DIR}). Use sudo."
  exit 2
fi

# helper log
log(){ printf '%s %s\n' "[$(date -Is)]" "$*" | systemd-cat -t setup_wsl_tunnel 2>/dev/null || printf '%s %s\n' "[$(date -Is)]" "$*"; }

if [ -z "$CURL" ]; then
  echo "curl required but not found. Install it and re-run."
  exit 3
fi
if [ -z "$SSHKEYGEN" ]; then
  echo "ssh-keygen required but not found. Install openssh-client and re-run."
  exit 3
fi

# 1) Create / update env file if missing or token provided
write_env(){
  log "Writing env file ${ENVFILE}"
  cat >"${ENVFILE}.tmp" <<EOF
DOMAIN="${DOMAIN}"
TOKEN="${TOKEN}"
PRINCIPAL="${PRINCIPAL}"
USERNAME="${USERNAME}"
LOCAL_PORT=${LOCAL_PORT}
RENEW_BEFORE=${RENEW_BEFORE}
EOF
  mv "${ENVFILE}.tmp" "${ENVFILE}"
  chmod 600 "${ENVFILE}"
  chown root:root "${ENVFILE}"
  log "Wrote ${ENVFILE} (owner root, mode 600)"
}

if [ -f "${ENVFILE}" ]; then
  # if token not provided via CLI, read token from existing env
  if [ -z "$TOKEN" ]; then
    # extract TOKEN safely
    TOKEN="$(awk -F= '/^TOKEN=/{gsub(/"/,"",$2); print $2}' "${ENVFILE}" || true)"
    if [ -z "$TOKEN" ]; then
      echo "ENV file ${ENVFILE} exists but TOKEN not found inside. Provide --token or edit ${ENVFILE}."
      exit 4
    fi
  else
    # token provided on command line: merge into env file
    # preserve other values from current file if present
    DOMAIN="$(awk -F= '/^DOMAIN=/{gsub(/"/,"",$2); print $2}' "${ENVFILE}" 2>/dev/null || echo "$DOMAIN")"
    PRINCIPAL="$(awk -F= '/^PRINCIPAL=/{gsub(/"/,"",$2); print $2}' "${ENVFILE}" 2>/dev/null || echo "$PRINCIPAL")"
    USERNAME="$(awk -F= '/^USERNAME=/{gsub(/"/,"",$2); print $2}' "${ENVFILE}" 2>/dev/null || echo "$USERNAME")"
    LOCAL_PORT="$(awk -F= '/^LOCAL_PORT=/{gsub(/"/,"",$2); print $2}' "${ENVFILE}" 2>/dev/null || echo "$LOCAL_PORT")"
    write_env
  fi
else
  if [ -z "$TOKEN" ]; then
    echo "No ${ENVFILE} and no --token provided. Provide --token or create ${ENVFILE} beforehand."
    exit 4
  fi
  write_env
fi

# show summary
log "Configuration: DOMAIN=${DOMAIN} PRINCIPAL=${PRINCIPAL} USERNAME=${USERNAME} LOCAL_PORT=${LOCAL_PORT} TTL=${TTL}"

# 2) Ensure key directory and keypair exist (create if missing)
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"
if [ ! -f "${KEY_PATH}" ]; then
  log "Generating ed25519 key at ${KEY_PATH}"
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "faas-tunnel-${USERNAME}@${HOSTNAME:-local}" >/dev/null 2>&1
  chmod 600 "${KEY_PATH}" "${KEY_PATH}.pub"
  chown root:root "${KEY_PATH}"* || true
else
  log "Key already exists: ${KEY_PATH}"
fi

# helper to set resolve option if local nginx bound
RESOLVE_OPT=""
_set_curl_resolve(){
  RESOLVE_OPT=""
  if printf '%s\n' "$DOMAIN" | grep -Eq '^localhost$|^127\.0\.0\.1$|^\[::1\]$'; then
    RESOLVE_OPT=""
    return 0
  fi
  if ss -ltnp 2>/dev/null | grep -q '127.0.0.1:443'; then
    RESOLVE_OPT="--resolve ${DOMAIN}:443:127.0.0.1"
    return 0
  fi
  if grep -Eq "^\s*127\.0\.0\.1\s+${DOMAIN}(\s|\$)" /etc/hosts 2>/dev/null; then
    RESOLVE_OPT="--resolve ${DOMAIN}:443:127.0.0.1"
    return 0
  fi
  RESOLVE_OPT=""
  return 0
}

_set_curl_resolve

# 3) Request cert from sign-cert endpoint and save it
log "Requesting certificate from https://${DOMAIN}/sign-cert (resolve='${RESOLVE_OPT}')"

PUBKEY_CONTENT="$(sed -e ':a' -e 'N' -e '$!ba' -e 's/"/\\"/g' -e 's/\n/ /g' "${KEY_PATH}.pub")"
PAYLOAD="{\"pubkey\":\"${PUBKEY_CONTENT}\",\"principal\":\"${PRINCIPAL}\",\"ttl\":${TTL}}"

# build curl invocation
CURL_ARGS=()
[ -n "${RESOLVE_OPT}" ] && CURL_ARGS+=("${RESOLVE_OPT}")
CURL_ARGS+=("-sS" "-H" "Host: ${DOMAIN}" "-H" "Authorization: Bearer ${TOKEN}" "-H" "Content-Type: application/json" "-X" "POST" "https://${DOMAIN}/sign-cert" "--data" "${PAYLOAD}")

# run curl and capture body
RESP="$("${CURL}" "${CURL_ARGS[@]}" 2>&1 || true)"
# If the response is multi-line with http code, we used -sS so it returns body only.
if [ -z "${RESP:-}" ]; then
  echo "curl failed or returned empty response: ${RESP}"
  exit 5
fi

# if jq present, parse .cert; else use python fallback
if [ -n "${JQ}" ]; then
  CERT_TEXT="$(printf "%s" "${RESP}" | jq -r .cert 2>/dev/null || true)"
else
  if [ -n "${PYTHON3}" ]; then
    CERT_TEXT="$(printf "%s" "${RESP}" | ${PYTHON3} -c "import sys, json; print(json.load(sys.stdin).get('cert',''))" 2>/dev/null || true)"
  else
    echo "Neither jq nor python3 available to parse JSON response; show response and exit:"
    printf "%s\n" "${RESP}"
    exit 6
  fi
fi

if [ -z "${CERT_TEXT}" ]; then
  echo "Failed to extract cert from server response. Server replied:"
  printf "%s\n" "${RESP}"
  exit 7
fi

# save cert
printf "%s\n" "${CERT_TEXT}" > "${CERT_PATH}"
chmod 600 "${CERT_PATH}"
chown root:root "${CERT_PATH}" || true
log "Saved certificate to ${CERT_PATH}"

# 4) Validate cert format with ssh-keygen -Lf
if ! "${SSHKEYGEN}" -Lf "${CERT_PATH}" >/dev/null 2>&1; then
  echo "ssh-keygen could not parse certificate (invalid format)."
  echo "Please re-run and inspect the raw response from the server."
  exit 8
fi
log "ssh-keygen parsed certificate OK"
"${SSHKEYGEN}" -Lf "${CERT_PATH}"

# 5) Query /whoami to discover remote port
log "Querying whoami to discover remote port"
WHOAMI_ARGS=()
[ -n "${RESOLVE_OPT}" ] && WHOAMI_ARGS+=("${RESOLVE_OPT}")
WHOAMI_ARGS+=("-sS" "-H" "Host: ${DOMAIN}" "-H" "Authorization: Bearer ${TOKEN}" "https://${DOMAIN}/whoami")
WHOAMI_RESP="$("${CURL}" "${WHOAMI_ARGS[@]}" 2>&1 || true)"
if [ -z "${WHOAMI_RESP}" ]; then
  echo "whoami query failed; response empty. Raw output:"
  echo "${WHOAMI_RESP}"
  exit 9
fi

if [ -n "${JQ}" ]; then
  REMOTE_PORT="$(printf "%s" "${WHOAMI_RESP}" | jq -r .port 2>/dev/null || true)"
else
  REMOTE_PORT="$(printf "%s" "${WHOAMI_RESP}" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
fi

if [ -z "${REMOTE_PORT}" ]; then
  echo "Failed to extract remote port from whoami response:"
  printf "%s\n" "${WHOAMI_RESP}"
  exit 10
fi

log "Discovered remote port: ${REMOTE_PORT}"

# 6) Show & optionally start autossh command
AUTOSSH_CMD=(autossh -M 0 -N -o "ExitOnForwardFailure=yes" \
  -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
  -i "${KEY_PATH}" -o "CertificateFile=${CERT_PATH}" \
  -R "127.0.0.1:${REMOTE_PORT}:localhost:${LOCAL_PORT}" "${PRINCIPAL}@${DOMAIN}")

echo
log "=== READY: autossh command ==="
printf '%s ' "${AUTOSSH_CMD[@]}"
echo
echo

if [ "${AUTO_START_AUTOSSH}" -eq 1 ]; then
  if [ -z "${AUTOSSH}" ]; then
    echo "autossh not found. Install it (apt install autossh) and re-run, or run the printed command with ssh."
    exit 11
  fi
  log "Starting autossh in background"
  # use setsid to detach, stdout/stderr redirected to journal via systemd-cat
  setsid "${AUTOSSH_CMD[@]}" >/dev/null 2>&1 &
  sleep 1
  if pgrep -f "autossh.*${PRINCIPAL}@${DOMAIN}" >/dev/null 2>&1; then
    log "autossh started successfully"
    echo "autossh started (detached). Check: sudo journalctl -u faas_register_tunnel.service -f or ps aux | grep autossh"
  else
    echo "autossh failed to start (check journal/system logs)."
    exit 12
  fi
else
  echo "AUTO_START_AUTOSSH disabled. To start the tunnel, run the printed command as root (or the right user)."
fi

log "Setup complete"
echo "Done. Tunnel should be available at https://${DOMAIN}/${USERNAME} (once server nginx routes are present)."
