unit PasTreeIdePlugin.FindHierarchy;

{
  Find Overrides and Find Implementations - the two hierarchy commands of the
  editor's local menu, next to Find References (see PasTreeIdePlugin.Wizard).

  Two commands for two identities, as PasTree draws the line
  (docs/editor-features.md sections 4 and 5 there):

    - Find Overrides: the caret is on a CLASS method. The answer is its VMT
      chain across the closure - the declaration that introduced the slot
      (root), every override below it, a reintroduce (reported so a reader
      does not mistake it for an override) and a message handler (implicitly
      virtual). No call site is a row: this is not a reference search.

      Also a CLASS PROPERTY, where the same command answers a different
      chain: a bare `property Items;` republishing an inherited property is
      the same property, so the rows are its declarations and carry the kind
      `redeclared`. Nothing here branches on that - the row's kind word is
      painted as it arrives (see RowTag), which is why supporting it needed
      no code, only a message that stops saying "no class method".
    - Find Implementations: the caret is on an INTERFACE method. The answer
      is every class listing that interface or a descendant of it, with a
      class that satisfies the method through an ANCESTOR reported on the
      ancestor's declaration - the code that runs - and the listing class
      named beside it.

  Both run out of process (pastree/findOverrides, pastree/findImplementations
  via PasTreeIdePlugin.LspSession), across the project group the way Find
  References does since 0.32.0, and report into a tab of their own in the
  Messages panel, shaped exactly like the Find References tab - the rows come
  from PasTreeIdePlugin.ResultRows. What differs is the label after each
  snippet: the type declaring the row and its kind ("TDerived (override)"),
  the thing a reader of a chain navigates by, where the references tab says
  only "declaration".

  WHY THE MENU ITEMS ARE ALWAYS ENABLED. PasTree gates its own demo's items on
  MethodAt/InterfaceMethodAt, so a caret on a field never offers the command.
  This package cannot: the verdict lives in the server, OnUpdate runs on the
  menu's popup on the main thread, and an answer that arrives after the menu
  is drawn is no gate. So the item is offered wherever an editor is, and a
  caret that is not the right kind of method gets a one-line message box -
  the same shape Find References uses for "no identifier under the cursor".
  A method nothing overrides is NOT that case: it answers with its own single
  root row, which is the honest "nothing overrides this".

  Snippets come from the SERVER'S answer, not from LspSourceTextOf as the
  references tab reads them: a row may sit in a unit this IDE never opened and
  never sent, and the server holds the text it analyzed either way.
}

interface

uses
  ToolsAPI;

/// <summary>Entry point of the "Find Overrides" editor menu action.</summary>
procedure ExecuteFindOverrides(const AView: IOTAEditView);

/// <summary>Entry point of the "Find Implementations" editor menu action.</summary>
procedure ExecuteFindImplementations(const AView: IOTAEditView);

/// <summary>
/// Removes both result tabs and closes the callback gate. Call once from
/// TIDEWizard.Destroy, BEFORE FinalizeLspSession, for the reason
/// PasTreeIdePlugin.FindReferences gives for its own: a request answered
/// during unload must find nothing left to paint into.
/// </summary>
procedure FinalizeFindHierarchyMessageGroups;

/// <summary>
/// Drops both result tabs because the project they describe is closing - the
/// same hygiene CloseFindReferencesResults performs, for the same reason:
/// rows into a project that is no longer loaded are indistinguishable from a
/// fresh search.
/// </summary>
procedure CloseFindHierarchyResults;

implementation

uses
  System.SysUtils, System.Generics.Collections,
  Vcl.Dialogs, Vcl.Forms,
  ToolsAPI.UI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog;

type
  THierarchyCommand = (hcOverrides, hcImplementations);

const
  cGroupName: array[THierarchyCommand] of string =
    ('Find Overrides', 'Find Implementations');
  cCommandName: array[THierarchyCommand] of string =
    ('Find Overrides', 'Find Implementations');
  cWaitText: array[THierarchyCommand] of string =
    ('Searching overrides...', 'Searching implementations...');
  cNotSubject: array[THierarchyCommand] of string =
    ('No class method or property under the cursor.' + sLineBreak + sLineBreak +
     'Find Overrides works on a method of a class - the declaration or its ' +
     'implementation header - and on a class property, whose chain is its ' +
     'redeclarations.',
     'No interface method under the cursor.' + sLineBreak + sLineBreak +
     'Find Implementations works on a method declared in an interface type.');

