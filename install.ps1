# ================================================================
#  CloudDrive Installer - files.creationsit.com
#  Run as Administrator in PowerShell
#  GitHub: https://github.com/HackMe7822/clouddrive-setup
# ================================================================

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Please run this script as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    pause; exit 1
}

# ---- CONFIG (edit these before running) ----
$TUNNEL_NAME     = "files-drive"           # Your cloudflared tunnel name
$SUBDOMAIN       = "files.creationsit.com" # Your public URL
$ADMIN_USER      = "admin"
$ADMIN_PASS      = "ChangeMe@123"          # CHANGE THIS after install
$FB_PORT         = 8080
$INSTALL_DIR     = "C:\CloudDrive"
$CLOUD_ROOT      = "C:\CloudRoot"
# ---- END CONFIG ----------------------------

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  CloudDrive Installer" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# ---- Step 1: Create directories ----
Write-Host "[1/6] Creating directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CLOUD_ROOT  | Out-Null

# ---- Step 2: Download FileBrowser ----
Write-Host "[2/6] Downloading FileBrowser..." -ForegroundColor Yellow
$fbExe = "$INSTALL_DIR\filebrowser.exe"
if (-not (Test-Path $fbExe)) {
    $fbUrl = "https://github.com/filebrowser/filebrowser/releases/download/v2.32.0/windows-amd64-filebrowser.zip"
    Invoke-WebRequest -Uri $fbUrl -OutFile "$INSTALL_DIR\fb.zip" -UseBasicParsing
    Expand-Archive -Path "$INSTALL_DIR\fb.zip" -DestinationPath $INSTALL_DIR -Force
    Remove-Item "$INSTALL_DIR\fb.zip"
    Write-Host "  FileBrowser downloaded." -ForegroundColor Green
} else {
    Write-Host "  FileBrowser already exists, skipping." -ForegroundColor Gray
}

# ---- Step 3: Create drive junctions ----
Write-Host "[3/6] Mapping drives to CloudRoot..." -ForegroundColor Yellow
$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\" }
foreach ($drive in $drives) {
    $letter = $drive.Name
    $junctionPath = "$CLOUD_ROOT\$letter-Drive"
    if (Test-Path $junctionPath) { Remove-Item $junctionPath -Force -Recurse -ErrorAction SilentlyContinue }
    & cmd /c "mklink /J `"$junctionPath`" `"$($drive.Root)`"" | Out-Null
    Write-Host "  Mapped: $junctionPath -> $($drive.Root)" -ForegroundColor Green
}

# ---- Step 4: Initialize FileBrowser ----
Write-Host "[4/6] Initializing FileBrowser..." -ForegroundColor Yellow
$dbPath = "$INSTALL_DIR\filebrowser.db"

if (Test-Path $dbPath) { Remove-Item $dbPath -Force }

& $fbExe config init --database $dbPath | Out-Null
& $fbExe config set --root $CLOUD_ROOT --address "127.0.0.1" --port $FB_PORT --database $dbPath | Out-Null
& $fbExe users add $ADMIN_USER $ADMIN_PASS --perm.admin --database $dbPath | Out-Null
Write-Host "  FileBrowser initialized. Root: $CLOUD_ROOT" -ForegroundColor Green

# ---- Step 5: Install cloudflared ----
Write-Host "[5/6] Setting up Cloudflare Tunnel..." -ForegroundColor Yellow
$cfInstalled = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cfInstalled) {
    winget install Cloudflare.cloudflared --silent
}

# Copy config if exists
$configSrc = "$INSTALL_DIR\config.yml"
if (Test-Path $configSrc) {
    Write-Host "  Using existing config.yml" -ForegroundColor Green
} else {
    Write-Host "  ACTION REQUIRED: Run the following after install:" -ForegroundColor Red
    Write-Host "    cloudflared tunnel login" -ForegroundColor White
    Write-Host "    cloudflared tunnel create $TUNNEL_NAME" -ForegroundColor White
    Write-Host "    cloudflared tunnel route dns $TUNNEL_NAME $SUBDOMAIN" -ForegroundColor White
}

# ---- Step 6: Register scheduled tasks ----
Write-Host "[6/6] Registering startup tasks..." -ForegroundColor Yellow

# FileBrowser task
Unregister-ScheduledTask -TaskName "FileBrowser" -Confirm:$false -ErrorAction SilentlyContinue
$fbAction   = New-ScheduledTaskAction -Execute $fbExe -Argument "--database $dbPath"
$fbTrigger  = New-ScheduledTaskTrigger -AtStartup
$fbSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
$fbPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "FileBrowser" -Action $fbAction -Trigger $fbTrigger -Settings $fbSettings -Principal $fbPrincipal -Description "FileBrowser cloud drive at localhost:$FB_PORT" | Out-Null
Start-ScheduledTask -TaskName "FileBrowser"
Write-Host "  FileBrowser task registered." -ForegroundColor Green

# Cloudflared task
if (Test-Path $configSrc) {
    $cfExe = (Get-Command cloudflared).Source
    Unregister-ScheduledTask -TaskName "CloudflaredTunnel" -Confirm:$false -ErrorAction SilentlyContinue
    $cfAction   = New-ScheduledTaskAction -Execute $cfExe -Argument "tunnel --config $configSrc run"
    $cfTrigger  = New-ScheduledTaskTrigger -AtStartup
    $cfSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    $cfPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "CloudflaredTunnel" -Action $cfAction -Trigger $cfTrigger -Settings $cfSettings -Principal $cfPrincipal -Description "Cloudflare Tunnel -> $SUBDOMAIN" | Out-Null
    Start-ScheduledTask -TaskName "CloudflaredTunnel"
    Write-Host "  Cloudflared task registered." -ForegroundColor Green
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  URL:      https://$SUBDOMAIN" -ForegroundColor Cyan
Write-Host "  Username: $ADMIN_USER" -ForegroundColor White
Write-Host "  Password: $ADMIN_PASS  <-- CHANGE THIS!" -ForegroundColor Red
Write-Host ""
Write-Host "  Drives available:" -ForegroundColor Yellow
foreach ($d in $drives) { Write-Host "    $($d.Name)-Drive -> $($d.Root)" -ForegroundColor White }
Write-Host "=================================================" -ForegroundColor Green
