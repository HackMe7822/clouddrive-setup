# ================================================================
#  Nextcloud Installer for Windows
#  Personal cloud drive - accessible from anywhere via Cloudflare
#  Run as Administrator in PowerShell
#  GitHub: https://github.com/HackMe7822/clouddrive-setup
# ================================================================
#
#  EDIT THESE 3 LINES BEFORE RUNNING:
# ================================================================
$SUBDOMAIN  = "files.yourdomain.com"    # your public URL
$ADMIN_USER = "admin"                   # Nextcloud admin username
$ADMIN_PASS = "ChangeMe@123"            # Nextcloud admin password
# ================================================================

$INSTALL_DIR = "C:\CloudDrive"
$NC_DATA_DIR = "D:\NextcloudData"       # Nextcloud files (change drive if needed)
$NC_DB_DIR   = "D:\NextcloudDB"         # Database files
$NC_PORT     = 8080
$CF_DIR      = "$env:USERPROFILE\.cloudflared"
$COMPOSE_DIR = "$INSTALL_DIR\nextcloud"
$RESUME_FLAG = "$INSTALL_DIR\install-resume.flag"

# ---- Admin check ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run this script as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    pause; exit 1
}

function Write-Step($n, $total, $msg) {
    Write-Host ""
    Write-Host "[$n/$total] $msg" -ForegroundColor Yellow
}

$isResume = Test-Path $RESUME_FLAG

if (-not $isResume) {
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "  Nextcloud Cloud Drive Installer" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
}

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $NC_DATA_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $NC_DB_DIR   | Out-Null
New-Item -ItemType Directory -Force -Path $COMPOSE_DIR | Out-Null

# ================================================================
# STEP 1 - Docker Desktop
# ================================================================
Write-Step 1 6 "Docker Desktop..."

function Test-DockerRunning {
    docker info 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Wait-ForDocker($timeoutSec) {
    Write-Host "  Waiting for Docker daemon (up to $timeoutSec sec)..." -ForegroundColor Gray
    $elapsed = 0
    while ($elapsed -lt $timeoutSec) {
        Start-Sleep 5
        $elapsed += 5
        if (Test-DockerRunning) {
            Write-Host "  Docker is ready." -ForegroundColor Green
            return $true
        }
        Write-Host "  Still starting... ($elapsed/$timeoutSec sec)" -ForegroundColor Gray
    }
    return $false
}

if (Test-DockerRunning) {
    Write-Host "  Docker already running." -ForegroundColor Green
} else {
    $dockerDesktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    $dockerInstalled = Test-Path $dockerDesktop

    if (-not $dockerInstalled) {
        Write-Host "  Installing Docker Desktop via winget..." -ForegroundColor Gray
        winget install Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
        $dockerInstalled = Test-Path $dockerDesktop
    }

    if ($dockerInstalled) {
        Write-Host "  Starting Docker Desktop..." -ForegroundColor Gray
        Start-Process -FilePath $dockerDesktop
    }

    $ready = Wait-ForDocker 180

    if (-not $ready) {
        Write-Host ""
        Write-Host "  Docker Desktop may need you to accept a license or finish setup." -ForegroundColor Cyan
        Write-Host "  Please open Docker Desktop from your taskbar, accept any prompts," -ForegroundColor Cyan
        Write-Host "  wait for the whale icon to stop animating, then press Enter." -ForegroundColor Cyan
        Read-Host "  Press Enter to continue"
        $ready = Wait-ForDocker 60
    }

    if (-not $ready) {
        # Save flag and schedule resume after restart
        "pending" | Set-Content $RESUME_FLAG
        $scriptPath = $MyInvocation.MyCommand.Path
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" `
            -Name "NextcloudInstallResume" `
            -Value "powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File `"$scriptPath`""
        Write-Host ""
        Write-Host "  Docker needs a system restart (WSL2 setup)." -ForegroundColor Yellow
        Write-Host "  This script will AUTO-RESUME after you restart and log in." -ForegroundColor Green
        $choice = Read-Host "  Restart now? (Y/N)"
        if ($choice -eq "Y" -or $choice -eq "y") { Restart-Computer -Force }
        exit
    }
}

# Clean up resume state
Remove-Item $RESUME_FLAG -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "NextcloudInstallResume" -ErrorAction SilentlyContinue

# ================================================================
# STEP 2 - Remove FileBrowser (replaced by Nextcloud)
# ================================================================
Write-Step 2 6 "Removing FileBrowser..."
Stop-ScheduledTask -TaskName "FileBrowser" -ErrorAction SilentlyContinue
Stop-Process -Name "filebrowser" -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "FileBrowser" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  FileBrowser removed." -ForegroundColor Green

# ================================================================
# STEP 3 - Nextcloud via Docker Compose
# ================================================================
Write-Step 3 6 "Setting up Nextcloud containers..."

# Generate random DB passwords (no external dependencies)
$chars  = (65..90) + (97..122) + (48..57)
$dbPass = -join ($chars | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$dbRoot = -join ($chars | Get-Random -Count 24 | ForEach-Object { [char]$_ })

# Write docker-compose.yml
$composeFile = "$COMPOSE_DIR\docker-compose.yml"
@"
version: '3.8'

services:
  db:
    image: mariadb:10.11
    restart: always
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - $($NC_DB_DIR -replace '\\','/'):/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: $dbRoot
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: $dbPass
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  nextcloud:
    image: nextcloud:latest
    restart: always
    ports:
      - "127.0.0.1:${NC_PORT}:80"
    volumes:
      - $($NC_DATA_DIR -replace '\\','/'):/var/www/html
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: $dbPass
      NEXTCLOUD_ADMIN_USER: $ADMIN_USER
      NEXTCLOUD_ADMIN_PASSWORD: $ADMIN_PASS
      NEXTCLOUD_TRUSTED_DOMAINS: $SUBDOMAIN localhost 127.0.0.1
    depends_on:
      db:
        condition: service_healthy
"@ | Set-Content $composeFile -Encoding UTF8

Set-Location $COMPOSE_DIR
Write-Host "  Pulling images (this may take a few minutes)..." -ForegroundColor Gray
docker compose pull
Write-Host "  Starting containers..." -ForegroundColor Gray
docker compose up -d

Write-Host "  Containers started. Waiting for Nextcloud to initialize (~2 min)..." -ForegroundColor Gray
$elapsed = 0
while ($elapsed -lt 180) {
    Start-Sleep 10
    $elapsed += 10
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$NC_PORT/status.php" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) {
            Write-Host "  Nextcloud is up!" -ForegroundColor Green
            break
        }
    } catch {}
    Write-Host "  Initializing... ($elapsed sec)" -ForegroundColor Gray
}

