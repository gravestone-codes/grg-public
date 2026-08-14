<#
.SYNOPSIS
  GRG installer for Windows.

.DESCRIPTION
  Sets up GRG on this machine using Docker Desktop: the application, its database, sign-in, and
  storage for photos. Asks a few questions, generates every password and key itself, and starts
  everything.

  Run in PowerShell as Administrator:

    irm https://raw.githubusercontent.com/gravestone-codes/grg-public/main/install.ps1 | iex

  Safe to run again — that is how you update. It never overwrites the settings file it created,
  because the encryption key inside it is the only way to read your existing data.

  Windows is well suited to trying GRG out and to small office use. For a machine that must stay
  up unattended, Linux is the better host: Docker Desktop here starts when you log in, not when
  the computer boots, so a restart leaves GRG down until someone signs in.

.PARAMETER Domain
  What people type to open GRG. Defaults to this machine's network address.

.PARAMETER InstallDir
  Where to put it. Defaults to C:\GRG.

.PARAMETER Version
  Image tag to deploy: latest, or a sha-xxxxxxx build to pin or roll back.

.PARAMETER Yes
  Don't ask anything; use the defaults and whatever was passed.

.PARAMETER NoWait
  Don't wait for it to answer; finish as soon as it has started.
#>
[CmdletBinding()]
param(
  [string]$Domain,
  [string]$MediaDomain,
  [string]$AdminEmail,
  [string]$AdminName = "GRG Admin",
  [string]$InstallDir = "C:\GRG",
  [string]$Version,
  [int]$WaitSeconds = 90,
  [switch]$Yes,
  [switch]$NoWait
)

$ErrorActionPreference = "Stop"
if ($NoWait) { $WaitSeconds = 0 }

$BundleRepo = "gravestone-codes/grg-public"
$BundleRef  = "main"

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    $m" }
function Write-Warn { param($m) Write-Host " !! $m" -ForegroundColor Yellow }
function Stop-With  { param($m) Write-Host "`n !! $m`n" -ForegroundColor Red; exit 1 }

# Addresses that can never get a public certificate — nobody can prove ownership of them to a
# certificate authority, so these are served over plain http and skip the certificate entirely.
function Test-LocalAddress {
  param([string]$a)
  if ($a -match '^(localhost|0\.0\.0\.0)$') { return $true }
  if ($a -match '^(10\.|127\.|192\.168\.)') { return $true }
  if ($a -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { return $true }
  if ($a -match '\.(local|lan|home|internal|localdomain|test|example)$') { return $true }
  if ($a -match '\.localhost$') { return $true }
  return $false
}

function Test-ValidAddress {
  param([string]$a)
  if ([string]::IsNullOrWhiteSpace($a)) { Write-Host "    That can't be blank."; return $false }
  if ($a -match '^https?://')          { Write-Host "    Leave off the http:// — just the address."; return $false }
  if ($a -match '[^a-zA-Z0-9.:-]')     { Write-Host "    Addresses only contain letters, numbers, dots and hyphens."; return $false }
  if ($a -eq 'localhost' -or $a -match '\.') { return $true }
  Write-Host "    That needs to be a full address like garage.example.com, or localhost."
  return $false
}

function Ask {
  param([string]$Current, [string]$Label, [string]$Description, [string]$Default, [scriptblock]$Validator)
  if ($Current) { return $Current }
  if ($Yes) {
    if (-not $Default) { Stop-With "Need a value for $Label. Pass it as a parameter, or drop -Yes to be asked." }
    return $Default
  }
  while ($true) {
    Write-Host ""
    Write-Host "  $Label" -ForegroundColor White
    Write-Host "  $Description" -ForegroundColor DarkGray
    if ($Default) { Write-Host "  [$Default]" -ForegroundColor DarkGray }
    $reply = Read-Host "  "
    if (-not $reply) { $reply = $Default }
    if (& $Validator $reply) { return $reply }
  }
}

# Cryptographically strong, not Get-Random — these are the keys protecting the installation.
function New-HexSecret {
  param([int]$Bytes)
  # RNGCryptoServiceProvider rather than RandomNumberGenerator::Fill: the latter is .NET Core only,
  # and Windows ships PowerShell 5.1 on .NET Framework, where it doesn't exist. Not Get-Random
  # either — these are the keys protecting the installation.
  $b = New-Object byte[] $Bytes
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  ($b | ForEach-Object { $_.ToString("x2") }) -join ""
}
function New-AdminPassword {
  # The sign-in system requires upper, lower, digit and symbol; the fixed tail guarantees all four.
  (New-HexSecret 10) + "Aa1!"
}

# ── Checks ──────────────────────────────────────────────────────────────────────────────────────
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Stop-With "Please run PowerShell as Administrator, then try again." }

