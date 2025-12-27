# FAAS Client Tunnel — Multi-User Reverse SSH Registration System

This client package enables any Linux/WSL machine to securely register itself
with a FAAS VM and expose a local service (e.g., on port 8080) over HTTPS using
short-lived SSH certificates and a persistent reverse SSH tunnel.

The v2 design supports **multiple tunnels on the same machine**, each isolated
by a dedicated Linux user and systemd service instance.

---

## ✨ Key Features

- Obtain short-lived SSH certificates from the FAAS server using a token
- Discover assigned remote TCP port dynamically via `/whoami`
- Create a secure reverse SSH tunnel to the VM
- Expose a local service at:

https://bitone.in/<username>

yaml
Copy code

- Auto-renew certificates before expiry
- Auto-reconnect tunnels on failure and reboot
- **Multi-user support**: one tunnel per Linux user
- systemd-managed, no manual daemon handling

---

## 📁 Files Included

| File                          | Purpose |
|-------------------------------|---------|
| `faas_register_tunnel.sh`     | Main tunnel client script. Handles cert request, renewal, port discovery, and SSH tunnel loop. |
| `faas_register_tunnel@.service` | systemd **template unit** to run one tunnel instance per Linux user. |
| `install.sh`                 | Interactive installer. Creates Linux user (if missing), env file, SSH key, installs and enables service. |
| `uninstall.sh`               | Removes a specific tunnel instance and optionally shared files and user. |

Installed locations:

/usr/local/sbin/faas_register_tunnel.sh
/etc/systemd/system/faas_register_tunnel@.service
/etc/faas_register_tunnel/<SERVICE_USER>.env

yaml
Copy code

---

## 🧠 How It Works

1. Admin provides you a **TOKEN**.
2. Installer creates (or uses) a Linux user, e.g. `alice`.
3. The client sends `alice`’s SSH public key + token to:

https://bitone.in/sign-cert

arduino
Copy code

4. Server returns a signed SSH certificate.
5. Client queries:

https://bitone.in/whoami

arduino
Copy code

to get the assigned remote port (e.g., `9004`).
6. Client opens a reverse tunnel:

local:8080 → vm:127.0.0.1:9004

markdown
Copy code

7. VM routes:

https://bitone.in/alice → 127.0.0.1:9004

yaml
Copy code

8. The script runs continuously:
- renews cert before expiry
- reconnects SSH if dropped
9. systemd ensures it runs on boot.

---

## 🔧 Installation

### Step 1 — Place files in a folder

Example:

~/faas-client/
├─ faas_register_tunnel.sh
├─ faas_register_tunnel@.service
├─ install.sh
└─ uninstall.sh

bash
Copy code

### Step 2 — Run installer

```bash
cd ~/faas-client
sudo bash install.sh
You will be prompted for:

SERVICE_USER → Linux user to run the tunnel (e.g., alice)

Domain → e.g., bitone.in

Principal → remote SSH login user

Local port → your local service port (e.g., 8080)

Token → provided by admin

If the Linux user does not exist, the installer will offer to create it.

The installer will:

Create /etc/faas_register_tunnel/<SERVICE_USER>.env

Generate SSH key for that user (if missing)

Install script and systemd template

Enable: faas_register_tunnel@<SERVICE_USER>.service

⚙️ Per-User Configuration
Each tunnel instance has its own env file:

bash
Copy code
/etc/faas_register_tunnel/<SERVICE_USER>.env
Example: /etc/faas_register_tunnel/alice.env

bash
Copy code
DOMAIN="bitone.in"
TOKEN="PASTE_TOKEN_HERE"
PRINCIPAL="bitresearch2006"
LOCAL_PORT=8080
RENEW_BEFORE=300
Permissions are restricted to the service user.

▶️ Managing the Service
Start:

bash
Copy code
sudo systemctl start faas_register_tunnel@alice
Stop:

bash
Copy code
sudo systemctl stop faas_register_tunnel@alice
Enable at boot:

bash
Copy code
sudo systemctl enable faas_register_tunnel@alice
Status:

bash
Copy code
sudo systemctl status faas_register_tunnel@alice
You can repeat installation for other users (e.g., bob, carol) to run
multiple tunnels in parallel.

🔍 Logs & Monitoring
View logs for a user:

bash
Copy code
sudo journalctl -u faas_register_tunnel@alice -f
Check certificate:

bash
Copy code
sudo ssh-keygen -Lf /home/alice/.ssh/bitone_key-cert.pub
🌐 Accessing Your Service
Once connected:

php-template
Copy code
https://bitone.in/<SERVICE_USER>
Example:

arduino
Copy code
https://bitone.in/alice
This maps to:

php-template
Copy code
alice's localhost:<LOCAL_PORT>
🛡 Security Notes
Env files are user-specific and protected (600).

Tokens grant cert signing — keep them secret.

Certificates are short-lived and auto-renewed.

Each tunnel runs as its own Linux user for isolation.

Only the specified local port is exposed via reverse tunnel.

❗ Troubleshooting
Service fails to start

bash
Copy code
sudo journalctl -u faas_register_tunnel@alice -f
Common causes:

Invalid TOKEN

Wrong PRINCIPAL

Local service not running on LOCAL_PORT

Server unreachable

Tunnel up but no external access

On VM, admin should verify:

user/port mapping

NGINX route for the user

/whoami returns invalid

Token may be revoked or not registered.

🧹 Uninstall
To remove a specific tunnel:

bash
Copy code
sudo bash uninstall.sh
Enter:

ini
Copy code
SERVICE_USER = alice
The uninstaller will:

Stop & disable faas_register_tunnel@alice

Optionally remove /etc/faas_register_tunnel/alice.env

Optionally remove Linux user alice

Optionally remove shared files if no instances remain