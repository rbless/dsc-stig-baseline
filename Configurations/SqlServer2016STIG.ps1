#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for sql server 2016 instance stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for sql server 2016 (instance-level).
    requires sql server 2016 to be installed on the target node.

.PARAMETER nodename
    target node name. defaults to 'localhost'.

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -SqlVersion 2016
    update stigversion below to match the latest available.
#>

Configuration sqlserver2016stig {
    param (
        [string]$nodename       = 'localhost',
        [string]$serverinstance = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig -- sql server 2016 instance
        # note: Bootstrap.ps1 pre-creates C:\Audits before calling Apply so
        # powerstig can write the STIG_AUDIT object there without errors.
        # ---------------------------------------------------------------

        ##### applies the disa stig for sql server 2016 at the instance level via the powerstig SqlServer resource #####
        SqlServer baselineinstancestig {
            SqlVersion     = '2016'
            SqlRole        = 'Instance'
            StigVersion    = '3.6'
            ServerInstance = $serverinstance
            SkipRule       = @(
                'V-213967.a',  # tls 1.0 client disabledbydefault=1 -- skipped: disabling tls 1.0 breaks ssis packages
                'V-213967.e',  # tls 1.0 server disabledbydefault=1 -- skipped: same
                'V-213967.i',  # tls 1.0 client enabled=0 -- skipped: same
                'V-213967.m',  # tls 1.0 server enabled=0 -- skipped: same
                'V-214028'     # sa disable -- skipped: setscript runs ALTER LOGIN [sa] DISABLE on principal_id=1;
                               # broke app admin access on awis-sql2-SOW (account disabled, appeared removed).
                               # sa is already renamed/managed outside dsc; re-enable manually and skip enforcement here.
            )
        }
    }
}
