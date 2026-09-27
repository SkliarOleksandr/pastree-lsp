@echo off
rem Decide which RAD Studio installation this run targets, and which of its
rem IDEs, and export it as BDSVER (e.g. "37.0"), BDSROOT (that installation's
rem directory) and BDSPLATFORMS - "win32", "win64" or "win32 win64", the IDEs
rem the package is built for and registered with. The caller then invokes
rem "%BDSROOT%\bin\rsvars.bat" itself - rsvars sets PATH, BDS and friends, and
rem those would be lost across this script's endlocal.
rem
rem ONE PLACE, BECAUSE THE ANSWER MUST BE THE SAME FOR BOTH USES. A designtime
rem BPL loads only in the compiler version that produced it. So "which Delphi
rem builds the package" and "which Delphi gets the package registered" are not
rem two questions: a build.bat with 37.0 hardcoded next to an install.bat that
rem picked something else would register a BPL the IDE silently declines to
rem load, and the symptom - a plugin that is installed and simply does nothing -
rem names no cause at all. The same holds for the IDE's bitness: the 64-bit IDE
rem loads only a Win64 BPL, from its own registry key, so which IDEs get a
rem package built and which get one registered is decided here too, once.
rem
rem Usage:  call scripts\ide.bat [version] [win32] [win64] [--yes]
rem   version  an installed one, e.g. 37.0 - skips every question.
rem   win32    only the 32-bit IDE (bin\bds.exe).
rem   win64    only the 64-bit IDE (bin64\bds.exe) - where the version has one.
rem            Neither: every IDE the version has that the package supports.
rem   --yes    never prompt; take the newest suitable version.
rem Arguments may come in any order. PASTREE_IDE_VERSION means the same as the
rem version argument, PASTREE_IDE_PLATFORMS (e.g. "win32") the same as the
rem platform arguments; an argument wins over the variable.
rem
rem THE PROMPT IS THE LAST RESORT, not the normal path: an explicit version
rem answers it, and so does having exactly one suitable installation, which is
rem the common case. It also has to happen HERE, before the caller starts
rem building - a question that surfaces after several minutes of compiling is
rem a question asked at the worst possible moment.
rem
rem THERE IS NO QUESTION ABOUT THE BITNESS AT ALL, for the same reason. Being
rem installed into both IDEs costs nothing - each loads only its own
rem registration - while missing from one is the silent failure again: the
rem plugin simply absent the day someone starts the other IDE. So the default
rem is every IDE the version has, and the win32/win64 arguments only narrow it.
setlocal enabledelayedexpansion

set "LWANT="
set "LYES="
set "LW32="
set "LW64="
set "LBADPLAT="
:args
if "%~1"=="" goto :argsdone
if /i "%~1"=="--yes" (
  set "LYES=1"
) else if /i "%~1"=="win32" (
  set "LW32=1"
) else if /i "%~1"=="win64" (
  set "LW64=1"
) else (
  set "LWANT=%~1"
)
shift
goto :args
:argsdone
if not defined LWANT if defined PASTREE_IDE_VERSION set "LWANT=%PASTREE_IDE_VERSION%"
if not defined LW32 if not defined LW64 if defined PASTREE_IDE_PLATFORMS (
  for %%P in (%PASTREE_IDE_PLATFORMS%) do (
    if /i "%%P"=="win32" (
      set "LW32=1"
    ) else if /i "%%P"=="win64" (
      set "LW64=1"
    ) else (
      set "LBADPLAT=!LBADPLAT! %%P"
    )
  )
)
if defined LBADPLAT (
  echo.
  echo PASTREE_IDE_PLATFORMS names something other than win32 or win64:!LBADPLAT!
  goto :fail
)

rem The floor is a real requirement, not caution: the package targets Delphi 12
rem and newer (see README.md).
rem
rem DELPHI 12 ATHENS IS BDS 23.0 - the registry key is the IDE's own version,
rem which has not matched the product name since "Delphi 10 Seattle" was 17.0:
rem 10.4 Sydney 21.0, 11 Alexandria 22.0, 12 Athens 23.0, 13 Florence 37.0.
rem Written down because the first draft of this file guessed 29.0 for Delphi
rem 12, and the effect was not a crash: it silently withheld an installed,
rem perfectly suitable IDE and called it too old. Change this only against the
rem actual key under HKCU\Software\Embarcadero\BDS on a machine that has the
rem version in question.
set "LMINMAJOR=23"

