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
rem Requires the PasTree repo checked out as a sibling: ..\object-pascal-tree
rem (the server links it; the package deliberately does not -- see
rem clients\rad-studio\README.md).
setlocal enabledelayedexpansion
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"

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
set PLUGIN=clients\rad-studio
set TESTOUT=%PLUGIN%\tests\out
set DCU32=%CD%\out\dcu\win32
set DCU64=%CD%\out\dcu\win64
if not exist out mkdir out
if not exist out\dcu\win32 mkdir out\dcu\win32
if not exist out\dcu\win64 mkdir out\dcu\win64
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
 -U"..\object-pascal-tree\source" ^
 -I"..\object-pascal-tree\source" ^
 -Usource ^
 -N0"%DCU64%" -Eout pastree-server.dpr
if errorlevel 1 goto :fail

rem -- 2. the RAD Studio designtime package (Win32, and it links no PasTree) --
echo === RAD Studio package (Win32) ===
msbuild "%PLUGIN%\PasTreeIdePlugin.dproj" /t:Build /p:Config=Debug /p:Platform=Win32 /p:DCC_MapFile=3 /nologo /v:m
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
