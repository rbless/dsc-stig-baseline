dsc stig baseline - multi-platform
written by Ryan Blessing

the use of Claude Code was used in this project to enhance already-written
scripts and to accelerate development throughout.
=======================================

about
-----
this project automates the application of disa stigs using powershell dsc
and powerstig. it is designed for air-gapped environments - once the deployment
zip is built on an internet-connected machine, no internet access is required
on target vms.

bootstrap automatically detects what is installed on the target machine and
applies the appropriate stig configurations. supported targets:

  os:       windows server 2016, 2019, 2022 (member server or domain controller)
  database: sql server 2016, 2017, 2019, 2022
  web:      iis 10.0 (server + site)
  app:      adobe acrobat pro, adobe acrobat reader dc

scap scanning content (for use with scc) is included in StigContent\ for:
  iis 8.5 server, iis 8.5 site, windows server 2012 r2 ms, windows server 2012 r2 dc

note: oracle database, apache 2.4, and sql server 2012/2014 stigs exist as
manual checklists only - disa has not released automated scap benchmark content
for these products. they cannot be enforced via dsc or scanned with scc.


first time setup - step by step
--------------------------------

step 1
    - download modules (internet-connected machine, run once)
      powershell: .\VendorModules.ps1
      downloads all required dsc modules from psgallery to .\VendorOutput\Modules\.
      only needed once, or when updating module versions.

step 2
    - provision your target vm
      spin up your windows server vm (azure, vsphere, bare metal, etc.)
      ensure winrm is available and you can rdp in as a local admin.

step 3
    - copy and extract the zip (if you have storage container in azure, az copy way faster)
      copy dsc-stig-fixed.zip to the target machine.
      extract it to C:\
      the zip extracts to a DSC\ folder - it will land at C:\DSC\.
      do not extract into C:\DSC or you will get C:\DSC\DSC\.

step 4
    - run bootstrap (on the target vm, as administrator)
      powershell: C:\DSC\Bootstrap.ps1
      - installs vendored modules from C:\DSC\Modules\
      - configures the lcm (applyandautocorrect, 15-minute check interval)
      - auto-detects os version, sql server, iis, apache, and adobe installs
      - compiles one mof per detected target into C:\DSC\MOF\<target>\
      run this before anything else.

step 5
    - apply the configuration (on the target vm, as administrator)
      powershell: C:\DSC\Apply.ps1
      applies all compiled mofs to the machine. expect verbose dsc output - normal.
      the machine may reboot during apply if the lcm requires it. rdp back in after.

step 6
    - verify compliance
      powershell: C:\DSC\DriftTest.ps1
      runs compliance checks against all compiled mofs and writes a json report
      to C:\DSC\Logs\. exit code 0 = compliant, 1 = drift, 2 = error.
      optional: run scc against the scap benchmarks in StigContent\ before/after.


ongoing use
-----------
- the lcm is set to applyandautocorrect - it will re-enforce the config every
  15 minutes automatically. manual apply is only needed after re-running bootstrap.
- run DriftTest.ps1 on a schedule for audit reporting (json output per target)
- use DriftTest.ps1 -AutoRemediate $true to invoke Apply.ps1 on drift detection
- when updating to a new package version, bootstrap archives the previous install
  to C:\DSC\History\ before overwriting

adding new stig targets
-----------------------
1. create a config script in Configurations\ following the existing pattern
2. add an entry to the $configmap table in Bootstrap.ps1
3. add detection logic to Get-StigTargets in Bootstrap.ps1 if the product
   is not already detected
4. re-run VendorModules.ps1 if new dsc modules are required
5. rebuild and redistribute the zip


********* changelog *********

version history
=======================================

v1.0.0
    - initial release
    - first pass at the dsc config and supporting scripts
    - got the basic structure in place: bootstrap, apply, drifttest, build-package
    - written with ai assistance, rough around the edges but functional as a starting point

v1.1.0
    - repo cleanup and bug fixes (ai-corrected)
    - ai corrected several issues from the original 1.0 scripts:
        * vendormodules.ps1 was missing entirely - created from scratch
        * windowsserver2016stig.ps1 moved to configurations/ where bootstrap expected it
        * bootstrap.ps1 was referencing $previousversionfile before definition - fixed
        * em dashes in log strings were breaking the powershell parser - replaced
        * expanded .gitignore to cover runtime folders and .claude directory

v1.1.1
    - manual corrections
    - closed missing brackets
    - added notes and comments where language was unclear (to ryan)
    - general readability pass (for ryan)

