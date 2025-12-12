#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh
# Reverses the installation performed by install.sh.
# Stops and disables the systemd service, removes installed files,
# and cleans up the configuration and SSH keys.
#
# Run as root:
#   sudo bash uninstall.sh

echo "=== FAAS Tunnel Service Uninstaller ==="

# Check for root privileges
if (( EUID != 0 )); then
  echo "ERROR: Run this script with sudo or as root." >&2
  exit 1
fi

# Destination locations from install.sh
DST_CLIENT="/usr/local/sbin/faas_register_tunnel.sh"
DST_HELPER="/usr/local/sbin/fass_register_tunnel.sh"
DST_SERVICE_UNIT="/etc/systemd/system/faas_register_tunnel.service"
ENV_FILE="/etc/faas_register_tunnel.env"

# Generated keys/certs (assuming the systemd service runs as root,
# which uses /root/.ssh as the home directory for key storage,
# based on the faas_register_tunnel.sh script's default KEY path.)
ROOT_SSH_DIR="/root/.ssh"
KEY="$ROOT_SSH_DIR/bitone_key"
PUB="$KEY.pub"
CERT="$KEY-cert.pub"
LOGFILE="/root/wsl_tunnel.log" # Default log path when run as root

# --- 1. Stop and Disable Systemd Service ---
SERVICE_NAME="faas_register_tunnel.service"
echo "--> Stopping and disabling systemd service: $SERVICE_NAME"
systemctl stop "$SERVICE_NAME" || true
systemctl disable "$SERVICE_NAME" || true
systemctl daemon-reload

# --- 2. Remove Installed Files ---
echo "--> Removing installed files..."
for f in "$DST_CLIENT" "$DST_SERVICE_UNIT" "$DST_HELPER"; do
  if [ -f "$f" ]; then
    echo "    - Removing $f"
    rm -f "$f"
  fi
done

# --- 3. Remove Configuration and Logs ---
echo "--> Removing configuration and log files..."
if [ -f "$ENV_FILE" ]; then
  echo "    - Removing environment file $ENV_FILE"
  # Note: The user may want to back this up, but for a full uninstall, it is removed.
  rm -f "$ENV_FILE"
fi

# The log file location is /root/wsl_tunnel.log when the service runs as root.
if [ -f "$LOGFILE" ]; then
  echo "    - Removing log file $LOGFILE"
  rm -f "$LOGFILE"
fi

# --- 4. Remove SSH Keys and Certificate ---
echo "--> Removing generated SSH keys and certificate (root's .ssh directory)..."
for f in "$KEY" "$PUB" "$CERT"; do
  if [ -f "$f" ]; then
    echo "    - Removing $f"
    rm -f "$f"
  fi
done

echo
echo "UNINSTALL COMPLETE."
echo "The tunnel service, scripts, config, keys, and logs have been removed."
echo "If the token was compromised, inform the FAAS admin to revoke it."

exit 0