#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for iis 10.0 server and site stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for iis 10.0.
    covers both server-level (IISServer) and site-level (IISSite) stig controls.
    requires iis 10.0 (w3svc) to be installed on the target node.

.PARAMETER nodename
    target node name. defaults to 'localhost'.

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -Technology IISServer
        Get-StigList -Technology IISSite
    update stigversions below to match the latest available.
#>

Configuration iis10stig {
    param (
        [string]$nodename = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig — iis 10.0 server
        # ---------------------------------------------------------------

        ##### applies server-level iis 10.0 stig controls — covers service configuration, logging, and authentication settings #####
        IISServer baselineserverstig {
            IisVersion  = '10.0'
            StigVersion = '3.6'
        }

        # ---------------------------------------------------------------
        # disa stig — iis 10.0 site
        # ---------------------------------------------------------------

        ##### applies site-level iis 10.0 stig controls — covers ssl, authentication, and request filtering per-site #####
        IISSite baselinesitestig {
            IisVersion  = '10.0'
            StigVersion = '2.14'
        }
    }
}
