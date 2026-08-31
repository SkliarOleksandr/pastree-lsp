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

  APPLYING IS TWO PASSES OVER THE WHOLE PLAN, NOT PER FILE. Pass one opens
  every touched file and checks that each site still reads the old name;
  pass two writes. A single mismatch aborts everything before anything has
  been written, because a half-applied rename across five files is far worse
  than one that did not happen - and it is a real case, not a theoretical
  one: the plan describes the buffers as the server last saw them, and the
  user may have typed since.

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
  ToolsAPI.UI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.Settings;

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
procedure ReportRename(const APlan: TLspRenamePlan);
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
/// Opens AFileName if it is not open already and returns its source editor.
/// nil when the file cannot be opened or is not a source editor - which
/// aborts the whole rename, by design (see the unit header).
/// </summary>
function OpenSourceEditor(const AFileName: string): IOTASourceEditor;
var
  LActionServices: IOTAActionServices;
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LIdx: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LModule := LModuleServices.FindModule(AFileName);
  if not Assigned(LModule) then
  begin
    if not Supports(BorlandIDEServices, IOTAActionServices,
      LActionServices) then
      Exit;
    if not LActionServices.OpenFile(AFileName) then
      Exit;
    LModule := LModuleServices.FindModule(AFileName);
    if not Assigned(LModule) then
      Exit;
  end;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor,
      Result) then
      Exit;
  Result := nil;
end;

{ Pass one of two: every site is checked against the LIVE buffer before
  anything is written. The plan's coordinates describe the text the server
  holds, and the user may have typed since; a mismatch here means the whole
  rename is refused, with the file and line named, rather than applied to
  whatever now sits at those columns.

  Per EDIT rather than per rename, deliberately: a peer routine header's own
  parameter is a separate symbol and could, in already-broken code, be
  spelled differently from the one that was clicked. }
