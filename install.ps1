# ================================================================
#  CloudDrive - Native Windows Installer
#  Nextcloud on PHP + MariaDB + Caddy, no Docker needed
#  USB drives appear instantly - no container restarts
#  Run as Administrator in PowerShell
#  GitHub: https://github.com/HackMe7822/clouddrive-setup
# ================================================================
#
#  EDIT THESE BEFORE RUNNING:
# ================================================================
$SUBDOMAIN   = "files.creationsit.com"  # your public URL
$ADMIN_USER  = "admin"
$ADMIN_PASS  = "ChangeMe@123"           # change after install
$NC_DATA_DIR = "D:\NCData"              # where user files are stored
$NC_DIR      = "C:\Nextcloud"           # Nextcloud app files
$NC_PORT     = 8080
$PHP_PORT    = 9123                     # internal PHP-CGI port
$INSTALL_DIR = "C:\CloudDrive"
$CF_DIR      = "$env:USERPROFILE\.cloudflared"
# ================================================================

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "Run as Administrator!" -ForegroundColor Red; pause; exit 1 }

function Write-Step($n, $total, $msg) { Write-Host "`n[$n/$total] $msg" -ForegroundColor Yellow }
function Invoke-Occ($args) {
    $php = (Get-Command php -ErrorAction SilentlyContinue).Source
    if (-not $php) { $php = Get-ChildItem "C:\php\php.exe","C:\PHP\php.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    & $php "$NC_DIR\occ" @args 2>&1
}

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "  CloudDrive Native Installer" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $NC_DATA_DIR | Out-Null

# ================================================================
# STEP 1 - Install PHP, MariaDB, Caddy
# ================================================================
Write-Step 1 8 "Installing PHP, MariaDB, Caddy..."

function Install-IfMissing($cmd, $wingetId, $label) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) { Write-Host "  $label already installed: $($found.Source)" -ForegroundColor Gray; return }
    Write-Host "  Installing $label..." -ForegroundColor Gray
    winget install $wingetId --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
}

Install-IfMissing "caddy"  "CaddyServer.Caddy" "Caddy"
Install-IfMissing "mysql"  "MariaDB.Server"    "MariaDB"

# PHP: check multiple package IDs since winget changed the name
$phpExe = (Get-Command php -ErrorAction SilentlyContinue).Source
if (-not $phpExe) {
    Write-Host "  Installing PHP 8.3..." -ForegroundColor Gray
    winget install PHP.PHP.8.3 --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
}

