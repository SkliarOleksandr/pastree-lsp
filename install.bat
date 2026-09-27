@echo off
rem Build the product and register the IDE package with RAD Studio - with each
rem of the version's IDEs: the 32-bit one, and the 64-bit one where the
rem version has it.
rem
rem Usage:  install.bat [version] [win32] [win64] [--yes]
rem   version  which RAD Studio, e.g. 37.0. Asked for only when more than one
rem            suitable installation exists.
rem   win32    only the 32-bit IDE; win64 only the 64-bit one. Neither: every
rem            IDE the version has that the package supports.
rem   --yes    never ask; take the newest suitable one.
rem
rem IT ALWAYS BUILDS, and calls build.bat rather than reimplementing it. A
rem register-only mode would be a way to point the IDE at a stale BPL - which
rem is the failure this product already spends a version-equality check on -
rem so the cheap convenience is not worth the way back in.
rem
rem WHAT "INSTALLING" IS HERE: one registry value per IDE, naming its BPL by
rem full path - under Known Packages for the 32-bit IDE, under Known Packages
rem x64 for the 64-bit one, which reads only that key and loads only a Win64
rem BPL. Nothing is copied anywhere. The server exe is built into out\, two
rem levels above both BPLs, and the plugin finds it there, so the matched pair
rem is a consequence of where the build wrote them rather than of a deployment
rem step that can be half-done.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem WHICH RAD STUDIO, AND WHICH OF ITS IDEs - first, before the build. It
rem decides two things at once (which compiler builds each BPL, which IDE gets
rem it registered) and those must not be allowed to differ: see
rem scripts\ide.bat.
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
rem ONLY THE VERSION BEING INSTALLED INTO COUNTS - both of its IDEs, no other
rem version's. Both reasons are per-version: the BPLs live in out\<version>\
rem and the registrations are under that version's own key, so a running
rem Delphi 12 holds out\23.0\ and rewrites 23.0's package list, and has no
rem opinion about 37.0. Refusing on any bds.exe at all - which is what this did
rem first, written before the split - makes installing for one IDE impossible
rem while another is merely open, for no reason the message could honestly
rem give. See scripts\ide-closed.bat for why the version's other IDE still
rem counts.
rem
rem Matched by the process's own path against %BDSROOT%, which is passed
rem through the environment rather than quoted into the command line: the path
rem contains both spaces and parentheses, and "Program Files (x86)" inside a
rem batch for/if block is a parsing accident waiting to happen. A process whose
rem path cannot be read (an elevated IDE, say) is counted too - unknown is not
rem the same as absent, and the safe reading of "cannot tell" is to stop.
call "%~dp0scripts\ide-closed.bat"
if errorlevel 1 exit /b 1

call "%~dp0build.bat" %BDSVER% %BDSPLATFORMS% --yes
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

set "LBASE=HKCU\Software\Embarcadero\BDS\%BDSVER%"
set "LPUB=%PUBLIC%\Documents\Embarcadero\Studio\%BDSVER%"
if not exist out mkdir out

rem PER RAD STUDIO VERSION AND PER IDE, so installing into a second IDE does
rem not overwrite the first one's package: a designtime BPL loads only in the
rem compiler and the bitness that produced it, and every registration names a
rem full path. The server exe is shared and sits two levels up - see
rem FindServerExe.
for %%P in (%BDSPLATFORMS%) do (
  call :register %%P
  if errorlevel 1 exit /b 1
)

call :oldlayout

echo.
echo Installed. Start RAD Studio %BDSVER% - the package is loaded at startup,
echo so this takes effect on the next launch and not before.
echo.
for %%P in (%BDSPLATFORMS%) do echo   plugin:  %CD%\out\%BDSVER%\%%P\PasTreeIdePlugin.bpl
echo   server:  %CD%\out\pastree-server.exe
echo.
echo All of them were produced by this one build and check each other's version
echo when they connect. Rebuilding with build.bat replaces them in place; there
echo is no need to run this again unless the package was unregistered.
exit /b 0

