@echo off
rem Build the whole product: the LSP server, the RAD Studio package for each
rem IDE of the chosen version, and the package's test harnesses -- then run
rem the harnesses.
rem
rem ONE SCRIPT FOR BOTH HALVES, ON PURPOSE. The server and the package are one
rem deliverable sharing one version (PasLsp.ProductVersion), and the failure
rem this replaces was exactly a half-rebuild: a fresh package running against
rem yesterday's exe. Building them separately is how that happens; building them
rem together is how it stops. The client checks at handshake that the two
rem versions match, which only means anything if a normal build produces both.
rem The same goes for the two IDEs of one version: both packages come from this
rem one run, so a 64-bit IDE cannot be left with last week's package.
rem
rem THE IDE MUST BE CLOSED. A running RAD Studio holds the .bpl, and a live LSP
rem session holds pastree-server.exe -- either one turns this into a confusing
rem "cannot create output file".
rem
rem Requires the PasTree repo as a sibling: ..\object-pascal-tree (the server
rem links it; the package deliberately does not -- see
rem clients\rad-studio\README.md). A release archive ships the two directories
rem in exactly that arrangement, so this script is the same script there --
rem no second layout that only ever runs on someone else's machine.
rem
rem Takes the same arguments as scripts\ide.bat: an explicit RAD Studio version,
rem win32 and/or win64 to narrow the IDEs, and --yes.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem WHICH RAD STUDIO, AND WHICH OF ITS IDEs -- resolved before anything is
rem compiled, because it may ask, and a question is worth nothing after a
rem five-minute build. See scripts\ide.bat for why one place decides this.
call "%~dp0scripts\ide.bat" %*
if errorlevel 1 exit /b 1

rem THE IDE MUST BE CLOSED, and it is now CHECKED rather than only stated
rem above. A running RAD Studio holds the .bpl, and what msbuild then reports
rem is "F2039 Could not create output file" naming a path - which says nothing
rem about the IDE and reads like a permissions or disk problem. That message
rem cost time three separate times while this script was being written, and
rem once more from release.bat, which reached the same failure through here
rem because only install.bat was checking.
call "%~dp0scripts\ide-closed.bat"
if errorlevel 1 exit /b 1

call "%BDSROOT%\bin\rsvars.bat"

