#Requires -Module PSDscResources
<#
.SYNOPSIS
    dsc configuration for microsoft defender antivirus stig baseline.

.DESCRIPTION
    writes defender preference policy values directly to the policy hive under
    HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender. these are the same keys
    scc reads during a scap scan, so a passing registry state here will satisfy
    the stig scan.

    this config does not use any defender cmdlets at runtime -- all enforcement
    is declarative via the Registry resource. lcm applyandautocorrect will
    revert tampered values automatically on its 15-min pass.

    risk tiering (legacy sql + app fleet):
      tier 1 -- scan behavior, signatures, threat response (low)
      tier 2 -- maps / cloud telemetry (low on air-gapped)
      tier 3 -- pua protection (medium, default audit)
      tier 4 -- asr rules + network protection (high, default audit)

.PARAMETER nodename
    target node name. defaults to 'localhost' for push-mode local application.

.PARAMETER aggressivepua
    $true flips v-213426 (pua block) from AuditMode to Enabled.
    default $false -- pua stays in audit until dev has verified no admin
    tool is misclassified.

.PARAMETER asrmode
    'Audit'   (default) -- all eight tier 4 rules in audit-only mode. event
                           id 1121/1122 is logged when a rule would fire but
                           nothing is blocked. use this for dev bake-in.
    'Enforce'           -- all eight tier 4 rules in block mode. only flip
                           after dev has observed a clean audit log for the
                           app set that runs on the target.
#>

