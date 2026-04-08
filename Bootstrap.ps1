#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstraps the DSC environment on a freshly provisioned VM.

.DESCRIPTION
    Performs three steps in sequence:
      1. Installs vendored PowerShell modules from C:\DSC\Modules (no internet required)
      2. Configures the Local Configuration Manager (LCM)
      3. Compiles the DSC configuration to a MOF file

    Run this script FIRST after the ZIP is extracted.
    Then run Apply.ps1 to enforce the configuration.

.PARAMETER DSCRoot
    Root path where the DSC ZIP was extracted. Default: C:\DSC

.PARAMETER OsRole
    MS = Member Server (default) | DC = Domain Controller

.EXAMPLE
    .\Bootstrap.ps1
    .\Bootstrap.ps1 -OsRole DC
#>

[CmdletBinding()]
param (
    [string]$DSCRoot = 'C:\DSC',

    [ValidateSet('MS', 'DC')]
    [string]$OsRole = 'MS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$LogDir  = Join-Path $DSCRoot 'Logs'
$null    = New-Item -ItemType Directory -Path $LogDir -Force
$LogFile = Join-Path $LogDir "Bootstrap_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        'WARN'  { Write-Warning $entry }
        'ERROR' { Write-Error   $entry }
        default { Write-Host    $entry }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-Log "========== Bootstrap started on $env:COMPUTERNAME =========="
    Write-Log "DSCRoot : $DSCRoot"
    Write-Log "OsRole  : $OsRole"
    Write-Log "Log     : $LogFile"

    # -----------------------------------------------------------------------
    # Step 0: Archive previous install if one exists
    # -----------------------------------------------------------------------
    Write-Log "--- Step 0: Checking for previous install ---"

    $PreviousVersionFile = Join-Path $DSCRoot 'VERSION'
    if (Test-Path $PreviousVersionFile) {
        try {
            $PrevVersion = (Get-Content $PreviousVersionFile -Raw | ConvertFrom-Json).PackageVersion
            $ArchiveName = "v${PrevVersion}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $ArchiveDest = Join-Path $DSCRoot "History\$ArchiveName"

            $null = New-Item -ItemType Directory -Path $ArchiveDest -Force

            # Archive scripts and configs only — not modules (too large), not runtime folders
            $ToArchive = @('Bootstrap.ps1','Apply.ps1','DriftTest.ps1','VERSION','Configurations')
            foreach ($item in $ToArchive) {
                $itemPath = Join-Path $DSCRoot $item
                if (Test-Path $itemPath) {
                    Copy-Item -Path $itemPath -Destination $ArchiveDest -Recurse -Force
                }
            }

            Write-Log "Previous v$PrevVersion archived to History\$ArchiveName"
        }
        catch {
            Write-Log "Could not archive previous install (non-fatal): $_" 'WARN'
        }
    }
    else {
        Write-Log "No previous install detected — fresh deployment"
    }

    # -----------------------------------------------------------------------
    # Step 1: Install vendored modules
    # -----------------------------------------------------------------------
    Write-Log "--- Step 1: Installing vendored modules ---"

    $ModuleSource = Join-Path $DSCRoot 'Modules'
    $ModuleDest   = "$env:ProgramFiles\WindowsPowerShell\Modules"

    if (-not (Test-Path $ModuleSource)) {
        throw "Module source path not found: $ModuleSource"
    }

    Get-ChildItem -Path $ModuleSource -Directory | ForEach-Object {
        $destPath = Join-Path $ModuleDest $_.Name
        if (Test-Path $destPath) {
            Write-Log "Removing existing module: $($_.Name)"
            Remove-Item -Path $destPath -Recurse -Force
        }
        Copy-Item -Path $_.FullName -Destination $destPath -Recurse -Force
        Write-Log "Installed: $($_.Name)"
    }

    Write-Log "All modules installed"

    # -----------------------------------------------------------------------
    # Step 2: Configure LCM
    # -----------------------------------------------------------------------
    Write-Log "--- Step 2: Configuring Local Configuration Manager ---"

    [DSCLocalConfigurationManager()]
    Configuration LCMSettings {
        Node localhost {
            Settings {
                RefreshMode                    = 'Push'
                ConfigurationMode              = 'ApplyAndMonitor'
                RebootNodeIfNeeded             = $true
                ActionAfterReboot              = 'ContinueConfiguration'
                ConfigurationModeFrequencyMins = 15
                AllowModuleOverwrite           = $true
            }
        }
    }

    $LCMPath = Join-Path $DSCRoot 'LCM'
    $null    = New-Item -ItemType Directory -Path $LCMPath -Force
    LCMSettings -OutputPath $LCMPath | Out-Null
    Set-DscLocalConfigurationManager -Path $LCMPath -Force -Verbose
    Write-Log "LCM configured (Mode: ApplyAndMonitor, Push)"

    # -----------------------------------------------------------------------
    # Step 3: Compile MOF
    # -----------------------------------------------------------------------
    Write-Log "--- Step 3: Compiling DSC configuration ---"

    $ConfigScript = Join-Path $DSCRoot 'Configurations\WindowsServer2016STIG.ps1'
    if (-not (Test-Path $ConfigScript)) {
        throw "Configuration script not found: $ConfigScript"
    }

    # Dot-source to load the Configuration block into scope
    . $ConfigScript

    $MofPath = Join-Path $DSCRoot 'MOF'
    $null    = New-Item -ItemType Directory -Path $MofPath -Force

    WindowsServer2016STIG `
        -NodeName   'localhost' `
        -OsRole     $OsRole `
        -OutputPath $MofPath

    $MofFile = Get-ChildItem -Path $MofPath -Filter '*.mof' | Select-Object -First 1
    if (-not $MofFile) {
        throw "MOF compilation produced no output in $MofPath"
    }

    Write-Log "MOF compiled: $($MofFile.FullName)"
    Write-Log "========== Bootstrap complete. Run Apply.ps1 to enforce configuration. =========="
}
catch {
    Write-Log "FATAL ERROR: $_" 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
    exit 1
}
