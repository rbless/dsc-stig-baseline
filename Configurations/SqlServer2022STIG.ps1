#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for sql server 2022 instance stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for sql server 2022 (instance-level).
    requires sql server 2022 to be installed on the target node.

.PARAMETER nodename
    target node name. defaults to 'localhost'.

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -SqlVersion 2022
    update stigversion below to match the latest available.
#>

Configuration sqlserver2022stig {
    param (
        [string]$nodename = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig — sql server 2022 instance
        # ---------------------------------------------------------------

        ##### applies the disa stig for sql server 2022 at the instance level via the powerstig SqlServer resource #####
        SqlServer baselineinstancestig {
            SqlVersion  = '2022'
            SqlRole     = 'Instance'
            StigVersion = '1.3'
        }
    }
}
