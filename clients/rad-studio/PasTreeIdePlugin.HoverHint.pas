unit PasTreeIdePlugin.HoverHint;

{
  THE EDITOR'S HOVER HINT, OURS: rest the mouse on an identifier and a popup
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

procedure InitializeHoverHint;
procedure FinalizeHoverHint;

implementation

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Variants, System.Math, System.Win.Registry,
  Winapi.Windows, Winapi.Messages,
  Vcl.Controls, Vcl.Graphics, Vcl.Forms, Vcl.ExtCtrls, Vcl.AppEvnts,
  ToolsAPI, ToolsAPI.Editor, ToolsAPI.UI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.ResultRows, PasTreeIdePlugin.DirectiveText,
  PasTreeIdePlugin.GotoDeclaration, PasTreeIdePlugin.Settings;

const
  // The native hint's measured timing (2026-10-07): its first window comes
  // 150-500 ms after the mouse stops.
  cHoverDelayMs = 450;
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
  THoverHintWindow = class(TCustomControl)
  private
    FInfo: TLspHoverInfo;
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
      const AProgress: string);
    procedure HideHint;
    function IsShowing: Boolean;
    property Info: TLspHoverInfo read FInfo;
  end;

  THoverHintNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

  THoverHintController = class(TComponent)
  private
    FServices: INTACodeEditorServices;
    FNotifier: THoverHintNotifier;
    FNotifierIndex: Integer;
    FWindow: THoverHintWindow;
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
  GController: THoverHintController;
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

{ THoverHintWindow }

constructor THoverHintWindow.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
  FPpi := 96;
  FCodeFontName := 'Consolas';
  FCodeFontSize := 10;
end;

procedure THoverHintWindow.CreateParams(var Params: TCreateParams);
begin
  inherited;
  Params.Style := WS_POPUP;
  Params.ExStyle := WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE;
  Params.WindowClass.style := Params.WindowClass.style or CS_DROPSHADOW;
  Params.WndParent := Application.Handle;
end;

procedure THoverHintWindow.WMMouseActivate(var Message: TWMMouseActivate);
begin
  Message.Result := MA_NOACTIVATE;
end;

procedure THoverHintWindow.WMNCHitTest(var Message: TWMNCHitTest);
begin
  Message.Result := HTCLIENT;
end;

function THoverHintWindow.S(AValue: Integer): Integer;
begin
  Result := MulDiv(AValue, FPpi, 96);
end;

procedure THoverHintWindow.UseCodeFont;
begin
  Canvas.Font.Name := FCodeFontName;
  Canvas.Font.Height := -MulDiv(FCodeFontSize, FPpi, 72);
  Canvas.Font.Style := [];
end;

procedure THoverHintWindow.UseUiFont;
begin
  Canvas.Font.Name := Screen.MessageFont.Name;
  Canvas.Font.Height := -MulDiv(9, FPpi, 72);
  Canvas.Font.Style := [];
  Canvas.Font.Color := FText;
end;