if ([Environment]::Is64BitOperatingSystem -eq $false) {
  Stop-With "GRG needs 64-bit Windows."
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
  Stop-With "This needs Windows PowerShell 5.1 or newer, which comes with Windows 10 and 11."
}

Write-Host @"

  GRG installer

  This sets up GRG on this machine: the application, its database, sign-in, and
  storage for photos.

  You'll be asked a few questions first.
"@

# ── Questions ───────────────────────────────────────────────────────────────────────────────────
# This machine's address on the network — what everyone else will type to reach it.
$lanIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } |
          Select-Object -First 1).IPv4Address.IPAddress

$Domain = Ask $Domain "Web address" `
  "What people will type to open GRG. Use your domain name if you have one. If this is a computer on your own network, press Enter to use its network address — everyone on the network can reach that, with nothing to set up on their computers." `
  $lanIp { param($a) Test-ValidAddress $a }

$isLocal = Test-LocalAddress $Domain
if ($isLocal) {
  # No certificate is possible for a private address, so photos go on a port of the same address
  # rather than a second hostname that would need DNS.
  $SiteScheme = "http"
  if (-not $MediaDomain) { $MediaDomain = "${Domain}:8081" }
  Write-Info ""
  Write-Info "$Domain is a local address, so GRG will be served over plain http://."
  Write-Info "No certificate is involved, and browsers won't warn about one."
  $AcmeEmail = "none@localhost"
} else {
  $SiteScheme = "https"
  if (-not $MediaDomain) {
    $MediaDomain = Ask $MediaDomain "Address for photos and videos" `
      "Photos are served from a separate address. This one must point at this machine too." `
      "media.$Domain" { param($a) Test-ValidAddress $a }
  }
  $AcmeEmail = Ask $null "Your email address" `
    "Used only to warn you if the site's security certificate is about to expire." `
    "admin@$Domain" { param($a) if ($a -match '^.+@.+\..+$') { $true } else { Write-Host "    That doesn't look like an email address."; $false } }
}

$AdminEmail = Ask $AdminEmail "Sign-in email for the first account" `
  "The account you'll use to log in and create everyone else. A password is generated and shown at the end." `
  $AcmeEmail { param($a) if ($a -match '^.+@.+\..+$') { $true } else { Write-Host "    That doesn't look like an email address."; $false } }

Write-Host @"

  Everything else is generated automatically and stored on this machine only:
  the database password, the encryption key for the sign-in system, and the keys
  for photo storage. You never need to choose or remember any of them.

  Ready to install
    Web address        ${SiteScheme}://${Domain}
    Photos and videos  ${SiteScheme}://${MediaDomain}
    First account      $AdminEmail  ($AdminName)
    Installing into    $InstallDir
"@

if (-not $Yes) {
  $go = Read-Host "  Continue? [Y/n]"
  if ($go -and $go -notmatch '^[Yy]') { Stop-With "Nothing was changed." }
}

# ── Ports ───────────────────────────────────────────────────────────────────────────────────────
# IIS and Skype are the usual occupants of port 80 on Windows. Caddy needs 80 and 443 both to serve
# and to prove domain ownership, so a conflict has to be settled before anything else.
Write-Step "Checking ports 80 and 443"
$busy = @()
foreach ($p in 80, 443) {
  if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p }
}
if ($busy.Count -gt 0) {
  $who = (Get-NetTCPConnection -LocalPort $busy[0] -State Listen -ErrorAction SilentlyContinue |
          Select-Object -First 1 | ForEach-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName })
  Stop-With @"
Port $($busy -join ', ') already in use$(if ($who) { " (by $who)" }).

GRG needs ports 80 and 443. Something else is serving on them — often IIS or the
World Wide Web Publishing Service. To stop it:

    Stop-Service -Name W3SVC -Force
    Set-Service  -Name W3SVC -StartupType Disabled

Then run this again.
"@
}
Write-Info "Both ports are free."

# ── Docker ──────────────────────────────────────────────────────────────────────────────────────
Write-Step "Checking Docker Desktop"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Stop-With @"
Docker Desktop isn't installed.

Install it, start it, then run this again:

    winget install Docker.DockerDesktop

or download it from https://www.docker.com/products/docker-desktop/
"@
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Info "Docker Desktop isn't running — starting it…"
  $exe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $exe) { Start-Process $exe | Out-Null }
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { break }
  }
  docker info *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-With "Docker Desktop didn't start. Open it from the Start menu, wait until it says Running, then run this again."
  }
}
Write-Info "Docker Desktop is running: $(docker --version)"

