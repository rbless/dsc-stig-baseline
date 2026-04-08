#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for windows server 2016 stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for windows server 2016.
    additional registry hardening is layered on top for items outside the stig scope.

.PARAMETER nodename
    target node name. defaults to 'localhost' for push-mode local application.

.PARAMETER osrole
    ms = member server (default)
    dc = domain controller

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -OsVersion 2016
    update stigversion below to match the latest available.
#>

Configuration windowsserver2016stig {
    param (
        [string]$nodename = 'localhost',

        [ValidateSet('ms', 'dc')]
        [string]$osrole = 'ms'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig — windows server 2016
        # run Get-StigList to confirm the latest stigversion available.
        # ---------------------------------------------------------------
        WindowsServer baselinestig {
            OsVersion   = '2016'
            OsRole      = $osrole
            StigVersion = '2.6'
        }

        # ---------------------------------------------------------------
        # additional hardening not covered by powerstig
        # ---------------------------------------------------------------

        # disable smbv1 — mitigates eternalblue (ms17-010) exploitation
        Registry disablesmbv1_server {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
            ValueName = 'SMB1'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        # disable autorun on all drive types — prevents malicious media execution
        Registry disableautorun {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            ValueName = 'NoDriveTypeAutoRun'
            ValueType = 'dword'
            ValueData = '255'
            Ensure    = 'present'
        }

        # disable netbios over tcp/ip via registry — reduces legacy lateral movement surface
        Registry disablenetbioshelper {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\lmhosts'
            ValueName = 'Start'
            ValueType = 'dword'
            ValueData = '4'
            Ensure    = 'present'
        }

        # disable wdigest — prevents cleartext credential caching in lsass memory
        Registry disablewdigest {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
            ValueName = 'UseLogonCredential'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        # enable lsa protection (runasppl) — prevents non-ppl processes from reading lsass
        Registry enablelsaprotection {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            ValueName = 'RunAsPPL'
            ValueType = 'dword'
            ValueData = '1'
            Ensure    = 'present'
        }

        # disable llmnr — prevents name poisoning attacks on local network
        Registry disablellmnr {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
            ValueName = 'EnableMulticast'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }
    }
}
