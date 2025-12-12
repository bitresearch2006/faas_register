#!/usr/bin/env bash
set -euo pipefail

# install_faas_tunnel_service.sh
# Idempotent installer for the faas register tunnel service (system-wide).
# Place this installer in the same directory as:
#   - faas_register_tunnel.sh
#   - faas_register_tunnel.service
#
# Run as root:
#   sudo bash install.sh

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source filenames (must exist)
SRC_CLIENT="$SRC_DIR/faas_register_tunnel.sh"        # renamed client
SRC_SERVICE_UNIT="$SRC_DIR/faas_register_tunnel.service"

# Destination locations (system-wide)
DST_CLIENT="/usr/local/sbin/faas_register_tunnel.sh"
DST_HELPER="/usr/local/sbin/fass_register_tunnel.sh"
DST_SERVICE_UNIT="/etc/systemd/system/faas_register_tunnel.service"

# Environment file (global)
ENV_FILE="/etc/wsl_tunnel.env"

echo "=== FAAS Tunnel Service Installer ==="

if (( EUID != 0 )); then
  echo "ERROR: Run this script with sudo or as root." >&2
  exit 1
fi

# Verify source files exist
for f in "$SRC_CLIENT" "$SRC_SERVICE_UNIT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found in current directory: $f" >&2
    exit 2
  fi
done

echo "--> Installing client script to $DST_CLIENT"
cp -f "$SRC_CLIENT" "$DST_CLIENT"
chmod 700 "$DST_CLIENT"
chown root:root "$DST_CLIENT"

echo "--> Installing systemd unit to $DST_SERVICE_UNIT"
cp -f "$SRC_SERVICE_UNIT" "$DST_SERVICE_UNIT"
chmod 644 "$DST_SERVICE_UNIT"
chown root:root "$DST_SERVICE_UNIT"

# Create secure env file template if missing
if [ ! -f "$ENV_FILE" ]; then
  echo "--> Creating environment template at $ENV_FILE (fill values before starting service)"
  cat > "$ENV_FILE" <<'ENV'
# /etc/wsl_tunnel.env - global env for faas_register_tunnel.sh
# REQUIRED: set TOKEN to the value admin gave you.
DOMAIN="bitone.in"
TOKEN="PASTE_YOUR_TOKEN_HERE"
PRINCIPAL="bitresearch"
USERNAME="alice"     # logical username part of URL (eg /alice)
LOCAL_PORT=8080      # local port on WSL to expose
RENEW_BEFORE=300     # seconds before cert expiry to renew
ENV
  chmod 600 "$ENV_FILE"
  chown root:root "$ENV_FILE"
else
  echo "--> Environment file $ENV_FILE already exists — leaving intact."
fi

echo "--> Reloading systemd and enabling service"
systemctl daemon-reload

# Enable & start service (idempotent)
systemctl enable --now faas_register_tunnel.service || true

sleep 1
echo
echo "--> Service status (short):"
systemctl status --no-pager --full faas_register_tunnel.service || true

cat <<EOF

INSTALL COMPLETE — NEXT STEPS:

1) Edit /etc/wsl_tunnel.env and set the TOKEN and any other values:
   sudo nano /etc/wsl_tunnel.env
   (Ensure the file remains root-only:)
   sudo chmod 600 /etc/wsl_tunnel.env

2) Check logs to confirm the service started correctly:
   sudo journalctl -u faas_register_tunnel.service -f

3) Manually test the client script (optional):
   sudo /usr/local/sbin/faas_register_tunnel.sh start
   # or to run the renewal daemon manually:
   sudo /usr/local/sbin/faas_register_tunnel.sh daemon

4) If service fails to start, check:
   - /etc/wsl_tunnel.env for correct TOKEN & DOMAIN
   - that /usr/local/sbin/faas_register_tunnel.sh is executable (permission 700)
   - system journal: sudo journalctl -u faas_register_tunnel.service

5) To stop & disable the service:
   sudo systemctl stop faas_register_tunnel.service
   sudo systemctl disable faas_register_tunnel.service

Notes:
- The installer copies your uploaded files; it does NOT alter them.
- The service runs as root and reads /etc/wsl_tunnel.env. Keep that file secure (600).
- You can change the service unit name or paths if desired.

EOF

exit 0
