unit PasTreeIdePlugin.TooltipSymbolInsight;

{
  TOOLTIP SYMBOL INSIGHT, OURS - the editor's hover hint, named after the
  IDE option it replaces: rest the mouse on an identifier and a popup
  shows its declaration line in the editor's own syntax colours (type names in
  the Highlighting tab's colour), the declaration's documentation, and a link
  "Unit.pas (302)" that jumps there the way Ctrl+Click does. It works under
  every Insight Provider, DelphiLSP included.

  WHY A WINDOW OF OUR OWN. The Code Insight manager's hint path
  (AsyncGetHintText) takes a bare string into a plain window - measured
  2026-08-23, see clients/rad-studio/SPEC.md - and belongs to the CURRENT
  manager only, which is not ours under DelphiLSP. Nothing in the ToolsAPI
  draws into the editor's hint. So the hint is a popup we show and paint,
  triggered by the editor's mouse-move event.

  THE NATIVE HINT IS SWITCHED OFF WHILE OURS IS ON - otherwise two hints. The
  native one is the Tools > Options "Tooltip symbol insight" box, which the
  IDE holds in memory as the environment option `DeclarationInformation`
  (IOTAEnvironmentOptions.Values). Measured 2026-10-07 with a WinEvent probe:
  the native hover is a TIDEHintWindow "Calculating..." followed by a
  THelpInsightWindowImpl, and that one option set to False stops both at
  once, live, while toolbar hints (also TIDEHintWindow) keep working. Writing
  the same value into the registry does NOT reach a running IDE - only the
  environment option does. So: never a hook on the IDE's windows, one
  documented switch instead.

  The switch is restored exactly: it is turned off only if it was on, and a
  marker under our settings key (SavedDeclarationInformation) remembers that
  it was - written BEFORE the switch, kept across sessions, removed only when
  the setting is turned off and the IDE's value is put back. At unload the
  option is set back to True as well, so a session that ends without us
  leaves the IDE as it found it; the marker covers the case where the IDE
  persisted our False first. A user who ticks the box again in Tools >
  Options while ours is on is not fought: the switch acts on transitions of
  our setting only.

  PROBLEMS UNDER THE POINTER come first in the hint, one line each, drawn as
  the IDE's own error hint draws them (Alex, 2026-10-08): a disc with a `!`
  in the colour of the underline, the compiler's code (`E2003`) in that
  colour, then the message. Only while PasTree draws the underlines (the
  settings' Errors Insight) - with the IDE's Error Insight on, the IDE shows
  its own error hint, Tooltip symbol insight or not (ProblemsOnRow). A name
  with an ERROR shows the problems alone - no card, not even asked for (a
  redeclared name's card is the declaration it collides with); so does a
  name with no card (an undeclared identifier) and a problem that is not on
  a name at all (a missing `;`). A warning or hint keeps the card.

  WHILE THE ANALYSIS IS NOT READY the hover request waits in the server
  (WaitAnalyzed). Instead of the native "Calculating..." window, ours shows
  the status line ("PasTree: analyzing...") in the hint itself once the
  answer is later than cProgressAfterMs, and replaces it with the card when
  the answer arrives - or closes if there is nothing under the pointer.

  LIFETIME. Shown cHoverDelayMs after the mouse stops on an identifier;
  stays up while the pointer is on that identifier, on the hint, or between
  the two (so the link can be reached); closes on any key, wheel or click
  elsewhere, when the IDE loses activation, or when the pointer leaves. The
  window never takes focus (WS_EX_NOACTIVATE, MA_NOACTIVATE).

  NOT SHOWN while a debugged process is stopped - the IDE's evaluation
  tooltips (ToolTip Watches) own the hover then - nor with Ctrl held (the
  Ctrl+hover underline of navigation) or a mouse button down (a selection).
}

interface

procedure InitializeTooltipSymbolInsight;
procedure FinalizeTooltipSymbolInsight;

implementation

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Variants, System.Math, System.StrUtils, System.Win.Registry,
  Winapi.Windows, Winapi.Messages,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls, Vcl.AppEvnts,
  ToolsAPI, ToolsAPI.Editor, ToolsAPI.UI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.DirectiveText,
  PasTreeIdePlugin.GotoDeclaration, PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.ErrorPaint;

const
  // The native hint's measured timing (2026-10-07): its first window comes
  // 150-500 ms after the mouse stops. 450 felt slow; 300 since 0.63.8
  // (Alex, 2026-10-08).
  cHoverDelayMs = 300;
  // A hover answered within this is shown straight away; a later one gets the
  // progress line first.
  cProgressAfterMs = 300;
  cCheckMs = 100;
  // Unscaled layout, in 96-dpi pixels.
  cPad = 6;
  cDocGap = 6;
  cDocMinWidth = 360;
  cDocMaxWidth = 640;
  cEnvDeclInfo = 'DeclarationInformation';
  cValueSavedDeclInfo = 'SavedDeclarationInformation';

type
  TSymbolInsightWindow = class(TCustomControl)
  private
    FInfo: TLspHoverInfo;
    // The problems under the pointer, shown above the card, and where each
    // message goes (its prefix sits left of the rect).
    FErrors: TArray<TLspDiagnostic>;
    FErrorRects: TArray<TRect>;
    // Line one's top, -1 when there is no line one (problems only).
    FCodeTop: Integer;
    FProgress: string;
    FPpi: Integer;
    FBack, FText, FDim, FBorder, FLink, FTypeColor: TColor;
    FTypeStyle: TFontStyles;
    FCodeFontName: string;
    FCodeFontSize: Integer;
    FLinkText: string;
    FLinkRect: TRect;
    FDocRect: TRect;
    FNoteRect: TRect;
    // The grey lines under line one: a type's SizeOf, then the note.
    FNoteText: string;
    FLineHeight: Integer;
    FCodeWidth: Integer;
    function S(AValue: Integer): Integer;
    procedure UseCodeFont;
    procedure UseUiFont;
    procedure ReadColors;
    procedure PaintCode(var AX: Integer; AY: Integer; ADoDraw: Boolean);
    function Measure: TSize;
    procedure WMMouseActivate(var Message: TWMMouseActivate); message WM_MOUSEACTIVATE;
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    OnLinkClick: TNotifyEvent;
    constructor Create(AOwner: TComponent); override;
    procedure ShowAt(const AAnchor: TRect; const AInfo: TLspHoverInfo;
      const AErrors: TArray<TLspDiagnostic>; const AProgress: string);
    procedure HideHint;
    function IsShowing: Boolean;
    property Info: TLspHoverInfo read FInfo;
  end;

  TSymbolInsightNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

  TSymbolInsightController = class(TComponent)
  private
    FServices: INTACodeEditorServices;
    FNotifier: TSymbolInsightNotifier;
    FNotifierIndex: Integer;
    FWindow: TSymbolInsightWindow;
    FShowTimer: TTimer;
    FCheckTimer: TTimer;
    FAppEvents: TApplicationEvents;
    FEditor: TWinControl;
    FMouse: TPoint;
    // The identifier the hint is about: editor row (logical), its columns
    // [ColFrom, ColTo), the visible line it was found on, and its screen
    // rect at the time - the anchor the window is placed under.
    FRow, FColFrom, FColTo, FVisibleLine: Integer;
    FAnchor: TRect;
    FFileName: string;
    // The problems over [FColFrom, FColTo) on FRow, taken when the hover
    // starts - shown with the card, or alone when there is none.
    FErrors: TArray<TLspDiagnostic>;
    FGeneration: Integer;
    FPending: Boolean;
    FPendingSince: Cardinal;
    FDots: Integer;
    // Whether the IDE's hint is off on our account - put back at unload.
    FQuenched: Boolean;
    // Our setting as last acted on, and whether it has been at all.
    FApplied: Boolean;
    FSettingsRead: Boolean;
    procedure DoMouseMove(const Editor: TWinControl; Shift: TShiftState;
      X, Y: Integer);
    procedure OnShowTimer(Sender: TObject);
    procedure OnCheckTimer(Sender: TObject);
    procedure OnAppMessage(var Msg: TMsg; var Handled: Boolean);
    procedure OnAppDeactivate(Sender: TObject);
    procedure OnLinkClick(Sender: TObject);
    procedure StartHover;
    procedure CancelHover;
    function ProblemsOnRow(ARow: Integer): TArray<TLspDiagnostic>;
    function OverAnchor(const AScreen: TPoint): Boolean;
    function InKeepZone(const AScreen: TPoint): Boolean;
    function ProgressText: string;
    procedure SyncNativeHint;
    procedure SetNativeHint(AOn: Boolean);
    procedure SetEditor(AEditor: TWinControl);
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Shutdown;
  end;

var
  GController: TSymbolInsightController;
  // False from the moment the package starts unloading: an answer that comes
  // back after that must not touch a freed window (the LspSession callbacks
  // run on the main thread, but can still be queued behind the unload).
  GAlive: Boolean;

{ Helpers }

function SettingsKey: string;
var
  LServices: IOTAServices;
begin
  Result := '';
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    Result := IncludeTrailingPathDelimiter(LServices.GetBaseRegistryKey)
      + 'PasTree';
end;

function DebuggerStopped: Boolean;
var
  LDebugger: IOTADebuggerServices;
  LProcess: IOTAProcess;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTADebuggerServices, LDebugger) then
    Exit;
  LProcess := LDebugger.CurrentProcess;
  Result := Assigned(LProcess) and (LProcess.ProcessState = psStopped);
end;

{ What a problem line names its problem by, after the icon: the compiler's
  number, as the IDE's own error hint does (`E2003`) - or the severity's
  word when the server sent none. }
function ProblemLabel(const AProblem: TLspDiagnostic): string;
begin
  Result := AProblem.Code;
  if Result = '' then
    case AProblem.Severity of
      1: Result := 'Error';
      2: Result := 'Warning';
    else
      Result := 'Hint';
    end;
end;

{ The IDE error hint's icon: a disc in the severity's colour with a white
  `!` cut into it, ASize pixels square at (AX, AY). Anti-aliased the way
  ErrorPaint draws the underlines - coverage per pixel (here from 4x4
  samples) into a premultiplied DIB, AlphaBlend-ed onto the hint - since a
  GDI Ellipse at this size is a jagged blob. }
procedure DrawProblemIcon(ACanvas: TCanvas; AX, AY, ASize: Integer;
  AColor: TColor);
const
  cSub = 4;
var
  LInfo: TBitmapInfo;
  LBits: Pointer;
  LDib, LOld: HBITMAP;
  LMemDC: HDC;
  LPx: PCardinal;
  LRgb, LR, LG, LB, LA, LW: Cardinal;
  LX, LY, LSX, LSY, LDisc, LMark: Integer;
  LR0, LPx0, LPy0, LDx, LDy: Single;
  LBlend: TBlendFunction;
begin
  if ASize <= 2 then
    Exit;
  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.bmiHeader.biSize := SizeOf(LInfo.bmiHeader);
  LInfo.bmiHeader.biWidth := ASize;
  LInfo.bmiHeader.biHeight := -ASize;
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
      LR0 := ASize / 2;
      LPx := LBits;
      for LY := 0 to ASize - 1 do
        for LX := 0 to ASize - 1 do
        begin
          LDisc := 0;
          LMark := 0;
          for LSY := 0 to cSub - 1 do
            for LSX := 0 to cSub - 1 do
            begin
              // The sample, relative to the centre, in radii.
              LPx0 := (LX + (LSX + 0.5) / cSub - LR0) / LR0;
              LPy0 := (LY + (LSY + 0.5) / cSub - LR0) / LR0;
              if LPx0 * LPx0 + LPy0 * LPy0 > 0.92 * 0.92 then
                Continue;
              Inc(LDisc);
              // The `!`: a bar from -0.55 to 0.14 with round ends, and a dot.
              LDx := Abs(LPx0);
              LDy := 0;
              if LPy0 < -0.45 then
                LDy := LPy0 + 0.45
              else if LPy0 > 0.06 then
                LDy := LPy0 - 0.06;
              if (LDx * LDx + LDy * LDy <= 0.12 * 0.12) or
                 (Sqr(LPx0) + Sqr(LPy0 - 0.42) <= 0.13 * 0.13) then
                Inc(LMark);
            end;
          // Premultiplied BGRA: the white of the mark over the disc's colour.
          LA := LDisc * 255 div (cSub * cSub);
          LW := LMark * 255 div (cSub * cSub);
          LPx^ := (LA shl 24)
            or (((LR * (LA - LW) + 255 * LW) div 255) shl 16)
            or (((LG * (LA - LW) + 255 * LW) div 255) shl 8)
            or ((LB * (LA - LW) + 255 * LW) div 255);
          Inc(LPx);
        end;
      LOld := SelectObject(LMemDC, LDib);
      try
        LBlend.BlendOp := AC_SRC_OVER;
        LBlend.BlendFlags := 0;
        LBlend.SourceConstantAlpha := 255;
        LBlend.AlphaFormat := AC_SRC_ALPHA;
        Winapi.Windows.AlphaBlend(ACanvas.Handle, AX, AY, ASize, ASize,
          LMemDC, 0, 0, ASize, ASize, LBlend);
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

{ The problems of one row's list that touch columns [AFrom, ATo) - a
  zero-width one counts as its one character. }
function ProblemsOver(const AProblems: TArray<TLspDiagnostic>;
  AFrom, ATo: Integer): TArray<TLspDiagnostic>;
var
  LDiag: TLspDiagnostic;
begin
  Result := nil;
  for LDiag in AProblems do
    if (LDiag.ColFrom < ATo) and
       (Max(LDiag.ColTo, LDiag.ColFrom + 1) > AFrom) then
      Result := Result + [LDiag];
end;

function ThemedColor(AColor: TColor): TColor;
var
  LTheming: IOTAIDEThemingServices;
begin
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled and Assigned(LTheming.StyleServices) then
    Result := LTheming.StyleServices.GetSystemColor(AColor)
  else
    Result := ColorToRGB(AColor);
end;

{ TSymbolInsightWindow }

constructor TSymbolInsightWindow.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
  FPpi := 96;
  FCodeFontName := 'Consolas';
  FCodeFontSize := 10;
end;

procedure TSymbolInsightWindow.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := WS_POPUP;
  Params.ExStyle := WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE;
  Params.WindowClass.style := Params.WindowClass.style or CS_DROPSHADOW;
  Params.WndParent := Application.Handle;
end;

procedure TSymbolInsightWindow.WMMouseActivate(var Message: TWMMouseActivate);
begin
  Message.Result := MA_NOACTIVATE;
end;

procedure TSymbolInsightWindow.WMNCHitTest(var Message: TWMNCHitTest);
begin
  Message.Result := HTCLIENT;
end;

function TSymbolInsightWindow.S(AValue: Integer): Integer;
begin
  Result := MulDiv(AValue, FPpi, 96);
end;

procedure TSymbolInsightWindow.UseCodeFont;
begin
  Canvas.Font.Name := FCodeFontName;
  Canvas.Font.Height := -MulDiv(FCodeFontSize, FPpi, 72);
  Canvas.Font.Style := [];
end;

procedure TSymbolInsightWindow.UseUiFont;
begin
  Canvas.Font.Name := Screen.MessageFont.Name;
  // The editor's size, not a fixed 9 pt: the hint sits over the code and
  // read small beside it (Alex, 2026-10-08), and follows the editor's zoom
  // setting the way the declaration line already does.
  Canvas.Font.Height := -MulDiv(FCodeFontSize, FPpi, 72);
  Canvas.Font.Style := [];
  Canvas.Font.Color := FText;
end;

procedure TSymbolInsightWindow.ReadColors;
var
  LUI: INTAIDEUIServices;
  LEditor: IOTAEditorServices;
begin
  FBack := ThemedColor(clInfoBk);
  FText := ThemedColor(clInfoText);
  FDim := ThemedColor(clGrayText);
  FBorder := ThemedColor(clBtnShadow);
  if Supports(BorlandIDEServices, INTAIDEUIServices, LUI) then
    FLink := LUI.ThemeAwareColors[itcBlue]
  else
    FLink := clHotLight;
  if TypeHighlightEnabled then
    FTypeColor := TypeHighlightColor
  else
    FTypeColor := clNone;
  FTypeStyle := TypeHighlightStyle;
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditor) and
     Assigned(LEditor.EditOptions) then
  begin
    FCodeFontName := LEditor.EditOptions.FontName;
    FCodeFontSize := LEditor.EditOptions.FontSize;
  end;
