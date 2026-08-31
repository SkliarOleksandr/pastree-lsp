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
      panel (see ReportHits), grouped by file: one owner-drawn header row
      per file, one owner-drawn snippet row per hit (custom message tree
      via AddCustomMessagePtr/AddCustomMessage Parent pointers - the
      custom-message parallel of the AddToolMessage tree "Find in Files"
      uses). Rows come from PasTreeIdePlugin.ResultRows: the snippet is
      painted in the user's live editor syntax colors, the matched
      identifier carries the editor's own "Search match" element, and
      every row - headers included - navigates on double-click/Enter/F8.

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
  System.SysUtils, System.Character, System.Generics.Collections,
  Vcl.Dialogs, Vcl.Forms,
  ToolsAPI.UI, PasTreeIdePlugin.LspSession, PasTreeIdePlugin.ResultRows;

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

{ NOT AT IDE SHUTDOWN - this is the AV of 2026-08-22 and 2026-08-24, finally
  located by the crash recorder (PasTreeIdePlugin.CrashLog) on the second one:

    IDE ACCESS VIOLATION at coreide370.bpl + 3202A8, read of address 00000010
      PasTreeIdePlugin.bpl -> PasTreeIdePlugin.FindReferences.pas:94
      PasTreeIdePlugin.bpl -> PasTreeIdePlugin.Wizard.pas:369

  i.e. RemoveMessageGroup, called from TIDEWizard.Destroy, faulting inside the
  IDE. By the time a designtime package is unloaded as part of the IDE closing,
  the Messages panel that owns the group is already torn down, and the removal
  reads a field off something that is gone. Nothing about the group is wrong -
  the same call during an ordinary package Uninstall works.

  So the call is now conditional on the IDE NOT terminating, which is exactly
  the distinction that matters: at shutdown the group dies with the panel and
  removing it buys nothing, while during an uninstall-with-the-IDE-running it
  is the difference between a clean reinstall and a stale tab. Application is
  the IDE's own, and Terminated is set once its main form is closing.

  The try/except is the belt to that braces, and deliberately silent: this runs
  while the package is being unloaded, so there is no panel left to report to,
  and an exception escaping a destructor here would take the IDE down over a
  cosmetic cleanup. }
procedure FinalizeFindReferencesMessageGroup;
var
  LMessageServices: IOTAMessageServices;
begin
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // See above. The group is released either way by the line below.
    end;
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
  // degrade to an empty snippet rather than raise. The line comes back RAW
  // (untrimmed): the caller maps the hit's column into the display text, so
  // it must be the one deciding how much leading whitespace went away.
  if (ARow >= 1) and (ARow <= Length(LLines)) then
    Result := LLines[ARow - 1];
end;

/// <summary>
/// Reports the declaration site (if any) plus every found reference, grouped
/// by file, in a dedicated "Find References" tab in the Messages panel
/// (distinct from the Build tab, reused across searches - each call clears
/// it first). Every row is an owner-drawn custom message from
/// PasTreeIdePlugin.ResultRows: one navigable header per file (bold name +
/// count, double-click opens the file - the AddToolMessage headers never
/// could), one syntax-colored snippet per hit with the matched identifier
/// highlighted the way the editor highlights a search match. The tree is
/// AddCustomMessagePtr (header, returns the Parent pointer) plus
/// AddCustomMessage(row, Parent) (hits) - the custom-message parallel of
/// the AddToolMessage Parent/LineRef mechanism used before.
/// </summary>
procedure ReportHits(const AIdentifier: string; AHasDecl: Boolean;
  const ADeclHit: TLspHit; const AHits: TArray<TLspHit>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LParentRef: Pointer;
  LHit: TLspHit;
  LSnippets: TSnippetCache;
  LTitleHead, LTitleCount: string;

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

  { The line goes to the row RAW, indentation included - Find in Files
    shows its snippets that way, and this tab replicates its shape (see
    PasTreeIdePlugin.ResultRows). The match is highlighted only when the
    text at the hit's column still reads as the identifier - anything else
    (a stale row, a column past the end) degrades to an unhighlighted
    snippet, never to a highlight on the wrong characters. }
  procedure AddSnippetRow(const AHit: TLspHit; const ATag: string;
    AParent: Pointer);
  var
    LDisplay: string;
    LMatchStart, LMatchLen: Integer;
  begin
    LDisplay := TrimRight(LSnippets.LineAt(AHit.FilePath, AHit.Row));
    LMatchStart := AHit.Col;
    LMatchLen := Length(AIdentifier);
    if (LMatchLen = 0) or (LMatchStart < 1) or
       (LMatchStart + LMatchLen - 1 > Length(LDisplay)) or
       not SameText(Copy(LDisplay, LMatchStart, LMatchLen), AIdentifier) then
    begin
      LMatchStart := 0;
      LMatchLen := 0;
    end;
    LMessageServices.AddCustomMessage(
      NewSnippetRow(AHit.FilePath, AHit.Row, AHit.Col, LDisplay,
        LMatchStart, LMatchLen, ATag), AParent);
  end;

begin
  if not Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    Exit;

  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);

  // A custom row rather than AddTitleMessage: a title message is IDE-drawn
  // in the plain text color, and this line is styled like the headers -
  // blue bold, the count in the line-number orange (built by concatenation
  // so the count's span is known, not searched for).
  LTitleHead := Format('PasTree Find References: "%s" - ', [AIdentifier]);
  LTitleCount := IntToStr(Length(AHits));
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(LTitleHead + LTitleCount + ' reference(s)',
      Length(LTitleHead) + 1, Length(LTitleCount)), LGroup);

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
      AddSnippetRow(ADeclHit, 'declaration', LParentRef);
    end;

    for LHit in AHits do
    begin
      LParentRef := GetOrCreateFileHeader(LHit.FilePath);
      AddSnippetRow(LHit, '', LParentRef);
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
