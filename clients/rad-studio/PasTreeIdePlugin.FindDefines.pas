unit PasTreeIdePlugin.FindDefines;

{
  "Find All > Defines" and "Defines at cursor" entry points, wired to the
  editor's Find All submenu (see PasTreeIdePlugin.Wizard) - the IDE side of
  PasTree 0.28.0's two cursor-free define inventories (FindDefines,
  DefinesAt; docs/editor-features.md section 10 in the PasTree repo owns the
  contract).

  Modeled on PasTreeIdePlugin.FindReferences, which owns the longer story on
  why this runs out of process. Three differences from that unit:

    - NO SNIPPET LOOKUP, and no TSnippetCache: these rows carry their own
      line AND the span to highlight in it, so nothing here re-reads a
      source line (see DisplaySnippet - pairing the server's span with any
      other text is what produced two wrong highlights on 2026-09-14).


    - BOTH commands need NO IDENTITY at the caret - `pastree/findDefines` is
      a project-wide inventory and `pastree/definesAt` replays the model's
      define state up to the cursor, so neither can answer "nothing here"
      the way a reference search can. They are always offered (no findAllAt
      gate, unlike the seven Find All commands - see SPEC.md).

    - PROJECT-SCOPED, DELIBERATELY, unlike Find References: LspFindDefines
      and LspDefinesAt ask only the active file's own server
      (LspSession.SessionForRequest), never LspXxxInGroup. A conditional
      symbol is a project-local fact - PasTree's docs note plainly that a
      $DEFINE is unit-local and a define one project of a group makes is not
      in effect in another project's compile at all - so a group-wide merge
      would answer a question nobody asked, unlike a shared unit's
      references, which really are one fact seen from two closures.

  Two commands, one Messages tab ("Find Defines"), cleared and rebuilt on
  each call - the tab's title line says which one ran. `Find All > Defines`
  groups by file (one header per file, as Find References does) plus two
  more groups, "Project defines" and "Platform defines" - the PasTree demo's
  own shape (AGroupKeys). `Defines at cursor` is a FLAT list, one row per
  name in effect, each showing the $DEFINE that put it there.
}

interface

uses
  ToolsAPI;

/// <summary>Find All > Defines: the project-wide inventory.</summary>
procedure ExecuteFindDefines(const AView: IOTAEditView);

/// <summary>Defines at cursor: the flat in-effect set.</summary>
procedure ExecuteDefinesAtCursor(const AView: IOTAEditView);

/// <summary>
/// Removes the "Find Defines" Messages tab - call once from
/// TIDEWizard.Destroy, before FinalizeLspSession, exactly as
/// FinalizeFindReferencesMessageGroup does and for the same reason (see its
/// own header comment: a callback landing after the group's vtable is
/// unloaded is the dangling-code AV this package has already been bitten by).
/// </summary>
procedure FinalizeFindDefinesMessageGroup;

/// <summary>Drops the results tab because the project it describes is closing.</summary>
procedure CloseFindDefinesResults;

implementation

uses
  System.SysUtils, System.Generics.Collections, Vcl.Forms,
  ToolsAPI.UI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog;

const
  cMessageGroupName = 'Find Defines';
  cProjectGroupLabel = 'Project defines';
  cPlatformGroupLabel = 'Platform defines';

var
  // Same lifecycle as FindReferences' GMessageGroup/GAlive - see that unit's
  // header for why this is hygiene (orphaned IDE resource) for the group and
  // a real crash guard (dangling BPL code) for the gate.
  GMessageGroup: IOTAMessageGroup;
  GAlive: Boolean = True;

function GetOrCreateMessageGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
end;

// Not at IDE shutdown - see FindReferences.FinalizeFindReferencesMessageGroup
// for the AV this guards against; the same reasoning applies verbatim here.
procedure FinalizeFindDefinesMessageGroup;
var
  LMessageServices: IOTAMessageServices;
begin
  GAlive := False;
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // See FinalizeFindReferencesMessageGroup: cosmetic cleanup, no panel
      // left to report a failure to.
    end;
  GMessageGroup := nil;
