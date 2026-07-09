# ================================================================
#  CloudDrive Installer
#  Serves all PC drives via FileBrowser + Cloudflare Tunnel
#  Run as Administrator in PowerShell
#  GitHub: https://github.com/HackMe7822/clouddrive-setup
# ================================================================

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Please run as Administrator." -ForegroundColor Red
    pause; exit 1
}

# ---- CONFIG ----
$SUBDOMAIN   = "files.yourdomain.com"   # <-- change this
$TUNNEL_NAME = "files-drive"            # tunnel name (created if not found)
$ADMIN_USER  = "admin"
$ADMIN_PASS  = "ChangeMe@123"           # change after install
$FB_PORT     = 8080
$INSTALL_DIR = "C:\CloudDrive"
$CLOUD_ROOT  = "C:\CloudRoot"
$CF_DIR      = "$env:USERPROFILE\.cloudflared"
# ---- END CONFIG ----

function Write-Step($n, $total, $msg) {
    Write-Host ""
    Write-Host "[$n/$total] $msg" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  CloudDrive Installer" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# ================================================================
# STEP 1 - Directories
# ================================================================
Write-Step 1 7 "Creating directories..."
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CLOUD_ROOT  | Out-Null
Write-Host "  OK" -ForegroundColor Green

# ================================================================
# STEP 2 - FileBrowser
# ================================================================
Write-Step 2 7 "FileBrowser..."
$fbExe = "$INSTALL_DIR\filebrowser.exe"
if (-not (Test-Path $fbExe)) {
    Write-Host "  Downloading FileBrowser..." -ForegroundColor Gray
    $fbUrl = "https://github.com/filebrowser/filebrowser/releases/download/v2.32.0/windows-amd64-filebrowser.zip"
    Invoke-WebRequest -Uri $fbUrl -OutFile "$INSTALL_DIR\fb.zip" -UseBasicParsing
    Expand-Archive -Path "$INSTALL_DIR\fb.zip" -DestinationPath $INSTALL_DIR -Force
    Remove-Item "$INSTALL_DIR\fb.zip"
    Write-Host "  Downloaded." -ForegroundColor Green
} else {
    Write-Host "  Already installed, skipping download." -ForegroundColor Gray
}

# ================================================================
# STEP 3 - Map all drives + DriveWatcher task
# ================================================================
Write-Step 3 7 "Mapping all drives to CloudRoot..."
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\" }
foreach ($drive in $drives) {
    $jp = "$CLOUD_ROOT\$($drive.Name)-Drive"
    if (Test-Path $jp) { Remove-Item $jp -Force -Recurse -ErrorAction SilentlyContinue }
    & cmd /c "mklink /J `"$jp`" `"$($drive.Root)`"" | Out-Null
    Write-Host "  $($drive.Name): -> $jp" -ForegroundColor Green
}

# DriveWatcher - auto-maps new drives every 5 min
$watcherScript = @'
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\" }
foreach ($drive in $drives) {
    $jp = "C:\CloudRoot\$($drive.Name)-Drive"
    if (-not (Test-Path $jp)) {
        New-Item -ItemType Directory -Force -Path "C:\CloudRoot" | Out-Null
        & cmd /c "mklink /J `"$jp`" `"$($drive.Root)`""
    }
}
'@
$watcherScript | Set-Content "$INSTALL_DIR\drive-watcher.ps1" -Encoding UTF8

$dwCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $INSTALL_DIR\drive-watcher.ps1"
schtasks /delete /tn "DriveWatcher"     /f 2>$null
schtasks /delete /tn "DriveWatcherBoot" /f 2>$null
schtasks /create /tn "DriveWatcher"     /tr $dwCmd /sc MINUTE /mo 5  /ru SYSTEM /rl HIGHEST /f | Out-Null
schtasks /create /tn "DriveWatcherBoot" /tr $dwCmd /sc ONSTART        /ru SYSTEM /rl HIGHEST /f | Out-Null
Write-Host "  DriveWatcher task registered (every 5 min + at boot)." -ForegroundColor Green

# ================================================================
# STEP 4 - FileBrowser init
# ================================================================
Write-Step 4 7 "Initializing FileBrowser..."
$dbPath = "$INSTALL_DIR\filebrowser.db"
if (Test-Path $dbPath) { Remove-Item $dbPath -Force }
& $fbExe config init --database $dbPath | Out-Null
& $fbExe config set --root $CLOUD_ROOT --address "127.0.0.1" --port $FB_PORT --database $dbPath | Out-Null
& $fbExe users add $ADMIN_USER $ADMIN_PASS --perm.admin --database $dbPath | Out-Null
Write-Host "  Initialized. Root: $CLOUD_ROOT" -ForegroundColor Green

# ================================================================
# STEP 5 - Cloudflare Tunnel
# ================================================================
Write-Step 5 7 "Setting up Cloudflare Tunnel..."

# Install cloudflared if missing
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing cloudflared..." -ForegroundColor Gray
    winget install Cloudflare.cloudflared --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}
