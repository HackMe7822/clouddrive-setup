# CloudDrive Setup

Turn any Windows PC into a personal cloud drive accessible from anywhere via a Cloudflare Tunnel.

**Stack:** [FileBrowser](https://github.com/filebrowser/filebrowser) + [Cloudflare Tunnel](https://github.com/cloudflare/cloudflared) — no port forwarding, no exposed IP, free tier.

## What you get

- All PC drives accessible at your custom domain (e.g. `files.yourdomain.com`)
- HTTPS automatically via Cloudflare
- User management with per-folder permissions
- Upload, download, rename, delete from any browser
- Auto-starts on boot, auto-restarts if it crashes

## Prerequisites

- Windows 10/11
- A Cloudflare account with a domain pointed to Cloudflare DNS
- PowerShell running as Administrator

## Install

### 1. Clone this repo
```powershell
git clone https://github.com/HackMe7822/clouddrive-setup.git
cd clouddrive-setup
```

### 2. Edit config at the top of install.ps1
```powershell
$TUNNEL_NAME  = "files-drive"           # pick any name
$SUBDOMAIN    = "files.yourdomain.com"  # your domain
$ADMIN_PASS   = "ChangeMe@123"          # set a strong password
```

### 3. Set up Cloudflare Tunnel (one-time)
```powershell
cloudflared tunnel login
cloudflared tunnel create files-drive
cloudflared tunnel route dns files-drive files.yourdomain.com
```
Copy the generated credentials JSON to `C:\CloudDrive\tunnel.json` and update `config.yml`.

### 4. Run the installer as Administrator
```powershell
Right-click install.ps1 -> Run with PowerShell (as Administrator)
```

### 5. Add DNS record in Cloudflare dashboard
- Type: `CNAME`
- Name: `files`
- Target: `<tunnel-id>.cfargotunnel.com`
- Proxy: ON (orange cloud)

## File structure

```
C:\CloudDrive\
  filebrowser.exe     # FileBrowser binary
  filebrowser.db      # User accounts and config database
  config.yml          # Cloudflare Tunnel config
  tunnel.json         # Tunnel credentials (keep secret!)

C:\CloudRoot\
  C-Drive\            # Junction -> C:\
  D-Drive\            # Junction -> D:\
  (more drives auto-detected)
```

## User management

Settings -> Users in the FileBrowser web UI.

| Field | Example | Effect |
|-------|---------|--------|
| Scope | `D-Drive/Projects` | Limits user to that folder only |
| Admin | on/off | Full access vs restricted |
| Permissions | toggles | Create / Delete / Download etc |

## Adding new drives

Run as Administrator:
```powershell
mklink /J "C:\CloudRoot\E-Drive" "E:\"
```
The drive appears instantly in FileBrowser — no restart needed.

## Live file detection

FileBrowser reads the filesystem live. Any file added to a drive by any app or user shows up immediately on next refresh — no sync delay.