# ================================================================
# STEP 4 - Cloudflare Tunnel
# ================================================================
Write-Step 4 6 "Cloudflare Tunnel..."

$cfExe = (Get-Command cloudflared -ErrorAction SilentlyContinue)
if (-not $cfExe) {
    Write-Host "  Installing cloudflared..." -ForegroundColor Gray
    winget install Cloudflare.cloudflared --silent --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    $cfExe = Get-Command cloudflared -ErrorAction SilentlyContinue
}
$cfBin = $cfExe.Source

# Login if no cert
if (-not (Test-Path "$CF_DIR\cert.pem")) {
    Write-Host "  A browser will open - log into your Cloudflare account." -ForegroundColor Cyan
    & $cfBin tunnel login
}

# Find or create tunnel credentials
$credJson = Get-ChildItem $CF_DIR -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "cert.json" } |
    Select-Object -First 1

$localCred = "$INSTALL_DIR\tunnel.json"

if ($credJson) {
    $tunnelId = $credJson.BaseName
    if (-not (Test-Path $localCred)) {
        Copy-Item $credJson.FullName $localCred -Force
    }
    Write-Host "  Using existing tunnel: $tunnelId" -ForegroundColor Green
} else {
    Write-Host "  Creating new tunnel..." -ForegroundColor Gray
    & $cfBin tunnel create files-drive 2>&1 | Out-Null
    $credJson = Get-ChildItem $CF_DIR -Filter "*.json" |
        Where-Object { $_.Name -ne "cert.json" } |
        Select-Object -First 1
    $tunnelId = $credJson.BaseName
    Copy-Item $credJson.FullName $localCred -Force
    Write-Host "  Tunnel created: $tunnelId" -ForegroundColor Green
}

# Write config.yml
$configPath = "$INSTALL_DIR\config.yml"
@"
tunnel: $tunnelId
credentials-file: $localCred

ingress:
  - hostname: $SUBDOMAIN
    service: http://localhost:$NC_PORT
  - service: http_status:404
"@ | Set-Content $configPath -Encoding UTF8

# Add DNS route via cloudflared
& $cfBin tunnel route dns --overwrite-dns $tunnelId $SUBDOMAIN 2>&1 | Out-Null
Write-Host "  Tunnel configured." -ForegroundColor Green

# ================================================================
# STEP 5 - DNS record via Cloudflare API
# ================================================================
Write-Step 5 6 "Cloudflare DNS..."

$domain      = ($SUBDOMAIN -split "\." | Select-Object -Last 2) -join "."
$subdName    = ($SUBDOMAIN -split "\.")[0]
$cnameTarget = "$tunnelId.cfargotunnel.com"

