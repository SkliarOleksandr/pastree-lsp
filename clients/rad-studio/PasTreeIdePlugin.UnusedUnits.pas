unit PasTreeIdePlugin.UnusedUnits;

{
  Find All > Unused Units, Unused Units in the Project, Units Nobody Uses -
  PasTree 0.93.0's unused-units checks (PasTree.Sema.Lint, the demo's three
  commands), with the results as a tree in the "PasTree Unused Units" tab
  and a toolbar above it: Remove takes the selected unit out, Remove All
  every one, Revert takes the last Remove back.

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

  REMOVE IS PER NODE, so a unit can be taken out and the project compiled
  before the next one (Alex, 2026-10-06): Remove takes the node selected in
  the tree (RenameToolbar.ResultFocusedRow), Remove All every node left.
  The edits are asked for at the click (pastree/usesRemoval), on the text
  as it is then - not with the search: a unit nobody uses is listed beside
  its siblings in one clause, and an edit computed before the first of
  them went no longer matches the clause it left. All or nothing per
  Remove: every edit is checked against the text before any is made. Open
  modules are edited through one undoable writer each (one Ctrl+Z per
  file) and saved; files nobody has open are rewritten on disk in their own
  encoding (PasLsp.SourceText). For Units Nobody Uses each unit is also
  taken out of the project (IOTAProject.RemoveFile - which edits the .dpr's
  own uses), and the project is saved. A removed node leaves the tree.

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
  cMessageGroupName = 'PasTree Unused Units';
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
  end;

var
  GMessageGroup: IOTAMessageGroup;
  GAlive: Boolean = True;
  GCommand: TUnusedUnitsCommand;
  GAnswer: TLspUnusedAnswer;
  GTitleFile: string;
  // The nodes: for Unused Units the files of GAnswer.Entries in order, for
  // Units Nobody Uses GAnswer.Units' (a node is an index into either).
  GFiles: TArray<string>;
  GRemovals: TArray<TRemoval>;      // in order; Revert takes the last back
  GRowNode: TDictionary<Pointer, Integer> = nil;   // a shown row -> its node
  GTopNode: TArray<Integer>;        // the top-level rows -> node, -1 title
  GBusy: Boolean;                   // a Remove waits for its edits
  GGeneration: Integer;             // a new search or a closed tab

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
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
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
  LSaved: TDictionary<string, Boolean>;
begin
  Result := False;
  ADiskPaths := nil;
  AError := '';
  LTargets := TList<TEditTarget>.Create;
  LRanges := TList<TPair<Integer, Integer>>.Create;
  LOffsets := TList<TArray<Integer>>.Create;
  LSaved := TDictionary<string, Boolean>.Create;
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
      if Assigned(LTarget.Module) then
      begin
        if not LSaved.ContainsKey(LowerCase(LTarget.Module.FileName)) then
        begin
          LSaved.Add(LowerCase(LTarget.Module.FileName), True);
          LTarget.Module.Save(False, True);
        end;
      end
      else if TryWriteSource(LTarget.Path, LTarget.Text, LTarget.Encoding) then
        ADiskPaths := ADiskPaths + [LTarget.Path]
      else
        LogDiagnostic(ExtractFileName(LTarget.Path) +
          ' could not be written - its edit is lost');
    end;
    Result := True;
  finally
    LSaved.Free;
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
  if GCommand = uucNobody then
    Result := Length(GAnswer.Units)
  else
    Result := Length(GFiles);
end;

function NodeRemoved(ANode: Integer): Boolean;
begin
  for var LRemoval in GRemovals do
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
  if GCommand = uucNobody then
    Exit(GAnswer.Units[ANode].Doubts = nil);
  for var LEntry in GAnswer.Entries do
    if SameText(LEntry.FilePath, GFiles[ANode]) and EntryRemovable(LEntry) then
      Exit(True);
  Result := False;
end;

