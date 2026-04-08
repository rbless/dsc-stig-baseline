#Requires -RunAsAdministrator
<#
.SYNOPSIS
    tests this node against the dsc stig configuration and reports any drift.

.DESCRIPTION
    runs Test-DscConfiguration and produces:
      - console output with pass/fail summary
      - a timestamped json report in C:\DSC\Logs\

    returns exit code 0 if compliant, 1 if drift detected.
    suitable for use as a scheduled task or pipeline health check.

.PARAMETER dscroot
    root path where the dsc zip was extracted. default: C:\DSC

.PARAMETER autoremediate
    if $true, calls Apply.ps1 automatically when drift is detected. default: $false

.EXAMPLE
    .\DriftTest.ps1
    .\DriftTest.ps1 -AutoRemediate $true
#>

[CmdletBinding()]
param (
    [string]$dscroot     = 'C:\DSC',
    [bool]$autoremediate = $false
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$logdir     = Join-Path $dscroot 'Logs'
$null       = New-Item -ItemType Directory -Path $logdir -Force
$logfile    = Join-Path $logdir "DriftTest_$timestamp.log"
$reportfile = Join-Path $logdir "DriftReport_$timestamp.json"

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
    Write-Log "========== drift test started on $env:COMPUTERNAME =========="

    $mofpath = Join-Path $dscroot 'MOF'

    # abort if mof directory is missing — bootstrap must run first
    if (-not (Test-Path $mofpath)) {
        throw "mof directory not found at '$mofpath'. run Bootstrap.ps1 first."
    }

    # test the node against the compiled mof and return detailed per-resource results
    Write-Log "running Test-DscConfiguration..."
    $result = Test-DscConfiguration -Path $mofpath -Detailed

    $indesiredstate = $result.InDesiredState
    $driftedcount   = $result.ResourcesNotInDesiredState.Count
    $compliantcount = $result.ResourcesInDesiredState.Count

    # build structured report object for json serialization
    $report = [ordered]@{
        computername           = $env:COMPUTERNAME
        timestamp              = (Get-Date -Format 'o')
        indesiredstate         = $indesiredstate
        compliantresourcecount = $compliantcount
        driftedresourcecount   = $driftedcount
        driftedresources       = @(
            # enumerate each resource that failed the test and capture key identifiers
            $result.ResourcesNotInDesiredState | ForEach-Object {
                [ordered]@{
                    resourceid   = $_.ResourceId
                    modulename   = $_.ModuleName
                    durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
        compliantresources     = @(
            # enumerate each resource that passed the test
            $result.ResourcesInDesiredState | ForEach-Object {
                [ordered]@{
                    resourceid   = $_.ResourceId
                    modulename   = $_.ModuleName
                    durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
    }

    # write json report to disk for pipeline consumption or audit trail
    $report | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportfile -Encoding UTF8
    Write-Log "report written: $reportfile"

    # evaluate overall compliance and branch on result
    if ($indesiredstate) {
        Write-Log "result: compliant — all $compliantcount resources in desired state"
        Write-Log "========== drift test complete =========="
        exit 0
    }
    else {
        Write-Log "result: drift detected — $driftedcount resource(s) out of desired state" 'warn'

        # log each drifted resource by id for quick triage
        $result.ResourcesNotInDesiredState | ForEach-Object {
            Write-Log "  [drift] $($_.ResourceId)" 'warn'
        }

        # if autoremediate is enabled, invoke Apply.ps1 to push the config back into state
        if ($autoremediate) {
            Write-Log "autoremediate is enabled — invoking Apply.ps1" 'warn'
            $applyscript = Join-Path $dscroot 'Apply.ps1'
            & $applyscript -dscroot $dscroot
        }
        else {
            Write-Log "autoremediate is disabled. run Apply.ps1 manually to remediate." 'warn'
        }

        Write-Log "========== drift test complete =========="
        exit 1
    }
}
catch {
    Write-Log "fatal error: $_" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace)" 'error'
    exit 2
}
