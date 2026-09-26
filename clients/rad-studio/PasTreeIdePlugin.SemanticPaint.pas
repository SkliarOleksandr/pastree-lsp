unit PasTreeIdePlugin.SemanticPaint;

{
  SEMANTIC TYPE COLOURING - a type name painted in its own colour wherever
  it is written (`: TFoo`, `TFoo(X)`, `TFoo.Create`, `SizeOf(TFoo)`), which
  no lexical highlighter can do: the editor's own tokenizer sees every one
  of those as atIdentifier. The classification is the server's
  textDocument/semanticTokens/full (what Ctrl+Click would take to a type
  declaration), cached per file by the session; this unit only paints.

  THE HOOK, and what the spike of 2026-09-22 (0.47.24-0.47.28) established
  about it. INTACodeEditorEvents.PaintText fires per RUN, and a run is NOT
  a token: the IDE coalesces adjacent cells that share a paint attribute, so
  `  GNotifierIndex: Integer = -` arrives as one atIdentifier run, spaces,
  `:`, `=` and `-` included; strings, numbers, reserved words and `;` break
  runs, and the run's SyntaxCode is its first non-blank cell's - so
  `(TWinControl);` after `class` is an atSymbol run holding a type name.
  A type name is therefore a sub-span of a run, located by column, and
  its pixels found proportionally within the run's rect (the squiggle's
  rule - the rect is device pixels while CellSize is not). Three routes
  were tried and all three paint: setting Canvas.Font.Color in the
  before-event (the IDE honours it, for the whole run - useless for a
  sub-span), refusing default painting and drawing the run ourselves, and
  repainting only the sub-spans AFTER the IDE drew the run. The last is
  what this unit does: the IDE keeps every other behaviour (styles,
  selection, the current-line band), the canvas brush after the IDE's own
  paint IS the run's background, and we paint the fewest pixels. Verified
  in the light and dark themes.

  FRESHNESS rides the session's two listener hooks: every semantic answer
  invalidates the visible views of its file, and every publishDiagnostics
  (the server pushes one after each analysis) asks for that file's tokens
  again - so the colouring tracks the analysis with no polling. A file with
  no tokens yet asks once from its first paint, which is how a newly opened
  module gets its colours; the request never starts a server. Between an
  edit and the re-analysis the tokens are the LAST answer's. Kept rather
  than cleared, because clearing flickers every type name on each keystroke
  (the PasTree demo's finding, docs/editor-features.md 1.5) - but not
  painted at their old columns: each line is matched to the text the answer
  describes, and every token is carried to where its identifier now stands,
  or left out until the answer (PasTreeIdePlugin.TokenShift). Painted where
  they were, a character typed in front of a type name slid the name right
  for half a second and left its colour behind (2026-09-25).

  MAIN THREAD throughout: paint events are, and the session marshals its
  answers there (the client unit's own contract).
}

interface

procedure InitializeSemanticPaint;
procedure FinalizeSemanticPaint;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Types,
  System.Math,
  System.Generics.Collections,
  Vcl.Graphics,
  Vcl.Controls,
  ToolsAPI,
  ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.IdleSync,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.TokenShift;

type
  TPasSemanticPaintNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
    procedure HandlePaintText(const ARect: TRect; const AColNum: SmallInt;
      const AText: string; const ASyntaxCode: TOTASyntaxCode;
      const AHilight, ABeforeEvent: Boolean;
      var AAllowDefaultPainting: Boolean;
      const AContext: INTACodeEditorPaintContext);
    procedure HandleBeginPaint(const AEditor: TWinControl;
      const AForceFullRepaint: Boolean);
  end;

const
  // The server's legend, by index - PasLsp.Server's SEMANTIC_TOKENS_LEGEND.
  ST_TYPE = 1;
  ST_CLASS = 2;
  ST_ENUM = 3;
  ST_INTERFACE = 4;
  ST_STRUCT = 5;
  ST_TYPE_PARAMETER = 6;

var
  // Interface-typed on purpose: TNotifierObject is refcounted, and an object
  // variable would neither own nor release it.
  GNotifier: INTACodeEditorEvents;
  GNotifierIndex: Integer = -1;
  GDiagListener: Integer = 0;   // LspAddDiagnosticsChangedListener handle
  // ONE PAINT PASS's state for PasTreeIdePlugin.TokenShift: the editor it
  // is for, the row offset of the last line matched, and the one line
  // matched last - a line arrives as several runs in a row, and its text
  // does not change within a pass. Reset by BeginPaint.
  GPassEditor: TWinControl;
  GPassHint: Integer;
  GLineRow: Integer;
  GLineBase: Pointer;   // the base lines' array it was matched against
  GLineText: string;
  GLineShift: TLineShift;

function IsTypeToken(const AToken: TLspSemanticToken): Boolean;
begin
  case AToken.TokenType of
    ST_TYPE, ST_CLASS, ST_ENUM, ST_INTERFACE, ST_STRUCT, ST_TYPE_PARAMETER:
      Result := True;
  else
    Result := False;
  end;
end;

{ The first token of ARow in a position-sorted array, or Length(ATokens)
  when the row has none. Binary search: this runs per syntax run per
  repaint over arrays of tens of thousands on a large unit. }
function FirstTokenOfRow(const ATokens: TArray<TLspSemanticToken>;
  ARow: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := Length(ATokens);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if ATokens[LMid].Row < ARow then
      LLo := LMid + 1
    else
      LHi := LMid;
  end;
  Result := LLo;
end;

constructor TPasSemanticPaintNotifier.Create;
begin
  inherited Create;
  // The base class dispatches through event properties, not virtuals -
  // AllowedEvents is the only override, the handler rides the property.
  OnEditorPaintText := HandlePaintText;
  OnEditorBeginPaint := HandleBeginPaint;
end;

function TPasSemanticPaintNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevPaintTextEvents, cevBeginEndPaintEvents];
end;

{ Before the view paints: a buffer the IDE reloaded from disk repaints, and
  this is the one moment sure to follow the reload. Nothing reports the
  reload itself (see PasTreeIdePlugin.IdleSync), so without this the server
  keeps the old text and every type name after the change is painted at the
  old columns. Here rather than in a notifier of its own: one code-editor
  notifier fewer to tear down. Runs whether or not the colouring is on - the
  squiggles need the new text just as much. }
procedure TPasSemanticPaintNotifier.HandleBeginPaint(
  const AEditor: TWinControl; const AForceFullRepaint: Boolean);
var
  LServices: INTACodeEditorServices;
begin
  // A new pass: TokenShift's state starts over (see GPassEditor).
  GPassEditor := AEditor;
  GPassHint := 0;
  GLineRow := 0;
  if (AEditor = nil) or
     not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  CheckBufferReloaded(LServices.GetViewForEditor(AEditor));
end;

{ Where row ARow's tokens are, and ARow's text now - one TokenShift match per
  line per pass (see GPassEditor). No base lines means nothing to match
  against: the tokens apply where they are, as before there was a base. }
function LineShiftFor(const AContext: INTACodeEditorPaintContext;
  ARow: Integer; const ABase: TArray<string>; out AText: string): TLineShift;
var
  LLine: INTACodeEditorLineState;
begin
  if AContext.EditControl <> GPassEditor then
  begin
    // Painted without a BeginPaint of its own that we saw: its own pass.
    GPassEditor := AContext.EditControl;
    GPassHint := 0;
    GLineRow := 0;
  end;
  if (ARow = GLineRow) and (Pointer(ABase) = GLineBase) then
  begin
    AText := GLineText;
    Exit(GLineShift);
  end;
  AText := '';
  Result := Default(TLineShift);
  Result.BaseRow := ARow;
  Result.Same := True;
  if ABase <> nil then
  begin
    LLine := AContext.LineState;
    if Assigned(LLine) then
    begin
      AText := LLine.Text;
      Result := ShiftForLine(ABase, ARow, AText, GPassHint);
    end;
  end;
  GLineRow := ARow;
  GLineBase := Pointer(ABase);
  GLineText := AText;
  GLineShift := Result;
end;

procedure TPasSemanticPaintNotifier.HandlePaintText(const ARect: TRect;
  const AColNum: SmallInt; const AText: string;
  const ASyntaxCode: TOTASyntaxCode; const AHilight, ABeforeEvent: Boolean;
  var AAllowDefaultPainting: Boolean;
  const AContext: INTACodeEditorPaintContext);
var
  LTokens: TArray<TLspSemanticToken>;
  LBase: TArray<string>;
  LShift: TLineShift;
  LLineText: string;
  LIdx, LRow, LFrom, LTo, LRunEnd, LTokFrom, LTokTo: Integer;
  LCanvas: TCanvas;
  LPiece: TRect;
  LOldColor, LColor: TColor;
  LOldStyle, LStyle: TFontStyles;
begin
  // AFTER the IDE painted the run. A selected run keeps the selection's own
  // text colour - the one colour guaranteed readable on that background.
  // The run's code is the code of its FIRST non-blank cell, not of every
  // cell in it: `(TWinControl);` after the `class` keyword arrives as ONE
  // atSymbol run with the type name inside (second live run, 2026-09-22 -
  // every ancestor in a class header stayed black), so symbol runs are
  // looked into as well. Comments, strings, numbers, keywords and
  // directives never contain a type token and are skipped on their code.
  if ABeforeEvent or AHilight or (AContext = nil) or (AText = '') or
     not (ASyntaxCode in [atIdentifier, atSymbol, atWhiteSpace]) then
    Exit;
  if not TypeHighlightEnabled then
    Exit;
  if not IsPascalSourceFile(AContext.FileName) then
    Exit;
  if not LspTryGetSemanticTokens(AContext.FileName, LTokens, LBase) then
  begin
    // Nothing answered yet for this file - ask once (a no-op while the
    // request is in flight or no server is up); the answer repaints.
    LspRefreshSemanticTokens(AContext.FileName);
    Exit;
  end;
  if LTokens = nil then
    Exit;
  LRow := AContext.LogicalLineNum;
  // The answer describes the text it was asked about; this line may have
  // moved or changed since (PasTreeIdePlugin.TokenShift).
  LShift := LineShiftFor(AContext, LRow, LBase, LLineText);
  if LShift.BaseRow = 0 then
    Exit;
  LRunEnd := AColNum + Length(AText);
  LCanvas := AContext.Canvas;
  LOldColor := LCanvas.Font.Color;
  LOldStyle := LCanvas.Font.Style;
  LColor := TypeHighlightColor;
  // The user's style ADDED to the run's own (the editor may already paint
  // identifiers bold): a style is a mark, not a replacement.
  LStyle := LOldStyle + TypeHighlightStyle;
  LIdx := FirstTokenOfRow(LTokens, LShift.BaseRow);
  while (LIdx < Length(LTokens)) and (LTokens[LIdx].Row = LShift.BaseRow) do
  begin
    if IsTypeToken(LTokens[LIdx]) and
       ShiftToken(LShift, LLineText, LTokens[LIdx].ColFrom,
         LTokens[LIdx].ColTo, LTokFrom, LTokTo) then
    begin
      // Intersect the token's columns with this run's [AColNum, LRunEnd).
      LFrom := Max(LTokFrom, AColNum);
      LTo := Min(LTokTo, LRunEnd);
      if LTo > LFrom then
      begin
        // Columns -> pixels PROPORTIONALLY within the run's own rect (the
        // squiggle's rule, PasTreeIdePlugin.ErrorPaint). The brush is what
        // the IDE painted the run's background with, current-line band
        // included; the font is the run's, only the colour is ours.
        LPiece := Rect(
          ARect.Left + MulDiv(LFrom - AColNum, ARect.Width, Length(AText)),
          ARect.Top,
          ARect.Left + MulDiv(LTo - AColNum, ARect.Width, Length(AText)),
          ARect.Bottom);
        LCanvas.Font.Color := LColor;
        LCanvas.Font.Style := LStyle;
        LCanvas.FillRect(LPiece);
        LCanvas.TextRect(LPiece, LPiece.Left, LPiece.Top,
          Copy(AText, LFrom - AColNum + 1, LTo - LFrom));
      end;
    end;
    Inc(LIdx);
  end;
  LCanvas.Font.Color := LOldColor;
  LCanvas.Font.Style := LOldStyle;
end;

{ The Settings dialog saved: every open editor repaints with the new colour
  and style, or without ours when the switch went off. }
procedure OnSettingsSaved;
var
  LServices: INTACodeEditorServices;
  LEditors: TList<TWinControl>;
  LIdx: Integer;
begin
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  LEditors := LServices.GetKnownEditors;
  if LEditors = nil then
    Exit;
  try
    for LIdx := 0 to LEditors.Count - 1 do
      if LEditors[LIdx] <> nil then
        LServices.InvalidateEditor(LEditors[LIdx]);
  finally
    LEditors.Free;
  end;
end;

{ Repaint every visible view of APath - the answer landed, or the analysis
  did and the tokens are about to be asked for again. }
procedure InvalidateViewsOf(const APath: string);
var
  LServices: INTACodeEditorServices;
  LViews: TList<IOTAEditView>;
  LIdx: Integer;
  LEditor: TWinControl;
begin
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  LViews := LServices.GetKnownViews;
  if LViews = nil then
    Exit;
  try
    for LIdx := 0 to LViews.Count - 1 do
      if (LViews[LIdx] <> nil) and (LViews[LIdx].Buffer <> nil) and
         SameText(LViews[LIdx].Buffer.FileName, APath) then
      begin
        LEditor := LServices.GetEditorForView(LViews[LIdx]);
        if LEditor <> nil then
          LServices.InvalidateEditor(LEditor);
      end;
  finally
    LViews.Free;
  end;
end;

{ Fresh diagnostics for APath mean a fresh analysis: ask for its tokens
  again - but only for a file somebody is looking at, the rest can wait
  for their first paint. }
procedure OnDiagnosticsChanged(const APath: string);
var
  LServices: INTACodeEditorServices;
  LViews: TList<IOTAEditView>;
  LIdx: Integer;
begin
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  LViews := LServices.GetKnownViews;
  if LViews = nil then
    Exit;
  try
    for LIdx := 0 to LViews.Count - 1 do
      if (LViews[LIdx] <> nil) and (LViews[LIdx].Buffer <> nil) and
         SameText(LViews[LIdx].Buffer.FileName, APath) then
      begin
        LspRefreshSemanticTokens(APath);
        Exit;
      end;
  finally
    LViews.Free;
  end;
end;

procedure InitializeSemanticPaint;
var
  LServices: INTACodeEditorServices;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  GNotifier := TPasSemanticPaintNotifier.Create;
  GNotifierIndex := LServices.AddEditorEventsNotifier(GNotifier);
  if GNotifierIndex < 0 then
  begin
    GNotifier := nil;   // refcount frees it
    Exit;
  end;
  LspSetSemanticTokensChangedListener(InvalidateViewsOf);
  GDiagListener := LspAddDiagnosticsChangedListener(OnDiagnosticsChanged);
  SetSettingsSavedListener(OnSettingsSaved);
end;

procedure FinalizeSemanticPaint;
var
  LServices: INTACodeEditorServices;
begin
  SetSettingsSavedListener(nil);
  LspSetSemanticTokensChangedListener(nil);
  LspRemoveDiagnosticsChangedListener(GDiagListener);
  GDiagListener := 0;
  if GNotifierIndex < 0 then
    Exit;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

end.
