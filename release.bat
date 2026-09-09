@echo off
rem Pack a release archive: one zip a user unpacks and runs, containing the
rem sources of BOTH halves and nothing built.
rem
rem Usage:  release.bat [version] [--yes]   (RAD Studio version, as elsewhere)
rem
rem WHY SOURCES AND NOT A BUILT SERVER. Shipping pastree-server.exe would mean
rem shipping an unsigned binary: GitHub neither virus-scans release assets nor
rem signs them, so the user meets SmartScreen and their own antivirus with
rem nothing to answer them. Shipping sources removes the question instead of
rem answering it - and the IDE package HAS to be built locally anyway, since a
rem designtime BPL only loads in the compiler version that produced it.
rem
rem WHY THE TWO DIRECTORIES SIT SIDE BY SIDE. Because that is the layout this
rem repository already builds in: ..\object-pascal-tree next to pastree-lsp.
rem The archive is therefore not a second arrangement that only ever runs on
rem someone else's machine - build.bat there is the build.bat tested here, with
rem no path that exists only in a release.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem BOTH WORKING TREES MUST BE CLEAN, and this is the one check worth failing
rem the release over. The archive is exported with git archive, which packs
rem committed content - so an uncommitted change is built and tested here and
rem then silently absent from what users get. That divergence is invisible on
rem both sides: the build passes, the archive unpacks, and the two are not the
rem same product.
call :clean "." "pastree-lsp"
if errorlevel 1 exit /b 1
call :clean "..\object-pascal-tree" "PasTree"
if errorlevel 1 exit /b 1

for /f "tokens=2 delims='" %%V in ('findstr /b /c:"  PasTreeLspVersion = " source\PasLsp.ProductVersion.pas') do set "LVER=%%V"
if not defined LVER (
  echo Could not read PasTreeLspVersion from source\PasLsp.ProductVersion.pas
  exit /b 1
)

rem BUILT AND EXERCISED BEFORE PACKING, never after. A release that was never
rem run is a release whose harnesses might have failed, and the archive gives
rem no second chance to notice.
call "%~dp0build.bat" %*
if errorlevel 1 (
  echo.
  echo Nothing was packed: the build or the harnesses failed.
  exit /b 1
)

set "LNAME=pastree-lsp-%LVER%"
set "LSTAGE=out\release\%LNAME%"
echo.
echo === packing %LNAME% ===
if exist "out\release" rd /s /q "out\release"
mkdir "%LSTAGE%" 2>nul

call :export "." "%LSTAGE%\pastree-lsp"
if errorlevel 1 exit /b 1
call :export "..\object-pascal-tree" "%LSTAGE%\object-pascal-tree"
if errorlevel 1 exit /b 1

rem The shim at the archive root. Its only job is to be the obvious thing to
rem double-click, so the two source directories below read as sources rather
rem than as a choice the user has to make. It MUST forward the exit code:
rem install.bat always builds, and a shim that swallowed a failed build would
rem report a successful install of nothing.
> "%LSTAGE%\install.bat" echo @echo off
>>"%LSTAGE%\install.bat" echo rem Installs the PasTree LSP plugin into RAD Studio. The real installer is
>>"%LSTAGE%\install.bat" echo rem pastree-lsp\install.bat; this only forwards to it, exit code included.
>>"%LSTAGE%\install.bat" echo call "%%~dp0pastree-lsp\install.bat" %%*
>>"%LSTAGE%\install.bat" echo exit /b %%errorlevel%%

