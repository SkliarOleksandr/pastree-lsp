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

  THE SAME DIAGNOSTICS IN TWO MORE PLACES (0.80.0), so a problem off screen
  is findable rather than merely visible when scrolled to: a mark per line
  in the gutter, and a mark per line on the editor's scroll bar
  (INTACodeEditorScrollbarAnnotation - RAD Studio 12 and later; Delphi 11.3
  has no such interface). Both follow the underlines' gate and the user's
  Error Insight level, and a switch of their own (ErrorMarksEnabled).

  THE GUTTER MARK SITS IN THE LINE-NUMBER COLUMN, drawn after the number at
  PaintGutter's pgsLineNumber: the column is as wide as the file's widest
  number, right-aligned, and the IDE writes a number only on every tenth and
  the caret's line, so its left part is free nearly everywhere. A column of
  our own (RequestGutterColumn, 0.80.0 before the IDE test) cost a glyph's
  width on every line of every editor, and requested at package load it
  landed left of the line numbers whatever position it named.

  ROWS FROM PasTreeIdePlugin.DiagnosticLines, not from the cache: lines
  inserted or deleted above a problem since its answer move its underline,
  gutter mark and scroll bar mark with it.
}

interface

uses
  System.UITypes,
  ToolsAPI;

procedure InitializeErrorPaint;
procedure FinalizeErrorPaint;

/// <summary>
/// The buffer of AView was edited (IdleSync's EditorViewModified): our
/// marks follow the lines that moved (PasTreeIdePlugin.DiagnosticLines).
/// </summary>
procedure ErrorPaintViewModified(const AView: IOTAEditView);

/// <summary>
/// The gutter and scroll bar marks' switch changed (Settings): every
/// editor repainted.
/// </summary>
procedure ErrorMarksSettingChanged;

/// <summary>
/// A severity's underline colour (LSP 1 error, 2 warning, 3+ hint) - also
/// the colour of the "Error:" prefix in Tooltip symbol insight, so the hint
/// names a problem in the colour it is underlined in.
/// </summary>
function SeverityColor(ASeverity: Integer): TColor;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Types,
  System.Math,
  System.Generics.Collections,
  Vcl.Graphics,
  Vcl.Controls,
  ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.DiagnosticLines,
  PasTreeIdePlugin.PaintLines,
  PasTreeIdePlugin.NativeErrorInsight,   // CoreIdeExport
  PasTreeIdePlugin.Settings;   // PasTreeErrorSquigglesEnabled, IdeErrorMarkStyle

type
  TPasErrorPaintNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
    function AllowedGutterStages: TPaintGutterStages; override;
  public
    constructor Create;
    procedure HandlePaintGutter(const ARect: TRect;
      const AStage: TPaintGutterStage; const ABeforeEvent: Boolean;
      var AAllowDefaultPainting: Boolean;
      const AContext: INTACodeEditorPaintContext);
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
  // The scroll bar annotation (RegisterScrollbarAnnotation), -1 = none.
  GScrollIndex: Integer = -1;
  // Said once to the detail log: the line-number rect the gutter glyph is
  // placed in, and that the scroll bar asked - the two shapes ToolsAPI does
  // not document.
  GGutterShapeNoted: Boolean = False;
  GScrollAskNoted: Boolean = False;

const
  // The gutter glyph's size and its gap to the line number, at 96 DPI.
  cGutterGlyph = 12;
  cGutterGlyphGap = 4;
  // The scroll bar mark: its width and offset in the bar (1..15, 0..15).
  cScrollMarkWidth = 5;
  cScrollMarkStart = 0;

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
  OnEditorPaintGutter := HandlePaintGutter;
end;

function TPasErrorPaintNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevPaintTextEvents, cevPaintGutterEvents];
end;

{ pgsLineNumber is per line (the IDE's own PaintGutter demo reads the
  line from it), and the glyph is drawn into the line-number column. }
