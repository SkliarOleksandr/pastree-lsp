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

  WHAT IT WILL AND WILL NOT RENAME. A symbol - a routine, a type, a field, a
  variable, a parameter. Not a unit (that is a file rename plus every `uses`
  clause; the server declines it with a sentence saying so, and it is a
  planned feature, not a gap here) and not a compiler builtin (no declaration
  exists to rename). Both refusals arrive as the server's own message and are
  shown verbatim - this unit invents no vocabulary of its own for them.

  THE NEW NAME IS VALIDATED IN TWO PLACES, AND THAT IS DELIBERATE. Only the
  ANALYSIS knows that `begin` is a reserved word (IsValidRenameName lives in
  PasTree, which this Win32 designtime package must never link - see
  clients/rad-studio/README.md), so the real verdict always comes from the
  server. What happens here is the cheap half: obvious non-identifiers are
  refused without a round trip, so a typo does not cost a request. Never
  extend LooksLikeIdentifier into keyword knowledge - a copy of that list
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
  half is the server's and must stay there. }
function LooksLikeIdentifier(const AName: string): Boolean;
const
  cFirst = ['A'..'Z', 'a'..'z', '_'];
  cRest = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
var
  LIdx: Integer;
begin
  Result := False;
  if AName = '' then
    Exit;
  if not CharInSet(AName[1], cFirst) then
    Exit;
  for LIdx := 2 to Length(AName) do
    if not CharInSet(AName[LIdx], cRest) then
      Exit;
  Result := True;
end;

{ The identifier under the caret, read out of the text the SERVER was given -
  the same source, and for the same reason, as FindReferences' own copy of
  this: it is what the answer will be computed from, and an unsaved buffer's
  columns only mean anything against it. Used for the prompt's pre-fill only;
  the authoritative old name comes back in the plan. }
function IdentifierAt(const AFileName: string; ARow, ACol: Integer): string;
const
  cWordChars = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
var
  LLines: TArray<string>;
  LLine: string;
  LStart, LEnd: Integer;
begin
  Result := '';
  LLines := LspSourceTextOf(AFileName).Replace(#13#10, #10).Split([#10]);
  if (ARow < 1) or (ARow > Length(LLines)) then
    Exit;
  LLine := LLines[ARow - 1];
  if (ACol < 1) or (ACol > Length(LLine)) then
    Exit;
  if not CharInSet(LLine[ACol], cWordChars) then
    Exit;
  LStart := ACol;
  while (LStart > 1) and CharInSet(LLine[LStart - 1], cWordChars) do
    Dec(LStart);
  LEnd := ACol;
  while (LEnd < Length(LLine)) and CharInSet(LLine[LEnd + 1], cWordChars) do
    Inc(LEnd);
  Result := Copy(LLine, LStart, LEnd - LStart + 1);
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
          LWriter.Insert(UTF8String(APlan.NewName));
        end;
      finally
        LWriter := nil;   // the writer commits on release
      end;
      LView.Paint;
    end;
    LIdx := LRun;
  end;
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
    Result := True;
  finally
    LEditors.Free;
  end;
end;

procedure ExecuteRename(const AView: IOTAEditView);
var
  LFileName, LOldName, LNewName: string;
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
    LFileName := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;

    LOldName := IdentifierAt(LFileName, LRow, LCol);
    if LOldName = '' then
    begin
      TellUser('No identifier under the cursor.', mtInformation);
      Exit;
    end;
    LNewName := LOldName;
    if not InputQuery('Rename', Format('Rename "%s" to:', [LOldName]),
      LNewName) then
      Exit;
    LNewName := Trim(LNewName);
    if LNewName = LOldName then
      Exit;   // not a refusal worth a dialog: the user changed nothing
    if not LooksLikeIdentifier(LNewName) then
    begin
      TellUser(Format('"%s" is not a valid identifier.', [LNewName]),
        mtWarning);
      Exit;
    end;

    if GPlanning then
    begin
      TellUser('A rename is already in progress.', mtInformation);
      Exit;
    end;
    GPlanning := True;
    LspRenamePlan(LFileName, LRow, LCol, LNewName,
      procedure(ASuccess: Boolean; const APlan: TLspRenamePlan;
        const AError: string)
      begin
        GPlanning := False;
        if not GAlive then
          Exit;
        // The server's own sentence, verbatim - a reserved word, a unit
        // name, a builtin. See the unit header on why none of these is
        // re-worded here.
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
        LogDiagnostic(Format('rename: %s -> %s, %d site(s)',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits)]));
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
