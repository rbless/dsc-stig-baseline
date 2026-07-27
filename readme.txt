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


********* active skip rules *********

this section is the authoritative reference for every rule currently skipped across all configs.
keep this updated when rules are added or removed. reasoning is documented here for cyber review.

--- windows server (2016 / 2019 / 2022) ---

  V-225019 / V-205733 / V-254439  deny log on through remote desktop services
    reason: this rule removes local accounts from the rdp allow list. in the avd/gapped
            environment local accounts are the only logon method. enforcing this locks
            operators out of the vm entirely.

  V-225037 / V-205632 / V-254458  logon banner caption (LegalNoticeCaption)
    reason: the dod-mandated caption value is not appropriate for a dos environment.
            rule is skipped and the dos-approved caption is set directly via a registry
            resource in each os config: 'LEGAL NOTICE - WARNING: For Official Use Only'

  V-224862 / V-205800 / V-254281  windows time service (w32tm / ntp)
    reason: the rule requires an external ntp source. this environment is air-gapped
            and has no external ntp reachable. enforcing causes drift warnings and
            failed compliance checks with no corrective action available.

  V-225038 / V-205912 / V-254459  smart card removal lock
    reason: smart cards are not used in this avd environment. local logon only.
            enforcing this causes unnecessary lockouts.

  V-225059 / V-205842  (ws2016 / ws2019 only) fips algorithm policy
    reason: fips is not required in this environment and enabling it breaks certain
            application components. rule is skipped and fips is explicitly disabled
            via Registry disablefips resource (Enabled=0) in each os config to prevent
            accidental enforcement via gpo drift.
    note:   ws2022 stig has NO dedicated fips rule -- the disablefips registry resource
            in the ws2022 config is drift protection only. V-254276 was previously listed
            here mislabeled as fips; it is actually the smbv1 disable rule (SMB1=0) and
            has been removed from the ws2022 skip list so smbv1 remains disabled.

  V-205672 / V-254435  (ws2019 / ws2022 only) deny access to this computer from the network
    reason: the default membership of this right includes local accounts. on standalone
            vms this blocks rdp. skipped to preserve management access.

--- sql server 2016 / 2017 ---

  V-213967.a  tls 1.0 client — DisabledByDefault=1
  V-213967.e  tls 1.0 server — DisabledByDefault=1
  V-213967.i  tls 1.0 client — Enabled=0
  V-213967.m  tls 1.0 server — Enabled=0
    reason: these four rules disable tls 1.0 in the windows schannel registry. ssis
            packages in use by the application connect via .net components that default
            to tls 1.0. disabling tls 1.0 caused ssis package connection failures.
            tls 1.2 enforcement rules (V-213967.q/.r/.s/.t) are still active.

  V-214028  sa account disable
    reason: the setscript runs ALTER LOGIN [sa] DISABLE against principal_id=1.
            on awis-sql2-SOW this disabled the install-created admin account making it
            appear removed (the account exists but cannot log in). sa/admin account
            management is handled outside dsc. re-enable manually if needed:
            ALTER LOGIN [sa] ENABLE (or the renamed equivalent) from any active sysadmin.

  V-213958  clr enabled -- SqlServerConfiguration sp_configure 'clr enabled', 0
    reason: SqlServerConfiguration reasserts 'clr enabled' to 0 every 15 minutes
            via the lcm applyandautocorrect pass. app owner requires clr assemblies
            enabled -- appeared as intermittent clr outages to the user because
            manually enabling it lasted only until the next lcm consistency check.
            skipped in SqlServer2017STIG.ps1 only. SqlServer2016STIG.ps1 remains
            strict until a 2016 instance reports the same requirement. expect
            V-213958 to show open on scap scans of the 2017 instance; document
            as poam citing mission need for clr assemblies.

--- sql server 2022 ---

  V-271310.b  tls 1.0 disable rule
    reason: same as V-213967.i/.m above. sql 2022 stig consolidates the tls 1.0
            disablement into a single rule. ssis package compatibility.

  V-274444  sa account disable
    reason: same as V-214028 above. sql 2022 equivalent rule.


********* landmines and known behavior *********

these are STIG rules or PowerSTIG behaviors we do NOT skip, but that operators
should be aware of because they can cause disruptive or hard-to-diagnose incidents.

