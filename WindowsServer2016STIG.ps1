#Requires -Module PowerSTIG
<#
.SYNOPSIS
    DSC configuration for Windows Server 2016 STIG baseline.

.DESCRIPTION
    Uses PowerSTIG to apply the DISA STIG for Windows Server 2016.
    Additional registry hardening is layered on top for items outside the STIG scope.

.PARAMETER NodeName
    Target node name. Defaults to 'localhost' for push-mode local application.

.PARAMETER OsRole
    MS = Member Server (default)
    DC = Domain Controller

.NOTES
    To check available STIG versions bundled with your PowerSTIG version, run:
        Get-StigList -OsVersion 2016
    Update StigVersion below to match the latest available.
#>

Configuration WindowsServer2016STIG {
    param (
        [string]$NodeName = 'localhost',

        [ValidateSet('MS', 'DC')]
        [string]$OsRole = 'MS'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $NodeName {

        # ---------------------------------------------------------------
        # DISA STIG — Windows Server 2016
        # Run Get-StigList to confirm the latest StigVersion available.
        # ---------------------------------------------------------------
        WindowsServer BaselineSTIG {
            OsVersion   = '2016'
            OsRole      = $OsRole
            StigVersion = '2.6'
        }

        # ---------------------------------------------------------------
        # Additional hardening not covered by PowerSTIG
        # ---------------------------------------------------------------

        # Disable SMBv1 (EternalBlue mitigation)
        Registry 'DisableSMBv1_Server' {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
            ValueName = 'SMB1'
            ValueType = 'DWord'
            ValueData = '0'
            Ensure    = 'Present'
        }

        # Disable AutoRun on all drive types
        Registry 'DisableAutoRun' {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            ValueName = 'NoDriveTypeAutoRun'
            ValueType = 'DWord'
            ValueData = '255'
            Ensure    = 'Present'
        }

        # Disable NetBIOS over TCP/IP via registry (belt-and-suspenders)
        Registry 'DisableNetBIOSHelper' {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\lmhosts'
            ValueName = 'Start'
            ValueType = 'DWord'
            ValueData = '4'
            Ensure    = 'Present'
        }

        # Disable WDigest (prevents cleartext credential caching in LSASS)
        Registry 'DisableWDigest' {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
            ValueName = 'UseLogonCredential'
            ValueType = 'DWord'
            ValueData = '0'
            Ensure    = 'Present'
        }

        # Enable LSA Protection (RunAsPPL)
        Registry 'EnableLSAProtection' {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            ValueName = 'RunAsPPL'
            ValueType = 'DWord'
            ValueData = '1'
            Ensure    = 'Present'
        }

        # Disable LLMNR
        Registry 'DisableLLMNR' {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
            ValueName = 'EnableMulticast'
            ValueType = 'DWord'
            ValueData = '0'
            Ensure    = 'Present'
        }
    }
}
