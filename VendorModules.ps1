#Requires -Version 5.1
<#
.SYNOPSIS
    downloads all required dsc modules from psgallery for offline/air-gapped deployment.

.DESCRIPTION
    run this script ONCE on an internet-connected machine before running Build-Package.ps1.
    modules are saved to disk (not installed) so they can be bundled into the deployment zip.
    after this runs, the output folder is passed to Build-Package.ps1 via -ModulesPath.

    internet access required. does not modify the system module path.

.PARAMETER outputpath
    where to save the downloaded modules. default: <script dir>\VendorOutput\Modules

.EXAMPLE
    .\VendorModules.ps1
    .\VendorModules.ps1 -OutputPath 'D:\staging\Modules'
#>

[CmdletBinding()]
param (
    [string]$outputpath = 'C:\DSC\Modules'
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$logdir  = Join-Path $PSScriptRoot 'Logs'
$null    = New-Item -ItemType Directory -Path $logdir -Force
$logfile = Join-Path $logdir "VendorModules_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
# modules to vendor
# ---------------------------------------------------------------------------
##### these are the exact modules bootstrap.ps1 will install on the target vm — keep this list in sync with the requiredmodules list in build-package.ps1 #####
$modules = @(
    'PowerSTIG'
    'PSDscResources'
    'SecurityPolicyDsc'
    'AuditPolicyDsc'
    'AccessControlDsc'
    'FileContentDsc'
    'xDnsServer'
    'xWebAdministration'
)

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
try {
    Write-Log "========== vendormodules started =========="
    Write-Log "output path : $outputpath"
    Write-Log "log         : $logfile"

    $null = New-Item -ItemType Directory -Path $outputpath -Force

    ##### windows server 2016 defaults to tls 1.0 — psgallery requires tls 1.2, force it for this session #####
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "tls 1.2 enforced for psgallery connectivity"

    ##### install nuget provider upfront so save-module doesn't trigger an interactive ShouldContinue prompt #####
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
        Write-Log "installing nuget package provider"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Write-Log "nuget provider ready"

    foreach ($mod in $modules) {
        Write-Log "downloading: $mod"

        ##### use save-module instead of install-module — writes the module to disk without touching the system module path #####
        Save-Module -Name $mod -Path $outputpath -Repository PSGallery -Force

        $savedpath = Join-Path $outputpath $mod
        if (Test-Path $savedpath) {
            Write-Log "saved: $mod -> $savedpath"
        } else {
            throw "save-module completed but $mod not found at expected path: $savedpath"
        }
    }

    Write-Log "========== all modules saved. run Build-Package.ps1 next. =========="
    Write-Host "`nDone. Modules saved to: $outputpath" -ForegroundColor Green
    Write-Host "Next step: .\Build-Package.ps1`n" -ForegroundColor Cyan
}
catch {
    Write-Log "fatal error: $_" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace)" 'error'
    exit 1
}
