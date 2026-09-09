@echo off
rem Build the product and register the IDE package with RAD Studio.
rem
rem Usage:  install.bat [version] [--yes]
rem   version  which RAD Studio, e.g. 37.0. Asked for only when more than one
rem            suitable installation exists.
rem   --yes    never ask; take the newest suitable one.
rem
rem IT ALWAYS BUILDS, and calls build.bat rather than reimplementing it. A
rem register-only mode would be a way to point the IDE at a stale BPL - which
rem is the failure this product already spends a version-equality check on -
rem so the cheap convenience is not worth the way back in.
rem
rem WHAT "INSTALLING" IS HERE: one registry value under the IDE's Known
rem Packages, naming out\PasTreeIdePlugin.bpl by full path. Nothing is copied
rem anywhere. The server exe is built into that same out\, and the plugin
rem finds its server beside its own BPL, so the matched pair is a consequence
rem of where the build wrote them rather than of a deployment step that can be
rem half-done.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem WHICH RAD STUDIO - first, before the build. It decides two things at once
rem (which compiler builds the BPL, which IDE gets it registered) and those
rem must not be allowed to differ: see scripts\ide.bat.
rem Called by FULL path, not by bare name: Git Bash sets
rem NoDefaultCurrentDirectoryInExePath, so a cmd started from it does not look
rem in the current directory for a command, and a bare "build.bat" fails with
rem "not recognized" in a repository that plainly contains one.
call "%~dp0scripts\ide.bat" %*
if errorlevel 1 exit /b 1

rem THE TARGET IDE MUST BE CLOSED, and this is checked rather than asked for.
rem Two separate reasons, either one enough: a loaded designtime package holds
rem its .bpl so the build cannot replace it, AND RAD Studio writes its package
rem list back out when it exits - so a registration made while it runs is
rem discarded on close, leaving an install that reported success and did
rem nothing.
rem
rem ONLY THE VERSION BEING INSTALLED INTO COUNTS. Both of those reasons are
rem per-version now that the BPL lives in out\<version>\ and the registration
rem is under that version's own key: a running Delphi 12 holds out\23.0\ and
rem rewrites 23.0's package list, and has no opinion about 37.0. Refusing on
rem any bds.exe at all - which is what this did first, written before the
rem split - makes installing for one IDE impossible while another is merely
rem open, for no reason the message could honestly give.
rem
rem Matched by the process's own path against %BDSROOT%, which is passed
rem through the environment rather than quoted into the command line: the path
rem contains both spaces and parentheses, and "Program Files (x86)" inside a
rem batch for/if block is a parsing accident waiting to happen. A process whose
rem path cannot be read (an elevated IDE, say) is counted too - unknown is not
rem the same as absent, and the safe reading of "cannot tell" is to stop.
call "%~dp0scripts\ide-closed.bat"
if errorlevel 1 exit /b 1

call "%~dp0build.bat" %BDSVER% --yes
if errorlevel 1 (
  echo.
  echo Nothing was registered: the build failed, and registering a package
  echo that did not build would point the IDE at whatever was there before.
  exit /b 1
)

rem rsvars is what knows the IDE's shared directories - BDSCOMMONDIR is where
rem a package built with no explicit output path used to land, and that is
rem exactly the copy this install has to clear away.
call "%BDSROOT%\bin\rsvars.bat" >nul

rem PER RAD STUDIO VERSION, so installing into a second IDE does not overwrite
rem the first one's package: a designtime BPL loads only in the compiler that
rem produced it, and both registrations name a full path. The server exe is
rem shared and stays one level up - see FindServerExe.
set "LBPL=%CD%\out\%BDSVER%\PasTreeIdePlugin.bpl"
set "LKEY=HKCU\Software\Embarcadero\BDS\%BDSVER%\Known Packages"

echo.
echo === registering with RAD Studio %BDSVER% ===