rem ---------------------------------------------------------------------------
rem Register the package with one IDE: %1 is win32 or win64.
:register
set "LPLAT=%~1"
if /i "%LPLAT%"=="win64" (
  set "LKEY=%LBASE%\Known Packages x64"
  set "LDISABLED=%LBASE%\Disabled Packages x64"
  set "LMSPLAT=Win64"
  set "LIDE=64-bit IDE"
  set "LSHARED=Win64\"
) else (
  set "LKEY=%LBASE%\Known Packages"
  set "LDISABLED=%LBASE%\Disabled Packages"
  set "LMSPLAT=Win32"
  set "LIDE=32-bit IDE"
  set "LSHARED="
)
set "LBPL=%CD%\out\%BDSVER%\%LPLAT%\PasTreeIdePlugin.bpl"

echo.
echo === registering with RAD Studio %BDSVER%, %LIDE% ===

rem THE OLD COPIES GO FIRST. Before the .dproj named an output directory this
rem package built into the IDE's shared Bpl directory (Bpl\Win64\ for Win64),
rem and that registration would still be there - pointing at a BPL that no
rem longer gets rebuilt. Two entries for one package means the IDE loads the
rem stale one and every fix appears not to work, with nothing in any log to
rem say why.
rem
rem BOTH CANDIDATES ARE TRIED, and %BDSCOMMONDIR% is NOT trusted on its own: it
rem is an ordinary environment variable, and on the machine this was written on
rem a system-wide one left over from RAD Studio 5.0 shadows what rsvars sets,
rem so it names a directory this product has never written to. The documented
rem default under %PUBLIC% is where the BPL actually landed there.
rem
rem out\<version>\ itself held the 32-bit IDE's BPL until 0.56.0 split it per
rem IDE; the rest of that layout's files go in :oldlayout, once this is
rem unregistered.
rem
rem One-line ifs, not ( ) blocks: these paths are expanded when a block is
rem read, and a ")" in one - "Program Files (x86)" - would close it early.
call :drop "%LPUB%\Bpl\%LSHARED%PasTreeIdePlugin.bpl" "%LPUB%\Dcp\%LSHARED%PasTreeIdePlugin.dcp"
if defined BDSCOMMONDIR call :drop "%BDSCOMMONDIR%\Bpl\%LSHARED%PasTreeIdePlugin.bpl" "%BDSCOMMONDIR%\Dcp\%LSHARED%PasTreeIdePlugin.dcp"
if /i "%LPLAT%"=="win32" call :drop "%CD%\out\%BDSVER%\PasTreeIdePlugin.bpl" "%CD%\out\%BDSVER%\PasTreeIdePlugin.dcp"
rem out\ was the location before the per-version split, and out\ide\<platform>\
rem is where a build started from inside the IDE lands (the .dproj cannot know
rem which version is running it) - and the IDE's own Install command registers
rem exactly that file. Neither is the file this registers, so neither may stay
rem registered.
call :drop "%CD%\out\PasTreeIdePlugin.bpl" "%CD%\out\PasTreeIdePlugin.dcp"
call :drop "%CD%\out\ide\%LMSPLAT%\PasTreeIdePlugin.bpl" "%CD%\out\ide\%LMSPLAT%\PasTreeIdePlugin.dcp"

rem INSTALLED MEANS ENABLED. Unchecking the package in Component > Install
rem Packages records its path under Disabled Packages, and the IDE honours that
rem over Known Packages - so without this step a reinstall after an uncheck
rem reports success and loads nothing. "Disabled Packages x64" is named by
rem analogy with Known Packages x64 and not yet observed: the 64-bit IDE had
rem disabled nothing on the machine this was written on (2026-09-27).
reg query "%LDISABLED%" /v "%LBPL%" >nul 2>&1
if not errorlevel 1 (
  echo   re-enabling it - it was unchecked in Component ^> Install Packages
  reg delete "%LDISABLED%" /v "%LBPL%" /f >nul
)

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

