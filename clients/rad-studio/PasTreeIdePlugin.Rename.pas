unit PasTreeIdePlugin.Rename;

{
  Rename, on Ctrl+Shift+E and in the editor's local menu - the one feature in
  this package that CHANGES the user's code, and the shape it takes is the
  demo's (see PasTreeDemo.Main's RenameActionExecute/ApplyRenameEdits/
  ShowRenameTab), because the ToolsAPI has no refactoring surface to plug
  into: the IDE's own rename is not extensible, so ours is a plain command
  that edits buffers and then SHOWS what it did.

  THE RESULTS TAB IS THE POINT. A rename that silently touched fourteen
  places in five files is indistinguishable from one that touched the wrong
  fourteen. So every applied edit is listed afterwards in a Messages tab
  shaped exactly like Find References (grouped by file, one navigable line
  each) - except the text of each line is the line AS IT NOW READS. The
  server hands those previews over ready-made in pastree/renamePlan; nothing
  here re-reads a buffer to build them.

  SYMBOLS ONLY - a routine, a type, a field, a variable, a parameter. Text
  edits and nothing else.

  A UNIT IS DECLINED, and not for want of a plan: the server produces a
  correct one (the header, every `uses` item, the `in '...'` path, and the
  file name the unit then requires), and a plain LSP client applies all of it
  as one workspace edit. Inside the IDE it does not work. The IDE performs a
  rename of its OWN the moment a unit whose `unit` clause changed is saved or
  closed - through its project manager and SaveAs paths - and it cannot be
  asked to stand still while ours runs. Four live runs on a 3759-unit project
  each ended in a different collision between the two: a file already moved
  under us, a project entry already rewritten, an IDE dialog "Unable to
  rename A to B" over a rename that had already happened. Whatever the right
  approach is, it is not "do it ourselves and hope", so the plugin refuses
  and says where to do it instead. The removed half is kept on the
  feature/unit-rename branch, trace and all.

  A compiler builtin is refused too (there is no declaration to rename), as is
  a `uses` spelling the analysis has no rule for. Those refusals arrive as the
  server's own message and are shown verbatim - this unit invents no
  vocabulary of its own for them.

  THE NAME UNDER THE CARET IS ASKED FOR, NOT READ. prepareRename runs before
  the dialog opens, because a unit's name may be dotted - `Namespace.Foo` is
  ONE name - and the text under the caret is at best one segment of it. A
  dialog pre-filled from the buffer would offer half a name.

  THE NEW NAME IS VALIDATED IN TWO PLACES, AND THAT IS DELIBERATE. Only the
  ANALYSIS knows that `begin` is a reserved word (IsValidRenameName lives in
  PasTree, which this Win32 designtime package must never link - see
  clients/rad-studio/README.md), so the real verdict always comes from the
  server. What happens here is the cheap half: obvious non-identifiers are
  refused without a round trip, so a typo does not cost a request. Never
  extend LooksLikeName into keyword knowledge - a copy of that list
  here would be a second answer able to disagree with the first.

  APPLIED AND SAVED AT ONCE, ACROSS THE GROUP, WITH ONE WAY BACK. The plan
  is the union of every running project server's answer for the position
  (LspRenamePlan). A file the user has open is changed through its edit
  buffer - an ordinary Ctrl+Z step in its tab - and saved through its module;
  a file nobody has open is read, edited in memory and written back in the
  encoding it came in (PasLsp.SourceText), never loaded into the IDE. No tab
  is opened for anything. The results tab then carries ONE button, Revert
  (PasTreeIdePlugin.RenameToolbar): the same applier run backwards over the
  files as they now stand, saved again.

  That is the fourth shape this has had, settled with the user on
  2026-09-11/12, and the other three are worth a line each so they are not
  tried again. Disk writes for closed files (to 0.27) had no way back.
  A tab per file (0.28 to 0.38) had Ctrl+Z but walked a dozen tabs across the
  screen per rename. Loading closed files as INVISIBLE modules (OpenModule
  without Show, 0.39.0 for a day) had no tabs - and saving a form unit's
  module rewrote its untouched .dfm too, while Save(False, False) asked
  about every file instead. A Save button between the rename and the disk
  was tried the same day and dropped as a click that only confirmed what the
  tab already showed; a rename applied to buffers but not yet to disk also
  left the server seeing open files renamed and closed ones not.

  APPLYING IS TWO PASSES OVER THE WHOLE PLAN, NOT PER FILE, IN EITHER
  DIRECTION. Pass one gathers every touched file and checks that each site
  still reads what it should - the old name going forward, the new name
  coming back; pass two writes. A single mismatch aborts everything before
  anything has been written, because a half-applied rename across five files
  is far worse than one that did not happen - and it is a real case, not a
  theoretical one: the plan describes the sources as the server last saw
  them, and the user may have typed since. Revert has two tolerances the
  rename does not: a site already reading the OLD name is skipped (the user
  pressed Ctrl+Z in a file they had open - Revert is how the other files
  follow), and a site whose LINE moved is found again by the line's
  post-rename text if exactly one line reads that way (LocateSite). Anything
  less certain is a refusal that names the file and line, and Revert stays
  live for a second try once the user has looked.

  Sites are addressed as BYTES of the UTF-8 content, because those are the
  offsets an IOTAEditWriter takes; a held disk text is encoded the same way
  so one applier serves both kinds. The conversion from the plan's line and
  character column lives in LineBytes and SiteByteOffset and nowhere else.

  THE SERVER IS TOLD TWICE: the ordinary document sync carries the buffers
  it holds overlays for, and workspace/didChangeWatchedFiles names the files
  written on disk, which no editor event ever reports.

  Within a file the edits are applied ASCENDING through one undoable writer -
  the same rule (and the same reason) as PasTreeIdePlugin.ClassComplete: a
  writer cannot move backwards. Every offset is resolved BEFORE the first
  write, against the untouched buffer, for that unit's other hard-won reason.
  Note that this is where the IDE differs from the demo, which walks each
  file backwards through SynEdit's SelText: a writer's offsets all address
  the original text, so ascending order needs no shifting arithmetic at all.

  EVERY STEP IS TRACED into pastree-lsp.log, always - see Trace. A rename is
  rare and deliberate, and the question after something odd is always "which
  step did that"; answering that by adding logging afterwards cost several
  round trips through a live IDE.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Entry point for both the editor's local menu action and Ctrl+Shift+E.
/// Asks for the new name, plans, applies, reports. Returns immediately -
/// everything after the prompt happens on a later main-thread turn.
/// </summary>
procedure ExecuteRename(const AView: IOTAEditView);

/// <summary>Registers the Ctrl+Shift+E binding.</summary>
procedure InitializeRename;