rem THE 64-BIT IDE HAS ITS OWN FLOOR, and this one IS caution - deliberately.
rem Delphi 12.3 shipped a 64-bit IDE as an optional "initial release" (no
rem Delphi refactorings, no Live Templates, among others), and the package has
rem been run only in 37.0's. It compiles for 23.0's Win64 without a change,
rem but a green build does not cover the half of this product that lives
rem inside the IDE (see CLAUDE.md). Lower this to 23 once someone has run the
rem package in 12.3's 64-bit IDE - install that one with Tools > Manage
rem Features in Delphi 12.
set "LMINMAJOR64=37"

set "LCOUNT=0"
set "LOLD="
for /f "tokens=5 delims=\" %%V in ('reg query "HKCU\Software\Embarcadero\BDS" 2^>nul') do (
  if not "%%V"=="" call :probe "%%V"
)

for /l %%I in (1,1,%LCOUNT%) do set "LLIST=!LLIST! !LVER[%%I]!"

if %LCOUNT%==0 (
  echo.
  echo No suitable RAD Studio installation found.
  if defined LOLD echo Installed but too old:!LOLD!
  echo This package needs Delphi 12 ^(BDS 23.0^) or newer.
  goto :fail
)

rem An explicit version is honoured only if it is one of the suitable ones. The
rem two ways it can fail need different messages, so they get different ones.
if defined LWANT (
  for /l %%I in (1,1,%LCOUNT%) do (
    if "!LVER[%%I]!"=="%LWANT%" set "LPICK=%%I"
  )
  if not defined LPICK (
    echo.
    echo RAD Studio %LWANT% is not available for this build.
    if defined LOLD echo Installed but too old:!LOLD!
    echo Suitable:!LLIST!
    goto :fail
  )
  goto :chosen
)

if %LCOUNT%==1 (
  set "LPICK=1"
  goto :chosen
)

rem The candidates are held newest first (see :probe), so the newest is [1].
if defined LYES (
  set "LPICK=1"
  goto :chosen
)

echo.
echo Which RAD Studio should this target?
set "LKEYS="
for /l %%I in (1,1,%LCOUNT%) do (
  call :describe "!LX64[%%I]!"
  echo   [%%I] !LVER[%%I]!  !LROOT[%%I]!  - !LDESC!
  set "LKEYS=!LKEYS!%%I"
)
if defined LOLD echo   ^(too old for this package, not offered:!LOLD! ^)
choice /c !LKEYS! /n /m "Choose [1-%LCOUNT%]: "
set "LPICK=!errorlevel!"

:chosen
for %%I in (!LPICK!) do (
  set "LVER=!LVER[%%I]!"
  set "LROOT=!LROOT[%%I]!"
  set "LHAS64=!LX64[%%I]!"
)

rem WHICH OF ITS IDEs. Win32 is every suitable version's; Win64 only where the
rem 64-bit IDE is installed and past its floor. Asked for and absent is an
rem error rather than a quiet narrowing: "install into the 64-bit IDE" that
rem registers nothing there would be exactly the silent no-op this file exists
rem to prevent.
if not defined LW32 if not defined LW64 (
  set "LW32=1"
  if "!LHAS64!"=="yes" set "LW64=1"
)
if defined LW64 if not "!LHAS64!"=="yes" (
  echo.
  if "!LHAS64!"=="old" (
    echo The 64-bit IDE of RAD Studio !LVER! is not supported yet: the package has
    echo only been run in the 64-bit IDE of %LMINMAJOR64%.0 and newer. See LMINMAJOR64 in
    echo scripts\ide.bat for why, and what it takes to lower it.
  ) else (
    echo RAD Studio !LVER! has no 64-bit IDE installed. Where the version offers
    echo one ^(Delphi 12.3 and newer^), it is an optional feature: Tools ^> Manage
    echo Features.
  )
  goto :fail
)
set "LPLATS="
if defined LW32 set "LPLATS=win32"
if defined LW64 (
  if defined LPLATS (
    set "LPLATS=!LPLATS! win64"
    set "LWHICH=32-bit and 64-bit IDE"
  ) else (
    set "LPLATS=win64"
    set "LWHICH=64-bit IDE"
  )
) else (
  set "LWHICH=32-bit IDE"
)