rem DCUS: every compilation in this repository writes its .dcu files under
rem out\dcu, and nothing else writes anything there. They are intermediate
rem output - no build step consumes a .dcu from a previous run (every dcc call
rem here passes -B, a full rebuild, and msbuild's Build target is the same) -
rem so the directory exists to be DELETED, which is the point: one path to
rem exclude from a backup, and one path to clear when something looks stale.
rem Left at their defaults they land next to the sources instead, scattered
rem across source\, clients\rad-studio\ and the harness output directory.
rem
rem SPLIT BY PLATFORM, because this product compiles the SAME units for both:
rem the server is Win64, the package and harnesses are Win32 and - for a 64-bit
rem IDE - Win64 as well, so PasLsp.ProductVersion.dcu exists twice and one
rem would silently overwrite the other. Every call here passes -B, so a
rem clobber could not corrupt a build -- but it would leave a directory whose
rem contents depend on build order, and the first person to drop -B would get
rem a platform-mismatch error with no obvious cause.
rem WHICH PASTREE -- and say so out loud. The server links PasTree, so which
rem checkout was compiled in is part of what this build IS, and that checkout
rem is edited independently of this one. "PasTree 0.20.3" from --version at the
rem end names a version; the directory and commit name the actual source, which
rem is what a "but it worked yesterday" needs.
rem
rem MISSING IS TWO DIFFERENT SITUATIONS. In a git checkout it means the sibling
rem was never cloned, and cloning it is right. In an unpacked release archive
rem it means the archive was unpacked in part, and cloning would be WRONG: it
rem would fetch whatever PasTree is newest today rather than the one this
rem release was built and tested against, and the mismatch would be silent.
rem The presence of .git is what separates the two - a release archive is
rem exported sources and carries none.
set PASTREE=..\object-pascal-tree
if not exist "%PASTREE%\source" (
  if exist ".git\NUL" (
    echo === PasTree not found next to this repo, cloning it ===
    git clone https://github.com/SkliarOleksandr/object-pascal-tree.git "%PASTREE%"
    if errorlevel 1 goto :fail
  ) else (
    echo.
    echo PasTree sources are missing: "%PASTREE%\source" does not exist.
    echo This looks like a release archive rather than a git checkout, so the
    echo two directories must sit side by side exactly as they were packed:
    echo.
    echo     ^<archive^>\pastree-lsp\          ^(this one^)
    echo     ^<archive^>\object-pascal-tree\
    echo.
    echo Unpack the whole archive and run this again.
    exit /b 1
  )
)
rem The commit alone would be a HALF-TRUTH, and a confident-looking one: that
rem checkout is edited by other sessions, so its working tree is routinely
rem ahead of its last commit, and a build compiled from uncommitted changes
rem reported as a bare hash is a build nobody can reproduce from that hash.
echo === PasTree sources ===
for %%D in ("%PASTREE%") do echo   dir:     %%~fD
set "LDIRTY="
for /f "delims=" %%S in ('git -C "%PASTREE%" status --porcelain --untracked-files^=no 2^>nul') do set "LDIRTY= + uncommitted changes"
git -C "%PASTREE%" log -1 --format="  commit:  %%h %%d!LDIRTY!" 2>nul
findstr /c:"PasTreeVersion = " "%PASTREE%\source\PasTree.Version.pas"

rem EVERYTHING THE COMPILER PRODUCES IS PER RAD STUDIO VERSION, because more
rem than one may be installed and the plugin may be installed into each. Two
rem IDE versions cannot share one .bpl - a designtime package loads only in the
rem compiler that built it - and they cannot share .dcu files either, which is
rem the failure that would come first and read as nonsense ("unit was compiled
rem with a different version of ...") in a build that changed nothing.
rem
rem AND THE PACKAGE IS PER IDE WITHIN THAT: out\<version>\win32\ for the 32-bit
rem IDE, out\<version>\win64\ for the 64-bit one (RAD Studio 13 has both, in
rem bin\ and bin64\). The two BPLs have the same name and cannot share a
rem directory; a subdirectory each, rather than Win32 left where it was, keeps
rem every BPL exactly two levels below out\, which is where FindServerExe
rem looks for the server.
rem
rem THE SERVER IS THE EXCEPTION and stays at out\pastree-server.exe: it is a
rem standalone Win64 process talking a protocol, not a package, so one build of
rem it serves every IDE of every version. That is also why the package looks
rem for it two directories above its own - see FindServerExe.
set PLUGIN=clients\rad-studio
set TESTOUT=%PLUGIN%\tests\out
set TESTOUT64=%PLUGIN%\tests\out64
set DCU32=%CD%\out\dcu\%BDSVER%\win32
set DCU64=%CD%\out\dcu\%BDSVER%\win64
set HARNESSES=VersionSmoke LspTextSmoke LspTransportSmoke LspClientSmoke LspProjectSmoke
set "LBUILD64="
for %%P in (%BDSPLATFORMS%) do if /i "%%P"=="win64" set "LBUILD64=1"
if not exist out mkdir out
if not exist "%DCU32%" mkdir "%DCU32%"
if not exist "%DCU64%" mkdir "%DCU64%"
if not exist "%TESTOUT%" mkdir "%TESTOUT%"
if defined LBUILD64 if not exist "%TESTOUT64%" mkdir "%TESTOUT64%"

rem -- 1. the server (Win64: a real project's closure needs more than a 32-bit
rem       address space, the rule every PasTree tool follows) ----------------
rem       -GD writes a DETAILED map next to the exe, and it is not optional
rem       tooling. An EAccessViolation reaching a user's pastree-lsp.log says
rem       only "offset 27F109" - a unit, a routine and a line only come back
rem       from a map, and only from the map built from the SAME sources, which
rem       is why it is produced by the ordinary build rather than by a
rem       reproduction attempt days later. The 2026-09-02 report was diagnosed
rem       this way and could not have been diagnosed any other way.
echo === server (Win64) ===
dcc64 -B -Q -GD ^
 -U"%BDS%\lib\win64\release" ^
 -U"%PASTREE%\source" ^
 -I"%PASTREE%\source" ^
 -Usource ^
 -N0"%DCU64%" -Eout pastree-server.dpr
if errorlevel 1 goto :fail

rem -- 2. the RAD Studio designtime package, once per IDE (and it links no
rem       PasTree, whichever IDE it is for) --------------------------------
for %%P in (%BDSPLATFORMS%) do (
  call :package %%P
  if errorlevel 1 goto :failbpl
)

rem -- 3. the harnesses: Win32 always, like the package every supported
rem       version has, driving the Win64 server -- the same cross-bitness
rem       pairing the 32-bit IDE uses. And Win64 as well whenever the Win64
rem       package was built: the harnessed units are the IDE-free half of both
rem       packages, and the transport's process and handle plumbing is exactly
rem       where pointer size can break one flavour and not the other.
rem       EXEs go to %TESTOUT% (%TESTOUT64%) because each locates its own
rem       resources relative to its exe: ..\fixtures and ..\.. for the package
rem       directory - which is also why the Win64 set gets a SIBLING directory
rem       rather than one below tests\out. DCUs go to out\dcu with every other
rem       build's of that platform -- see DCUS, above.
echo === test harnesses (Win32) ===
rem       One fixture is a unit the server must see ONLY compiled: its source
rem       sits in tests\dcusrc (on no search path of the harness) and its .dcu
rem       goes to tests\fixtures\dcu32, which LspClientSmoke adds as a search
rem       path. Exercises PasTree's .dcu fallback and pastree/dcuSource with
rem       whichever compiler this build uses - the reader takes Delphi 11 to 13.
rem       It is data for the server, so both harness sets share the one fixture.
if not exist "%PLUGIN%\tests\fixtures\dcu32" mkdir "%PLUGIN%\tests\fixtures\dcu32"
dcc32 -B -Q -N0"%PLUGIN%\tests\fixtures\dcu32" "%PLUGIN%\tests\dcusrc\DemoDcuLib.pas"
if errorlevel 1 goto :fail
for %%T in (%HARNESSES%) do (
  dcc32 -B -Q -U"%PLUGIN%;source" -E"%TESTOUT%" -N0"%DCU32%" "%PLUGIN%\tests\%%T.dpr"
  if errorlevel 1 goto :fail
)
if defined LBUILD64 (
  echo === test harnesses ^(Win64^) ===
  for %%T in (%HARNESSES%) do (
    dcc64 -B -Q -U"%PLUGIN%;source" -E"%TESTOUT64%" -N0"%DCU64%" "%PLUGIN%\tests\%%T.dpr"
    if errorlevel 1 goto :fail
  )
)

rem -- 4. run them. VersionSmoke and LspTextSmoke need nothing; the other three
rem       take the server path as argv[1] -- passed explicitly rather than
rem       relying on their relative default, so a broken default cannot
rem       silently pass here.
echo === running harnesses ===
set FAILED=
for %%T in (%HARNESSES%) do (
  echo --- %%T
  "%TESTOUT%\%%T.exe" "%CD%\out\pastree-server.exe"
  if errorlevel 1 set FAILED=!FAILED! %%T
)
if defined LBUILD64 (
  for %%T in (%HARNESSES%) do (
    echo --- %%T ^(Win64^)
    "%TESTOUT64%\%%T.exe" "%CD%\out\pastree-server.exe"
    if errorlevel 1 set FAILED=!FAILED! %%T^(Win64^)
  )
)

echo.
"out\pastree-server.exe" --version
for %%P in (%BDSPLATFORMS%) do echo   package: %CD%\out\%BDSVER%\%%P\PasTreeIdePlugin.bpl

rem THE LAYOUT BEFORE THE PER-IDE SPLIT, still registered. Until 0.56.0 the BPL
rem was out\<version>\PasTreeIdePlugin.bpl, and this build no longer writes
rem that file - so an IDE still registered to it keeps loading the last one
rem built there, and every fix after this build "does not work". install.bat
rem moves the registration; this only says so, because a build must not change
rem what the IDE loads.
reg query "HKCU\Software\Embarcadero\BDS\%BDSVER%\Known Packages" /v "%CD%\out\%BDSVER%\PasTreeIdePlugin.bpl" >nul 2>&1
if not errorlevel 1 (
  echo.
  echo WARNING: RAD Studio %BDSVER% is still registered to out\%BDSVER%\PasTreeIdePlugin.bpl,
  echo which this build no longer writes - the IDE would load a stale package.
  echo Run install.bat once to move the registration to out\%BDSVER%\win32\.
)

if not "!FAILED!"=="" (
  echo.
  echo BUILD OK, HARNESSES FAILED:!FAILED!
  exit /b 1
)
echo.
echo all built, all harnesses passed
exit /b 0

rem ---------------------------------------------------------------------------
rem The package for one IDE: %1 is win32 or win64, the directory name under
rem out\<version>\ and out\dcu\<version>\; msbuild wants the platform's own
rem spelling. The output paths are passed here rather than left to the
rem .dproj: they depend on which RAD Studio this run picked, and msbuild does
rem not expose that version as a property to write into the project (checked:
rem there is no $(ProductVersion) - it expands to nothing and the build fails
rem on a path ending in a bare separator). The .dproj keeps out\ide\$(Platform)
rem for a build started from inside the IDE, which install.bat treats as a
rem stale location.
:package
set "LPLAT=%~1"
if /i "%LPLAT%"=="win64" (
  set "LMSPLAT=Win64"
  set "LIDE=64-bit IDE"
) else (
  set "LMSPLAT=Win32"
  set "LIDE=32-bit IDE"
)
set "LBPLOUT=%CD%\out\%BDSVER%\%LPLAT%"
echo === RAD Studio package (%LMSPLAT%, for the %LIDE%) ===
if not exist "%LBPLOUT%" mkdir "%LBPLOUT%"
msbuild "%PLUGIN%\PasTreeIdePlugin.dproj" /t:Build /p:Config=Debug /p:Platform=%LMSPLAT% /p:DCC_MapFile=3 /p:DCC_BplOutput="%LBPLOUT%" /p:DCC_DcpOutput="%LBPLOUT%" /p:DCC_DcuOutput="%CD%\out\dcu\%BDSVER%\%LPLAT%" /nologo /v:m
exit /b %errorlevel%

:failbpl
echo.
echo The package failed to build. If the error mentions the .bpl being in use,
echo close RAD Studio first -- a loaded designtime package cannot be replaced.
exit /b 1

:fail
echo.
echo BUILD FAILED
exit /b 1