> "%LSTAGE%\README.txt" echo PasTree LSP for RAD Studio %LVER%
>>"%LSTAGE%\README.txt" echo.
>>"%LSTAGE%\README.txt" echo Requires Delphi 12 or newer, with the Win64 target installed, and git on
>>"%LSTAGE%\README.txt" echo PATH is not needed - everything is in this archive.
>>"%LSTAGE%\README.txt" echo.
>>"%LSTAGE%\README.txt" echo To install: close RAD Studio, then run install.bat in this directory.
>>"%LSTAGE%\README.txt" echo It builds both halves from source and registers the IDE package. RAD
>>"%LSTAGE%\README.txt" echo Studio must be closed: it holds the package file while running, and it
>>"%LSTAGE%\README.txt" echo rewrites its own package list when it exits.
>>"%LSTAGE%\README.txt" echo.
>>"%LSTAGE%\README.txt" echo To remove it again: run pastree-lsp\uninstall.bat.
>>"%LSTAGE%\README.txt" echo.
>>"%LSTAGE%\README.txt" echo Keep the two directories side by side as unpacked - the build looks for
>>"%LSTAGE%\README.txt" echo object-pascal-tree next to pastree-lsp.
>>"%LSTAGE%\README.txt" echo.
>>"%LSTAGE%\README.txt" echo Nothing here is prebuilt: no binary is shipped, so there is none to trust.
>>"%LSTAGE%\README.txt" echo Full documentation is in pastree-lsp\README.md.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'out\release\%LNAME%' -DestinationPath 'out\release\%LNAME%.zip' -Force"
if errorlevel 1 exit /b 1

echo.
for %%Z in ("out\release\%LNAME%.zip") do echo   %%~fZ  ^(%%~zZ bytes^)
echo.
echo Packed. Unpack it somewhere empty and run install.bat to check it as a
echo user would - that is the only run in which the archive layout is tested.
exit /b 0

rem ---------------------------------------------------------------------------
rem Refuse a release built from anything the last commit does not contain.
rem
rem UNTRACKED FILES COUNT, and the first draft of this check let them pass on
rem the reasoning that an unexported file cannot contradict what was built.
rem That reasoning is exactly backwards for a NEW file: install.bat itself was
rem untracked while this was written, so the check would have waved through an
rem archive with no installer in it - built, tested and shipped incomplete,
rem with every step reporting success. Ignored paths (out\, local\) are not
rem untracked as far as git status is concerned, so they cost nothing here.
:clean
set "LDIRT="
for /f "delims=" %%S in ('git -C "%~1" status --porcelain 2^>nul') do set "LDIRT=1"
if not defined LDIRT exit /b 0
echo.
echo %~2 has changes the last commit does not contain, so a release cannot be
echo packed from it: the archive is exported from that commit, and would not
echo be what this build just compiled and tested.
echo.
git -C "%~1" status --short
exit /b 1

rem Export committed content only. tar is Windows' own since 1803; the pipe
rem would need a shell, so the tarball goes through a file.
rem
rem THE TARBALL GOES IN out\, NOT %TEMP%. Run from Git Bash, %TEMP% holds a
rem POSIX path like /c/Users/... , which git's -o and tar's -f each interpret
rem differently from cmd - a difference that shows up as a release script that
rem works in one shell and not the other, for no visible reason. out\ is ours,
rem it is ignored, and it means the same thing from every shell.
rem THE TARBALL PATH IS ABSOLUTE, and that is not tidiness: `git -C <dir>`
rem changes git's working directory, so a relative -o resolves inside the
rem repository being exported rather than inside this one. The first export
rem here passes "." and so appeared to work; the second wrote into PasTree's
rem tree and failed with git's own message swallowed by the pipeline.
rem
rem tar IS CALLED BY FULL PATH for the same reason `find` is avoided in
rem scripts\ide.bat: run from Git Bash, its PATH comes first, and `tar` is then
rem GNU tar, which reads an absolute Windows path as a REMOTE HOST because of
rem the colon - "Cannot execute remote shell". Windows ships its own tar
rem (bsdtar) in System32 and that one takes C:\... as a path. Same script, same
rem behaviour, whichever shell started it.
:export
mkdir "%~2" 2>nul
git -C "%~1" archive --format=tar -o "%CD%\out\release\export.tar" HEAD
if errorlevel 1 exit /b 1
"%SystemRoot%\System32\tar.exe" -xf "%CD%\out\release\export.tar" -C "%~2"
if errorlevel 1 exit /b 1
del /q "%CD%\out\release\export.tar"
for %%D in ("%~2") do echo   exported %%~nxD
exit /b 0