/// <summary>
/// Removes the binding and the "PasTree Rename" Messages tab. Same shutdown
/// rule as PasTreeIdePlugin.FindReferences' own finalizer - read its comment
/// on RemoveMessageGroup before touching this one.
/// </summary>
procedure FinalizeRename;

/// <summary>
/// Drops the results tab because the project it describes is closing. The
/// binding and the rest of the feature stay - this is only the tab.
///
/// A rename tab outliving its project is worse than a stale search: it says
/// sites were changed, and closing the project without saving is exactly how
/// those changes get discarded. What is then left on screen is a list of
/// edits that no longer exist, with rows that navigate into whatever file
/// takes those lines in the next project opened.
/// </summary>
procedure CloseRenameResults;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes,
  System.Generics.Collections,
  Vcl.Menus, Vcl.Forms, Vcl.Dialogs, Winapi.Windows,
  System.IOUtils,
  // PasLsp.SourceText: reading a closed file and writing it back in its own
  // encoding, for the files the IDE does not have open - see CollectFiles.
  PasLsp.SourceText,
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog, PasTreeIdePlugin.RenameToolbar;

const
  cMessageGroupName = 'PasTree Rename';
  // LocateSite's answer for a site that already reads what the pass would
  // write - nothing to verify, nothing to write. 0 stays "not found".
  cAlreadyDone = -1;

type
  TPasRenameBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure RenameProc(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

  { One touched FILE, of one of two kinds.

    OPEN in the IDE - on screen, or loaded behind a form - and then Module
    and Editor are set: it is edited through its buffer (an undo step in its
    tab) and saved through its module. Or NOT open, OnDisk, and then Text is
    the file as read, edited in memory, and Encoding is what to write it back
    in at Save (a .pas is UTF-8-with-BOM, bare UTF-8 or ANSI, and rewriting
    it as a different one of those moves every non-ASCII column in it).
    Nothing of the disk kind touches the disk before Save.

    The disk kind has been in and out of this record twice; CollectFiles has
    the reasons it is back. }
  TRenameFile = record
    Path: string;
    Module: IOTAModule;
    Editor: IOTASourceEditor;
    OnDisk: Boolean;
    Text: string;
    Encoding: TPasSourceEncoding;
  end;

  TRenameFiles = TDictionary<string, TRenameFile>;

  { Which way a plan is being applied. Forward is the rename: each site reads
    OldText and gets NewText. Backward is Cancel: each site reads NewText -
    at the column the forward pass left it at, see SiteCol - and gets OldText
    back. One applier, two directions, so the revert cannot drift from the
    rename it undoes. }
  TApplyDirection = (adForward, adBackward);

  { The rename that Revert would undo: its plan and its files, as applied
    and saved. Revert exists for the user who presses Ctrl+Z in the one file
    they had open and finds the other fifty-one still renamed (2026-09-11):
    it is the button that finishes what the Ctrl+Z started. Cleared by
    Revert, by the next rename, by a project close, and at unload. }
  TAppliedRename = class
    Plan: TLspRenamePlan;
    Files: TRenameFiles;
    constructor Create(const APlan: TLspRenamePlan; AFiles: TRenameFiles);
    destructor Destroy; override;
  end;

var
  GMessageGroup: IOTAMessageGroup;
  GKeyboardServices: IOTAKeyboardServices;
  GBindingIndex: Integer = -1;
  // Same teardown guard every async feature here carries: a plan can answer
  // while the package is unloading, and by then nothing it touches is safe.
  GAlive: Boolean = False;
  // One rename at a time. Between the request and its answer this feature
  // is holding coordinates for buffers it is about to edit; a second plan
  // started meanwhile would be verified against the text the first one is
  // in the middle of changing. The window is short and the key is easy to
  // press twice, so it is closed rather than reasoned about.
  GPlanning: Boolean = False;
  GApplied: TAppliedRename = nil;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ ONE LINE PER STEP OF A RENAME, into pastree-lsp.log beside the project.

  ALWAYS ON, and that is a decision rather than an oversight. A rename is a
  rare, deliberate act - a dozen lines per invocation is nothing next to what
  an analysis writes - and it is the one command here that CHANGES the user's
  code across several files and the project file. When something about it
  behaves oddly, the question is always "which step did that", and answering
  it by adding logging after the fact costs another round trip through a live
  IDE (it cost several, 2026-08-31). So the trace is part of the feature.

  Into the SERVER'S log rather than the Build tab: the Build tab is where
  the user's own compiler output lives and a step-by-step trace would bury
  it, while the log is already the place this product answers "what actually
  happened" from. Failures still go to the Build tab through LogDiagnostic. }
procedure Trace(const AWhat: string);
begin
  LspLogToServer('rename: ' + AWhat);
end;

{ The same, formatted - saves every caller a Format call. }
procedure TraceFmt(const AFormat: string; const AArgs: array of const);
begin
  Trace(Format(AFormat, AArgs));
end;

/// <summary>
/// A modal message for the user - as opposed to LogDiagnostic, which files
/// something in the Build tab. A rename is a deliberate act, so its refusals
/// are said to the user's face rather than left in a panel they would have
/// to think to open.
/// </summary>
procedure TellUser(const AMessage: string; AKind: TMsgDlgType);
begin
  (BorlandIDEServices as INTAIDEUIServices).MessageDlg(AMessage, AKind,
    [mbOK], -1);
end;

{ The cheap half of the name check - see the unit header on why the other
  half is the server's and must stay there.

  DOTS ARE ALLOWED, because a UNIT name is dotted: `Namespace.Foo` is one
  name, and each segment has to be an identifier. Whether a dotted name is
  legal for what is actually being renamed is NOT decided here - a symbol
  cannot have one, and the analysis says so (IsValidRenameName), which keeps
  this to the one question it can answer without knowing the target. }
function LooksLikeName(const AName: string): Boolean;
const
  cFirst = ['A'..'Z', 'a'..'z', '_'];
  cRest = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
var
  LSegment: string;
  LIdx: Integer;
begin
  Result := False;
  if AName = '' then
    Exit;
  for LSegment in AName.Split(['.']) do
  begin
    if LSegment = '' then
      Exit;   // a leading, trailing or doubled dot
    if not CharInSet(LSegment[1], cFirst) then
      Exit;
    for LIdx := 2 to Length(LSegment) do
      if not CharInSet(LSegment[LIdx], cRest) then
        Exit;
  end;
  Result := True;
end;

function GetOrCreateMessageGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
end;

{ TAppliedRename }

constructor TAppliedRename.Create(const APlan: TLspRenamePlan;
  AFiles: TRenameFiles);
begin
  inherited Create;
  Plan := APlan;
  Files := AFiles;
end;

destructor TAppliedRename.Destroy;
begin
  Files.Free;
  inherited;
end;

procedure RevertApplied; forward;

{ The rename's own results tab: the same owner-drawn rows Find References
  uses (PasTreeIdePlugin.ResultRows - Find in Files skeleton, editor syntax
  colors), fed the POST-rename lines, with the NEW name carrying the maroon
  match marker: the server's HiFrom/HiTo (0-based, end-exclusive, into the
  snippet) span exactly it. See PasTreeIdePlugin.FindReferences for why the
  removal below is conditional on the IDE not terminating - it is the same
  group mechanism and the same 2026-08-22 access violation.

  And, above the rows, the Revert toolbar (PasTreeIdePlugin.RenameToolbar):
  the one way back. }
