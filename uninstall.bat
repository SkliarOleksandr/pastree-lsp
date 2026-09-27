@echo off
rem Unregister the IDE package from RAD Studio - from each of the version's
rem IDEs, or only the one named. Builds nothing and deletes no build output -
rem out\ is left exactly as it was, so running install.bat again is all it
rem takes to come back.
rem
rem Usage:  uninstall.bat [version] [win32] [win64] [--yes]
rem         (the same arguments as install.bat)
rem
rem THIS EXISTS BECAUSE A DANGLING REGISTRATION IS NOT HARMLESS. Known Packages
rem names a BPL by full path; delete or move the repository and the IDE still
rem tries to load it, and greets every startup with "Can't load package" until
rem someone finds the registry key. Deleting the files without this step is the
rem obvious way to uninstall and the one that leaves that behind.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem Full path, not a bare name - see the note in install.bat about Git Bash and
rem NoDefaultCurrentDirectoryInExePath.
call "%~dp0scripts\ide.bat" %*
if errorlevel 1 exit /b 1

rem Same reason as install.bat, and only for the version being unregistered:
rem RAD Studio rewrites its package list on exit, so a removal made while it
rem runs comes back from the dead when it closes. See scripts\ide-closed.bat.
call "%~dp0scripts\ide-closed.bat"
if errorlevel 1 exit /b 1

call "%BDSROOT%\bin\rsvars.bat" >nul
set "LBASE=HKCU\Software\Embarcadero\BDS\%BDSVER%"
set "LPUB=%PUBLIC%\Documents\Embarcadero\Studio\%BDSVER%"
if not exist out mkdir out

set "LWHICH=32-bit and 64-bit IDE"
if "%BDSPLATFORMS%"=="win32" set "LWHICH=32-bit IDE"
if "%BDSPLATFORMS%"=="win64" set "LWHICH=64-bit IDE"

set "LFOUND="
for %%P in (%BDSPLATFORMS%) do call :unregister %%P

rem THE KEY MAPPINGS RECORD. The IDE writes one subkey under Editor\Options\
rem Known Editor Enhancements for every keyboard-binding module it has ever
rem seen, by the module's GetName, and never removes one - eight
rem PasTreeIdePlugin.* subkeys were found on 2026-09-21, seven of them dead
rem names. An uninstall that leaves them is not an uninstall. BUT THEY CANNOT
rem SIMPLY BE DELETED: the IDE places each module at its Priority in a list
rem sized by the count, so a gap stops RAD Studio from starting ("List index
rem out of bounds (15). TList range is 0..7" - the first version of this step,
rem same day). The remaining modules must be renumbered to 0..N-1, which is
rem why this is a PowerShell script (scripts\prune-key-mappings.ps1) rather
rem than a reg delete loop: it deletes and renumbers as one step, and closes
rem the gaps even when a deletion fails halfway. -File, not -Command - see
rem scripts\ide-closed.bat for what cmd's parser does to an inline
rem expression.
rem
rem ONLY ONCE THE PACKAGE IS GONE FROM BOTH IDEs. The key has no x64 twin
rem (checked on 13.2): the 32-bit and the 64-bit IDE of a version share these
rem records, by the same module names. So "uninstall.bat win32" with the
rem 64-bit IDE still registered leaves them for the IDE that still uses them.
set "LSTILL="
for %%K in ("Known Packages" "Known Packages x64") do (
  reg query "%LBASE%\%%~K" /f "PasTreeIdePlugin.bpl" 2>nul | findstr /i /c:".bpl" >nul
  if not errorlevel 1 set "LSTILL=1"
)
if defined LSTILL (
  if defined LFOUND (
    echo.
    echo   Key Mappings records kept: the other IDE of RAD Studio %BDSVER% still has
    echo   the package registered, and the two IDEs share them.
  )
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\prune-key-mappings.ps1"
  if errorlevel 2 (
    set "LFOUND=1"
  ) else if errorlevel 1 (
    echo.
    echo WARNING: the Key Mappings records could not be cleaned - see above.
    set "LFOUND=1"
  )
)