function TPasErrorPaintNotifier.AllowedGutterStages: TPaintGutterStages;
begin
  Result := [pgsLineNumber];
end;

procedure TPasErrorPaintNotifier.HandlePaintText(const ARect: TRect;
  const AColNum: SmallInt; const AText: string;
  const ASyntaxCode: TOTASyntaxCode; const AHilight, ABeforeEvent: Boolean;
  var AAllowDefaultPainting: Boolean;
  const AContext: INTACodeEditorPaintContext);
var
  LDiags: TArray<TLspDiagnostic>;
  LLine: INTACodeEditorLineState;
  LIdx, LRow, LFrom, LTo, LColTo, LXFrom, LXTo, LXAnchor, LMaxSev: Integer;
begin
  // AFTER the IDE painted the run - underlining is an overlay, never a
  // replacement (AllowDefaultPainting stays untouched).
  if ABeforeEvent or (AContext = nil) or (AText = '') then
    Exit;
  // The user's choice between these underlines and the IDE's own Error
  // Insight - from the settings cache, so no registry read per run.
  if not PasTreeErrorSquigglesEnabled then
    Exit;
  // atFolded is exported by ToolsAPI only since Delphi 12; the 11.3 editor
  // passes the same code, so the value is pinned for it.
  if ASyntaxCode = {$IF Declared(atFolded)} atFolded {$ELSE} 40 {$IFEND} then
    Exit;   // a folded box stands for many lines; per-line ranges lie there
  if not IsPascalSourceFile(AContext.FileName) then
    Exit;
  if not LiveDiagnostics(AContext.FileName, LDiags) then
    Exit;
  // Not AContext.LogicalLineNum: below a folded block it names another
  // line (PasTreeIdePlugin.PaintLines).
  LRow := PaintedRow(AContext, AColNum, AText, LLine);
  if LRow < 1 then
    Exit;
  // The level the user had chosen for Error Insight, now ours to honour.
  LMaxSev := PasTreeErrorMaxSeverity;
  for LIdx := 0 to High(LDiags) do
  begin
    if (LDiags[LIdx].Row <> LRow) or (LDiags[LIdx].Severity > LMaxSev) then
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

{ THE GUTTER MARK: a crimson disc with a white cross for an error, an orange
  triangle with a white bar and dot for a warning, a small grey disc for a
  hint - the severity readable from the shape as well as the colour, and
  none of them the breakpoint's plain red dot.

  Rasterized like the underline (DrawErrorMark): coverage per sub-sample
  into a premultiplied DIB, AlphaBlend-ed onto the canvas, so the edges are
  smooth at any scale. The shapes are laid out in a [-1, 1] square, y down.

  IDEMPOTENT: the column is filled with its own background first (sampled
  at its corner, which no mark reaches), because the stage it is drawn at
  may come more than once per line. }
const
  cGlyphSub = 4;

function DistToSegment(AX, AY, AX1, AY1, AX2, AY2: Single): Single;
var
  LDx, LDy, LLen, LT: Single;
begin
  LDx := AX2 - AX1;
  LDy := AY2 - AY1;
  LLen := LDx * LDx + LDy * LDy;
  if LLen = 0 then
    LT := 0
  else
    LT := EnsureRange(((AX - AX1) * LDx + (AY - AY1) * LDy) / LLen, 0, 1);
  Result := Sqrt(Sqr(AX - (AX1 + LT * LDx)) + Sqr(AY - (AY1 + LT * LDy)));
end;

