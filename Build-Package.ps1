#Requires -Version 5.1
<#
.SYNOPSIS
    Assembles the DSC package and produces a versioned ZIP ready for Blob Storage.

.DESCRIPTION
    Run this on your dev machine or in your Azure DevOps pipeline (build agent).
    Do NOT run on the target VMs.

    What it does:
      1. Reads version from VERSION file
      2. Validates that vendored modules exist
      3. Assembles the full C:\DSC folder structure into a staging directory
      4. Stamps BUILD date and builder name into VERSION
      5. Outputs DSC_v<version>.zip ready to upload to Blob Storage

.PARAMETER SourceRoot
    Root of this repo / working directory. Default: script directory.

.PARAMETER ModulesPath
    Where VendorModules.ps1 dropped the downloaded modules.
    Default: <SourceRoot>\VendorOutput\Modules

.PARAMETER OutputPath
    Where the final ZIP is written. Default: <SourceRoot>\dist

.PARAMETER PackageVersion
    Override the version in the VERSION file. Optional.

.PARAMETER BuiltBy
    Name/identity stamped into VERSION. Defaults to current user.

.EXAMPLE
    .\Build-Package.ps1
    .\Build-Package.ps1 -PackageVersion '1.2.0' -BuiltBy 'pipeline-agent'
#>

[CmdletBinding()]
param (
    [string]$SourceRoot     = $PSScriptRoot,
    [string]$ModulesPath    = (Join-Path $PSScriptRoot 'VendorOutput\Modules'),
    [string]$OutputPath     = (Join-Path $PSScriptRoot 'dist'),
    [string]$PackageVersion = '',
    [string]$BuiltBy        = $env:USERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$LogDir  = Join-Path $SourceRoot 'Logs'
$null    = New-Item -ItemType Directory -Path $LogDir -Force
$LogFile = Join-Path $LogDir "Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$Msg)
    Write-Host "`n==> $Msg" -ForegroundColor Cyan
    Write-Log $Msg
}
function Write-OK {
    param([string]$Msg)
    Write-Host "    [OK] $Msg" -ForegroundColor Green
    Write-Log "[OK] $Msg"
}
function Write-Fail {
    param([string]$Msg)
    Write-Log $Msg 'ERROR'
    Write-Error "    [FAIL] $Msg"
}