function NodeFile(ANode: Integer): string;
begin
  if GCommand = uucNobody then
    Result := GAnswer.Units[ANode].FilePath
  else
    Result := GFiles[ANode];
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
  SetResultToolbarEnabled(cMessageGroupName, cRemoveButton,
    not GBusy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(cMessageGroupName, cRemoveAllButton,
    not GBusy and (RemovableNodes <> nil));
  SetResultToolbarEnabled(cMessageGroupName, cRevertButton,
    not GBusy and (GRemovals <> nil));
end;

procedure RemoveClick; forward;
procedure RemoveAllClick; forward;
procedure RevertClick; forward;

procedure Report;
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LCache: TObjectDictionary<string, TStringList>;
  LTitle, LCount: string;
  LTop, LRowPtr: Pointer;
  LShown, LRemoved, LCountAt: Integer;

  procedure Note(ANode: Integer; const ALeadIn, AText: string;
    AParent: Pointer);
  begin
    GRowNode.AddOrSetValue(LMessageServices.AddCustomMessage(NewNoteRow(
      ALeadIn, AText), AParent), ANode);
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices)
  then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  if not Assigned(GRowNode) then
    GRowNode := TDictionary<Pointer, Integer>.Create;
  GRowNode.Clear;
  GTopNode := [-1];
  LShown := 0;
  LRemoved := 0;
  for var LNode := 0 to NodeCount - 1 do
    if NodeRemoved(LNode) then
      Inc(LRemoved)
    else if GCommand = uucNobody then
      Inc(LShown)
    else
      for var LEntry in GAnswer.Entries do
        if SameText(LEntry.FilePath, GFiles[LNode]) then
          Inc(LShown);
  LCache := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  try
    case GCommand of
      uucUnit:
        LTitle := 'Unused units in ' + ExtractFileName(GTitleFile) + ': ';
      uucProject:
        LTitle := Format('Unused units in %s (%d units): ',
          [ExtractFileName(GAnswer.ProjectFile), NodeCount - LRemoved]);
    else
      LTitle := 'Units nobody uses in ' + ExtractFileName(GAnswer.ProjectFile) +
        ': ';
    end;
    LCount := IntToStr(LShown);
    LCountAt := Length(LTitle) + 1;
    LTitle := LTitle + LCount;
    if LRemoved > 0 then
      LTitle := LTitle + Format(' - %d %s removed, Revert takes the last ' +
        'Remove back', [LRemoved, IfThen(GCommand = uucNobody, 'units',
        'files')])
    else if (LShown > 0) and (RemovableNodes = nil) then
      LTitle := LTitle + ' - every one has a note, nothing to remove';
    LMessageServices.AddCustomMessage(NewTitleRow(LTitle, LCountAt,
      Length(LCount)), LGroup);

    for var LNode := 0 to NodeCount - 1 do
    begin
      if NodeRemoved(LNode) then
        Continue;
      LTop := LMessageServices.AddCustomMessagePtr(NewFileNameRow(
        NodeFile(LNode)), LGroup);
      GRowNode.AddOrSetValue(LTop, LNode);
      GTopNode := GTopNode + [LNode];
      if GCommand = uucNobody then
      begin
        for var LDoubt in GAnswer.Units[LNode].Doubts do
          Note(LNode, 'kept: ', LDoubt, LTop);
        for var LBy in GAnswer.Units[LNode].ListedBy do
          // Under a header: the Pointer overload, which hands back the row.
          GRowNode.AddOrSetValue(LMessageServices.AddCustomMessage(
            NewSnippetRow(LBy.FilePath, LBy.Row, LBy.Col, SnippetOf(LCache,
            LBy.FilePath, LBy.Row), LBy.Col, LBy.Len, '', LBy.TypeSpans), LTop),
            LNode);
      end
      else
        for var LEntry in GAnswer.Entries do
        begin
          if not SameText(LEntry.FilePath, GFiles[LNode]) then
            Continue;
          LRowPtr := LMessageServices.AddCustomMessage(NewSnippetRow(
            LEntry.FilePath, LEntry.Row, LEntry.Col, SnippetOf(LCache,
            LEntry.FilePath, LEntry.Row), LEntry.Col, LEntry.Len, '',
            LEntry.TypeSpans), LTop);
          GRowNode.AddOrSetValue(LRowPtr, LNode);
          for var LDoubt in LEntry.Doubts do
            Note(LNode, 'kept: ', LDoubt, LRowPtr);
          if (LEntry.Doubts = nil) and (LEntry.Refused <> '') then
            Note(LNode, 'not removable: ', LEntry.Refused, LRowPtr);
        end;
    end;
  finally
    LCache.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
  ShowResultToolbar(cMessageGroupName, [
    ResultToolButton('Remove', 'EditDeleteCommand', RemoveClick),
    ResultToolButton('Remove All', 'EditDeleteCommand', RemoveAllClick),
    ResultToolButton('Revert', 'EditUndoCommand', RevertClick)]);
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

