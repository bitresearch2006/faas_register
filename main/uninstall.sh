#!/usr/bin/env bash
set -euo pipefail

echo "────────────────────────────────────────────"
echo " FAAS WSL Tunnel — Uninstaller"
echo "────────────────────────────────────────────"

SERVICE="/etc/systemd/system/faas_wsl_tunnel.service"
SCRIPT="/usr/local/sbin/faas_wsl_tunnel.sh"
ENV_FILE="/etc/faas_register_tunnel.env"

#--------------------------------------------------------------------
# Require root
#--------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo:"
  echo "   sudo bash uninstall.sh"
  exit 1
fi

#--------------------------------------------------------------------
stop_and_disable() {
  if systemctl list-unit-files | grep -q "faas_wsl_tunnel.service"; then
    echo "→ Stopping service…"
    systemctl stop faas_wsl_tunnel.service 2>/dev/null || true
    echo "→ Disabling service…"
    systemctl disable faas_wsl_tunnel.service 2>/dev/null || true
  fi
}

#--------------------------------------------------------------------
remove_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    echo "→ Removing $f"
    rm -f "$f"
  else
    echo "→ Skipping $f (not found)"
  fi
}

#--------------------------------------------------------------------
# Begin uninstall
#--------------------------------------------------------------------
stop_and_disable

echo ""
echo "→ Removing installed files…"
remove_file "$SERVICE"
remove_file "$SCRIPT"

echo ""
echo "→ Reloading systemd…"
systemctl daemon-reload

#--------------------------------------------------------------------
# ENV file (optional)
#--------------------------------------------------------------------
echo ""
if [[ -f "$ENV_FILE" ]]; then
  read -r -p "Remove env file $ENV_FILE ? (y/N): " ANSWER
  if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    rm -f "$ENV_FILE"
    echo "→ Environment file removed."
  else
    echo "→ Keeping environment file."
  fi
else
  echo "→ Env file not found, skipping."
fi

echo ""
echo "────────────────────────────────────────────"
echo " ✔ Uninstall complete."
echo ""
echo "You can verify:"
echo "  systemctl status faas_wsl_tunnel.service"
echo "────────────────────────────────────────────"
