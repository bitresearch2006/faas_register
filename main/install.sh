#!/usr/bin/env bash
set -euo pipefail

echo "────────────────────────────────────────────"
echo " FAAS register Tunnel Installer"
echo "────────────────────────────────────────────"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

SRC_SCRIPT="$BASE_DIR/faas_register_tunnel.sh"
SRC_SERVICE="$BASE_DIR/faas_register_tunnel.service"

DST_SCRIPT="/usr/local/sbin/faas_register_tunnel.sh"
DST_SERVICE="/etc/systemd/system/faas_register_tunnel.service"
ENV_FILE="/etc/faas_register_tunnel.env"

#--------------------------------------------------------------------
# 1. Detect the Real User (who ran sudo)
#--------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "   sudo bash install.sh"
  exit 1
fi

# $SUDO_USER holds the username of the person who ran sudo
# Fallback to $USER if logged in as root directly
SERVICE_USER="${SUDO_USER:-$USER}"

# Get the user's home directory and group dynamically
SERVICE_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
SERVICE_GROUP=$(id -gn "$SERVICE_USER")

echo "→ Configuring service for user: $SERVICE_USER ($SERVICE_HOME)"

#--------------------------------------------------------------------
backup_if_exists() {
  if [[ -f "$1" ]]; then
    cp "$1" "$1.bak.$(date +%s)"
    echo "Backup created: $1.bak.$(date +%s)"
  fi
}

#--------------------------------------------------------------------
# 2. Verify source files exist
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
# 3. Install ENV file (owned by the SERVICE_USER)
#--------------------------------------------------------------------
echo ""
echo "→ Installing environment file…"

if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<EOF
# REQUIRED — edit these before starting service
DOMAIN="bitone.in"
TOKEN=""
PRINCIPAL=""
USERNAME=""
LOCAL_PORT=8080
RENEW_BEFORE=300
EOF
  
  # IMPORTANT: Change ownership so the service user can read it
  chown "$SERVICE_USER":"$SERVICE_GROUP" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created: $ENV_FILE (Owned by $SERVICE_USER)"
else
  echo "$ENV_FILE already exists — ensuring correct ownership."
  chown "$SERVICE_USER":"$SERVICE_GROUP" "$ENV_FILE"
fi

#--------------------------------------------------------------------
# 4. Check/Generate SSH Key for SERVICE_USER
#--------------------------------------------------------------------
echo ""
echo "→ Checking SSH key for $SERVICE_USER…"

KEY_PATH="$SERVICE_HOME/.ssh/bitone_key"

if [[ ! -f "$KEY_PATH" ]]; then
  echo "   Key missing. Generating new ED25519 key..."
  # Run ssh-keygen as the actual user to get permissions right automatically
  sudo -u "$SERVICE_USER" mkdir -p "$SERVICE_HOME/.ssh"
  sudo -u "$SERVICE_USER" chmod 700 "$SERVICE_HOME/.ssh"
  sudo -u "$SERVICE_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "faas-tunnel"
  echo "   Key generated at: $KEY_PATH"
else
  echo "   Key found at: $KEY_PATH"
fi

#--------------------------------------------------------------------
# 5. Install tunnel script
#--------------------------------------------------------------------
echo ""
echo "→ Installing tunnel script…"

backup_if_exists "$DST_SCRIPT"
cp "$SRC_SCRIPT" "$DST_SCRIPT"
chmod 700 "$DST_SCRIPT"
chown root:root "$DST_SCRIPT"

echo "Installed: $DST_SCRIPT"

#--------------------------------------------------------------------
# 6. Install systemd service & Patch User
#--------------------------------------------------------------------
echo ""
echo "→ Installing systemd service…"

backup_if_exists "$DST_SERVICE"
cp "$SRC_SERVICE" "$DST_SERVICE"

# DYNAMICALLY UPDATE THE USER IN THE SERVICE FILE
# This replaces "User=..." with "User=actual_user"
sed -i "s/^User=.*/User=$SERVICE_USER/" "$DST_SERVICE"

chmod 644 "$DST_SERVICE"

echo "Reloading systemd…"
systemctl daemon-reload

echo "Enabling service…"
systemctl enable faas_register_tunnel.service

echo ""
echo "────────────────────────────────────────────"
echo " ✔ Installation complete for user: $SERVICE_USER"
echo ""
echo "Edit your env file:"
echo "  sudo nano $ENV_FILE"
echo ""
echo "Start the service:"
echo "  sudo systemctl start faas_register_tunnel.service"
echo ""
echo "Watch logs:"
echo "  sudo journalctl -u faas_register_tunnel.service -f"
echo "────────────────────────────────────────────"