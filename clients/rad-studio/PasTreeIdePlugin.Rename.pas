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

  NOTHING IS EVER WRITTEN TO DISK. Every file the plan touches is OPENED in
  the editor and changed through its buffer, which is the whole point: a
  buffer edit is an IDE undo step and a disk write is not. The user keeps
  Ctrl+Z over a rename, sees every change before deciding to keep it, and can
  close the lot without saving to reject it - which is the only "undo" a
  fourteen-site rename across five files can honestly offer.

  The price is paid up front and is not hidden: a rename with a dozen
  references opens a dozen tabs, and every one of them is a MODIFIED buffer,
  so the IDE asks about each at the next close. That was tried and withdrawn
  once for exactly those reasons (2026-08-31), and is now chosen for a reason
  that outranks them - the alternative was files rewritten under the user
  with no way back. Nothing here should quietly reintroduce a disk path to
  keep the tab count down; the tabs ARE the feature.

  APPLYING IS TWO PASSES OVER THE WHOLE PLAN, NOT PER FILE. Pass one opens
  every touched file and checks that each site still reads the old name; pass
  two writes. A single mismatch aborts everything before anything has been
  written, because a half-applied rename across five files is far worse than
  one that did not happen - and it is a real case, not a theoretical one: the
  plan describes the sources as the server last saw them, and the user may
  have typed since. Opening in pass one and writing in pass two also means an
  aborted rename leaves tabs open but every buffer untouched.

  THE SERVER IS NOT TOLD ANYTHING SPECIAL any more. It used to be told which
  files had been rewritten on disk, because a disk write is invisible to the
  analysis; a buffer edit is not - opening a file makes it a document the
  session syncs, and the edit reaches the server as an ordinary didChange
  like any typing would.

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

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes,
  System.Generics.Collections,
  Vcl.Menus, Vcl.Forms, Vcl.Dialogs, Winapi.Windows,
  System.IOUtils,
  // PasLsp.SourceText is gone with the disk path that needed it: reading a
  // file and writing it back in its own encoding was the whole reason this
  // unit ever touched a file directly. It does not any more.
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.WaitDialog;

const
  cMessageGroupName = 'PasTree Rename';

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

{ The rename's own results tab: the same owner-drawn rows Find References
  uses (PasTreeIdePlugin.ResultRows - Find in Files skeleton, editor syntax
  colors), fed the POST-rename lines, with the NEW name carrying the maroon
  match marker: the server's HiFrom/HiTo (0-based, end-exclusive, into the
  snippet) span exactly it. See PasTreeIdePlugin.FindReferences for why the
  removal below is conditional on the IDE not terminating - it is the same
  group mechanism and the same 2026-08-22 access violation. }
procedure ReportRename(const APlan: TLspRenamePlan; AOpenedCount: Integer);
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
  LTitleHead := Format('PasTree Rename: "%s" -> "%s" - ',
    [APlan.OldName, APlan.NewName]);
  LTitleCount := IntToStr(Length(APlan.Edits));
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(LTitleHead + LTitleCount + ' site(s) changed',
      Length(LTitleHead) + 1, Length(LTitleCount)), LGroup);
  { The one thing about this rename the editor cannot show on its own: tabs
    appeared that the user did not open. Saying so is not an apology for the
    clutter, it is the instruction for undoing the rename - every one of them
    is an unsaved buffer, so Ctrl+Z works in each and closing without saving
    throws the whole change away. A user who does not know they are there
    cannot use either. Said here rather than in a dialog because it is a fact
    about the result, and this tab IS the result. }
  if AOpenedCount > 0 then
    LMessageServices.AddTitleMessage(
      Format('%d file(s) were opened to make this change - nothing was ' +
        'saved, so Ctrl+Z in a tab undoes it and closing without saving ' +
        'discards it.', [AOpenedCount]), LGroup);

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
end;

