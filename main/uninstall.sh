#!/usr/bin/env bash
set -euo pipefail

echo "────────────────────────────────────────────"
echo " FAAS register Tunnel — Uninstaller"
echo "────────────────────────────────────────────"

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash uninstall.sh"; exit 1; }

SERVICE_TEMPLATE="/etc/systemd/system/faas_register_tunnel@.service"
SCRIPT="/usr/local/sbin/faas_register_tunnel.sh"
ENV_DIR="/etc/faas_register_tunnel"

read -rp "Enter SERVICE_USER to uninstall (e.g. alice): " SERVICE_USER
SERVICE="faas_register_tunnel@${SERVICE_USER}.service"
ENV_FILE="${ENV_DIR}/${SERVICE_USER}.env"

echo ""
echo "→ Stopping service $SERVICE ..."
systemctl stop "$SERVICE" 2>/dev/null || true

echo "→ Disabling service $SERVICE ..."
systemctl disable "$SERVICE" 2>/dev/null || true

#--------------------------------------------------------------------
echo ""
echo "→ Removing env file ..."
if [[ -f "$ENV_FILE" ]]; then
  read -rp "Remove env file $ENV_FILE ? (y/N): " ANS
  if [[ "$ANS" =~ ^[Yy]$ ]]; then
    rm -f "$ENV_FILE"
    echo "✔ Removed $ENV_FILE"
  else
    echo "→ Keeping env file."
  fi
else
  echo "→ Env file not found, skipping."
fi

#--------------------------------------------------------------------
# Optional: remove Linux user
#--------------------------------------------------------------------
if id "$SERVICE_USER" &>/dev/null; then
  echo ""
  read -rp "Remove Linux user '$SERVICE_USER' and its home directory? (y/N): " ANS_USER
  if [[ "$ANS_USER" =~ ^[Yy]$ ]]; then
    userdel -r "$SERVICE_USER"
    echo "✔ User $SERVICE_USER removed."
  else
    echo "→ Keeping Linux user."
  fi
fi

#--------------------------------------------------------------------
# Check if any instances remain
#--------------------------------------------------------------------
echo ""
REMAINING=$(systemctl list-unit-files "faas_register_tunnel@*.service" --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -v '^faas_register_tunnel@\.service$' \
  | wc -l)

if (( REMAINING == 0 )); then
  echo "→ No remaining tunnel instances found."

  read -rp "Remove shared script and service template? (y/N): " ANS_SHARED
  if [[ "$ANS_SHARED" =~ ^[Yy]$ ]]; then
    rm -f "$SERVICE_TEMPLATE"
    rm -f "$SCRIPT"
    echo "✔ Removed shared files."
  else
    echo "→ Keeping shared files."
  fi
else
  echo "→ Other tunnel instances still exist. Keeping shared files."
fi

echo ""
echo "→ Reloading systemd..."
systemctl daemon-reload

echo ""
echo "────────────────────────────────────────────"
echo " ✔ Uninstall complete for: $SERVICE_USER"
echo ""
echo "You can verify with:"
echo "  systemctl status $SERVICE"
echo "────────────────────────────────────────────"
