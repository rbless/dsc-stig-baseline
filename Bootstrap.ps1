#Requires -RunAsAdministrator
<#
.SYNOPSIS
    bootstraps the dsc environment on a freshly provisioned vm.

.DESCRIPTION
    performs three steps in sequence:
      1. installs vendored powershell modules from C:\DSC\Modules (no internet required)
      2. configures the local configuration manager (lcm)
      3. compiles the dsc configuration to a mof file

    run this script first after the zip is extracted.
    then run Apply.ps1 to enforce the configuration.

.PARAMETER dscroot
    root path where the dsc zip was extracted. default: C:\DSC

.PARAMETER osrole
    ms = member server (default) | dc = domain controller

.EXAMPLE
    .\Bootstrap.ps1
    .\Bootstrap.ps1 -OsRole dc
#>

[CmdletBinding()]
param (
    [string]$dscroot = 'C:\DSC',

    [ValidateSet('ms', 'dc')]
    [string]$osrole = 'ms'
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$logdir  = Join-Path $dscroot 'Logs'
$null    = New-Item -ItemType Directory -Path $logdir -Force
$logfile = Join-Path $logdir "Bootstrap_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$message,
        [ValidateSet('info','warn','error')]
        [string]$level = 'info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $message"
    Add-Content -Path $logfile -Value $entry
    switch ($level) {
        'warn'  { Write-Warning $entry }
        'error' { Write-Error   $entry }
        default { Write-Host    $entry }
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
try {
    Write-Log "========== bootstrap started on $env:COMPUTERNAME =========="
    Write-Log "dscroot : $dscroot"
    Write-Log "osrole  : $osrole"
    Write-Log "log     : $logfile"

    # -----------------------------------------------------------------------
    # step 0: archive previous install if one exists
    # -----------------------------------------------------------------------
    Write-Log "--- step 0: checking for previous install ---"

    # check for a version file left by a prior run — if found, archive before overwriting
    $previousversionfile = Join-Path $dscroot 'VERSION'
    if (Test-Path $previousversionfile) {
        try {
            # read the previous version number to use as the archive folder name
            $prevversion = (Get-Content $previousversionfile -Raw | ConvertFrom-Json).PackageVersion
            $archivename = "v${prevversion}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $archivedest = Join-Path $dscroot "History\$archivename"

            $null = New-Item -ItemType Directory -Path $archivedest -Force

            # copy scripts and configs only — skip modules (too large) and runtime folders
            $toarchive = @('Bootstrap.ps1','Apply.ps1','DriftTest.ps1','VERSION','Configurations')
            foreach ($item in $toarchive) {
                $itempath = Join-Path $dscroot $item
                if (Test-Path $itempath) {
                    Copy-Item -Path $itempath -Destination $archivedest -Recurse -Force
                }
            }

            Write-Log "previous v$prevversion archived to History\$archivename"
        }
        catch {
            # archiving failure is non-fatal — log and continue with install
            Write-Log "could not archive previous install (non-fatal): $_" 'warn'
        }
    }
    else {
        Write-Log "no previous install detected — fresh deployment"
    }

    # -----------------------------------------------------------------------
    # step 1: install vendored modules
    # -----------------------------------------------------------------------
    Write-Log "--- step 1: installing vendored modules ---"

    $modulesource = Join-Path $dscroot 'Modules'
    $moduledest   = "$env:ProgramFiles\WindowsPowerShell\Modules"

    # abort if the vendored modules folder is missing from the extracted package
    if (-not (Test-Path $modulesource)) {
        throw "module source path not found: $modulesource"
    }

    # iterate each module subdirectory and copy it into the system module path
    Get-ChildItem -Path $modulesource -Directory | ForEach-Object {
        $destpath = Join-Path $moduledest $_.Name
        # remove existing version first to avoid stale file conflicts
        if (Test-Path $destpath) {
            Write-Log "removing existing module: $($_.Name)"
            Remove-Item -Path $destpath -Recurse -Force
        }
        Copy-Item -Path $_.FullName -Destination $destpath -Recurse -Force
        Write-Log "installed: $($_.Name)"
    }

    Write-Log "all modules installed"

    # -----------------------------------------------------------------------
    # step 2: configure lcm
    # -----------------------------------------------------------------------
    Write-Log "--- step 2: configuring local configuration manager ---"

    # define the lcm meta-configuration inline — push mode with auto-reboot enabled
    [DSCLocalConfigurationManager()]
    Configuration lcmsettings {
        Node localhost {
            Settings {
                RefreshMode                    = 'push'
                ConfigurationMode              = 'applyandmonitor'
                RebootNodeIfNeeded             = $true
                ActionAfterReboot              = 'continueconfiguration'
                ConfigurationModeFrequencyMins = 15
                AllowModuleOverwrite           = $true
            }
        }
    }

    $lcmpath = Join-Path $dscroot 'LCM'
    $null    = New-Item -ItemType Directory -Path $lcmpath -Force

    # compile the lcm meta-configuration to a meta-mof, then apply it
    lcmsettings -OutputPath $lcmpath | Out-Null
    Set-DscLocalConfigurationManager -Path $lcmpath -Force -Verbose
    Write-Log "lcm configured (mode: applyandmonitor, push)"

    # -----------------------------------------------------------------------
    # step 3: compile mof
    # -----------------------------------------------------------------------
    Write-Log "--- step 3: compiling dsc configuration ---"

    $configscript = Join-Path $dscroot 'Configurations\WindowsServer2016STIG.ps1'

    # abort if the configuration script is missing from the extracted package
    if (-not (Test-Path $configscript)) {
        throw "configuration script not found: $configscript"
    }

    # dot-source to load the Configuration block into the current scope so it can be called
    . $configscript

    $mofpath = Join-Path $dscroot 'MOF'
    $null    = New-Item -ItemType Directory -Path $mofpath -Force

    # compile the configuration to a mof file targeting localhost
    windowsserver2016stig `
        -NodeName   'localhost' `
        -OsRole     $osrole `
        -OutputPath $mofpath

    # verify the mof was actually produced before declaring success
    $moffile = Get-ChildItem -Path $mofpath -Filter '*.mof' | Select-Object -First 1
    if (-not $moffile) {
        throw "mof compilation produced no output in $mofpath"
    }

    Write-Log "mof compiled: $($moffile.FullName)"
    Write-Log "========== bootstrap complete. run Apply.ps1 to enforce configuration. =========="
}
catch {
    Write-Log "fatal error: $_" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace)" 'error'
    exit 1
}
