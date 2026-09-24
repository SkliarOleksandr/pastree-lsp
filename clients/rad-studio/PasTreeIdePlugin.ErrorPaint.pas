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
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings;   // PasTreeErrorSquigglesEnabled, IdeErrorMarkStyle

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
  GListener: Integer = 0;   // LspAddDiagnosticsChangedListener handle

{ Severity -> underline color: LSP 1 error, 2 warning, 3 information, 4 hint -
  the same red/orange/gray family the IDE's own Error Insight draws, with the
  bottom two sharing the gray. TColor is BGR. The error red is the IDE's own
  crimson (220,20,60 - read off its underline, 2026-09-24), not clRed. }
function SeverityColor(ASeverity: Integer): TColor;
begin
  case ASeverity of
    1: Result := TColor($003C14DC);   // crimson
    2: Result := TColor($0000A5FF);   // orange
  else
    Result := TColor($00909090);      // quiet gray for hints
  end;
end;

{ THE UNDERLINE, in the shape the IDE's own Error Insight is set to draw
  (IdeErrorMarkStyle - Tools > Options > Error Insight > "Editor rendering
  style"), so switching to ours does not also switch the look.

  MEASURED, NOT INVENTED: every constant below was read off the IDE's own
  underline under the same identifier, at a 26px line (150%), one screenshot
  per style (Alex, 2026-09-24). cRefLine is that line height; the paint
  canvas is in device pixels, so everything scales by ALineHeight / cRefLine
  (a hardcoded 2px wave that looks right at 96 DPI reads as a hairline at
  150% - first live run, 2026-08-22). Offsets are up from the line rect's
  bottom edge, in pixels at the reference size:

    Classic      triangle wave, period 10, crest centre 5.0, trough 0.0,
                 stroke 1.6 - a 45-degree zigzag whose troughs the rect's
                 bottom flattens; first crest 0.5px past the anchor
    Smooth Wave  sine, period 12.5, crest 4.5, trough 0.5, stroke 3.0 -
                 bolder; mid-height 1px past the anchor, heading down
    Solid Line   3 rows flat along the bottom, not anti-aliased
    Dots         discs of radius 2.3, pitch 7, centre 2.0; the first 3px
                 past the anchor

  Both waves' troughs are cut by the rect's bottom, as the IDE's are.

  ANTI-ALIASED LIKE THE IDE's, WITHOUT GDI+: coverage is computed per pixel
  (four sub-columns, each an exact vertical interval of the shape), written
  into a small premultiplied 32-bit DIB and AlphaBlend-ed onto the canvas.
  AlphaBlend takes logical coordinates through the same DC as every other
  GDI call on this canvas, which GDI+ over the IDE's HDC would not promise;
  and there is no GdiplusStartup to own inside a package. Stacked 1px GDI
  passes (0.52.4) could not match the IDE's weight - three passes at 150%
  still read as a jagged zigzag beside its rounded wave.

  PHASE FROM THE DIAGNOSTIC'S START (AXAnchor), not the run's left edge: a
  diagnostic over several coalesced runs is one unbroken wave, and the wave
  starts where the IDE's does (the offsets in the table). }
const
  cRefLine = 26.0;
  cSubCols = 4;

type
  TMarkShape = record
    Style: TErrorMarkStyle;
    Scale, Anchor, Bottom: Single;
  end;

{ The shape's vertical extent [ATop, ABot) in the sub-column at AX, in canvas
  pixels (y grows downward). False when this sub-column has none. }
function ShapeInterval(const AShape: TMarkShape; AX: Single;
  out ATop, ABot: Single): Boolean;
var
  S, LPeriod, LCrest, LTrough, LHalfW, LT, LY, LSlope, LPitch, LR, LDx,
    LCx: Single;
begin
  S := AShape.Scale;
  Result := True;
  case AShape.Style of
    emsSolidLine:
      begin
        ABot := AShape.Bottom;
        ATop := ABot - Max(1, Round(3 * S));
      end;
    emsDots:
      begin
        LPitch := 7 * S;
        LR := 2.3 * S;
        // Nearest disc centre; the first one sits 3px past the anchor.
        LCx := AShape.Anchor + 3.0 * S
          + LPitch * Round((AX - AShape.Anchor - 3.0 * S) / LPitch);
        LDx := AX - LCx;
        if Abs(LDx) >= LR then
          Exit(False);
        LY := AShape.Bottom - 2.0 * S;
        LHalfW := Sqrt(LR * LR - LDx * LDx);
        ATop := LY - LHalfW;
        ABot := LY + LHalfW;
      end;
    emsSmoothWave:
      begin
        LPeriod := 12.5 * S;
        LCrest := AShape.Bottom - 4.5 * S;
        LTrough := AShape.Bottom - 0.5 * S;
        LHalfW := 1.5 * S;
        LT := 2 * Pi * (AX - AShape.Anchor - 1.0 * S) / LPeriod;
        // Mid-height at the anchor, heading DOWN (y grows downward), so the
        // first trough is a quarter period in.
        LY := (LCrest + LTrough) / 2 + (LTrough - LCrest) / 2 * Sin(LT);
        LSlope := (LTrough - LCrest) / 2 * (2 * Pi / LPeriod) * Cos(LT);
        LHalfW := LHalfW * Sqrt(1 + LSlope * LSlope);
        ATop := LY - LHalfW;
        ABot := LY + LHalfW;
      end;
  else
    begin
      // Classic: a crest half a pixel past the anchor, 45-degree flanks to a
      // trough ON the rect's bottom edge - clipped there into the IDE's flat,
      // five-pixel-wide bottom.
      LPeriod := 10 * S;
      LCrest := AShape.Bottom - 5.0 * S;
      LTrough := AShape.Bottom;
      LT := (AX - AShape.Anchor - 0.5 * S) / LPeriod;
      LT := LT - Floor(LT);
      LY := LCrest + (LTrough - LCrest) * (1 - Abs(1 - 2 * LT));
      LSlope := 2 * (LTrough - LCrest) / LPeriod;
      LHalfW := 0.8 * S * Sqrt(1 + LSlope * LSlope);
      ATop := LY - LHalfW;
      ABot := LY + LHalfW;
    end;
  end;
end;

procedure DrawErrorMark(ACanvas: TCanvas; AXFrom, AXTo, AXAnchor, ARectTop,
  ABottom, ALineHeight: Integer; AColor: TColor; AStyle: TErrorMarkStyle);
var
  LShape: TMarkShape;
  LW, LH, LTopRow, LX, LRow, LSub, LIdx: Integer;
  LCover: TArray<Single>;
  LSX, LTop, LBot, LA: Single;
  LInfo: TBitmapInfo;
  LBits: Pointer;
  LDib, LOld: HBITMAP;
  LMemDC: HDC;
  LPx: PCardinal;
  LRgb: Cardinal;
  LAlpha, LR, LG, LB: Cardinal;
  LBlend: TBlendFunction;
begin
  LW := AXTo - AXFrom;
  if LW <= 0 then
    Exit;
  LShape.Style := AStyle;
  LShape.Scale := ALineHeight / cRefLine;
  LShape.Anchor := AXAnchor;
  LShape.Bottom := ABottom;
  // Every shape stays within 6 reference px of the bottom; one row spare.
  LTopRow := Max(ARectTop, ABottom - Ceil(7 * LShape.Scale) - 1);
  LH := ABottom - LTopRow;
  if LH <= 0 then
    Exit;

  // Coverage per pixel: the mean, over cSubCols sub-columns, of how much of
  // the pixel's row the shape's interval in that sub-column covers.
  SetLength(LCover, LW * LH);
  for LX := 0 to LW - 1 do
    for LSub := 0 to cSubCols - 1 do
    begin
      LSX := AXFrom + LX + (LSub + 0.5) / cSubCols;
      if not ShapeInterval(LShape, LSX, LTop, LBot) then
        Continue;
      LTop := Max(LTop, LTopRow);
      LBot := Min(LBot, ABottom);   // clipped at the line rect, as the IDE's
      for LRow := Floor(LTop) - LTopRow to Ceil(LBot) - LTopRow - 1 do
      begin
        if (LRow < 0) or (LRow >= LH) then
          Continue;
        LA := Min(LBot, LTopRow + LRow + 1) - Max(LTop, LTopRow + LRow);
        if LA > 0 then
        begin
          LIdx := LRow * LW + LX;
          LCover[LIdx] := LCover[LIdx] + LA / cSubCols;
        end;
      end;
    end;

  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.bmiHeader.biSize := SizeOf(LInfo.bmiHeader);
  LInfo.bmiHeader.biWidth := LW;
  LInfo.bmiHeader.biHeight := -LH;   // top-down rows
  LInfo.bmiHeader.biPlanes := 1;
  LInfo.bmiHeader.biBitCount := 32;
  LInfo.bmiHeader.biCompression := BI_RGB;
  LMemDC := CreateCompatibleDC(ACanvas.Handle);
  if LMemDC = 0 then
    Exit;
  try
    LDib := CreateDIBSection(LMemDC, LInfo, DIB_RGB_COLORS, LBits, 0, 0);
    if (LDib = 0) or (LBits = nil) then
      Exit;
    try
      LRgb := ColorToRGB(AColor);
      LR := LRgb and $FF;
      LG := (LRgb shr 8) and $FF;
      LB := (LRgb shr 16) and $FF;
      LPx := LBits;
      // PREMULTIPLIED, as AlphaBlend's AC_SRC_ALPHA requires: B,G,R scaled
      // by alpha, in BGRA byte order.
      for LIdx := 0 to LW * LH - 1 do
      begin
        LAlpha := Round(Min(1, LCover[LIdx]) * 255);
        LPx^ := (LAlpha shl 24) or ((LR * LAlpha div 255) shl 16)
          or ((LG * LAlpha div 255) shl 8) or (LB * LAlpha div 255);
        Inc(LPx);
      end;
      LOld := SelectObject(LMemDC, LDib);
      try
        LBlend.BlendOp := AC_SRC_OVER;
        LBlend.BlendFlags := 0;
        LBlend.SourceConstantAlpha := 255;
        LBlend.AlphaFormat := AC_SRC_ALPHA;
        Winapi.Windows.AlphaBlend(ACanvas.Handle, AXFrom, LTopRow, LW, LH,
          LMemDC, 0, 0, LW, LH, LBlend);
      finally
        SelectObject(LMemDC, LOld);
      end;
    finally
      DeleteObject(LDib);
    end;
  finally
    DeleteDC(LMemDC);
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
  LIdx, LRow, LFrom, LTo, LColTo, LXFrom, LXTo, LXAnchor: Integer;
begin
  // AFTER the IDE painted the run - underlining is an overlay, never a
  // replacement (AllowDefaultPainting stays untouched).
  if ABeforeEvent or (AContext = nil) or (AText = '') then
    Exit;
  // The user's choice between these underlines and the IDE's own Error
  // Insight - from the settings cache, so no registry read per run.
  if not PasTreeErrorSquigglesEnabled then
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
    // Where the DIAGNOSTIC starts, possibly left of this run: the wave's
    // phase, so it continues unbroken across the runs it spans.
    LXAnchor := ARect.Left + MulDiv(LDiags[LIdx].ColFrom - AColNum,
      ARect.Width, Length(AText));
    DrawErrorMark(AContext.Canvas, Max(LXFrom, ARect.Left),
      Min(LXTo, ARect.Right), LXAnchor, ARect.Top, ARect.Bottom,
      ARect.Height, SeverityColor(LDiags[LIdx].Severity), IdeErrorMarkStyle);
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
  GListener := LspAddDiagnosticsChangedListener(InvalidateViewsOf);
end;

procedure FinalizeErrorPaint;
var
  LServices: INTACodeEditorServices;
begin
  LspRemoveDiagnosticsChangedListener(GListener);
  GListener := 0;
  if GNotifierIndex < 0 then
    Exit;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

end.
