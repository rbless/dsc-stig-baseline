#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for adobe acrobat pro and reader stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for adobe acrobat pro and acrobat reader dc.
    detection of which product is installed is handled at runtime — both are applied
    if both are present on the target node.

.PARAMETER nodename
    target node name. defaults to 'localhost'.

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -Technology Adobe
    update stigversions below to match the latest available.
#>

Configuration adobeacrobatstig {
    param (
        [string]$nodename = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig — adobe acrobat pro dc
        # applied only if acrobat pro is installed on this node
        # ---------------------------------------------------------------

        ##### check for acrobat pro installation before applying — both 32-bit and 64-bit registry paths checked #####
        $acroproinstalled = (Test-Path 'HKLM:\SOFTWARE\Adobe\Adobe Acrobat') -or
                            (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Adobe\Adobe Acrobat')

        if ($acroproinstalled) {
            Adobe baselineacrobatprostig {
                AdobeApp    = 'AcrobatPro'
                StigVersion = '2.1'
            }
        }

        # ---------------------------------------------------------------
        # disa stig — adobe acrobat reader dc
        # applied only if acrobat reader is installed on this node
        # ---------------------------------------------------------------

        ##### check for acrobat reader installation before applying #####
        $acroreaderinstalled = (Test-Path 'HKLM:\SOFTWARE\Adobe\Acrobat Reader') -or
                               (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Adobe\Acrobat Reader')

        if ($acroreaderinstalled) {
            Adobe baselineacrobatreaderstig {
                AdobeApp    = 'AcrobatReader'
                StigVersion = '2.1'
            }
        }
    }
}