rem A LAST SWEEP, because the cleanup above can only remove paths it can name,
rem and a registration this package left in some other location years ago would
rem still load in front of the one just made. Reported rather than deleted: a
rem value matched by name only is not certainly ours, and the cost of guessing
rem wrong is someone else's plugin disappearing. reg's own output is echoed as
rem it stands, so whatever is listed can be removed by hand.
rem The scratch file lives in out\, not %TEMP%: run from Git Bash the latter is
rem a POSIX path (/c/Users/...) that cmd's redirection does not resolve.
reg query "%LKEY%" /f "PasTreeIdePlugin.bpl" 2>nul | findstr /i /c:".bpl" | findstr /i /v /c:"%LBPL%" >"out\stale-packages.txt"
for %%Z in ("out\stale-packages.txt") do if %%~zZ gtr 0 (
  echo.
  echo WARNING: other registrations of this package are still present:
  type "out\stale-packages.txt"
  echo Remove them under %LKEY%, or the IDE may load one of those instead.
)
del /q "out\stale-packages.txt" 2>nul
exit /b 0

rem ---------------------------------------------------------------------------
rem Remove one registration by exact path - from Known Packages and from the
rem disabled list - and the file it named, with the .dcp given as %2. Exact
rem means no parsing of reg's output, whose value names are full paths that
rem can contain spaces - the parse is the part that would quietly get it wrong.
rem Gotos rather than ( ) blocks: a ")" in the path - "Program Files (x86)" -
rem would close a block early.
:drop
if /i "%~1"=="%LBPL%" exit /b 0
reg query "%LKEY%" /v "%~1" >nul 2>&1
if errorlevel 1 goto :dropdisabled
echo   removing previous registration: %~1
reg delete "%LKEY%" /v "%~1" /f >nul
:dropdisabled
reg query "%LDISABLED%" /v "%~1" >nul 2>&1
if errorlevel 1 goto :dropfile
echo   removing it from the disabled list: %~1
reg delete "%LDISABLED%" /v "%~1" /f >nul
:dropfile
if not exist "%~1" goto :dropdcp
echo   deleting stale package: %~1
del /q "%~1"
:dropdcp
if not "%~2"=="" if exist "%~2" del /q "%~2"
exit /b 0

rem ---------------------------------------------------------------------------
rem What is left of the layout before 0.56.0 in out\<version>\: the package's
rem .map/.drc/.rsm, and server copies from a build that once wrote the exe
rem there too. The server copies go unconditionally - nothing looks for a
rem server in out\<version>\ any more, and a copy there is precisely what an
rem old package found before the fresh one and "ran the fix that did not
rem work". The package files go only once nothing is registered to that BPL:
rem "install.bat win64" leaves the 32-bit IDE's registration alone, and
rem deleting a file an IDE still loads greets its next start with "Can't load
rem package" - build.bat warns about that registration instead.
:oldlayout
set "LOLD=%CD%\out\%BDSVER%"
set "LGONE="
for %%X in (exe map drc) do if exist "%LOLD%\pastree-server.%%X" (
  del /q "%LOLD%\pastree-server.%%X"
  set "LGONE=1"
)
reg query "%LBASE%\Known Packages" /v "%LOLD%\PasTreeIdePlugin.bpl" >nul 2>&1
if errorlevel 1 (
  for %%X in (bpl dcp map drc rsm) do if exist "%LOLD%\PasTreeIdePlugin.%%X" (
    del /q "%LOLD%\PasTreeIdePlugin.%%X"
    set "LGONE=1"
  )
)
if defined LGONE (
  echo.
  echo   removed the pre-0.56.0 layout's files from %LOLD%\
)
exit /b 0