end;

procedure CloseFindDefinesResults;
var
  LMessageServices: IOTAMessageServices;
begin
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // As above - a closing project asked nothing of the Messages panel.
    end;
  GMessageGroup := nil;
end;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  LspLogToServer(AMessage);
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ THE SNIPPET IS THE SERVER'S, AND SO IS THE SPAN - they only mean anything
  TOGETHER, which is the whole story of two wrong highlights in a row
  (screenshots, 2026-09-14).

  PasTree frames each row itself: for a $DEFINE site the snippet is the
  source line and hiFrom/hiTo span the name inside it; for a project or
  platform define, which has no source site, the snippet is THE NAME ITSELF
  and the span covers that. Pairing either span with any other text is a
  highlight on the wrong characters - first against a name-prefixed line
  (the underline sat on "{$DEFIN"), then against the main module's own
  `program AVImark;`, which a 10-character MSWINDOWS span turned into
  "program A".

  So the line is never re-read locally. Find References has to read one -
  an LSP Location carries no text at all - but these rows arrive with
  theirs, from the same snapshot the answer was computed over, which is
  exactly what a re-read was buying there. TrimRight only: hiFrom/hiTo are
  offsets from the START of the snippet, so trimming the left would move
  every one of them.

  AND NOTHING IS PUT IN FRONT OF IT. A row read the name, a colon, and then
  the very same name inside its own directive, until Alex asked for the
  duplicate to go (2026-09-14): the name is already in the directive,
  highlighted, and the file and line ahead of it are the result row's own
  (PasTreeIdePlugin.ResultRows). A project or platform define wanted no
  prefix either - its snippet IS the name. Which leaves the span usable
  exactly as it arrived, with nothing to shift it by - the mistake the
  prefix kept reintroducing. }
function DisplaySnippet(const ARow: TLspDefineRow;
  out AMatchStart, AMatchLen: Integer): string;
begin
  AMatchStart := 0;
  AMatchLen := 0;
  Result := TrimRight(ARow.Snippet);
  if Result = '' then
    Exit(ARow.Name);
  if (ARow.HiTo > ARow.HiFrom) and (ARow.HiFrom >= 0) and
     (ARow.HiTo <= Length(Result)) then
  begin
    AMatchStart := ARow.HiFrom + 1;   // 0-based -> 1-based
    AMatchLen := ARow.HiTo - ARow.HiFrom;
  end;
end;

function OriginTag(const ARow: TLspDefineRow): string;
begin
  if not ARow.Active then
    Result := 'inactive'
  else if ARow.Origin = 'project' then
    Result := 'project'
  else if ARow.Origin = 'platform' then
    Result := 'platform'
  else
    Result := '';
end;

/// <summary>
/// Find All > Defines: grouped like Find References (one header per file),
/// plus "Project defines" and "Platform defines" as two groups of their
/// own, in whatever order the server already sorted them (file/line/col,
/// then project names, then platform names).
/// </summary>
procedure ReportFindDefines(const ARows: TArray<TLspDefineRow>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LGroupCounts: TDictionary<string, Integer>;
  LGroupHeaders: TDictionary<string, Pointer>;
  LRow: TLspDefineRow;
  LKey, LLabel: string;
  LParentRef: Pointer;
  LDisplay: string;
  LMatchStart, LMatchLen, LExisting: Integer;

  function GroupKeyAndLabel(const ARow: TLspDefineRow;
    out ALabel: string): string;
  begin
    if ARow.Origin = 'project' then
      ALabel := cProjectGroupLabel
    else if ARow.Origin = 'platform' then
      ALabel := cPlatformGroupLabel
    else
      ALabel := ARow.Hit.FilePath;
    Result := LowerCase(ALabel);
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(Format('PasTree Find All Defines: %d define(s)',
      [Length(ARows)])), LGroup);

  LGroupCounts := TDictionary<string, Integer>.Create;
  LGroupHeaders := TDictionary<string, Pointer>.Create;
  try
    for LRow in ARows do
    begin
      LKey := GroupKeyAndLabel(LRow, LLabel);
      LGroupCounts.TryGetValue(LKey, LExisting);
      LGroupCounts.AddOrSetValue(LKey, LExisting + 1);
    end;
    for LRow in ARows do
    begin
      LKey := GroupKeyAndLabel(LRow, LLabel);
      if not LGroupHeaders.TryGetValue(LKey, LParentRef) then
      begin
        LParentRef := LMessageServices.AddCustomMessagePtr(
          NewFileHeaderRow(LLabel, LGroupCounts[LKey]), LGroup);
        LGroupHeaders.Add(LKey, LParentRef);
      end;
      LDisplay := DisplaySnippet(LRow, LMatchStart, LMatchLen);
      LMessageServices.AddCustomMessage(
        NewSnippetRow(LRow.Hit.FilePath, LRow.Hit.Row, LRow.Hit.Col,
          LDisplay, LMatchStart, LMatchLen, OriginTag(LRow),
          LRow.Hit.TypeSpans),
        LParentRef);
    end;
  finally
    LGroupHeaders.Free;
    LGroupCounts.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