# ── Files ───────────────────────────────────────────────────────────────────────────────────────
Write-Step "Downloading GRG"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { "" }
if ($here -and (Test-Path (Join-Path $here "docker-compose.yml"))) {
  $InstallDir = $here
  Write-Info "Using the files next to this script: $InstallDir"
} else {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $zip = Join-Path $env:TEMP "grg-bundle.zip"
  Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$BundleRepo/zip/refs/heads/$BundleRef" -OutFile $zip
  $tmp = Join-Path $env:TEMP "grg-bundle"
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  # The archive wraps everything in a repo-name-and-ref folder; lift its contents out.
  $inner = Get-ChildItem $tmp | Select-Object -First 1
  Copy-Item -Path (Join-Path $inner.FullName "*") -Destination $InstallDir -Recurse -Force
  Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
  Write-Info "Downloaded into $InstallDir"
}
Set-Location $InstallDir
if (-not (Test-Path "docker-compose.yml")) { Stop-With "Something's wrong — docker-compose.yml is missing from $InstallDir." }

# ── Settings ────────────────────────────────────────────────────────────────────────────────────
Write-Step "Writing settings"
$envPath = Join-Path $InstallDir ".env"
$freshInstall = $false

if (Test-Path $envPath) {
  Write-Info "Settings already exist here — keeping them, including your encryption key."
  $existing = Get-Content $envPath | Where-Object { $_ -match '^\s*[A-Z_]+=' } |
              ForEach-Object { $p = $_ -split '=', 2; @{ k = $p[0].Trim(); v = $p[1] } }
  foreach ($e in $existing) {
    switch ($e.k) {
      "APP_DOMAIN"        { $Domain = $e.v }
      "MEDIA_DOMAIN"      { $MediaDomain = $e.v }
      "SITE_SCHEME"       { $SiteScheme = $e.v }
      "FIRST_ADMIN_EMAIL" { $AdminEmail = $e.v }
    }
  }
} else {
  # Volumes are named after the compose project, not this folder, so they outlive a reinstall into
  # a new path. A fresh encryption key against an existing database makes that data unreadable.
  $vols = docker volume ls -q 2>$null
  if ($vols -match '^grg_(pg_data|machinekey)$') {
    Stop-With @"
There's already GRG data on this machine, but no settings file in $InstallDir.

Creating new settings now would generate a new encryption key, and your existing
data could never be read again.

  - Updating an existing install? Run this from its original folder, or copy its
    .env file here first.

  - Starting fresh, and the old data doesn't matter? Remove it with
      docker compose -p grg down -v
    then run this again.
"@
  }

  $AdminPassword = New-AdminPassword
  @"
# GRG settings, created $(Get-Date -Format s)Z. Keep this file private.
#
# ZITADEL_MASTERKEY encrypts the sign-in database. Back this file up together with your data —
# without it, a restored backup cannot be read.

APP_DOMAIN=$Domain
MEDIA_DOMAIN=$MediaDomain
ACME_EMAIL=$AcmeEmail
SITE_SCHEME=$SiteScheme
GRG_VERSION=$(if ($Version) { $Version } else { "latest" })

DB_NAME=grg
DB_USER=grg
DB_PASSWORD=$(New-HexSecret 24)

ZITADEL_MASTERKEY=$(New-HexSecret 16)

FIRST_ADMIN_EMAIL=$AdminEmail
FIRST_ADMIN_PASSWORD=$AdminPassword
FIRST_ADMIN_FULL_NAME=$AdminName

GARAGE_RPC_SECRET=$(New-HexSecret 32)
GARAGE_ADMIN_TOKEN=$(New-HexSecret 32)
GARAGE_ACCESS_KEY_ID=GK$(New-HexSecret 12)
GARAGE_SECRET_ACCESS_KEY=$(New-HexSecret 32)
"@ | Set-Content -Path $envPath -Encoding ASCII

  # Readable only by Administrators and SYSTEM — this file holds every key.
  $acl = Get-Acl $envPath
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($who in "BUILTIN\Administrators", "NT AUTHORITY\SYSTEM") {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, "FullControl", "Allow")))
  }
  Set-Acl -Path $envPath -AclObject $acl
  Write-Info "Created $envPath — readable only by administrators."
  $freshInstall = $true
}

if ($Version) {
  $content = Get-Content $envPath
  if ($content -match '^GRG_VERSION=') {
    ($content -replace '^GRG_VERSION=.*', "GRG_VERSION=$Version") | Set-Content $envPath -Encoding ASCII
  } else {
    Add-Content $envPath "`nGRG_VERSION=$Version"
  }
  Write-Info "Using version $Version."
}

