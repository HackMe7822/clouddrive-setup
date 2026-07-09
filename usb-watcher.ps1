# ================================================================
#  USB Drive Watcher - always-on background service
#  Detects new/removed drives every 10 sec
#  Adds them to Nextcloud External Storage instantly (no restart)
# ================================================================

$INSTALL_DIR = "C:\CloudDrive"
$NC_DIR      = "C:\Nextcloud"
$STATE_FILE  = "$INSTALL_DIR\known-drives.json"
$LOG_FILE    = "$INSTALL_DIR\usb-watcher.log"
$POLL_SEC    = 10

# Find PHP
$phpExe = (Get-Command php -ErrorAction SilentlyContinue).Source
if (-not $phpExe) {
    $phpExe = @("C:\php\php.exe","C:\PHP\php.exe","C:\Program Files\PHP\php.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
}

function Get-AllDrives {
    @(Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Root -match "^[A-Z]:\\" } |
        Select-Object -ExpandProperty Name |
        Sort-Object)
}

function Read-KnownDrives {
    if (Test-Path $STATE_FILE) {
        try { return @((Get-Content $STATE_FILE -Raw | ConvertFrom-Json).drives) } catch {}
    }
    return @()
}
function Load-KnownDrives { Read-KnownDrives }  # alias kept for compatibility

function Save-KnownDrives($drives) {
    @{ drives = @($drives) } | ConvertTo-Json | Set-Content $STATE_FILE -Encoding UTF8
}

function Invoke-Occ($occArgs) {
    if (-not $phpExe) { return }
    & $phpExe "$NC_DIR\occ" @occArgs 2>&1
}

function Add-DriveToNextcloud($letter) {
    $drivePath = "$($letter):"
    $driveName = "$($letter)-Drive"
    $existing  = Invoke-Occ @("files_external:list")
    if ($existing -match "/$driveName") { return }
    Invoke-Occ @("files_external:create", $driveName, "local", "null::null", "--config", "datadir=$drivePath") | Out-Null
    Write-Log "Added drive $($letter): to Nextcloud External Storage"
    Write-Host "USB: Added $($letter): to Nextcloud" -ForegroundColor Green
}

function Remove-DriveFromNextcloud($letter) {
    $driveName = "$($letter)-Drive"
    $list      = Invoke-Occ @("files_external:list")
    $idLine    = $list | Select-String "/$driveName"
    if (-not $idLine) { return }
    $mountId   = ($idLine -split "\|" | Where-Object { $_.Trim() -match "^\d+$" } | Select-Object -First 1).Trim()
    if ($mountId) {
        Invoke-Occ @("files_external:delete", $mountId, "--yes") | Out-Null
        Write-Log "Removed drive $($letter): from Nextcloud External Storage"
        Write-Host "USB: Removed $($letter): from Nextcloud" -ForegroundColor Yellow
    }
}

# ---- Start ----
Write-Log "USB Watcher started. PHP: $phpExe"

$knownDrives = @(Read-KnownDrives)
if ($knownDrives.Count -eq 0) {
    $knownDrives = @(Get-AllDrives)
    Save-KnownDrives $knownDrives
    Write-Log "Initialized with drives: $($knownDrives -join ', ')"
}

# ---- Monitor loop ----
while ($true) {
    Start-Sleep $POLL_SEC

    $current = @(Get-AllDrives)
    $known   = @(Read-KnownDrives)

    $newDrives     = @($current | Where-Object { $_ -notin $known })
    $removedDrives = @($known   | Where-Object { $_ -notin $current })

    foreach ($drive in $newDrives) {
        Write-Log "New drive detected: $($drive):"
        Add-DriveToNextcloud $drive
    }

    foreach ($drive in $removedDrives) {
        Write-Log "Drive removed: $($drive):"
        Remove-DriveFromNextcloud $drive
    }

    if ($newDrives.Count -gt 0 -or $removedDrives.Count -gt 0) {
        Save-KnownDrives $current
    }
}
