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

function Write-Log {
    param(
        [string]$message,
        [ValidateSet('info','warn','error')]
        [string]$level = 'info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $message"
    Add-Content -Path $logfile -Value $entry
}

# ---------------------------------------------------------------------------
# helpers — write-step/ok/fail mirror the log to file alongside console output
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$msg)
    Write-Host "`n==> $msg" -ForegroundColor Cyan
    Write-Log $msg
}
function Write-OK {
    param([string]$msg)
    Write-Host "    [OK] $msg" -ForegroundColor Green
    Write-Log "[ok] $msg"
}
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

# abort early if the version file is missing — nothing else can proceed without it
if (-not (Test-Path $versionfile)) { Write-Fail "version file not found at $versionfile" }

$versiondata = Get-Content $versionfile -Raw | ConvertFrom-Json

# allow caller to override the version number (e.g. from a pipeline variable)
if ($packageversion) {
    $versiondata.PackageVersion = $packageversion
}

$version   = $versiondata.PackageVersion
$builddate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# stamp build metadata into the version object before it gets written into the package
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

# these modules must be pre-downloaded by VendorModules.ps1 — no internet on target vms
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

# check each required module directory exists under the vendor output path
foreach ($mod in $requiredmodules) {
    $modpath = Join-Path $modulespath $mod
    if (Test-Path $modpath) {
        Write-OK $mod
    } else {
        $missingmodules += $mod
        Write-Host "    [MISS] $mod" -ForegroundColor Yellow
    }
}

# fail the build if any required modules are absent
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

# use a unique temp path so parallel builds don't collide
$stagingroot = Join-Path $env:TEMP "DSC_staging_$(Get-Date -Format 'yyyyMMddHHmmss')"
$dscstage    = Join-Path $stagingroot 'DSC'

# create the full folder structure that will exist on the vm after the zip is extracted
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

# drop .gitkeep placeholders in empty runtime folders so the zip extraction preserves them
foreach ($runtimefolder in @('Downloads', 'Logs', 'MOF', 'LCM', 'Reports', 'History')) {
    $placeholder = Join-Path $dscstage "$runtimefolder\.gitkeep"
    '' | Out-File -FilePath $placeholder -Encoding ASCII
}

# ---------------------------------------------------------------------------
# step 4: copy scripts and configs
# ---------------------------------------------------------------------------
Write-Step "copying scripts and configuration files"

# list of source files relative to sourceroot and their destination subfolder in the package
$filestocopy = @(
    @{ src = 'Bootstrap.ps1';                            dst = '' }
    @{ src = 'Apply.ps1';                                dst = '' }
    @{ src = 'DriftTest.ps1';                            dst = '' }
    @{ src = 'Configurations\WindowsServer2016STIG.ps1'; dst = 'Configurations' }
)

foreach ($file in $filestocopy) {
    $srcpath = Join-Path $sourceroot $file.src
    $dstdir  = if ($file.dst) { Join-Path $dscstage $file.dst } else { $dscstage }
    if (-not (Test-Path $srcpath)) { Write-Fail "source file not found: $srcpath" }
    Copy-Item -Path $srcpath -Destination $dstdir -Force
    Write-OK $file.src
}

# ---------------------------------------------------------------------------
# step 5: write stamped version into package
# ---------------------------------------------------------------------------
Write-Step "writing stamped version into package"

# overwrite the version file in staging with the build-stamped copy
$stampedversionpath = Join-Path $dscstage 'VERSION'
$versiondata | ConvertTo-Json -Depth 5 | Out-File -FilePath $stampedversionpath -Encoding UTF8
Write-OK "version stamped"

# ---------------------------------------------------------------------------
# step 6: copy vendored modules
# ---------------------------------------------------------------------------
Write-Step "copying vendored modules"

$moduledest = Join-Path $dscstage 'Modules'

# copy each module folder wholesale into the package modules directory
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

# remove any existing zip for this version before recreating it
if (Test-Path $zippath) {
    Remove-Item $zippath -Force
    Write-Host "    removed existing $zipname"
}

# use .net compression directly — avoids Compress-Archive 2gb limit
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stagingroot,   # zip from staging root so DSC\ is the top-level folder in the archive
    $zippath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false          # don't include the staging root directory name itself in the zip
)

Write-OK "zip created: $zippath"

# remove the temp staging tree now that the zip is built
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