echo Targeting RAD Studio !LVER!, !LWHICH!  ^(!LROOT!^)
endlocal & set "BDSVER=%LVER%" & set "BDSROOT=%LROOT%" & set "BDSPLATFORMS=%LPLATS%"
exit /b 0

:fail
endlocal
exit /b 1

rem ---------------------------------------------------------------------------
rem The menu's description of one candidate's IDEs, from its LX64 state.
:describe
if "%~1"=="yes" (
  set "LDESC=32-bit and 64-bit IDE"
) else if "%~1"=="old" (
  set "LDESC=32-bit IDE (its 64-bit IDE is not supported before %LMINMAJOR64%.0)"
) else (
  set "LDESC=32-bit IDE"
)
exit /b 0

rem ---------------------------------------------------------------------------
rem One candidate version key. A key under BDS is not proof of an installation -
rem an uninstall can leave one behind - so the test that counts is whether
rem rsvars.bat is actually there, which is also the file the caller needs next.
:probe
set "LV=%~1"
rem Parsed without piping through find/findstr ON PURPOSE. This script is run
rem from Git Bash as often as from cmd, and there `find` resolves to the Unix
rem one, which reads the pipe as a path and reports nothing - leaving the
rem script to announce that no RAD Studio is installed on a machine that has
rem two. Matching on the value name instead needs no external tool at all:
rem reg prints "RootDir  REG_SZ  <path>", and every other line of its output
rem has something else in the first token.
set "LR="
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\%LV%" /v RootDir 2^>nul') do (
  if /i "%%A"=="RootDir" set "LR=%%C"
)
if not defined LR exit /b 0
if "!LR:~-1!"=="\" set "LR=!LR:~0,-1!"
if not exist "!LR!\bin\rsvars.bat" exit /b 0

for /f "tokens=1 delims=." %%M in ("%LV%") do set "LMAJOR=%%M"
if !LMAJOR! lss %LMINMAJOR% (
  set "LOLD=!LOLD! %LV%"
  exit /b 0
)

rem THE 64-BIT IDE, by the IDE's own word and then by the file. "App x64" is
rem the value the installer writes beside "App" when the 64-bit IDE is
rem installed, naming its bds.exe - and the file must exist, for the reason
rem rsvars.bat must above. The x64 KEYS ARE NO EVIDENCE AT ALL: Delphi 12.3
rem creates "Known Packages x64" and friends whether or not the 64-bit IDE was
rem installed (checked 2026-09-27 on a 12.3 without it). The value name holds
rem a space, so reg prints "App  x64  REG_SZ  <path>" and the path is the
rem fourth token onward. LX64 is "yes", "old" (installed, below LMINMAJOR64)
rem or empty.
set "LA64="
for /f "tokens=1,2,3,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\%LV%" /v "App x64" 2^>nul') do (
  if /i "%%A"=="App" if /i "%%B"=="x64" set "LA64=%%D"
)
set "LX="
if defined LA64 if exist "!LA64!" (
  if !LMAJOR! lss %LMINMAJOR64% (
    set "LX=old"
  ) else (
    set "LX=yes"
  )
)

rem KEPT NEWEST FIRST, by insertion rather than by enumeration order: reg query
rem lists subkeys as text, so it would put "10.0" ahead of "9.0". Sorting once,
rem here, is what makes the menu, the "Suitable:" line and the --yes pick agree,
rem and it puts the newest IDE - the one meant in the common case - at [1].
set /a LCOUNT+=1
set "LPOS=!LCOUNT!"
:insert
if !LPOS! gtr 1 (
  set /a LPREV=!LPOS!-1
  call set "LPV=%%LVER[!LPREV!]%%"
  for /f "tokens=1 delims=." %%M in ("!LPV!") do set "LPMAJOR=%%M"
  if !LMAJOR! gtr !LPMAJOR! (
    call set "LVER[!LPOS!]=%%LVER[!LPREV!]%%"
    call set "LROOT[!LPOS!]=%%LROOT[!LPREV!]%%"
    call set "LX64[!LPOS!]=%%LX64[!LPREV!]%%"
    set "LPOS=!LPREV!"
    goto :insert
  )
)
set "LVER[!LPOS!]=%LV%"
set "LROOT[!LPOS!]=!LR!"
set "LX64[!LPOS!]=!LX!"
exit /b 0