$cfExe = (Get-Command cloudflared).Source

# Login if no cert
if (-not (Test-Path "$CF_DIR\cert.pem")) {
    Write-Host ""
    Write-Host "  ACTION: A browser will open — log into your Cloudflare account." -ForegroundColor Cyan
    Write-Host "  Press Enter when done..." -ForegroundColor Cyan
    & $cfExe tunnel login
    Read-Host "  Press Enter to continue"
}

# Find or create tunnel credentials
$configPath  = "$INSTALL_DIR\config.yml"
$tunnelJson  = Get-ChildItem $CF_DIR -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "cert.json" } | Select-Object -First 1

if ($tunnelJson) {
    # Re-use existing tunnel
    $tunnelId   = ($tunnelJson.BaseName)
    $tunnelCred = $tunnelJson.FullName
    Write-Host "  Found existing tunnel: $tunnelId" -ForegroundColor Green
    Write-Host "  Using credentials: $($tunnelJson.Name)" -ForegroundColor Gray
} else {
    # Create new tunnel
    Write-Host "  Creating new tunnel '$TUNNEL_NAME'..." -ForegroundColor Gray
    & $cfExe tunnel create $TUNNEL_NAME 2>&1 | Out-Null
    $tunnelJson = Get-ChildItem $CF_DIR -Filter "*.json" | Where-Object { $_.Name -ne "cert.json" } | Select-Object -First 1
    $tunnelId   = ($tunnelJson.BaseName)
    $tunnelCred = $tunnelJson.FullName
    Write-Host "  Tunnel created: $tunnelId" -ForegroundColor Green
}

# Copy credentials to install dir (no spaces in path)
$localCred = "$INSTALL_DIR\tunnel.json"
Copy-Item $tunnelCred $localCred -Force

# Write config.yml
@"
tunnel: $tunnelId
credentials-file: $localCred

ingress:
  - hostname: $SUBDOMAIN
    service: http://localhost:$FB_PORT
  - service: http_status:404
"@ | Set-Content $configPath -Encoding UTF8
Write-Host "  config.yml written." -ForegroundColor Green

# ================================================================
# STEP 6 - DNS record via Cloudflare API
# ================================================================
Write-Step 6 7 "Configuring DNS record..."

$domain = ($SUBDOMAIN -split "\." | Select-Object -Last 2) -join "."
$subdName = ($SUBDOMAIN -split "\.")[0]
$cnameTarget = "$tunnelId.cfargotunnel.com"

Write-Host ""
Write-Host "  To auto-update DNS, provide a Cloudflare API token." -ForegroundColor Cyan
Write-Host "  Get one at: dash.cloudflare.com -> My Profile -> API Tokens" -ForegroundColor Gray
Write-Host "  Use template 'Edit zone DNS', add Zone:Read + Zone:DNS:Edit for $domain" -ForegroundColor Gray
Write-Host ""
$cfToken = Read-Host "  Paste API token (or press Enter to skip)"