end;

{ The declaration line: its lead (`var`, `param [in/out]` - HeadLen chars) in
  the editor's reserved-word colour and style, whatever the tokenizer would
  make of `param`; the rest through the display tokenizer with the type
  spans re-based onto it. ADoDraw=False measures only. }
procedure TSymbolInsightWindow.PaintCode(var AX: Integer; AY: Integer;
  ADoDraw: Boolean);
var
  LHead, LRest: string;
  LSpans: TArray<Integer>;
  LIdx: Integer;
begin
  LHead := Copy(FInfo.Code, 1, FInfo.HeadLen);
  LRest := Copy(FInfo.Code, FInfo.HeadLen + 1, MaxInt);
  if LHead <> '' then
  begin
    Canvas.Font.Color := EditorSyntaxColor(atReservedWord, FText);
    Canvas.Font.Style := EditorSyntaxStyle(atReservedWord);
    if ADoDraw then
      Canvas.TextOut(AX, AY, LHead);
    Inc(AX, Canvas.TextWidth(LHead));
  end;
  LSpans := Copy(FInfo.TypeSpans);
  LIdx := 0;
  while LIdx + 1 < Length(LSpans) do
  begin
    Dec(LSpans[LIdx], FInfo.HeadLen);
    Inc(LIdx, 2);
  end;
  PaintSyntaxTextTyped(Canvas, AX, AY, LRest, FText, LSpans, FTypeColor,
    FTypeStyle, ADoDraw);