v1.2.0
    - stig version fix and package corrections
    - stigversion updated to 2.10 (latest available for ws2016 in powerstig 4.29.0)
    - removed vmware modules pulled in as unwanted dependencies
    - first successful bootstrap and apply run on a live azure ws2016 vm
    - readme.txt added and included in the zip package

v1.2.1
    - drift test enhancement
    - added get-dscconfigurationstatus to drift test json report
    - captures last apply result, reboot status, duration, and lcm mode

v1.2.2
    - fix nuget provider install, add author to readme
    - replaced psgallery trust check with explicit nuget provider install
    - added author attribution to readme.txt

v1.3.0
    - multi-platform support and pipeline readiness
    - bootstrap now auto-detects os version, sql server, iis, apache, and adobe
    - bootstrap auto-detects dc vs member server via win32_computersystem.domainrole
    - lcm changed from applyandmonitor to applyandautocorrect (enforces every 15min)
    - apply.ps1 and drifttest.ps1 loop over mof subfolders per detected target
    - drifttest.ps1 aggregates all targets into a single json report
    - added config scripts: ws2019, ws2022, sql 2016/2017/2022, iis 10, adobe acrobat
    - sql 2017 uses sql 2016 benchmark per disa guidance (no separate 2017 stig)
    - vendormodules.ps1 default outputpath fixed to c:\dsc\modules
    - added stigcontent\ folder with iis 8.5 and ws2012r2 scap benchmarks
    - scap/scc installer (scc 5.12) included in scap\ folder
    - deployment zip (dsc-stig-baseline.zip) stored in git via lfs
    - git lfs configured for *.zip tracking

v1.4.0
    - sql stig fixes, encoding cleanup, zip slimdown
    - whoops - sql server config scripts were missing the ServerInstance property on
      the powerstig SqlServer resource. ps was prompting for it interactively during
      mof compilation which is not great. added ServerInstance = 'localhost' to sql
      2016, 2017, and 2022 config scripts. if you're running a named instance you'll
      wanna change that.
    - bootstrap.ps1 now passes -ServerInstance 'localhost' when calling sql config
      functions. os configs still get -OsRole, everything else takes defaults.
    - bootstrap.ps1 and all sql config scripts scrubbed of em dashes and other non-ascii
      characters. turns out powershell 5.1 on ws2016 reads utf-8 files as windows-1252
      unless there's a bom - the em dash bytes (e2 80 94) contain 0x94 which is a
      windows curly quote, which breaks string parsing. everything's ascii now, no more
      surprise parse errors on fresh vms.
    - vendoroutput\ removed from the deployment zip. it was dead weight - bootstrap
      installs from Modules\ directly, vendoroutput was just a duplicate of that plus
      ~400mb of vmware powercli we're not using. zip went from 828mb to 106mb.
    - tested end-to-end on azure ws2016 + sql 2017 developer vm. bootstrap detects
      both targets, compiles two mofs (WS2016 and SQL2017), auto-invokes apply.


v1.5.0
    - reboot persistence, sql audit cleanup, drifttest hardening
    - big one i missed: lcm push mode doesn't guarantee re-enforcement after a hard
      reboot if the pending config cache gets wiped. bootstrap now registers a windows
      scheduled task (DSC-ApplyOnBoot, runs as SYSTEM) that fires Apply.ps1 at every
      startup. belt and suspenders -- lcm still autocorrects every 15 min while running,
      scheduled task covers you on reboot. ephemeral servers will run Apply.ps1 on creation,
      covering both ends
    - stripped the custom createstigaudit script resource out of all sql config scripts.
      i had been pre-creating STIG_AUDIT at C:\STIG_Audit but powerstig's own SetQuery
      drops and recreates it at C:\Audits anyway, so our prereq resource was just
      fighting powerstig and losing. bootstrap now creates C:\Audits before calling
      Apply so powerstig has the directory it expects. 
    - ServerInstance default was 'MSSQLSERVER' on some scripts, '.' on others. fixed
      to 'localhost' across all sql configs. 'localhost' makes powerstig produce
      ServerName=localhost, InstanceName=MSSQLSERVER in the mof which is correct for
      the default instance. named pipes not required, tcp on localhost works fine.
    - Write-Log catch blocks in bootstrap.ps1 and apply.ps1 now strip new lines from
      the error message before passing to Write-Log. multi-line error strings were
      causing the second line to be parsed as the -level argument, which hit the
      ValidateSet and threw an extra error on top of the original one. 
    - drifttest.ps1 fixes: Found out duration property doesn't exist in ps 5.1 dsc objects
      (use DurationInSeconds instead), -Path and -Detailed are incompatible parameter
      sets so i split them into two calls, ResourcesInDesiredState can be null so
      arrays are filtered with Where-Object, domain SID checks that throw on standalone
      vms are caught and marked non-compliant rather than crashing the whole test run.