if ($cfToken.Trim() -ne "") {
    $headers = @{ "Authorization" = "Bearer $($cfToken.Trim())"; "Content-Type" = "application/json" }
    try {
        # Get zone ID
        $zoneResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $headers
        $zoneId   = $zoneResp.result[0].id

        # Check if record exists
        $recResp  = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=CNAME&name=$SUBDOMAIN" -Headers $headers
        $body     = @{ type="CNAME"; name=$subdName; content=$cnameTarget; proxied=$true } | ConvertTo-Json

        if ($recResp.result.Count -gt 0) {
            $recId = $recResp.result[0].id
            Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$recId" -Method Put -Headers $headers -Body $body | Out-Null
            Write-Host "  DNS record UPDATED: $SUBDOMAIN -> $cnameTarget" -ForegroundColor Green
        } else {
            Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $body | Out-Null
            Write-Host "  DNS record CREATED: $SUBDOMAIN -> $cnameTarget" -ForegroundColor Green
        }
    } catch {
        Write-Host "  DNS update failed: $_" -ForegroundColor Red
        Write-Host "  Add manually: CNAME $subdName -> $cnameTarget (proxied ON)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Skipped. Add this DNS record manually in Cloudflare dashboard:" -ForegroundColor Yellow
    Write-Host "    Type:    CNAME" -ForegroundColor White
    Write-Host "    Name:    $subdName" -ForegroundColor White
    Write-Host "    Target:  $cnameTarget" -ForegroundColor White
    Write-Host "    Proxy:   ON (orange cloud)" -ForegroundColor White
}

# ================================================================
# STEP 7 - Scheduled tasks
# ================================================================
Write-Step 7 7 "Registering startup tasks..."

# FileBrowser
Unregister-ScheduledTask -TaskName "FileBrowser" -Confirm:$false -ErrorAction SilentlyContinue
$fbAction    = New-ScheduledTaskAction -Execute $fbExe -Argument "--database $dbPath"
$fbTrigger   = New-ScheduledTaskTrigger -AtStartup
$fbSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
$fbPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "FileBrowser" -Action $fbAction -Trigger $fbTrigger -Settings $fbSettings -Principal $fbPrincipal -Description "FileBrowser at localhost:$FB_PORT" | Out-Null
Start-ScheduledTask -TaskName "FileBrowser"
Write-Host "  FileBrowser task registered." -ForegroundColor Green

# Cloudflared
Unregister-ScheduledTask -TaskName "CloudflaredTunnel" -Confirm:$false -ErrorAction SilentlyContinue
$cfAction    = New-ScheduledTaskAction -Execute $cfExe -Argument "tunnel --config $configPath run"
$cfTrigger   = New-ScheduledTaskTrigger -AtStartup
$cfSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
$cfPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "CloudflaredTunnel" -Action $cfAction -Trigger $cfTrigger -Settings $cfSettings -Principal $cfPrincipal -Description "Cloudflare Tunnel -> $SUBDOMAIN" | Out-Null
Start-ScheduledTask -TaskName "CloudflaredTunnel"
Write-Host "  Cloudflared task registered." -ForegroundColor Green

# ================================================================
# DONE
# ================================================================
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  URL:      https://$SUBDOMAIN" -ForegroundColor Cyan
Write-Host "  Username: $ADMIN_USER" -ForegroundColor White
Write-Host "  Password: $ADMIN_PASS  <-- CHANGE THIS!" -ForegroundColor Red
Write-Host ""
Write-Host "  Drives mapped:" -ForegroundColor Yellow
foreach ($d in $drives) { Write-Host "    $($d.Name)-Drive -> $($d.Root)" -ForegroundColor White }
Write-Host ""
Write-Host "  New drives auto-detected every 5 minutes." -ForegroundColor Gray
Write-Host "=================================================" -ForegroundColor Green