##### defenderavstig: the top-level dsc configuration block. accepts nodename and two risk knobs for staged rollout on legacy app hosts. bootstrap.ps1 dot-sources this file and calls this function to produce the mof. #####
Configuration defenderavstig {
    param (
        [string]$nodename = 'localhost',

        [bool]$aggressivepua = $false,

        [ValidateSet('Audit', 'Enforce')]
        [string]$asrmode = 'Audit'
    )

    Import-DscResource -ModuleName PSDscResources

    ##### asr / network-protection value encoding. 1 = block, 2 = audit. one knob controls all eight tier 4 rules so dev can bake audit telemetry before enforcing anything. #####
    $asrvalue = if ($asrmode -eq 'Enforce') { 1 } else { 2 }

    ##### pua: audit (2) by default, block (1) only when $aggressivepua is set. keeps legacy admin utilities unblocked until dev confirms. #####
    $puavalue = if ($aggressivepua) { 1 } else { 2 }

    ##### common policy roots used throughout this config #####
    $defbase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    $egbase  = "$defbase\Windows Defender Exploit Guard"
    $asrkey  = "$egbase\ASR\Rules"

    Node $nodename {

        # =============================================================
        # tier 1 -- scan behavior, signatures, threat response
        # =============================================================

        ##### v-213452 spyware definition age not to exceed 7 days #####
        Registry spywaredefage {
            Key       = "$defbase\Signature Updates"
            ValueName = 'ASSignatureDue'
            ValueType = 'dword'
            ValueData = '7'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213453 virus definition age not to exceed 7 days #####
        Registry virusdefage {
            Key       = "$defbase\Signature Updates"
            ValueName = 'AVSignatureDue'
            ValueType = 'dword'
            ValueData = '7'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213454 check for definition updates daily -- interval in hours. 8 = 3x daily, well under the stig threshold of once per day #####
        Registry defupdateinterval {
            Key       = "$defbase\Signature Updates"
            ValueName = 'SignatureUpdateInterval'
            ValueType = 'dword'
            ValueData = '8'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213450 weekly scheduled scan. ScheduleDay=0 is sunday. ScanParameters=2 is full scan. tune ScheduleTime for off-hours per fleet. #####
        Registry weeklyscanday {
            Key       = "$defbase\Scan"
            ValueName = 'ScheduleDay'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
        }
        Registry weeklyscantype {
            Key       = "$defbase\Scan"
            ValueName = 'ScanParameters'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213449 scan removable drives. 0 = do scan (not disabled) #####
        Registry scanremovable {
            Key       = "$defbase\Scan"
            ValueName = 'DisableRemovableDriveScanning'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213451 e-mail scanning (pst/ost). 0 = do scan (not disabled). rare on servers. #####
        Registry scanemail {
            Key       = "$defbase\Scan"
            ValueName = 'DisableEmailScanning'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213431 automatic exclusions (defender recognizes sql/iis/ad roles and self-excludes). 0 = enabled (not disabled). actively helpful for this fleet. #####
        Registry autoexclusions {
            Key       = "$defbase\Exclusions"
            ValueName = 'DisableAutoExclusions'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
        }

        ##### threat severity default action. subkey values map severity level to action code: 1=Low, 2=Medium, 4=High, 5=Severe. action code 2 = Quarantine (safe default across all tiers). flip to 3 (Remove) in a follow-up if your cyber shop requires. #####

        ##### v-213466 low #####
        Registry threatactionlow {
            Key       = "$defbase\Threats\ThreatSeverityDefaultAction"
            ValueName = '1'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213465 medium #####
        Registry threatactionmedium {
            Key       = "$defbase\Threats\ThreatSeverityDefaultAction"
            ValueName = '2'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213464 high #####
        Registry threatactionhigh {
            Key       = "$defbase\Threats\ThreatSeverityDefaultAction"
            ValueName = '4'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213455 severe #####
        Registry threatactionsevere {
            Key       = "$defbase\Threats\ThreatSeverityDefaultAction"
            ValueName = '5'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        # =============================================================
        # tier 2 -- maps / cloud telemetry
        # =============================================================

        ##### v-213434 join maps. 2 = advanced membership #####
        Registry mapsjoin {
            Key       = "$defbase\Spynet"
            ValueName = 'SpynetReporting'
            ValueType = 'dword'
            ValueData = '2'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213435 only send safe samples. 1 = safe samples only #####
        Registry mapssafesamples {
            Key       = "$defbase\Spynet"
            ValueName = 'SubmitSamplesConsent'
            ValueType = 'dword'
            ValueData = '1'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213433 real-time maps check (block-at-first-seen). 0 = enabled (not disabled). air-gapped targets will fail the cloud call silently; this still satisfies the registry check that scc reads. #####
        Registry mapsrealtime {
            Key       = "$defbase\Real-Time Protection"
            ValueName = 'DisableBlockAtFirstSeen'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
        }

        # =============================================================
        # tier 3 -- pua protection (default: audit)
        # =============================================================

        ##### v-213426 block potentially unwanted applications. defaults to audit (2) -- legacy admin tools can trip false positives. flip with -AggressivePua $true after dev review. #####
        Registry puaprotection {
            Key       = $defbase
            ValueName = 'PUAProtection'
            ValueType = 'dword'
            ValueData = "$puavalue"
            Ensure    = 'present'
            Force     = $true
        }

        # =============================================================
        # tier 4 -- attack surface reduction + network protection
        #          default: audit (2). flip with -AsrMode 'Enforce'.
        # =============================================================

        ##### enable asr parent switch #####
        Registry asrparent {
            Key       = "$egbase\ASR"
            ValueName = 'ExploitGuard_ASR_Rules'
            ValueType = 'dword'
            ValueData = '1'
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213456 block executable content from email client and webmail #####
        Registry asr_emailexe {
            Key       = $asrkey
            ValueName = 'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213457 block office apps from creating child processes -- HIGH breakage risk on legacy automation / access macros / ssis->office. keep in audit until dev clean. #####
        Registry asr_officechild {
            Key       = $asrkey
            ValueName = 'D4F940AB-401B-4EFC-AADC-AD5F3C50688A'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213458 block office apps from creating executable content #####
        Registry asr_officeexe {
            Key       = $asrkey
            ValueName = '3B576869-A4EC-4529-8536-B80A7769E899'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213459 block office apps from injecting into other processes #####
        Registry asr_officeinject {
            Key       = $asrkey
            ValueName = '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213460 impede js/vbs from launching executables -- MEDIUM-HIGH breakage risk on legacy wsh admin scripts / old login scripts. #####
        Registry asr_jsvbsexe {
            Key       = $asrkey
            ValueName = 'D3E037E1-3EB8-44C8-A917-57927947596D'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213461 block execution of potentially obfuscated scripts #####
        Registry asr_obfuscated {
            Key       = $asrkey
            ValueName = '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213462 block win32 imports from macro code in office -- HIGH breakage risk for legacy reporting/accounting macros that touch registry/filesystem/shell. #####
        Registry asr_win32macro {
            Key       = $asrkey
            ValueName = '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B'
            ValueType = 'string'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }

        ##### v-213463 network protection -- block user/apps from accessing dangerous urls. separate feature from asr but shares the -AsrMode knob for risk-grouped rollout. #####
        Registry netprotect {
            Key       = "$egbase\Network Protection"
            ValueName = 'EnableNetworkProtection'
            ValueType = 'dword'
            ValueData = "$asrvalue"
            Ensure    = 'present'
            Force     = $true
        }
    }
}
