unit PasTreeIdePlugin.FormModules;

{
  WHICH IDE MODULE HOLDS A FILE, and whether a FORM FILE (.dfm/.fmx) is held
  by a loaded form designer - the questions Rename (PasTreeIdePlugin.Rename)
  asks before it touches a file, and a Find References / Rename row asks
  before it jumps to a form file's line (PasTreeIdePlugin.ResultRows). Moved
  here from Rename in 0.58.0 so the two ask them the same way.

  Every function here only FINDS - none opens a module. A module this unit
  answers nil for is one the IDE does not have, and Rename's disk path stands
  on that (see its CollectFiles).
}

interface

uses
  ToolsAPI, DesignIntf;

/// Is APath the same file as BPath? Compared as PATHS, not as strings - see
/// the implementation for the bug this is the fix for.
function SameFile(const APath, BPath: string): Boolean;

/// The ALREADY-OPEN module for APath, spelling-tolerantly; never opens one.
function ModuleOf(const APath: string): IOTAModule;

/// A form file: .dfm or .fmx.
function IsFormFile(const APath: string): Boolean;

/// The loaded module that owns form file AFormPath, or nil.
function FormOwnerModule(const AFormPath: string): IOTAModule;

/// AModule's form editor, or nil (no form, or AModule nil).
function FormEditorOf(const AModule: IOTAModule): IOTAFormEditor;

/// AModule's form designer, or nil.
function DesignerOf(const AModule: IOTAModule): IDesigner;

/// <summary>
/// A result row's jump to line ARow, column ACol of form file AFormPath.
/// Its form LOADED: the form designer is shown (the IDE cannot show a loaded
/// form as text - see the implementation). NOT loaded: the file opened as
/// text, the caret at the site. False, and nothing done, for
/// a file that is not a form file, or when the IDE would not open it - then
/// the IDE's own jump is left to happen.
/// </summary>
function ShowFormFileSite(const AFormPath: string; ARow, ACol: Integer): Boolean;

implementation

uses
  System.SysUtils, System.IOUtils,
  PasTreeIdePlugin.GotoDeclaration;   // MoveCaretCentred

{ THIS IS LOAD-BEARING, and the way it is written is the fix for the ugliest
  bug of the 2026-08-31 live runs. Every path in a rename plan comes from
  PasTree, which spells the drive letter in lower case (`c:\Repos\...`); the
  IDE spells its own as the user opened them (`C:\Repos\...`). Comparing those
  as strings makes an OPEN file look closed - and a file that looks closed is
  rewritten on disk, under a buffer that still holds the old text. The IDE
  then asks what to do about the file having changed underneath it, for every
  file, which is exactly what "it keeps asking me to save things" was. }
function SameFile(const APath, BPath: string): Boolean;
begin
  Result := False;
  if (APath = '') or (BPath = '') then
    Exit;
  try
    Result := SameText(TPath.GetFullPath(APath), TPath.GetFullPath(BPath));
  except
    // A path the RTL cannot expand (a stale entry, a bad drive) is not equal
    // to anything rather than an exception in the middle of a rename.
    Result := SameText(APath, BPath);
  end;
end;

{ FindModule FIRST, then the module list by hand: FindModule matches on the
  name it is given, and "the same file, spelled differently" is a case it
  answers nil to (see SameFile). Getting that wrong used to silently turn an
  open file into a disk write, and it still would: a file this misses is
  held for the disk, under a buffer that still reads the old text, and the
  IDE then asks what to do about the file having changed underneath it. }
function ModuleOf(const APath: string): IOTAModule;
var
  LModuleServices: IOTAModuleServices;
  LIdx: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  Result := LModuleServices.FindModule(APath);
  if Assigned(Result) then
    Exit;
  for LIdx := 0 to LModuleServices.ModuleCount - 1 do
    if SameFile(LModuleServices.Modules[LIdx].FileName, APath) then
      Exit(LModuleServices.Modules[LIdx]);
  Result := nil;
end;

