unit PasTreeIdePlugin.UnusedUnits;

{
  Find All > Unused Units, Unused Units in the Project, Units Nobody Uses -
  PasTree 0.93.0's unused-units checks (PasTree.Sema.Lint, the demo's three
  commands), with the results as a tree in a tab of its own per command
  ("Unused Units", "Unused Units in the Project", "Units Nobody Uses" -
  without the "PasTree " the other result tabs carry, which made these
  captions too long, Alex 2026-10-06) and a toolbar above it: Remove takes
  the selected unit out, Remove All every one, Revert takes the last Remove
  back.

  WHAT IS OFFERED IS THE SERVER'S. It answers pastree/unusedUses (the unit
  in the editor, or every unit of the project outside the library paths)
  and pastree/unreferencedUnits, with the rows and why a row is kept (its
  doubts - shown, never removed). A unit whose initialization reaches
  outside itself is not offered at all - it is in `uses` for what it
  registers (PasTree's loHideGlobalInit, Alex 2026-10-05).

  THE TREE (Alex, 2026-10-06: the file name alone on top, no tags): a top
  row per node - the file for Unused Units, the unit for Units Nobody Uses -
  named by its file name. Under it the `uses` lines: the unused entries,
  the name marked; for a unit nobody uses, every entry still naming it. A
  note under a row says why it is kept ("kept: ...") or why no edit removes
  it.
  Unused Units of the one unit in the editor (Alex, 2026-10-06, second
  shape): no file row - the top level is "interface (N)" and
  "implementation (N)", each shown only when N > 0, the `uses` lines under
  them as above. A node there is one entry, not the file.

  REMOVE IS PER NODE, so a unit can be taken out and the project compiled
  before the next one (Alex, 2026-10-06): Remove takes the node selected in
  the tree (RenameToolbar.ResultFocusedRow) - a section row stands for every
  node under it - Remove All every node left.
  The edits are asked for at the click (pastree/usesRemoval), on the text
  as it is then - not with the search: a unit nobody uses is listed beside
  its siblings in one clause, and an edit computed before the first of
  them went no longer matches the clause it left. All or nothing per
  Remove: every edit is checked against the text before any is made. Open
  modules are edited through one undoable writer each (one Ctrl+Z per
  file) and saved, as Rename does (Alex, 2026-10-06, after trying it
  unsaved). The save drops the editor's undo history unless the editor's
  "Undo after save" is on - Revert is the way back. Files nobody has open
  are rewritten on disk in their own
  encoding (PasLsp.SourceText). For Units Nobody Uses each unit is also
  taken out of the project (IOTAProject.RemoveFile - which edits the .dpr's
  own uses), and the project is saved. A removed node leaves the tree; the
  rows left are moved to the lines the edits left them on (MoveRows - on
  AVImark every row under a removed interface clause pointed lines too low,
  2026-10-06), and Revert puts back the positions it took. The tab is
  rebuilt (the ToolsAPI has no way to drop one row), and the selection is
  put on the node after the removed ones (SelectNode).

  REVERT takes the LAST Remove back, and again the one before - a stack.
  Every rewritten clause must still read what that Remove wrote, at the
  place it wrote it - the offsets are kept from the forward pass, shifted by
  what the earlier edits in the same file added or took away; the later
  Removes are already undone, so the text is the one it left. Anything else
  (the file was edited in between) refuses that Revert and names the file;
  Ctrl+Z in an open file and Revert again is the way out. Units taken out
  of the project are added back.

  Kept per Remove: the nodes, the edits and their offsets, the files taken
  out of the project - never an IDE interface, which the user can close
  under us (the Rename tab's lesson, see its unit).
}

interface

uses
  ToolsAPI;

type
  TUnusedUnitsCommand = (uucUnit, uucProject, uucNobody);

/// <summary>Runs one of the three checks for the file in AView (any file
/// of the project for the two project-wide ones).</summary>
procedure ExecuteUnusedUnits(ACommand: TUnusedUnitsCommand;
  const AView: IOTAEditView);

/// <summary>Drops the results tab because the project it describes is
/// closing.</summary>
procedure CloseUnusedUnitsResults;

/// <summary>Removes the tab and gates late callbacks off - from the
/// wizard's teardown, before FinalizeLspSession.</summary>
procedure FinalizeUnusedUnits;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, System.UITypes, Vcl.Forms, Vcl.Dialogs,
  PasLsp.SourceText,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.RenameToolbar,
  PasTreeIdePlugin.WaitDialog, PasTreeIdePlugin.FormModules;

const
  // A tab per command (Alex, 2026-10-06: Unused Units and Units Nobody Uses
  // shared one, and each search threw the other's results and Removes away).
  cMessageGroupName: array[TUnusedUnitsCommand] of string = (
    'Unused Units',
    'Unused Units in the Project',
    'Units Nobody Uses');
  cRemoveButton = 0;
  cRemoveAllButton = 1;
  cRevertButton = 2;

type
  // One edit as applied: the edit and its 0-based character offset in the
  // file's text (no BOM) BEFORE the forward pass.
  TAppliedEdit = record
    Edit: TLspUsesEdit;
    Offset: Integer;
  end;

  // A file's text and how to write it back.
  TEditTarget = record
    Path: string;
    Module: IOTAModule;      // nil: not open, Text is the file's
    Bom: Boolean;            // the buffer starts with a UTF-8 BOM
    Text: string;            // without a BOM
    Encoding: TPasSourceEncoding;
  end;

  // One Remove as made: the nodes it took out, its edits (with the offsets
  // of the forward pass), the units it took out of the project.
  TRemoval = record
    Nodes: TArray<Integer>;
    Edits: TArray<TAppliedEdit>;
    Units: TArray<string>;
    Before: TLspUnusedAnswer;   // the rows' positions before it, for Revert
  end;

type
  // One command's tab and everything its toolbar works on.
  TUnusedTab = class
    Command: TUnusedUnitsCommand;
    Caption: string;                // the message group's name
    Group: IOTAMessageGroup;        // set once the tab was shown
    Answer: TLspUnusedAnswer;
    TitleFile: string;
    // The nodes: for Unused Units in the Project the files of Answer.Entries
    // in order (a node is an index into Files), for Unused Units the entries
    // themselves, for Units Nobody Uses Answer.Units (an index into either).
    Files: TArray<string>;
    Removals: TArray<TRemoval>;     // in order; Revert takes the last back
    // A shown row -> its nodes: one, or every node under a section row.
    RowNode: TDictionary<Pointer, TArray<Integer>>;
    TopNode: TArray<TArray<Integer>>;  // the top-level rows -> nodes, nil title
    // The nodes in the order shown, and the row each is selected by (its
    // `uses` line for Unused Units, its file row otherwise) - for the
    // selection after a Remove.
    ShownNode: TArray<Integer>;
    ShownRow: TArray<Pointer>;
    Busy: Boolean;                  // a Remove waits for its edits
    Generation: Integer;            // a new search or a closed tab
    constructor Create(ACommand: TUnusedUnitsCommand);
    destructor Destroy; override;
    procedure Clear;
  end;

var
  GAlive: Boolean = True;
  GTabs: array[TUnusedUnitsCommand] of TUnusedTab;
  { THE TAB THE CODE BELOW WORKS ON. Every entry point - a search, a toolbar
    click, a server's answer, a queued selection - sets it to its own tab
    first (UseTab), and everything runs on the main thread, so the routines
    under it read one tab's state without passing it down. }
  GTab: TUnusedTab;

constructor TUnusedTab.Create(ACommand: TUnusedUnitsCommand);
begin
  inherited Create;
  Command := ACommand;
  Caption := cMessageGroupName[ACommand];
  RowNode := TDictionary<Pointer, TArray<Integer>>.Create;
end;

destructor TUnusedTab.Destroy;
begin
  RowNode.Free;
  inherited;
end;

procedure TUnusedTab.Clear;
begin
  Inc(Generation);
  Group := nil;
  Answer := Default(TLspUnusedAnswer);
  Files := nil;
  Removals := nil;
  TopNode := nil;
  ShownNode := nil;
  ShownRow := nil;
  Busy := False;
  RowNode.Clear;
end;

// Makes ACommand's tab the one worked on; False once the package is going.
function UseTab(ACommand: TUnusedUnitsCommand): Boolean;
begin
  Result := GAlive;
  if not Result then
    Exit;
  if not Assigned(GTabs[ACommand]) then
    GTabs[ACommand] := TUnusedTab.Create(ACommand);
  GTab := GTabs[ACommand];
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  LspLogToServer('unused units: ' + AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

procedure TellUser(const AText: string; AType: TMsgDlgType);
begin
  MessageDlg(AText, AType, [mbOK], 0);
end;

function GetOrCreateMessageGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  // Looked up every time: a tab the user closed is a group the IDE has
  // dropped, and the reference held here keeps only its object alive -
  // ShowMessageView on it was an access violation in TTabSet.SetTabIndex
  // (Alex, 2026-10-06: close the tab, search again).
  GTab.Group := AMessageServices.GetGroup(GTab.Caption);
  if not Assigned(GTab.Group) then
    GTab.Group := AMessageServices.AddMessageGroup(GTab.Caption);
  Result := GTab.Group;
end;

{ -------- the edits -------- }

// The 0-based offset of line ARow, character column ACol (both 1-based) in
// AText; -1 when there is no such line.
function OffsetOf(const AText: string; ARow, ACol: Integer): Integer;
var
  LLine, LPos: Integer;
begin
  Result := -1;
  LPos := 1;
  LLine := 1;
  while LLine < ARow do
  begin
    while (LPos <= Length(AText)) and (AText[LPos] <> #10) do
      Inc(LPos);
    if LPos > Length(AText) then
      Exit;
    Inc(LPos);
    Inc(LLine);
  end;
  Result := LPos - 1 + ACol - 1;
  if Result > Length(AText) then
    Result := -1;
end;

// The open module of APath, or nil. A module without a source editor (a
// project file's .dproj) counts as not open.
function SourceEditorOf(const AModule: IOTAModule): IOTASourceEditor;
begin
  Result := nil;
  if not Assigned(AModule) then
    Exit;
  for var LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTASourceEditor, Result)
    then
      Exit;
  Result := nil;
end;

function LoadTarget(const APath: string; out ATarget: TEditTarget;
  out AError: string): Boolean;
var
  LBytes: UTF8String;
begin
  ATarget := Default(TEditTarget);
  ATarget.Path := APath;
  AError := '';
  ATarget.Module := ModuleOf(APath);
  if Assigned(SourceEditorOf(ATarget.Module)) then
  begin
    LBytes := ReadModuleBufferUtf8(ATarget.Module);
    ATarget.Bom := (Length(LBytes) >= 3) and (LBytes[1] = #$EF) and
      (LBytes[2] = #$BB) and (LBytes[3] = #$BF);
    if ATarget.Bom then
      Delete(LBytes, 1, 3);
    ATarget.Text := UTF8ToString(LBytes);
    Exit(True);
  end;
  ATarget.Module := nil;
  Result := TryReadSourceForEdit(APath, ATarget.Text, ATarget.Encoding);
  if not Result then
    AError := ExtractFileName(APath) + ' could not be read';
end;

// The edits of one file in order, with the offsets this pass works at:
// forward, where the server saw them; backward, where the forward pass left
// them.
function TargetOffsets(const ATarget: TEditTarget;
  const AEdits: TArray<TAppliedEdit>; AForward: Boolean;
  out AOffsets: TArray<Integer>; out AError: string): Boolean;
var
  LShift: Integer;
  LExpected: string;
begin
  Result := False;
  AError := '';
  SetLength(AOffsets, Length(AEdits));
  LShift := 0;
  for var LIdx := 0 to High(AEdits) do
  begin
    if AForward then
    begin
      AOffsets[LIdx] := OffsetOf(ATarget.Text, AEdits[LIdx].Edit.Row,
        AEdits[LIdx].Edit.Col);
      LExpected := AEdits[LIdx].Edit.OldText;
    end
    else
    begin
      AOffsets[LIdx] := AEdits[LIdx].Offset + LShift;
      LExpected := AEdits[LIdx].Edit.NewText;
    end;
    Inc(LShift, Length(AEdits[LIdx].Edit.NewText) -
      Length(AEdits[LIdx].Edit.OldText));
    if (AOffsets[LIdx] < 0) or
       (Copy(ATarget.Text, AOffsets[LIdx] + 1, Length(LExpected)) <> LExpected)
    then
    begin
      if AForward then
        AError := Format('%s line %d no longer reads what the analysis saw ' +
          '- the file has changed since. Nothing was removed. Run the search ' +
          'again.', [ExtractFileName(ATarget.Path), AEdits[LIdx].Edit.Row])
      else
        AError := Format('%s has been edited since the Remove (line %d). ' +
          'Nothing was reverted. Undo the edit there and press Revert again.',
          [ExtractFileName(ATarget.Path), AEdits[LIdx].Edit.Row]);
      Exit;
    end;
  end;
  Result := True;
end;

// Writes AEdits into ATarget at AOffsets (ascending), forward or back.
procedure WriteTarget(var ATarget: TEditTarget;
  const AEdits: TArray<TAppliedEdit>; const AOffsets: TArray<Integer>;
  AForward: Boolean);
var
  LWriter: IOTAEditWriter;
  LFrom, LTo: string;
  LByte: Integer;
  LText: string;
begin
  if Assigned(ATarget.Module) then
  begin
    LWriter := SourceEditorOf(ATarget.Module).CreateUndoableWriter;
    for var LIdx := 0 to High(AEdits) do
    begin
      if AForward then
      begin
        LFrom := AEdits[LIdx].Edit.OldText;
        LTo := AEdits[LIdx].Edit.NewText;
      end
      else
      begin
        LFrom := AEdits[LIdx].Edit.NewText;
        LTo := AEdits[LIdx].Edit.OldText;
      end;
      // A writer counts UTF-8 bytes of the buffer, BOM included.
      LByte := Length(UTF8Encode(Copy(ATarget.Text, 1, AOffsets[LIdx])));
      if ATarget.Bom then
        Inc(LByte, 3);
      LWriter.CopyTo(LByte);
      LWriter.DeleteTo(LByte + Length(UTF8Encode(LFrom)));
      if LTo <> '' then
        LWriter.Insert(PAnsiChar(UTF8Encode(LTo)));
    end;
    LWriter := nil;
    NoteBufferModified(ATarget.Path);
    Exit;
  end;
  // On disk: spliced from the last edit back, so earlier offsets hold.
  LText := ATarget.Text;
  for var LIdx := High(AEdits) downto 0 do
  begin
    if AForward then
    begin
      LFrom := AEdits[LIdx].Edit.OldText;
      LTo := AEdits[LIdx].Edit.NewText;
    end
    else
    begin
      LFrom := AEdits[LIdx].Edit.NewText;
      LTo := AEdits[LIdx].Edit.OldText;
    end;
    LText := Copy(LText, 1, AOffsets[LIdx]) + LTo +
      Copy(LText, AOffsets[LIdx] + Length(LFrom) + 1, MaxInt);
  end;
  ATarget.Text := LText;
end;

{ Both passes, all or nothing: every file is read and every edit checked
  before the first is written. AEdits sorted by file, then position; on a
  forward pass their offsets are filled in. ADiskPaths: the files written on
  disk, for the server. }
function ApplyAll(var AEdits: TArray<TAppliedEdit>; AForward: Boolean;
  out ADiskPaths: TArray<string>; out AError: string): Boolean;
var
  LTargets: TList<TEditTarget>;
  LRanges: TList<TPair<Integer, Integer>>;   // first edit, count per target
  LOffsets: TList<TArray<Integer>>;
  LTarget: TEditTarget;
  LFirst, LLast: Integer;
  LOff: TArray<Integer>;
  LFileEdits: TArray<TAppliedEdit>;
begin
  Result := False;
  ADiskPaths := nil;
  AError := '';
  LTargets := TList<TEditTarget>.Create;
  LRanges := TList<TPair<Integer, Integer>>.Create;
  LOffsets := TList<TArray<Integer>>.Create;
  try
    // Pass one: read and check.
    LFirst := 0;
    while LFirst <= High(AEdits) do
    begin
      LLast := LFirst;
      while (LLast < High(AEdits)) and SameText(AEdits[LLast + 1].Edit.FilePath,
        AEdits[LFirst].Edit.FilePath) do
        Inc(LLast);
      if not LoadTarget(AEdits[LFirst].Edit.FilePath, LTarget, AError) then
      begin
        AError := AError + '. Nothing was ' + IfThen(AForward, 'removed',
          'reverted') + '.';
        Exit;
      end;
      LFileEdits := Copy(AEdits, LFirst, LLast - LFirst + 1);
      if not TargetOffsets(LTarget, LFileEdits, AForward, LOff, AError) then
        Exit;
      LTargets.Add(LTarget);
      LRanges.Add(TPair<Integer, Integer>.Create(LFirst, LLast - LFirst + 1));
      LOffsets.Add(LOff);
      LFirst := LLast + 1;
    end;
    // Pass two: write and save.
    for var LIdx := 0 to LTargets.Count - 1 do
    begin
      LTarget := LTargets[LIdx];
      LFileEdits := Copy(AEdits, LRanges[LIdx].Key, LRanges[LIdx].Value);
      if AForward then
        for var LE := 0 to High(LFileEdits) do
          AEdits[LRanges[LIdx].Key + LE].Offset := LOffsets[LIdx][LE];
      WriteTarget(LTarget, LFileEdits, LOffsets[LIdx], AForward);
      // An open module is saved, like every file written on disk - one
      // shape for all three checks (Alex, 2026-10-06).
      if Assigned(LTarget.Module) then
        LTarget.Module.Save(False, True)
      else if TryWriteSource(LTarget.Path, LTarget.Text, LTarget.Encoding) then
        ADiskPaths := ADiskPaths + [LTarget.Path]
      else
        LogDiagnostic(ExtractFileName(LTarget.Path) +
          ' could not be written - its edit is lost');
    end;
    Result := True;
  finally
    LOffsets.Free;
    LRanges.Free;
    LTargets.Free;
  end;
end;

{ -------- the project -------- }

function ProjectByFile(const AProjectFile: string): IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LGroup := LModuleServices.MainProjectGroup;
  if Assigned(LGroup) then
    for var LIdx := 0 to LGroup.ProjectCount - 1 do
      if SameText(LGroup.Projects[LIdx].FileName, AProjectFile) then
        Exit(LGroup.Projects[LIdx]);
end;

{ -------- the nodes -------- }

function NodeCount: Integer;
begin
  case GTab.Command of
    uucUnit: Result := Length(GTab.Answer.Entries);
    uucNobody: Result := Length(GTab.Answer.Units);
  else
    Result := Length(GTab.Files);
  end;
end;

function NodeRemoved(ANode: Integer): Boolean;
begin
  for var LRemoval in GTab.Removals do
    for var LN in LRemoval.Nodes do
      if LN = ANode then
        Exit(True);
  Result := False;
end;

// An entry Remove takes out: no doubt, and an edit can do it.
function EntryRemovable(const AEntry: TLspUnusedEntry): Boolean;
begin
  Result := (AEntry.Doubts = nil) and (AEntry.Refused = '');
end;

// Whether ANode has anything Remove takes out.
function NodeRemovable(ANode: Integer): Boolean;
begin
  case GTab.Command of
    uucUnit: Exit(EntryRemovable(GTab.Answer.Entries[ANode]));
    uucNobody: Exit(GTab.Answer.Units[ANode].Doubts = nil);
  end;
  for var LEntry in GTab.Answer.Entries do
    if SameText(LEntry.FilePath, GTab.Files[ANode]) and EntryRemovable(LEntry) then
      Exit(True);
  Result := False;
end;

function NodeFile(ANode: Integer): string;
begin
  case GTab.Command of
    uucUnit: Result := GTab.Answer.Entries[ANode].FilePath;
    uucNobody: Result := GTab.Answer.Units[ANode].FilePath;
  else
    Result := GTab.Files[ANode];
  end;
end;

// What a message about ANode calls it: the unit for Unused Units, else the
// file.
function NodeName(ANode: Integer): string;
begin
  if GTab.Command = uucUnit then
    Result := GTab.Answer.Entries[ANode].UnitName
  else
    Result := ExtractFileName(NodeFile(ANode));
end;

// The nodes left that Remove All takes.
function RemovableNodes: TArray<Integer>;
begin
  Result := nil;
  for var LNode := 0 to NodeCount - 1 do
    if not NodeRemoved(LNode) and NodeRemovable(LNode) then
      Result := Result + [LNode];
end;

{ -------- the tab -------- }

function SnippetOf(ACache: TDictionary<string, TStringList>;
  const APath: string; ARow: Integer): string;
var
  LLines: TStringList;
begin
  if not ACache.TryGetValue(LowerCase(APath), LLines) then
  begin
    LLines := TStringList.Create;
    LLines.Text := LspSourceTextOf(APath);
    ACache.Add(LowerCase(APath), LLines);
  end;
  if (ARow >= 1) and (ARow <= LLines.Count) then
    Result := LLines[ARow - 1]
  else
    Result := '';
end;

procedure UpdateButtons;
begin
  SetResultToolbarEnabled(GTab.Caption, cRemoveButton,
    not GTab.Busy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(GTab.Caption, cRemoveAllButton,
    not GTab.Busy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(GTab.Caption, cRevertButton,
    not GTab.Busy and (GTab.Removals <> nil));
end;

procedure RemoveClick(ACommand: TUnusedUnitsCommand); forward;
procedure RemoveAllClick(ACommand: TUnusedUnitsCommand); forward;
procedure RevertClick(ACommand: TUnusedUnitsCommand); forward;

procedure Report;
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LCache: TObjectDictionary<string, TStringList>;
  LTitle, LCount: string;
  LTop: Pointer;
  LShown, LRemoved, LCountAt: Integer;
  LCommand: TUnusedUnitsCommand;   // the buttons' tab, captured

  procedure Note(ANode: Integer; const ALeadIn, AText: string;
    AParent: Pointer);
  begin
    GTab.RowNode.AddOrSetValue(LMessageServices.AddCustomMessage(NewNoteRow(
      ALeadIn, AText), AParent), [ANode]);
  end;

  // An unused entry's `uses` line under AParent, and its notes under it.
  procedure EntryRow(const AEntry: TLspUnusedEntry; ANode: Integer;
    AParent: Pointer);
  var
    LRowPtr: Pointer;
  begin
    LRowPtr := LMessageServices.AddCustomMessage(NewSnippetRow(
      AEntry.FilePath, AEntry.Row, AEntry.Col, SnippetOf(LCache,
      AEntry.FilePath, AEntry.Row), AEntry.Col, AEntry.Len, '',
      AEntry.TypeSpans), AParent);
    GTab.RowNode.AddOrSetValue(LRowPtr, [ANode]);
    if GTab.Command = uucUnit then
    begin
      GTab.ShownNode := GTab.ShownNode + [ANode];
      GTab.ShownRow := GTab.ShownRow + [LRowPtr];
    end;
    for var LDoubt in AEntry.Doubts do
      Note(ANode, 'kept: ', LDoubt, LRowPtr);
    if (AEntry.Doubts = nil) and (AEntry.Refused <> '') then
      Note(ANode, 'not removable: ', AEntry.Refused, LRowPtr);
  end;

  // Unused Units: "interface (N)" / "implementation (N)", the entries of
  // that section left under it; nothing when none is left.
  procedure SectionRows(const ASection: string);
  var
    LNodes: TArray<Integer>;
    LSectionCount: string;
  begin
    LNodes := nil;
    for var LNode := 0 to NodeCount - 1 do
      if not NodeRemoved(LNode) and
         SameText(GTab.Answer.Entries[LNode].Section, ASection) then
        LNodes := LNodes + [LNode];
    if LNodes = nil then
      Exit;
    LSectionCount := IntToStr(Length(LNodes));
    LTop := LMessageServices.AddCustomMessagePtr(NewTitleRow(
      ASection + ' (' + LSectionCount + ')', Length(ASection) + 3,
      Length(LSectionCount)), LGroup);
    GTab.RowNode.AddOrSetValue(LTop, LNodes);
    GTab.TopNode := GTab.TopNode + [LNodes];
    for var LNode in LNodes do
      EntryRow(GTab.Answer.Entries[LNode], LNode, LTop);
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices)
  then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  GTab.RowNode.Clear;
  GTab.TopNode := [nil];
  GTab.ShownNode := nil;
  GTab.ShownRow := nil;
  LShown := 0;
  LRemoved := 0;
  for var LNode := 0 to NodeCount - 1 do
    if NodeRemoved(LNode) then
      Inc(LRemoved)
    else if GTab.Command <> uucProject then
      Inc(LShown)
    else
      for var LEntry in GTab.Answer.Entries do
        if SameText(LEntry.FilePath, GTab.Files[LNode]) then
          Inc(LShown);
  LCache := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  try
    case GTab.Command of
      uucUnit:
        LTitle := 'Unused units in ' + ExtractFileName(GTab.TitleFile) + ': ';
      uucProject:
        LTitle := Format('Unused units in %s (%d units): ',
          [ExtractFileName(GTab.Answer.ProjectFile), NodeCount - LRemoved]);
    else
      LTitle := 'Units nobody uses in ' + ExtractFileName(GTab.Answer.ProjectFile) +
        ': ';
    end;
    LCount := IntToStr(LShown);
    LCountAt := Length(LTitle) + 1;
    LTitle := LTitle + LCount;
    if LRemoved > 0 then
      LTitle := LTitle + Format(' - %d %s removed, Revert takes the last ' +
        'Remove back', [LRemoved, IfThen(GTab.Command = uucProject, 'files',
        'units')])
    else if (LShown > 0) and (RemovableNodes = nil) then
      LTitle := LTitle + ' - every one has a note, nothing to remove';
    LMessageServices.AddCustomMessage(NewTitleRow(LTitle, LCountAt,
      Length(LCount)), LGroup);

    if GTab.Command = uucUnit then
    begin
      SectionRows('interface');
      SectionRows('implementation');
    end
    else
      for var LNode := 0 to NodeCount - 1 do
      begin
        if NodeRemoved(LNode) then
          Continue;
        LTop := LMessageServices.AddCustomMessagePtr(NewFileNameRow(
          NodeFile(LNode)), LGroup);
        GTab.RowNode.AddOrSetValue(LTop, [LNode]);
        GTab.TopNode := GTab.TopNode + [[LNode]];
        GTab.ShownNode := GTab.ShownNode + [LNode];
        GTab.ShownRow := GTab.ShownRow + [LTop];
        if GTab.Command = uucNobody then
        begin
          for var LDoubt in GTab.Answer.Units[LNode].Doubts do
            Note(LNode, 'kept: ', LDoubt, LTop);
          for var LBy in GTab.Answer.Units[LNode].ListedBy do
            // Under a header: the Pointer overload, which hands back the row.
            GTab.RowNode.AddOrSetValue(LMessageServices.AddCustomMessage(
              NewSnippetRow(LBy.FilePath, LBy.Row, LBy.Col, SnippetOf(LCache,
              LBy.FilePath, LBy.Row), LBy.Col, LBy.Len, '', LBy.TypeSpans), LTop),
              [LNode]);
        end
        else
          for var LEntry in GTab.Answer.Entries do
            if SameText(LEntry.FilePath, GTab.Files[LNode]) then
              EntryRow(LEntry, LNode, LTop);
      end;
  finally
    LCache.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
  LCommand := GTab.Command;
  ShowResultToolbar(GTab.Caption, [
    ResultToolButton('Remove', 'EditDeleteCommand',
      procedure begin RemoveClick(LCommand) end),
    ResultToolButton('Remove All', 'EditDeleteCommand',
      procedure begin RemoveAllClick(LCommand) end),
    ResultToolButton('Revert', 'EditUndoCommand',
      procedure begin RevertClick(LCommand) end)]);
  UpdateButtons;
end;

{ -------- Remove / Revert -------- }

function SortedEdits(const AEdits: TArray<TLspUsesEdit>): TArray<TAppliedEdit>;
begin
  SetLength(Result, Length(AEdits));
  for var LIdx := 0 to High(AEdits) do
  begin
    Result[LIdx].Edit := AEdits[LIdx];
    Result[LIdx].Offset := -1;
  end;
  TArray.Sort<TAppliedEdit>(Result, TComparer<TAppliedEdit>.Construct(
    function(const A, B: TAppliedEdit): Integer
    begin
      Result := CompareText(A.Edit.FilePath, B.Edit.FilePath);
      if Result = 0 then
        Result := A.Edit.Row - B.Edit.Row;
      if Result = 0 then
        Result := A.Edit.Col - B.Edit.Col;
    end));
end;

{ -------- the rows' positions -------- }

// Where AText ends when it starts at ARow:ACol (1-based, character columns).
procedure EndOf(const AText: string; ARow, ACol: Integer;
  out AEndRow, AEndCol: Integer);
var
  LLastBreak: Integer;
begin
  AEndRow := ARow;
  LLastBreak := 0;
  for var LIdx := 1 to Length(AText) do
    if AText[LIdx] = #10 then
    begin
      Inc(AEndRow);
      LLastBreak := LIdx;
    end;
  if LLastBreak = 0 then
    AEndCol := ACol + Length(AText)
  else
    AEndCol := Length(AText) - LLastBreak + 1;
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) or
    (Ord(C) > 127);
end;

{ A row's ARow:ACol (its name ALen characters long) after AFrom, starting at
  AEditRow:AEditCol, became ATo. Before it: unchanged. After it: moved by
  what the edit added or took away. Inside it (an entry of the rewritten
  clause): wherever its name stands in ATo; left alone when it is not there
  - that row was removed and is not shown. }
procedure MapPosition(var ARow, ACol: Integer; ALen, AEditRow,
  AEditCol: Integer; const AFrom, ATo: string);
var
  LEndRow, LEndCol, LToRow, LToCol, LAt, LFound, LBreaks, LLastBreak: Integer;
  LName, LUpperTo: string;
begin
  if (ARow < AEditRow) or ((ARow = AEditRow) and (ACol < AEditCol)) then
    Exit;
  EndOf(AFrom, AEditRow, AEditCol, LEndRow, LEndCol);
  if (ARow > LEndRow) or ((ARow = LEndRow) and (ACol >= LEndCol)) then
  begin
    EndOf(ATo, AEditRow, AEditCol, LToRow, LToCol);
    if ARow = LEndRow then
      ACol := ACol - LEndCol + LToCol;
    Inc(ARow, LToRow - LEndRow);
    Exit;
  end;
  if ARow = AEditRow then
    LAt := OffsetOf(AFrom, 1, ACol - AEditCol + 1)
  else
    LAt := OffsetOf(AFrom, ARow - AEditRow + 1, ACol);
  if LAt < 0 then
    Exit;
  LName := UpperCase(Copy(AFrom, LAt + 1, ALen));
  LUpperTo := UpperCase(ATo);
  LFound := 0;
  LAt := Pos(LName, LUpperTo);
  while (LName <> '') and (LAt > 0) do
  begin
    if ((LAt = 1) or not IsNameChar(ATo[LAt - 1])) and
       ((LAt + Length(LName) > Length(ATo)) or
        not IsNameChar(ATo[LAt + Length(LName)])) then
    begin
      LFound := LAt;
      Break;
    end;
    LAt := PosEx(LName, LUpperTo, LAt + 1);
  end;
  if LFound = 0 then
    Exit;
  LBreaks := 0;
  LLastBreak := 0;
  for var LIdx := 1 to LFound - 1 do
    if ATo[LIdx] = #10 then
    begin
      Inc(LBreaks);
      LLastBreak := LIdx;
    end;
  ARow := AEditRow + LBreaks;
  if LBreaks = 0 then
    ACol := AEditCol + LFound - 1
  else
    ACol := LFound - LLastBreak;
end;

// GTab.Answer with arrays of its own, so moving GTab.Answer's rows leaves it alone.
function SnapshotAnswer: TLspUnusedAnswer;
begin
  Result := GTab.Answer;
  Result.Entries := Copy(GTab.Answer.Entries);
  Result.Units := Copy(GTab.Answer.Units);
  for var LIdx := 0 to High(Result.Units) do
    Result.Units[LIdx].ListedBy := Copy(GTab.Answer.Units[LIdx].ListedBy);
end;

{ The rows of GTab.Answer moved to where AEdits (one Remove, sorted, in the
  coordinates of the text before it) left them - so a row clicked after a
  Remove still lands on its line. From the last edit back: each edit's
  coordinates still hold while only the ones after it have been made. }
procedure MoveRows(const AEdits: TArray<TAppliedEdit>);
begin
  for var LIdx := High(AEdits) downto 0 do
  begin
    var LEdit := AEdits[LIdx].Edit;
    for var LE := 0 to High(GTab.Answer.Entries) do
      if SameText(GTab.Answer.Entries[LE].FilePath, LEdit.FilePath) then
        MapPosition(GTab.Answer.Entries[LE].Row, GTab.Answer.Entries[LE].Col,
          GTab.Answer.Entries[LE].Len, LEdit.Row, LEdit.Col, LEdit.OldText,
          LEdit.NewText);
    for var LU := 0 to High(GTab.Answer.Units) do
      for var LB := 0 to High(GTab.Answer.Units[LU].ListedBy) do
        if SameText(GTab.Answer.Units[LU].ListedBy[LB].FilePath, LEdit.FilePath)
        then
          MapPosition(GTab.Answer.Units[LU].ListedBy[LB].Row,
            GTab.Answer.Units[LU].ListedBy[LB].Col,
            GTab.Answer.Units[LU].ListedBy[LB].Len, LEdit.Row, LEdit.Col,
            LEdit.OldText, LEdit.NewText);
  end;
end;

procedure TellServer(const ADiskPaths: TArray<string>);
begin
  LspSyncDocuments;
  if ADiskPaths <> nil then
    LspFilesChangedOnDisk(ADiskPaths);
end;

{ What ANodes' Remove asks pastree/usesRemoval for, and the units it takes
  out of the project. Unused Units: the nodes that are removable entries.
  Unused Units in the Project: the removable entries of each file.
  Units Nobody Uses: every entry naming one of the units, except in the
  program (RemoveFile edits that) and in a unit leaving the project too -
  now or with an earlier Remove. }
function RemovalFiles(const ANodes: TArray<Integer>;
  out AUnits: TArray<string>): TArray<TLspRemovalFile>;
var
  LByFile: TDictionary<string, Integer>;   // lower-cased path -> index
  LGoing: TDictionary<string, Boolean>;
  LAt: Integer;

  procedure Add(const APath, AName: string);
  begin
    if not LByFile.TryGetValue(LowerCase(APath), LAt) then
    begin
      LAt := Length(Result);
      SetLength(Result, LAt + 1);
      Result[LAt].FilePath := APath;
      LByFile.Add(LowerCase(APath), LAt);
    end;
    Result[LAt].Names := Result[LAt].Names + [AName];
  end;

begin
  Result := nil;
  AUnits := nil;
  LByFile := TDictionary<string, Integer>.Create;
  LGoing := TDictionary<string, Boolean>.Create;
  try
    if GTab.Command = uucUnit then
    begin
      for var LNode in ANodes do
        if EntryRemovable(GTab.Answer.Entries[LNode]) then
          Add(GTab.Answer.Entries[LNode].FilePath, GTab.Answer.Entries[LNode].UnitName);
      Exit;
    end;
    if GTab.Command = uucProject then
    begin
      for var LNode in ANodes do
        for var LEntry in GTab.Answer.Entries do
          if SameText(LEntry.FilePath, GTab.Files[LNode]) and
             EntryRemovable(LEntry) then
            Add(LEntry.FilePath, LEntry.UnitName);
      Exit;
    end;
    for var LNode in ANodes do
    begin
      AUnits := AUnits + [GTab.Answer.Units[LNode].FilePath];
      LGoing.AddOrSetValue(LowerCase(GTab.Answer.Units[LNode].FilePath), True);
    end;
    for var LRemoval in GTab.Removals do
      for var LPath in LRemoval.Units do
        LGoing.AddOrSetValue(LowerCase(LPath), True);
    for var LNode in ANodes do
      for var LBy in GTab.Answer.Units[LNode].ListedBy do
        if not LBy.IsProgram and
           not LGoing.ContainsKey(LowerCase(LBy.FilePath)) then
          Add(LBy.FilePath, GTab.Answer.Units[LNode].UnitName);
  finally
    LGoing.Free;
    LByFile.Free;
  end;
end;

{ -------- the selection after a rebuild -------- }

// The node to select once AGone has left the tree: the first one shown
// after the last of them, else the last one shown before them; -1 when
// none is left.
function NodeAfter(const AGone: TArray<Integer>): Integer;
var
  LLast, LFirst: Integer;
  LGone: Boolean;
begin
  Result := -1;
  LLast := -1;
  LFirst := -1;
  for var LIdx := 0 to High(GTab.ShownNode) do
    if TArray.IndexOf<Integer>(AGone, GTab.ShownNode[LIdx]) >= 0 then
    begin
      if LFirst < 0 then
        LFirst := LIdx;
      LLast := LIdx;
    end;
  if LLast < 0 then
    Exit;
  for var LIdx := LLast + 1 to High(GTab.ShownNode) do
  begin
    LGone := TArray.IndexOf<Integer>(AGone, GTab.ShownNode[LIdx]) >= 0;
    if not LGone then
      Exit(GTab.ShownNode[LIdx]);
  end;
  for var LIdx := LFirst - 1 downto 0 do
    if TArray.IndexOf<Integer>(AGone, GTab.ShownNode[LIdx]) < 0 then
      Exit(GTab.ShownNode[LIdx]);
end;

// The row ANode is selected by, nil when it is not shown.
function ShownRowOf(ANode: Integer): Pointer;
begin
  Result := nil;
  for var LIdx := 0 to High(GTab.ShownNode) do
    if GTab.ShownNode[LIdx] = ANode then
      Exit(GTab.ShownRow[LIdx]);
end;

{ Selects ANode's row in the rebuilt tab (Alex, 2026-10-06: the selection
  stays on the next unit, so Remove can be pressed again). The ToolsAPI can
  only clear a group and fill it again, so the rows are new; the tree is
  told which one through RenameToolbar.ResultSelectRow. Tried at once and,
  if the tree has not taken the rows in yet, once more when the message
  queue is next empty. }
procedure SelectNode(ANode: Integer);
var
  LGeneration: Integer;
  LCommand: TUnusedUnitsCommand;
begin
  if (ANode < 0) or ResultSelectRow(ShownRowOf(ANode)) then
    Exit;
  LGeneration := GTab.Generation;
  LCommand := GTab.Command;
  TThread.ForceQueue(nil,
    procedure
    begin
      if UseTab(LCommand) and (LGeneration = GTab.Generation) and not
        ResultSelectRow(ShownRowOf(ANode)) then
        LspLogToServer('unused units: the row after the Remove could not be ' +
          'selected');
    end);
end;

// Makes one Remove of ANodes with AEdits (the server's, on the text as it
// is now).
procedure ApplyRemoval(const ANodes: TArray<Integer>;
  const AEdits: TArray<TLspUsesEdit>; const AUnits: TArray<string>);
var
  LNext: Integer;
  LRemoval: TRemoval;
  LDisk: TArray<string>;
  LError: string;
  LProject: IOTAProject;
begin
  LRemoval.Nodes := ANodes;
  LRemoval.Edits := SortedEdits(AEdits);
  LRemoval.Units := nil;
  if not ApplyAll(LRemoval.Edits, True, LDisk, LError) then
  begin
    TellUser(LError, mtError);
    Exit;
  end;
  LRemoval.Before := SnapshotAnswer;
  MoveRows(LRemoval.Edits);
  if AUnits <> nil then
  begin
    LProject := ProjectByFile(GTab.Answer.ProjectFile);
    if not Assigned(LProject) then
      LogDiagnostic(ExtractFileName(GTab.Answer.ProjectFile) + ' is not open - ' +
        'the units stay in it')
    else
    begin
      for var LPath in AUnits do
        try
          LProject.RemoveFile(LPath);
          LRemoval.Units := LRemoval.Units + [LPath];
        except
          on E: Exception do
            LogDiagnostic(Format('%s could not be taken out of the ' +
              'project: %s', [ExtractFileName(LPath), E.Message]));
        end;
      if LRemoval.Units <> nil then
        LProject.Save(False, True);
    end;
  end;
  GTab.Removals := GTab.Removals + [LRemoval];
  LspLogToServer(Format('unused units: Remove %d - %d node(s), %d clause ' +
    'edit(s), %d unit(s) out of the project', [Length(GTab.Removals),
    Length(ANodes), Length(LRemoval.Edits), Length(LRemoval.Units)]));
  // The server first: the rows read their snippets from the text it was
  // sent, which must be the edited one.
  TellServer(LDisk);
  LNext := NodeAfter(ANodes);
  Report;
  SelectNode(LNext);
end;

procedure StartRemoval(const ANodes: TArray<Integer>);
var
  LFiles: TArray<TLspRemovalFile>;
  LUnits: TArray<string>;
  LGeneration: Integer;
  LCommand: TUnusedUnitsCommand;
begin
  LFiles := RemovalFiles(ANodes, LUnits);
  if LFiles = nil then
  begin
    // A unit only the program names: RemoveFile is all there is to do.
    ApplyRemoval(ANodes, nil, LUnits);
    Exit;
  end;
  GTab.Busy := True;
  UpdateButtons;
  LGeneration := GTab.Generation;
  LCommand := GTab.Command;
  LspUsesRemoval(GTab.TitleFile, LFiles,
    procedure(ASuccess: Boolean; const AAnswer: TLspUsesRemovalAnswer;
      const AError: string)
    begin
      if not UseTab(LCommand) or (LGeneration <> GTab.Generation) then
        Exit;
      GTab.Busy := False;
      try
        if not ASuccess then
        begin
          UpdateButtons;
          TellUser('Nothing was removed: ' + AError, mtError);
          Exit;
        end;
        for var LS in AAnswer.Missing do
          LogDiagnostic('no longer in the uses: ' + LS);
        if AAnswer.Refused <> nil then
        begin
          if GTab.Command <> uucNobody then
          begin
            // The clause changed since the search (a directive, a typo).
            UpdateButtons;
            TellUser('Nothing was removed - an entry cannot be taken out by ' +
              'an edit any more:'#13#10 + string.Join(#13#10,
              AAnswer.Refused) + #13#10'Run the search again.', mtError);
            Exit;
          end;
          // A unit leaving the project while a clause still names it builds
          // only while its file is found: said, and the unit still goes.
          for var LS in AAnswer.Refused do
            LogDiagnostic('an entry stays, remove it by hand: ' + LS);
        end;
        ApplyRemoval(ANodes, AAnswer.Edits, LUnits);
      except
        on E: Exception do
        begin
          UpdateButtons;
          LogDiagnostic(Format('Remove failed: %s: %s', [E.ClassName,
            E.Message]));
        end;
      end;
    end);
end;

{ The nodes of the row selected in the tree - one, or every node under a
  section row: by the row itself (one of the pointers ResultFocusedRow
  offers for it is the one AddCustomMessage handed back), the focused row
  before its parents. By its top-level position only when the top-level row
  itself is focused, or stands for one node: a row under a section must
  never stand for the section - that removed a whole interface clause on
  13.1 (Alex, 2026-10-06). nil when it cannot be told. }
function SelectedNodes: TArray<Integer>;
var
  LChain: TArray<TArray<Pointer>>;
  LTop: Integer;
begin
  Result := nil;
  if not ResultFocusedRow(LChain, LTop) or not Assigned(GTab.RowNode) then
    Exit;
  for var LDepth := 0 to High(LChain) do
    for var LSlot := 0 to High(LChain[LDepth]) do
      if GTab.RowNode.TryGetValue(LChain[LDepth][LSlot], Result) then
      begin
        LspLogToServer(Format('unused units: the selected row told by ' +
          'pointer %d at depth %d - %d node(s)', [LSlot, LDepth,
          Length(Result)]));
        Exit;
      end;
  if (LTop >= 0) and (LTop < Length(GTab.TopNode)) and
     ((Length(LChain) = 1) or (Length(GTab.TopNode[LTop]) = 1)) then
    Result := GTab.TopNode[LTop];
  LspLogToServer(Format('unused units: the selected row is not one of ours ' +
    'by pointer - depth %d, top index %d, %d node(s)', [High(LChain), LTop,
    Length(Result)]));
end;

procedure RemoveClick(ACommand: TUnusedUnitsCommand);
var
  LSelected, LNodes: TArray<Integer>;
begin
  if not UseTab(ACommand) or GTab.Busy then
    Exit;
  try
    LSelected := nil;
    for var LNode in SelectedNodes do
      if (LNode >= 0) and (LNode < NodeCount) and not NodeRemoved(LNode) then
        LSelected := LSelected + [LNode];
    LNodes := nil;
    for var LNode in LSelected do
      if NodeRemovable(LNode) then
        LNodes := LNodes + [LNode];
    if LSelected = nil then
      TellUser('Select a unit in the ' + GTab.Caption + ' tab first: ' +
        'Remove takes out the selected one, Remove All every one.',
        mtInformation)
    else if LNodes = nil then
    begin
      if Length(LSelected) = 1 then
        TellUser(NodeName(LSelected[0]) + IfThen(GTab.Command = uucUnit,
          ' has a note - it stays.', ' has a note on every row - nothing ' +
          'to remove there.'), mtInformation)
      else
        TellUser('Every unit there has a note - nothing to remove.',
          mtInformation);
    end
    else
      StartRemoval(LNodes);
  except
    on E: Exception do
      LogDiagnostic(Format('Remove failed: %s: %s', [E.ClassName, E.Message]));
  end;
end;

procedure RemoveAllClick(ACommand: TUnusedUnitsCommand);
begin
  if not UseTab(ACommand) or GTab.Busy then
    Exit;
  try
    if RemovableNodes <> nil then
      StartRemoval(RemovableNodes);
  except
    on E: Exception do
      LogDiagnostic(Format('Remove All failed: %s: %s', [E.ClassName,
        E.Message]));
  end;
end;

procedure RevertClick(ACommand: TUnusedUnitsCommand);
var
  LDisk: TArray<string>;
  LError: string;
  LProject: IOTAProject;
  LRemoval: TRemoval;
begin
  if not UseTab(ACommand) or GTab.Busy or (GTab.Removals = nil) then
    Exit;
  try
    LRemoval := GTab.Removals[High(GTab.Removals)];
    if LRemoval.Units <> nil then
    begin
      LProject := ProjectByFile(GTab.Answer.ProjectFile);
      if not Assigned(LProject) then
      begin
        TellUser(ExtractFileName(GTab.Answer.ProjectFile) + ' is not open. ' +
          'Nothing was reverted.', mtError);
        Exit;
      end;
    end;
    if not ApplyAll(LRemoval.Edits, False, LDisk, LError) then
    begin
      TellUser(LError, mtError);
      Exit;
    end;
    if LRemoval.Units <> nil then
    begin
      for var LPath in LRemoval.Units do
        try
          LProject.AddFile(LPath, True);
        except
          on E: Exception do
            LogDiagnostic(Format('%s could not be added back: %s',
              [ExtractFileName(LPath), E.Message]));
        end;
      LProject.Save(False, True);
    end;
    // The rows back where they were before that Remove.
    GTab.Answer := LRemoval.Before;
    SetLength(GTab.Removals, Length(GTab.Removals) - 1);
    LspLogToServer(Format('unused units: reverted - %d clause edit(s), %d ' +
      'unit(s) back in the project', [Length(LRemoval.Edits),
      Length(LRemoval.Units)]));
    TellServer(LDisk);
    Report;
    if LRemoval.Nodes <> nil then
      SelectNode(LRemoval.Nodes[0]);
  except
    on E: Exception do
      LogDiagnostic(Format('Revert failed: %s: %s', [E.ClassName, E.Message]));
  end;
end;

{ -------- entry points -------- }

procedure ExecuteUnusedUnits(ACommand: TUnusedUnitsCommand;
  const AView: IOTAEditView);
const
  cWait: array[TUnusedUnitsCommand] of string = (
    'Looking for unused units...',
    'Looking for unused units in the project...',
    'Looking for units nobody uses...');
var
  LFile: string;
  LDone: TLspUnusedProc;
begin
  try
    if not Assigned(AView) or not Assigned(AView.Buffer) or
       not UseTab(ACommand) then
      Exit;
    if GTab.Removals <> nil then
      if MessageDlg('The Removes made from the ' + GTab.Caption + ' tab ' +
        'can still be reverted there. A new search drops that. Search anyway?',
        mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
        Exit;
    LFile := AView.Buffer.FileName;
    ShowWaitDialog(cWait[ACommand]);
    LDone :=
      procedure(ASuccess: Boolean; const AAnswer: TLspUnusedAnswer;
        const AError: string)
      begin
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          CloseWaitDialog;
          LogDiagnostic(AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(AAnswer.Entries) + Length(AAnswer.Units),
          procedure
          begin
            if not UseTab(ACommand) then
              Exit;
            Inc(GTab.Generation);
            GTab.Answer := AAnswer;
            GTab.TitleFile := LFile;
            GTab.Files := nil;
            for var LIdx := 0 to High(AAnswer.Entries) do
              if (LIdx = 0) or not SameText(AAnswer.Entries[LIdx].FilePath,
                AAnswer.Entries[LIdx - 1].FilePath) then
                GTab.Files := GTab.Files + [AAnswer.Entries[LIdx].FilePath];
            GTab.Removals := nil;
            GTab.Busy := False;
            Report;
            // A new search only: after a Remove or a Revert the selection
            // (SelectNode) decides what is in view.
            ResultScrollToTop;
          end);
      end;
    case ACommand of
      uucUnit: LspUnusedUses('unit', LFile, LDone);
      uucProject: LspUnusedUses('project', LFile, LDone);
      uucNobody: LspUnreferencedUnits(LFile, LDone);
    end;
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('unhandled %s: %s', [E.ClassName, E.Message]));
    end;
  end;
end;

// Every tab, its toolbar and its state - not GTab: this also runs once
// GAlive is cleared, when UseTab no longer hands a tab out.
procedure DropGroups;
var
  LMessageServices: IOTAMessageServices;
begin
  for var LTab in GTabs do
  begin
    if not Assigned(LTab) then
      Continue;
    HideResultToolbar(LTab.Caption);
    if Assigned(LTab.Group) and not Application.Terminated and
       Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
      try
        // Only while the tab is still there - see GetOrCreateMessageGroup.
        if Assigned(LMessageServices.GetGroup(LTab.Caption)) then
          LMessageServices.RemoveMessageGroup(
            LMessageServices.GetGroup(LTab.Caption));
      except
        // Cosmetic cleanup; there is no panel left to report a failure to.
      end;
    LTab.Clear;
  end;
end;

procedure CloseUnusedUnitsResults;
begin
  DropGroups;
end;

procedure FinalizeUnusedUnits;
begin
  GAlive := False;
  DropGroups;
  GTab := nil;
  for var LCommand := Low(TUnusedUnitsCommand) to High(TUnusedUnitsCommand) do
    FreeAndNil(GTabs[LCommand]);
end;

end.