var
  GMessageGroup: array[THierarchyCommand] of IOTAMessageGroup;
  // The teardown gate - see PasTreeIdePlugin.FindReferences.GAlive for the
  // crash it prevents (rows whose vtables live in a BPL being unloaded).
  GAlive: Boolean = True;

function GetOrCreateMessageGroup(ACommand: THierarchyCommand;
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup[ACommand]) then
    GMessageGroup[ACommand] := AMessageServices.GetGroup(cGroupName[ACommand]);
  if not Assigned(GMessageGroup[ACommand]) then
    GMessageGroup[ACommand] :=
      AMessageServices.AddMessageGroup(cGroupName[ACommand]);
  Result := GMessageGroup[ACommand];
end;

{ Not at IDE shutdown, and silently - the same two rules FindReferences
  learned from the AVs of 2026-08-22/24: by the time a designtime package is
  unloaded with the IDE closing, the Messages panel is gone and RemoveMessageGroup
  faults inside the IDE. }
procedure RemoveGroups;
var
  LMessageServices: IOTAMessageServices;
  LCommand: THierarchyCommand;
begin
  if not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    for LCommand := Low(THierarchyCommand) to High(THierarchyCommand) do
      if Assigned(GMessageGroup[LCommand]) then
        try
          LMessageServices.RemoveMessageGroup(GMessageGroup[LCommand]);
        except
          // Cosmetic cleanup; nothing to report to and nowhere to report it.
        end;
  for LCommand := Low(THierarchyCommand) to High(THierarchyCommand) do
    GMessageGroup[LCommand] := nil;
end;

procedure FinalizeFindHierarchyMessageGroups;
begin
  GAlive := False;   // callbacks stop here, not later
  RemoveGroups;
end;

procedure CloseFindHierarchyResults;
begin
  RemoveGroups;   // GAlive untouched: the package lives on, the next search must work
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

/// <summary>
/// The label painted after a row's snippet, in the place the references tab
/// writes "declaration": the type that declares the row, then its kind - so a
/// chain reads "TBase (root)", "TDerived (override)", "TOther (reintroduce)",
/// and implementors "IFoo (interface)", "TFoo", "TInterfacedObject (inherited
/// via TFoo)". A plain implementor gets no kind word: it is the ordinary row,
/// and labelling every one would bury the two that are not.
/// </summary>
function RowTag(ACommand: THierarchyCommand;
  const ARow: TLspHierarchyRow): string;
begin
  Result := ARow.TypeName;
  if ACommand = hcOverrides then
  begin
    if ARow.Kind <> '' then
      Result := Result + ' (' + ARow.Kind + ')';
  end
  else if SameText(ARow.Kind, 'root') then
    Result := Result + ' (interface)'
  else if SameText(ARow.Kind, 'inherited') then
  begin
    if ARow.ViaTypeName <> '' then
      Result := Result + ' (inherited via ' + ARow.ViaTypeName + ')'
    else
      Result := Result + ' (inherited)';
  end
  else if not SameText(ARow.Kind, 'implementor') and (ARow.Kind <> '') then
    Result := Result + ' (' + ARow.Kind + ')';
  Result := Trim(Result);
end;