Write-Host ""
Write-Host "  Provide a Cloudflare API token to auto-update DNS." -ForegroundColor Cyan
Write-Host "  Get one at: dash.cloudflare.com -> My Profile -> API Tokens" -ForegroundColor Gray
Write-Host "  Template: Edit zone DNS | Permissions: Zone:Read + Zone:DNS:Edit" -ForegroundColor Gray
Write-Host ""
$cfToken = Read-Host "  Paste API token (or press Enter to skip)"

if ($cfToken.Trim() -ne "") {
    $headers = @{ "Authorization" = "Bearer $($cfToken.Trim())"; "Content-Type" = "application/json" }
    try {
        $zoneResp = Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $headers
        $zoneId   = $zoneResp.result[0].id
        $recResp  = Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=CNAME&name=$SUBDOMAIN" -Headers $headers
        $body     = @{ type="CNAME"; name=$subdName; content=$cnameTarget; proxied=$true } | ConvertTo-Json

        if ($recResp.result.Count -gt 0) {
            $recId = $recResp.result[0].id
            Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$recId" -Method Put -Headers $headers -Body $body | Out-Null
            Write-Host "  DNS record updated: $SUBDOMAIN -> $cnameTarget" -ForegroundColor Green
        } else {
            Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $body | Out-Null
            Write-Host "  DNS record created: $SUBDOMAIN -> $cnameTarget" -ForegroundColor Green
        }
    } catch {
        Write-Host "  DNS API failed. Add manually in Cloudflare dashboard:" -ForegroundColor Yellow
        Write-Host "    CNAME  $subdName  ->  $cnameTarget  (Proxied ON)" -ForegroundColor White
    }
} else {
    Write-Host "  Skipped. Add this record in Cloudflare dashboard:" -ForegroundColor Yellow
    Write-Host "    Type:   CNAME" -ForegroundColor White
    Write-Host "    Name:   $subdName" -ForegroundColor White
    Write-Host "    Target: $cnameTarget" -ForegroundColor White
    Write-Host "    Proxy:  ON (orange cloud)" -ForegroundColor White
}

# ================================================================
# STEP 6 - Startup tasks
# ================================================================
Write-Step 6 6 "Registering startup tasks..."

# DriveWatcher (auto-maps new drives to C:\CloudRoot every 5 min)
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

schtasks /delete /tn "DriveWatcher"      /f 2>$null
schtasks /delete /tn "DriveWatcherBoot"  /f 2>$null
$dwCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $INSTALL_DIR\drive-watcher.ps1"
schtasks /create /tn "DriveWatcher"     /tr $dwCmd /sc MINUTE /mo 5  /ru SYSTEM /rl HIGHEST /f | Out-Null
schtasks /create /tn "DriveWatcherBoot" /tr $dwCmd /sc ONSTART        /ru SYSTEM /rl HIGHEST /f | Out-Null
Write-Host "  DriveWatcher registered (every 5 min + at boot)." -ForegroundColor Green

# Cloudflared tunnel task
Unregister-ScheduledTask -TaskName "CloudflaredTunnel" -Confirm:$false -ErrorAction SilentlyContinue
$cfAction    = New-ScheduledTaskAction -Execute $cfBin -Argument "tunnel --config $configPath run"
$cfTrigger   = New-ScheduledTaskTrigger -AtStartup
$cfSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
$cfPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "CloudflaredTunnel" -Action $cfAction -Trigger $cfTrigger -Settings $cfSettings -Principal $cfPrincipal -Description "Cloudflare Tunnel -> $SUBDOMAIN" | Out-Null
Start-ScheduledTask -TaskName "CloudflaredTunnel" -ErrorAction SilentlyContinue
Write-Host "  Cloudflared tunnel task registered." -ForegroundColor Green

# Docker auto-starts on boot by default (no extra task needed)
# Make sure Docker Desktop launches on login
$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path $dockerDesktopExe) {
    $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Set-ItemProperty -Path $regPath -Name "DockerDesktop" -Value "`"$dockerDesktopExe`" -Autostart"
    Write-Host "  Docker Desktop set to launch on login." -ForegroundColor Green
}

# ================================================================
# DONE
# ================================================================
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  URL:       https://$SUBDOMAIN" -ForegroundColor Cyan
Write-Host "  Username:  $ADMIN_USER" -ForegroundColor White
Write-Host "  Password:  $ADMIN_PASS" -ForegroundColor White
Write-Host ""
Write-Host "  Data stored at:  $NC_DATA_DIR" -ForegroundColor Gray
Write-Host "  Database at:     $NC_DB_DIR" -ForegroundColor Gray
Write-Host ""
Write-Host "  New drives auto-detected every 5 minutes." -ForegroundColor Gray
Write-Host "  Nextcloud and tunnel start automatically on reboot." -ForegroundColor Gray
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  IMPORTANT: Change your password after first login!" -ForegroundColor Red
Write-Host "=================================================" -ForegroundColor Green