procedure ReportRename(const APlan: TLspRenamePlan;
  ADiskCount, AFileCount, AFailed: Integer);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LParentRef: Pointer;
  LEdit: TLspRenameEdit;
  LKey, LTitleHead, LTitleCount: string;
  LExisting, LFileCount: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices,
    LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  // Built by concatenation so the count's orange span is known, not
  // searched for - same as the Find References title.
  // HOW FAR ACROSS THE GROUP, when there is a group: the plan is the union
  // of every running project server's answer (LspRenamePlan), and a project
  // whose server was not up contributed nothing - which this line has to
  // say, because the rows below read as complete.
  if APlan.ProjectsInGroup > 1 then
    LTitleHead := Format('PasTree Rename: "%s" -> "%s" in %d of %d project(s) - ',
      [APlan.OldName, APlan.NewName, APlan.ProjectsAnswered,
       APlan.ProjectsInGroup])
  else
    LTitleHead := Format('PasTree Rename: "%s" -> "%s" - ',
      [APlan.OldName, APlan.NewName]);
  LTitleCount := IntToStr(Length(APlan.Edits));
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(LTitleHead + LTitleCount + ' site(s) changed',
      Length(LTitleHead) + 1, Length(LTitleCount)), LGroup);
  { The one thing the rows cannot show: which files were not on screen, and
    that everything is already on disk. Revert above is the way back. }
  LMessageServices.AddTitleMessage(
    Format('%d file(s) changed and saved - %d open in the IDE (Ctrl+Z works ' +
      'there), %d not open (written to disk)%s. Revert puts every site back.',
      [AFileCount, AFileCount - ADiskCount, ADiskCount,
       IfThen(AFailed > 0, Format('; %d could not be saved, see the Build tab',
         [AFailed]), '')]), LGroup);

  LFileCounts := TDictionary<string, Integer>.Create;
  LFileHeaders := TDictionary<string, Pointer>.Create;
  try
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      LFileCounts.TryGetValue(LKey, LExisting);
      LFileCounts.AddOrSetValue(LKey, LExisting + 1);
    end;
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      if not LFileHeaders.TryGetValue(LKey, LParentRef) then
      begin
        LFileCounts.TryGetValue(LKey, LFileCount);
        LParentRef := LMessageServices.AddCustomMessagePtr(
          NewFileHeaderRow(LEdit.FilePath, LFileCount), LGroup);
        LFileHeaders.Add(LKey, LParentRef);
      end;
      // The declaration is labelled rather than shown as its own line: the
      // snippet is worth more than the word "declaration", and losing which
      // row it was is exactly what the demo's pinned first row avoids.
      LMessageServices.AddCustomMessage(
        NewSnippetRow(LEdit.FilePath, LEdit.Row, LEdit.Col,
          TrimRight(LEdit.Snippet), LEdit.HiFrom + 1,
          LEdit.HiTo - LEdit.HiFrom,
          IfThen(LEdit.IsDecl, 'declaration', '')), LParentRef);
    end;
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
  // AFTER ShowMessageView: the tab has to exist before a control can be put
  // in it, and showing the group is what makes the IDE build it.
  ShowRenameToolbar(cMessageGroupName, RevertApplied);
end;

{ One more line under the rows once Revert has run. The toolbar goes grey at
  the same time: there is nothing left to take back. }
procedure ReportOutcome(const AText: string);
var
  LMessageServices: IOTAMessageServices;
begin
  SetRenameToolbarEnabled(False);
  if Assigned(GMessageGroup) and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage(AText, GMessageGroup);
end;

