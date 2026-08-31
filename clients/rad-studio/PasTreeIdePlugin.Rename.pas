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

  TWO THINGS IT RENAMES. A SYMBOL - a routine, a type, a field, a variable, a
  parameter - which is text edits and nothing else. And a UNIT, which is text
  edits AND THE FILE: Object Pascal ties a unit's name to its file name, so
  the second half is not an extra, it is the difference between a rename and
  a project that no longer compiles. RenameUnitFile does it through the
  IDE's own project API, which is also what fixes the one thing the analysis
  plan cannot express - a program's `uses Foo in 'Foo.pas'` path.

  A compiler builtin is refused (there is no declaration to rename), as is a
  `uses` spelling the analysis has no rule for. Both refusals arrive as the
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

  APPLYING IS TWO PASSES OVER THE WHOLE PLAN, NOT PER FILE. Pass one takes
  hold of every touched file - the buffer if it is open, the text on disk if
  it is not - and checks that each site still reads the old name; pass two
  writes. A single mismatch aborts everything before anything has been
  written, because a half-applied rename across five files is far worse than
  one that did not happen - and it is a real case, not a theoretical one: the
  plan describes the sources as the server last saw them, and the user may
  have typed since.

  A FILE NOBODY HAS OPEN IS NOT OPENED. It is rewritten on disk instead. The
  first live run opened one editor tab per touched file - a dozen tabs the
  user never asked for, every one of them a modified buffer, so the IDE then
  asked what to do with each at the next close, which read as "something told
  it to close everything" (2026-08-31). The cost is real and is stated where
  it belongs, in the results tab: those files have no undo step. The server
  is told about them too - a disk write is invisible to the analysis
  otherwise (LspFilesChangedOnDisk).

  Within a file the edits are applied ASCENDING through one undoable writer -
  the same rule (and the same reason) as PasTreeIdePlugin.ClassComplete: a
  writer cannot move backwards. Every offset is resolved BEFORE the first
  write, against the untouched buffer, for that unit's other hard-won reason.
  Note that this is where the IDE differs from the demo, which walks each
  file backwards through SynEdit's SelText: a writer's offsets all address
  the original text, so ascending order needs no shifting arithmetic at all.

  A UNIT RENAME THEN RESTARTS THE ANALYSIS. The server fixes its closure at
  initialize, so a file that has just changed name is not something it can be
  told about - see LspRestartForClosureChange. It is the one edit in the
  product the incremental path cannot absorb, and pretending otherwise would
  have the server answering about a file that no longer exists.
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
  ToolsAPI.UI, PasLsp.SourceText,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.Settings;

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

{ The rename's own results tab: the tree Find References fills, fed the
  POST-rename lines. See PasTreeIdePlugin.FindReferences for why the removal
  below is conditional on the IDE not terminating - it is the same group
  mechanism and the same 2026-08-22 access violation. }
