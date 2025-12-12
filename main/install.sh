#!/usr/bin/env bash
set -euo pipefail

echo "────────────────────────────────────────────"
echo " FAAS WSL Tunnel Installer"
echo "────────────────────────────────────────────"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

SRC_SCRIPT="$BASE_DIR/faas_register_tunnel.sh"
SRC_SERVICE="$BASE_DIR/faas_register_tunnel.service"

DST_SCRIPT="/usr/local/sbin/faas_wsl_tunnel.sh"
DST_SERVICE="/etc/systemd/system/faas_wsl_tunnel.service"
ENV_FILE="/etc/faas_register_tunnel.env"

#--------------------------------------------------------------------
# Require root privileges
#--------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "   sudo bash install.sh"
  exit 1
fi

#--------------------------------------------------------------------
backup_if_exists() {
  if [[ -f "$1" ]]; then
    cp "$1" "$1.bak.$(date +%s)"
    echo "Backup created: $1.bak.$(date +%s)"
  fi
}

#--------------------------------------------------------------------
# 1. Verify source files exist
#--------------------------------------------------------------------
if [[ ! -f "$SRC_SCRIPT" ]]; then
  echo "ERROR: Missing script in current directory: $SRC_SCRIPT"
  exit 1
fi

if [[ ! -f "$SRC_SERVICE" ]]; then
  echo "ERROR: Missing service file in current directory: $SRC_SERVICE"
  exit 1
fi

#--------------------------------------------------------------------
# 2. Install ENV file (if missing)
#--------------------------------------------------------------------
echo ""
echo "→ Installing environment file…"

if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# REQUIRED — edit these before starting service
DOMAIN="bitone.in"
TOKEN=""
PRINCIPAL=""
USERNAME=""
LOCAL_PORT=8080
RENEW_BEFORE=300
EOF
  chmod 600 "$ENV_FILE"
  echo "Created: $ENV_FILE"
else
  echo "$ENV_FILE already exists — leaving untouched."
fi

#--------------------------------------------------------------------
# 3. Install tunnel script
#--------------------------------------------------------------------
echo ""
echo "→ Installing tunnel script…"

backup_if_exists "$DST_SCRIPT"
cp "$SRC_SCRIPT" "$DST_SCRIPT"
chmod 700 "$DST_SCRIPT"
chown root:root "$DST_SCRIPT"

echo "Installed: $DST_SCRIPT"

#--------------------------------------------------------------------
# 4. Install systemd service
#--------------------------------------------------------------------
echo ""
echo "→ Installing systemd service…"

backup_if_exists "$DST_SERVICE"
cp "$SRC_SERVICE" "$DST_SERVICE"
chmod 644 "$DST_SERVICE"

echo "Reloading systemd…"
systemctl daemon-reload

echo "Enabling service…"
systemctl enable faas_wsl_tunnel.service

echo ""
echo "────────────────────────────────────────────"
echo " ✔ Installation complete!"
echo ""
echo "Edit your env file:"
echo "  sudo nano /etc/faas_register_tunnel.env"
echo ""
echo "Start the service:"
echo "  sudo systemctl start faas_wsl_tunnel.service"
echo ""
echo "Watch logs:"
echo "  sudo journalctl -u faas_wsl_tunnel.service -f"
echo "────────────────────────────────────────────"
