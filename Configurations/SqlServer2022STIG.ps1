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
        [string]$nodename       = 'localhost',
        [string]$serverinstance = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig -- sql server 2022 instance
        # note: Bootstrap.ps1 pre-creates C:\Audits before calling Apply so
        # powerstig can write the STIG_AUDIT object there without errors.
        # ---------------------------------------------------------------

        ##### applies the disa stig for sql server 2022 at the instance level via the powerstig SqlServer resource #####
        SqlServer baselineinstancestig {
            SqlVersion     = '2022'
            SqlRole        = 'Instance'
            StigVersion    = '1.3'
            ServerInstance = $serverinstance
            SkipRule       = @(
                'V-271310.b',  # tls 1.0 disable rule -- skipped: disabling tls 1.0 breaks ssis packages
                'V-274444'     # sa disable -- skipped: setscript runs ALTER LOGIN [sa] DISABLE on principal_id=1;
                               # broke app admin access on awis-sql2-SOW (account disabled, appeared removed).
                               # sa is already renamed/managed outside dsc; re-enable manually and skip enforcement here.
            )
        }
    }
}
