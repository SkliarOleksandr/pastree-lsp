unit PasTreeIdePlugin.ErrorPaint;

{
  PAINTED SQUIGGLES - the diagnostics route the file-trait spike settled on
  (2026-08-22, readout in clients/rad-studio/SPEC.md): the module answers
  IOTAModuleErrors NATIVELY inside the IDE, so a trait can never win the
  editor's query, and the personality-wide registration was invisible to
  FindFileTrait anyway. What remains is drawing them ourselves, which this
  unit does at the one hook made for it: INTACodeEditorEvents.PaintText
  fires per token run with the run's rect, start column and text, and the
  paint context carries the file, the logical line, the canvas and the cell
  size - everything a wavy underline needs, no coordinate archaeology.

  DATA: the session's publishDiagnostics cache (LspTryGetDiagnostics), in
  IDE coordinates (1-based row/cols, ColTo exclusive). Freshness rides the
  session's listener hook: every stored publishDiagnostics invalidates the
  visible views of that file, so squiggles appear when the analysis lands
  and vanish when it comes back clean - no polling, no timers.

  MAIN THREAD throughout: paint events are, and the session marshals its
  notifications there (the client unit's own contract).
}

interface

procedure InitializeErrorPaint;
procedure FinalizeErrorPaint;

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
  PasTreeIdePlugin.LspDocuments;

type
  TPasErrorPaintNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
    procedure HandlePaintText(const ARect: TRect; const AColNum: SmallInt;
      const AText: string; const ASyntaxCode: TOTASyntaxCode;
      const AHilight, ABeforeEvent: Boolean;
      var AAllowDefaultPainting: Boolean;
      const AContext: INTACodeEditorPaintContext);
  end;

var
  // Interface-typed on purpose: TNotifierObject is refcounted, and an object
  // variable would neither own nor release it.
  GNotifier: INTACodeEditorEvents;
  GNotifierIndex: Integer = -1;

{ Severity -> underline color: LSP 1 error, 2 warning, 3 hint - the same
  red/orange/gray family the IDE's own Error Insight draws. TColor is BGR. }
function SeverityColor(ASeverity: Integer): TColor;
begin
  case ASeverity of
    1: Result := clRed;
    2: Result := TColor($0000A5FF);   // orange
  else
    Result := TColor($00909090);      // quiet gray for hints
  end;
end;

{ The classic squiggle: a zigzag hugging the bottom of the line rect. SIZED
  FROM THE RECT, not from constants - the paint canvas is in device pixels,
  so a hardcoded 2px wave that looks right at 96 DPI reads as a hairline at
  150% (first live run, 2026-08-22). ALineHeight is the run rect's height;
  amplitude and half-period scale with it. }
procedure DrawSquiggle(ACanvas: TCanvas; AXFrom, AXTo, ABottom,
  ALineHeight: Integer; AColor: TColor);
var
  LX, LAmp, LStep, LYLow, LYHigh, LPass: Integer;
  LUp: Boolean;
begin
  LAmp := Max(2, ALineHeight div 6);    // 16-20px line -> 3, scales up
  LStep := LAmp;                        // ~45-degree zigzag
  if AXTo - AXFrom < LStep then
    Exit;
  ACanvas.Pen.Color := AColor;
  ACanvas.Pen.Width := 1;
  ACanvas.Pen.Style := psSolid;
  // TWO passes one pixel apart: a single 1px zigzag reads as washed-out
  // next to the editor's text (live feedback, 2026-08-22), while a wide
  // pen draws blocky joints at the peaks. Double-stroking is how the
  // classic squiggle gets its weight.
  for LPass := 0 to 1 do
  begin
    LYLow := ABottom - 1 - LPass;       // wave lives inside the line rect
    LYHigh := LYLow - LAmp;
    ACanvas.MoveTo(AXFrom, LYLow);
    LUp := True;
    LX := AXFrom + LStep;
    while LX <= AXTo do
    begin
      if LUp then
        ACanvas.LineTo(LX, LYHigh)
      else
        ACanvas.LineTo(LX, LYLow);
      LUp := not LUp;
      Inc(LX, LStep);
    end;
  end;
end;

constructor TPasErrorPaintNotifier.Create;
begin
  inherited Create;
  // The base class dispatches through event properties, not virtuals -
  // AllowedEvents is the only override, the handler rides the property.
  OnEditorPaintText := HandlePaintText;
end;

function TPasErrorPaintNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevPaintTextEvents];
end;

procedure TPasErrorPaintNotifier.HandlePaintText(const ARect: TRect;
  const AColNum: SmallInt; const AText: string;
  const ASyntaxCode: TOTASyntaxCode; const AHilight, ABeforeEvent: Boolean;
  var AAllowDefaultPainting: Boolean;
  const AContext: INTACodeEditorPaintContext);
var
  LDiags: TArray<TLspDiagnostic>;
  LIdx, LRow, LFrom, LTo, LColTo, LXFrom, LXTo: Integer;
begin
  // AFTER the IDE painted the run - underlining is an overlay, never a
  // replacement (AllowDefaultPainting stays untouched).
  if ABeforeEvent or (AContext = nil) or (AText = '') then
    Exit;
  if ASyntaxCode = atFolded then
    Exit;   // a folded box stands for many lines; per-line ranges lie there
  if not IsPascalSourceFile(AContext.FileName) then
    Exit;
  if not LspTryGetDiagnostics(AContext.FileName, LDiags) then
    Exit;
  LRow := AContext.LogicalLineNum;
  for LIdx := 0 to High(LDiags) do
  begin
    if LDiags[LIdx].Row <> LRow then
      Continue;
    // ColTo is exclusive; a zero-width diagnostic degrades to one cell -
    // the same rule the retired trait code applied.
    LColTo := LDiags[LIdx].ColTo;
    if LColTo <= LDiags[LIdx].ColFrom then
      LColTo := LDiags[LIdx].ColFrom + 1;
    // Intersect the diagnostic's columns with this run's [AColNum, +Len).
    LFrom := Max(LDiags[LIdx].ColFrom, AColNum);
    LTo := Min(LColTo, AColNum + Length(AText));
    if LTo <= LFrom then
      Continue;
    // Columns -> pixels PROPORTIONALLY within the run's own rect. The rect
    // is device pixels while CellSize answers unscaled units, so cell
    // arithmetic drew the wave at ~2/3 width on a scaled monitor (first
    // live run); the run's width over its own character count cannot drift.
    LXFrom := ARect.Left
      + MulDiv(LFrom - AColNum, ARect.Width, Length(AText));
    LXTo := ARect.Left
      + MulDiv(LTo - AColNum, ARect.Width, Length(AText));
    DrawSquiggle(AContext.Canvas, Max(LXFrom, ARect.Left),
      Min(LXTo, ARect.Right), ARect.Bottom, ARect.Height,
      SeverityColor(LDiags[LIdx].Severity));
  end;
end;

{ Fresh diagnostics for APath: repaint every visible view of that file, so
  squiggles track the analysis without any polling. }
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

procedure InitializeErrorPaint;
var
  LServices: INTACodeEditorServices;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  GNotifier := TPasErrorPaintNotifier.Create;
  GNotifierIndex := LServices.AddEditorEventsNotifier(GNotifier);
  if GNotifierIndex < 0 then
  begin
    GNotifier := nil;   // refcount frees it
    Exit;
  end;
  LspSetDiagnosticsChangedListener(InvalidateViewsOf);
end;

procedure FinalizeErrorPaint;
var
  LServices: INTACodeEditorServices;
begin
  LspSetDiagnosticsChangedListener(nil);
  if GNotifierIndex < 0 then
    Exit;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

end.
