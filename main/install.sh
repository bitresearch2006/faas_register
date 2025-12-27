#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_SCRIPT="/usr/local/sbin/faas_register_tunnel.sh"
DST_SERVICE="/etc/systemd/system/faas_register_tunnel@.service"
ENV_DIR="/etc/faas_register_tunnel"

echo "── FAAS Tunnel Multi-User Installer ──"

read -rp "Linux username to run service (SERVICE_USER): " SERVICE_USER
read -rp "Domain (e.g. bitone.in): " DOMAIN
read -rp "Principal (SSH login user): " PRINCIPAL
read -rp "Local port to expose: " LOCAL_PORT
read -rsp "Token: " TOKEN
echo

#--------------------------------------------------------------------
# 1) Ensure Linux user exists (create if missing)
#--------------------------------------------------------------------
if ! id "$SERVICE_USER" &>/dev/null; then
  echo "User '$SERVICE_USER' does not exist."
  read -rp "Create user '$SERVICE_USER'? [y/N]: " ANS
  if [[ "$ANS" =~ ^[Yy]$ ]]; then
    adduser "$SERVICE_USER"
  else
    echo "Aborting. Please create user manually."
    exit 1
  fi
fi

# Get the user's home directory and group dynamically
SERVICE_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
SERVICE_GROUP=$(id -gn "$SERVICE_USER")

#--------------------------------------------------------------------
# 2) Create env file for this user
#--------------------------------------------------------------------
mkdir -p "$ENV_DIR"
ENV_FILE="$ENV_DIR/${SERVICE_USER}.env"

#--------------------------------------------------------------------
# 3. Install ENV file (owned by the SERVICE_USER)
#--------------------------------------------------------------------
cat >"$ENV_FILE" <<EOF
DOMAIN="$DOMAIN"
TOKEN="$TOKEN"
PRINCIPAL="$PRINCIPAL"
LOCAL_PORT=$LOCAL_PORT
RENEW_BEFORE=300
EOF
  
  # IMPORTANT: Change ownership so the service user can read it
chown "$SERVICE_USER:$SERVICE_GROUP" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "Env created: $ENV_FILE"

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
  sudo -u "$SERVICE_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "faas-$SERVICE_USER"
  echo "   Key generated at: $KEY_PATH"
else
  echo "   Key found at: $KEY_PATH"
fi

#--------------------------------------------------------------------
# 5. Install tunnel script
#--------------------------------------------------------------------
echo ""
echo "→ Installing tunnel script…"

cp "$BASE_DIR/faas_register_tunnel.sh" "$DST_SCRIPT"
chmod 755 "$DST_SCRIPT"

echo "Installed: $DST_SCRIPT"

#--------------------------------------------------------------------
# 6. Install systemd service & Patch User
#--------------------------------------------------------------------
echo ""
echo "→ Installing systemd service…"

cp "$BASE_DIR/faas_register_tunnel@.service" "$DST_SERVICE"
chmod 644 "$DST_SERVICE"

echo "Reloading systemd…"
systemctl daemon-reload
systemctl enable "faas_register_tunnel@${SERVICE_USER}.service"

echo
echo "✔ Installed for service user: $SERVICE_USER"
echo
echo "Start service:"
echo "  sudo systemctl start faas_register_tunnel@${SERVICE_USER}"
echo
echo "Logs:"
echo "  sudo journalctl -u faas_register_tunnel@${SERVICE_USER} -f"
