dsc stig baseline - windows server 2016
version history
=======================================

v1.0.0 - initial release
  - first pass at the dsc config and supporting scripts
  - got the basic structure in place: bootstrap, apply, drifttest, build-package
  - written with ai assistance, rough around the edges but functional as a starting point

v1.1.0 - repo cleanup and bug fixes (ai-corrected)
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

v1.1.1 - manual corrections (ryan)
  - closed some missing brackets that slipped through
  - added #notes and comments in places the language was unclear or overlooked
  - general cleanup pass on readability

v1.2.0 - stig version fix and package corrections
  - the original config had stigversion set to 2.6 which doesnt exist in
    powerstig 4.29.0 - updated to 2.10 (latest available for ws2016)
  - updated powerstigversion in version file to reflect actual vendored version (4.29.0)
  - removed vmware modules that save-module pulled in as unwanted dependencies,
    dropped the zip from ~79mb down to ~7.66mb
  - fixed build-package log string that had an em dash causing a parse error
  - first successful bootstrap and apply run on a live azure ws2016 vm
  - readme.txt added and included in the zip package

v1.2.1 - drifttest enhancement
  - added get-dscconfigurationstatus to the drifttest json report
  - captures last apply result, reboot pending status, duration, and lcm mode
    alongside the existing per-resource compliance data