--- sql audit ON_FAILURE = SHUTDOWN ---

  affected rules: V-213939, V-213940, V-213942, V-213943, V-213989,
                  V-214000, V-214004, V-214014 (sql 2016/2017)
                  and their sql 2022 equivalents (V-271272, V-271273, V-271351,
                  V-271370, V-271375 -- audit rules with the same setscript)

  behavior: each of these rules runs a T-SQL setscript that creates the
            STIG_AUDIT server audit with:
                WITH (QUEUE_DELAY = 1000, ON_FAILURE = SHUTDOWN)
            if the audit target (C:\Audits) becomes unwritable -- disk full,
            permission changes, folder deletion -- sql server SHUTS ITSELF DOWN.

  mitigation: Bootstrap.ps1 pre-creates C:\Audits with default acls before compile
              time. operators must monitor free space on the audit drive and never
              hand-edit permissions on C:\Audits. if sql server refuses to start
              after an apply, check the audit target first.

--- sql SqlScriptQuery is destructive ---

  behavior: PowerSTIG rules that use the SqlScriptQuery dsc resource run
            arbitrary T-SQL setscripts, which may include DROP LOGIN, DISABLE LOGIN,
            or ALTER SERVER ROLE ... DROP MEMBER. these are not reversible via dsc.

  mitigation: before enabling a new sql rule in ApplyAndAutoCorrect mode, read the
              setscript from StigData\Processed\SqlServer-*.xml. V-214028/V-274444
              already skipped as a known landmine (see skip rules section).

--- bootstrap default sql instance uses port 1433 ---

  behavior: Bootstrap.ps1 passes 'localhost,1433' to PowerSTIG for the default
            (MSSQLSERVER) instance to force tcp instead of named pipes.

  mitigation: if the default instance is configured on a non-standard tcp port,
            dsc will silently fail to connect. verify the instance is on 1433
            or extend Bootstrap.ps1 to read the port from
            HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\<MSSQLxx.MSSQLSERVER>\
            MSSQLServer\SuperSocketNetLib\Tcp\IPAll before adjusting.


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

v1.5.8
    - fix oracle not detected when ORACLE_HOME_VERSION registry property is absent
    - the v1.5.7 PSObject.Properties guard prevented the crash but silently skipped detection
      when ORACLE_HOME_VERSION doesn't exist in the registry (common on some oracle installs).
    - added fallback: parse the major version from the KEY_ subkey name itself
      (e.g. KEY_OraDB19Home1 -> 19, KEY_OraClient12Home1 -> 12) when the property is missing.

v1.5.9
    - fix sql named instance not detected / mof compilation fails for non-default instances
    - bootstrap was hardcoding ServerInstance = 'localhost' which powerstig resolves to
      MSSQLSERVER on the local machine. machines with named sql instances (e.g. SQLEXPRESS
      or custom instance names) would compile a mof pointing at the wrong instance and fail
      during Apply with 'Failed to obtain a SQL Server instance with name MSSQLSERVER'.
    - also fixed sql detection: was enumerating numeric version subkeys under the sql root
      which includes sql client tools and shared components (false positives for SQL2012/SQL2014
      on machines that only have sql tools installed, not an engine). switched to enumerating
      Instance Names\SQL registry values which lists only actual engine instances. value name
      is the instance name, value data (MSSQL14.INSTANCENAME) encodes the sql major version.
    - instance name now encoded in the detected target as SQL2017:INSTANCENAME and extracted
      at mof compile time, same pattern as WS2019:ms for os role.

v1.6.0
    - oracle correctly handled as manual-only stig
    - oracle 12c and 19c detection is kept (useful to know oracle is present in the log)
      but oracle database stig is a disa manual checklist only -- powerstig has no oracle
      database parser and there is no dsc module that can configure oracle internals.
      oracle entries removed from configmap, replaced with an explicit info log at runtime
      explaining why no mof is compiled. eliminates the misleading 'config script not found'
      warning that implied a missing file rather than a product that cannot be automated.

v1.6.1
    - apply.ps1: fix crash when lcm is in disabled mode
    - apply.ps1 was calling test-dscconfiguration after start-dscconfiguration. if the lcm
      transitioned to Disabled mode during the apply (pending reboot, gpo override, or machine
      never bootstrapped), test-dscconfiguration throws and crashes the entire apply run even
      though the configuration was already applied successfully.
    - added lcm refreshmode check at startup: if the lcm is Disabled before any work begins,
      throw a clear message telling the operator to run Bootstrap.ps1 first.
    - wrapped the post-apply test-dscconfiguration in try/catch: if it fails after the apply
      already ran, log a warning and continue rather than crashing the whole script.

v1.6.2
    - bootstrap.ps1: switch sql server connection to tcp to fix named-pipe deployment failures
      (see v1.6.3 for named instance follow-up fix)

v1.6.3
    - fix named sql instance connection: port cannot be appended after backslash in serverinstance
      (see v1.6.4 for additional sql and os registry fixes discovered during testing)

