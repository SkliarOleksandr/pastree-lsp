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

set PLUGIN=clients\rad-studio
set TESTOUT=%PLUGIN%\tests\out
if not exist out mkdir out
if not exist out\dcu mkdir out\dcu
if not exist "%TESTOUT%" mkdir "%TESTOUT%"

rem -- 1. the server (Win64: a real project's closure needs more than a 32-bit
rem       address space, the rule every PasTree tool follows) ----------------
echo === server (Win64) ===
dcc64 -B -Q ^
 -U"%BDS%\lib\win64\release" ^
 -U"..\object-pascal-tree\source" ^
 -I"..\object-pascal-tree\source" ^
 -Usource ^
 -N0out\dcu -Eout pastree-server.dpr
if errorlevel 1 goto :fail

rem -- 2. the RAD Studio designtime package (Win32, and it links no PasTree) --
echo === RAD Studio package (Win32) ===
msbuild "%PLUGIN%\PasTreeIdePlugin.dproj" /t:Build /p:Config=Debug /p:Platform=Win32 /nologo /v:m
if errorlevel 1 goto :failbpl

rem -- 3. the harnesses (Win32, like the package they exercise, driving the
rem       Win64 server -- the same cross-bitness pairing the real plugin uses).
rem       Built into %TESTOUT% because each locates its own resources relative
rem       to its exe: ..\fixtures and ..\.. for the package directory.
echo === test harnesses (Win32) ===
for %%T in (VersionSmoke LspTransportSmoke LspClientSmoke LspProjectSmoke) do (
  dcc32 -B -Q -U"%PLUGIN%;source" -E"%TESTOUT%" -N"%TESTOUT%" "%PLUGIN%\tests\%%T.dpr"
  if errorlevel 1 goto :fail
)

rem -- 4. run them. VersionSmoke needs nothing; the other three take the server
rem       path as argv[1] -- passed explicitly rather than relying on their
rem       relative default, so a broken default cannot silently pass here.
echo === running harnesses ===
set FAILED=
for %%T in (VersionSmoke LspTransportSmoke LspClientSmoke LspProjectSmoke) do (
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