/// <summary>
{ One touched FILE. ONE KIND, and that is the design: every file a rename
  touches is open in the editor by the time anything is written to it, so
  Editor is never nil past CollectFiles.

  This record used to carry a second kind - a file nobody had open, patched
  on disk with its text and encoding held here. That is gone with the disk
  path itself (see the unit header): a disk write has no undo step, and a
  rename the user cannot take back is the one thing this feature must not
  be. The encoding field went with it, because reading and rewriting a file
  is exactly what no longer happens - the buffer is the IDE's problem now,
  and it is better at it than we were. }
type
  TRenameFile = record
    Path: string;
    Editor: IOTASourceEditor;
  end;

  TRenameFiles = TDictionary<string, TRenameFile>;

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

{ The ALREADY-OPEN module for APath, spelling-tolerantly. Never opens one -
  that is EnsureOpenEditorOf's job, and keeping the two apart is what lets
  CollectFiles log "already open" and "opened for this rename" as the
  different events they are.

  FindModule FIRST, then the module list by hand: FindModule matches on the
  name it is given, and "the same file, spelled differently" is a case it
  answers nil to (see SameFile). Getting that wrong used to silently turn an
  open file into a disk write; today it merely re-opens something already
  open, which the IDE tolerates - but the log would then lie about what
  happened, so the care is still worth its keep. }
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

function OpenEditorOf(const AFileName: string): IOTASourceEditor;
var
  LModule: IOTAModule;
  LIdx: Integer;
begin
  Result := nil;
  LModule := ModuleOf(AFileName);
  if not Assigned(LModule) then
    Exit;
  if not SameText(LModule.FileName, AFileName) then
    // Not always a spelling difference: the IDE answers for a program's
    // .dpr with its PROJECT module, whose own FileName is the .dproj. Both
    // cases are fine and both are worth seeing in the log.
    TraceFmt('  %s: answered by the module %s',
      [ExtractFileName(AFileName), LModule.FileName]);
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor,
      Result) then
      Exit;
  Result := nil;
end;

{ The editor for AFileName, OPENING the file if nobody has it open. AOpened
  says which of the two happened - the caller logs it, and only a file this
  rename opened is one the user did not choose to have on screen.

  OpenModule rather than IOTAActionServices.OpenFile: it hands back the module
  it opened, so the editor comes from the same object instead of a second
  lookup that could answer about something else. Either way the IDE gives the
  file a tab, which is the intent - see the unit header.

  nil, not an exception, when the file cannot be opened at all: the caller
  turns that into a refusal of the WHOLE rename, because a plan that cannot
  reach one of its files must not apply the rest. }
function EnsureOpenEditorOf(const AFileName: string;
  out AOpened: Boolean): IOTASourceEditor;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LIdx: Integer;
begin
  AOpened := False;
  Result := OpenEditorOf(AFileName);
  if Assigned(Result) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  try
    LModule := LModuleServices.OpenModule(AFileName);
  except
    // A file the IDE will not open - gone, locked, or not something it has a
    // module for. Refused by the caller with the file named; an exception
    // escaping here would abort the rename with no explanation instead.
    on E: Exception do
    begin
      TraceFmt('  %s: OpenModule raised %s: %s',
        [ExtractFileName(AFileName), E.ClassName, E.Message]);
      Exit(nil);
    end;
  end;
  if not Assigned(LModule) then
    Exit(nil);
  AOpened := True;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor,
      Result) then
      Exit;
  Result := nil;
end;

{ Every file the plan touches, OPENED. AOpenedCount comes back with how many
  of them this rename had to open, which is what the results tab tells the
  user about afterwards.

  False (with AError set) for any file that cannot be opened, and that
  refuses the WHOLE rename rather than skipping a site - the same
  all-or-nothing rule every other check here follows.

  ALL THE OPENING HAPPENS HERE, before a single edit is written. An abort
  after this point would leave tabs open, but every buffer untouched, which
  is a state the user can simply close; opening as we write would leave a
  half-renamed set of files instead. }