end;

/// <summary>
/// Defines at cursor: a flat list, one row per name in effect, prefixed with
/// the defining file and line - no grouping, since "in effect here" is
/// already the whole answer.
/// </summary>
procedure ReportDefinesAt(const ARows: TArray<TLspDefineRow>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LRow: TLspDefineRow;
  LDisplay: string;
  LMatchStart, LMatchLen: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(Format('PasTree Defines at cursor: %d name(s) in effect',
      [Length(ARows)])), LGroup);

  for LRow in ARows do
  begin
    LDisplay := DisplaySnippet(LRow, LMatchStart, LMatchLen);
    LMessageServices.AddCustomMessagePtr(
      NewSnippetRow(LRow.Hit.FilePath, LRow.Hit.Row, LRow.Hit.Col,
        LDisplay, LMatchStart, LMatchLen, OriginTag(LRow),
        LRow.Hit.TypeSpans),
      LGroup);
  end;
  LMessageServices.ShowMessageView(LGroup);
end;

procedure ExecuteFindDefines(const AView: IOTAEditView);
var
  LCursorFile: string;
begin
  try
    if not Assigned(AView) then
      Exit;
    LCursorFile := AView.Buffer.FileName;
    ShowWaitDialog('Searching defines...');
    LspLogToServer('findDefines: asking ' + ExtractFileName(LCursorFile));
    LspFindDefines(LCursorFile,
      procedure(ASuccess: Boolean; const ARows: TArray<TLspDefineRow>;
        const AError: string)
      begin
        LspLogToServer(Format('findDefines: answer ok=%s rows=%d err=%s',
          [BoolToStr(ASuccess, True), Length(ARows), AError]));
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          CloseWaitDialog;   // before anything that can talk to the user
          LogDiagnostic('Find All Defines: ' + AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(ARows),
          procedure
          begin
            ReportFindDefines(ARows);
          end);
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('Find All Defines: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

procedure ExecuteDefinesAtCursor(const AView: IOTAEditView);
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
    ShowWaitDialog('Finding defines at cursor...');
    LspLogToServer(Format('definesAt: asking %s(%d,%d)',
      [ExtractFileName(LCursorFile), LRow, LCol]));
    LspDefinesAt(LCursorFile, LRow, LCol,
      procedure(ASuccess: Boolean; const ARows: TArray<TLspDefineRow>;
        const AError: string)
      begin
        LspLogToServer(Format('definesAt: answer ok=%s rows=%d err=%s',
          [BoolToStr(ASuccess, True), Length(ARows), AError]));
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          CloseWaitDialog;   // as above
          LogDiagnostic('Defines at cursor: ' + AError);
          Exit;
        end;
        ReportUnderWaitDialog(Length(ARows),
          procedure
          begin
            ReportDefinesAt(ARows);
          end);
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      LogDiagnostic(Format('Defines at cursor: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

end.
