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
            SkipRule    = @(
                'V-254439',  # deny log on through remote desktop services - blocks local accounts, not applicable to gapped/avd environment
                'V-254435',  # deny access to this computer from the network - default includes local account, blocks rdp on standalone vms
                'V-254281',  # windows time service - no external ntp reachable in gapped environment
                'V-254459',  # smart card removal lock - smart cards not used in avd, local logon only
                'V-254458'   # logon banner caption - dod-only values not applicable, replaced with dos caption via registry resource below
            )
            # note: ws2022 stig has no dedicated fips algorithm policy rule (unlike ws2016 V-225059 and ws2019 V-205842).
            # V-254276 previously appeared in this list mislabeled as fips -- it is actually the smbv1 disable rule and has been removed.
            # override banner body text with dos-approved legal notice (v-254457)
            # v-254458 (caption) is skipped above and set directly via registry resource below
            OrgSettings = @{
                'V-254457' = @{
                    ValueData = 'You are accessing a U.S. Government information system, which includes (1) this computer, (2) this computer network, (3) all computers connected to this network, and (4) all devices and storage media attached to this network or to a computer on this network. This information system is provided for U.S. Government-authorized use only. Unauthorized or improper use of this system may result in disciplinary action, as well as civil and criminal penalties. By using this information system, you understand and consent to the following: You have no reasonable expectation of privacy regarding any communications or data transiting or stored on this information system. At any time, and for any lawful government purpose, the government may monitor, intercept, and search and seize any communication or data transiting or stored on this information system. Any communications or data transiting or stored on this information system may be disclosed or used for any lawful government purpose. Nothing herein consents to the search or seizure of a privately-owned computer or other privately owned communications device, or the contents thereof, that is in the system user home. Opening e-mails from unknown/unconfirmed websites may open the Department''s systems to malware.'
                }
            }
        }

        ##### dos logon banner caption - replaces dod-locked caption from v-254458 with dos-approved text #####
        Registry doscaptionbanner {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            ValueName = 'LegalNoticeCaption'
            ValueType = 'String'
            ValueData = 'LEGAL NOTICE - WARNING: For Official Use Only'
            Ensure    = 'Present'
            Force     = $true
        }

        ##### disable fips algorithm policy — ws2022 stig has no fips rule; this is pure drift protection to prevent gpo/os defaults from re-enabling fips #####
        Registry disablefips {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy'
            ValueName = 'Enabled'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
            Force     = $true
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
            Force     = $true
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
