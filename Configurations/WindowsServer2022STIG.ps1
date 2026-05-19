#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for windows server 2022 stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for windows server 2022.
    additional registry hardening is layered on top for items outside the stig scope.

.PARAMETER nodename
    target node name. defaults to 'localhost' for push-mode local application.

.PARAMETER osrole
    ms = member server (default)
    dc = domain controller

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -OsVersion 2022
    update stigversion below to match the latest available.
#>

Configuration windowsserver2022stig {
    param (
        [string]$nodename = 'localhost',

        [ValidateSet('ms', 'dc')]
        [string]$osrole = 'ms'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig — windows server 2022
        # run Get-StigList to confirm the latest stigversion available.
        # ---------------------------------------------------------------

        ##### applies the full disa stig for windows server 2022 via the powerstig WindowsServer resource #####
        WindowsServer baselinestig {
            OsVersion   = '2022'
            OsRole      = $osrole
            StigVersion = '2.7'
        }

        # ---------------------------------------------------------------
        # additional hardening not covered by powerstig
        # ---------------------------------------------------------------

        ##### disable smbv1 — mitigates eternalblue (ms17-010) exploitation #####
        Registry disablesmbv1_server {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
            ValueName = 'SMB1'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        ##### disable autorun on all drive types #####
        Registry disableautorun {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            ValueName = 'NoDriveTypeAutoRun'
            ValueType = 'dword'
            ValueData = '255'
            Ensure    = 'present'
        }

        ##### disable netbios over tcp/ip #####
        Registry disablenetbioshelper {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\lmhosts'
            ValueName = 'Start'
            ValueType = 'dword'
            ValueData = '4'
            Ensure    = 'present'
        }

        ##### disable wdigest — prevents cleartext credential caching in lsass #####
        Registry disablewdigest {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
            ValueName = 'UseLogonCredential'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        ##### enable lsa protection — marks lsass as a protected process #####
        Registry enablelsaprotection {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            ValueName = 'RunAsPPL'
            ValueType = 'dword'
            ValueData = '1'
            Ensure    = 'present'
        }

        ##### disable llmnr — prevents responder-style name poisoning #####
        Registry disablellmnr {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
            ValueName = 'EnableMulticast'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        # ---------------------------------------------------------------
        # ie mode (edge) — pending enterprise site list xml from other team
        # TODO: uncomment once site list url(s) are available
        # ---------------------------------------------------------------

        # ##### enable ie mode in edge — sets integration level to ie mode (1) #####
        # Registry iemode_integrationlevel {
        #     Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        #     ValueName = 'InternetExplorerIntegrationLevel'
        #     ValueType = 'dword'
        #     ValueData = '1'
        #     Ensure    = 'present'
        # }

        # ##### ie mode site list — path or url to enterprise mode site list xml #####
        # Registry iemode_sitelist {
        #     Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        #     ValueName = 'InternetExplorerIntegrationSiteList'
        #     ValueType = 'string'
        #     ValueData = ''  # set to \\server\share\sitelist.xml or https:// url
        #     Ensure    = 'present'
        # }
    }
}
