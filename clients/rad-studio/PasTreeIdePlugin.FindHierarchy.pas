unit PasTreeIdePlugin.FindHierarchy;

{
  The Find All family of the editor's local menu, less Find References (which
  keeps its own unit, PasTreeIdePlugin.FindReferences, and its own snippet
  source): Overrides, Implementations, Descendants, Assignments, Creations,
  Destructions. Since 0.37.0 all seven sit under one "Find All" submenu - see
  PasTreeIdePlugin.Wizard - the way PasTree's own demo groups them.

  Six commands for six identities, as PasTree draws the lines
  (docs/editor-features.md sections 4 to 8 there):

    - Overrides: the caret is on a CLASS method. The answer is its VMT chain
      across the closure - the declaration that introduced the slot (root),
      every override below it, a reintroduce (reported so a reader does not
      mistake it for an override) and a message handler (implicitly
      virtual). No call site is a row: this is not a reference search.
      Also a CLASS PROPERTY, where the same command answers a different
      chain: a bare `property Items;` republishing an inherited property is
      the same property, so the rows are its declarations and carry the kind
      `redeclared`.
    - Implementations: the caret is on an INTERFACE method - every class
      listing that interface, with a class that satisfies the method through
      an ANCESTOR reported on the ancestor's declaration and the listing
      class named beside it - or on the interface TYPE name itself, where
      the answer is one row per class that lists it. Two entry points, one
      command, one server method. A class listing a DESCENDANT interface is
      not a row (PasTree 0.25.0): the interfaces below one are Descendants'
      answer, the child's implementors this command on the child.
    - Descendants: the caret is on a CLASS or INTERFACE type name - every
      type below it, transitively. THIS ONE IS A TREE, and is painted as
      one: the root row at the top of the tab and every descendant nested
      under the row of its direct ancestor, to any depth, each row spelling
      its own unit. No file grouping here - a hierarchy grouped by file is
      two trees fighting over one indentation, which is exactly what
      PasTree's demo shows when it indents by depth inside file groups.
    - Assignments: the caret is on something WRITABLE - a variable, field,
      parameter, or property with a `write` specifier. The answer is the
      writes to it (the left side of `:=`, a `for` counter), the declaration
      pinned first as the references tab pins it.
    - Creations / Destructions: the caret is on a CLASS. Every
      `TFoo.Create(...)` constructing exactly that class; every `X.Free` /
      `X.Destroy` / `FreeAndNil(X)` where X's static type is exactly that
      class. PasTree's own doc names the gaps (a descendant's constructor, a
      class-reference variable, an owner freeing the instance).

  All six run out of process (one pastree/find* method each, via
  PasTreeIdePlugin.LspSession.LspFindAllInGroup), across the project group
  the way Find References does since 0.32.0, and report into a tab of their
  own in the Messages panel - the rows come from PasTreeIdePlugin.ResultRows,
  and the label after a snippet follows the references tab exactly: the row
  the search started from is tagged "definition" and no other row is tagged
  at all (see RowTag for what that label used to say and why it went).

  THE MENU ITEMS ARE GATED ON THE CARET SINCE 0.37.0, the way PasTree's demo
  gates its own: one synchronous pastree/findAllAt on the submenu's OnUpdate,
  with a short budget (PasTreeIdePlugin.Wizard). When the server does not
  answer in time every item stays enabled and the command itself is the gate,
  as it was before: a caret that is not the right kind of thing gets a
  one-line message box - the same shape Find References uses for "no
  identifier under the cursor". A method nothing overrides is NOT that case:
  it answers with its own single root row, which is the honest "nothing
  overrides this".

  Snippets come from the SERVER'S answer, not from LspSourceTextOf as the
  references tab reads them: a row may sit in a unit this IDE never opened and
  never sent, and the server holds the text it analyzed either way.
}

interface

uses
  ToolsAPI;

type
  /// <summary>
  /// The six commands of this unit, in the submenu's order. Find References
  /// is not one of them - it has its own unit - but it is the submenu's first
  /// item, which is why the Wizard's gate record has one flag more.
  /// </summary>
  TFindAllCommand = (facOverrides, facImplementations, facDescendants,
    facAssignments, facCreations, facDestructions);

