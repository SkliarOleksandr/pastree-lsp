@echo off
rem Succeed only if the RAD Studio named by %BDSROOT% is NOT running. Exit code
rem 1, with an explanation, if it is - or if that cannot be determined.
rem
rem Shared by install.bat and uninstall.bat rather than written twice: they
rem refuse for the same two reasons and would otherwise drift apart, and the
rem reasoning below is the part worth having in one place.
rem
rem WHY EITHER SCRIPT CARES. A loaded designtime package holds its own .bpl, so
rem a build cannot replace it. And RAD Studio writes its package list back out
rem when it exits, so a registry change made while it runs is discarded on
rem close - an install that reported success and did nothing, which is worse
rem than one that failed.
rem
rem WHY ONLY THIS VERSION. Both reasons are per-version: the BPL lives in
rem out\<version>\ and the registration is under that version's own key, so a
rem running Delphi 12 holds out\23.0\ and rewrites 23.0's list while having no
rem opinion about 37.0. An earlier version of this check refused on any bds.exe
rem at all - written before the per-version split - which made installing for
rem one IDE impossible while another was merely open.
rem
rem WHY POWERSHELL, AND WHY IN ITS OWN FILE. tasklist gives no executable path,
rem and the path is the only thing that says which version a bds.exe is. The
rem first version of this ran the query inline - powershell -Command with a
rem Where-Object block inside a cmd for/f - and cmd's parser ate the $_ on the
rem way through: it answered "no IDE running" with an IDE plainly open, exit
rem code 0, no error anywhere. A guard that fails open silently is worse than
rem no guard at all. scripts\ide-running.ps1 is called with -File, so no
rem expression passes through cmd's parser, and it answers by exit code so
rem there is no number left to misparse either.
setlocal

if not defined BDSROOT (
  echo scripts\ide-closed.bat: BDSROOT is not set - call scripts\ide.bat first.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ide-running.ps1"
rem Descending, because `if errorlevel N` means "N or greater".
if errorlevel 2 goto :running
if errorlevel 1 (
  echo.
  echo Could not determine whether RAD Studio is running, so nothing was
  echo changed. Close it and run this again.
  exit /b 1
)
exit /b 0

:running

echo.
echo RAD Studio %BDSVER% is running. Close it and run this again.
echo.
echo   %BDSROOT%
echo.
echo   Both halves of this need it closed: the running IDE holds the .bpl that
echo   has to be rebuilt, and it rewrites its own package list when it exits,
echo   which would silently undo the registry change made here.
echo.
echo   Only this version matters - another RAD Studio may stay open.
exit /b 1