procedure TellServer(const ADiskPaths: TArray<string>);
begin
  LspSyncDocuments;
  if ADiskPaths <> nil then
    LspFilesChangedOnDisk(ADiskPaths);
end;

{ What ANodes' Remove asks pastree/usesRemoval for, and the units it takes
  out of the project. Unused Units: the removable entries of each file.
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
    if GCommand <> uucNobody then
    begin
      for var LNode in ANodes do
        for var LEntry in GAnswer.Entries do
          if SameText(LEntry.FilePath, GFiles[LNode]) and
             EntryRemovable(LEntry) then
            Add(LEntry.FilePath, LEntry.UnitName);
      Exit;
    end;
    for var LNode in ANodes do
    begin
      AUnits := AUnits + [GAnswer.Units[LNode].FilePath];
      LGoing.AddOrSetValue(LowerCase(GAnswer.Units[LNode].FilePath), True);
    end;
    for var LRemoval in GRemovals do
      for var LPath in LRemoval.Units do
        LGoing.AddOrSetValue(LowerCase(LPath), True);
    for var LNode in ANodes do
      for var LBy in GAnswer.Units[LNode].ListedBy do
        if not LBy.IsProgram and
           not LGoing.ContainsKey(LowerCase(LBy.FilePath)) then
          Add(LBy.FilePath, GAnswer.Units[LNode].UnitName);
  finally
    LGoing.Free;
    LByFile.Free;
  end;
end;

// Makes one Remove of ANodes with AEdits (the server's, on the text as it
// is now).
procedure ApplyRemoval(const ANodes: TArray<Integer>;
  const AEdits: TArray<TLspUsesEdit>; const AUnits: TArray<string>);
var
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
  if AUnits <> nil then
  begin
    LProject := ProjectByFile(GAnswer.ProjectFile);
    if not Assigned(LProject) then
      LogDiagnostic(ExtractFileName(GAnswer.ProjectFile) + ' is not open - ' +
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
  GRemovals := GRemovals + [LRemoval];
  LspLogToServer(Format('unused units: Remove %d - %d node(s), %d clause ' +
    'edit(s), %d unit(s) out of the project', [Length(GRemovals),
    Length(ANodes), Length(LRemoval.Edits), Length(LRemoval.Units)]));
  Report;
  TellServer(LDisk);
end;

procedure StartRemoval(const ANodes: TArray<Integer>);
var
  LFiles: TArray<TLspRemovalFile>;
  LUnits: TArray<string>;
  LGeneration: Integer;
begin
  LFiles := RemovalFiles(ANodes, LUnits);
  if LFiles = nil then
  begin
    // A unit only the program names: RemoveFile is all there is to do.
    ApplyRemoval(ANodes, nil, LUnits);
    Exit;
  end;
  GBusy := True;
  UpdateButtons;
  LGeneration := GGeneration;
  LspUsesRemoval(GTitleFile, LFiles,
    procedure(ASuccess: Boolean; const AAnswer: TLspUsesRemovalAnswer;
      const AError: string)
    begin
      if not GAlive or (LGeneration <> GGeneration) then
        Exit;
      GBusy := False;
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
          if GCommand <> uucNobody then
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

{ The node of the row selected in the tree: by the row itself (the
  pointers AddCustomMessage handed back), else by its top-level position.
  -1 when it cannot be told. }
function SelectedNode: Integer;
var
  LChain: TArray<Pointer>;
  LTop: Integer;
begin
  Result := -1;
  if not ResultFocusedRow(LChain, LTop) then
    Exit;
  for var LPtr in LChain do
    if Assigned(GRowNode) and GRowNode.TryGetValue(LPtr, Result) then
      Exit;
  if (LTop >= 0) and (LTop < Length(GTopNode)) then
    Result := GTopNode[LTop];
  LspLogToServer(Format('unused units: the selected row is not one of ours ' +
    'by pointer - top index %d, node %d', [LTop, Result]));
end;

procedure RemoveClick;
var
  LNode: Integer;
begin
  if not GAlive or GBusy then
    Exit;
  try
    LNode := SelectedNode;
    if (LNode < 0) or (LNode >= NodeCount) or NodeRemoved(LNode) then
      TellUser('Select a unit in the Unused Units tab first: Remove takes ' +
        'out the selected one, Remove All every one.', mtInformation)
    else if not NodeRemovable(LNode) then
      TellUser(ExtractFileName(NodeFile(LNode)) + ' has a note on every row ' +
        '- nothing to remove there.', mtInformation)
    else
      StartRemoval([LNode]);
  except
    on E: Exception do
      LogDiagnostic(Format('Remove failed: %s: %s', [E.ClassName, E.Message]));
  end;
end;

procedure RemoveAllClick;
begin
  if not GAlive or GBusy then
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

procedure RevertClick;
var
  LDisk: TArray<string>;
  LError: string;
  LProject: IOTAProject;
  LRemoval: TRemoval;
begin
  if not GAlive or GBusy or (GRemovals = nil) then
    Exit;
  try
    LRemoval := GRemovals[High(GRemovals)];
    if LRemoval.Units <> nil then
    begin
      LProject := ProjectByFile(GAnswer.ProjectFile);
      if not Assigned(LProject) then
      begin
        TellUser(ExtractFileName(GAnswer.ProjectFile) + ' is not open. ' +
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
    SetLength(GRemovals, Length(GRemovals) - 1);
    LspLogToServer(Format('unused units: reverted - %d clause edit(s), %d ' +
      'unit(s) back in the project', [Length(LRemoval.Edits),
      Length(LRemoval.Units)]));
    Report;
    TellServer(LDisk);
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
    if not Assigned(AView) or not Assigned(AView.Buffer) then
      Exit;
    if GRemovals <> nil then
      if MessageDlg('The Removes made from the Unused Units tab can still ' +
        'be reverted there. A new search drops that. Search anyway?',
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
            Inc(GGeneration);
            GCommand := ACommand;
            GAnswer := AAnswer;
            GTitleFile := LFile;
            GFiles := nil;
            for var LIdx := 0 to High(AAnswer.Entries) do
              if (LIdx = 0) or not SameText(AAnswer.Entries[LIdx].FilePath,
                AAnswer.Entries[LIdx - 1].FilePath) then
                GFiles := GFiles + [AAnswer.Entries[LIdx].FilePath];
            GRemovals := nil;
            GBusy := False;
            Report;
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

procedure DropGroup;
var
  LMessageServices: IOTAMessageServices;
begin
  HideResultToolbar(cMessageGroupName);
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // Cosmetic cleanup; there is no panel left to report a failure to.
    end;
  Inc(GGeneration);
  GMessageGroup := nil;
  GAnswer := Default(TLspUnusedAnswer);
  GFiles := nil;
  GRemovals := nil;
  GTopNode := nil;
  GBusy := False;
  if Assigned(GRowNode) then
    GRowNode.Clear;
end;

procedure CloseUnusedUnitsResults;
begin
  DropGroup;
end;

procedure FinalizeUnusedUnits;
begin
  GAlive := False;
  DropGroup;
  FreeAndNil(GRowNode);
end;

end.
