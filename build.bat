@echo off
rem Build the whole product: the LSP server, the RAD Studio package, and the
rem package's test harnesses -- then run the harnesses.
rem
rem ONE SCRIPT FOR BOTH HALVES, ON PURPOSE. The server and the package are one
rem deliverable sharing one version (PasLsp.ProductVersion), and the failure
rem this replaces was exactly a half-rebuild: a fresh package running against
rem yesterday's exe. Building them separately is how that happens; building them
rem together is how it stops. The client checks at handshake that the two
rem versions match, which only means anything if a normal build produces both.
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
rem Takes the same arguments as scripts\ide.bat: an explicit RAD Studio version
rem and/or --yes.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem WHICH RAD STUDIO -- resolved before anything is compiled, because it may
rem ask, and a question is worth nothing after a five-minute build. See
rem scripts\ide.bat for why one place decides this.
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
rem here passes -B, a full rebuild) - so the directory exists to be DELETED,
rem which is the point: one path to exclude from a backup, and one path to
rem clear when something looks stale. Left at their defaults they land next to
rem the sources instead, scattered across source\, clients\rad-studio\ and the
rem harness output directory.
rem
rem SPLIT BY PLATFORM, because this product compiles the SAME units for both:
rem the server is Win64 and the package and harnesses are Win32, so
rem PasLsp.ProductVersion.dcu exists twice and one would silently overwrite the
rem other. Every call here passes -B, so a clobber could not corrupt a build --
rem but it would leave a directory whose contents depend on build order, and
rem the first person to drop -B would get a platform-mismatch error with no
rem obvious cause.
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
rem THE SERVER IS THE EXCEPTION and stays at out\pastree-server.exe: it is a
rem standalone Win64 process talking a protocol, not a package, so one build of
rem it serves every IDE. That is also why the package looks for it in its own
rem directory's PARENT - see FindServerExe.
set PLUGIN=clients\rad-studio
set TESTOUT=%PLUGIN%\tests\out
set BPLOUT=%CD%\out\%BDSVER%
set DCU32=%CD%\out\dcu\%BDSVER%\win32
set DCU64=%CD%\out\dcu\%BDSVER%\win64
if not exist out mkdir out
if not exist "%BPLOUT%" mkdir "%BPLOUT%"
if not exist "%DCU32%" mkdir "%DCU32%"
if not exist "%DCU64%" mkdir "%DCU64%"
if not exist "%TESTOUT%" mkdir "%TESTOUT%"

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

rem -- 2. the RAD Studio designtime package (Win32, and it links no PasTree) --
echo === RAD Studio package (Win32) ===
rem The output paths are passed here rather than left to the .dproj: they
rem depend on which RAD Studio this run picked, and msbuild does not expose
rem that version as a property to write into the project (checked: there is no
rem $(ProductVersion) - it expands to nothing and the build fails on a path
rem ending in a bare separator). The .dproj keeps a plain out\ for a build
rem started from inside the IDE, which install.bat treats as a stale location.
msbuild "%PLUGIN%\PasTreeIdePlugin.dproj" /t:Build /p:Config=Debug /p:Platform=Win32 /p:DCC_MapFile=3 /p:DCC_BplOutput="%BPLOUT%" /p:DCC_DcpOutput="%BPLOUT%" /p:DCC_DcuOutput="%DCU32%" /nologo /v:m
if errorlevel 1 goto :failbpl

rem -- 3. the harnesses (Win32, like the package they exercise, driving the
rem       Win64 server -- the same cross-bitness pairing the real plugin uses).
rem       EXEs go to %TESTOUT% because each locates its own resources relative
rem       to its exe: ..\fixtures and ..\.. for the package directory. DCUs go
rem       to out\dcu\win32 with every other Win32 build's -- see DCUS, above.
echo === test harnesses (Win32) ===
for %%T in (VersionSmoke LspTextSmoke LspTransportSmoke LspClientSmoke LspProjectSmoke) do (
  dcc32 -B -Q -U"%PLUGIN%;source" -E"%TESTOUT%" -N0"%DCU32%" "%PLUGIN%\tests\%%T.dpr"
  if errorlevel 1 goto :fail
)

rem -- 4. run them. VersionSmoke and LspTextSmoke need nothing; the other three
rem       take the server path as argv[1] -- passed explicitly rather than
rem       relying on their relative default, so a broken default cannot
rem       silently pass here.
echo === running harnesses ===
set FAILED=
for %%T in (VersionSmoke LspTextSmoke LspTransportSmoke LspClientSmoke LspProjectSmoke) do (
  echo --- %%T
  "%TESTOUT%\%%T.exe" "%CD%\out\pastree-server.exe"
  if errorlevel 1 set FAILED=!FAILED! %%T
)

echo.
"out\pastree-server.exe" --version
if not "!FAILED!"=="" (
  echo.
  echo BUILD OK, HARNESSES FAILED:!FAILED!
  exit /b 1
)
echo.
echo all built, all harnesses passed
exit /b 0

:failbpl
echo.
echo The package failed to build. If the error mentions the .bpl being in use,
echo close RAD Studio first -- a loaded designtime package cannot be replaced.
exit /b 1

:fail
echo.
echo BUILD FAILED
exit /b 1
