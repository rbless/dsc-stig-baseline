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
    Write-Log "========== drift test started on $env:COMPUTERNAME =========="

    $mofpath = Join-Path $dscroot 'MOF'

    ##### check if the mof directory exists — if missing, bootstrap has not run yet, throw and abort before attempting a test against nothing #####
    if (-not (Test-Path $mofpath)) {
        throw "mof directory not found at '$mofpath'. run Bootstrap.ps1 first."
    }

    ##### run Test-DscConfiguration against the compiled mof with -detailed to get per-resource pass/fail results rather than a single boolean #####
    Write-Log "running Test-DscConfiguration..."
    $result = Test-DscConfiguration -Path $mofpath -Detailed

    $indesiredstate = $result.InDesiredState
    $driftedcount   = $result.ResourcesNotInDesiredState.Count
    $compliantcount = $result.ResourcesInDesiredState.Count

    ##### build a structured ordered hashtable for json serialization — captures node name, timestamp, overall state, and per-resource detail for both drifted and compliant resources #####
    $report = [ordered]@{
        computername           = $env:COMPUTERNAME
        timestamp              = (Get-Date -Format 'o')
        indesiredstate         = $indesiredstate
        compliantresourcecount = $compliantcount
        driftedresourcecount   = $driftedcount
        driftedresources       = @(
            ##### iterate each resource that failed the test — captures resourceid, module name, and how long the test took for triage #####
            $result.ResourcesNotInDesiredState | ForEach-Object {
                [ordered]@{
                    resourceid   = $_.ResourceId
                    modulename   = $_.ModuleName
                    durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
        compliantresources     = @(
            ##### iterate each resource that passed the test — same shape as driftedresources for consistent report structure #####
            $result.ResourcesInDesiredState | ForEach-Object {
                [ordered]@{
                    resourceid   = $_.ResourceId
                    modulename   = $_.ModuleName
                    durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                }
            }
        )
    }

    ##### serialize the report hashtable to json and write it to disk — used by pipelines and audit processes to consume results without parsing log text #####
    $report | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportfile -Encoding UTF8
    Write-Log "report written: $reportfile"

    ##### branch on overall compliance result — exit 0 if clean, otherwise log each drifted resource and optionally invoke Apply.ps1 to remediate #####
    if ($indesiredstate) {
        Write-Log "result: compliant — all $compliantcount resources in desired state"
        Write-Log "========== drift test complete =========="
        exit 0
    }
    else {
        Write-Log "result: drift detected — $driftedcount resource(s) out of desired state" 'warn'

        ##### iterate each drifted resource and log its id individually so the log shows exactly which controls slipped without requiring json parsing #####
        $result.ResourcesNotInDesiredState | ForEach-Object {
            Write-Log "  [drift] $($_.ResourceId)" 'warn'
        }

        ##### check autoremediate flag — if true, call Apply.ps1 to push the config back into desired state. if false, log that manual remediation is needed and exit 1 #####
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