procedure ReportRename(const APlan: TLspRenamePlan;
  const ADiskFiles: TArray<string>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LLineRef, LParentRef: Pointer;
  LEdit: TLspRenameEdit;
  LKey: string;
  LExisting, LFileCount: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices,
    LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  LMessageServices.AddTitleMessage(
    Format('PasTree Rename: "%s" -> "%s" - %d site(s) changed',
      [APlan.OldName, APlan.NewName, Length(APlan.Edits)]), LGroup);
  { The one thing about this rename the editor cannot show: files nobody had
    open were rewritten ON DISK, and those changes have no undo step. Said
    here rather than in a dialog because it is a fact about the result, and
    this tab IS the result. }
  if Length(ADiskFiles) > 0 then
    LMessageServices.AddTitleMessage(
      Format('%d file(s) were not open and were changed on disk - no undo ' +
        'step for those.', [Length(ADiskFiles)]), LGroup);

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
        LMessageServices.AddToolMessage(LEdit.FilePath,
          Format('%s (%d)', [ExtractFileName(LEdit.FilePath), LFileCount]),
          '', 1, 1, nil, LParentRef, LGroup);
        LFileHeaders.Add(LKey, LParentRef);
      end;
      // The declaration is labelled rather than shown as its own line: the
      // snippet is worth more than the word "declaration", and losing which
      // row it was is exactly what the demo's pinned first row avoids.
      LMessageServices.AddToolMessage(LEdit.FilePath,
        Trim(LEdit.Snippet) + IfThen(LEdit.IsDecl, '   [declaration]', ''),
        '', LEdit.Row, LEdit.Col, LParentRef, LLineRef, LGroup);
    end;
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
end;

/// <summary>
{ One touched FILE, and how it is going to be written.

  TWO KINDS, AND THE DISTINCTION IS THE WHOLE REASON THIS RECORD EXISTS. A
  file somebody has open is edited through its buffer, so the change is
  undoable and the editor shows it immediately. A file nobody has open is
  edited ON DISK - and, crucially, is NOT OPENED to do it.

  Opening it would be easier and it is what this did first (2026-08-31): a
  rename of anything with a dozen references buried the user in a dozen new
  editor tabs they never asked for, which is how the first live run reported
  it. Worse than the clutter, every one of those tabs is a MODIFIED buffer -
  so the IDE then asks what to do with each of them at the next close, which
  is the "it wants to save everything" symptom from the same run.

  The cost of the disk half is honest and stated to the user: those files
  have no undo step. Everything else about the rename stays the same, checks
  included - a site is verified against the text that will be rewritten,
  whichever kind it is. }
type
  TRenameFile = record
    Path: string;
    // nil for a file nobody has open - see above.
    Editor: IOTASourceEditor;
    // Only for the disk kind: the text as read, and the encoding to put it
    // back in (a .pas is UTF-8-with-BOM, bare UTF-8 or ANSI, and rewriting
    // it as a different one of those moves every non-ASCII column in it).
    Text: string;
    Encoding: TPasSourceEncoding;
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

{ The editor holding AFileName, or nil if nobody has it open. Deliberately
  never OPENS one - see TRenameFile.

  FindModule FIRST, then the module list by hand: FindModule matches on the
  name it is given, and "the same file, spelled differently" is a case it
  answers nil to (see SameFile). Getting that wrong is not a missed
  optimisation - it silently turns an open file into a disk write. }
{ The open module for APath, spelling-tolerantly - the half of OpenEditorOf
  the file rename needs on its own. }
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

{ The 1-based character offset of (ARow, ACol) in AText, or 0 when the text is
  too short for it.

  Line ends are counted as they are FOUND rather than assumed: a file may hold
  CRLF, LF or a mixture, and a rename that guessed two characters where there
  was one would land its edit somewhere else entirely. }
function OffsetOf(const AText: string; ARow, ACol: Integer): Integer;
var
  LIdx, LRow: Integer;
begin
  Result := 0;
  if (ARow < 1) or (ACol < 1) then
    Exit;
  LIdx := 1;
  LRow := 1;
  while (LRow < ARow) and (LIdx <= Length(AText)) do
  begin
    if AText[LIdx] = #13 then
    begin
      Inc(LRow);
      if (LIdx < Length(AText)) and (AText[LIdx + 1] = #10) then
        Inc(LIdx);
    end
    else if AText[LIdx] = #10 then
      Inc(LRow);
    Inc(LIdx);
  end;
  if LRow <> ARow then
    Exit;
  Result := LIdx + ACol - 1;
end;

{ Every file the plan touches, each one told apart into the two kinds. False
  (with AError set) only for a file that can be neither: not open AND not
  readable, which aborts the whole rename rather than skipping a site. }
function CollectFiles(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LKey: string;
begin
  Result := False;
  AError := '';
  for LEdit in APlan.Edits do
  begin
    LKey := LowerCase(LEdit.FilePath);
    if AFiles.ContainsKey(LKey) then
      Continue;
    LFile := Default(TRenameFile);
    LFile.Path := LEdit.FilePath;
    LFile.Editor := OpenEditorOf(LEdit.FilePath);
    if Assigned(LFile.Editor) then
      TraceFmt('  %s: open in the editor (modified=%s)',
        [ExtractFileName(LEdit.FilePath),
         BoolToStr(LFile.Editor.Modified, True)])
    else
      if not TryReadSourceForEdit(LEdit.FilePath, LFile.Text,
        LFile.Encoding) then
      begin
        TraceFmt('  %s: NOT open and NOT readable - refusing',
          [ExtractFileName(LEdit.FilePath)]);
        AError := Format('%s is not open and could not be read.'#13#10#13#10 +
          'Nothing was renamed.', [LEdit.FilePath]);
        Exit;
      end
      else
        TraceFmt('  %s: not open, will be patched on disk (encoding=%d)',
          [ExtractFileName(LEdit.FilePath), Ord(LFile.Encoding)]);
    AFiles.Add(LKey, LFile);
  end;
  Result := True;
end;

{ Pass one of two: every site is checked against the text that is about to be
  rewritten - the live buffer for an open file, the text just read for a
  closed one. The plan's coordinates describe what the server last saw, and
  the user may have typed since; a mismatch refuses the WHOLE rename, naming
  the file and line, rather than writing over whatever now sits there.

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
    if Assigned(LFile.Editor) then
    begin
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
    end
    else
    begin
      LOffset := OffsetOf(LFile.Text, LEdit.Row, LEdit.Col);
      if LOffset > 0 then
        LFound := Copy(LFile.Text, LOffset, LEdit.Len);
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

{ Pass two, the disk half: the same edits into the text already in hand,
  walked BACKWARDS so an earlier replacement cannot move a later one's offset,
  then written back in the encoding the file came in.

  The opposite direction from the buffer half, and both are right: a writer
  streams forward through the original text, while string surgery mutates what
  the next offset is measured against. }
function WriteDisk(var AFile: TRenameFile; const APlan: TLspRenamePlan;
  AFrom, ATo: Integer): Boolean;
var
  LIdx, LOffset: Integer;
begin
  for LIdx := ATo downto AFrom do
  begin
    LOffset := OffsetOf(AFile.Text, APlan.Edits[LIdx].Row,
      APlan.Edits[LIdx].Col);
    if LOffset <= 0 then
      Exit(False);   // verified above, so this is a bug rather than a race
    Delete(AFile.Text, LOffset, APlan.Edits[LIdx].Len);
    Insert(APlan.Edits[LIdx].NewText, AFile.Text, LOffset);
  end;
  Result := TryWriteSource(AFile.Path, AFile.Text, AFile.Encoding);
end;

{ Open everything that is already open, read the rest, verify EVERYTHING, then
  write - the two passes the unit header describes.

  ADiskFiles comes back holding every file that was changed on disk rather
  than in a buffer: the caller owes those two things the buffer half gets for
  free - telling the server they moved, and telling the USER they have no undo
  step. }
function ApplyPlan(const APlan: TLspRenamePlan;
  out ADiskFiles: TArray<string>): Boolean;
var
  LFiles: TRenameFiles;
  LFile: TRenameFile;
  LError: string;
  LIdx, LRun: Integer;
  LDisk: TList<string>;
begin
  Result := False;
  ADiskFiles := nil;
  LFiles := TRenameFiles.Create;
  LDisk := TList<string>.Create;
  try
    TraceFmt('applying %d edit(s) - collecting files', [Length(APlan.Edits)]);
    if not CollectFiles(APlan, LFiles, {out} LError) then
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
        if Assigned(LFile.Editor) then
        begin
          WriteBuffer(LFile.Editor, APlan, LIdx, LRun);
          TraceFmt('  %s: %d edit(s) written to the buffer',
            [ExtractFileName(LFile.Path), LRun - LIdx + 1]);
        end
        else if WriteDisk(LFile, APlan, LIdx, LRun) then
        begin
          LDisk.Add(LFile.Path);
          TraceFmt('  %s: %d edit(s) written to disk',
            [ExtractFileName(LFile.Path), LRun - LIdx + 1]);
        end
        else
          // One file of several failed to write. Said out loud rather than
          // silently: the rename is now partial, and only the user can decide
          // what to do about it.
          TellUser(Format('%s could not be written - it may be read-only. ' +
            'The rename is INCOMPLETE: everything else was changed.',
            [LFile.Path]), mtError);
      end;
      LIdx := LRun + 1;
    end;
    ADiskFiles := LDisk.ToArray;
    Result := True;
  finally
    LDisk.Free;
    LFiles.Free;
  end;
end;


{ The project the IDE currently considers active - the one a renamed unit
  belongs to. nil during startup, or with no project open, and every caller
  treats that as "do the disk half only". }
function ActiveProject: IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LGroup := LModuleServices.MainProjectGroup;
  if Assigned(LGroup) then
    Result := LGroup.ActiveProject;
end;


{ Every module the plan touched, to disk - the open ones only, since the
  closed ones were written directly.

  BEFORE THE FILE MOVES, and that ordering is the fix for the ugliest symptom
  of the first live run: a unit renamed while its own buffer (and its
  callers' buffers) still held unsaved edits left the IDE asking what to do
  with each of them afterwards, which reads exactly like "something told it to
  close everything". Saving first means there is nothing left to ask about. }
procedure SaveTouchedModules(const APlan: TLspRenamePlan);
var
  LEdit: TLspRenameEdit;
  LSeen: TDictionary<string, Boolean>;
  LEditor: IOTASourceEditor;
  LKey: string;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      if LSeen.ContainsKey(LKey) then
        Continue;
      LSeen.Add(LKey, True);
      LEditor := OpenEditorOf(LEdit.FilePath);
      if Assigned(LEditor) and Assigned(LEditor.Module) then
        try
          TraceFmt('  saving %s (modified=%s)',
            [ExtractFileName(LEdit.FilePath),
             BoolToStr(LEditor.Modified, True)]);
          { FORCED, and not only when the editor reports Modified: the buffer
            we just wrote through a writer is what has to reach disk before
            the file moves, and taking Modified's word for it is what left
            the IDE asking about these files afterwards. ForceSave = True is
            the second parameter (ToolsAPI.pas:3098 - "ForceSave will not
            prompt"). }
          LEditor.Module.Save(False, True);
        except
          on E: Exception do
            // Reported, not raised: the caller is mid-rename and the next
            // steps still have to run or the state gets worse, not better.
            LogDiagnostic(Format('rename: saving %s failed: %s',
              [ExtractFileName(LEdit.FilePath), E.Message]));
        end;
    end;
  finally
    LSeen.Free;
  end;
end;

{ THE PROJECT''S OWN RECORD OF THE FILE, after the file has moved.

  Renaming the file is not the whole job even when the IDE did it on save:
  the project still lists the OLD name, and in a program that entry carries
  the path - `uaviConst in ''uaviConst.pas''`. That literal is the one thing a
  rename plan cannot express (the server reports it as staleInPaths), so if
  nothing rewrites the entry the project stops compiling for a reason no
  diff explains.

  RemoveFile then AddFile is what rewrites it: the IDE drops the stale entry,
  including its path, and writes a fresh one for the file that now exists.
  Both are guarded and both are logged - a duplicated or missing entry is
  exactly the kind of thing that needs to be readable afterwards. }
procedure ReregisterFile(const AProject: IOTAProject;
  const AOldPath, ANewPath: string);
begin
  if not Assigned(AProject) then
    Exit;
  { ASK BEFORE ACTING, in both directions. By the time this runs the IDE has
    usually already fixed its own record - its SaveAs path renames the file
    AND registers the new name, even when IOTAProject100.Rename reported
    False (observed 2026-08-31: Rename returned False, the project already
    held the new name, and the unconditional AddFile below then failed with
    "the project already contains a form or module named uaviConst2" - an
    error about a rename that had entirely succeeded).

    FindModuleInfo is the question to ask: it answers nil for a file the
    project does not list. Two lookups turn this from a sequence of commands
    into a reconciliation, which is what it has to be - anything else here is
    a guess about what the IDE already did. }
  if Assigned(AProject.FindModuleInfo(AOldPath)) then
    try
      Trace('  RemoveFile (the stale entry, with its `in` path)');
      AProject.RemoveFile(AOldPath);
    except
      on E: Exception do
        LogDiagnostic(Format('rename: removing %s from the project failed: %s',
          [ExtractFileName(AOldPath), E.Message]));
    end
  else
    Trace('  the project no longer lists the old name - nothing to remove');

  if Assigned(AProject.FindModuleInfo(ANewPath)) then
  begin
    Trace('  the project already lists the new name - nothing to add');
    Exit;
  end;
  try
    Trace('  AddFile (the new name, with a matching path)');
    AProject.AddFile(ANewPath, True);
  except
    on E: Exception do
      { LOGGED, NOT SHOWN. The refusal this hits in practice is "the project
        already contains a form or module named X" - by UNIT NAME, not by
        path, and the name is already right because the plan renamed it in
        the project source itself (`X in 'X.pas'`, both halves - see the
        server's AugmentUsesInPaths). So the project knows about the file and
        there is nothing for the user to do; a modal error over it is how
        three live runs ended up looking like failures after the rename had
        entirely succeeded. A real problem still leaves its reason in the
        log, next to every other step. }
      LogDiagnostic(Format('rename: adding %s to the project was declined: ' +
        '%s (the project source already names it, so this is expected when ' +
        'the IDE registered it itself)',
        [ExtractFileName(ANewPath), E.Message]));
  end;
end;

{ THE PROJECT FILE, SAVED BY US.

  A unit rename edits the .dproj - a different file name in it - whichever way
  the rename was performed, and the IDE then asks "Save changes to project
  X?" at some later moment of its own choosing. That prompt was reported
  twice (2026-08-31), and it is not a bug in the rename: it is an unsaved
  project file, exactly as if the user had dragged a unit in the project
  manager. Predates the switch to IOTAProject100.Rename, which is the proof
  that the rename mechanism was never the cause.

  So it is saved here, immediately, while the rename is still the thing on
  screen. A project is an IOTAModule, and ForceSave (the second parameter)
  means no prompt - ToolsAPI.pas:3098. }
procedure SaveProject(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;
  try
    Trace('  saving the project file');
    AProject.Save(False, True);
  except
    on E: Exception do
      // Not fatal: the rename is done, and the worst case is the prompt this
      // was meant to avoid.
      LogDiagnostic(Format('rename: saving the project failed: %s',
        [E.Message]));
  end;
end;

{ THE IDE'S OWN RENAME, which is what this should have been doing from the
  start: IOTAProject100.Rename is documented as "renames file using the same
  logic as an inplace rename in the project manager" (ToolsAPI.pas:3809), so
  the IDE moves the file, rewrites its own project entry and fires its own
  BeforeRename/AfterRename notifiers - all the bookkeeping the manual
  sequence below reconstructs by hand, done by the code that owns it.

  Preferred for exactly that reason. The hand-rolled path stays as a fallback
  for a project that does not answer IOTAProject100 (or answers False), which
  is the only case left where reconstructing it is better than nothing.

  False here is not an error yet - the caller falls back - so nothing is said
  to the user from in here. }
function RenameThroughProject(const AProject: IOTAProject;
  const AOldPath, ANewPath: string): Boolean;
var
  LProject100: IOTAProject100;
begin
  Result := False;
  if not Assigned(AProject) then
    Exit;
  if not Supports(AProject, IOTAProject100, LProject100) then
  begin
    Trace('  the project does not answer IOTAProject100');
    Exit;
  end;
  try
    Result := LProject100.Rename(AOldPath, ANewPath);
    TraceFmt('  IOTAProject100.Rename returned %s',
      [BoolToStr(Result, True)]);
  except
    on E: Exception do
    begin
      LogDiagnostic(Format('rename: the IDE''s own project rename of %s ' +
        'raised %s: %s - falling back to renaming it by hand',
        [ExtractFileName(AOldPath), E.ClassName, E.Message]));
      Result := False;
    end;
  end;
end;

{ THE FILE HALF OF A UNIT RENAME, and the only place this package renames
  anything on disk.

  Object Pascal ties a unit's name to its file name, so text edits alone
  produce a project that does not compile - which makes this not an extra but
  the other half of the same action.

  THE IDE DOES IT IF IT WILL: RenameThroughProject above, which is the project
  manager's own rename. Only if that is unavailable does the sequence below
  reconstruct it - RemoveFile, move, AddFile - and the reconstruction exists
  for one reason: something has to rewrite the .dproj entry and, in a program,
  the `uses Foo in ''Foo.pas''` path. That path is exactly what the analysis
  plan CANNOT fix (it has no position for the literal; see the server''s
  UsesInPathSites), so this is not a convenience - it is the reason a unit
  rename can be complete at all.

  A .dfm goes with it. A form unit's resource directive resolves against the
  UNIT name, so a renamed unit whose .dfm kept the old name loses its form -
  and that fails at RUN time, not at build.

  EVERY STEP IS INDIVIDUALLY GUARDED, and that is not defensive habit: an
  exception escaping this ran through an LSP callback into the IDE's message
  loop on the first live run, which is how a rename that had already succeeded
  ended with no results tab and a confused IDE. Each step reports and the rest
  still runs, because a rename stopped halfway is worse than one that finishes
  with a warning.

  ORDER OF THE FALLBACK, and each step is here because the previous one makes
  it possible:
    1. save every touched module      - the edits must be on disk
    2. remove the file from the project - while it still exists, or the IDE
                                         cannot find what to remove
    3. close the module                - Windows will not rename an open file
    4. move .pas (and .dfm if any)     - the rename itself
    5. add the new file to the project - the IDE rewrites .dproj and the
                                         program's uses path here
    6. reopen it in the editor         - the user was looking at it }
function RenameUnitFile(const APlan: TLspRenamePlan): Boolean;
var
  LModuleServices: IOTAModuleServices;
  LActionServices: IOTAActionServices;
  LModule: IOTAModule;
  LProject: IOTAProject;
  LOldDfm, LNewDfm: string;
begin
  Result := False;
  if (APlan.FilePath = '') or (APlan.NewFilePath = '') then
  begin
    TellUser('The rename plan did not say what the file must be called, so ' +
      'the file was left alone. The text edits are applied - rename the ' +
      'file by hand, or undo.', mtError);
    Exit;
  end;
  if TFile.Exists(APlan.NewFilePath) then
  begin
    TellUser(Format('%s already exists. The text edits are applied but the ' +
      'file was NOT renamed - undo, or move that file out of the way first.',
      [APlan.NewFilePath]), mtError);
    Exit;
  end;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) or
     not Supports(BorlandIDEServices, IOTAActionServices, LActionServices)
  then
    Exit;

  TraceFmt('file half: %s -> %s', [APlan.FilePath, APlan.NewFilePath]);
  SaveTouchedModules(APlan);

  { THE IDE MAY HAVE DONE IT ALREADY, and on a real project it does.

    Saving a module whose `unit` clause no longer matches its file name makes
    the IDE take the SaveAs path - it writes the file under the name the unit
    now claims. Since the text edits go in first, that is the ORDINARY case
    for an open unit, not an exotic one: by the time we get here the file has
    moved and the old name is gone. Measured 2026-08-31 on a 3759-unit
    project, where the previous version then failed the whole file half with
    "The specified file was not found" - after the rename had actually
    succeeded.

    So the state is checked rather than assumed. Old gone and new present is a
    SUCCESS, whoever performed it; the only thing left to do is the project
    file, which the IDE marks modified either way. }
  if not TFile.Exists(APlan.FilePath) and TFile.Exists(APlan.NewFilePath) then
  begin
    Trace('  the file had already moved - the IDE renamed it on save');
    ReregisterFile(ActiveProject, APlan.FilePath, APlan.NewFilePath);
    SaveProject(ActiveProject);
    Exit(True);
  end;

  LModule := ModuleOf(APlan.FilePath);
  LProject := ActiveProject;
  TraceFmt('  module found=%s, active project=%s',
    [BoolToStr(Assigned(LModule), True),
     IfThen(Assigned(LProject), 'yes', 'NO')]);

  // The IDE first, by preference - see RenameThroughProject.
  if RenameThroughProject(LProject, APlan.FilePath, APlan.NewFilePath) then
  begin
    Trace('  IOTAProject100.Rename succeeded');
    SaveProject(LProject);
    Exit(True);
  end;
  Trace('  IOTAProject100.Rename unavailable or declined - by hand');

  { BY HAND FROM HERE, and every step is individually guarded for the reason
    the header states. }
  { NO RemoveFile HERE ANY MORE. It used to come first, on the reasoning that
    the project should be told before the file moves - but the IDE gets there
    on its own (closing a module whose unit clause changed takes its SaveAs
    path, which renames the file AND rewrites the project), and removing the
    entry in front of that only made the two disagree. The project is
    reconciled once, at the end, by ReregisterFile. }
  if Assigned(LModule) then
    try
      Trace('  closing the module');
      LModule.Close;
    except
      on E: Exception do
        LogDiagnostic(Format('rename: closing %s failed: %s',
          [ExtractFileName(APlan.FilePath), E.Message]));
    end;

  if not TFile.Exists(APlan.FilePath) and TFile.Exists(APlan.NewFilePath) then
  begin
    // Something in the steps above moved it - the project rename, or a save
    // the close triggered. Nothing to move, and nothing wrong.
    Trace('  the file moved during the earlier steps');
    ReregisterFile(LProject, APlan.FilePath, APlan.NewFilePath);
    SaveProject(LProject);
    Exit(True);
  end;
  try
    Trace('  moving the file');
    TFile.Move(APlan.FilePath, APlan.NewFilePath);
  except
    on E: Exception do
    begin
      TellUser(Format('Could not rename %s to %s: %s'#13#10#13#10 +
        'The text edits are applied - rename the file by hand, or undo.',
        [ExtractFileName(APlan.FilePath),
         ExtractFileName(APlan.NewFilePath), E.Message]), mtError);
      // Put the file back in the project even so: a project missing a unit it
      // still contains is worse than the failed rename.
      if Assigned(LProject) then
        try
          LProject.AddFile(APlan.FilePath, True);
        except
        end;
      Exit;
    end;
  end;
  LOldDfm := TPath.ChangeExtension(APlan.FilePath, '.dfm');
  LNewDfm := TPath.ChangeExtension(APlan.NewFilePath, '.dfm');
  if TFile.Exists(LOldDfm) and not TFile.Exists(LNewDfm) then
    try
      TFile.Move(LOldDfm, LNewDfm);
    except
      on E: Exception do
        TellUser(Format('The unit was renamed, but its form file could not ' +
          'be renamed from %s to %s: %s'#13#10#13#10 +
          'Rename it by hand before running - a unit whose .dfm name does ' +
          'not match it loses its form.',
          [ExtractFileName(LOldDfm), ExtractFileName(LNewDfm), E.Message]),
          mtError);
    end;

  ReregisterFile(LProject, APlan.FilePath, APlan.NewFilePath);
  try
    Trace('  reopening');
    LActionServices.OpenFile(APlan.NewFilePath);
  except
    on E: Exception do
      LogDiagnostic(Format('rename: reopening %s failed: %s',
        [ExtractFileName(APlan.NewFilePath), E.Message]));
  end;
  SaveProject(LProject);
  Result := True;
end;


{ 'unit' or 'symbol' - for the Build tab line, so a reader can tell which of
  the two renames just happened without counting the edits. }
function KindWord(AIsUnit: Boolean): string;
begin
  if AIsUnit then
    Result := 'unit'
  else
    Result := 'symbol';
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
begin
  LNewName := AOldName;
  if not InputQuery('Rename', Format('Rename "%s" to:', [AOldName]),
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
  LspRenamePlan(AFileName, ARow, ACol, LNewName,
    procedure(ASuccess: Boolean; const APlan: TLspRenamePlan;
      const AError: string)
    var
      LDiskFiles: TArray<string>;
    begin
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
        if Length(APlan.Edits) = 0 then
        begin
          TellUser('Nothing to rename.', mtInformation);
          Exit;
        end;
        TraceFmt('plan: kind=%s old=%s new=%s edits=%d file=%s stale=%d',
          [KindWord(APlan.IsUnit), APlan.OldName, APlan.NewName,
           Length(APlan.Edits), APlan.RequiredFileName,
           Length(APlan.StaleInPaths)]);
        if not ApplyPlan(APlan, {out} LDiskFiles) then
        begin
          Trace('apply refused - nothing was changed');
          Exit;   // ApplyPlan has already said why, and changed nothing
        end;
        ReportRename(APlan, LDiskFiles);
        LogDiagnostic(Format('rename: %s %s -> %s, %d site(s)%s%s',
          [KindWord(APlan.IsUnit), APlan.OldName, APlan.NewName,
           Length(APlan.Edits),
           IfThen(Length(LDiskFiles) > 0,
             Format(', %d on disk', [Length(LDiskFiles)]), ''),
           IfThen(APlan.IsUnit, ' + file -> ' + APlan.RequiredFileName, '')]));
        if APlan.IsUnit then
        begin
          TraceFmt('file half returned %s',
            [BoolToStr(RenameUnitFile(APlan), True)]);
          { A renamed FILE is a different analysis closure, and the server
            fixes its closure at initialize - so this is the one edit in the
            product that cannot be absorbed incrementally. Restarting is
            honest and costs the next request one rebuild; keeping the old
            server would have it answer every later question about a file
            that no longer exists. }
          Trace('done - restarting the analysis');
          LspRestartForClosureChange(Format('unit %s was renamed to %s',
            [APlan.OldName, APlan.NewName]));
        end
        else if Length(LDiskFiles) > 0 then
          // A file written on disk is invisible to the analysis until it is
          // told - no editor event ever happens for it. Not needed in the
          // unit case above, which restarts the whole session anyway.
        begin
          TraceFmt('done - telling the server about %d disk file(s)',
            [Length(LDiskFiles)]);
          LspFilesChangedOnDisk(LDiskFiles);
        end;
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
    LspRenameTarget(LFileName, LRow, LCol,
      procedure(ASuccess: Boolean; const AName, AError: string)
      begin
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