{ Is APath the same file as BPath? Compared as PATHS, not as strings.

  THIS IS LOAD-BEARING, and the way it is written is the fix for the ugliest
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

{ The ALREADY-OPEN module for APath, spelling-tolerantly. Never opens one:
  nil here is what makes a file the disk kind (CollectFiles).

  FindModule FIRST, then the module list by hand: FindModule matches on the
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

function SourceEditorOf(const AModule: IOTAModule): IOTASourceEditor;
var
  LIdx: Integer;
begin
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTASourceEditor,
      Result) then
      Exit;
  Result := nil;
end;

{ Every file the plan touches, told apart into the two kinds - see
  TRenameFile. ADiskCount comes back with how many are of the disk kind,
  which is what the results tab tells the user about afterwards.

  NO OpenModule, and that is a decision with a date. Loading a closed unit as
  a module (0.39.0's first shape) gave it a buffer and no tab, which looked
  ideal - until Save: a form unit's module owns its .dfm, the designer comes
  up with the module, and saving the module rewrote every .dfm untouched, as
  IDE churn in every diff after a rename (user, 2026-09-11). Save(False,
  False) instead asks about every file one by one. So a file the IDE does not
  have is not given to the IDE at all: its text is read here, edited here,
  and written back here at Save, in the encoding it came in.

  False (with AError set) for any file that is neither open nor readable,
  and that refuses the WHOLE rename rather than skipping a site - the same
  all-or-nothing rule every other check here follows. }
function CollectFiles(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  out ADiskCount: Integer; out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LKey: string;
begin
  Result := False;
  AError := '';
  ADiskCount := 0;
  for LEdit in APlan.Edits do
  begin
    LKey := LowerCase(LEdit.FilePath);
    if AFiles.ContainsKey(LKey) then
      Continue;
    LFile := Default(TRenameFile);
    LFile.Path := LEdit.FilePath;
    LFile.Module := ModuleOf(LEdit.FilePath);
    if Assigned(LFile.Module) then
    begin
      if not SameText(LFile.Module.FileName, LEdit.FilePath) then
        // Not always a spelling difference: the IDE answers for a program's
        // .dpr with its PROJECT module, whose own FileName is the .dproj.
        // Both cases are fine and both are worth seeing in the log.
        TraceFmt('  %s: answered by the module %s',
          [ExtractFileName(LEdit.FilePath), LFile.Module.FileName]);
      LFile.Editor := SourceEditorOf(LFile.Module);
    end;
    if Assigned(LFile.Editor) then
      TraceFmt('  %s: open in the IDE (modified=%s, views=%d)',
        [ExtractFileName(LEdit.FilePath),
         BoolToStr(LFile.Editor.Modified, True), LFile.Editor.GetEditViewCount])
    else
    begin
      LFile.Module := nil;
      LFile.OnDisk := True;
      if not TryReadSourceForEdit(LEdit.FilePath, {out} LFile.Text,
        {out} LFile.Encoding) then
      begin
        TraceFmt('  %s: not open and not readable - refusing',
          [ExtractFileName(LEdit.FilePath)]);
        AError := Format('%s is not open in the IDE and could not be ' +
          'read.'#13#10#13#10'Nothing was renamed.', [LEdit.FilePath]);
        Exit;
      end;
      Inc(ADiskCount);
      TraceFmt('  %s: not open - held for the disk (encoding=%d)',
        [ExtractFileName(LEdit.FilePath), Ord(LFile.Encoding)]);
    end;
    AFiles.Add(LKey, LFile);
  end;
  Result := True;
end;

{ ---- Sites in a buffer's bytes -------------------------------------------

  Everything below addresses the buffer as the UTF-8 BYTES IOTAEditorContent
  hands out, because those are the offsets an IOTAEditWriter takes. A plan's
  Row/Col are 1-based line and CHARACTER column; the conversion is a line
  found by counting line breaks and a column turned into bytes by encoding
  that line's prefix. Non-ASCII before a site on the same line (a string
  literal, a comment) is exactly where char and byte columns part ways, and
  encoding the prefix is what keeps them together. A BOM, if the buffer
  holds one, is bytes before line 1 like any other and is skipped by the
  line scan for line 1's text. }

{ The byte range [AStart, AStart + ALen) of line ARow in AText, without its
  line break. False when the buffer has fewer lines. }
function LineBytes(const AText: UTF8String; ARow: Integer;
  out AStart, ALen: Integer): Boolean;
var
  LPos, LLine, LTotal: Integer;
begin
  Result := False;
  LTotal := Length(AText);
  LPos := 1;
  // A UTF-8 BOM before line 1 is not part of the line.
  if (LTotal >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and
     (AText[3] = #$BF) then
    LPos := 4;
  LLine := 1;
  while LLine < ARow do
  begin
    while (LPos <= LTotal) and (AText[LPos] <> #10) do
      Inc(LPos);
    if LPos > LTotal then
      Exit;
    Inc(LPos);   // past the LF
    Inc(LLine);
  end;
  AStart := LPos;
  while (LPos <= LTotal) and (AText[LPos] <> #10) and (AText[LPos] <> #13) do
    Inc(LPos);
  ALen := LPos - AStart;
  Result := True;
end;

{ Line ARow as a string, '' past the end. }
function LineText(const AText: UTF8String; ARow: Integer): string;
var
  LStart, LLen: Integer;
begin
  if LineBytes(AText, ARow, {out} LStart, {out} LLen) then
    Result := UTF8ToString(Copy(AText, LStart, LLen))
  else
    Result := '';
end;

{ The byte offset, 0-based as a writer wants it, of character column ACol
  (1-based) on line ARow. -1 when the line does not exist. }
function SiteByteOffset(const AText: UTF8String; ARow, ACol: Integer): Integer;
var
  LStart, LLen: Integer;
  LLine: string;
begin
  Result := -1;
  if not LineBytes(AText, ARow, {out} LStart, {out} LLen) then
    Exit;
  LLine := UTF8ToString(Copy(AText, LStart, LLen));
  Result := (LStart - 1) + Length(UTF8Encode(Copy(LLine, 1, ACol - 1)));
end;

{ What a site reads before this pass, what it becomes, and where it is.

  The column is the plan's for the forward pass. For the BACKWARD pass it is
  where the forward pass LEFT the site: every earlier edit on the same line
  moved it by the difference between the two names, so the shift is the sum
  of those - the plan is sorted by (file, line, column), so "earlier" is
  "before it in the array with the same file and row". }
function SiteCol(const APlan: TLspRenamePlan; AIdx: Integer;
  ADirection: TApplyDirection): Integer;
var
  LPrev: Integer;
begin
  Result := APlan.Edits[AIdx].Col;
  if ADirection = adForward then
    Exit;
  LPrev := AIdx - 1;
  while (LPrev >= 0) and
        SameText(APlan.Edits[LPrev].FilePath, APlan.Edits[AIdx].FilePath) and
        (APlan.Edits[LPrev].Row = APlan.Edits[AIdx].Row) do
  begin
    Inc(Result, Length(APlan.Edits[LPrev].NewText) -
      Length(APlan.Edits[LPrev].OldText));
    Dec(LPrev);
  end;
end;

function SiteExpected(const AEdit: TLspRenameEdit;
  ADirection: TApplyDirection): string;
begin
  if ADirection = adForward then
    Result := AEdit.OldText
  else
    Result := AEdit.NewText;
end;

function SiteReplacement(const AEdit: TLspRenameEdit;
  ADirection: TApplyDirection): string;
begin
  if ADirection = adForward then
    Result := AEdit.NewText
  else
    Result := AEdit.OldText;
end;

{ A site's actual row, or 0 if it cannot be found.

  The plan's row first. If the expected text is not there, ONE fallback, for
  the backward pass only: the plan carries each line as it reads AFTER the
  rename (Snippet), so a site whose line moved - the user added or removed
  lines above it in a file they had open - is found again if exactly one
  line in the buffer still reads that way. Exactly one: two identical lines
  is a guess, and a revert does not guess. The forward pass has no such
  fallback: its plan is fresh from the analysis, and a mismatch there means
  the analysis and the buffer disagree, which is a reason to stop. }
function LocateSite(const AText: UTF8String; const APlan: TLspRenamePlan;
  AIdx: Integer; ADirection: TApplyDirection; out ACol: Integer): Integer;
var
  LEdit: TLspRenameEdit;
  LLine, LWanted: string;
  LRow, LFound, LCount: Integer;
begin
  LEdit := APlan.Edits[AIdx];
  ACol := SiteCol(APlan, AIdx, ADirection);
  LLine := LineText(AText, LEdit.Row);
  if SameText(Copy(LLine, ACol, Length(SiteExpected(LEdit, ADirection))),
    SiteExpected(LEdit, ADirection)) then
    Exit(LEdit.Row);
  Result := 0;
  if ADirection = adForward then
    Exit;
  // ALREADY REVERTED - the site reads the OLD name where the rename found
  // it: Ctrl+Z in a file the user had open, or a hand edit. Not a mismatch;
  // there is nothing left to do at this site, and the revert must not stop
  // for it (the Ctrl+Z case - see TAppliedRename).
  if SameText(Copy(LLine, SiteCol(APlan, AIdx, adForward),
    Length(LEdit.OldText)), LEdit.OldText) then
    Exit(cAlreadyDone);
  LWanted := TrimRight(LEdit.Snippet);
  if LWanted = '' then
    Exit;
  LFound := 0;
  LCount := 0;
  LRow := 1;
  while True do
  begin
    LLine := LineText(AText, LRow);
    if (LLine = '') and (LRow > 1) and (SiteByteOffset(AText, LRow, 1) < 0) then
      Break;
    if TrimRight(LLine) = LWanted then
    begin
      Inc(LCount);
      LFound := LRow;
    end;
    Inc(LRow);
  end;
  if LCount = 1 then
  begin
    TraceFmt('  %s: line %d moved to %d - found by its text',
      [ExtractFileName(LEdit.FilePath), LEdit.Row, LFound]);
    Result := LFound;
  end
  else
    TraceFmt('  %s: line %d not where it was and its text matches %d line(s)',
      [ExtractFileName(LEdit.FilePath), LEdit.Row, LCount]);
end;

{ The text of every file in AFiles as UTF-8 bytes, read once per pass: the
  live buffer for an open file, the held text for a disk one. UTF8Encode of
  a disk file's text is an internal representation, not the file's encoding:
  a single-byte source came in as identity-mapped characters (see
  PasLsp.SourceText) and goes back the same way after UTF8ToString, so the
  bytes here only have to agree with SiteByteOffset, which they do. }
type
  TBufferTexts = TDictionary<string, UTF8String>;

function ReadBuffers(AFiles: TRenameFiles): TBufferTexts;
var
  LPair: TPair<string, TRenameFile>;
begin
  Result := TBufferTexts.Create;
  for LPair in AFiles do
    if LPair.Value.OnDisk then
      Result.Add(LPair.Key, UTF8Encode(LPair.Value.Text))
    else
      Result.Add(LPair.Key, ReadModuleBufferUtf8(LPair.Value.Module));
end;

{ Pass one of two: every site is checked against the live buffer that is
  about to be rewritten. The plan's coordinates describe what the server
  last saw (forward) or what the rename wrote (backward), and the user may
  have typed since; a mismatch refuses the WHOLE pass, naming the file and
  line, rather than writing over whatever now sits there.

  Per EDIT rather than per rename, deliberately: a peer routine header's own
  parameter is a separate symbol and could, in already-broken code, be
  spelled differently from the one that was clicked.

  ARows comes back with each site's actual row (see LocateSite), so pass two
  writes where pass one looked. }
function VerifySites(const APlan: TLspRenamePlan; ATexts: TBufferTexts;
  ADirection: TApplyDirection; out ARows: TArray<Integer>;
  out AError: string): Boolean;
var
  LIdx, LCol: Integer;
  LText: UTF8String;
  LEdit: TLspRenameEdit;
begin
  Result := False;
  AError := '';
  SetLength(ARows, Length(APlan.Edits));
  for LIdx := 0 to High(APlan.Edits) do
  begin
    LEdit := APlan.Edits[LIdx];
    if not ATexts.TryGetValue(LowerCase(LEdit.FilePath), LText) then
      Exit;   // CollectFiles succeeded, so this cannot happen
    if LText = '' then
    begin
      AError := Format('%s has no editable buffer.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    ARows[LIdx] := LocateSite(LText, APlan, LIdx, ADirection, {out} LCol);
    if ARows[LIdx] = 0 then
    begin
      if ADirection = adForward then
        AError := Format('%s line %d no longer reads "%s" - the buffer has ' +
          'changed since the last analysis.'#13#10#13#10 +
          'Nothing was renamed. Try again in a moment.',
          [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.OldText])
      else
        AError := Format('%s line %d no longer reads "%s" - the file has ' +
          'been edited since the rename.'#13#10#13#10 +
          'Nothing was reverted. Undo the edit there (or put "%s" back by ' +
          'hand) and press Revert again.',
          [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.NewText,
           LEdit.NewText]);
      Exit;
    end;
  end;
  Result := True;
end;

{ Pass two, one FILE. The sites' byte offsets are all resolved first, against
  the bytes pass one verified - a writer's positions address the ORIGINAL
  text, so converting inside the loop would read a buffer the earlier writes
  had already changed (see ApplyClassComplete, which learned that the
  expensive way). Within the file the edits go ASCENDING; the plan is sorted
  so, and a backward pass keeps that order because it shifts columns rather
  than reordering. A site already reading its target (cAlreadyDone) is left
  alone; a file where every site is, is not touched at all.

  An OPEN file goes through one IOTASourceEditor.CreateUndoableWriter, so the
  file's pass is one Ctrl+Z in its tab. A DISK file is spliced in memory and
  the result held in AFiles until Save writes it - nothing reaches the disk
  from here. }
procedure WriteFile(AFiles: TRenameFiles; const AKey: string;
  const AText: UTF8String; const APlan: TLspRenamePlan;
  const ARows: TArray<Integer>; AFrom, ATo: Integer;
  ADirection: TApplyDirection);
var
  LFile: TRenameFile;
  LIdx, LCol, LFrom: Integer;
  LAny: Boolean;
  LWriter: IOTAEditWriter;
  LOffsets: TArray<Integer>;
  LExpected: string;
  LOut: UTF8String;
begin
  if not AFiles.TryGetValue(AKey, LFile) then
    Exit;
  SetLength(LOffsets, ATo - AFrom + 1);
  LAny := False;
  for LIdx := AFrom to ATo do
  begin
    if ARows[LIdx] = cAlreadyDone then
    begin
      LOffsets[LIdx - AFrom] := cAlreadyDone;
      Continue;
    end;
    LAny := True;
    LCol := SiteCol(APlan, LIdx, ADirection);
    LOffsets[LIdx - AFrom] := SiteByteOffset(AText, ARows[LIdx], LCol);
    if LOffsets[LIdx - AFrom] < 0 then
      Exit;   // pass one just found this line; a miss here is a logic error
  end;
  if not LAny then
    Exit;

  if LFile.OnDisk then
  begin
    // The same walk a writer makes - copy up to the site, skip what it
    // read, put the replacement - over a string instead of a buffer.
    LOut := '';
    LFrom := 0;
    for LIdx := AFrom to ATo do
    begin
      if LOffsets[LIdx - AFrom] = cAlreadyDone then
        Continue;
      LExpected := SiteExpected(APlan.Edits[LIdx], ADirection);
      LOut := LOut + Copy(AText, LFrom + 1, LOffsets[LIdx - AFrom] - LFrom) +
        UTF8Encode(SiteReplacement(APlan.Edits[LIdx], ADirection));
      LFrom := LOffsets[LIdx - AFrom] + Length(UTF8Encode(LExpected));
    end;
    LOut := LOut + Copy(AText, LFrom + 1, MaxInt);
    LFile.Text := UTF8ToString(LOut);
    AFiles.AddOrSetValue(AKey, LFile);
    Exit;
  end;

  LWriter := LFile.Editor.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := AFrom to ATo do
    begin
      if LOffsets[LIdx - AFrom] = cAlreadyDone then
        Continue;
      LExpected := SiteExpected(APlan.Edits[LIdx], ADirection);
      LWriter.CopyTo(LOffsets[LIdx - AFrom]);
      LWriter.DeleteTo(LOffsets[LIdx - AFrom] +
        Length(UTF8Encode(LExpected)));
      // The site's OWN new text: a unit rename writes the full dotted name
      // where the reference was written in full and the bare leaf where a
      // namespace prefix resolved it, on the same line.
      LWriter.Insert(UTF8String(SiteReplacement(APlan.Edits[LIdx],
        ADirection)));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  // The document sync re-reads a buffer when its change count moved, and
  // that count is fed by an editor VIEW notifier - which a module loaded
  // behind a form, with no view, never fires. Said explicitly.
  NoteBufferModified(LFile.Path);
  if LFile.Editor.GetEditViewCount > 0 then
    LFile.Editor.GetEditView(0).Paint;
end;

{ Verify EVERYTHING, then write - the two passes the unit header describes,
  in either direction, over files CollectFiles has already gathered. }
function ApplyDirection(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  ADirection: TApplyDirection; out AError: string): Boolean;
var
  LTexts: TBufferTexts;
  LRows: TArray<Integer>;
  LText: UTF8String;
  LKey: string;
  LIdx, LRun: Integer;
begin
  Result := False;
  LTexts := ReadBuffers(AFiles);
  try
    Trace('verifying every site against the text that will be rewritten');
    if not VerifySites(APlan, LTexts, ADirection, {out} LRows, {out} AError) then
    begin
      Trace('verify FAILED: ' + AError);
      Exit;
    end;
    Trace('verified; writing');
    LIdx := 0;
    while LIdx <= High(APlan.Edits) do
    begin
      // The run of edits belonging to one file - the plan is sorted by file.
      LRun := LIdx;
      while (LRun < High(APlan.Edits)) and
            SameText(APlan.Edits[LRun + 1].FilePath,
              APlan.Edits[LIdx].FilePath) do
        Inc(LRun);
      LKey := LowerCase(APlan.Edits[LIdx].FilePath);
      if LTexts.TryGetValue(LKey, LText) then
      begin
        WriteFile(AFiles, LKey, LText, APlan, LRows, LIdx, LRun, ADirection);
        TraceFmt('  %s: %d edit(s) applied',
          [ExtractFileName(APlan.Edits[LIdx].FilePath), LRun - LIdx + 1]);
      end;
      LIdx := LRun + 1;
    end;
    Result := True;
  finally
    LTexts.Free;
  end;
end;

{ Gather every touched file, then the forward pass. On success AFiles is
  handed to the caller (for Save and Cancel); on refusal it is freed here and
  the user has been told why. }
function ApplyPlan(const APlan: TLspRenamePlan; out ADiskCount: Integer;
  out AFiles: TRenameFiles): Boolean;
var
  LError: string;
begin
  Result := False;
  ADiskCount := 0;
  AFiles := TRenameFiles.Create;
  try
    TraceFmt('applying %d edit(s) - gathering files', [Length(APlan.Edits)]);
    if not CollectFiles(APlan, AFiles, {out} ADiskCount, {out} LError) then
    begin
      CloseWaitDialog;
      TellUser(LError, mtError);
      Exit;
    end;
    if not ApplyDirection(APlan, AFiles, adForward, {out} LError) then
    begin
      CloseWaitDialog;
      TellUser(LError, mtError);
      Exit;
    end;
    Result := True;
  finally
    if not Result then
      FreeAndNil(AFiles);
  end;
end;

{ ---- Revert ---------------------------------------------------------------- }

{ The rename that was waiting for Revert is over, one way or the other. }
procedure DropApplied;
begin
  FreeAndNil(GApplied);
end;

{ Every file in AFiles to disk: an open one through its module (Save(False,
  True) - keep the name, no question asked; a module here is one the IDE
  already had, so nothing is closed and its .dfm is the IDE's own affair), a
  disk one through TryWriteSource in the encoding it came in. The disk paths
  come back for the server, which has no other way of hearing about them.
  ASaved and AFailed count; a failure is logged with the file. }
procedure SaveFiles(AFiles: TRenameFiles; out ASaved, AFailed: Integer;
  out ADiskPaths: TArray<string>);
var
  LPair: TPair<string, TRenameFile>;
  LOk: Boolean;
begin
  ASaved := 0;
  AFailed := 0;
  ADiskPaths := nil;
  for LPair in AFiles do
  begin
    UpdateWaitDialogWork(ExtractFileName(LPair.Value.Path));
    if LPair.Value.OnDisk then
    begin
      LOk := TryWriteSource(LPair.Value.Path, LPair.Value.Text,
        LPair.Value.Encoding);
      if LOk then
        ADiskPaths := ADiskPaths + [LPair.Value.Path];
    end
    else
      LOk := Assigned(LPair.Value.Module) and
        LPair.Value.Module.Save(False, True);
    if LOk then
      Inc(ASaved)
    else
    begin
      Inc(AFailed);
      TraceFmt('  %s: could not be saved', [ExtractFileName(LPair.Value.Path)]);
    end;
  end;
end;

{ Revert: every site back to the old name and every file saved again - the
  same applier run backwards, verified first, all or nothing, refused with
  the file and line if a site no longer reads the new name. A site that
  already reads the OLD name is skipped, not refused: that is the user who
  pressed Ctrl+Z in the one file they had open and now wants the other
  fifty-one back too. The plan's files are gathered again as they now stand
  (a file opened since the rename is an open file now), and the server hears
  about the result the same two ways the rename told it. }
procedure RevertApplied;
var
  LFiles: TRenameFiles;
  LError, LOldName: string;
  LReverted, LFileCount, LDiskCount, LSaved, LFailed: Integer;
  LDiskPaths: TArray<string>;
begin
  if not GAlive or not Assigned(GApplied) then
    Exit;
  try
    Trace('Revert pressed');
    ShowWaitDialog('Reverting the rename...');
    LFiles := TRenameFiles.Create;
    if not CollectFiles(GApplied.Plan, LFiles, {out} LDiskCount,
      {out} LError) then
    begin
      LFiles.Free;
      CloseWaitDialog;
      TellUser(LError, mtError);
      Exit;
    end;
    GApplied.Files.Free;
    GApplied.Files := LFiles;
    if not ApplyDirection(GApplied.Plan, LFiles, adBackward, {out} LError) then
    begin
      // Refused: the rename stands, Revert stays live, and the user has been
      // told which line to look at.
      CloseWaitDialog;
      TellUser(LError, mtError);
      Exit;
    end;
    LReverted := Length(GApplied.Plan.Edits);
    LOldName := GApplied.Plan.OldName;
    LFileCount := LFiles.Count;
    SaveFiles(LFiles, {out} LSaved, {out} LFailed, {out} LDiskPaths);
    CloseWaitDialog;
    TraceFmt('reverted %d site(s) in %d file(s); saved %d, %d failed',
      [LReverted, LFileCount, LSaved, LFailed]);
    ReportOutcome(Format('Reverted - %d site(s) in %d file(s) read "%s" ' +
      'again, saved%s.', [LReverted, LFileCount, LOldName,
      IfThen(LFailed > 0, Format(' (%d could not be saved)', [LFailed]), '')]));
    DropApplied;
    LspSyncDocuments;
    LspFilesChangedOnDisk(LDiskPaths);
  except
    on E: Exception do
      LogDiagnostic(Format('Rename Revert: unhandled %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

{ The rename proper, once the analysis has said WHAT is being renamed (see
  ExecuteRename): ask for the new name, plan, apply, report.

  THE RESULTS TAB COMES BEFORE THE FILE RENAME, deliberately. The text edits
  are done by then and the user is entitled to see them whatever happens next;
  on the first live run a failure inside the file half took the tab down with
  it and the rename looked like it had done nothing (2026-08-31). Reporting
  first also means the tab is the record of what was changed even when the
  file half then complains.

  EVERYTHING HERE RUNS INSIDE A CALLBACK, which is why the whole body is
  guarded. ExecuteRename's own try/except only covers issuing the request -
  by the time the answer arrives that frame is long gone, so an exception
  raised here would escape into the IDE's message loop with nothing to catch
  it. That is exactly what happened on the first live run. }
procedure RenameFrom(const AFileName: string; ARow, ACol: Integer;
  const AOldName: string);
var
  LNewName: string;
  LUI: INTAIDEUIServices;
begin
  LNewName := AOldName;
  // The IDE's own prompt, not Vcl.Dialogs.InputQuery: the VCL one knows
  // nothing about IDE theming and came up light inside the dark theme
  // (user, 2026-08-31). INTAIDEUIServices is how the settings dialog gets
  // its colors too, just wholesale rather than per-prompt.
  if not Supports(BorlandIDEServices, INTAIDEUIServices, LUI) then
    Exit;
  if not LUI.InputQuery('Rename', Format('Rename "%s" to:', [AOldName]),
    LNewName) then
    Exit;
  LNewName := Trim(LNewName);
  if LNewName = AOldName then
    Exit;   // not a refusal worth a dialog: the user changed nothing
  if not LooksLikeName(LNewName) then
  begin
    TellUser(Format('"%s" is not a valid name.', [LNewName]), mtWarning);
    Exit;
  end;

  GPlanning := True;
  // No names in the text: the dialog does not grow for it, and two
  // identifiers plus decoration is clipped (user, 2026-08-31).
  ShowWaitDialog('Renaming...');
  LspRenamePlan(AFileName, ARow, ACol, LNewName,
    procedure(ASuccess: Boolean; const APlan: TLspRenamePlan;
      const AError: string)
    var
      LFiles: TRenameFiles;
      LDiskCount, LSaved, LFailed: Integer;
      LDiskPaths: TArray<string>;
    begin
      // The wait dialog STAYS UP through the apply and the save below - it
      // was shown before the request went out and the file names run on
      // its work line - and is closed before every dialog and before the
      // report: it disables input, and a message box over disabled input is
      // a stuck IDE. Hence a CloseWaitDialog ahead of every TellUser here.
      GPlanning := False;
      if not GAlive then
      begin
        CloseWaitDialog;
        Exit;
      end;
      try
        TraceFmt('plan for %s -> %s: success=%s',
          [AOldName, LNewName, BoolToStr(ASuccess, True)]);
        // The server's own sentence, verbatim - a reserved word, a builtin, a
        // `uses` spelling it has no rule for. See the unit header on why none
        // of these is re-worded here.
        if not ASuccess then
        begin
          CloseWaitDialog;
          TellUser(AError, mtWarning);
          Exit;
        end;
        { A UNIT, DECLINED HERE - BEFORE ANYTHING IS WRITTEN. The server plans
          one correctly (the header, every `uses` item, the `in '...'` path and
          the file name the unit then requires), and a plain LSP client applies
          all of that as one workspace edit. Inside the IDE it does not work,
          and the reason is not in this code: the IDE performs a rename of its
          own the moment a unit whose `unit` clause changed is saved or closed,
          through its project manager and SaveAs paths, and those cannot be
          told to stand still while ours runs. Four live runs on a 3759-unit
          project each ended in a different collision between the two - a file
          already moved, a project entry already rewritten, an IDE dialog
          "Unable to rename A to B" over a rename that had already happened.

          The refusal is deliberately at this point rather than earlier: the
          plan is what says whether the target is a unit, and asking is one
          round trip that changes nothing. Nothing has been applied yet, so
          there is nothing to undo. }
        if APlan.IsUnit then
        begin
          Trace('declined: a unit rename is not applied from the IDE');
          CloseWaitDialog;
          TellUser(Format('"%s" is a unit.'#13#10#13#10 +
            'Renaming a unit also renames its file, and the IDE performs a ' +
            'rename of its own whenever a unit''s name changes - the two ' +
            'collide, so this plugin does not do it. Rename the unit through ' +
            'the Project Manager instead; renaming symbols works as usual.',
            [APlan.OldName]), mtInformation);
          Exit;
        end;
        if Length(APlan.Edits) = 0 then
        begin
          CloseWaitDialog;
          TellUser('Nothing to rename.', mtInformation);
          Exit;
        end;
        TraceFmt('plan: old=%s new=%s edits=%d',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits)]);
        // APPLIED AND SAVED, HERE AND NOW - open files through their
        // buffers (an undo step in each tab), closed ones straight to disk -
        // and the tab then shows what was done, with Revert above it. A
        // separate Save step was tried and dropped (user, 2026-09-12): one
        // click that only confirmed what the tab already showed.
        if not ApplyPlan(APlan, {out} LDiskCount, {out} LFiles) then
        begin
          Trace('apply refused - nothing was changed');
          Exit;   // ApplyPlan has already said why, and changed nothing
        end;
        SaveFiles(LFiles, {out} LSaved, {out} LFailed, {out} LDiskPaths);
        CloseWaitDialog;
        DropApplied;
        GApplied := TAppliedRename.Create(APlan, LFiles);
        TraceFmt('applied %d site(s); saved %d file(s), %d failed, %d of them on disk',
          [Length(APlan.Edits), LSaved, LFailed, Length(LDiskPaths)]);
        ReportRename(APlan, LDiskCount, LFiles.Count, LFailed);
        LogDiagnostic(Format('rename: %s -> %s, %d site(s) in %d file(s), ' +
          '%d of them not open in the IDE%s - Revert in the PasTree Rename tab',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits), LFiles.Count,
           LDiskCount, IfThen(LFailed > 0,
             Format(', %d could not be saved', [LFailed]), '')]));
        // Two audiences at the server: the buffers it holds overlays for (the
        // ordinary sync) and the files it reads from disk, which only this
        // notification can tell it about.
        LspSyncDocuments;
        LspFilesChangedOnDisk(LDiskPaths);
      except
        on E: Exception do
          LogDiagnostic(Format('Rename: unhandled %s: %s',
            [E.ClassName, E.Message]));
      end;
    end);
end;


{ THE ANALYSIS IS ASKED WHAT IS UNDER THE CARET BEFORE THE DIALOG OPENS, and
  that is not ceremony. A UNIT's name may be dotted - `Namespace.Foo` is ONE
  name - and the text under the caret is at best one segment of it, so a
  dialog pre-filled from the buffer would offer half a name and rename it to
  something the user did not mean. prepareRename answers with the whole of
  it, and refuses (with a reason) where nothing can be renamed at all, which
  makes it also the earliest point a refusal can be shown. }
procedure ExecuteRename(const AView: IOTAEditView);
var
  LFileName: string;
  LRow, LCol: Integer;
begin
  try
    if not Assigned(AView) or not Assigned(AView.Buffer) then
      Exit;
    // Checked here too, not only at the two entry points: this is the
    // procedure that edits code, and it should be impossible to reach with
    // the feature switched off no matter who calls it.
    if not RenameEnabled then
      Exit;
    if GPlanning then
    begin
      TellUser('A rename is already in progress.', mtInformation);
      Exit;
    end;
    LFileName := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;

    GPlanning := True;
    // Visible progress for the slow half: on a cold big project this
    // prepareRename is what takes the seconds, not the plan.
    ShowWaitDialog('Resolving identifier...');
    LspRenameTarget(LFileName, LRow, LCol,
      procedure(ASuccess: Boolean; const AName, AError: string)
      begin
        CloseWaitDialog;
        GPlanning := False;
        if not GAlive then
          Exit;
        // Guarded for RenameFrom's reason: this body runs long after the
        // frame below returned, so there is nothing else to catch it.
        try
          if not ASuccess then
          begin
            TellUser(AError, mtWarning);
            Exit;
          end;
          if AName = '' then
          begin
            TellUser('No identifier under the cursor.', mtInformation);
            Exit;
          end;
          // The caret may have moved while we were asking, and that is fine:
          // the POSITION we asked about is the one we keep renaming from,
          // and the server still holds the snapshot it answered from.
          RenameFrom(LFileName, LRow, LCol, AName);
        except
          on E: Exception do
            LogDiagnostic(Format('Rename: unhandled %s: %s',
              [E.ClassName, E.Message]));
        end;
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      GPlanning := False;
      LogDiagnostic(Format('Rename: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

{ TPasRenameBinding }

function TPasRenameBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TPasRenameBinding.GetDisplayName: string;
begin
  Result := 'PasTree: rename (Ctrl+Shift+E)';
end;

function TPasRenameBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.RenameBinding';
end;

procedure TPasRenameBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  // Ctrl+Shift+E, not Ctrl+E: the IDE gives Ctrl+E to incremental search,
  // which is used far more often than this is.
  ABindingServices.AddKeyBinding([ShortCut(Ord('E'), [ssCtrl, ssShift])],
    RenameProc, nil);
end;

procedure TPasRenameBinding.RenameProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
begin
  // krHandled once the key is recognised, for the reason the toggle and
  // class completion both state: krUnhandled would hand the keystroke back
  // to the IDE, and a position ours declines would silently get some other
  // behaviour instead.
  { THE OFF SWITCH, and the one line in here that may answer krUnhandled -
    which is exactly what makes "rename off" mean "the key is the IDE's
    again", with no keymap to unbind. Same shape as the decl/impl toggle's,
    and it must stay ahead of the unconditional krHandled below. }
  if not RenameEnabled then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  ExecuteRename(AContext.EditBuffer.TopView);
end;

procedure InitializeRename;
begin
  GAlive := True;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices,
    GKeyboardServices) then
    Exit;
  GBindingIndex := GKeyboardServices.AddKeyboardBinding(
    TPasRenameBinding.Create);
end;

procedure FinalizeRename;
var
  LMessageServices: IOTAMessageServices;
begin
  GAlive := False;
  // The toolbar first: it lives in a control the IDE owns, and the pending
  // rename it acts on is gone with GAlive anyway.
  HideRenameToolbar;
  DropApplied;
  if (GBindingIndex >= 0) and Assigned(GKeyboardServices) then
    GKeyboardServices.RemoveKeyboardBinding(GBindingIndex);
  GBindingIndex := -1;
  GKeyboardServices := nil;
  // NOT AT IDE SHUTDOWN - PasTreeIdePlugin.FindReferences' finalizer carries
  // the full story of the access violation this guard exists for.
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // Deliberately silent: this runs while the package is unloading.
    end;
  GMessageGroup := nil;
end;

{ The same removal for a project close, leaving GAlive and the key binding
  alone - the package lives on and the next rename must work.

  WORSE HERE THAN FOR A SEARCH, which is why it is worth its own note: this
  tab claims sites were CHANGED. Close the project without saving and every
  one of those changes is gone, but the tab still stands, still lists them,
  and its rows still navigate - into whatever file now occupies those lines
  in the next project opened. A record of edits that were undone is not a
  stale result, it is a false one. }
procedure CloseRenameResults;
var
  LMessageServices: IOTAMessageServices;
begin
  // A pending rename in a project that is closing: the IDE asks about each
  // modified module itself, tab or no tab, so nothing is lost silently -
  // but the buttons that referred to those modules must not outlive them.
  HideRenameToolbar;
  DropApplied;
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // Cosmetic cleanup on a path the user did not ask anything of.
    end;
  GMessageGroup := nil;
end;

end.