rem THE OLD COPIES GO FIRST. Before the .dproj named an output directory this
rem package built into the IDE's shared Bpl directory, and that registration
rem would still be there - pointing at a BPL that no longer gets rebuilt. Two
rem entries for one package means the IDE loads the stale one and every fix
rem appears not to work, with nothing in any log to say why.
rem
rem BOTH CANDIDATES ARE TRIED, and %BDSCOMMONDIR% is NOT trusted on its own: it
rem is an ordinary environment variable, and on the machine this was written on
rem a system-wide one left over from RAD Studio 5.0 shadows what rsvars sets,
rem so it names a directory this product has never written to. The documented
rem default under %PUBLIC% is where the BPL actually landed there.
call :drop "%PUBLIC%\Documents\Embarcadero\Studio\%BDSVER%\Bpl\PasTreeIdePlugin.bpl"
if defined BDSCOMMONDIR call :drop "%BDSCOMMONDIR%\Bpl\PasTreeIdePlugin.bpl"
rem out\ itself was the location before the BPL moved into a per-version
rem subdirectory, and it is still where a build started from inside the IDE
rem lands (the .dproj cannot know which version is running it). Either way it
rem is not the file this registers, so it must not stay registered.
call :drop "%CD%\out\PasTreeIdePlugin.bpl"

rem The same wording as the {$DESCRIPTION} in PasTreeIdePlugin.dpk. The IDE's
rem Install Packages list shows the one compiled into the .bpl rather than this
rem one, so the two are not interchangeable - which is exactly why they should
rem not disagree when something does show this one.
reg add "%LKEY%" /v "%LBPL%" /t REG_SZ /d "PasTree LSP - Object Pascal code intelligence" /f >nul
if errorlevel 1 (
  echo.
  echo Could not write to the registry: %LKEY%
  exit /b 1
)
echo   registered: %LBPL%

echo.
echo Installed. Start RAD Studio %BDSVER% - the package is loaded at startup,
echo so this takes effect on the next launch and not before.
echo.
echo   plugin:  %LBPL%
echo   server:  %CD%\out\pastree-server.exe
echo.
echo Both were produced by this one build and check each other's version when
echo they connect. Rebuilding with build.bat replaces them in place; there is
echo no need to run this again unless the package was unregistered.

rem A LAST SWEEP, because the cleanup above can only remove paths it can name,
rem and a registration this package left in some other location years ago would
rem still load in front of the one just made. Reported rather than deleted: a
rem value matched by name only is not certainly ours, and the cost of guessing
rem wrong is someone else's plugin disappearing. reg's own output is echoed as
rem it stands, so whatever is listed can be removed by hand.
rem The scratch file lives in out\, not %TEMP%: run from Git Bash the latter is
rem a POSIX path (/c/Users/...) that cmd's redirection does not resolve.
echo.
if not exist out mkdir out
reg query "%LKEY%" /f "PasTreeIdePlugin.bpl" 2>nul | findstr /i /c:".bpl" | findstr /i /v /c:"%LBPL%" >"out\stale-packages.txt"
for %%Z in ("out\stale-packages.txt") do if %%~zZ gtr 0 (
  echo WARNING: other registrations of this package are still present:
  type "out\stale-packages.txt"
  echo Remove them under %LKEY%, or the IDE may load one of those instead.
)
del /q "out\stale-packages.txt" 2>nul
exit /b 0

rem ---------------------------------------------------------------------------
rem Remove one registration by exact path, and the file it named. Exact means
rem no parsing of reg's output, whose value names are full paths that can
rem contain spaces - the parse is the part that would quietly get it wrong.
:drop
if /i "%~1"=="%LBPL%" exit /b 0
reg query "%LKEY%" /v "%~1" >nul 2>&1
if not errorlevel 1 (
  echo   removing previous registration: %~1
  reg delete "%LKEY%" /v "%~1" /f >nul
)
if exist "%~1" (
  echo   deleting stale package: %~1
  del /q "%~1"
)
for %%F in ("%~1") do if exist "%%~dpF..\Dcp\PasTreeIdePlugin.dcp" del /q "%%~dpF..\Dcp\PasTreeIdePlugin.dcp"
exit /b 0