function VerifySites(const AEditors: TDictionary<string, IOTASourceEditor>;
  const APlan: TLspRenamePlan; out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LEditor: IOTASourceEditor;
  LView: IOTAEditView;
  LPos: IOTAEditPosition;
  LRow, LCol: Integer;
begin
  Result := False;
  AError := '';
  for LEdit in APlan.Edits do
  begin
    if not AEditors.TryGetValue(LowerCase(LEdit.FilePath), LEditor) or
       (LEditor.GetEditViewCount = 0) then
    begin
      AError := Format('%s could not be opened.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    LView := LEditor.GetEditView(0);
    LPos := LView.Buffer.EditPosition;
    if not Assigned(LPos) then
    begin
      AError := Format('%s has no editable buffer.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    // The caret is a side effect of reading; put it back where it was, or
    // a cancelled rename would still have moved the user's cursor.
    LRow := LPos.Row;
    LCol := LPos.Column;
    try
      LPos.Move(LEdit.Row, LEdit.Col);
      if not SameText(LPos.Read(LEdit.Len), LEdit.OldText) then
      begin
        AError := Format('%s line %d no longer reads "%s" - the buffer has ' +
          'changed since the last analysis.'#13#10#13#10 +
          'Nothing was renamed. Try again in a moment.',
          [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.OldText]);
        Exit;
      end;
    finally
      LPos.Move(LRow, LCol);
    end;
  end;
  Result := True;
end;

{ Pass two: the writes. One undoable writer per FILE, so each file's rename
  is one Ctrl+Z - the closest this can get to the single undo step the demo
  gets from one editor per file.

  Offsets are all resolved before the first write of that file (a writer's
  positions address the ORIGINAL text, and CharPosToPos answers about the
  buffer as it is now - converting inside the loop would read a buffer the
  earlier writes had already changed; see ApplyClassComplete, which learned
  this the expensive way). }
procedure ApplySites(const AEditors: TDictionary<string, IOTASourceEditor>;
  const APlan: TLspRenamePlan);
var
  LIdx, LRun, LOffIdx: Integer;
  LEditor: IOTASourceEditor;
  LView: IOTAEditView;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LOffsets: TArray<Integer>;
begin
  LIdx := 0;
  while LIdx <= High(APlan.Edits) do
  begin
    // The run of edits belonging to one file - the plan is sorted by file.
    LRun := LIdx;
    while (LRun <= High(APlan.Edits)) and
          SameText(APlan.Edits[LRun].FilePath, APlan.Edits[LIdx].FilePath) do
      Inc(LRun);
    if AEditors.TryGetValue(LowerCase(APlan.Edits[LIdx].FilePath), LEditor) and
       (LEditor.GetEditViewCount > 0) then
    begin
      LView := LEditor.GetEditView(0);
      SetLength(LOffsets, LRun - LIdx);
      for LOffIdx := LIdx to LRun - 1 do
      begin
        LCharPos.Line := APlan.Edits[LOffIdx].Row;
        LCharPos.CharIndex := APlan.Edits[LOffIdx].Col - 1;
        LOffsets[LOffIdx - LIdx] := LView.CharPosToPos(LCharPos);
      end;
      LWriter := LView.Buffer.CreateUndoableWriter;
      if Assigned(LWriter) then
      try
        for LOffIdx := LIdx to LRun - 1 do
        begin
          LWriter.CopyTo(LOffsets[LOffIdx - LIdx]);
          LWriter.DeleteTo(LOffsets[LOffIdx - LIdx] + APlan.Edits[LOffIdx].Len);
          // The site's OWN new text: a unit rename writes the full dotted
          // name where the reference was written in full and the bare leaf
          // where a namespace prefix resolved it, on the same line.
          LWriter.Insert(UTF8String(APlan.Edits[LOffIdx].NewText));
        end;
      finally
        LWriter := nil;   // the writer commits on release
      end;
      LView.Paint;
    end;
    LIdx := LRun;
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

{ THE FILE HALF OF A UNIT RENAME, and the only place this package writes to
  the file system.

  Object Pascal ties a unit's name to its file name, so text edits alone
  produce a project that does not compile - which makes this not an extra
  but the other half of the same action. It runs only after every text edit
  has been applied and SAVED: a file renamed under an unsaved buffer loses
  whatever the buffer held.

  THROUGH THE PROJECT, NOT ONLY THROUGH THE DISK. RemoveFile + AddFile is
  what makes the IDE rewrite its own bookkeeping - the .dproj entry and, in a
  program, the `uses Foo in 'Foo.pas'` path. That path is exactly what the
  analysis plan CANNOT fix (it has no position for the literal; see the
  server's UsesInPathSites), so this is not a convenience: it is the reason a
  unit rename can be complete at all.

  A .dfm goes with it. A form unit's resource directive resolves against the
  UNIT
  name, so a renamed unit whose .dfm kept the old name loses its form - and
  the error appears at run time, not at build. Same for the .dcr/.dcu-adjacent
  companions we do NOT touch: those are build output and regenerate.

  ORDER, and each step is here because the previous one makes it possible:
    1. save every touched module      - the edits must be on disk
    2. remove the file from the project - while it still exists, or the IDE
                                         cannot find what to remove
    3. close the module                - Windows will not rename an open file
    4. move .pas (and .dfm if any)     - the rename itself
    5. add the new file to the project - the IDE rewrites .dproj and the
                                         program's uses path here
    6. reopen it in the editor         - the user was looking at it }
function RenameUnitFile(const APlan: TLspRenamePlan;
  const AEditors: TDictionary<string, IOTASourceEditor>): Boolean;
var
  LModuleServices: IOTAModuleServices;
  LActionServices: IOTAActionServices;
  LModule: IOTAModule;
  LProject: IOTAProject;
  LEditor: IOTASourceEditor;
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

  // 1. Every touched buffer to disk. Not just the renamed one: the `uses`
  //    edits in other units are part of the same rename, and leaving them
  //    only in buffers while the file name changes underneath is how a
  //    half-state becomes permanent.
  for LEditor in AEditors.Values do
    if Assigned(LEditor.Module) then
      LEditor.Module.Save(False, False);

  LModule := LModuleServices.FindModule(APlan.FilePath);
  LProject := ActiveProject;

  // 2-3. Out of the project, then out of the editor. RemoveFile first: it
  //      addresses the file by the name the project knows, which the move
  //      below is about to invalidate.
  if Assigned(LProject) then
    try
      LProject.RemoveFile(APlan.FilePath);
    except
      on E: Exception do
        // Not fatal on its own - AddFile below still repairs the project -
        // but it is the step whose failure explains a duplicated entry.
        LogDiagnostic(Format('rename: removing %s from the project failed: ' +
          '%s', [ExtractFileName(APlan.FilePath), E.Message]));
    end;
  if Assigned(LModule) then
    LModule.Close;

  // 4. The rename itself, .dfm included.
  try
    TFile.Move(APlan.FilePath, APlan.NewFilePath);
  except
    on E: Exception do
    begin
      TellUser(Format('Could not rename %s to %s: %s'#13#10#13#10 +
        'The text edits are applied - rename the file by hand, or undo.',
        [ExtractFileName(APlan.FilePath),
         ExtractFileName(APlan.NewFilePath), E.Message]), mtError);
      // Put the file back in the project even so: a project missing a unit
      // it still contains is worse than the failed rename.
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
        // Said out loud rather than swallowed: a form that has lost its .dfm
        // fails at RUN time, which is a long way from here.
        TellUser(Format('The unit was renamed, but its form file could not ' +
          'be renamed from %s to %s: %s'#13#10#13#10 +
          'Rename it by hand before running - a unit whose .dfm name does ' +
          'not match it loses its form.',
          [ExtractFileName(LOldDfm), ExtractFileName(LNewDfm), E.Message]),
          mtError);
    end;

  // 5-6. Back into the project - which is what rewrites the .dproj entry and
  //      a program's `in '...'` path - and back into the editor.
  if Assigned(LProject) then
    try
      LProject.AddFile(APlan.NewFilePath, True);
    except
      on E: Exception do
        TellUser(Format('%s was renamed to %s, but adding it back to the ' +
          'project failed: %s'#13#10#13#10 +
          'Add it to the project by hand.',
          [ExtractFileName(APlan.FilePath),
           ExtractFileName(APlan.NewFilePath), E.Message]), mtError);
    end;
  LActionServices.OpenFile(APlan.NewFilePath);
  Result := True;
end;

{ Open everything, verify everything, then write - the two passes the unit
  header describes, with the opening folded into the first because a file
  that will not open is the same kind of refusal as a site that moved. }
function ApplyPlan(const APlan: TLspRenamePlan): Boolean;
var
  LEditors: TDictionary<string, IOTASourceEditor>;
  LEdit: TLspRenameEdit;
  LEditor: IOTASourceEditor;
  LKey, LError: string;
begin
  Result := False;
  LEditors := TDictionary<string, IOTASourceEditor>.Create;
  try
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      if LEditors.ContainsKey(LKey) then
        Continue;
      LEditor := OpenSourceEditor(LEdit.FilePath);
      if not Assigned(LEditor) then
      begin
        TellUser(Format('Cannot open %s.'#13#10#13#10 +
          'Nothing was renamed.', [LEdit.FilePath]), mtError);
        Exit;
      end;
      LEditors.Add(LKey, LEditor);
    end;
    if not VerifySites(LEditors, APlan, {out} LError) then
    begin
      TellUser(LError, mtError);
      Exit;
    end;
    ApplySites(LEditors, APlan);
    { And, for a unit, the half that is not text at all. Deliberately AFTER
      the edits: the plan describes the sources as analyzed, so every
      position must be resolved and written against the old file name. A
      failure here reports itself and leaves the text edits standing - the
      user can undo them or finish the file rename by hand, and either way
      is told which. }
    if APlan.IsUnit then
      RenameUnitFile(APlan, LEditors);
    Result := True;
  finally
    LEditors.Free;
  end;
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
  ExecuteRename): ask for the new name, plan, apply, report. }
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
    begin
      GPlanning := False;
      if not GAlive then
        Exit;
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
      if not ApplyPlan(APlan) then
        Exit;   // ApplyPlan has already said why, and changed nothing
      ReportRename(APlan);
      LogDiagnostic(Format('rename: %s %s -> %s, %d site(s)%s',
        [KindWord(APlan.IsUnit), APlan.OldName, APlan.NewName,
         Length(APlan.Edits),
         IfThen(APlan.IsUnit, ' + file -> ' + APlan.RequiredFileName, '')]));
      { A renamed FILE is a different analysis closure, and the server fixes
        its closure at initialize - so this is the one edit in the product
        that cannot be absorbed incrementally. Restarting is honest and costs
        the next request one rebuild; keeping the old server would have it
        answer every later question about a file that no longer exists. }
      if APlan.IsUnit then
        LspRestartForClosureChange(Format('unit %s was renamed to %s',
          [APlan.OldName, APlan.NewName]));
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
        // the POSITION we asked about is the one we keep renaming from, and
        // the server still holds the same snapshot it answered from.
        RenameFrom(LFileName, LRow, LCol, AName);
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
