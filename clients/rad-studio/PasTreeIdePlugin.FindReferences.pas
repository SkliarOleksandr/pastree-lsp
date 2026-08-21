unit PasTreeIdePlugin.FindReferences;

{
  Find References entry point, wired to the "Find References" editor
  menu item (see PasTreeIdePlugin.Wizard).

  Runs OUT OF PROCESS since the LSP move: ExecuteFindReferences asks
  pastree-server.exe (Win64) via PasTreeIdePlugin.LspSession instead of
  building a TPasNavigator inside this Win32 designtime package. The
  three-identity resolve (symbol / unit / builtin) lives in the server now -
  one implementation shared with every other LSP client.

    - Results go to a dedicated "Find References" tab in the Messages
      panel (see ReportHits), grouped by file (one header row per file via
      AddToolMessage's own Parent/LineRef mechanism - same tree structure
      "Find in Files" uses), one line per hit with file/line/column so the
      IDE's own message navigation jumps straight to it.

  ASYNCHRONOUS, AND IT SHOWS IN TWO PLACES. The menu handler returns
  immediately and the panel fills in on a later main-thread turn. Two
  consequences worth knowing:

    - The identifier name for the report title is read at ANSWER time out of
      the text the server was given (IdentifierAt), because LSP answers with
      positions only and the cursor may have moved by then.
    - Snippet text is not in the response either - an LSP Location has no line
      content, where TPasRefHit carried one. TSnippetCache reads it from the
      same server-side snapshot, never from a fresh file read, so an unsaved
      buffer's line numbers still line up with the text shown.

  TODO (next):
    1. Highlight the matched identifier within each hit's snippet text.
       The LSP Location's range already carries the identifier's extent on the
       line, so the offsets are available without a protocol extension.
       AddToolMessage draws plain text only; doing this means a message class
       implementing IOTACustomMessage100 (for FileName/Line/Col + navigation)
       and INTACustomDrawMessage (Draw/CalcRect on a TCanvas -
       ToolsAPI.pas:6335) together, registered via AddCustomMessage instead of
       AddToolMessage. Deliberately deferred - a cosmetic-only improvement.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Entry point called from the editor's local menu action.
/// </summary>
procedure ExecuteFindReferences(const AView: IOTAEditView);

/// <summary>
/// Removes the "Find References" Messages tab. Call once (from
/// PasTreeIdePlugin.Wizard's TIDEWizard.Destroy) so the group doesn't
/// persist forever across package reinstalls - see the field comment on
/// GMessageGroup in the implementation section for why this is hygiene,
/// not something suspected of causing the reinstall AVs.
/// </summary>
procedure FinalizeFindReferencesMessageGroup;

implementation

uses
  System.SysUtils, System.Character, System.Generics.Collections, Vcl.Dialogs,
  ToolsAPI.UI, PasTreeIdePlugin.LspSession;

const
  cMessageGroupName = 'Find References';

var
  // Held so FinalizeFindReferencesMessageGroup can remove it on package
  // unload - a plain data container (no code pointers back into us), so its
  // leaking across a hot-reinstall was never itself a crash risk, just an
  // orphaned IDE resource. Fixed for hygiene, not because it was suspected
  // of causing the AVs - see PasTreeIdePlugin.GotoDeclaration's own header
  // for that (unrelated) investigation.
  GMessageGroup: IOTAMessageGroup;

function GetOrCreateMessageGroup(const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
end;

procedure FinalizeFindReferencesMessageGroup;
var
  LMessageServices: IOTAMessageServices;
begin
  if Assigned(GMessageGroup) and Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.RemoveMessageGroup(GMessageGroup);
  GMessageGroup := nil;
end;

/// <summary>
/// Diagnostics/errors/progress - as opposed to actual results (ReportHits) -
/// go to the IDE's own default Messages tab (nil group = the "Build" tab,
/// where compiler output already lives) rather than our own "Find
/// References" tab, so they're where a developer would already be looking
/// and not competing for space with the actual reference list. Tagged with
/// "[pastree]" to stay identifiable alongside compiler/linker noise.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

type
  /// <summary>
  /// Line lookup for the report's snippet column, which LSP does not provide -
  /// a Location carries a position and nothing else, where the in-process
  /// TPasRefHit carried the source line with it.
  ///
  /// The text comes from LspSourceTextOf, i.e. from what the SERVER was given,
  /// never from a fresh read of the file: an unsaved buffer's line numbers only
  /// mean anything against the text the answer was computed from. Split lines
  /// are cached per report because a reference list is normally many hits
  /// across few files.
  /// </summary>
  TSnippetCache = class
  private
    FLines: TDictionary<string, TArray<string>>;
  public
    constructor Create;
    destructor Destroy; override;
    function LineAt(const AFilePath: string; ARow: Integer): string;
  end;

constructor TSnippetCache.Create;
begin
  inherited Create;
  FLines := TDictionary<string, TArray<string>>.Create;
end;

destructor TSnippetCache.Destroy;
begin
  FLines.Free;
  inherited;
end;

function TSnippetCache.LineAt(const AFilePath: string; ARow: Integer): string;
var
  LKey: string;
  LLines: TArray<string>;
begin
  Result := '';
  LKey := LowerCase(AFilePath);
  if not FLines.TryGetValue(LKey, LLines) then
  begin
    LLines := LspSourceTextOf(AFilePath).Replace(#13#10, #10).Split([#10]);
    FLines.Add(LKey, LLines);
  end;
  // ARow is 1-based, and a stale row against a file we could not read must
  // degrade to an empty snippet rather than raise.
  if (ARow >= 1) and (ARow <= Length(LLines)) then
    Result := Trim(LLines[ARow - 1]);
end;

/// <summary>
/// Reports the declaration site (if any) plus every found reference, grouped
/// by file, in a dedicated "Find References" tab in the Messages panel
/// (distinct from the Build tab, reused across searches - each call clears
/// it first). Grouping uses AddToolMessage's own Parent/LineRef mechanism -
/// one header line per file (its LineRef captured), every hit in that file
/// added as a child of that header - no custom message class needed, this
/// is the same mechanism the IDE's own "Find in Files" tree uses. Each leaf
/// line carries a file/line/column, so the IDE's own message-view navigation
/// (double-click, Enter, F8/Shift+F8) jumps straight to it.
/// </summary>
procedure ReportHits(const AIdentifier: string; AHasDecl: Boolean;
  const ADeclHit: TLspHit; const AHits: TArray<TLspHit>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LLineRef, LParentRef: Pointer;
  LHit: TLspHit;
  LSnippets: TSnippetCache;

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
      // LineNumber stays 1 (not the file's reference count) - double-click
      // still jumps to the top of the file rather than doing nothing/
      // expand-only. Fixing that needs a custom IOTACustomMessage100 class
      // (CanGotoSource/DefaultHandling) - deliberately not done yet, see
      // this procedure's own doc comment.
      LMessageServices.AddToolMessage(AFilePath,
        Format('%s (%d)', [ExtractFileName(AFilePath), LFileCount]),
        '', 1, 1, nil, Result, LGroup);
      LFileHeaders.Add(LKey, Result);
    end;
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  LMessageServices.AddTitleMessage(
    Format('PasTree Find References: "%s" - %d reference(s)', [AIdentifier, Length(AHits)]),
    LGroup);

  LFileCounts := TDictionary<string, Integer>.Create;
  LFileHeaders := TDictionary<string, Pointer>.Create;
  LSnippets := TSnippetCache.Create;
  try
    if AHasDecl then
      CountFile(ADeclHit.FilePath);
    for LHit in AHits do
      CountFile(LHit.FilePath);

    if AHasDecl then
    begin
      LParentRef := GetOrCreateFileHeader(ADeclHit.FilePath);
      LMessageServices.AddToolMessage(ADeclHit.FilePath,
        Format('declaration of "%s"', [AIdentifier]),
        '', ADeclHit.Row, ADeclHit.Col, LParentRef, LLineRef, LGroup);
    end;

    for LHit in AHits do
    begin
      LParentRef := GetOrCreateFileHeader(LHit.FilePath);
      LMessageServices.AddToolMessage(LHit.FilePath,
        LSnippets.LineAt(LHit.FilePath, LHit.Row),
        '', LHit.Row, LHit.Col, LParentRef, LLineRef, LGroup);
    end;
  finally
    LSnippets.Free;
    LFileHeaders.Free;
    LFileCounts.Free;
  end;

  LMessageServices.ShowMessageView(LGroup);
end;

/// <summary>
/// The identifier the user clicked, read out of the same text the server was
/// given. LSP answers with positions only, so the name for the report's title
/// has to come from here - the in-process navigator used to hand it back
/// alongside the hits.
/// </summary>
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
  // Only ASCII word characters: a Pascal identifier cannot contain anything
  // else, and treating a non-ASCII letter as a boundary is harmless here (the
  // worst case is a shorter title on a hit inside a string literal).
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

{ Two requests, deliberately.

  The server prepends the declaration to the reference list when
  includeDeclaration is set, but the response is a flat array - there is no way
  to tell afterwards which element was the declaration. The report has always
  shown it as its own labelled row ("declaration of X"), so instead of losing
  that, references are asked for WITHOUT the declaration and the declaration is
  asked for separately. The second request costs almost nothing: the project is
  analyzed by the time the first one answers, and everything after that is
  cache lookups (measured at 0-16ms against this package's own .dproj).

  Sequential rather than parallel because the report needs both answers and
  sequencing two callbacks is easier to follow than counting completions. }
procedure ExecuteFindReferences(const AView: IOTAEditView);
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

    LspReferences(LCursorFile, LRow, LCol, False,
      procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
        const AError: string)
      var
        LName: string;
        LRefs: TArray<TLspHit>;
      begin
        if not ASuccess then
        begin
          LogDiagnostic('Find References: ' + AError);
          Exit;
        end;

        // The name is read at ANSWER time, not click time - the cursor may
        // have moved, but the text at the position we asked about has not,
        // since the server holds the same snapshot we sent it.
        LName := IdentifierAt(LCursorFile, LRow, LCol);
        if (Length(AHits) = 0) and (LName = '') then
        begin
          (BorlandIDEServices as INTAIDEUIServices).MessageDlg(
            'No identifier under the cursor.', mtInformation, [mbOK], -1);
          Exit;
        end;

        LRefs := AHits;
        LspDefinition(LCursorFile, LRow, LCol,
          procedure(ADeclOk: Boolean; const ADeclHits: TArray<TLspHit>;
            const ADeclError: string)
          begin
            // No declaration is a legitimate answer, not a failure: a compiler
            // builtin has none anywhere. Report the references either way.
            if ADeclOk and (Length(ADeclHits) > 0) then
              ReportHits(LName, True, ADeclHits[0], LRefs)
            else
              ReportHits(LName, False, Default(TLspHit), LRefs);
          end);
      end);
  except
    // Scaffold diagnostics: surface the real exception in the Messages panel
    // instead of letting an unhandled one pop the IDE's generic "Error"
    // dialog with no context. Remove once the pipeline is stable.
    on E: Exception do
      LogDiagnostic(Format('Find References: unhandled %s: %s', [E.ClassName, E.Message]));
  end;
end;

end.