end;

{ The card's size, and the rects the paint and the mouse use. First the
  problems under the pointer, one per line: "Error: " in the severity's
  colour, the message wrapped beside it. Then line one - the declaration in
  the editor font, " - " and the link in the UI font, or the progress line
  while the answer waits; then the note (only where it says more than the
  link would) and the documentation, wrapped to a width between
  cDocMinWidth and cDocMaxWidth - or to the declaration line, when that is
  wider. Any part may be absent: an undeclared name has problems and no
  card. }
function TSymbolInsightWindow.Measure: TSize;
var
  LX, LY, LCodeH, LUiH, LWidth, LTextW, LIdx, LPrefixW: Integer;
  LRect: TRect;
  LNote: string;
begin
  if Canvas.Handle = 0 then   // a DC to measure with
    Exit(TSize.Create(0, 0));
  UseCodeFont;
  LCodeH := Canvas.TextHeight('Wg');
  UseUiFont;
  LUiH := Canvas.TextHeight('Wg');
  FLineHeight := Max(LCodeH, LUiH);

  // Line one's width: the progress line, or the declaration and its link.
  FCodeWidth := 0;
  FLinkText := '';
  FLinkRect := TRect.Empty;
  LWidth := 0;
  if FProgress <> '' then
  begin
    Canvas.Font.Style := [fsItalic];
    FCodeWidth := Canvas.TextWidth(FProgress);
    Canvas.Font.Style := [];
    LWidth := FCodeWidth;
  end
  else if FInfo.Code <> '' then
  begin
    UseCodeFont;
    LX := 0;
    PaintCode(LX, 0, False);
    FCodeWidth := LX;
    LWidth := FCodeWidth;
    UseUiFont;
    if FInfo.FilePath <> '' then
    begin
      FLinkText := ExtractFileName(FInfo.FilePath);
      if FInfo.Line > 0 then
        FLinkText := Format('%s (%d)', [FLinkText, FInfo.Line]);
      Canvas.Font.Style := [fsUnderline];
      LWidth := FCodeWidth + Canvas.TextWidth(' - ')
        + Canvas.TextWidth(FLinkText);
      Canvas.Font.Style := [];
    end;
  end;

  LTextW := Max(S(cDocMinWidth), LWidth);
  LTextW := Min(LTextW, Max(S(cDocMaxWidth), FCodeWidth));
  LY := S(cPad);

  // The problems, on top: what is wrong here is what the pointer is most
  // likely asking about.
  UseUiFont;
  SetLength(FErrorRects, Length(FErrors));
  for LIdx := 0 to High(FErrors) do
  begin
    if LIdx > 0 then
      Inc(LY, S(2));
    // Icon, gap, the code, a blank: the message wraps beside them.
    LPrefixW := LUiH + S(4)
      + Canvas.TextWidth(ProblemLabel(FErrors[LIdx]) + ' ');
    LRect := Rect(0, 0, Max(LTextW - LPrefixW, S(120)), 0);
    DrawText(Canvas.Handle, PChar(FErrors[LIdx].Text), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FErrorRects[LIdx] := Rect(S(cPad) + LPrefixW, LY,
      S(cPad) + LPrefixW + LRect.Width, LY + Max(LRect.Height, LUiH));
    LWidth := Max(LWidth, LPrefixW + LRect.Width);
    LY := FErrorRects[LIdx].Bottom;
  end;

  FCodeTop := -1;
  if (FProgress <> '') or (FInfo.Code <> '') then
  begin
    if Length(FErrors) > 0 then
      Inc(LY, S(cDocGap));
    FCodeTop := LY;
    if FLinkText <> '' then
    begin
      LX := S(cPad) + FCodeWidth + Canvas.TextWidth(' - ');
      Canvas.Font.Style := [fsUnderline];
      FLinkRect := Rect(LX, LY, LX + Canvas.TextWidth(FLinkText),
        LY + FLineHeight);
      Canvas.Font.Style := [];
    end;
    Inc(LY, FLineHeight);
  end;

  // A type's size first, on the line under the declaration (Alex,
  // 2026-10-09). Then the note, which says what the link cannot: where a
  // define comes from, that a name is the function's result or a System
  // built-in - whose card otherwise reads like any declaration with a link.
  FNoteRect := TRect.Empty;
  LNote := '';
  if (FProgress = '') and (FInfo.Code <> '') then
  begin
    // `+`: a generic declaration's minimum, its parameters' share unknown.
    if FInfo.TypeSize >= 0 then
      LNote := Format('SizeOf: %d%s', [FInfo.TypeSize,
        IfThen(FInfo.TypeSizeMin, '+', '')]);
    // A class: its SizeOf is the reference, so the instance's size beside it.
    if (FInfo.TypeSize >= 0) and (FInfo.InstanceSize >= 0) then
      LNote := LNote + Format(', InstanceSize: %d%s', [FInfo.InstanceSize,
        IfThen(FInfo.InstanceSizeMin, '+', '')]);
    if (FInfo.Note <> '') and ((FInfo.FilePath = '') or FInfo.Builtin
      or SameText(FInfo.Kind, 'conditional symbol')) then
    begin
      if LNote <> '' then
        LNote := LNote + sLineBreak;
      LNote := LNote + FInfo.Note;
    end;
  end;
  FNoteText := LNote;
  if LNote <> '' then
  begin
    Canvas.Font.Style := [fsItalic];
    LRect := Rect(0, 0, LTextW, 0);
    DrawText(Canvas.Handle, PChar(LNote), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FNoteRect := Rect(S(cPad), LY + S(cDocGap),
      S(cPad) + LRect.Width, LY + S(cDocGap) + LRect.Height);
    LWidth := Max(LWidth, LRect.Width);
    LY := FNoteRect.Bottom;
    Canvas.Font.Style := [];
  end;

  FDocRect := TRect.Empty;
  if (FProgress = '') and (FInfo.Doc <> '') then
  begin
    LRect := Rect(0, 0, LTextW, 0);
    DrawText(Canvas.Handle, PChar(FInfo.Doc), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FDocRect := Rect(S(cPad), LY + S(cDocGap),
      S(cPad) + LRect.Width, LY + S(cDocGap) + LRect.Height);
    LWidth := Max(LWidth, LRect.Width);
    LY := FDocRect.Bottom;
  end;

  Result.cx := LWidth + 2 * S(cPad);
  Result.cy := LY + S(cPad);
end;

procedure TSymbolInsightWindow.ShowAt(const AAnchor: TRect;
  const AInfo: TLspHoverInfo; const AErrors: TArray<TLspDiagnostic>;
  const AProgress: string);
var
  LSize: TSize;
  LMonitor: TMonitor;
  LWork: TRect;
  LLeft, LTop: Integer;
begin
  FInfo := AInfo;
  FErrors := AErrors;
  FProgress := AProgress;
  LMonitor := Screen.MonitorFromPoint(AAnchor.TopLeft);
  if Assigned(LMonitor) then
  begin
    FPpi := LMonitor.PixelsPerInch;
    LWork := LMonitor.WorkareaRect;
  end
  else
  begin
    FPpi := Screen.PixelsPerInch;
    LWork := Screen.WorkAreaRect;
  end;
  HandleNeeded;
  ReadColors;
  LSize := Measure;
  // Under the identifier, its left edge on the identifier's; above it when
  // there is no room below, and pulled inside the monitor sideways.
  LLeft := AAnchor.Left;
  LTop := AAnchor.Bottom + S(2);
  if LTop + LSize.cy > LWork.Bottom then
    LTop := AAnchor.Top - S(2) - LSize.cy;
  if LLeft + LSize.cx > LWork.Right then
    LLeft := LWork.Right - LSize.cx;
  if LLeft < LWork.Left then
    LLeft := LWork.Left;
  SetWindowPos(Handle, HWND_TOPMOST, LLeft, LTop, LSize.cx, LSize.cy,
    SWP_NOACTIVATE or SWP_SHOWWINDOW);
  Invalidate;
end;

procedure TSymbolInsightWindow.HideHint;
begin
  if HandleAllocated and IsWindowVisible(Handle) then
    ShowWindow(Handle, SW_HIDE);
end;

function TSymbolInsightWindow.IsShowing: Boolean;
begin
  Result := HandleAllocated and IsWindowVisible(Handle);
end;

procedure TSymbolInsightWindow.Paint;
var
  LR: TRect;
  LX, LY, LCodeH, LIdx: Integer;
  LPrefix: string;
begin
  LR := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FBack;
  Canvas.FillRect(LR);
  Canvas.Pen.Color := FBorder;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(LR);

  // The problems as the IDE's own error hint draws them: the icon, the code
  // in the severity's colour, the message in the hint's text colour.
  UseUiFont;
  LCodeH := Canvas.TextHeight('Wg');
  for LIdx := 0 to Min(High(FErrors), High(FErrorRects)) do
  begin
    LY := FErrorRects[LIdx].Top;
    DrawProblemIcon(Canvas, S(cPad) + S(1), LY + S(1), LCodeH - S(2),
      SeverityColor(FErrors[LIdx].Severity));
    Canvas.Brush.Style := bsClear;
    LPrefix := ProblemLabel(FErrors[LIdx]);
    Canvas.Font.Color := SeverityColor(FErrors[LIdx].Severity);
    Canvas.TextOut(S(cPad) + LCodeH + S(4), LY, LPrefix);
    Canvas.Font.Color := FText;
    LR := FErrorRects[LIdx];
    DrawText(Canvas.Handle, PChar(FErrors[LIdx].Text), -1, LR,
      DT_WORDBREAK or DT_NOPREFIX);
  end;

  if FCodeTop >= 0 then
    if FProgress <> '' then
    begin
      UseUiFont;
      Canvas.Font.Style := [fsItalic];
      Canvas.Font.Color := FDim;
      Canvas.TextOut(S(cPad), FCodeTop, FProgress);
      Canvas.Font.Style := [];
    end
    else
    begin
      // Line one: the declaration, then the link - each font centred on the
      // shared line height, so the two read as one line.
      UseCodeFont;
      LCodeH := Canvas.TextHeight('Wg');
      LX := S(cPad);
      LY := FCodeTop + (FLineHeight - LCodeH) div 2;
      PaintCode(LX, LY, True);
      UseUiFont;
      if FLinkText <> '' then
      begin
        LY := FCodeTop + (FLineHeight - Canvas.TextHeight('Wg')) div 2;
        Canvas.Font.Color := FDim;
        Canvas.TextOut(LX, LY, ' - ');
        Canvas.Font.Color := FLink;
        Canvas.Font.Style := [fsUnderline];
        Canvas.TextOut(FLinkRect.Left, LY, FLinkText);
        Canvas.Font.Style := [];
      end;
    end;

  if not FNoteRect.IsEmpty then
  begin
    Canvas.Font.Color := FDim;
    Canvas.Font.Style := [fsItalic];
    LR := FNoteRect;
    DrawText(Canvas.Handle, PChar(FNoteText), -1, LR,
      DT_WORDBREAK or DT_NOPREFIX);
    Canvas.Font.Style := [];
  end;

  if not FDocRect.IsEmpty then
  begin
    Canvas.Font.Color := FText;
    LR := FDocRect;
    DrawText(Canvas.Handle, PChar(FInfo.Doc), -1, LR,
      DT_WORDBREAK or DT_NOPREFIX);
  end;
end;

procedure TSymbolInsightWindow.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FLinkRect.Contains(Point(X, Y)) then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
end;

procedure TSymbolInsightWindow.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if (Button = mbLeft) and FLinkRect.Contains(Point(X, Y)) and
     Assigned(OnLinkClick) then
    OnLinkClick(Self);
end;

{ TSymbolInsightNotifier }

function TSymbolInsightNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents];
end;

{ TSymbolInsightController }

constructor TSymbolInsightController.Create(AOwner: TComponent);
begin
  inherited;
  FNotifierIndex := -1;
  FWindow := TSymbolInsightWindow.Create(Self);
  FWindow.OnLinkClick := OnLinkClick;
  FShowTimer := TTimer.Create(Self);
  FShowTimer.Enabled := False;
  FShowTimer.Interval := cHoverDelayMs;
  FShowTimer.OnTimer := OnShowTimer;
  FCheckTimer := TTimer.Create(Self);
  FCheckTimer.Enabled := False;
  FCheckTimer.Interval := cCheckMs;
  FCheckTimer.OnTimer := OnCheckTimer;
  FAppEvents := TApplicationEvents.Create(Self);
  FAppEvents.OnMessage := OnAppMessage;
  FAppEvents.OnDeactivate := OnAppDeactivate;
  if Supports(BorlandIDEServices, INTACodeEditorServices, FServices) then
  begin
    FNotifier := TSymbolInsightNotifier.Create;
    FNotifier.OnEditorMouseMove := DoMouseMove;
    FNotifierIndex := FServices.AddEditorEventsNotifier(FNotifier);
  end;
end;

destructor TSymbolInsightController.Destroy;
begin
  Shutdown;
  inherited;
end;

{ Everything the IDE could call into, released; and the native hint put back
  on - see the header for why at unload too. Safe twice. }
procedure TSymbolInsightController.Shutdown;
begin
  FShowTimer.Enabled := False;
  FCheckTimer.Enabled := False;
  FAppEvents.OnMessage := nil;
  FAppEvents.OnDeactivate := nil;
  if Assigned(FServices) and (FNotifierIndex >= 0) then
    FServices.RemoveEditorEventsNotifier(FNotifierIndex);
  FNotifierIndex := -1;
  FServices := nil;
  SetEditor(nil);
  FWindow.HideHint;
  if FQuenched then
  try
    // The option only - the marker stays, see the header.
    (BorlandIDEServices as IOTAServices).GetEnvironmentOptions
      .Values[cEnvDeclInfo] := True;
    FQuenched := False;
  except
  end;
end;

procedure TSymbolInsightController.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FEditor) then
  begin
    FEditor := nil;
    CancelHover;
  end;
end;

procedure TSymbolInsightController.SetEditor(AEditor: TWinControl);
begin
  if FEditor = AEditor then
    Exit;
  if Assigned(FEditor) then
    FEditor.RemoveFreeNotification(Self);
  FEditor := AEditor;
  if Assigned(FEditor) then
    FEditor.FreeNotification(Self);
end;

{ The IDE's own hint on or off, through the environment option the Options
  dialog itself writes. The marker under our key is written before the switch
  goes off and read back when it goes on: it alone says the IDE's value was
  True before we touched it. }
procedure TSymbolInsightController.SetNativeHint(AOn: Boolean);
var
  LServices: IOTAServices;
  LOptions: IOTAEnvironmentOptions;
  LReg: TRegistry;
  LKey: string;
  LWasOn, LMarked: Boolean;
begin
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  LKey := SettingsKey;
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LOptions := LServices.GetEnvironmentOptions;
      LReg.RootKey := HKEY_CURRENT_USER;
      if not LReg.OpenKey(LKey, True) then
        Exit;
      LMarked := LReg.ValueExists(cValueSavedDeclInfo);
      if not AOn then
      begin
        LWasOn := VarToStrDef(LOptions.Values[cEnvDeclInfo], '') = 'True';
        if LWasOn then
        begin
          if not LMarked then
            LReg.WriteString(cValueSavedDeclInfo, 'True');
          LOptions.Values[cEnvDeclInfo] := False;
        end;
        FQuenched := LWasOn or LMarked;
      end
      else
      begin
        if LMarked then
        begin
          LOptions.Values[cEnvDeclInfo] := True;
          LReg.DeleteValue(cValueSavedDeclInfo);
        end;
        FQuenched := False;
      end;
    except
      // An IDE without the option (an older version) keeps its own hint; the
      // two then show together, which is visible and harmless.
      on E: Exception do
        LspLogToServer('tooltip symbol insight: could not switch the IDE''s tooltip: '
          + E.ClassName + ': ' + E.Message);
    end;
  finally
    LReg.Free;
  end;
end;

{ Called on every mouse move: cheap (the setting is cached), and acts only on
  a change of our setting - see the header. }
procedure TSymbolInsightController.SyncNativeHint;
var
  LWant: Boolean;
begin
  LWant := TooltipSymbolInsightEnabled;
  if FSettingsRead and (LWant = FApplied) then
    Exit;
  // Recorded before the switch, so a failed one is not retried on every
  // move; the next change of the setting tries again.
  FSettingsRead := True;
  FApplied := LWant;
  SetNativeHint(not LWant);
end;

procedure TSymbolInsightController.DoMouseMove(const Editor: TWinControl;
  Shift: TShiftState; X, Y: Integer);
var
  LScreen: TPoint;
begin
  if not GAlive then
    Exit;
  SyncNativeHint;
  if not TooltipSymbolInsightEnabled then
  begin
    CancelHover;
    Exit;
  end;
  LScreen := Editor.ClientToScreen(Point(X, Y));
  if (FWindow.IsShowing or FPending) and (Editor = FEditor) and
     InKeepZone(LScreen) then
    Exit;
  CancelHover;
  if Shift * [ssLeft, ssRight, ssMiddle] <> [] then
    Exit;
  SetEditor(Editor);
  FMouse := Point(X, Y);
  FShowTimer.Enabled := False;
  FShowTimer.Enabled := True;
end;

procedure TSymbolInsightController.OnShowTimer(Sender: TObject);
begin
  FShowTimer.Enabled := False;
  if GAlive then
    StartHover;
end;

{ The mouse has rested: find the identifier under it, and ask. }
procedure TSymbolInsightController.StartHover;
var
  LState: INTACodeEditorState;
  LLineState: INTACodeEditorLineState;
  LView: IOTAEditView;
  LColumn, LVisibleLine, LFrom, LTo, LGen: Integer;
  LText: string;
  LCellFrom, LCellTo: TRect;
  LProblems: TArray<TLspDiagnostic>;
  LAsk: Boolean;
begin
  if not Assigned(FEditor) or not Assigned(FServices) then
    Exit;
  if not Application.Active or not FEditor.Showing then
    Exit;
  // Still over the editor, nothing pressed, no Ctrl (navigation's hover).
  if WindowFromPoint(Mouse.CursorPos) <> FEditor.Handle then
    Exit;
  if (GetKeyState(VK_CONTROL) < 0) or (GetKeyState(VK_LBUTTON) < 0) or
     (GetKeyState(VK_RBUTTON) < 0) then
    Exit;
  if DebuggerStopped then
    Exit;

  LView := FServices.GetViewForEditor(FEditor);
  if not Assigned(LView) or not Assigned(LView.Buffer) then
    Exit;
  FFileName := LView.Buffer.FileName;
  if not IsPascalSourceFile(FFileName) then
    Exit;
  LState := FServices.EditorState[FEditor];
  if not Assigned(LState) then
    Exit;
  if not LState.PointToCharacterPos(FMouse, LColumn, LVisibleLine) then
    Exit;
  LLineState := LState.LineState[LVisibleLine];
  if not Assigned(LLineState) then
    Exit;
  // A word of the line, or a name inside a directive - the only places an
  // answer can come from. Asking about blank space or punctuation would show
  // "analyzing..." over nothing while the server is busy.
  LText := LLineState.Text;
  LProblems := ProblemsOnRow(LLineState.LogicalLineNum);
  LAsk := IdentRunAt(LText, LColumn, LFrom, LTo) or
    DirectiveNameAt(LText, LColumn, LFrom, LTo);
  if LAsk then
  begin
    FErrors := ProblemsOver(LProblems, LFrom, LTo);
    // An ERROR here makes the card beside the point - a redeclared `X`
    // would show the declaration it collides with (Alex, 2026-10-08): the
    // error alone, and no request. A warning or hint keeps the card.
    if (Length(FErrors) > 0) and (FErrors[0].Severity = 1) then
      LAsk := False;
  end
  else
  begin
    // Not on a name, but on a problem - a missing `;`, a stray `end`: the
    // hint explains it all the same, anchored on the problem's own span.
    FErrors := ProblemsOver(LProblems, LColumn, LColumn + 1);
    if Length(FErrors) = 0 then
      Exit;
    LFrom := Max(FErrors[0].ColFrom, 1);
    LTo := Min(Max(FErrors[0].ColTo, LFrom + 1), Length(LText) + 1);
    if LTo <= LFrom then
      LTo := LFrom + 1;
  end;

  FRow := LLineState.LogicalLineNum;
  FColFrom := LFrom;
  FColTo := LTo;
  FVisibleLine := LVisibleLine;
  LCellFrom := LState.GetCharacterPosPx(LFrom, LVisibleLine);
  LCellTo := LState.GetCharacterPosPx(LTo - 1, LVisibleLine);
  FAnchor := TRect.Create(FEditor.ClientToScreen(LCellFrom.TopLeft),
    FEditor.ClientToScreen(LCellTo.BottomRight));

  Inc(FGeneration);
  if not LAsk then
  begin
    // Nothing to ask the server: the problems are the whole hint.
    FPending := False;
    FCheckTimer.Enabled := True;
    FWindow.ShowAt(FAnchor, Default(TLspHoverInfo), FErrors, '');
    Exit;
  end;
  LGen := FGeneration;
  FPending := True;
  FPendingSince := GetTickCount;
  FCheckTimer.Enabled := True;
  LspHoverInfo(FFileName, FRow, LColumn,
    procedure(ASuccess, AFound: Boolean; const AInfo: TLspHoverInfo;
      const AError: string)
    begin
      if not GAlive or not Assigned(GController) then
        Exit;
      if LGen <> FGeneration then
        Exit;   // superseded, or the pointer moved away meanwhile
      FPending := False;
      if ASuccess and AFound then
        FWindow.ShowAt(FAnchor, AInfo, FErrors, '')
      // No card - an undeclared name has none - but a problem to explain.
      else if Length(FErrors) > 0 then
        FWindow.ShowAt(FAnchor, Default(TLspHoverInfo), FErrors, '')
      else
        CancelHover;
    end);
end;

{ The problems on ARow - ours (publishDiagnostics), and only while the
  settings' Errors Insight has PasTree draw the underlines. With the IDE's
  Error Insight on, the IDE shows its own error hint over an underline even
  with Tooltip symbol insight switched off, so ours would be a second copy
  of it (Alex, 2026-10-08; 0.63.6 read them through IOTAModuleErrors, which
  does answer DelphiLSP's errors). Errors first, then warnings, then hints;
  a message twice over the same span once. }
function TSymbolInsightController.ProblemsOnRow(
  ARow: Integer): TArray<TLspDiagnostic>;
var
  LAll: TArray<TLspDiagnostic>;
  LDiag: TLspDiagnostic;
  LIdx, LSev, LKept: Integer;
  LDup: Boolean;
begin
  Result := nil;
  if not PasTreeErrorSquigglesEnabled or
     not LspTryGetDiagnostics(FFileName, LAll) then
    Exit;

  for LSev := 1 to 3 do
    for LIdx := 0 to High(LAll) do
    begin
      if LAll[LIdx].Row <> ARow then
        Continue;
      if (LSev < 3) and (LAll[LIdx].Severity <> LSev) then
        Continue;
      if (LSev = 3) and (LAll[LIdx].Severity < 3) then
        Continue;
      LDiag := LAll[LIdx];
      // PasTree's messages start with their code (`E2003 Undeclared
      // identifier: 'Y'`), which the line shows on its own before them.
      if (LDiag.Code <> '') and StartsText(LDiag.Code + ' ', LDiag.Text) then
        LDiag.Text := Trim(Copy(LDiag.Text, Length(LDiag.Code) + 2, MaxInt));
      if Trim(LDiag.Text) = '' then
        Continue;
      LDup := False;
      for LKept := 0 to High(Result) do
        if (Result[LKept].ColFrom = LDiag.ColFrom) and
           (Result[LKept].Text = LDiag.Text) then
          LDup := True;
      if not LDup then
        Result := Result + [LDiag];
    end;
end;

procedure TSymbolInsightController.CancelHover;
begin
  FShowTimer.Enabled := False;
  FCheckTimer.Enabled := False;
  // A late answer for this hover is dropped by the generation.
  Inc(FGeneration);
  FPending := False;
  FWindow.HideHint;
end;

{ On the identifier the hint is about - judged again from the editor, so a
  scroll that moved another word under the pointer counts as leaving. }
function TSymbolInsightController.OverAnchor(const AScreen: TPoint): Boolean;
var
  LState: INTACodeEditorState;
  LLineState: INTACodeEditorLineState;
  LColumn, LVisibleLine: Integer;
begin
  Result := False;
  if not Assigned(FEditor) or not Assigned(FServices) then
    Exit;
  LState := FServices.EditorState[FEditor];
  if not Assigned(LState) or
     not LState.PointToCharacterPos(FEditor.ScreenToClient(AScreen),
       LColumn, LVisibleLine) then
    Exit;
  LLineState := LState.LineState[LVisibleLine];
  Result := Assigned(LLineState) and (LLineState.LogicalLineNum = FRow) and
    (LColumn >= FColFrom) and (LColumn < FColTo);
end;

{ Where the pointer may be without closing the hint: the identifier, the
  hint, and the band between them over the hint's width - the way to the
  link. }
function TSymbolInsightController.InKeepZone(const AScreen: TPoint): Boolean;
var
  LHint, LBand: TRect;
begin
  if OverAnchor(AScreen) then
    Exit(True);
  if not FWindow.IsShowing then
    Exit(False);
  GetWindowRect(FWindow.Handle, LHint);
  if LHint.Contains(AScreen) then
    Exit(True);
  if LHint.Top >= FAnchor.Bottom then
    LBand := Rect(LHint.Left, FAnchor.Top, LHint.Right, LHint.Top)
  else
    LBand := Rect(LHint.Left, LHint.Bottom, LHint.Right, FAnchor.Bottom);
  Result := LBand.Contains(AScreen);
end;

function TSymbolInsightController.ProgressText: string;
var
  LRunningMs: UInt64;
  LDots: string;
begin
  LDots := StringOfChar('.', FDots + 1);
  case LspServerStatusFor(FFileName, LRunningMs) of
    lssStarting:
      Result := 'PasTree: starting' + LDots;
    lssIncremental:
      Result := 'PasTree: analyzing (inc)' + LDots;
    lssFull:
      Result := 'PasTree: analyzing' + LDots;
  else
    Result := 'PasTree: waiting for the answer' + LDots;
  end;
end;

procedure TSymbolInsightController.OnCheckTimer(Sender: TObject);
begin
  if not GAlive then
    Exit;
  if not FWindow.IsShowing and not FPending then
  begin
    FCheckTimer.Enabled := False;
    Exit;
  end;
  if not Application.Active or not Assigned(FEditor) or
     not InKeepZone(Mouse.CursorPos) then
  begin
    CancelHover;
    Exit;
  end;
  // The answer is late: the analysis is running or the server starting. Say
  // so in the hint, where the native IDE shows its "Calculating...".
  if FPending and (GetTickCount - FPendingSince >= cProgressAfterMs) then
  begin
    FDots := (FDots + 1) mod 3;
    FWindow.ShowAt(FAnchor, Default(TLspHoverInfo), FErrors, ProgressText);
  end;
end;

procedure TSymbolInsightController.OnAppMessage(var Msg: TMsg;
  var Handled: Boolean);
begin
  if not GAlive or not (FWindow.IsShowing or FPending or FShowTimer.Enabled) then
    Exit;
  case Msg.message of
    WM_KEYDOWN, WM_SYSKEYDOWN, WM_MOUSEWHEEL, WM_MOUSEHWHEEL:
      CancelHover;
    WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN,
    WM_NCLBUTTONDOWN, WM_NCRBUTTONDOWN:
      if not FWindow.HandleAllocated or (Msg.hwnd <> FWindow.Handle) then
        CancelHover;
  end;
end;

procedure TSymbolInsightController.OnAppDeactivate(Sender: TObject);
begin
  if GAlive then
    CancelHover;
end;

procedure TSymbolInsightController.OnLinkClick(Sender: TObject);
var
  LInfo: TLspHoverInfo;
begin
  LInfo := FWindow.Info;
  CancelHover;
  if LInfo.FilePath <> '' then
    NavigateHistoryAware(LInfo.FilePath, Max(LInfo.Line, 1), Max(LInfo.Col, 1));
end;

procedure InitializeTooltipSymbolInsight;
begin
  GAlive := True;
  if not Assigned(GController) then
    GController := TSymbolInsightController.Create(nil);
end;

procedure FinalizeTooltipSymbolInsight;
begin
  GAlive := False;
  if Assigned(GController) then
  begin
    GController.Shutdown;
    FreeAndNil(GController);
  end;
end;

initialization

finalization
  FinalizeTooltipSymbolInsight;

end.
