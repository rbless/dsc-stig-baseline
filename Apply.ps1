#Requires -RunAsAdministrator
<#
.SYNOPSIS
    applies all compiled dsc stig configurations to this node.

.DESCRIPTION
    loops over all target subfolders under C:\DSC\MOF\ and calls
    Start-DscConfiguration against each one. each subfolder corresponds
    to a detected product (e.g. WS2016, SQL2014) compiled by Bootstrap.ps1.

    run Bootstrap.ps1 first if mofs have not yet been compiled.

.PARAMETER dscroot
    root path where the dsc zip was extracted. default: C:\DSC

.PARAMETER force
    re-applies all resources even if already in desired state. default: $true

.EXAMPLE
    .\Apply.ps1
    .\Apply.ps1 -Force $false
#>

[CmdletBinding()]
param (
    [string]$dscroot = 'C:\DSC',
    [bool]$force     = $true
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$logdir  = Join-Path $dscroot 'Logs'
$null    = New-Item -ItemType Directory -Path $logdir -Force
$logfile = Join-Path $logdir "Apply_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

##### write-log: accepts a message string and optional level (info/warn/error). builds a timestamped entry string, appends it to the log file, then routes output to write-warning, write-error, or write-host depending on level #####
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
    Write-Log "========== apply started on $env:COMPUTERNAME =========="
    Write-Log "force: $force"

    $mofpath = Join-Path $dscroot 'MOF'

    ##### check if the mof directory exists — if missing, bootstrap has not run yet, abort #####
    if (-not (Test-Path $mofpath)) {
        throw "mof directory not found at '$mofpath'. run Bootstrap.ps1 first."
    }

    ##### find all subfolders under MOF\ that contain at least one .mof file — each subfolder is one compiled stig target #####
    $mofdirs = Get-ChildItem -Path $mofpath -Directory | Where-Object {
        Get-ChildItem -Path $_.FullName -Filter '*.mof' -ErrorAction SilentlyContinue
    }

    if (-not $mofdirs) {
        throw "no .mof files found in '$mofpath'. run Bootstrap.ps1 to compile configurations."
    }

    Write-Log "targets to apply: $($mofdirs.Name -join ', ')"

    $applied  = 0
    $drifted  = 0

    ##### iterate each mof subfolder and apply the configuration — wait for completion before moving to the next target #####
    foreach ($mofdir in $mofdirs) {
        $target = $mofdir.Name
        Write-Log "--- applying: $target ---"

        $params = @{
            Path    = $mofdir.FullName
            Wait    = $true
            Verbose = $true
            Force   = $force
        }

        Start-DscConfiguration @params

        ##### post-apply compliance check — warns if not fully in desired state, which may indicate a pending reboot #####
        $testresult = Test-DscConfiguration -Path $mofdir.FullName
        if ($testresult) {
            Write-Log "$target — in desired state"
        } else {
            Write-Log "$target — not fully in desired state. a reboot may be required." 'warn'
            $drifted++
        }

        $applied++
    }

    if ($drifted -gt 0) {
        Write-Log "========== apply complete — $applied target(s) applied, $drifted may require reboot ==========" 'warn'
        Write-Log "if RebootNodeIfNeeded is true in lcm, the system will reboot and continue automatically." 'warn'
    } else {
        Write-Log "========== apply complete — all $applied target(s) in desired state =========="
    }
}
catch {
    Write-Log "fatal error: $_" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace)" 'error'
    exit 1
}