try {

# ---------------------------------------------------------------------------
# Step 1: Load and validate VERSION
# ---------------------------------------------------------------------------
Write-Step "Loading VERSION metadata"

$VersionFile = Join-Path $SourceRoot 'VERSION'
if (-not (Test-Path $VersionFile)) { Write-Fail "VERSION file not found at $VersionFile" }

$VersionData = Get-Content $VersionFile -Raw | ConvertFrom-Json

if ($PackageVersion) {
    $VersionData.PackageVersion = $PackageVersion
}

$Version   = $VersionData.PackageVersion
$BuildDate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# Stamp build metadata
$VersionData.BuildDate = $BuildDate
$VersionData.BuiltBy   = $BuiltBy

Write-OK "Package version : $Version"
Write-OK "STIG version    : $($VersionData.StigVersion)"
Write-OK "Built by        : $BuiltBy"
Write-OK "Build date      : $BuildDate"

# ---------------------------------------------------------------------------
# Step 2: Validate vendored modules exist
# ---------------------------------------------------------------------------
Write-Step "Validating vendored modules at: $ModulesPath"

$RequiredModules = @(
    'PowerSTIG'
    'PSDscResources'
    'SecurityPolicyDsc'
    'AuditPolicyDsc'
    'AccessControlDsc'
    'FileContentDsc'
    'xDnsServer'
    'xWebAdministration'
)

$missingModules = @()
foreach ($mod in $RequiredModules) {
    $modPath = Join-Path $ModulesPath $mod
    if (Test-Path $modPath) {
        Write-OK $mod
    } else {
        $missingModules += $mod
        Write-Host "    [MISS] $mod" -ForegroundColor Yellow
    }
}

if ($missingModules.Count -gt 0) {
    Write-Fail @"
Missing modules: $($missingModules -join ', ')
Run VendorModules.ps1 on an internet-connected machine first:
    .\VendorModules.ps1 -OutputPath '$ModulesPath'
"@
}

# ---------------------------------------------------------------------------
# Step 3: Create staging directory
# ---------------------------------------------------------------------------
Write-Step "Creating staging directory"

$StagingRoot = Join-Path $env:TEMP "DSC_staging_$(Get-Date -Format 'yyyyMMddHHmmss')"
$DSCStage    = Join-Path $StagingRoot 'DSC'

# Full folder structure that will exist on the VM after unzip
$Folders = @(
    ''                    # DSC root
    'Configurations'      # PS1 config scripts
    'Modules'             # Vendored PSModules
    'Downloads'           # Runtime staging (empty in ZIP, used by scripts at runtime)
    'Logs'                # Runtime logs (empty in ZIP)
    'MOF'                 # Compiled at bootstrap (empty in ZIP)
    'LCM'                 # LCM meta-MOF (empty in ZIP)
    'Reports'             # Drift JSON reports
    'History'             # Previous installs archived by Bootstrap
)

foreach ($folder in $Folders) {
    $path = if ($folder) { Join-Path $DSCStage $folder } else { $DSCStage }
    $null = New-Item -ItemType Directory -Path $path -Force
    Write-OK "Created: DSC\$folder"
}

# Drop .gitkeep placeholders in empty runtime folders so unzip preserves them
foreach ($runtimeFolder in @('Downloads', 'Logs', 'MOF', 'LCM', 'Reports', 'History')) {
    $placeholder = Join-Path $DSCStage "$runtimeFolder\.gitkeep"
    '' | Out-File -FilePath $placeholder -Encoding ASCII
}

# ---------------------------------------------------------------------------
# Step 4: Copy scripts and configs
# ---------------------------------------------------------------------------
Write-Step "Copying scripts and configuration files"

$FilesToCopy = @(
    @{ Src = 'Bootstrap.ps1';                          Dst = '' }
    @{ Src = 'Apply.ps1';                              Dst = '' }
    @{ Src = 'DriftTest.ps1';                          Dst = '' }
    @{ Src = 'Configurations\WindowsServer2016STIG.ps1'; Dst = 'Configurations' }
)

foreach ($file in $FilesToCopy) {
    $srcPath = Join-Path $SourceRoot $file.Src
    $dstDir  = if ($file.Dst) { Join-Path $DSCStage $file.Dst } else { $DSCStage }
    if (-not (Test-Path $srcPath)) { Write-Fail "Source file not found: $srcPath" }
    Copy-Item -Path $srcPath -Destination $dstDir -Force
    Write-OK $file.Src
}

# ---------------------------------------------------------------------------
# Step 5: Write stamped VERSION into package
# ---------------------------------------------------------------------------
Write-Step "Writing stamped VERSION into package"

$StampedVersionPath = Join-Path $DSCStage 'VERSION'
$VersionData | ConvertTo-Json -Depth 5 | Out-File -FilePath $StampedVersionPath -Encoding UTF8
Write-OK "VERSION stamped"

# ---------------------------------------------------------------------------
# Step 6: Copy vendored modules
# ---------------------------------------------------------------------------
Write-Step "Copying vendored modules"

$ModuleDest = Join-Path $DSCStage 'Modules'
Get-ChildItem -Path $ModulesPath -Directory | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $ModuleDest $_.Name) -Recurse -Force
    Write-OK $_.Name
}

# ---------------------------------------------------------------------------
# Step 7: Build ZIP
# ---------------------------------------------------------------------------
Write-Step "Building ZIP"

$null = New-Item -ItemType Directory -Path $OutputPath -Force

$ZipName = "DSC_v$Version.zip"
$ZipPath = Join-Path $OutputPath $ZipName

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
    Write-Host "    Removed existing $ZipName"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $StagingRoot,   # Zip from staging root so DSC\ is the top-level folder in the archive
    $ZipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false          # Don't include base directory name
)

Write-OK "ZIP created: $ZipPath"

# Cleanup staging
Remove-Item -Path $StagingRoot -Recurse -Force

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$ZipSize = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Package ready" -ForegroundColor Cyan
Write-Host "  File    : $ZipPath" -ForegroundColor White
Write-Host "  Version : $Version" -ForegroundColor White
Write-Host "  Size    : $ZipSize MB" -ForegroundColor White
Write-Host "  Next    : Upload to Azure Blob Storage" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Log "========== Build complete — $ZipName ($ZipSize MB) =========="

}
catch {
    Write-Log "FATAL ERROR: $_" 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
    Write-Error "Build failed: $_"
    exit 1
}
