@echo off
rem Build pastree-server.exe. WIN64 ONLY -- same rule as every PasTree tool:
rem a real project's closure needs more than a 32-bit address space.
rem Requires the PasTree repo checked out as a sibling: ..\object-pascal-tree
call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
cd /d "%~dp0"
if not exist out mkdir out
if not exist out\dcu mkdir out\dcu
dcc64 -B -Q ^
 -U"%BDS%\lib\win64\release" ^
 -U"..\object-pascal-tree\source" ^
 -I"..\object-pascal-tree\source" ^
 -Usource ^
 -N0out\dcu -Eout pastree-server.dpr
