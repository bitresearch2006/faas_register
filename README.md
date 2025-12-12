FAAS Client Tunnel — WSL Registration & Reverse Tunnel System

This client-side package enables any WSL machine to automatically:

Obtain a short-lived SSH certificate from the FAAS VM using a token

Discover its assigned remote TCP port dynamically via /whoami

Create a secure reverse SSH tunnel to the VM

Expose a local service (e.g., chatbot on port 8080) at a URL:

https://bitone.in/<username>


Renew the certificate automatically before expiry

Re-establish the tunnel automatically, including after reboot

This allows your WSL workstation to “register” itself with the remote VM and stay connected securely without manual steps.

📁 Files Included
File	Purpose
faas_register_tunnel.sh	Main WSL client script. Requests cert, discovers port, establishes autossh tunnel, renews certs.
faas_register_tunnel.service	systemd service file to auto-start tunnel on boot.
fass_register_tunnel.sh	Optional helper utility script used internally or by admin tooling.
install.sh	Installer script to copy files, create environment config, enable systemd service.

All scripts are root-only and run under /usr/local/sbin.

🚀 How It Works (Summary)

You obtain a token from the server admin.

The client script sends your SSH public key + token to:

https://bitone.in/sign-cert


The server signs the key with its SSH CA and returns a certificate.

The client calls:

https://bitone.in/whoami


which returns:

your registered username

your assigned reverse-tunnel port (e.g., 9004)

The client starts an autossh reverse tunnel:

WSL:8080  →  VM:127.0.0.1:9004


The VM’s NGINX routes:

https://bitone.in/<username>  → 127.0.0.1:9004


The client script monitors certificate expiry and renews automatically.

systemd ensures the service reconnects on boot and after any interruption.

🔧 Installation
Step 1 — Place all files in one folder on WSL

Example:

~/faas-client/
  ├─ faas_register_tunnel.sh
  ├─ faas_register_tunnel.service
  └─ install.sh

Step 2 — Run the installer
cd ~/faas-client
sudo bash install.sh


The installer will:

Copy scripts into /usr/local/sbin/

Install the systemd unit into /etc/systemd/system/

Create the env file /etc/wsl_tunnel.env (secure permissions)

Enable + start the system service

Show its status

⚙️ Configure the Client

After installation, edit:

sudo nano /etc/wsl_tunnel.env


Example:

DOMAIN="bitone.in"
TOKEN="PASTE_YOUR_TOKEN_HERE"
PRINCIPAL="bitresearch"
USERNAME="alice"     # must match VM registration
LOCAL_PORT=8080
RENEW_BEFORE=300     # renew 5 minutes before expiry


Required:

TOKEN ← provided by the FAAS admin

USERNAME ← the VM maps this to a specific route

LOCAL_PORT ← your local chatbot/service port

Save and ensure:

sudo chmod 600 /etc/wsl_tunnel.env

▶️ Running the Client Manually (Optional)
Start the tunnel once:
sudo faas_register_tunnel.sh start

Begin the continuous renewal daemon:
sudo faas_register_tunnel.sh daemon

Stop tunnel:
sudo faas_register_tunnel.sh stop

Show status:
sudo faas_register_tunnel.sh status

🔁 Automatic Startup via Systemd

The installer already enabled the service.
To check:

sudo systemctl status faas_register_tunnel.service


To manually enable:

sudo systemctl enable --now faas_register_tunnel.service


To stop:

sudo systemctl stop faas_register_tunnel.service


To disable:

sudo systemctl disable faas_register_tunnel.service

🔍 Monitoring & Logs
View live logs:
sudo journalctl -u faas_register_tunnel.service -f


Look for:

cert renewal

autossh reconnect

tunnel established

discovery of remote port

Check cert info:
sudo ssh-keygen -L -f /root/.ssh/bitone_key-cert.pub

Check autossh is running:
ps aux | grep autossh

🌐 Accessing Your Exposed Service

Once connected, your local WSL service becomes public at:

https://bitone.in/<USERNAME>


Example:

https://bitone.in/alice

🛡 Security Notes

/etc/wsl_tunnel.env must be root-only (600).

Your token grants access to certificate signing — keep it secret.

The certificate TTL is short-lived; renewal maintains security.

Root permissions are required because the tunnel modifies SSH behavior.

autossh is sandboxed and only exposes local > VM tunnels; VM cannot reach your WSL system outside that port.

❗ Troubleshooting
1. Service fails to start

Check logs:

sudo journalctl -u faas_register_tunnel.service -f


Common causes:

Wrong TOKEN

Missing LOCAL_PORT service

VM unreachable

Certificate signing failed

2. Tunnel up but no external access

On VM, the admin should check:

/etc/tunnel/user_ports.json
/etc/nginx/conf.d/users/<username>.conf

3. Can’t discover remote port

Means /whoami is returning 403 → token is invalid or revoked.

✔️ Summary

This client system:

Registers WSL with the remote FAAS platform

Automatically provisions SSH certificates

Discovers tunnel port dynamically

Maintains a persistent reverse tunnel

Exposes your local service over HTTPS

Survives reboots

Requires zero manual intervention after setup
