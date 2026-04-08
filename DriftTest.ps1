#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tests this node against the DSC STIG configuration and reports any drift.

.DESCRIPTION
    Runs Test-DscConfiguration and produces:
      - Console output with pass/fail summary
      - A timestamped JSON report in C:\DSC\Logs\

    Returns exit code 0 if compliant, 1 if drift detected.
    Suitable for use as a scheduled task or pipeline health check.

.PARAMETER DSCRoot
    Root path where the DSC ZIP was extracted. Default: C:\DSC

.PARAMETER AutoRemediate
    If $true, calls Apply.ps1 automatically when drift is detected. Default: $false

.EXAMPLE
    .\DriftTest.ps1
    .\DriftTest.ps1 -AutoRemediate $true
#>

[CmdletBinding()]
param (
    [string]$DSCRoot       = 'C:\DSC',
    [bool]$AutoRemediate   = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogDir    = Join-Path $DSCRoot 'Logs'
$null      = New-Item -ItemType Directory -Path $LogDir -Force
$LogFile   = Join-Path $LogDir "DriftTest_$Timestamp.log"
$ReportFile = Join-Path $LogDir "DriftReport_$Timestamp.json"

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
    Write-Log "========== Drift Test started on $env:COMPUTERNAME =========="

    $MofPath = Join-Path $DSCRoot 'MOF'
    if (-not (Test-Path $MofPath)) {
        throw "MOF directory not found at '$MofPath'. Run Bootstrap.ps1 first."
    }

    Write-Log "Running Test-DscConfiguration..."
    $result = Test-DscConfiguration -Detailed

    $inDesiredState = $result.InDesiredState
    $driftedCount   = $result.ResourcesNotInDesiredState.Count
    $compliantCount = $result.ResourcesInDesiredState.Count

    # Build report object
    $report = [ordered]@{
        ComputerName           = $env:COMPUTERNAME
        Timestamp              = (Get-Date -Format 'o')
        InDesiredState         = $inDesiredState
        CompliantResourceCount = $compliantCount
        DriftedResourceCount   = $driftedCount
        DriftedResources       = @(
            $result.ResourcesNotInDesiredState | ForEach-Object {
                [ordered]@{
                    ResourceId   = $_.ResourceId
                    ModuleName   = $_.ModuleName
                    DurationSecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
        CompliantResources     = @(
            $result.ResourcesInDesiredState | ForEach-Object {
                [ordered]@{
                    ResourceId   = $_.ResourceId
                    ModuleName   = $_.ModuleName
                    DurationSecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
    }

    # Write JSON report
    $report | ConvertTo-Json -Depth 6 | Out-File -FilePath $ReportFile -Encoding UTF8
    Write-Log "Report written: $ReportFile"

    # Summary
    if ($inDesiredState) {
        Write-Log "RESULT: COMPLIANT — All $compliantCount resources in desired state"
        Write-Log "========== Drift Test complete =========="
        exit 0
    }
    else {
        Write-Log "RESULT: DRIFT DETECTED — $driftedCount resource(s) out of desired state" 'WARN'
        $result.ResourcesNotInDesiredState | ForEach-Object {
            Write-Log "  [DRIFT] $($_.ResourceId)" 'WARN'
        }

        if ($AutoRemediate) {
            Write-Log "AutoRemediate is enabled — invoking Apply.ps1" 'WARN'
            $ApplyScript = Join-Path $DSCRoot 'Apply.ps1'
            & $ApplyScript -DSCRoot $DSCRoot
        }
        else {
            Write-Log "AutoRemediate is disabled. Run Apply.ps1 manually to remediate." 'WARN'
        }

        Write-Log "========== Drift Test complete =========="
        exit 1
    }
}
catch {
    Write-Log "FATAL ERROR: $_" 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
    exit 2
}