/// <summary>Entry point of one "Find All" submenu action.</summary>
procedure ExecuteFindAll(ACommand: TFindAllCommand; const AView: IOTAEditView);

/// <summary>
/// Removes every result tab and closes the callback gate. Call once from
/// TIDEWizard.Destroy, BEFORE FinalizeLspSession, for the reason
/// PasTreeIdePlugin.FindReferences gives for its own: a request answered
/// during unload must find nothing left to paint into.
/// </summary>
procedure FinalizeFindHierarchyMessageGroups;

/// <summary>
/// Drops every result tab because the project they describe is closing - the
/// same hygiene CloseFindReferencesResults performs, for the same reason:
/// rows into a project that is no longer loaded are indistinguishable from a
/// fresh search.
/// </summary>
procedure CloseFindHierarchyResults;

implementation

uses
  System.SysUtils, System.Character, System.Generics.Collections,
  Vcl.Dialogs, Vcl.Forms,
  ToolsAPI.UI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog;

const
  cMethod: array[TFindAllCommand] of string =
    ('pastree/findOverrides', 'pastree/findImplementations',
     'pastree/findDescendants', 'pastree/findAssignments',
     'pastree/findCreations', 'pastree/findDestructions');
  // The tab's name and the command's name are one string: "Find Overrides"
  // is what the submenu item reads as when its parent's caption is joined
  // to it, and a tab called anything else would not be found by eye.
  cCommandName: array[TFindAllCommand] of string =
    ('Find Overrides', 'Find Implementations', 'Find Descendants',
     'Find Assignments', 'Find Creations', 'Find Destructions');
  cWaitText: array[TFindAllCommand] of string =
    ('Searching overrides...', 'Searching implementations...',
     'Searching descendants...', 'Searching assignments...',
     'Searching creations...', 'Searching destructions...');
  // What the title row counts: a chain and a hierarchy list declarations, a
  // site search lists sites.
  cRowNoun: array[TFindAllCommand] of string =
    ('declaration(s)', 'declaration(s)', 'type(s)', 'assignment(s)',
     'creation(s)', 'destruction(s)');
  cNotSubject: array[TFindAllCommand] of string =
    ('No class method or property under the cursor.' + sLineBreak + sLineBreak +
     'Find Overrides works on a method of a class - the declaration or its ' +
     'implementation header - and on a class property, whose chain is its ' +
     'redeclarations.',
     'No interface or interface method under the cursor.' + sLineBreak +
     sLineBreak +
     'Find Implementations works on a method declared in an interface type ' +
     '(who implements this method) and on the interface''s own name (which ' +
     'classes implement it).',
     'No class or interface type under the cursor.' + sLineBreak + sLineBreak +
     'Find Descendants works on the name of a class, an object type or an ' +
     'interface - its declaration or any use of it.',
     'Nothing assignable under the cursor.' + sLineBreak + sLineBreak +
     'Find Assignments works on a variable, a field, a parameter or a ' +
     'property with a write specifier. A constant, a type, a routine and a ' +
     'read-only property have no assignments to find.',
     'No class under the cursor.' + sLineBreak + sLineBreak +
     'Find Creations works on the name of a class or object type - the ' +
     'places an instance of exactly that class is constructed.',
     'No class under the cursor.' + sLineBreak + sLineBreak +
     'Find Destructions works on the name of a class or object type - the ' +
     'places a variable of exactly that static type is freed.');

var
  GMessageGroup: array[TFindAllCommand] of IOTAMessageGroup;
  // The teardown gate - see PasTreeIdePlugin.FindReferences.GAlive for the
  // crash it prevents (rows whose vtables live in a BPL being unloaded).
  GAlive: Boolean = True;

function GetOrCreateMessageGroup(ACommand: TFindAllCommand;
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup[ACommand]) then
    GMessageGroup[ACommand] :=
      AMessageServices.GetGroup(cCommandName[ACommand]);
  if not Assigned(GMessageGroup[ACommand]) then
    GMessageGroup[ACommand] :=
      AMessageServices.AddMessageGroup(cCommandName[ACommand]);
  Result := GMessageGroup[ACommand];