function CollectFiles(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  out AOpenedCount: Integer; out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LKey: string;
  LOpened: Boolean;
begin
  Result := False;
  AError := '';
  AOpenedCount := 0;
  for LEdit in APlan.Edits do
  begin
    LKey := LowerCase(LEdit.FilePath);
    if AFiles.ContainsKey(LKey) then
      Continue;
    LFile := Default(TRenameFile);
    LFile.Path := LEdit.FilePath;
    LFile.Editor := EnsureOpenEditorOf(LEdit.FilePath, {out} LOpened);
    if not Assigned(LFile.Editor) then
    begin
      TraceFmt('  %s: could not be opened - refusing',
        [ExtractFileName(LEdit.FilePath)]);
      AError := Format('%s could not be opened in the editor.'#13#10#13#10 +
        'Nothing was renamed.', [LEdit.FilePath]);
      Exit;
    end;
    if LOpened then
      Inc(AOpenedCount);
    TraceFmt('  %s: %s (modified=%s)',
      [ExtractFileName(LEdit.FilePath),
       IfThen(LOpened, 'opened for this rename', 'already open'),
       BoolToStr(LFile.Editor.Modified, True)]);
    AFiles.Add(LKey, LFile);
  end;
  Result := True;
end;

{ Pass one of two: every site is checked against the live buffer that is about
  to be rewritten - one source now that every file is open, where this used to
  read a closed file's text instead. The plan's coordinates describe what the
  server last saw, and the user may have typed since; a mismatch refuses the
  WHOLE rename, naming the file and line, rather than writing over whatever
  now sits there.

  Per EDIT rather than per rename, deliberately: a peer routine header's own
  parameter is a separate symbol and could, in already-broken code, be spelled
  differently from the one that was clicked. }
function VerifySites(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LView: IOTAEditView;
  LPos: IOTAEditPosition;
  LRow, LCol, LOffset: Integer;
  LFound: string;
begin
  Result := False;
  AError := '';
  for LEdit in APlan.Edits do
  begin
    if not AFiles.TryGetValue(LowerCase(LEdit.FilePath), LFile) then
      Exit;   // CollectFiles succeeded, so this cannot happen
    LFound := '';
    if LFile.Editor.GetEditViewCount = 0 then
    begin
      AError := Format('%s is open but has no view.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    LView := LFile.Editor.GetEditView(0);
    LPos := LView.Buffer.EditPosition;
    if not Assigned(LPos) then
    begin
      AError := Format('%s has no editable buffer.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    // The caret is a side effect of reading; put it back, or a cancelled
    // rename would still have moved the user's cursor.
    LRow := LPos.Row;
    LCol := LPos.Column;
    try
      LPos.Move(LEdit.Row, LEdit.Col);
      LFound := LPos.Read(LEdit.Len);
    finally
      LPos.Move(LRow, LCol);
    end;
    if not SameText(LFound, LEdit.OldText) then
    begin
      AError := Format('%s line %d no longer reads "%s" - the buffer has ' +
        'changed since the last analysis.'#13#10#13#10 +
        'Nothing was renamed. Try again in a moment.',
        [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.OldText]);
      Exit;
    end;
  end;
  Result := True;
end;

{ Pass two, the buffer half: one undoable writer per FILE, so each file's
  rename is one Ctrl+Z.

  Offsets are all resolved before the first write of that file - a writer's
  positions address the ORIGINAL text while CharPosToPos answers about the
  buffer as it is NOW, so converting inside the loop would read a buffer the
  earlier writes had already changed (see ApplyClassComplete, which learned
  that the expensive way). Within the file the edits go ASCENDING, the only
  direction a writer can move. }
procedure WriteBuffer(const AEditor: IOTASourceEditor;
  const APlan: TLspRenamePlan; AFrom, ATo: Integer);
var
  LIdx: Integer;
  LView: IOTAEditView;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LOffsets: TArray<Integer>;
begin
  if AEditor.GetEditViewCount = 0 then
    Exit;
  LView := AEditor.GetEditView(0);
  SetLength(LOffsets, ATo - AFrom + 1);
  for LIdx := AFrom to ATo do
  begin
    LCharPos.Line := APlan.Edits[LIdx].Row;
    LCharPos.CharIndex := APlan.Edits[LIdx].Col - 1;
    LOffsets[LIdx - AFrom] := LView.CharPosToPos(LCharPos);
  end;
  LWriter := LView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := AFrom to ATo do
    begin
      LWriter.CopyTo(LOffsets[LIdx - AFrom]);
      LWriter.DeleteTo(LOffsets[LIdx - AFrom] + APlan.Edits[LIdx].Len);
      // The site's OWN new text: a unit rename writes the full dotted name
      // where the reference was written in full and the bare leaf where a
      // namespace prefix resolved it, on the same line.
      LWriter.Insert(UTF8String(APlan.Edits[LIdx].NewText));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  LView.Paint;
end;

{ Open every touched file, verify EVERYTHING, then write - the two passes the
  unit header describes.

  AOpenedCount comes back with how many files this rename had to open, which
  the caller passes on to the user: those tabs are the undo the feature is
  built around, and a user who does not know they appeared cannot use them. }
function ApplyPlan(const APlan: TLspRenamePlan;
  out AOpenedCount: Integer): Boolean;
var
  LFiles: TRenameFiles;
  LFile: TRenameFile;
  LError: string;
  LIdx, LRun: Integer;
begin
  Result := False;
  AOpenedCount := 0;
  LFiles := TRenameFiles.Create;
  try
    TraceFmt('applying %d edit(s) - opening files', [Length(APlan.Edits)]);
    if not CollectFiles(APlan, LFiles, {out} AOpenedCount, {out} LError) then
    begin
      TellUser(LError, mtError);
      Exit;
    end;
    Trace('verifying every site against the text that will be rewritten');
    if not VerifySites(APlan, LFiles, {out} LError) then
    begin
      Trace('verify FAILED: ' + LError);
      TellUser(LError, mtError);
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
      if LFiles.TryGetValue(LowerCase(APlan.Edits[LIdx].FilePath), LFile) then
      begin
        WriteBuffer(LFile.Editor, APlan, LIdx, LRun);
        TraceFmt('  %s: %d edit(s) written to the buffer',
          [ExtractFileName(LFile.Path), LRun - LIdx + 1]);
      end;
      LIdx := LRun + 1;
    end;
    Result := True;
  finally
    LFiles.Free;
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
      LOpenedCount: Integer;
    begin
      // Before anything else, the GAlive check included: the wait dialog
      // disables input, and every path below (TellUser, ApplyPlan's own
      // dialogs, the report) needs it gone.
      CloseWaitDialog;
      GPlanning := False;
      if not GAlive then
        Exit;
      try
        TraceFmt('plan for %s -> %s: success=%s',
          [AOldName, LNewName, BoolToStr(ASuccess, True)]);
        // The server's own sentence, verbatim - a reserved word, a builtin, a
        // `uses` spelling it has no rule for. See the unit header on why none
        // of these is re-worded here.
        if not ASuccess then
        begin
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
          TellUser('Nothing to rename.', mtInformation);
          Exit;
        end;
        TraceFmt('plan: old=%s new=%s edits=%d',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits)]);
        if not ApplyPlan(APlan, {out} LOpenedCount) then
        begin
          Trace('apply refused - nothing was changed');
          Exit;   // ApplyPlan has already said why, and changed nothing
        end;
        ReportRename(APlan, LOpenedCount);
        LogDiagnostic(Format('rename: %s -> %s, %d site(s)%s',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits),
           IfThen(LOpenedCount > 0,
             Format(', %d file(s) opened', [LOpenedCount]), '')]));
        // The buffers the IDE now holds are ahead of what the server was
        // given, and nothing else here would say so until the user's next
        // navigation happened to sync. Pushed immediately so the analysis
        // describes the renamed code from this moment, not from whenever
        // somebody next clicks something.
        Trace('done - syncing the changed buffers to the server');
        LspSyncDocuments;
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

end.