# Refresh PATH so winget-installed binaries are visible
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# Locate PHP (winget puts it in AppData\Local\Microsoft\WinGet\Links or the install dir)
$phpExe = (Get-Command php -ErrorAction SilentlyContinue).Source
if (-not $phpExe) {
    $phpExe = @(
        "C:\php\php.exe",
        "C:\PHP\php.exe",
        "C:\Program Files\PHP\php.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\php.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $phpExe) {
    # Fallback: download directly
    Write-Host "  PHP not found via winget - downloading directly..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $phpZip = "$INSTALL_DIR\php.zip"
    Invoke-WebRequest "https://windows.php.net/downloads/releases/php-8.3.32-Win32-vs16-x64.zip" -OutFile $phpZip -UseBasicParsing
    New-Item -ItemType Directory -Force -Path "C:\php" | Out-Null
    Expand-Archive -Path $phpZip -DestinationPath "C:\php" -Force
    Remove-Item $phpZip -Force
    $phpExe = 'C:\php\php.exe'
    $env:PATH = 'C:\php;' + $env:PATH
    [System.Environment]::SetEnvironmentVariable('PATH', 'C:\php;' + [System.Environment]::GetEnvironmentVariable('PATH','Machine'), 'Machine')
}
if (-not $phpExe) { Write-Host "PHP install failed. Check internet and re-run." -ForegroundColor Red; exit 1 }

$phpDir    = Split-Path $phpExe
$phpCgiExe = Join-Path $phpDir "php-cgi.exe"
$phpIni    = Join-Path $phpDir "php.ini"
Write-Host "  PHP: $phpExe" -ForegroundColor Green

# Configure php.ini
if (Test-Path "$phpDir\php.ini-production") { Copy-Item "$phpDir\php.ini-production" $phpIni -Force }
elseif (Test-Path "$phpDir\php.ini-development") { Copy-Item "$phpDir\php.ini-development" $phpIni -Force }

$extensions = @("curl","gd","intl","mbstring","openssl","pdo_mysql","zip","fileinfo","bcmath","exif","gmp","sodium")
foreach ($ext in $extensions) {
    (Get-Content $phpIni) -replace ";extension=$ext", "extension=$ext" | Set-Content $phpIni
}

# Set extension_dir to actual PHP install location (winget uses a non-standard path)
$extDir = Join-Path $phpDir "ext"
if (Test-Path $extDir) {
    $escaped = $extDir -replace "\\", "\\"
    $ini = Get-Content $phpIni
    if ($ini -match "^;?extension_dir") {
        $ini = $ini -replace "^;?extension_dir\s*=.*", "extension_dir = `"$extDir`""
    } else {
        $ini += "`nextension_dir = `"$extDir`""
    }
    $ini | Set-Content $phpIni
}

(Get-Content $phpIni) -replace "^;?date.timezone =.*", "date.timezone = Asia/Kolkata" `
                      -replace "^;?memory_limit =.*", "memory_limit = 512M" `
                      -replace "^;?upload_max_filesize =.*", "upload_max_filesize = 10G" `
                      -replace "^;?post_max_size =.*", "post_max_size = 10G" `
                      -replace "^;?max_execution_time =.*", "max_execution_time = 3600" `
                      -replace "^;?output_buffering =.*", "output_buffering = Off" `
                      -replace "^;?default_socket_timeout =.*", "default_socket_timeout = 5" | Set-Content $phpIni

# Ensure default_socket_timeout is present (may not exist in ini)
if (-not (Get-Content $phpIni | Select-String "^default_socket_timeout")) {
    Add-Content $phpIni "`ndefault_socket_timeout = 5"
}
# Disable OPcache CLI to avoid stale class caches during occ runs
if (-not (Get-Content $phpIni | Select-String "^opcache.enable_cli")) {
    Add-Content $phpIni "`nopcache.enable_cli=0"
}
Write-Host "  PHP configured." -ForegroundColor Green

# Find Caddy
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
$caddyExe = (Get-Command caddy -ErrorAction SilentlyContinue).Source
if (-not $caddyExe) {
    $caddyExe = @(
        "C:\Program Files\Caddy\caddy.exe",
        "C:\ProgramData\caddy\caddy.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\caddy.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
Write-Host "  Caddy: $caddyExe" -ForegroundColor Green

# Find MariaDB mysql
$mysqlExe = Get-ChildItem "C:\Program Files\MariaDB*\bin\mysql.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $mysqlExe) { $mysqlExe = (Get-Command mysql -ErrorAction SilentlyContinue).Source }
Write-Host "  MariaDB mysql: $mysqlExe" -ForegroundColor Green

# ================================================================
# STEP 2 - Database setup
# ================================================================
Write-Step 2 8 "Setting up database..."

# Start MariaDB service
$dbService = Get-Service -Name "MySQL*","MariaDB*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dbService) {
    Start-Service $dbService.Name -ErrorAction SilentlyContinue
    Write-Host "  Started $($dbService.Name)" -ForegroundColor Green
} else {
    Write-Host "  MariaDB service not found - trying to initialize..." -ForegroundColor Yellow
    $mysqldExe = Split-Path $mysqlExe | ForEach-Object { Join-Path $_ "mysqld.exe" }
    if (Test-Path $mysqldExe) {
        & $mysqldExe --install MySQL --defaults-file="$(Split-Path $mysqlExe)\my.ini" 2>&1 | Out-Null
        Start-Service MySQL
    }
}
Start-Sleep 3

# Generate DB password
$chars  = (65..90) + (97..122) + (48..57)
$dbPass = -join ($chars | Get-Random -Count 24 | ForEach-Object { [char]$_ })

# Create database and user - both @localhost and @127.0.0.1 are needed on Windows
& $mysqlExe -u root --execute="CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" 2>&1 | Out-Null
& $mysqlExe -u root --execute="CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '$dbPass';" 2>&1 | Out-Null
& $mysqlExe -u root --execute="CREATE USER IF NOT EXISTS 'nextcloud'@'127.0.0.1' IDENTIFIED BY '$dbPass';" 2>&1 | Out-Null
& $mysqlExe -u root --execute="GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';" 2>&1 | Out-Null
& $mysqlExe -u root --execute="GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'127.0.0.1';" 2>&1 | Out-Null
& $mysqlExe -u root --execute="FLUSH PRIVILEGES;" 2>&1 | Out-Null
Write-Host "  Database nextcloud created." -ForegroundColor Green

# Save DB password
"DB_PASS=$dbPass" | Set-Content "$INSTALL_DIR\db.env" -Encoding UTF8

# ================================================================
# STEP 3 - Download and install Nextcloud
# ================================================================
Write-Step 3 8 "Downloading Nextcloud..."

if (Test-Path "$NC_DIR\occ") {
    Write-Host "  Nextcloud already installed at $NC_DIR, skipping download." -ForegroundColor Gray
} else {
    $ncZip = "$INSTALL_DIR\nextcloud.zip"
    Write-Host "  Downloading latest Nextcloud (~200MB)..." -ForegroundColor Gray
    Invoke-WebRequest -Uri "https://download.nextcloud.com/server/releases/latest.zip" -OutFile $ncZip -UseBasicParsing
    Write-Host "  Extracting..." -ForegroundColor Gray
    # Add Defender exclusions before extracting to prevent file locking
    Add-MpPreference -ExclusionPath $NC_DIR -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $NC_DATA_DIR -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $INSTALL_DIR -ErrorAction SilentlyContinue
    Expand-Archive -Path $ncZip -DestinationPath "C:\" -Force
    Remove-Item $ncZip -Force
    Write-Host "  Nextcloud extracted to $NC_DIR" -ForegroundColor Green
}

# Create the .ncdata marker file required by Nextcloud
if (-not (Test-Path "$NC_DATA_DIR\.ncdata")) {
    "# Nextcloud data directory" | Set-Content "$NC_DATA_DIR\.ncdata" -Encoding UTF8
}

# Set folder permissions for www-data equivalent (running as SYSTEM)
$acl = Get-Acl $NC_DIR
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$acl.SetAccessRule($rule)
Set-Acl $NC_DIR $acl

# ================================================================
# STEP 4 - Apply Windows compatibility patches
# ================================================================
Write-Step 4 8 "Applying Windows compatibility patches..."

# Patch 1: occ - skip dropPrivileges() on Windows (posix_getuid() not available)
$occPath = "$NC_DIR\occ"
$occContent = Get-Content $occPath -Raw -Encoding UTF8
if ($occContent -notmatch "PHP_OS_FAMILY.*Windows.*dropPrivileges") {
    $occContent = $occContent -replace "(function dropPrivileges\(\): void \{)", @'
$1
    if (PHP_OS_FAMILY === 'Windows') {
        return;
    }
'@
    [System.IO.File]::WriteAllText($occPath, $occContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  occ: patched dropPrivileges for Windows" -ForegroundColor Green
}

# Patch 2: console.php - add POSIX stubs and fix fileowner check
$consolePath = "$NC_DIR\console.php"
$consoleContent = Get-Content $consolePath -Raw -Encoding UTF8
if ($consoleContent -notmatch "posix_getuid.*return 0") {
    $stub = @'
// Windows compatibility: stub POSIX functions not available on Windows PHP
if (PHP_OS_FAMILY === 'Windows') {
	if (!function_exists('posix_getuid')) {
		function posix_getuid(): int { return 0; }
	}
	if (!function_exists('posix_getpwuid')) {
		function posix_getpwuid(int $uid): array|false { return ['name' => 'system', 'uid' => 0, 'gid' => 0, 'dir' => 'C:\\', 'shell' => '']; }
	}
	if (!function_exists('posix_setuid')) {
		function posix_setuid(int $uid): bool { return true; }
	}
	if (!function_exists('posix_setgid')) {
		function posix_setgid(int $gid): bool { return true; }
	}
}

'@
    $consoleContent = $consoleContent -replace "(define\('OC_CONSOLE', 1\);)", "$1`n`n$stub"
    # Fix fileowner() call to not crash on missing file and skip on Windows
    $consoleContent = $consoleContent -replace '\$configUser = fileowner\(\$configFile\);', '$configUser = file_exists($configFile) ? fileowner($configFile) : $user;'
    $consoleContent = $consoleContent -replace '(if \(\$configUser !== false && \$user !== \$configUser\))', '$1 && PHP_OS_FAMILY !== ''Windows'''
    [System.IO.File]::WriteAllText($consolePath, $consoleContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  console.php: patched POSIX stubs and fileowner check" -ForegroundColor Green
}

# Patch 3: MigrationService.php - fix regex to accept both / and \ as path separators
$migPath = "$NC_DIR\lib\private\DB\MigrationService.php"
$migContent = Get-Content $migPath -Raw -Encoding UTF8
if ($migContent -match "#\^\.\+\\\\/Version") {
    Write-Host "  MigrationService.php: already patched" -ForegroundColor Gray
} else {
    $migContent = $migContent -replace "#\^\.\+\\\\/Version\[^\\\\/\]\{1,255\}\\\\.php\\\$#i", "#^.+[\\\\/]Version[^\\\\/]{1,255}\.php$#i"
    # More robust search and replace
    $migContent = $migContent -replace [regex]::Escape("#^.+\/Version[^\/]{1,255}\.php$#i"), "#^.+[\\\\/]Version[^\\\\/]{1,255}\.php\$#i"
    [System.IO.File]::WriteAllText($migPath, $migContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  MigrationService.php: patched path separator regex" -ForegroundColor Green
}

# Patch 4: OC_Util.php - accept Windows absolute paths like D:\NCData
$utilPath = "$NC_DIR\lib\private\legacy\OC_Util.php"
$utilContent = Get-Content $utilPath -Raw -Encoding UTF8
if ($utilContent -notmatch "A-Za-z.*:\[/") {
    $utilContent = $utilContent -replace 'if \(\$dataDirectory\[0\] !== .\/.\)', 'if ($dataDirectory[0] !== ''/'' && !preg_match(''#^[A-Za-z]:[/\\\\\\\\ ]#'', $dataDirectory))'
    [System.IO.File]::WriteAllText($utilPath, $utilContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  OC_Util.php: patched Windows path check" -ForegroundColor Green
}

# Patch 5: Manager.php - fix infinite loop on Windows paths in find()
$mgrPath = "$NC_DIR\lib\private\Files\Mount\Manager.php"
$mgrContent = Get-Content $mgrPath -Raw -Encoding UTF8
if ($mgrContent -notmatch '\$prev = \$current') {
    $mgrContent = $mgrContent -replace '(\s+)\$current = dirname\(\$current\);\r?\n(\s+)if \(\$current === \x27\.\x27 \|\| \$current === \x27\/\x27\)', '$1$prev = $current;
$1$current = dirname($current);
$2if ($current === ''.'' || $current === ''/'' || $current === ''\\'' || $current === $prev)'
    [System.IO.File]::WriteAllText($mgrPath, $mgrContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Manager.php: patched infinite loop on Windows paths" -ForegroundColor Green
}

# Patch 6: Local.php - fix realpath() returning backslashes causing false symlink errors
$localPath = "$NC_DIR\lib\private\Files\Storage\Local.php"
$localContent = Get-Content $localPath -Raw -Encoding UTF8
if ($localContent -notmatch "str_replace\(.*realPath") {
    # Fix in constructor
    $localContent = $localContent -replace '(\$realPath = realpath\(\$this->datadir\) \?: \$this->datadir;\s*\n\s*)(\$this->realDataDir)', '$1$realPath = str_replace(''\'', ''/'', $realPath);
		$2'
    # Fix in getSourcePath()
    $localContent = $localContent -replace '(if \(\$realPath\) \{\s*\n\s*)\$realPath = \$realPath \. \x27\/\x27;', '$1$realPath = str_replace(''\'', ''/'', $realPath) . ''/''};'
    [System.IO.File]::WriteAllText($localPath, $localContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Local.php: patched realpath backslash normalization" -ForegroundColor Green
}

Write-Host "  Windows patches applied." -ForegroundColor Green

Write-Host "  Installing Nextcloud (this takes ~2 minutes)..." -ForegroundColor Gray
& $phpExe "$NC_DIR\occ" maintenance:install `
    --database "mysql" `
    --database-host "127.0.0.1" `
    --database-name "nextcloud" `
    --database-user "nextcloud" `
    --database-pass "$dbPass" `
    --admin-user "$ADMIN_USER" `
    --admin-pass "$ADMIN_PASS" `
    --data-dir "$NC_DATA_DIR" 2>&1

& $phpExe "$NC_DIR\occ" config:system:set trusted_domains 0 --value="localhost"
& $phpExe "$NC_DIR\occ" config:system:set trusted_domains 1 --value="$SUBDOMAIN"
& $phpExe "$NC_DIR\occ" config:system:set trusted_domains 2 --value="127.0.0.1"
& $phpExe "$NC_DIR\occ" config:system:set overwrite.cli.url --value="https://$SUBDOMAIN"
& $phpExe "$NC_DIR\occ" config:system:set overwriteprotocol --value="https"
& $phpExe "$NC_DIR\occ" config:system:set trusted_proxies 0 --value="127.0.0.1"
& $phpExe "$NC_DIR\occ" config:system:set check_data_directory_permissions --value=false --type=boolean
& $phpExe "$NC_DIR\occ" config:system:set has_internet_connection --value=false --type=boolean
& $phpExe "$NC_DIR\occ" config:system:set connectivity_check_domains --value="" --type=json
& $phpExe "$NC_DIR\occ" config:system:set updatechecker --value=false --type=boolean
& $phpExe "$NC_DIR\occ" config:system:set check_for_working_wellknown_setup --value=false --type=boolean
& $phpExe "$NC_DIR\occ" app:disable notifications 2>&1 | Out-Null
Write-Host "  Nextcloud installed." -ForegroundColor Green

# ================================================================
# STEP 5 - External Storage (all drives, instant USB support)
# ================================================================
Write-Step 5 8 "Configuring drive access..."

& $phpExe "$NC_DIR\occ" app:enable files_external 2>&1 | Out-Null
& $phpExe "$NC_DIR\occ" config:app:set core enable_external_storage --value=yes 2>&1 | Out-Null

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\" }
foreach ($drive in $drives) {
    $letter = $drive.Name
    $path   = $drive.Root -replace "\\$", ""
    & $phpExe "$NC_DIR\occ" files_external:create "${letter}-Drive" local null::null --config "datadir=$path" 2>&1 | Out-Null
    Write-Host "  Added $($letter): as external storage" -ForegroundColor Green
}

# Save known drives for USB watcher
$knownDrives = @{ drives = @($drives | ForEach-Object { $_.Name }) }
$knownDrives | ConvertTo-Json | Set-Content "$INSTALL_DIR\known-drives.json" -Encoding UTF8

# Copy USB watcher script
if (Test-Path "$PSScriptRoot\usb-watcher.ps1") {
    Copy-Item "$PSScriptRoot\usb-watcher.ps1" "$INSTALL_DIR\usb-watcher.ps1" -Force
}

# ================================================================
# STEP 6 - Caddy web server config
# ================================================================
Write-Step 6 8 "Configuring web server..."

$caddyFile = "$INSTALL_DIR\Caddyfile"
@"
:$NC_PORT {
    root * $NC_DIR

    rewrite /.well-known/carddav /remote.php/dav
    rewrite /.well-known/caldav  /remote.php/dav

    encode gzip

    php_fastcgi 127.0.0.1:$PHP_PORT

    file_server

    @forbidden {
        path /.htaccess /data/* /config/* /db_structure /.xml /README
        path /3rdparty/* /lib/* /templates/* /occ /console.php
    }
    respond @forbidden 404
}
"@ | Set-Content $caddyFile -Encoding UTF8
Write-Host "  Caddyfile written." -ForegroundColor Green

# ================================================================
# STEP 7 - Cloudflare Tunnel
# ================================================================
Write-Step 7 8 "Cloudflare Tunnel..."

$cfInstalled = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cfInstalled) {
    winget install Cloudflare.cloudflared --silent --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}
$cfBin = (Get-Command cloudflared).Source

if (-not (Test-Path "$CF_DIR\cert.pem")) {
    Write-Host "  A browser will open - log into Cloudflare." -ForegroundColor Cyan
    & $cfBin tunnel login
}

$localCred = "$INSTALL_DIR\tunnel.json"

# Use existing tunnel.json in $INSTALL_DIR if present (already configured)
if (Test-Path $localCred) {
    $tunnelId = (Get-Content $localCred -Raw | ConvertFrom-Json).TunnelID
    Write-Host "  Using existing tunnel from $localCred : $tunnelId" -ForegroundColor Green
} else {
    # Look for tunnel credentials in cloudflared dir - prefer any that matches current config.yml
    $existingConfig = if (Test-Path "$INSTALL_DIR\config.yml") { Get-Content "$INSTALL_DIR\config.yml" -Raw } else { "" }
    $credJson = $null
    if ($existingConfig -match "tunnel:\s*([a-f0-9-]{36})") {
        $cfgTunnelId = $Matches[1]
        $credJson = Get-ChildItem $CF_DIR -Filter "$cfgTunnelId.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $credJson) {
        $credJson = Get-ChildItem $CF_DIR -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "cert.json" } | Select-Object -Last 1
    }
    if ($credJson) {
        $tunnelId = $credJson.BaseName
        Copy-Item $credJson.FullName $localCred -Force
        Write-Host "  Using existing tunnel: $tunnelId" -ForegroundColor Green
    } else {
        & $cfBin tunnel create files-drive 2>&1 | Out-Null
        $credJson  = Get-ChildItem $CF_DIR -Filter "*.json" | Where-Object { $_.Name -ne "cert.json" } | Select-Object -Last 1
        $tunnelId  = $credJson.BaseName
        Copy-Item $credJson.FullName $localCred -Force
        Write-Host "  Created tunnel: $tunnelId" -ForegroundColor Green
    }
}

$configPath = "$INSTALL_DIR\config.yml"
@"
tunnel: $tunnelId
credentials-file: $localCred

ingress:
  - hostname: $SUBDOMAIN
    service: http://localhost:$NC_PORT
  - service: http_status:404
"@ | Set-Content $configPath -Encoding UTF8

# DNS update
$domain   = ($SUBDOMAIN -split "\." | Select-Object -Last 2) -join "."
$subdName = ($SUBDOMAIN -split "\.")[0]
$cname    = "$tunnelId.cfargotunnel.com"

Write-Host ""
Write-Host "  Cloudflare API token for auto DNS update (leave blank to skip):" -ForegroundColor Cyan
Write-Host "  dash.cloudflare.com -> My Profile -> API Tokens -> Edit zone DNS template" -ForegroundColor Gray
# Set $CF_API_TOKEN before running to skip this prompt, or leave empty for manual DNS
$cfToken = if ($CF_API_TOKEN) { $CF_API_TOKEN } else { "" }

if ($cfToken.Trim() -ne "") {
    $h = @{ "Authorization" = "Bearer $($cfToken.Trim())"; "Content-Type" = "application/json" }
    try {
        $zoneId = (Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $h).result[0].id
        $rec    = (Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=CNAME&name=$SUBDOMAIN" -Headers $h).result
        $body   = @{ type="CNAME"; name=$subdName; content=$cname; proxied=$true } | ConvertTo-Json
        if ($rec.Count -gt 0) {
            Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($rec[0].id)" -Method Put -Headers $h -Body $body | Out-Null
            Write-Host "  DNS updated: $SUBDOMAIN -> $cname" -ForegroundColor Green
        } else {
            Invoke-RestMethod "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $h -Body $body | Out-Null
            Write-Host "  DNS created: $SUBDOMAIN -> $cname" -ForegroundColor Green
        }
    } catch { Write-Host "  DNS API failed. Add manually: CNAME $subdName -> $cname (Proxied ON)" -ForegroundColor Yellow }
} else {
    Write-Host "  Add this DNS record at your domain provider (works with ANY provider):" -ForegroundColor Yellow
    Write-Host "    Type:   CNAME" -ForegroundColor White
    Write-Host "    Name:   $subdName" -ForegroundColor White
    Write-Host "    Target: $cname" -ForegroundColor White
    Write-Host "    Note:   If using Cloudflare DNS, enable orange cloud (Proxied)" -ForegroundColor White
}

# ================================================================
# STEP 8 - Register all startup tasks
# ================================================================
Write-Step 8 8 "Registering startup tasks..."

$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew

# PHP-CGI task - pass -c to use the correct php.ini (winget puts PHP in a non-standard path)
$phpAction = New-ScheduledTaskAction -Execute $phpCgiExe -Argument "-b 127.0.0.1:$PHP_PORT -c `"$phpIni`""
Register-ScheduledTask -TaskName "CloudDrive-PHPCGI" -Action $phpAction -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName "CloudDrive-PHPCGI" -ErrorAction SilentlyContinue
Write-Host "  PHP-CGI task registered." -ForegroundColor Green

# Caddy task
$caddyAction = New-ScheduledTaskAction -Execute $caddyExe -Argument "run --config `"$caddyFile`"" -WorkingDirectory $INSTALL_DIR
Register-ScheduledTask -TaskName "CloudDrive-Caddy" -Action $caddyAction -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName "CloudDrive-Caddy" -ErrorAction SilentlyContinue
Write-Host "  Caddy task registered." -ForegroundColor Green

# Cloudflared tunnel task
$cfAction   = New-ScheduledTaskAction -Execute $cfBin -Argument "tunnel --config `"$configPath`" run" -WorkingDirectory $INSTALL_DIR
$cfSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "CloudDrive-Tunnel" -Action $cfAction -Trigger $trigger -Settings $cfSettings -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName "CloudDrive-Tunnel" -ErrorAction SilentlyContinue
Write-Host "  Tunnel task registered." -ForegroundColor Green

# USB Watcher task
$usbAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$INSTALL_DIR\usb-watcher.ps1`""
Register-ScheduledTask -TaskName "CloudDrive-USBWatcher" -Action $usbAction -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName "CloudDrive-USBWatcher" -ErrorAction SilentlyContinue
Write-Host "  USB Watcher task registered." -ForegroundColor Green

# Wait a moment then test
Start-Sleep 5
try {
    $r = Invoke-WebRequest -Uri "http://localhost:$NC_PORT/status.php" -UseBasicParsing -TimeoutSec 10
    $status = $r.Content | ConvertFrom-Json
    Write-Host "  Nextcloud running: v$($status.versionstring)" -ForegroundColor Green
} catch { Write-Host "  Nextcloud not responding yet - may need a moment to start." -ForegroundColor Yellow }

# ================================================================
# DONE
# ================================================================
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  URL:      https://$SUBDOMAIN" -ForegroundColor Cyan
Write-Host "  Username: $ADMIN_USER" -ForegroundColor White
Write-Host "  Password: $ADMIN_PASS  <-- change this!" -ForegroundColor Red
Write-Host ""
Write-Host "  Drives accessible:" -ForegroundColor Yellow
foreach ($d in $drives) { Write-Host "    $($d.Name)-Drive -> $($d.Root)" -ForegroundColor White }
Write-Host ""
Write-Host "  USB drives: plug in -> appears in Nextcloud within 10 sec" -ForegroundColor Cyan
Write-Host "  Works with ANY DNS provider (Cloudflare, GoDaddy, Namecheap...)" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Green