v1.5.1
    - skiprule corrections and zip naming convention
    - corrected dsc skiprule: V-73649 (logon banner) was incorrectly identified as the rdp
      lockout rule. replaced with V-225019 (deny log on through remote desktop services) which
      is the actual rule blocking local accounts from rdp in a gapped/avd environment.
    - added additional skiprules not applicable to environment: V-224862 (windows time service),
      V-225038 (smart card removal lock), V-225059 (fips algorithm policy)
    - deployment zip renamed to date-stamped format: dsc-stig-baseline-YYYY-MM-DD.zip
    - previous zip versions archived to Old Versions\ subfolder for historical reference

v1.5.2
    - dos logon banner (replaces dod banner)
    - V-225037 (logon banner caption) added to skiprule - dod-locked caption values are not
      applicable to dos environment. caption is now set directly via a custom registry dsc
      resource: 'LEGAL NOTICE - WARNING: For Official Use Only'
    - V-225036 (logon banner body) overridden via orgsettings with dos-approved legal notice
      text sourced from dos ginlsplash policy. the default dod banner text is replaced at mof
      compile time - no post-apply editing required.
    - confirmed powerstig 4.29.0 accepts orgsettings as a hashtable keyed by rule id with
      valuedata property - merges cleanly on top of org.default.xml at compile time

v1.5.3
    - ie mode stub (pending site list xml)
    - added ie mode registry block to all three os configs (2016, 2019, 2022), commented
      out pending enterprise site list xml from another team. two registry keys under
      HKLM:\SOFTWARE\Policies\Microsoft\Edge: InternetExplorerIntegrationLevel (dword 1)
      and InternetExplorerIntegrationSiteList (string, path/url tbd). uncomment both once
      the site list is available and the xml is built.

v1.5.4
    - build-package fixes: all configs included, vmware exclusion, archive naming
    - build-package.ps1 was hardcoded to only copy WindowsServer2016STIG.ps1 into the zip.
      all other configs (2019, 2022, sql 2016/2017/2022, iis 10, adobe acrobat) were silently
      excluded from every package built since v1.3.0. replaced the hardcoded entry with a
      glob copy of all *.ps1 files in Configurations\ so new configs are picked up automatically.
    - vmware powercli modules (VMware.OpenAPI, VMware.Vim, VMware.VimAutomation.*, VMware.vSphereDSC)
      were present in VendorOutput\Modules and getting bundled into every zip. removed them from
      VendorOutput\Modules and added a Where-Object filter in build-package.ps1 to exclude any
      VMware.* folder at build time - so even if they get pulled in by a future VendorModules run,
      they will not end up in the package.
    - zip dropped from ~79mb to ~7.68mb as a result of removing the vmware modules.
    - archive filename format changed from ddMMMyyyy to ddMMMyyyy_HHmm so multiple builds on the
      same day no longer collide (Rename-Item was failing with 'file already exists').

v1.5.5
    - 2019 stig skip rules and banner config, matching 2016 baseline
    - translated five ws2016 skip rules to their ws2019 V-number equivalents:
        * V-205733 (deny rdp logon), V-205800 (windows time service),
          V-205912 (smart card removal), V-205842 (fips policy), V-205632 (banner caption)
    - added V-205672 (deny access to this computer from the network) to skiprule -
      default value includes local account which blocks rdp on standalone vms
    - added orgsettings for V-205631 (banner body) with dos-approved legal notice text
    - added dos caption banner registry resource matching 2016 behavior

v1.5.6
    - explicitly disable fips via registry on 2016 and 2019
    - fips algorithm policy is skipped in powerstig on both platforms (V-225059 on 2016,
      V-205842 on 2019) because fips is not required in this environment. however, leaving
      the registry key unset allows a prior gpo push or os default to silently enable it.
    - added Registry disablefips block to WindowsServer2016STIG.ps1 and
      WindowsServer2019STIG.ps1: FipsAlgorithmPolicy\Enabled = 0. enforces the intent
      explicitly and prevents accidental drift.

v1.5.7
    - fix oracle detection crash under strict mode
    - bootstrap.ps1 was crashing at step 3 on machines with oracle registry keys (HKLM:\SOFTWARE\ORACLE\KEY_*)
      that don't have an ORACLE_HOME_VERSION property. set-strictmode -version latest throws
      PropertyNotFoundException on the .ORACLE_HOME_VERSION dereference. fixed by checking
      PSObject.Properties before accessing the value.
