#Requires -Module PowerSTIG
<#
.SYNOPSIS
    dsc configuration for sql server 2017 instance stig baseline.

.DESCRIPTION
    uses PowerSTIG to apply the disa stig for sql server 2017 (instance-level).
    requires sql server 2017 to be installed on the target node.

    note: disa did not release a separate stig benchmark for sql server 2017.
    the sql server 2016 stig benchmark is the applicable disa guidance for 2017 instances.
    this is standard disa practice -- sql 2017 is governed by the 2016 stig.

.PARAMETER nodename
    target node name. defaults to 'localhost'.

.NOTES
    to check available stig versions bundled with your powerstig version, run:
        Get-StigList -SqlVersion 2016
#>

Configuration sqlserver2017stig {
    param (
        [string]$nodename       = 'localhost',
        [string]$serverinstance = 'localhost'
    )

    Import-DscResource -ModuleName PowerSTIG
    Import-DscResource -ModuleName PSDscResources

    Node $nodename {

        # ---------------------------------------------------------------
        # disa stig -- sql server 2017 instance
        # disa applies the sql server 2016 stig benchmark to 2017 instances.
        # note: Bootstrap.ps1 pre-creates C:\Audits before calling Apply so
        # powerstig can write the STIG_AUDIT object there without errors.
        # ---------------------------------------------------------------

        ##### sql 2017 uses the 2016 stig benchmark per disa guidance -- no separate 2017 benchmark exists #####
        SqlServer baselineinstancestig {
            SqlVersion     = '2016'
            SqlRole        = 'Instance'
            StigVersion    = '3.6'
            ServerInstance = $serverinstance
            SkipRule       = @(
                'V-213967.a',  # tls 1.0 client disabledbydefault=1 -- skipped: disabling tls 1.0 breaks ssis packages
                'V-213967.e',  # tls 1.0 server disabledbydefault=1 -- skipped: same
                'V-213967.i',  # tls 1.0 client enabled=0 -- skipped: same
                'V-213967.m'   # tls 1.0 server enabled=0 -- skipped: same
            )
        }
    }
}

