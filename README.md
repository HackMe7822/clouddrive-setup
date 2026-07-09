# CloudDrive — Personal Cloud on Windows

Turn any Windows PC into a full cloud drive accessible from anywhere via Cloudflare Tunnel.

**Stack:** [Nextcloud](https://nextcloud.com) (native PHP + MariaDB + Caddy) + [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — no Docker, no port forwarding, no exposed IP, free Cloudflare tier.

## What you get

- Full Nextcloud — file manager, desktop sync app, mobile app, photo gallery
- User accounts with per-folder permissions
- File versioning and trash
- Upload/download from any browser or the Nextcloud desktop/mobile app
- HTTPS automatically via Cloudflare
- All PC drives accessible (C:, D:, any USB — auto-detected within 10 seconds)
- Everything starts automatically on reboot
- Works with **any DNS provider** (Cloudflare, GoDaddy, Namecheap, etc.)

## Prerequisites

- Windows 10/11 (64-bit)
- A domain at any DNS provider
- PowerShell running as Administrator

## Install — one script

### 1. Clone or download

```powershell
git clone https://github.com/HackMe7822/clouddrive-setup.git
cd clouddrive-setup
```

### 2. Edit the 3 lines at the top of install.ps1

```powershell
$SUBDOMAIN  = "files.yourdomain.com"   # your public URL
$ADMIN_USER = "admin"
$ADMIN_PASS = "ChangeMe@123"           # use a strong password
```

### 3. Right-click install.ps1 → Run with PowerShell (as Administrator)

The script handles everything automatically:
- Installs PHP, MariaDB, Caddy via winget
- Configures PHP and the database
- Downloads and installs Nextcloud
- Maps all current drives as External Storage
- Configures Caddy as the web server
- Reuses existing Cloudflare Tunnel or creates a new one
- Updates your DNS record (auto via API token, or prints the CNAME to add manually)
- Registers all startup tasks so everything restarts on reboot
- Starts the USB watcher (detects new drives within 10 seconds)

### 4. DNS record (Cloudflare auto or any provider manually)

When prompted, enter a Cloudflare API token to update DNS automatically:
- **dash.cloudflare.com → My Profile → API Tokens → Edit zone DNS** template
- Permissions: Zone:Read + Zone:DNS:Edit

Or press Enter to skip — the script prints the exact CNAME to add at any DNS provider.

## File locations

```
C:\CloudDrive\
  config.yml          Cloudflare Tunnel config
  tunnel.json         Tunnel credentials (keep secret)
  Caddyfile           Web server config
  db.env              Database password (keep secret)
  usb-watcher.ps1     USB drive detection daemon
  known-drives.json   USB watcher state file
  usb-watcher.log     USB watcher log

C:\Nextcloud\         Nextcloud app files (PHP)
D:\NextcloudData\     User files and uploads
```

## USB plug and play

Plug in any USB drive — it appears in Nextcloud within 10 seconds.
No restart needed. The USB watcher runs continuously in the background.

## Startup tasks (auto-registered by install.ps1)

| Task | What it runs |
|------|-------------|
| PhpCgi | PHP FastCGI server (port 9123) |
| CaddyServer | Caddy web server (port 8080) |
| CloudflaredTunnel | Cloudflare Tunnel to your domain |
| UsbWatcher | Detects drive changes every 10 sec |

## Managing the services

```powershell
# Check status
schtasks /query /tn "CaddyServer" /fo list
schtasks /query /tn "CloudflaredTunnel" /fo list

# Restart a service
schtasks /end /tn "CaddyServer"; schtasks /run /tn "CaddyServer"

# View USB watcher log
Get-Content C:\CloudDrive\usb-watcher.log -Tail 20

# Run occ commands (Nextcloud admin CLI)
php C:\Nextcloud\occ status
php C:\Nextcloud\occ files_external:list
```

## Updating Nextcloud

```powershell
# Download latest zip, extract to C:\Nextcloud, then:
php C:\Nextcloud\occ upgrade
```