end;

{ Not at IDE shutdown, and silently - the same two rules FindReferences
  learned from the AVs of 2026-08-22/24: by the time a designtime package is
  unloaded with the IDE closing, the Messages panel is gone and RemoveMessageGroup
  faults inside the IDE. }
procedure RemoveGroups;
var
  LMessageServices: IOTAMessageServices;
  LCommand: TFindAllCommand;
begin
  if not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    for LCommand := Low(TFindAllCommand) to High(TFindAllCommand) do
      if Assigned(GMessageGroup[LCommand]) then
        try
          LMessageServices.RemoveMessageGroup(GMessageGroup[LCommand]);
        except
          // Cosmetic cleanup; nothing to report to and nowhere to report it.
        end;
  for LCommand := Low(TFindAllCommand) to High(TFindAllCommand) do
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
  // Into the server's log as well: the Build tab is where the IDE puts it, the
  // log is where anyone diagnosing a report actually looks (2026-09-10).
  LspLogToServer(AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function IsRootRow(const ARow: TLspHierarchyRow): Boolean;
begin
  Result := SameText(ARow.Kind, 'root') or SameText(ARow.Kind, 'declaration');
end;

/// <summary>
/// The label painted after a row's snippet, in the place the references tab
/// writes "declaration": "definition" on the one row the search started from
/// and NOTHING on any other, for every command alike.
///
/// It used to name the row's own type and kind - "TDerived (override)",
/// "TEnumerator", "TShape (root)". Every one of those repeated what the
/// snippet beside it already spelled out (user, 2026-09-10, over a Find
/// Implementations list where each row read "... class(TInterfacedObject,
/// IEnumerator ...)  (TEnumerator)"), and a label on every row labels
/// nothing. The kind survives where it carries weight: the tree's shape for
/// findDescendants, the grouping for the rest - not as a word per line.
/// </summary>
function RowTag(const ARow: TLspHierarchyRow): string;
begin
  if IsRootRow(ARow) then
    Result := 'definition'
  else
    Result := '';
end;

{ The snippet is the server's line, highlighted where the server says the
  name is (0-based HiFrom/HiTo into that same text). Verified against the
  name before painting, as the references tab does: a span that does not
  read as the identifier degrades to no highlight, never to a highlight on
  the wrong characters. }
{ 1-based position of AName in ALine as a whole identifier - not inside a
  longer one (IFoo in IFooBar is no match) - case-insensitively, as Pascal
  reads names; 0 when absent. }
function IdentifierPos(const ALine, AName: string): Integer;
var
  LStart, LBefore, LAfter: Integer;

  function IsIdentChar(AChar: Char): Boolean;
  begin
    Result := AChar.IsLetterOrDigit or (AChar = '_');
  end;

begin
  Result := 0;
  if AName = '' then
    Exit;
  LStart := 1;
  repeat
    LStart := Pos(LowerCase(AName), LowerCase(ALine), LStart);
    if LStart = 0 then
      Exit;
    LBefore := LStart - 1;
    LAfter := LStart + Length(AName);
    if ((LBefore < 1) or not IsIdentChar(ALine[LBefore])) and
       ((LAfter > Length(ALine)) or not IsIdentChar(ALine[LAfter])) then
      Exit(LStart);
    Inc(LStart);
  until False;
end;

function SnippetRowFor(const AName: string;
  const ARow: TLspHierarchyRow): IOTACustomMessage;
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
    // The server's span marks the ROW's own name - the implementing class,
    // the descendant, the freed variable - which is the navigation target,
    // not the thing searched for. The reader scans for the thing searched
    // for (user, 2026-09-10: "paint the name I searched, as References
    // does"), so the marker goes on its first whole-word occurrence in the
    // line instead; a line that does not spell it at all stays unmarked.
    LMatchStart := IdentifierPos(LDisplay, AName);
    if LMatchStart > 0 then
      LMatchLen := Length(AName)
    else
      LMatchLen := 0;
  end;
  Result := NewSnippetRow(ARow.Hit.FilePath, ARow.Hit.Row, ARow.Hit.Col,
    LDisplay, LMatchStart, LMatchLen, RowTag(ARow));
end;

function DistinctFileCount(const ARows: TArray<TLspHierarchyRow>): Integer;
var
  LFiles: TDictionary<string, Boolean>;
  LRow: TLspHierarchyRow;
begin
  LFiles := TDictionary<string, Boolean>.Create;
  try
    for LRow in ARows do
      LFiles.AddOrSetValue(LowerCase(LRow.Hit.FilePath), True);
    Result := LFiles.Count;
  finally
    LFiles.Free;
  end;
end;

procedure AddTitleRowFor(const AMessageServices: IOTAMessageServices;
  const AGroup: IOTAMessageGroup; ACommand: TFindAllCommand;
  const AName: string; ACount, AUnits, AProjectsSearched,
  AProjectsInGroup: Integer);
var
  LTitleHead, LTitleCount, LScope: string;
begin
  // "5 declaration(s) in 3 unit(s)" - the unit count is the answer to "did
  // it only search the current file?", the question PasTree's own demo
  // puts in its tab caption for exactly this reason.
  LTitleHead := Format('PasTree %s: "%s" - ', [cCommandName[ACommand], AName]);
  LScope := '';
  if AProjectsInGroup > 1 then
    LScope := Format(' across %d of %d projects',
      [AProjectsSearched, AProjectsInGroup]);
  LTitleCount := IntToStr(ACount);
  AMessageServices.AddCustomMessagePtr(
    NewTitleRow(LTitleHead + LTitleCount +
      Format(' %s in %d unit(s)', [cRowNoun[ACommand], AUnits]) + LScope,
      Length(LTitleHead) + 1, Length(LTitleCount)), AGroup);
end;

/// <summary>
/// Fills a chain or site tab: a title row, one header per file, one snippet
/// row per declaration or site. ROOT ROWS GO FIRST, and with them their file's
/// header: the merged answer is sorted by path, which would put the chain's
/// origin - or the pinned declaration - wherever the alphabet does, and a
/// reader of "who overrides this" looks for where it starts. Within a file
/// the rows keep their sorted order.
/// </summary>
procedure ReportGrouped(ACommand: TFindAllCommand; const AName: string;
  const ARows: TArray<TLspHierarchyRow>;
  AProjectsSearched, AProjectsInGroup: Integer);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LRow: TLspHierarchyRow;
  LSites: Integer;

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

    // A chain counts every row (the root is a declaration too); a site
    // search counts the sites, not the pinned declaration - "0 assignment(s)"
    // with one row on screen is the honest reading of "nothing assigns this".
    LSites := Length(ARows);
    if ACommand in [facAssignments, facCreations, facDestructions] then
      for LRow in ARows do
        if IsRootRow(LRow) then
          Dec(LSites);
    AddTitleRowFor(LMessageServices, LGroup, ACommand, AName, LSites,
      LFileCounts.Count, AProjectsSearched, AProjectsInGroup);

    for LRow in ARows do
      if IsRootRow(LRow) then
        LMessageServices.AddCustomMessage(SnippetRowFor(AName, LRow),
          GetOrCreateFileHeader(LRow.Hit.FilePath));
    for LRow in ARows do
      if not IsRootRow(LRow) then
        LMessageServices.AddCustomMessage(SnippetRowFor(AName, LRow),
          GetOrCreateFileHeader(LRow.Hit.FilePath));
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;

  LMessageServices.ShowMessageView(LGroup);
end;

/// <summary>
/// Fills the Descendants tab as a TREE: the root type at the top level, every
/// descendant nested under the row of its direct ancestor - the panel nests
/// to any depth through the Pointer AddCustomMessage returns, the same
/// mechanism Find in Files uses for file/line. No file headers: each row's
/// own "Unit.pas (line):" prefix says where it lives, and grouping a
/// hierarchy by file would break it into one fragment per unit.
///
/// THE TREE IS REBUILT FROM ParentTypeName, NOT TRUSTED FROM ORDER. The
/// server's rows arrive breadth-first, but the group-wide merge sorted them
/// by path, so the order carries nothing any more; what does survive is each
/// row's ancestor name and depth. A row is attached to the row of Depth-1
/// whose TypeName is its ParentTypeName - a second same-named type at another
/// depth cannot be mistaken for it - and one whose parent is not in the
/// answer at all (the merge dropped a duplicate, or another project's closure
/// ended a level up) is attached to the root rather than lost. Rows are
/// walked depth by depth so a parent always exists before its children.
/// </summary>
procedure ReportTree(ACommand: TFindAllCommand; const AName: string;
  const ARows: TArray<TLspHierarchyRow>;
  AProjectsSearched, AProjectsInGroup: Integer);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LByDepth: TDictionary<string, Pointer>;   // key: depth + #0 + lowercase name
  LRow: TLspHierarchyRow;
  LRootPtr, LParentPtr, LThisPtr: Pointer;
  LDepth, LMaxDepth, LDescendants: Integer;
  LPlaced: Boolean;

  function KeyOf(ADepth: Integer; const ATypeName: string): string;
  begin
    Result := IntToStr(ADepth) + #0 + LowerCase(ATypeName);
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(ACommand, LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  LDescendants := 0;
  LMaxDepth := 0;
  for LRow in ARows do
  begin
    if not IsRootRow(LRow) then
      Inc(LDescendants);
    if LRow.Depth > LMaxDepth then
      LMaxDepth := LRow.Depth;
  end;
  AddTitleRowFor(LMessageServices, LGroup, ACommand, AName, LDescendants,
    DistinctFileCount(ARows), AProjectsSearched, AProjectsInGroup);

  LByDepth := TDictionary<string, Pointer>.Create;
  try
    // The root first, as the tree's one top-level row. A merged answer holds
    // exactly one (every project's root is the same declaration and the
    // merge de-duplicates by position); should none survive, the descendants
    // become top-level rows themselves rather than vanish.
    LRootPtr := nil;
    for LRow in ARows do
      if IsRootRow(LRow) then
      begin
        LRootPtr := LMessageServices.AddCustomMessagePtr(
          SnippetRowFor(AName, LRow), LGroup);
        LByDepth.AddOrSetValue(KeyOf(0, LRow.TypeName), LRootPtr);
        Break;
      end;

    for LDepth := 1 to LMaxDepth do
      for LRow in ARows do
      begin
        if IsRootRow(LRow) or (LRow.Depth <> LDepth) then
          Continue;
        LPlaced := LByDepth.TryGetValue(KeyOf(LDepth - 1, LRow.ParentTypeName),
          LParentPtr);
        if not LPlaced then
          LParentPtr := LRootPtr;
        if LParentPtr <> nil then
          LThisPtr := LMessageServices.AddCustomMessage(
            SnippetRowFor(AName, LRow), LParentPtr)
        else
          LThisPtr := LMessageServices.AddCustomMessagePtr(
            SnippetRowFor(AName, LRow), LGroup);
        LByDepth.AddOrSetValue(KeyOf(LDepth, LRow.TypeName), LThisPtr);
      end;
  finally
    LByDepth.Free;
  end;

  LMessageServices.ShowMessageView(LGroup);
end;

procedure ExecuteFindAll(ACommand: TFindAllCommand; const AView: IOTAEditView);
var
  LCursorFile: string;
  LRow, LCol: Integer;
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
    LspFindAllInGroup(cMethod[ACommand], LCursorFile, LRow, LCol,
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
        if ACommand = facDescendants then
          ReportTree(ACommand, AName, ARows, AProjectsSearched, AProjectsInGroup)
        else
          ReportGrouped(ACommand, AName, ARows, AProjectsSearched,
            AProjectsInGroup);
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('%s: unhandled %s: %s',
        [cCommandName[ACommand], E.ClassName, E.Message]));
    end;
  end;
end;

end.
