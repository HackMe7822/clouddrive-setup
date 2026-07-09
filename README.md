# CloudDrive — Personal Cloud on Windows

Turn any Windows PC into a full cloud drive accessible from anywhere via Cloudflare Tunnel.

**Stack:** [Nextcloud](https://nextcloud.com) (in Docker) + [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — no port forwarding, no exposed IP, free Cloudflare tier.

## What you get

- Full Nextcloud — file manager, desktop sync app, mobile app, photo gallery
- User accounts with per-folder permissions
- File versioning and trash
- Upload/download from any browser or the Nextcloud desktop/mobile app
- HTTPS automatically via Cloudflare
- All PC drives accessible (auto-detects new drives every 5 min)
- Everything starts automatically on reboot

## Prerequisites

- Windows 10/11 (64-bit)
- A domain on Cloudflare DNS
- PowerShell running as Administrator

## Install — one script

### 1. Clone or download

```powershell
git clone https://github.com/HackMe7822/clouddrive-setup.git
cd clouddrive-setup
```

### 2. Edit the 3 config lines at the top of install.ps1

```powershell
$SUBDOMAIN  = "files.yourdomain.com"   # your public URL
$ADMIN_USER = "admin"
$ADMIN_PASS = "ChangeMe@123"           # use a strong password
```

### 3. Right-click install.ps1 → Run with PowerShell (as Administrator)

The script handles everything:
- Installs Docker Desktop if missing (handles restart automatically)
- Pulls and starts Nextcloud + MariaDB containers
- Removes any existing FileBrowser setup
- Reuses existing Cloudflare Tunnel or creates a new one
- Updates your Cloudflare DNS record (prompts for API token)
- Registers all startup tasks

If a restart is needed (first-time Docker/WSL2 setup), the script auto-resumes after you log back in.

### 4. Cloudflare API token (optional but recommended)

When prompted, create a token at **dash.cloudflare.com → My Profile → API Tokens**:
- Template: **Edit zone DNS**
- Permissions: **Zone:Read** + **Zone:DNS:Edit**
- Zone: your domain only

If you skip this, add the CNAME manually in the Cloudflare dashboard (the script prints exactly what to add).

## File locations

```
C:\CloudDrive\
  config.yml          Cloudflare Tunnel config
  tunnel.json         Tunnel credentials (keep secret)
  drive-watcher.ps1   Auto-maps new drives every 5 min

C:\CloudDrive\nextcloud\
  docker-compose.yml  Nextcloud + MariaDB container config

D:\NextcloudData\     Nextcloud files (user uploads, config)
D:\NextcloudDB\       MariaDB database files

C:\CloudRoot\
  C-Drive\            Junction -> C:\
  D-Drive\            Junction -> D:\
  (new drives appear here automatically)
```

## Adding a drive manually

```powershell
# Run as Administrator
mklink /J "C:\CloudRoot\E-Drive" "E:\"
```

Shows up in Nextcloud within seconds — no restart needed.

## Managing containers

```powershell
cd C:\CloudDrive\nextcloud

docker compose ps          # check status
docker compose restart     # restart both containers
docker compose down        # stop
docker compose up -d       # start
docker compose logs -f     # view logs
```

## Updating Nextcloud

```powershell
cd C:\CloudDrive\nextcloud
docker compose pull
docker compose up -d
```