# ── Pull and start ──────────────────────────────────────────────────────────────────────────────
Write-Step "Downloading the application"
$pulled = $false
foreach ($attempt in 1..3) {
  docker compose pull
  if ($LASTEXITCODE -eq 0) { $pulled = $true; break }
  if ($attempt -lt 3) { Write-Warn "Download attempt $attempt of 3 didn't finish — trying again…"; Start-Sleep -Seconds 5 }
}
if (-not $pulled) {
  Stop-With @"
Couldn't download all of the pieces GRG needs.

Check this machine's internet connection, and any firewall or proxy in front of it,
then run this again — it picks up where it left off.
"@
}

Write-Step "Starting GRG"
docker compose up -d
if ($LASTEXITCODE -ne 0) { Stop-With "Couldn't start GRG. See what happened with: docker compose logs" }

# ── Ready? ──────────────────────────────────────────────────────────────────────────────────────
# 401 means "you're not signed in" — the right answer from a healthy server, so it counts as
# success. Checked against 127.0.0.1 so the answer doesn't depend on DNS; whether the address
# resolves for other people is asked separately, straight after.
function Get-AppStatus {
  param([string]$Target)
  # -SkipCertificateCheck only exists in PowerShell 6+. On 5.1 the equivalent is a global trust
  # callback, set once below. Certificates are only in play for a real domain, where they validate
  # anyway; this matters for the brief window before one has been issued.
  $extra = @{}
  if ($PSVersionTable.PSVersion.Major -ge 6) { $extra["SkipCertificateCheck"] = $true }
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri $Target -TimeoutSec 5 -ErrorAction Stop @extra
    return [int]$r.StatusCode
  } catch {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    return 0
  }
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
  # PowerShell 5.1: accept the not-yet-trusted certificate during these checks only.
  Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class GrgCertPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@ -ErrorAction SilentlyContinue
  try { [System.Net.ServicePointManager]::CertificatePolicy = New-Object GrgCertPolicy } catch {}
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

$localTarget = "${SiteScheme}://127.0.0.1/api/auth/me"
$realTarget  = "${SiteScheme}://${Domain}/api/auth/me"

Write-Step "Waiting for it to come up"
$ready = $false; $waited = 0
while ($waited -lt $WaitSeconds) {
  if ((Get-AppStatus $localTarget) -in 200, 401) { $ready = $true; break }
  Start-Sleep -Seconds 2
  $waited += 2
  if ($waited % 10 -eq 0) { Write-Host "`r    still starting… ${waited}s" -NoNewline }
}
Write-Host ""

$reachable = $false
if ($ready) { $reachable = ((Get-AppStatus $realTarget) -in 200, 401) }

if ($ready -and $reachable) {
  Write-Step "GRG is ready"
} elseif ($ready) {
  Write-Step "GRG is running"
  Write-Info "Everything started correctly."
  Write-Info "This machine can't reach itself at $Domain — usually just the name not"
  Write-Info "pointing here yet. It may already work from other computers; try it."
} else {
  Write-Step "Started — still coming up"
  Write-Info "Everything is installed and running. It hadn't answered after ${waited}s,"
  Write-Info "which is normal on a slow machine. Open the address in a minute."
  Write-Info "If it still doesn't: docker compose logs -f backend proxy"
}

Write-Host ""
Write-Host "  Open        ${SiteScheme}://${Domain}"
if ($ready -and -not $reachable) {
  Write-Host "  From this machine itself, use ${SiteScheme}://localhost" -ForegroundColor DarkGray
}
Write-Host "  Installed   $InstallDir"

if ($freshInstall) {
  Write-Host ""
  Write-Host "  Sign in     $AdminEmail"
  Write-Host "  Password    $AdminPassword"
  Write-Host ""
  Write-Host "  Write that password down now. GRG will ask you to change it the first" -ForegroundColor Yellow
  Write-Host "  time you sign in. If you lose it before then, it's in .env:" -ForegroundColor Yellow
  Write-Host "      Select-String FIRST_ADMIN_PASSWORD `"$envPath`"" -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Back up $envPath somewhere safe. It holds the key that" -ForegroundColor Yellow
  Write-Host "  unlocks your data; a backup restored without it can't be read." -ForegroundColor Yellow
} else {
  Write-Host ""
  Write-Host "  Sign in     $AdminEmail"
  Write-Host "  Your password hasn't changed. To see it:" -ForegroundColor DarkGray
  Write-Host "      Select-String FIRST_ADMIN_PASSWORD `"$envPath`"" -ForegroundColor DarkGray
}

Write-Host @"

  See what's happening   cd $InstallDir; docker compose logs -f
  Restart                cd $InstallDir; docker compose restart
  Update to the latest   $InstallDir\install.ps1 -Yes

  Note: Docker Desktop starts when you log in, not when Windows boots. After a
  restart, sign in to this machine and GRG comes back up on its own.

"@