function IsFormFile(const APath: string): Boolean;
begin
  Result := SameText(ExtractFileExt(APath), '.dfm') or
    SameText(ExtractFileExt(APath), '.fmx');
end;

{ A form file is never a module of its own - its unit's module holds it - so
  both names are asked: FindModule may answer for the form file's name, and
  the module list certainly knows the unit's. }
function FormOwnerModule(const AFormPath: string): IOTAModule;
begin
  Result := ModuleOf(AFormPath);
  if not Assigned(Result) then
    Result := ModuleOf(ChangeFileExt(AFormPath, '.pas'));
end;

function FormEditorOf(const AModule: IOTAModule): IOTAFormEditor;
var
  LIdx: Integer;
begin
  Result := nil;
  if not Assigned(AModule) then
    Exit;
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTAFormEditor, Result) then
      Exit;
  Result := nil;
end;

function DesignerOf(const AModule: IOTAModule): IDesigner;
var
  LNta: INTAFormEditor;
begin
  Result := nil;
  if Supports(FormEditorOf(AModule), INTAFormEditor, LNta) then
    Result := LNta.FormDesigner;
end;

// The SOURCE editor the IDE holds form file AFormPath in, as text - or nil.
function FormTextEditor(const AFormPath: string): IOTASourceEditor;
var
  LModule: IOTAModule;
  LIdx: Integer;
begin
  Result := nil;
  LModule := FormOwnerModule(AFormPath);
  if not Assigned(LModule) then
    Exit;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor, Result) and
       SameFile(Result.FileName, AFormPath) then
      Exit;
  Result := nil;
end;

{ Its own routine ON PURPOSE (the spike's CaretTo): `EditViews[0]` makes a
  hidden temporary interface that Delphi releases at the end of the ROUTINE,
  and a view still referenced when the IDE destroys it is the
  dangling-reference AV coreide gives. }
procedure CaretTo(const ASrc: IOTASourceEditor; ARow, ACol: Integer);
var
  LView: IOTAEditView;
begin
  if ASrc.EditViewCount = 0 then
    Exit;
  LView := ASrc.EditViews[0];
  MoveCaretCentred(LView, ARow, ACol);
  LView := nil;
end;

{ BOTH KINDS GO THROUGH IOTAActionServices.OpenFile, which does the right
  thing for each - measured in the spike runs (local/DFM-PLAN.md): on a
  LOADED form's form file it shows the designer (run 5, O) and makes no text
  view of the file, so a row's jump cannot put a text copy of the form beside
  its live designer; on a form that is NOT loaded it opens the file as a text
  source module (B2). The IDE's own jump does neither: on a form that is not
  loaded it opens the form in its designer (Alex, 2026-09-28 - the row he
  expected as text came up as the form), and on a loaded one it was never
  measured. The file name of a loaded form is the form editor's own, the
  IDE's spelling of it (see SameFile).

  Selecting the row's component in the designer was tried - IOTAComponent
  .Select(False) right after OpenFile - and selected nothing (Alex,
  2026-09-28); not needed, so not pursued. A loaded form cannot be shown as
  TEXT beside its designer: the designer writes its live components over
  the file on every save, and "View as Text" is refused for a form with
  open descendants or linked modules (spike run 2). }
function ShowFormFileSite(const AFormPath: string; ARow, ACol: Integer): Boolean;
var
  LFE: IOTAFormEditor;
  LActions: IOTAActionServices;
  LSrc: IOTASourceEditor;
begin
  Result := False;
  if not IsFormFile(AFormPath) or
     not Supports(BorlandIDEServices, IOTAActionServices, LActions) then
    Exit;
  LFE := FormEditorOf(FormOwnerModule(AFormPath));
  if Assigned(LFE) then
    Exit(LActions.OpenFile(LFE.FileName));
  if not LActions.OpenFile(AFormPath) then
    Exit;
  Result := True;
  LSrc := FormTextEditor(AFormPath);
  if Assigned(LSrc) then
    CaretTo(LSrc, ARow, ACol);   // none: opened as a form after all
end;

end.
