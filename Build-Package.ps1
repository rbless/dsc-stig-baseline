#Requires -Version 5.1
<#
.SYNOPSIS
    assembles the dsc package and produces a versioned zip ready for blob storage.

.DESCRIPTION
    run this on your dev machine or in your azure devops pipeline (build agent).
    do not run on the target vms.

    what it does:
      1. reads version from version file
      2. validates that vendored modules exist
      3. assembles the full C:\DSC folder structure into a staging directory
      4. stamps build date and builder name into version
      5. outputs DSC_v<version>.zip ready to upload to blob storage

.PARAMETER sourceroot
    root of this repo / working directory. default: script directory.

.PARAMETER modulespath
    where VendorModules.ps1 dropped the downloaded modules.
    default: <sourceroot>\VendorOutput\Modules

.PARAMETER outputpath
    where the final zip is written. default: <sourceroot>\dist

.PARAMETER packageversion
    override the version in the version file. optional.

.PARAMETER builtby
    name/identity stamped into version. defaults to current user.

.EXAMPLE
    .\Build-Package.ps1
    .\Build-Package.ps1 -PackageVersion '1.2.0' -BuiltBy 'pipeline-agent'
#>

[CmdletBinding()]
param (
    [string]$sourceroot     = $PSScriptRoot,
    [string]$modulespath    = (Join-Path $PSScriptRoot 'VendorOutput\Modules'),
    [string]$outputpath     = (Join-Path $PSScriptRoot 'dist'),
    [string]$packageversion = '',
    [string]$builtby        = $env:USERNAME
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$logdir  = Join-Path $sourceroot 'Logs'
$null    = New-Item -ItemType Directory -Path $logdir -Force
$logfile = Join-Path $logdir "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

##### write-log: accepts a message string and optional level (info/warn/error). builds a timestamped entry string and appends it to the build log file only — no console output, console is handled by write-step/ok/fail #####
function Write-Log {
    param(
        [string]$message,
        [ValidateSet('info','warn','error')]
        [string]$level = 'info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $message"
    Add-Content -Path $logfile -Value $entry
}

##### write-step: prints a cyan section header to console and mirrors it to the log file — used to mark the start of each numbered build step #####
function Write-Step {
    param([string]$msg)
    Write-Host "`n==> $msg" -ForegroundColor Cyan
    Write-Log $msg
}

##### write-ok: prints a green success line to console and mirrors it to the log file — used to confirm each item within a step completed successfully #####
function Write-OK {
    param([string]$msg)
    Write-Host "    [OK] $msg" -ForegroundColor Green
    Write-Log "[ok] $msg"
}

##### write-fail: logs the message at error level then calls write-error to throw — terminates the build with a clear failure message #####
function Write-Fail {
    param([string]$msg)
    Write-Log $msg 'error'
    Write-Error "    [FAIL] $msg"
}

try {

# ---------------------------------------------------------------------------
# step 1: load and validate version
# ---------------------------------------------------------------------------
Write-Step "loading version metadata"

$versionfile = Join-Path $sourceroot 'VERSION'

##### check the version file exists before trying to parse it — if missing the repo is incomplete, fail the build immediately #####
if (-not (Test-Path $versionfile)) { Write-Fail "version file not found at $versionfile" }

$versiondata = Get-Content $versionfile -Raw | ConvertFrom-Json

##### check if a packageversion override was passed in — if so, replace the version read from file before stamping and naming the zip #####
if ($packageversion) {
    $versiondata.PackageVersion = $packageversion
}

$version   = $versiondata.PackageVersion
$builddate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

##### stamp the build metadata into the version object — these values get written into the package so the deployed zip is self-describing #####
$versiondata.BuildDate = $builddate
$versiondata.BuiltBy   = $builtby

Write-OK "package version : $version"
Write-OK "stig version    : $($versiondata.StigVersion)"
Write-OK "built by        : $builtby"
Write-OK "build date      : $builddate"

# ---------------------------------------------------------------------------
# step 2: validate vendored modules exist
# ---------------------------------------------------------------------------
Write-Step "validating vendored modules at: $modulespath"

##### these modules must be pre-downloaded by VendorModules.ps1 on an internet-connected machine — target vms have no internet access so they must be in the package #####
$requiredmodules = @(
    'PowerSTIG'
    'PSDscResources'
    'SecurityPolicyDsc'
    'AuditPolicyDsc'
    'AccessControlDsc'
    'FileContentDsc'
    'xDnsServer'
    'xWebAdministration'
)

$missingmodules = @()

##### iterate each required module name — checks if a matching directory exists under modulespath, accumulates any missing ones into missingmodules for a single combined failure message #####
foreach ($mod in $requiredmodules) {
    $modpath = Join-Path $modulespath $mod
    if (Test-Path $modpath) {
        Write-OK $mod
    } else {
        $missingmodules += $mod
        Write-Host "    [MISS] $mod" -ForegroundColor Yellow
    }
}

##### check if any modules were missing — fail the entire build with the full list rather than partially packaging an incomplete set #####
if ($missingmodules.Count -gt 0) {
    Write-Fail @"
missing modules: $($missingmodules -join ', ')
run VendorModules.ps1 on an internet-connected machine first:
    .\VendorModules.ps1 -OutputPath '$modulespath'
"@
}

# ---------------------------------------------------------------------------
# step 3: create staging directory
# ---------------------------------------------------------------------------
Write-Step "creating staging directory"

##### use a unique temp path derived from the current timestamp so parallel builds running simultaneously do not collide on the same staging folder #####
$stagingroot = Join-Path $env:TEMP "DSC_staging_$(Get-Date -Format 'yyyyMMddHHmmss')"
$dscstage    = Join-Path $stagingroot 'DSC'

##### iterate the full target folder list — creates each subdirectory in staging to mirror the exact structure that will exist on the vm after zip extraction #####
$folders = @(
    ''                    # dsc root
    'Configurations'      # ps1 config scripts
    'Modules'             # vendored psmodules
    'Downloads'           # runtime staging (empty in zip, used by scripts at runtime)
    'Logs'                # runtime logs (empty in zip)
    'MOF'                 # compiled at bootstrap (empty in zip)
    'LCM'                 # lcm meta-mof (empty in zip)
    'Reports'             # drift json reports
    'History'             # previous installs archived by bootstrap
)

foreach ($folder in $folders) {
    $path = if ($folder) { Join-Path $dscstage $folder } else { $dscstage }
    $null = New-Item -ItemType Directory -Path $path -Force
    Write-OK "created: DSC\$folder"
}

##### iterate the runtime-only folders and drop a .gitkeep placeholder in each — ensures zip extraction recreates the empty folders on the target vm #####
foreach ($runtimefolder in @('Downloads', 'Logs', 'MOF', 'LCM', 'Reports', 'History')) {
    $placeholder = Join-Path $dscstage "$runtimefolder\.gitkeep"
    '' | Out-File -FilePath $placeholder -Encoding ASCII
}

# ---------------------------------------------------------------------------
# step 4: copy scripts and configs
# ---------------------------------------------------------------------------
Write-Step "copying scripts and configuration files"

##### define source-to-destination mapping for each deployable file — dst is relative to dscstage, empty string means dsc root #####
$filestocopy = @(
    @{ src = 'Bootstrap.ps1';                            dst = '' }
    @{ src = 'Apply.ps1';                                dst = '' }
    @{ src = 'DriftTest.ps1';                            dst = '' }
    @{ src = 'Configurations\WindowsServer2016STIG.ps1'; dst = 'Configurations' }
)

##### iterate the file map — resolves full source and destination paths, checks the source exists, then copies into staging #####
foreach ($file in $filestocopy) {
    $srcpath = Join-Path $sourceroot $file.src
    $dstdir  = if ($file.dst) { Join-Path $dscstage $file.dst } else { $dscstage }
    ##### check the source file exists before attempting copy — a missing file means the repo is incomplete, fail the build #####
    if (-not (Test-Path $srcpath)) { Write-Fail "source file not found: $srcpath" }
    Copy-Item -Path $srcpath -Destination $dstdir -Force
    Write-OK $file.src
}

# ---------------------------------------------------------------------------
# step 5: write stamped version into package
# ---------------------------------------------------------------------------
Write-Step "writing stamped version into package"

##### overwrite the version file in staging with the build-stamped copy — the deployed package version file will reflect actual build time and builder identity #####
$stampedversionpath = Join-Path $dscstage 'VERSION'
$versiondata | ConvertTo-Json -Depth 5 | Out-File -FilePath $stampedversionpath -Encoding UTF8
Write-OK "version stamped"

# ---------------------------------------------------------------------------
# step 6: copy vendored modules
# ---------------------------------------------------------------------------
Write-Step "copying vendored modules"

$moduledest = Join-Path $dscstage 'Modules'

##### iterate each module directory under modulespath and copy the entire folder tree into the staging modules directory wholesale #####
Get-ChildItem -Path $modulespath -Directory | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $moduledest $_.Name) -Recurse -Force
    Write-OK $_.Name
}

# ---------------------------------------------------------------------------
# step 7: build zip
# ---------------------------------------------------------------------------
Write-Step "building zip"

$null = New-Item -ItemType Directory -Path $outputpath -Force

$zipname = "DSC_v$version.zip"
$zippath = Join-Path $outputpath $zipname

##### check if a zip for this version already exists — remove it before recreating so we don't append into a stale archive #####
if (Test-Path $zippath) {
    Remove-Item $zippath -Force
    Write-Host "    removed existing $zipname"
}

##### use .net ZipFile directly rather than Compress-Archive — avoids the 2gb size limit that Compress-Archive hits with large module sets #####
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stagingroot,   # zip from staging root so DSC\ is the top-level folder in the archive
    $zippath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false          # do not include the staging root directory name itself in the zip
)

Write-OK "zip created: $zippath"

##### remove the temp staging tree now that the zip is sealed — keeps the temp directory clean between builds #####
Remove-Item -Path $stagingroot -Recurse -Force

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
$zipsize = [math]::Round((Get-Item $zippath).Length / 1MB, 2)
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  package ready" -ForegroundColor Cyan
Write-Host "  file    : $zippath" -ForegroundColor White
Write-Host "  version : $version" -ForegroundColor White
Write-Host "  size    : $zipsize mb" -ForegroundColor White
Write-Host "  next    : upload to azure blob storage" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Log "========== build complete — $zipname ($zipsize mb) =========="

}
catch {
    Write-Log "fatal error: $_" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace)" 'error'
    Write-Error "build failed: $_"
    exit 1
}