v1.6.4
    - skip sql sa-disable rules: V-214028 (sql 2016/2017) and V-274444 (sql 2022)
      (see v1.6.5 for ws2022 parity and skip rules reference section)

v1.6.5
    - add skip rule parity to windows server 2022 config
      (see v1.6.6 for correction: V-254276 was miscategorized and has been removed)
      ws2022 was missing the same environment exemptions applied to 2016 and 2019.
      added skiprule block with translated v-numbers: V-254439 (deny rdp logon),
      V-254435 (deny network access), V-254281 (windows time service),
      V-254459 (smart card removal), V-254276 (fips), V-254458 (banner caption).
      also added orgsettings for V-254457 (banner body), dos caption registry resource,
      and disablefips registry block to match 2016/2019 pattern.
    - add active skip rules reference section to readme.txt above changelog
      single authoritative list of all currently skipped rules with reasoning,
      organized by platform. intended for cyber review and change documentation.
      the setscript for these rules runs ALTER LOGIN [sa] DISABLE against principal_id=1.
      on awis-sql2-SOW this disabled the install admin account, making it appear removed.
      sa management is handled outside dsc; these rules are now skipped to prevent recurrence.
      to restore: ALTER LOGIN [sa] ENABLE (or the renamed equivalent) from any active sysadmin.
    - add Force=$true to disablefips and disablenetbioshelper in all three os configs (2016/2019/2022)
      both registry keys already exist on windows (FipsAlgorithmPolicy\Enabled and lmhosts\Start)
      and MSFT_RegistryResource requires Force=$true to overwrite pre-existing values. without it
      the WS2019 LCM consistency check was failing every 15 minutes with InvalidOperationException.
      powerstig splits serverinstance on backslash to separate servername from instancename, so
      localhost\INST1,1433 produced instancename='INST1,1433' which broke sqlprotocol wmi lookup
      with 'failed to obtain sql server instance with name INST1,1433'. named instances now use
      localhost\INSTANCE (shared memory handles local connections without a port). default instance
      keeps localhost,1433 -- port in the server name is safe because no backslash is present so
      smo reads servername='localhost,1433' and instancename='MSSQLSERVER' correctly.
      previously the serverinstance passed to sql configs was the raw registry instance name
      (e.g. MSSQLSERVER or SQLEXPRESS), which powerstig sql resources treated as the server
      hostname -- causing connections to fail via named pipes to a non-existent machine name.
      bootstrap now resolves the correct localhost,1433 (default instance) or
      localhost\INSTANCENAME,PORT (named instances, port read from tcp/ipall registry key)
      so dsc connects via tcp.
    - sql stigs: skip tls 1.0 schannel rules that were breaking ssis packages
      the sql 2016 stig rules V-213967.a/.e/.i/.m and sql 2022 rule V-271310.b disable
      tls 1.0 by setting Enabled=0 and DisabledByDefault=1 in schannel. these rules are
      now skipped so tls 1.0 remains available for ssis packages that require it.

v1.6.6
    - fix ws2022 skip list: remove V-254276 (mislabeled as fips in v1.6.5)
      V-254276 is actually the smbv1 disable rule (SMB1=0 in LanmanServer\Parameters),
      not the fips algorithm policy. skipping it disabled a security control we want on.
      the ws2022 stig has NO dedicated fips rule -- unlike ws2016 (V-225059) and
      ws2019 (V-205842). the disablefips registry resource remains in the ws2022 config
      but is now documented as drift protection only, not a rule override.
    - add "landmines and known behavior" reference section to readme.txt
      documents non-skipped rules and behaviors that can still cause operational
      issues: sql audit ON_FAILURE=SHUTDOWN, SqlScriptQuery destructiveness,
      and the bootstrap default-instance port 1433 assumption. intended for
      cyber/ops awareness so unexpected incidents can be diagnosed quickly.

v1.6.7
    - skip sql clr enabled rule on sql 2017 config
    - V-213958 (LegacyId V-79179) added to SqlServer2017STIG.ps1 skiprule. the
      SqlServerConfiguration dsc resource was reasserting sp_configure 'clr enabled', 0
      every 15 minutes via the lcm applyandautocorrect pass. app owner reported
      clr kept turning off after enabling it -- root cause was the drift correction.
    - SqlServer2016STIG.ps1 intentionally left strict for now. if a 2016 instance
      hits the same requirement, mirror the skip there and update the reference
      section above.
    - active skip rules reference section updated to include V-213958 under sql
      2016 / 2017 with note that it only applies to the 2017 config file.
