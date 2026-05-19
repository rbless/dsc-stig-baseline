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

##### windowsserver2016stig: the top-level dsc configuration block. accepts nodename and osrole, imports required dsc resource modules, then declares all resource nodes. bootstrap.ps1 dot-sources this file and calls this function to produce the mof #####
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

        ##### applies the full disa stig for windows server 2016 via the powerstig WindowsServer resource — osrole switches between member server and domain controller rule sets #####
        WindowsServer baselinestig {
            OsVersion   = '2016'
            OsRole      = $osrole
            StigVersion = '2.10'
            SkipRule    = @(
                'V-225019',  # deny log on through remote desktop services - blocks local accounts, not applicable to gapped/avd environment
                'V-224862',  # windows time service - no external ntp reachable in gapped environment
                'V-225038',  # smart card removal lock - smart cards not used in avd, local logon only
                'V-225059',  # fips algorithm policy - not required in this environment
                'V-225037'   # logon banner caption - dod-only values not applicable, replaced with dos caption via registry resource below
            )
            # override banner body text with dos-approved legal notice (v-225036)
            # v-225037 (caption) is skipped above and set directly via registry resource below
            OrgSettings = @{
                'V-225036' = @{
                    ValueData = 'You are accessing a U.S. Government information system, which includes (1) this computer, (2) this computer network, (3) all computers connected to this network, and (4) all devices and storage media attached to this network or to a computer on this network. This information system is provided for U.S. Government-authorized use only. Unauthorized or improper use of this system may result in disciplinary action, as well as civil and criminal penalties. By using this information system, you understand and consent to the following: You have no reasonable expectation of privacy regarding any communications or data transiting or stored on this information system. At any time, and for any lawful government purpose, the government may monitor, intercept, and search and seize any communication or data transiting or stored on this information system. Any communications or data transiting or stored on this information system may be disclosed or used for any lawful government purpose. Nothing herein consents to the search or seizure of a privately-owned computer or other privately owned communications device, or the contents thereof, that is in the system user home. Opening e-mails from unknown/unconfirmed websites may open the Department''s systems to malware.'
                }
            }
        }

        ##### dos logon banner caption - replaces dod-locked caption from v-225037 with dos-approved text #####
        Registry doscaptionbanner {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            ValueName = 'LegalNoticeCaption'
            ValueType = 'String'
            ValueData = 'LEGAL NOTICE - WARNING: For Official Use Only'
            Ensure    = 'Present'
            Force     = $true
        }

        # ---------------------------------------------------------------
        # additional hardening not covered by powerstig
        # ---------------------------------------------------------------

        ##### disable smbv1 — mitigates eternalblue (ms17-010) exploitation via lanmanserver registry key #####
        Registry disablesmbv1_server {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
            ValueName = 'SMB1'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        ##### disable autorun on all drive types — prevents malicious media from auto-executing on insert #####
        Registry disableautorun {
            Key       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            ValueName = 'NoDriveTypeAutoRun'
            ValueType = 'dword'
            ValueData = '255'
            Ensure    = 'present'
        }

        ##### disable netbios over tcp/ip by stopping the lmhosts service — reduces legacy name resolution lateral movement surface #####
        Registry disablenetbioshelper {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\lmhosts'
            ValueName = 'Start'
            ValueType = 'dword'
            ValueData = '4'
            Ensure    = 'present'
        }

        ##### disable wdigest authentication — prevents windows from caching cleartext credentials in lsass memory #####
        Registry disablewdigest {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
            ValueName = 'UseLogonCredential'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        ##### enable lsa protection (runasppl) — marks lsass as a protected process so non-ppl processes cannot inject into or read it #####
        Registry enablelsaprotection {
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            ValueName = 'RunAsPPL'
            ValueType = 'dword'
            ValueData = '1'
            Ensure    = 'present'
        }

        ##### disable llmnr multicast name resolution — prevents responder-style name poisoning attacks on the local network segment #####
        Registry disablellmnr {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
            ValueName = 'EnableMulticast'
            ValueType = 'dword'
            ValueData = '0'
            Ensure    = 'present'
        }

        # ---------------------------------------------------------------
        # IE (internet explorer 11) mode (within ms edge) — pending enterprise site list to build xml
        # IE mode just forces IE11 rendering onto a page loaded with Edge using IE engine (Trident?)
        # TO DO: uncomment once site list url(s) are available
        # ---------------------------------------------------------------

        # ##### enable IE mode in edge — sets integration level to ie mode (1) #####
        
        # Registry iemode_integrationlevel {
        #     Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        #     ValueName = 'InternetExplorerIntegrationLevel'
        #     ValueType = 'dword'
        #     ValueData = '1'
        #     Ensure    = 'present'
        # }

        # ##### IE mode site list — path or url to enterprise mode site list xml #####

        
       
        # Registry iemode_sitelist {
        #     Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        #     ValueName = 'InternetExplorerIntegrationSiteList'
        #     ValueType = 'string'
        #     ValueData = ''  # set to \\server\share\sitelist.xml or https:// url
        #     Ensure    = 'present'
        # }
    }
}