/// <summary>
/// Fills the command's tab: a title row, one header per file, one snippet row
/// per declaration. ROOT ROWS GO FIRST, and with them their file's header: the
/// merged answer is sorted by path, which would put the chain's origin
/// wherever the alphabet does, and a reader of "who overrides this" looks for
/// where it starts. Within a file the rows keep their sorted order.
/// </summary>
procedure ReportRows(ACommand: THierarchyCommand; const AName: string;
  const ARows: TArray<TLspHierarchyRow>;
  AProjectsSearched, AProjectsInGroup: Integer);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LRow: TLspHierarchyRow;
  LTitleHead, LTitleCount, LScope: string;
  LUnits: Integer;

  procedure CountFile(const AFilePath: string);
  var
    LKey: string;
    LExisting: Integer;
  begin
    LKey := LowerCase(AFilePath);
    LFileCounts.TryGetValue(LKey, LExisting);
    LFileCounts.AddOrSetValue(LKey, LExisting + 1);
  end;

  function GetOrCreateFileHeader(const AFilePath: string): Pointer;
  var
    LKey: string;
    LFileCount: Integer;
  begin
    LKey := LowerCase(AFilePath);
    if not LFileHeaders.TryGetValue(LKey, Result) then
    begin
      LFileCounts.TryGetValue(LKey, LFileCount);
      Result := LMessageServices.AddCustomMessagePtr(
        NewFileHeaderRow(AFilePath, LFileCount), LGroup);
      LFileHeaders.Add(LKey, Result);
    end;
  end;

  { The snippet is the server's line, highlighted where the server says the
    name is (0-based HiFrom/HiTo into that same text). Verified against the
    name before painting, as the references tab does: a span that does not
    read as the identifier degrades to no highlight, never to a highlight on
    the wrong characters. }
  procedure AddRow(const ARow: TLspHierarchyRow);
  var
    LDisplay: string;
    LMatchStart, LMatchLen: Integer;
  begin
    LDisplay := TrimRight(ARow.Snippet);
    LMatchStart := ARow.HiFrom + 1;
    LMatchLen := ARow.HiTo - ARow.HiFrom;
    if (LMatchLen <= 0) or (LMatchStart < 1) or
       (LMatchStart + LMatchLen - 1 > Length(LDisplay)) or
       not SameText(Copy(LDisplay, LMatchStart, LMatchLen), AName) then
    begin
      LMatchStart := 0;
      LMatchLen := 0;
    end;
    LMessageServices.AddCustomMessage(
      NewSnippetRow(ARow.Hit.FilePath, ARow.Hit.Row, ARow.Hit.Col, LDisplay,
        LMatchStart, LMatchLen, RowTag(ACommand, ARow)),
      GetOrCreateFileHeader(ARow.Hit.FilePath));
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(ACommand, LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  LFileCounts := TDictionary<string, Integer>.Create;
  LFileHeaders := TDictionary<string, Pointer>.Create;
  try
    for LRow in ARows do
      CountFile(LRow.Hit.FilePath);
    LUnits := LFileCounts.Count;

    // "5 declaration(s) in 3 units" - the unit count is the answer to "did
    // it only search the current file?", the question PasTree's own demo
    // puts in its tab caption for exactly this reason.
    LTitleHead := Format('PasTree %s: "%s" - ', [cCommandName[ACommand], AName]);
    LScope := '';
    if AProjectsInGroup > 1 then
      LScope := Format(' across %d of %d projects',
        [AProjectsSearched, AProjectsInGroup]);
    LTitleCount := IntToStr(Length(ARows));
    LMessageServices.AddCustomMessagePtr(
      NewTitleRow(LTitleHead + LTitleCount +
        Format(' declaration(s) in %d unit(s)', [LUnits]) + LScope,
        Length(LTitleHead) + 1, Length(LTitleCount)), LGroup);

    for LRow in ARows do
      if SameText(LRow.Kind, 'root') then
        AddRow(LRow);
    for LRow in ARows do
      if not SameText(LRow.Kind, 'root') then
        AddRow(LRow);
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;

  LMessageServices.ShowMessageView(LGroup);
end;

procedure Execute(ACommand: THierarchyCommand; const AView: IOTAEditView);
var
  LCursorFile: string;
  LRow, LCol: Integer;
  LOnDone: TLspHierarchyProc;
begin
  try
    if not Assigned(AView) then
      Exit;

    LCursorFile := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;

    // Visible progress, closed FIRST on every terminal path below: the
    // dialog disables input, and a message box over disabled input is a
    // stuck IDE (the Find References lesson of 2026-08-31).
    ShowWaitDialog(cWaitText[ACommand]);
    LOnDone :=
      procedure(ASuccess, AIsSubject: Boolean; const AName: string;
        const ARows: TArray<TLspHierarchyRow>;
        AProjectsSearched, AProjectsInGroup: Integer; const AError: string)
      begin
        if not GAlive then
          Exit;   // package unloading - nothing here may touch the IDE
        CloseWaitDialog;
        if not ASuccess then
        begin
          LogDiagnostic(cCommandName[ACommand] + ': ' + AError);
          Exit;
        end;
        if not AIsSubject then
        begin
          (BorlandIDEServices as INTAIDEUIServices).MessageDlg(
            cNotSubject[ACommand], mtInformation, [mbOK], -1);
          Exit;
        end;
        ReportRows(ACommand, AName, ARows, AProjectsSearched, AProjectsInGroup);
      end;
    case ACommand of
      hcOverrides:
        LspFindOverridesInGroup(LCursorFile, LRow, LCol, LOnDone);
      hcImplementations:
        LspFindImplementationsInGroup(LCursorFile, LRow, LCol, LOnDone);
    end;
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('%s: unhandled %s: %s',
        [cCommandName[ACommand], E.ClassName, E.Message]));
    end;
  end;
end;

procedure ExecuteFindOverrides(const AView: IOTAEditView);
begin
  Execute(hcOverrides, AView);
end;

procedure ExecuteFindImplementations(const AView: IOTAEditView);
begin
  Execute(hcImplementations, AView);
end;

end.