procedure THoverHintWindow.ReadColors;
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
procedure THoverHintWindow.PaintCode(var AX: Integer; AY: Integer;
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

{ The card's size, and the rects the paint and the mouse use. Line one is the
  declaration in the editor font, then " - " and the link in the UI font; the
  note (only where it says more than the link would) and the documentation go
  under it, wrapped to a width between cDocMinWidth and cDocMaxWidth - or to
  the declaration line, when that is wider. }
function THoverHintWindow.Measure: TSize;
var
  LX, LCodeH, LUiH, LWidth, LTextW: Integer;
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

  if FProgress <> '' then
  begin
    Canvas.Font.Style := [fsItalic];
    FCodeWidth := Canvas.TextWidth(FProgress);
    FLinkRect := TRect.Empty;
    FDocRect := TRect.Empty;
    FNoteRect := TRect.Empty;
    Exit(TSize.Create(FCodeWidth + 2 * S(cPad),
      FLineHeight + 2 * S(cPad)));
  end;

  UseCodeFont;
  LX := 0;
  PaintCode(LX, 0, False);
  FCodeWidth := LX;
  LWidth := FCodeWidth;

  UseUiFont;
  FLinkText := '';
  FLinkRect := TRect.Empty;
  if FInfo.FilePath <> '' then
  begin
    FLinkText := ExtractFileName(FInfo.FilePath);
    if FInfo.Line > 0 then
      FLinkText := Format('%s (%d)', [FLinkText, FInfo.Line]);
    LX := S(cPad) + FCodeWidth + Canvas.TextWidth(' - ');
    Canvas.Font.Style := [fsUnderline];
    LTextW := Canvas.TextWidth(FLinkText);
    FLinkRect := Rect(LX, S(cPad), LX + LTextW, S(cPad) + FLineHeight);
    LWidth := FLinkRect.Right - S(cPad);
    Canvas.Font.Style := [];
  end;

  LTextW := Max(S(cDocMinWidth), LWidth);
  LTextW := Min(LTextW, Max(S(cDocMaxWidth), FCodeWidth));
  Result.cy := S(cPad) + FLineHeight;

  // The note says what the link cannot: where a define comes from, that a
  // builtin has no source.
  FNoteRect := TRect.Empty;
  LNote := '';
  if (FInfo.FilePath = '') or SameText(FInfo.Kind, 'conditional symbol') then
    LNote := FInfo.Note;
  if LNote <> '' then
  begin
    Canvas.Font.Style := [fsItalic];
    LRect := Rect(0, 0, LTextW, 0);
    DrawText(Canvas.Handle, PChar(LNote), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FNoteRect := Rect(S(cPad), Result.cy + S(cDocGap),
      S(cPad) + LRect.Width, Result.cy + S(cDocGap) + LRect.Height);
    LWidth := Max(LWidth, LRect.Width);
    Result.cy := FNoteRect.Bottom;
    Canvas.Font.Style := [];
  end;

  FDocRect := TRect.Empty;
  if FInfo.Doc <> '' then
  begin
    LRect := Rect(0, 0, LTextW, 0);
    DrawText(Canvas.Handle, PChar(FInfo.Doc), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    FDocRect := Rect(S(cPad), Result.cy + S(cDocGap),
      S(cPad) + LRect.Width, Result.cy + S(cDocGap) + LRect.Height);
    LWidth := Max(LWidth, LRect.Width);
    Result.cy := FDocRect.Bottom;
  end;

  Result.cx := LWidth + 2 * S(cPad);
  Inc(Result.cy, S(cPad));
end;

procedure THoverHintWindow.ShowAt(const AAnchor: TRect;
  const AInfo: TLspHoverInfo; const AProgress: string);
var
  LSize: TSize;
  LMonitor: TMonitor;
  LWork: TRect;
  LLeft, LTop: Integer;
begin
  FInfo := AInfo;
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

procedure THoverHintWindow.HideHint;
begin
  if HandleAllocated and IsWindowVisible(Handle) then
    ShowWindow(Handle, SW_HIDE);
end;

function THoverHintWindow.IsShowing: Boolean;
begin
  Result := HandleAllocated and IsWindowVisible(Handle);
end;

procedure THoverHintWindow.Paint;
var
  LR: TRect;
  LX, LY, LCodeH: Integer;
begin
  LR := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := FBack;
  Canvas.FillRect(LR);
  Canvas.Pen.Color := FBorder;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(LR);

  if FProgress <> '' then
  begin
    UseUiFont;
    Canvas.Font.Style := [fsItalic];
    Canvas.Font.Color := FDim;
    Canvas.TextOut(S(cPad), S(cPad), FProgress);
    Exit;
  end;

  // Line one: the declaration, then the link - each font centred on the
  // shared line height, so the two read as one line.
  UseCodeFont;
  LCodeH := Canvas.TextHeight('Wg');
  LX := S(cPad);
  LY := S(cPad) + (FLineHeight - LCodeH) div 2;
  PaintCode(LX, LY, True);
  UseUiFont;
  if FLinkText <> '' then
  begin
    LY := S(cPad) + (FLineHeight - Canvas.TextHeight('Wg')) div 2;
    Canvas.Font.Color := FDim;
    Canvas.TextOut(LX, LY, ' - ');
    Canvas.Font.Color := FLink;
    Canvas.Font.Style := [fsUnderline];
    Canvas.TextOut(FLinkRect.Left, LY, FLinkText);
    Canvas.Font.Style := [];
  end;

  if not FNoteRect.IsEmpty then
  begin
    Canvas.Font.Color := FDim;
    Canvas.Font.Style := [fsItalic];
    LR := FNoteRect;
    DrawText(Canvas.Handle, PChar(FInfo.Note), -1, LR,
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

procedure THoverHintWindow.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FLinkRect.Contains(Point(X, Y)) then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
end;

procedure THoverHintWindow.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited;
  if (Button = mbLeft) and FLinkRect.Contains(Point(X, Y)) and
     Assigned(OnLinkClick) then
    OnLinkClick(Self);
end;

{ THoverHintNotifier }

function THoverHintNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents];
end;

{ THoverHintController }

constructor THoverHintController.Create(AOwner: TComponent);
begin
  inherited;
  FNotifierIndex := -1;
  FWindow := THoverHintWindow.Create(Self);
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
    FNotifier := THoverHintNotifier.Create;
    FNotifier.OnEditorMouseMove := DoMouseMove;
    FNotifierIndex := FServices.AddEditorEventsNotifier(FNotifier);
  end;
end;

destructor THoverHintController.Destroy;
begin
  Shutdown;
  inherited;
end;

{ Everything the IDE could call into, released; and the native hint put back
  on - see the header for why at unload too. Safe twice. }
procedure THoverHintController.Shutdown;
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

procedure THoverHintController.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FEditor) then
  begin
    FEditor := nil;
    CancelHover;
  end;
end;

procedure THoverHintController.SetEditor(AEditor: TWinControl);
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
procedure THoverHintController.SetNativeHint(AOn: Boolean);
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
        LspLogToServer('hover hint: could not switch the IDE''s tooltip: '
          + E.ClassName + ': ' + E.Message);
    end;
  finally
    LReg.Free;
  end;
end;

{ Called on every mouse move: cheap (the setting is cached), and acts only on
  a change of our setting - see the header. }
procedure THoverHintController.SyncNativeHint;
var
  LWant: Boolean;
begin
  LWant := HoverHintsEnabled;
  if FSettingsRead and (LWant = FApplied) then
    Exit;
  // Recorded before the switch, so a failed one is not retried on every
  // move; the next change of the setting tries again.
  FSettingsRead := True;
  FApplied := LWant;
  SetNativeHint(not LWant);
end;

procedure THoverHintController.DoMouseMove(const Editor: TWinControl;
  Shift: TShiftState; X, Y: Integer);
var
  LScreen: TPoint;
begin
  if not GAlive then
    Exit;
  SyncNativeHint;
  if not HoverHintsEnabled then
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

procedure THoverHintController.OnShowTimer(Sender: TObject);
begin
  FShowTimer.Enabled := False;
  if GAlive then
    StartHover;
end;

{ The mouse has rested: find the identifier under it, and ask. }
procedure THoverHintController.StartHover;
var
  LState: INTACodeEditorState;
  LLineState: INTACodeEditorLineState;
  LView: IOTAEditView;
  LColumn, LVisibleLine, LFrom, LTo, LGen: Integer;
  LText: string;
  LCellFrom, LCellTo: TRect;
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
  // A word of the line, or a conditional symbol inside a directive - the
  // only places an answer can come from. Asking about blank space or
  // punctuation would show "analyzing..." over nothing while the server is
  // busy.
  LText := LLineState.Text;
  if not IdentRunAt(LText, LColumn, LFrom, LTo) and
     not DirectiveSymbolAt(LText, LColumn, LFrom, LTo) then
    Exit;

  FRow := LLineState.LogicalLineNum;
  FColFrom := LFrom;
  FColTo := LTo;
  FVisibleLine := LVisibleLine;
  LCellFrom := LState.GetCharacterPosPx(LFrom, LVisibleLine);
  LCellTo := LState.GetCharacterPosPx(LTo - 1, LVisibleLine);
  FAnchor := TRect.Create(FEditor.ClientToScreen(LCellFrom.TopLeft),
    FEditor.ClientToScreen(LCellTo.BottomRight));

  Inc(FGeneration);
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
        FWindow.ShowAt(FAnchor, AInfo, '')
      else
        CancelHover;
    end);
end;

procedure THoverHintController.CancelHover;
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
function THoverHintController.OverAnchor(const AScreen: TPoint): Boolean;
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
function THoverHintController.InKeepZone(const AScreen: TPoint): Boolean;
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

function THoverHintController.ProgressText: string;
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

procedure THoverHintController.OnCheckTimer(Sender: TObject);
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
    FWindow.ShowAt(FAnchor, Default(TLspHoverInfo), ProgressText);
  end;
end;

procedure THoverHintController.OnAppMessage(var Msg: TMsg;
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

procedure THoverHintController.OnAppDeactivate(Sender: TObject);
begin
  if GAlive then
    CancelHover;
end;

procedure THoverHintController.OnLinkClick(Sender: TObject);
var
  LInfo: TLspHoverInfo;
begin
  LInfo := FWindow.Info;
  CancelHover;
  if LInfo.FilePath <> '' then
    NavigateHistoryAware(LInfo.FilePath, Max(LInfo.Line, 1), Max(LInfo.Col, 1));
end;

procedure InitializeHoverHint;
begin
  GAlive := True;
  if not Assigned(GController) then
    GController := THoverHintController.Create(nil);
end;

procedure FinalizeHoverHint;
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
  FinalizeHoverHint;

end.
