@echo off
rem Unregister the IDE package from RAD Studio. Builds nothing and deletes no
rem build output - out\ is left exactly as it was, so running install.bat again
rem is all it takes to come back.
rem
rem Usage:  uninstall.bat [version] [--yes]   (same arguments as install.bat)
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
set "LKEY=HKCU\Software\Embarcadero\BDS\%BDSVER%\Known Packages"

echo.
echo === unregistering from RAD Studio %BDSVER% ===

rem Every location that can be registered, not just the current one: out\ is
rem where this repository builds today, and the IDE's shared Bpl directory is
rem where it built before the .dproj named an output path. An uninstall that
rem knew only the current one would leave the older entry to fail at every
rem startup forever - which is the exact thing this script exists to prevent.
rem %BDSCOMMONDIR% is checked but not trusted alone; see the note in
rem install.bat about the stale system-wide value that shadows it.
set "LFOUND="
call :drop "%CD%\out\%BDSVER%\PasTreeIdePlugin.bpl"
call :drop "%CD%\out\PasTreeIdePlugin.bpl"
call :drop "%PUBLIC%\Documents\Embarcadero\Studio\%BDSVER%\Bpl\PasTreeIdePlugin.bpl"
if defined BDSCOMMONDIR call :drop "%BDSCOMMONDIR%\Bpl\PasTreeIdePlugin.bpl"

rem The same sweep install.bat ends with, and it matters more here: the whole
rem point of this script is that nothing is left to fail at startup, so a
rem registration in a location neither script can name must at least be named
rem to the person running it. Reported, not deleted - a name match is not proof
rem the value is ours.
rem out\ rather than %TEMP% - see the note in install.bat.
if not exist out mkdir out
reg query "%LKEY%" /f "PasTreeIdePlugin.bpl" 2>nul | findstr /i /c:".bpl" >"out\stale-packages.txt"
for %%Z in ("out\stale-packages.txt") do if %%~zZ gtr 0 (
  echo.
  echo WARNING: registrations of this package are still present:
  type "out\stale-packages.txt"
  echo Remove them under %LKEY% by hand.
  set "LFOUND=1"
)
del /q "out\stale-packages.txt" 2>nul

if not defined LFOUND (
  echo   nothing was registered for this version - nothing to do
  exit /b 0
)

echo.
echo Unregistered. RAD Studio %BDSVER% will start without the plugin from now
echo on. The built files in out\ are untouched: install.bat puts it back.
exit /b 0

:drop
reg query "%LKEY%" /v "%~1" >nul 2>&1
if errorlevel 1 exit /b 0
reg delete "%LKEY%" /v "%~1" /f >nul
echo   removed: %~1
set "LFOUND=1"
exit /b 0