if not defined LFOUND (
  echo   nothing was registered with the %LWHICH% of RAD Studio %BDSVER% - nothing
  echo   to do
  exit /b 0
)

echo.
echo Unregistered. The %LWHICH% of RAD Studio %BDSVER% will start without the
echo plugin from now on. The built files in out\ are untouched: install.bat
echo puts it back.
exit /b 0

rem ---------------------------------------------------------------------------
rem Unregister from one IDE: %1 is win32 or win64.
rem
rem Every location that can be registered, not just the current one:
rem out\<version>\<platform>\ is where this repository builds today,
rem out\<version>\ and out\ are where it built before, out\ide\<platform>\ is
rem what the IDE's own Install command registers after a build inside the IDE,
rem and the IDE's shared Bpl directory is where it built before the .dproj
rem named an output path. An uninstall that knew only the current one would
rem leave the older entry to fail at every startup forever - which is the exact
rem thing this script exists to prevent. %BDSCOMMONDIR% is checked but not
rem trusted alone; see the note in install.bat about the stale system-wide
rem value that shadows it.
:unregister
set "LPLAT=%~1"
if /i "%LPLAT%"=="win64" (
  set "LKEY=%LBASE%\Known Packages x64"
  set "LDISABLED=%LBASE%\Disabled Packages x64"
  set "LMSPLAT=Win64"
  set "LIDE=64-bit IDE"
  set "LSHARED=Bpl\Win64"
) else (
  set "LKEY=%LBASE%\Known Packages"
  set "LDISABLED=%LBASE%\Disabled Packages"
  set "LMSPLAT=Win32"
  set "LIDE=32-bit IDE"
  set "LSHARED=Bpl"
)

echo.
echo === unregistering from RAD Studio %BDSVER%, %LIDE% ===

call :drop "%CD%\out\%BDSVER%\%LPLAT%\PasTreeIdePlugin.bpl"
if /i "%LPLAT%"=="win32" call :drop "%CD%\out\%BDSVER%\PasTreeIdePlugin.bpl"
call :drop "%CD%\out\PasTreeIdePlugin.bpl"
call :drop "%CD%\out\ide\%LMSPLAT%\PasTreeIdePlugin.bpl"
call :drop "%LPUB%\%LSHARED%\PasTreeIdePlugin.bpl"
if defined BDSCOMMONDIR call :drop "%BDSCOMMONDIR%\%LSHARED%\PasTreeIdePlugin.bpl"

rem The same sweep install.bat ends with, and it matters more here: the whole
rem point of this script is that nothing is left to fail at startup, so a
rem registration in a location neither script can name must at least be named
rem to the person running it. Reported, not deleted - a name match is not proof
rem the value is ours.
rem out\ rather than %TEMP% - see the note in install.bat.
reg query "%LKEY%" /f "PasTreeIdePlugin.bpl" 2>nul | findstr /i /c:".bpl" >"out\stale-packages.txt"
for %%Z in ("out\stale-packages.txt") do if %%~zZ gtr 0 (
  echo.
  echo WARNING: registrations of this package are still present:
  type "out\stale-packages.txt"
  echo Remove them under %LKEY% by hand.
  set "LFOUND=1"
)
del /q "out\stale-packages.txt" 2>nul
exit /b 0

rem Remove one path from Known Packages and from the disabled list - an entry
rem there for a path nothing registers any more is clutter at best, and at
rem worst silently disables a later install to the same path. Gotos rather
rem than ( ) blocks: %~1 is a path, and a ")" in it - "Program Files (x86)" -
rem would close a block early.
:drop
reg query "%LKEY%" /v "%~1" >nul 2>&1
if errorlevel 1 goto :dropdisabled
reg delete "%LKEY%" /v "%~1" /f >nul
echo   removed: %~1
set "LFOUND=1"
:dropdisabled
reg query "%LDISABLED%" /v "%~1" >nul 2>&1
if errorlevel 1 exit /b 0
reg delete "%LDISABLED%" /v "%~1" /f >nul
echo   removed from the disabled list: %~1
set "LFOUND=1"
exit /b 0
