#Requires -RunAsAdministrator
<#
.SYNOPSIS
    bootstraps the dsc environment on a freshly provisioned vm.

.DESCRIPTION
    performs four steps in sequence:
      1. installs vendored powershell modules from C:\DSC\Modules (no internet required)
      2. configures the local configuration manager (lcm)
      3. detects installed products (os version, sql server, oracle) and compiles
         one mof per detected target into C:\DSC\MOF\<target>\
      4. archives any previous install before overwriting

    run this script first after the zip is extracted.
    then run Apply.ps1 to enforce the configuration.

    add new stig targets by dropping a config script into Configurations\
    and adding an entry to the $configmap table in this script.

.PARAMETER dscroot
    root path where the dsc zip was extracted. default: C:\DSC

.EXAMPLE
    .\Bootstrap.ps1

.NOTES
    some domain-specific STIGs (e.g. user rights assignments that check domain SIDs) cannot apply
    to a machine that is not domain-joined. it is normal for these to fail or error during testing
    on a standalone VM — they are not bugs, just controls that require a domain context to evaluate.
#>

[CmdletBinding()]
param (
    [string]$dscroot = 'C:\DSC'
)

Set-StrictMode -Version Latest
$erroractionpreference = 'Stop'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
$logdir  = Join-Path $dscroot 'Logs'
$null    = New-Item -ItemType Directory -Path $logdir -Force
$logfile = Join-Path $logdir "Bootstrap_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
# target detection
# ---------------------------------------------------------------------------
##### get-stigtargets: inspects the local machine and returns a list of target keys
##### representing what stig configs should be compiled. checks os version, sql server
##### registry keys, and oracle registry keys. only returns targets that have a known
##### mapping in the configmap -- unknown products are logged as warnings and skipped #####
function Get-StigTargets {
    $detected = [System.Collections.Generic.List[string]]::new()

    # os version -- always present. use win32_operatingsystem caption to determine which
    # windows server stig applies. domainrole 4/5 = domain controller, 2/3 = member server
    $osinfo   = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    $sysinfo  = Get-WmiObject -Class Win32_ComputerSystem  -ErrorAction SilentlyContinue
    $osrole   = if ($sysinfo.DomainRole -ge 4) { 'dc' } else { 'ms' }

    ##### match caption against known windows server release strings -- update the list as new stig benchmarks become available #####
    switch -Wildcard ($osinfo.Caption) {
        '*2012*' { $detected.Add("WS2012R2:$osrole") }
        '*2016*' { $detected.Add("WS2016:$osrole")   }
        '*2019*' { $detected.Add("WS2019:$osrole")   }
        '*2022*' { $detected.Add("WS2022:$osrole")   }
        default  { Write-Log "unrecognized os: $($osinfo.Caption) -- no os stig will be applied" 'warn' }
    }

    # sql server -- check for installed instances via the sql instance names registry key.
    # then enumerate version-numbered subkeys under the sql root to identify installed versions.
    # internal version numbers: 110=2012, 120=2014, 130=2016, 140=2017, 150=2019
    $sqlinstanceskey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path $sqlinstanceskey) {
        $sqlrootkey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
        ##### iterate numeric subkeys (e.g. 120, 130) under the sql root -- each represents an installed version family #####
        Get-ChildItem $sqlrootkey -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{2,3}$' } |
            ForEach-Object {
                switch ($_.PSChildName) {
                    '110' { $detected.Add('SQL2012') }
                    '120' { $detected.Add('SQL2014') }
                    '130' { $detected.Add('SQL2016') }
                    '140' { $detected.Add('SQL2017') }
                    '150' { $detected.Add('SQL2019') }
                }
            }
    }

    # oracle -- check HKLM:\SOFTWARE\ORACLE for KEY_ prefixed subkeys representing oracle homes.
    # each home has an ORACLE_HOME_VERSION property -- match major version to stig target name
    $oraclekey = 'HKLM:\SOFTWARE\ORACLE'
    if (Test-Path $oraclekey) {
        ##### iterate KEY_ subkeys -- each one is an oracle home. extract major version from ORACLE_HOME_VERSION property #####
        Get-ChildItem $oraclekey -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^KEY_' } |
            ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $ver   = if ($props -and $props.PSObject.Properties['ORACLE_HOME_VERSION']) { $props.ORACLE_HOME_VERSION } else { $null }
                ##### add oracle target only once per major version even if multiple homes exist #####
                if ($ver -match '^12' -and 'Oracle12c' -notin $detected) { $detected.Add('Oracle12c') }
                if ($ver -match '^19' -and 'Oracle19c' -notin $detected) { $detected.Add('Oracle19c') }
            }
    }

    # iis -- check for the W3SVC service which is present whenever the web server role is installed
    $iissvc = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
    if ($iissvc) {
        ##### iis version is tied to the os -- derive from os caption rather than a separate iis version check #####
        switch -Wildcard ($osinfo.Caption) {
            '*2012*' { $detected.Add('IIS8.5') }
            '*2016*' { $detected.Add('IIS10.0') }
            '*2019*' { $detected.Add('IIS10.0') }
            '*2022*' { $detected.Add('IIS10.0') }
        }
    }

    # apache -- check for apache service or registry entry. apache on windows typically
    # registers a service named Apache* and may have a registry key under apache software foundation
    $apachesvc = Get-Service -Name 'Apache*' -ErrorAction SilentlyContinue | Select-Object -First 1
    $apachekey = 'HKLM:\SOFTWARE\Apache Software Foundation'
    if ($apachesvc -or (Test-Path $apachekey)) {
        ##### apache httpd 2.4 is the current stig-covered version -- add detection for other versions if needed #####
        $detected.Add('Apache2.4')
    }

    # adobe acrobat / reader -- check both 32-bit and 64-bit registry hives.
    # acrobat pro registers under Adobe Acrobat, reader under Acrobat Reader
    $adobepaths = @(
        'HKLM:\SOFTWARE\Adobe\Acrobat Reader'
        'HKLM:\SOFTWARE\Adobe\Adobe Acrobat'
        'HKLM:\SOFTWARE\WOW6432Node\Adobe\Acrobat Reader'
        'HKLM:\SOFTWARE\WOW6432Node\Adobe\Adobe Acrobat'
    )
    ##### check each adobe registry path -- add target once on first match regardless of how many adobe products are found #####
    $adobefound = $adobepaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($adobefound) {
        $detected.Add('AdobeAcrobat')
    }

    return $detected
}