{ 0 = outside, 1 = the shape's colour, 2 = the white symbol on it. }
function GlyphAt(ASeverity: Integer; AX, AY: Single): Integer;
var
  LInside: Boolean;
begin
  Result := 0;
  case ASeverity of
    1:
      begin
        if AX * AX + AY * AY > 1 then
          Exit;
        Result := 1;
        if (DistToSegment(AX, AY, -0.42, -0.42, 0.42, 0.42) < 0.16) or
           (DistToSegment(AX, AY, -0.42, 0.42, 0.42, -0.42) < 0.16) then
          Result := 2;
      end;
    2:
      begin
        // Apex (0, -1), base from (-1, 0.85) to (1, 0.85): below the apex's
        // two flanks and above the base.
        LInside := (AY <= 0.85) and (AY + 1 >= 1.85 * AX) and
          (AY + 1 >= -1.85 * AX);
        if not LInside then
          Exit;
        Result := 1;
        if (DistToSegment(AX, AY, 0, -0.3, 0, 0.28) < 0.13) or
           (Sqr(AX) + Sqr(AY - 0.58) < Sqr(0.13)) then
          Result := 2;
      end;
  else
    if AX * AX + AY * AY <= Sqr(0.5) then
      Result := 1;
  end;
end;

procedure DrawGutterGlyph(ACanvas: TCanvas; const ARect: TRect;
  ASeverity: Integer);
var
  LSize, LLeft, LTop, LX, LY, LSx, LSy, LKind: Integer;
  LHalf, LCx, LCy, LU, LV: Single;
  LShape, LMark: Integer;
  LBack: COLORREF;
  LInfo: TBitmapInfo;
  LBits: Pointer;
  LDib, LOld: HBITMAP;
  LMemDC: HDC;
  LPx: PCardinal;
  LRgb: Cardinal;
  LAlpha, LR, LG, LB, LWhite: Cardinal;
  LBlend: TBlendFunction;
begin
  if (ARect.Width <= 2) or (ARect.Height <= 2) then
    Exit;
  LBack := GetPixel(ACanvas.Handle, ARect.Left, ARect.Top);
  if LBack <> CLR_INVALID then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := TColor(LBack);
    ACanvas.FillRect(ARect);
  end;
  LSize := Min(ARect.Width, ARect.Height) - 2;
  if LSize < 5 then
    Exit;
  LLeft := ARect.Left + (ARect.Width - LSize) div 2;
  LTop := ARect.Top + (ARect.Height - LSize) div 2;
  LHalf := LSize / 2;

  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.bmiHeader.biSize := SizeOf(LInfo.bmiHeader);
  LInfo.bmiHeader.biWidth := LSize;
  LInfo.bmiHeader.biHeight := -LSize;
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
      LRgb := ColorToRGB(SeverityColor(ASeverity));
      LPx := LBits;
      for LY := 0 to LSize - 1 do
        for LX := 0 to LSize - 1 do
        begin
          LShape := 0;
          LMark := 0;
          for LSy := 0 to cGlyphSub - 1 do
            for LSx := 0 to cGlyphSub - 1 do
            begin
              LCx := LX + (LSx + 0.5) / cGlyphSub;
              LCy := LY + (LSy + 0.5) / cGlyphSub;
              LU := (LCx - LHalf) / LHalf;
              LV := (LCy - LHalf) / LHalf;
              LKind := GlyphAt(ASeverity, LU, LV);
              if LKind = 1 then
                Inc(LShape)
              else if LKind = 2 then
                Inc(LMark);
            end;
          // Premultiplied BGRA: the shape's colour and white, each by its
          // share of the samples.
          LAlpha := (LShape + LMark) * 255 div (cGlyphSub * cGlyphSub);
          LWhite := LMark * 255 div (cGlyphSub * cGlyphSub);
          LR := ((LRgb and $FF) * Cardinal(LShape)) div (cGlyphSub * cGlyphSub)
            + LWhite;
          LG := (((LRgb shr 8) and $FF) * Cardinal(LShape))
            div (cGlyphSub * cGlyphSub) + LWhite;
          LB := (((LRgb shr 16) and $FF) * Cardinal(LShape))
            div (cGlyphSub * cGlyphSub) + LWhite;
          LPx^ := (LAlpha shl 24) or (Min(LR, 255) shl 16)
            or (Min(LG, 255) shl 8) or Min(LB, 255);
          Inc(LPx);
        end;
      LOld := SelectObject(LMemDC, LDib);
      try
        LBlend.BlendOp := AC_SRC_OVER;
        LBlend.BlendFlags := 0;
        LBlend.SourceConstantAlpha := 255;
        LBlend.AlphaFormat := AC_SRC_ALPHA;
        Winapi.Windows.AlphaBlend(ACanvas.Handle, LLeft, LTop, LSize, LSize,
          LMemDC, 0, 0, LSize, LSize, LBlend);
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

{ The marks' gate: the underlines are ours (PasTreeErrorSquigglesEnabled -
  with the IDE's Error Insight drawing, its own marks are the ones there)
  and their own switch is on. }
function ErrorMarksActive: Boolean;
begin
  Result := PasTreeErrorSquigglesEnabled and ErrorMarksEnabled;
end;

{ The worst severity per row, within the user's Error Insight level - LSP 1
  is the worst, so the smallest number wins. }
function WorstByRow(const ADiags: TArray<TLspDiagnostic>):
  TDictionary<Integer, Integer>;
var
  LMaxSev, LIdx, LSev: Integer;
begin
  Result := TDictionary<Integer, Integer>.Create;
  LMaxSev := PasTreeErrorMaxSeverity;
  for LIdx := 0 to High(ADiags) do
  begin
    if ADiags[LIdx].Severity > LMaxSev then
      Continue;
    if not Result.TryGetValue(ADiags[LIdx].Row, LSev) or
       (ADiags[LIdx].Severity < LSev) then
      Result.AddOrSetValue(ADiags[LIdx].Row, ADiags[LIdx].Severity);
  end;
end;

{ One visible line's worst severity: its own row's, or - a folded line
  standing for a block - the worst of the rows it hides. 0 = none. }
function LineSeverity(const ALine: INTACodeEditorLineState;
  AWorst: TDictionary<Integer, Integer>): Integer;
var
  LFrom, LTo, LRow, LSev: Integer;
begin
  Result := 0;
  if ALine = nil then
    Exit;
  LFrom := ALine.GetLogicalLineNum;
  LTo := LFrom;
  if ALine.IsElidedLine then
  begin
    LFrom := ALine.GetElidedLineStart;
    LTo := ALine.GetElidedLineEnd;
  end;
  for LRow := LFrom to LTo do
    if AWorst.TryGetValue(LRow, LSev) and ((Result = 0) or (LSev < Result)) then
      Result := LSev;
end;

{ WHERE THE IDE DREW THE NUMBER, read off the pixels: the rect it paints
  the number in also holds a right margin and the modified-lines bar, so
  "right-aligned in the rect" put the glyph onto a 2-digit number
  (2026-11-02). A column holds text when some pixel differs from the
  background (the rect's corner); the modified-lines bar is told apart by
  reaching the top row, which text never does. Error lines only, so a few
  hundred GetPixel calls are a paint's worth, not a scroll's. }
function IsInk(ADC: HDC; ABack: COLORREF; AX, AY: Integer): Boolean;
var
  LPx: COLORREF;
begin
  LPx := GetPixel(ADC, AX, AY);
  Result := (LPx <> CLR_INVALID) and
    (Abs(Integer(GetRValue(LPx)) - GetRValue(ABack))
     + Abs(Integer(GetGValue(LPx)) - GetGValue(ABack))
     + Abs(Integer(GetBValue(LPx)) - GetBValue(ABack)) > 60);
end;

function IsTextColumn(ADC: HDC; ABack: COLORREF; AX: Integer;
  const ARect: TRect): Boolean;
var
  LY: Integer;
begin
  Result := False;
  if IsInk(ADC, ABack, AX, ARect.Top) then
    Exit;   // a full-height bar, not text
  for LY := ARect.Top + 1 to ARect.Bottom - 2 do
    if IsInk(ADC, ABack, AX, LY) then
      Exit(True);
end;

{ Columns AFrom..ATo-1, over ARect's rows, hold nothing but the background
  of ARect's corner - a breakpoint or a bookmark there is ink. }
function BlankColumns(ACanvas: TCanvas; const ARect: TRect;
  AFrom, ATo: Integer): Boolean;
var
  LDC: HDC;
  LBack: COLORREF;
  LX, LY: Integer;
begin
  LDC := ACanvas.Handle;
  LBack := GetPixel(LDC, ARect.Left, ARect.Top);
  if (LBack = CLR_INVALID) or (AFrom < 0) then
    Exit(False);
  for LX := AFrom to ATo - 1 do
    for LY := ARect.Top to ARect.Bottom - 1 do
      if IsInk(LDC, LBack, LX, LY) then
        Exit(False);
  Result := True;
end;

{ The text's extent in ARect from AFrom on: ALeft..ARight inclusive, False
  when there is none. }
function TextExtent(ACanvas: TCanvas; const ARect: TRect; AFrom: Integer;
  out ALeft, ARight: Integer): Boolean;
var
  LDC: HDC;
  LBack: COLORREF;
begin
  Result := False;
  LDC := ACanvas.Handle;
  LBack := GetPixel(LDC, ARect.Left, ARect.Top);
  if LBack = CLR_INVALID then
    Exit;
  ARight := ARect.Right - 1;
  while (ARight >= AFrom) and not IsTextColumn(LDC, LBack, ARight, ARect) do
    Dec(ARight);
  if ARight < AFrom then
    Exit;
  ALeft := AFrom;
  while not IsTextColumn(LDC, LBack, ALeft, ARect) do
    Inc(ALeft);
  Result := True;
end;

procedure TPasErrorPaintNotifier.HandlePaintGutter(const ARect: TRect;
  const AStage: TPaintGutterStage; const ABeforeEvent: Boolean;
  var AAllowDefaultPainting: Boolean;
  const AContext: INTACodeEditorPaintContext);
var
  LDiags: TArray<TLspDiagnostic>;
  LWorst: TDictionary<Integer, Integer>;
  LState: INTACodeEditorState;
  LLine: INTACodeEditorLineState;
  LCanvas: TCanvas;
  LSev, LPPI, LCell, LGap, LNumberLeft, LNumberRight: Integer;
  LGlyph, LShifted: TRect;
  LWipe: Boolean;
  LBack: COLORREF;
begin
  if ABeforeEvent or (AContext = nil) or (AStage <> pgsLineNumber) then
    Exit;
  if not ErrorMarksActive or not IsPascalSourceFile(AContext.FileName) then
    Exit;
  try
    if not LiveDiagnostics(AContext.FileName, LDiags) or (LDiags = nil) then
      Exit;
    LState := AContext.EditorState;
    LCanvas := AContext.Canvas;
    // Not AContext.LineState: below a folded block it is another line
    // (PasTreeIdePlugin.PaintLines).
    LLine := PaintedLineState(AContext);
    if (LState = nil) or (LCanvas = nil) or (LLine = nil) then
      Exit;
    LWorst := WorstByRow(LDiags);
    try
      LSev := LineSeverity(LLine, LWorst);
    finally
      LWorst.Free;
    end;
    if LSev = 0 then
      Exit;
    // The glyph goes at the column's left edge, and the number is wiped
    // only when it comes closer than a small gap (TextExtent). The glyph's
    // own cell is not scanned: a second paint of the line finds the glyph
    // there, not the number.
    LPPI := 96;
    if AContext.EditControl <> nil then
      LPPI := AContext.EditControl.CurrentPPI;
    LCell := Min(MulDiv(cGutterGlyph, LPPI, 96), ARect.Height - 2) + 2;
    LGap := MulDiv(cGutterGlyphGap, LPPI, 96);
    LGlyph := Rect(ARect.Left + 1, ARect.Top, ARect.Left + 1 + LCell,
      ARect.Bottom);
    LWipe := False;
    LNumberLeft := -1;
    LNumberRight := -1;
    if TextExtent(LCanvas, ARect, LGlyph.Right, LNumberLeft, LNumberRight) then
    begin
      // Text right at the cell's edge may go on under it: then its left is
      // where its width says.
      if LNumberLeft = LGlyph.Right then
        LNumberLeft := LNumberRight + 1 - LCanvas.TextWidth(
          IntToStr(LLine.GetLogicalLineNum));
      // Too close: the glyph moves left by what the gap lacks, into the
      // empty gutter before the column when it is empty there (no
      // breakpoint, no bookmark); the number is wiped only when it is not.
      // A fixed gap that wiped instead took "93" off for 2 px (2026-11-02).
      if LNumberLeft < LGlyph.Right + LGap then
      begin
        LShifted := LGlyph;
        LShifted.Offset(LNumberLeft - LGap - LGlyph.Right, 0);
        if BlankColumns(LCanvas, ARect, LShifted.Left, ARect.Left) then
          LGlyph := LShifted
        else
          LWipe := True;
      end;
    end;
    if not GGutterShapeNoted then
    begin
      GGutterShapeNoted := True;
      LspLogDetail(Format('error marks: the line-number rect is %d..%d, %d px'
        + ' high, %d PPI, the number at %d..%d, the glyph %d px at %d - %s',
        [ARect.Left, ARect.Right, ARect.Height, LPPI, LNumberLeft,
         LNumberRight, LCell - 2, LGlyph.Left,
         IfThen(LWipe, 'the number wiped', 'the number kept')]));
    end;
    if LWipe then
    begin
      LBack := GetPixel(LCanvas.Handle, ARect.Left, ARect.Top);
      if LBack <> CLR_INVALID then
      begin
        LCanvas.Brush.Style := bsSolid;
        LCanvas.Brush.Color := TColor(LBack);
        LCanvas.FillRect(Rect(ARect.Left, ARect.Top, LNumberRight + 1,
          ARect.Bottom));
      end;
    end;
    DrawGutterGlyph(LCanvas, LGlyph, LSev);
  except
    // A paint event must not raise into the editor; the next paint retries.
    on E: Exception do
      if not GGutterShapeNoted then
      begin
        GGutterShapeNoted := True;
        LspLogDetail('error marks: gutter paint failed: ' + E.ClassName
          + ': ' + E.Message);
      end;
  end;
end;

{$IF Declared(INTACodeEditorScrollbarAnnotation)}
{ THE SCROLL BAR MARKS. The editor asks for them (GetScrollbarAnnotations)
  and draws each entry in the colour given with it, a severity's underline
  colour - so a whole file's problems are visible at a glance and a click
  on the bar goes there. The IDE's own "Toggle Scroll bar annotations"
  turns every annotation off, ours with them. }
type
  TPasScrollbarMarks = class(TNotifierObject, INTACodeEditorScrollbarAnnotation)
  private
    FEnabled: Boolean;
    FWidth, FStart: Integer;
  public
    constructor Create;
    function GetEnabled: Boolean;
    procedure SetEnabled(const Value: Boolean);
    function GetName: string;
    function GetWidth: Integer;
    procedure SetWidth(const Value: Integer);
    function GetStart: Integer;
    procedure SetStart(const Value: Integer);
    function GetColor: TColor;
    function GetCustomDraw: Boolean;
    procedure DrawMark(const AEditor: TWinControl; LineNum: Integer;
      ACanvas: TCanvas; ARect: TRect);
    procedure GetScrollbarAnnotations(const AEditor: TWinControl);
  end;

var
  GScrollMarks: INTACodeEditorScrollbarAnnotation;

constructor TPasScrollbarMarks.Create;
begin
  inherited Create;
  FEnabled := True;
  FWidth := cScrollMarkWidth;
  FStart := cScrollMarkStart;
end;

function TPasScrollbarMarks.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure TPasScrollbarMarks.SetEnabled(const Value: Boolean);
begin
  FEnabled := Value;
end;

function TPasScrollbarMarks.GetName: string;
begin
  Result := 'PasTree errors';
end;

function TPasScrollbarMarks.GetWidth: Integer;
begin
  Result := FWidth;
end;

procedure TPasScrollbarMarks.SetWidth(const Value: Integer);
begin
  FWidth := Value;
end;

function TPasScrollbarMarks.GetStart: Integer;
begin
  Result := FStart;
end;

procedure TPasScrollbarMarks.SetStart(const Value: Integer);
begin
  FStart := Value;
end;

function TPasScrollbarMarks.GetColor: TColor;
begin
  Result := SeverityColor(1);   // each entry carries its own
end;

function TPasScrollbarMarks.GetCustomDraw: Boolean;
begin
  // The editor's own drawing, the same as its other marks: a custom-drawn
  // taller mark (2026-11-02) looked out of place beside them.
  Result := False;
end;

procedure TPasScrollbarMarks.DrawMark(const AEditor: TWinControl;
  LineNum: Integer; ACanvas: TCanvas; ARect: TRect);
begin
  // Not custom-drawn: the editor paints each entry in its colour.
end;

procedure TPasScrollbarMarks.GetScrollbarAnnotations(
  const AEditor: TWinControl);
var
  LServices: INTACodeEditorServices;
  LState: INTACodeEditorState;
  LPath: string;
  LDiags: TArray<TLspDiagnostic>;
  LWorst: TDictionary<Integer, Integer>;
  LPair: TPair<Integer, Integer>;
begin
  if (GScrollIndex < 0) or (AEditor = nil) or not ErrorMarksActive then
    Exit;
  try
    if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
      Exit;
    LState := LServices.EditorState[AEditor];
    if (LState = nil) or (LState.View = nil) or
       (LState.View.Buffer = nil) then
      Exit;
    LPath := LState.View.Buffer.FileName;
    if not GScrollAskNoted then
    begin
      GScrollAskNoted := True;
      LspLogDetail('error marks: the scroll bar asked for '
        + ExtractFileName(LPath));
    end;
    if not IsPascalSourceFile(LPath) or
       not LiveDiagnostics(LPath, LDiags) or (LDiags = nil) then
      Exit;
    LWorst := WorstByRow(LDiags);
    try
      for LPair in LWorst do
        LServices.AddScrollbarAnnotationEntry(AEditor, GScrollIndex,
          LPair.Key, SeverityColor(LPair.Value));
    finally
      LWorst.Free;
    end;
  except
    on E: Exception do
      LspLogDetail('error marks: scroll bar entries failed: ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

{ THE SCROLL BAR ASKS AGAIN ONLY WHEN THE IDE SAYS SO - a click in the
  editor, a save - and ToolsAPI has no call that says so: an answer that
  landed showed its underline at once and its scroll bar mark only after the
  next click (2026-11-02). coreide's own TEditorScrollbarMarksManager.
  UpdateMarksBuffer(Editor) is that call: it asks every enabled annotation
  again, compares the entries' hash with the old one and repaints the bar
  only when it changed (read off the 37.0 Win32 code). Both names are
  exported in 23.0 and 37.0; missing, the marks just wait for the IDE. }
type
  TUpdateMarksBuffer = procedure(ASelf: TObject; const AEditor: TWinControl);

const
{$IFDEF WIN64}
  cMarksManager = '_ZN14Scrollbarmarks27EditorScrollbarMarksManagerE';
  cUpdateMarksBuffer = '_ZN14Scrollbarmarks28TEditorScrollbarMarksManager'
    + '17UpdateMarksBufferEPN3Vcl8Controls11TWinControlE';
{$ELSE}
  cMarksManager = '@Scrollbarmarks@EditorScrollbarMarksManager';
  cUpdateMarksBuffer = '@Scrollbarmarks@TEditorScrollbarMarksManager@'
    + 'UpdateMarksBuffer$qqrxp24Vcl@Controls@TWinControl';
{$ENDIF}

var
  GMarksManager: PPointer;   // the unit variable holding the manager
  GUpdateMarksBuffer: TUpdateMarksBuffer;
  GMarksSeamResolved: Boolean = False;

procedure RefreshScrollMarks(AEditor: TWinControl);
begin
  if GScrollIndex < 0 then
    Exit;
  if not GMarksSeamResolved then
  begin
    GMarksSeamResolved := True;
    GMarksManager := CoreIdeExport(cMarksManager);
    @GUpdateMarksBuffer := CoreIdeExport(cUpdateMarksBuffer);
    if (GMarksManager = nil) or not Assigned(GUpdateMarksBuffer) then
      LspLogDetail('error marks: no UpdateMarksBuffer in this coreide - the'
        + ' scroll bar marks follow the IDE''s own refreshes');
  end;
  if (GMarksManager = nil) or not Assigned(GUpdateMarksBuffer) or
     (GMarksManager^ = nil) then
    Exit;
  GUpdateMarksBuffer(TObject(GMarksManager^), AEditor);
end;
{$ELSE}
procedure RefreshScrollMarks(AEditor: TWinControl);
begin
  // Delphi 11.3: no scroll bar annotations.
end;
{$IFEND}

{ Every editor showing APath repainted ('' = every editor), so the marks
  follow the analysis and the edits without any polling. }
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
         ((APath = '') or SameText(LViews[LIdx].Buffer.FileName, APath)) then
      begin
        LEditor := LServices.GetEditorForView(LViews[LIdx]);
        if LEditor <> nil then
        begin
          try
            RefreshScrollMarks(LEditor);
          except
            on E: Exception do
              LspLogDetail('error marks: scroll bar refresh failed: '
                + E.ClassName + ': ' + E.Message);
          end;
          LServices.InvalidateEditor(LEditor);
        end;
      end;
  finally
    LViews.Free;
  end;
end;

{ A publishDiagnostics landed: its rows go into the line tracker before the
  repaint asks for them. }
procedure DiagnosticsChanged(const APath: string);
begin
  TrackDiagnosticLines(APath);
  InvalidateViewsOf(APath);
end;

procedure ErrorPaintViewModified(const AView: IOTAEditView);
begin
  if DiagnosticLinesViewModified(AView) then
    InvalidateViewsOf(AView.Buffer.FileName);
end;

procedure ErrorMarksSettingChanged;
begin
  InvalidateViewsOf('');
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
  GListener := LspAddDiagnosticsChangedListener(DiagnosticsChanged);
  {$IF Declared(INTACodeEditorScrollbarAnnotation)}
  GScrollMarks := TPasScrollbarMarks.Create;
  GScrollIndex := LServices.RegisterScrollbarAnnotation(GScrollMarks);
  if GScrollIndex < 0 then
    GScrollMarks := nil;
  {$IFEND}
end;

procedure FinalizeErrorPaint;
var
  LServices: INTACodeEditorServices;
begin
  LspRemoveDiagnosticsChangedListener(GListener);
  GListener := 0;
  FinalizeDiagnosticLines;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices := nil;
  {$IF Declared(INTACodeEditorScrollbarAnnotation)}
  if (GScrollIndex >= 0) and (LServices <> nil) then
    LServices.RemoveScrollbarAnnotation(GScrollIndex);
  GScrollIndex := -1;
  GScrollMarks := nil;
  {$IFEND}
  if GNotifierIndex < 0 then
    Exit;
  if LServices <> nil then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

end.
