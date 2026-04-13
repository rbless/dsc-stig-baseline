dsc stig baseline - windows server 2016
written by Ryan Blessing

the use of Claude code was used in this project to enhance an already written 
script, and to fix issues that kept popping up in a quick manner
=======================================

about
-----
this project automates the application of the disa stig for windows server 2016
using powershell dsc and powerstig. it is designed to work in air-gapped environments
once the initial module download has been completed on an internet-connected machine.


first time setup - step by step
--------------------------------

step 1 
	- download modules (internet-connected machine, run once)
  	 powershell: .\VendorModules.ps1
  	 this pulls all required dsc modules from psgallery and saves them to
  	 VendorOutput\Modules\. you only need to do this once, or when updating module versions.

step 2 
	- build the deployment package
  	  powershell: .\Build-Package.ps1
  	  bundles the scripts, config, and vendored modules into a versioned zip file.
  	  output lands in dist\DSC_v<version>.zip

step 3 
	- spin up your target vm
  	  if using the included tofu config (c:\tofu): tofu apply
	  otherwise provision your windows server 2016 machine however you normally would.

step 4 
	- copy and extract the zip
  	  copy dist\DSC_v<version>.zip to the target machine.
  	  extract it to C:\ 
	- the zip contains a DSC\ folder so it will land at C:\DSC\.
  	  do not extract into C:\DSC or you will get C:\DSC\DSC\.

step 5 
	- run bootstrap (on the target vm, as administrator)
  	  powershell: C:\DSC\Bootstrap.ps1
  	  installs the vendored modules, configures the lcm, and compiles the mof.
  	  run this before anything else.

step 6 
	- apply the configuration (on the target vm, as administrator)
  	  powershell: C:\DSC\Apply.ps1
  	  pushes the stig config to the machine. expect some red/verbose output - that is normal.
  	  the machine may reboot during apply if the lcm requires it. rdp back in after.

step 7 
	- verify compliance
  	  powershell: C:\DSC\DriftTest.ps1
  	  runs a compliance check and writes a json report to C:\DSC\Logs\.
  	  exit code 0 = compliant, 1 = drift detected, 2 = error.
	OPTIONAL: run SCAP compliance scans before/after

step 8 
	- tear down when done (if using tofu)
  	  tofu destroy
  	  don't forget this step - leaving the vm running costs money.


ongoing use
-----------
- re-run Apply.ps1 any time you want to re-enforce the config
- schedule DriftTest.ps1 as a recurring task to catch configuration drift
- use DriftTest.ps1 -AutoRemediate $true to auto-fix drift when detected
- when updating to a new package version, bootstrap handles archiving the previous install


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
      	* vendormodules.ps1 was missing entirely - created from scratch to handle
        offline module downloads from psgallery
      	* windowsserver2016stig.ps1 was sitting in the repo root instead of
        configurations/ where build-package expected it - moved it
      	* bootstrap.ps1 was referencing $previousversionfile before it was ever
        defined - fixed
      	* em dashes in log strings were breaking the powershell parser on the vm -
        replaced with regular hyphens across bootstrap, apply, and drifttest
      	* expanded .gitignore to cover runtime folders and the .claude directory

v1.1.1 
	- manual corrections 
  	- closed some missing brackets that slipped through
  	- added #notes and comments in places the language was unclear or overlooked
  	- general cleanup pass on readability

v1.2.0 	
	- stig version fix and package corrections
  	- the original config had stigversion set to 2.6 which doesnt exist in
    	  powerstig 4.29.0 - updated to 2.10 (latest available for ws2016)
  	- updated powerstigversion in version file to reflect actual vendored version (4.29.0)
  	- removed vmware modules that save-module pulled in as unwanted dependencies,
          dropped the zip from ~79mb down to ~7.66mb
  	- fixed build-package log string that had an em dash causing a parse error
  	- first successful bootstrap and apply run on a live azure ws2016 vm
  	- readme.txt added and included in the zip package

v1.2.1 
	- drifttest enhancement
  	- added get-dscconfigurationstatus to the drifttest json report
  	- captures last apply result, reboot pending status, duration, and lcm mode
    	  alongside the existing per-resource compliance data

v1.2.2 
	- fix nuget provider install, add author to readme
  	- replaced psgallery trust check in vendormodules.ps1 with explicit nuget
    	  provider install to prevent interactive prompts on fresh ws2016 machines
  	- added author attribution to readme.txt
