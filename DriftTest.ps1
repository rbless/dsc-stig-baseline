#Requires -RunAsAdministrator
<#
.SYNOPSIS
    tests this node against all compiled dsc stig configurations and reports drift.

.DESCRIPTION
    loops over all target subfolders under C:\DSC\MOF\ and runs
    Test-DscConfiguration against each one. produces:
      - console output with per-target pass/fail summary
      - a timestamped json report in C:\DSC\Logs\ aggregating all targets

    returns exit code 0 if all targets compliant, 1 if any drift detected.
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

    ##### check if the mof directory exists — if missing, bootstrap has not run yet, abort #####
    if (-not (Test-Path $mofpath)) {
        throw "mof directory not found at '$mofpath'. run Bootstrap.ps1 first."
    }

    ##### find all subfolders under MOF\ that contain at least one .mof file — each is one compiled stig target #####
    $mofdirs = Get-ChildItem -Path $mofpath -Directory | Where-Object {
        Get-ChildItem -Path $_.FullName -Filter '*.mof' -ErrorAction SilentlyContinue
    }

    if (-not $mofdirs) {
        throw "no .mof files found in '$mofpath'. run Bootstrap.ps1 to compile configurations."
    }

    Write-Log "targets to test: $($mofdirs.Name -join ', ')"

    ##### pull last apply status from the lcm once — not per-target since the lcm only tracks one active config at a time #####
    $lastrun = Get-DscConfigurationStatus -ErrorAction SilentlyContinue
    $lastruninfo = if ($lastrun) {
        [ordered]@{
            status          = $lastrun.Status
            startdate       = $lastrun.StartDate
            durationmins    = [math]::Round($lastrun.Duration.TotalMinutes, 2)
            rebootrequested = $lastrun.RebootRequested
            type            = $lastrun.Type
            mode            = $lastrun.Mode
        }
    } else { $null }

    $targetresults   = [System.Collections.Generic.List[object]]::new()
    $totaldrifted    = 0
    $totalcompliant  = 0
    $anydrift        = $false

    ##### iterate each mof subfolder and run a detailed compliance test — collect per-resource results for the json report #####
    foreach ($mofdir in $mofdirs) {
        $target = $mofdir.Name
        Write-Log "--- testing: $target ---"

        $result = Test-DscConfiguration -Path $mofdir.FullName -Detailed

        $indesiredstate = $result.InDesiredState
        $driftedcount   = $result.ResourcesNotInDesiredState.Count
        $compliantcount = $result.ResourcesInDesiredState.Count

        $totalcompliant += $compliantcount
        $totaldrifted   += $driftedcount

        if (-not $indesiredstate) {
            $anydrift = $true
            Write-Log "$target — drift detected: $driftedcount resource(s) out of desired state" 'warn'

            ##### log each drifted resource id individually so the log shows exactly which controls slipped #####
            $result.ResourcesNotInDesiredState | ForEach-Object {
                Write-Log "  [drift] $($_.ResourceId)" 'warn'
            }
        } else {
            Write-Log "$target — compliant: all $compliantcount resources in desired state"
        }

        ##### build per-target result block for the json report #####
        $targetresults.Add([ordered]@{
            target              = $target
            indesiredstate      = $indesiredstate
            compliantresources  = $compliantcount
            driftedresources    = $driftedcount
            drifted             = @(
                $result.ResourcesNotInDesiredState | ForEach-Object {
                    [ordered]@{
                        resourceid   = $_.ResourceId
                        modulename   = $_.ModuleName
                        durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                    }
                }
            )
            compliant           = @(
                $result.ResourcesInDesiredState | ForEach-Object {
                    [ordered]@{
                        resourceid   = $_.ResourceId
                        modulename   = $_.ModuleName
                        durationsecs = [math]::Round($_.Duration.TotalSeconds, 2)
                    }
                }
            )
        })
    }

    ##### build the top-level report aggregating all target results #####
    $report = [ordered]@{
        computername            = $env:COMPUTERNAME
        timestamp               = (Get-Date -Format 'o')
        overallindesiredstate   = (-not $anydrift)
        totalcompliantresources = $totalcompliant
        totaldriftedresources   = $totaldrifted
        lastconfigurationstatus = $lastruninfo
        targets                 = $targetresults
    }

    ##### serialize the aggregated report to json and write to disk #####
    $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $reportfile -Encoding UTF8
    Write-Log "report written: $reportfile"

    ##### branch on overall compliance — auto-remediate if enabled, otherwise exit 1 to signal drift to the pipeline #####
    if (-not $anydrift) {
        Write-Log "result: compliant — all targets in desired state ($totalcompliant resources)"
        Write-Log "========== drift test complete =========="
        exit 0
    } else {
        Write-Log "result: drift detected — $totaldrifted resource(s) out of desired state across all targets" 'warn'

        if ($autoremediate) {
            Write-Log "autoremediate is enabled — invoking Apply.ps1" 'warn'
            $applyscript = Join-Path $dscroot 'Apply.ps1'
            & $applyscript -dscroot $dscroot
        } else {
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