# ---------------------------------------------------------------------------
# config map -- add new stig targets here
# ---------------------------------------------------------------------------
##### configmap: maps each target key returned by get-stigtargets to the config script and
##### dsc configuration function name. os targets include a :role suffix (e.g. WS2016:ms)
##### which is stripped when looking up the entry -- the osrole is passed as a parameter instead #####
$configmap = [ordered]@{
    'WS2016'    = @{ Script = 'Configurations\WindowsServer2016STIG.ps1';   Function = 'windowsserver2016stig'   }
    'WS2019'    = @{ Script = 'Configurations\WindowsServer2019STIG.ps1';   Function = 'windowsserver2019stig'   }
    'WS2022'    = @{ Script = 'Configurations\WindowsServer2022STIG.ps1';   Function = 'windowsserver2022stig'   }
    'SQL2012'   = @{ Script = 'Configurations\SqlServer2012STIG.ps1';       Function = 'sqlserver2012stig'       }
    'SQL2014'   = @{ Script = 'Configurations\SqlServer2014STIG.ps1';       Function = 'sqlserver2014stig'       }
    'SQL2016'   = @{ Script = 'Configurations\SqlServer2016STIG.ps1';       Function = 'sqlserver2016stig'       }
    'SQL2017'   = @{ Script = 'Configurations\SqlServer2017STIG.ps1';       Function = 'sqlserver2017stig'       }
    'SQL2019'   = @{ Script = 'Configurations\SqlServer2019STIG.ps1';       Function = 'sqlserver2019stig'       }
    'Oracle12c'    = @{ Script = 'Configurations\Oracle12cSTIG.ps1';          Function = 'oracle12cstig'          }
    'Oracle19c'    = @{ Script = 'Configurations\Oracle19cSTIG.ps1';          Function = 'oracle19cstig'          }
    'IIS8.5'       = @{ Script = 'Configurations\IIS85STIG.ps1';              Function = 'iis85stig'              }
    'IIS10.0'      = @{ Script = 'Configurations\IIS10STIG.ps1';              Function = 'iis10stig'              }
    'Apache2.4'    = @{ Script = 'Configurations\Apache24STIG.ps1';           Function = 'apache24stig'           }
    'AdobeAcrobat' = @{ Script = 'Configurations\AdobeAcrobatSTIG.ps1';       Function = 'adobeacrobatstig'       }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
try {
    Write-Log "========== bootstrap started on $env:COMPUTERNAME =========="
    Write-Log "dscroot : $dscroot"
    Write-Log "log     : $logfile"

    # -----------------------------------------------------------------------
    # step 0: archive previous install if one exists
    # -----------------------------------------------------------------------
    Write-Log "--- step 0: checking for previous install ---"

    ##### check for a version file left by a prior run -- if found, archive scripts and configs before overwriting so rollback is possible #####
    $previousversionfile = Join-Path $dscroot 'VERSION'
    if (Test-Path $previousversionfile) {
        try {
            ##### read the previous version number from the json version file to use as a human-readable archive folder name #####
            $prevversion = (Get-Content $previousversionfile -Raw | ConvertFrom-Json).PackageVersion
            $archivename = "v${prevversion}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $archivedest = Join-Path $dscroot "History\$archivename"

            $null = New-Item -ItemType Directory -Path $archivedest -Force

            ##### iterate each item in the archive list -- skips modules (too large) and runtime folders, copies scripts and configs only #####
            $toarchive = @('Bootstrap.ps1','Apply.ps1','DriftTest.ps1','VERSION','Configurations')
            foreach ($item in $toarchive) {
                $itempath = Join-Path $dscroot $item
                ##### check each item path exists before attempting copy -- missing items are silently skipped rather than erroring #####
                if (Test-Path $itempath) {
                    Copy-Item -Path $itempath -Destination $archivedest -Recurse -Force
                }
            }

            Write-Log "previous v$prevversion archived to History\$archivename"
        }
        catch {
            ##### archiving failure is non-fatal -- log the warning and continue with install rather than blocking the whole bootstrap #####
            Write-Log "could not archive previous install (non-fatal) : $_" 'warn'
        }
    }
    else {
        Write-Log "no previous install detected - fresh deployment"
    }

    # -----------------------------------------------------------------------
    # step 1: install vendored modules
    # -----------------------------------------------------------------------
    Write-Log "--- step 1: installing vendored modules ---"

    $modulesource = Join-Path $dscroot 'Modules'
    $moduledest   = "$env:ProgramFiles\WindowsPowerShell\Modules"

    ##### check the vendored modules folder exists inside the extracted package -- if missing the zip was incomplete, abort #####
    if (-not (Test-Path $modulesource)) {
        throw "module source path not found: $modulesource"
    }

    ##### iterate each module subdirectory under modulesource -- removes any stale existing version first, then copies the vendored version into the system module path #####
    Get-ChildItem -Path $modulesource -Directory | ForEach-Object {
        $destpath = Join-Path $moduledest $_.Name
        ##### check if this module already exists in the system path -- remove it first to avoid stale file conflicts before copying the new version #####
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

    ##### define the lcm meta-configuration inline -- push mode means configs are applied manually rather than pulled from a server.
    ##### applyandautocorrect enforces desired state every 15 minutes rather than just monitoring for drift #####
    [DSCLocalConfigurationManager()]
    Configuration lcmsettings {
        Node localhost {
            Settings {
                RefreshMode                    = 'push'
                ConfigurationMode              = 'applyandautocorrect'
                RebootNodeIfNeeded             = $true
                ActionAfterReboot              = 'continueconfiguration'
                ConfigurationModeFrequencyMins = 15
                AllowModuleOverwrite           = $true
            }
        }
    }

    $lcmpath = Join-Path $dscroot 'LCM'
    $null    = New-Item -ItemType Directory -Path $lcmpath -Force

    ##### compile the lcm meta-configuration to a meta-mof file, then apply it to the local lcm via Set-DscLocalConfigurationManager #####
    lcmsettings -OutputPath $lcmpath | Out-Null
    Set-DscLocalConfigurationManager -Path $lcmpath -Force -Verbose
    Write-Log "lcm configured (mode: applyandmonitor, push)"

    # -----------------------------------------------------------------------
    # step 3: detect installed products and compile mofs
    # -----------------------------------------------------------------------
    Write-Log "--- step 3: detecting installed products ---"

    $mofpath = Join-Path $dscroot 'MOF'
    $null    = New-Item -ItemType Directory -Path $mofpath -Force

    $targets = Get-StigTargets
    Write-Log "detected targets: $($targets -join ', ')"

    $compiled = 0

    ##### iterate each detected target -- strip the :role suffix for map lookup, pass role as parameter for os configs #####
    foreach ($target in $targets) {
        $targetkey = $target -replace ':.*$', ''
        $osrole    = if ($target -match ':(.+)$') { $matches[1] } else { $null }

        if (-not $configmap.Contains($targetkey)) {
            Write-Log "no config mapped for detected target: $targetkey -- skipping" 'warn'
            continue
        }

        $cfg        = $configmap[$targetkey]
        $scriptpath = Join-Path $dscroot $cfg.Script

        ##### skip targets where the config script doesn't exist -- this is expected when a product is installed but no stig config has been authored yet #####
        if (-not (Test-Path $scriptpath)) {
            Write-Log "config script not found for $targetkey -- skipping: $scriptpath" 'warn'
            continue
        }

        Write-Log "compiling mof for: $targetkey"

        ##### dot-source the configuration script to load its Configuration block into scope, then call it to produce the mof #####
        . $scriptpath

        $mofsubpath = Join-Path $mofpath $targetkey
        $null = New-Item -ItemType Directory -Path $mofsubpath -Force

        ##### os configs accept -osrole to switch between member server and dc rule sets.
        ##### sql configs accept -serverinstance (defaults to MSSQLSERVER for default instance).
        ##### non-os/non-sql configs (oracle, iis, adobe) take only nodename and outputpath. #####
        if ($targetkey -match '^WS' -and $osrole) {
            & $cfg.Function -NodeName 'localhost' -OsRole $osrole -OutputPath $mofsubpath
        } elseif ($targetkey -match '^SQL') {
            & $cfg.Function -NodeName 'localhost' -ServerInstance 'localhost' -OutputPath $mofsubpath
        } else {
            & $cfg.Function -NodeName 'localhost' -OutputPath $mofsubpath
        }

        $moffile = Get-ChildItem -Path $mofsubpath -Filter '*.mof' | Select-Object -First 1
        if (-not $moffile) {
            throw "mof compilation produced no output for $targetkey in $mofsubpath"
        }

        Write-Log "mof compiled: $($moffile.FullName)"
        $compiled++
    }

    ##### abort if nothing compiled -- means detection found products but no matching config scripts exist yet #####
    if ($compiled -eq 0) {
        throw "no mofs compiled -- no matching config scripts found for detected targets: $($targets -join ', ')"
    }

    Write-Log "========== bootstrap complete. $compiled mof(s) compiled. =========="

    # -----------------------------------------------------------------------
    # step 4: pre-create C:\Audits for powerstig sql audit object
    # -----------------------------------------------------------------------
    ##### powerstig's SqlServer resource drops and recreates the STIG_AUDIT server audit object
    ##### pointing to C:\Audits\. create the directory now so the first apply does not fail #####
    $auditsdir = 'C:\Audits'
    if (-not (Test-Path $auditsdir)) {
        $null = New-Item -ItemType Directory -Path $auditsdir -Force
        Write-Log "created sql audit directory: $auditsdir"
    }

    # -----------------------------------------------------------------------
    # step 5: register startup scheduled task for reboot persistence
    # -----------------------------------------------------------------------
    ##### in push mode the lcm enforces config every 15 minutes once it has a pending configuration,
    ##### but after a hard reboot the lcm may not have a config in memory yet.
    ##### a startup scheduled task ensures Apply.ps1 runs as SYSTEM on every boot so
    ##### stigs are re-enforced even if the lcm cache was cleared or the vm was rebuilt. #####
    Write-Log "--- step 5: registering startup scheduled task ---"
    $applyscript  = Join-Path $dscroot 'Apply.ps1'
    $taskaction   = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$applyscript`""
    $tasktrigger  = New-ScheduledTaskTrigger -AtStartup
    $taskprincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName 'DSC-ApplyOnBoot' `
        -Action $taskaction -Trigger $tasktrigger -Principal $taskprincipal -Force | Out-Null
    Write-Log "scheduled task 'DSC-ApplyOnBoot' registered (runs Apply.ps1 as SYSTEM at startup)"

    # -----------------------------------------------------------------------
    # step 6: apply configuration
    # -----------------------------------------------------------------------
    Write-Log "--- step 6: invoking Apply.ps1 ---"
    if (Test-Path $applyscript) {
        & $applyscript -dscroot $dscroot
    } else {
        Write-Log "Apply.ps1 not found at $applyscript -- run it manually to enforce configuration" 'warn'
    }
}
catch {
    Write-Log "fatal error: $($_ -replace '[\r\n]+',' ')" 'error'
    Write-Log "stack trace: $($_.ScriptStackTrace -replace '[\r\n]+',' | ')" 'error'
    exit 1
}


