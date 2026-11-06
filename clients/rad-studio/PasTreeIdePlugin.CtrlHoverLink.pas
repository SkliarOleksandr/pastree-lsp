unit PasTreeIdePlugin.CtrlHoverLink;

{
  THE CTRL+HOVER LINK THE IDE DOES NOT DRAW - on a conditional symbol and on
  the `inherited` keyword, with PasTree as the Insight Provider.

  With PasTree selected, the IDE draws its Ctrl+hover underline (the "Hot
  Link" element of the editor colours) only where it would ask the provider
  to browse - an identifier. A name inside a directive is a comment to its
  tokenizer and `inherited` a reserved word: traced on 37.0 (2026-11-06), a
  Ctrl+Click on either reached neither GetCodeInsightType nor
  AsyncGotoDefinitionEx, and no underline appeared. The click on them is
  claimed by PasTreeIdePlugin.GotoDeclaration (PointOnUnaskedLink); this
  unit draws the underline that says the click will go somewhere. With
  DelphiLSP selected the IDE draws its own there, and this unit stands down.

  WHERE: the span under the pointer is found by the same text test the click
  uses (PasTreeIdePlugin.DirectiveText.UnaskedLinkAt), on the pointer's
  logical line - so the underline and the click can never disagree.

  WHEN: on every mouse move, and on Ctrl going down or up with the pointer
  still (the keyboard events, 37.0). A change of the span repaints the
  editor; a paint run crossing the span is repainted over its columns in the
  editor's own Hot Link colour and style, underlined - the after-event
  overpaint SemanticPaint uses (a run is not a token, see that unit). The
  pointer turns into the hand over the span, as over the IDE's own link.

  RAD Studio 12 and newer: the mouse-move event of 11 is not `of object`,
  and 11's provider is never asked about a click anyway.

  MAIN THREAD throughout, as editor events are.
}

interface

procedure InitializeCtrlHoverLink;
procedure FinalizeCtrlHoverLink;

implementation

{$IF CompilerVersion >= 36}
uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Types,
  System.Classes,
  System.Generics.Collections,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  ToolsAPI,
  ToolsAPI.Editor,
  PasTreeIdePlugin.CodeInsight,
  PasTreeIdePlugin.DirectiveText,
  PasTreeIdePlugin.PaintLines,
  PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.Settings;

type
  TCtrlHoverLinkNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
    procedure DoMouseMove(const Editor: TWinControl; Shift: TShiftState;
      X, Y: Integer);
{$IF Declared(TEditorKeyboardEvent)}
    procedure DoKey(const Editor: TWinControl; Key: Word;
      Shift: TShiftState; var Handled: Boolean);
{$IFEND}
    procedure DoPaintText(const ARect: TRect; const AColNum: SmallInt;
      const AText: string; const ASyntaxCode: TOTASyntaxCode;
      const AHilight, ABeforeEvent: Boolean;
      var AAllowDefaultPainting: Boolean;
      const AContext: INTACodeEditorPaintContext);
  end;

var
  GNotifier: INTACodeEditorEvents;
  GNotifierIndex: Integer = -1;
  // The pointer's last position, for a Ctrl press with the mouse still.
  GMouseEditor: TWinControl;
  GMouseX, GMouseY: Integer;
  // The span underlined now: logical row, columns [GFrom, GTo). GEditor nil
  // = none.
  GEditor: TWinControl;
  GRow, GFrom, GTo: Integer;

function CtrlOnlyDown: Boolean;
begin
  Result := (GetKeyState(VK_CONTROL) < 0) and (GetKeyState(VK_SHIFT) >= 0)
    and (GetKeyState(VK_MENU) >= 0);
end;

{ The unasked link under the pointer: logical row and columns, False when
  the pointer is on none. }
function LinkAtPoint(const AEditor: TWinControl; X, Y: Integer;
  out ARow, AFrom, ATo: Integer): Boolean;
var
  LServices: INTACodeEditorServices;
  LState: INTACodeEditorState;
  LLine: INTACodeEditorLineState;
  LColumn, LVisible: Integer;
begin
  Result := False;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  LState := LServices.EditorState[AEditor];
  if not Assigned(LState) then
    Exit;
  if not LState.PointToCharacterPos(Point(X, Y), LColumn, LVisible) then
    Exit;
  // A mouse position maps correctly through LineState, folds or not
  // (PasTreeIdePlugin.PaintLines).
  LLine := LState.LineState[LVisible];
  if not Assigned(LLine) or (LLine.LogicalLineNum < 1) then
    Exit;
  ARow := LLine.LogicalLineNum;
  Result := UnaskedLinkAt(LLine.Text, LColumn, AFrom, ATo);
end;

{ Whether AEditor is still one of the IDE's code editors. The two editor
  references above are kept between events, and a tab closed with Ctrl
  held would otherwise leave a freed control to be repainted or asked. }
function IsKnownEditor(const AEditor: TWinControl): Boolean;
var
  LServices: INTACodeEditorServices;
  LEditors: TList<TWinControl>;
begin
  Result := False;
  if not Assigned(AEditor) or
     not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  LEditors := LServices.GetKnownEditors;
  if LEditors = nil then
    Exit;
  try
    Result := LEditors.IndexOf(AEditor) >= 0;
  finally
    LEditors.Free;
  end;
end;

procedure Repaint(const AEditor: TWinControl);
var
  LServices: INTACodeEditorServices;
begin
  if IsKnownEditor(AEditor) and
     Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.InvalidateEditor(AEditor);
end;

{ Whether the mouse pointer is over AEditor's own window right now. }
function PointerOver(const AEditor: TWinControl): Boolean;
var
  LPos: TPoint;
begin
  Result := GetCursorPos(LPos) and (WindowFromPoint(LPos) = AEditor.Handle);
end;

{ Recomputes the span for the pointer's last position and repaints what
  changed. }
procedure UpdateLink;
var
  LEditor: TWinControl;
  LRow, LFrom, LTo: Integer;
begin
  if Assigned(GMouseEditor) and not IsKnownEditor(GMouseEditor) then
    GMouseEditor := nil;
  LEditor := nil;
  LRow := 0;
  LFrom := 0;
  LTo := 0;
  // Only where the IDE does not draw one itself: PasTree selected. With
  // DelphiLSP the IDE underlines these too, and the switch off means the
  // click is not ours either.
  if Assigned(GMouseEditor) and CtrlOnlyDown and CtrlClickNavigation
     and PasTreeIsActiveInsightProvider
     and LinkAtPoint(GMouseEditor, GMouseX, GMouseY, LRow, LFrom, LTo) then
    LEditor := GMouseEditor;
  // THE POINTER, as the IDE's own link shows it: the hand. Set on every
  // move, not only on a change - the editor answers each move's
  // WM_SETCURSOR, which comes before the move, with its I-beam again. When
  // the link goes, the editor is asked to set its own cursor back.
  if Assigned(LEditor) then
    Winapi.Windows.SetCursor(Screen.Cursors[crHandPoint])
  else if Assigned(GEditor) and IsKnownEditor(GEditor)
    and GEditor.HandleAllocated and PointerOver(GEditor) then
    GEditor.Perform(WM_SETCURSOR, GEditor.Handle,
      MakeLParam(HTCLIENT, WM_MOUSEMOVE));
  if (LEditor = GEditor) and (LRow = GRow) and (LFrom = GFrom)
     and (LTo = GTo) then
    Exit;
  if Assigned(GEditor) and (GEditor <> LEditor) then
    Repaint(GEditor);
  GEditor := LEditor;
  GRow := LRow;
  GFrom := LFrom;
  GTo := LTo;
  if Assigned(LEditor) then
    Repaint(LEditor)
  else
    Repaint(GMouseEditor);
end;

constructor TCtrlHoverLinkNotifier.Create;
begin
  inherited Create;
  OnEditorMouseMove := DoMouseMove;
{$IF Declared(TEditorKeyboardEvent)}
  OnEditorKeyDown := DoKey;
  OnEditorKeyUp := DoKey;
{$IFEND}
  OnEditorPaintText := DoPaintText;
end;

function TCtrlHoverLinkNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents, cevPaintTextEvents];
{$IF Declared(TEditorKeyboardEvent)}
  Include(Result, cevKeyboardEvents);
{$IFEND}
end;

procedure TCtrlHoverLinkNotifier.DoMouseMove(const Editor: TWinControl;
  Shift: TShiftState; X, Y: Integer);
begin
  GMouseEditor := Editor;
  GMouseX := X;
  GMouseY := Y;
  // Cheap when nothing is held and nothing is drawn: no position lookup.
  if not (ssCtrl in Shift) and not Assigned(GEditor) then
    Exit;
  UpdateLink;
end;

{$IF Declared(TEditorKeyboardEvent)}
procedure TCtrlHoverLinkNotifier.DoKey(const Editor: TWinControl; Key: Word;
  Shift: TShiftState; var Handled: Boolean);
begin
  // Ctrl itself, or Shift/Alt joining it (which is no longer the chord the
  // click claims). Never Handled: the key is the editor's.
  if (Key = VK_CONTROL) or (Key = VK_SHIFT) or (Key = VK_MENU) then
    UpdateLink;
end;
{$IFEND}

procedure TCtrlHoverLinkNotifier.DoPaintText(const ARect: TRect;
  const AColNum: SmallInt; const AText: string;
  const ASyntaxCode: TOTASyntaxCode; const AHilight, ABeforeEvent: Boolean;
  var AAllowDefaultPainting: Boolean;
  const AContext: INTACodeEditorPaintContext);
var
  LLine: INTACodeEditorLineState;
  LFrom, LTo: Integer;
  LCanvas: TCanvas;
  LPiece: TRect;
  LOldColor, LColor: TColor;
  LOldStyle: TFontStyles;
begin
  // AFTER the IDE painted the run, and only the one span.
  if ABeforeEvent or (GEditor = nil) or (AContext = nil) or (AText = '') then
    Exit;
  if AContext.EditControl <> GEditor then
    Exit;
  LFrom := GFrom;
  LTo := GTo;
  if AColNum > LFrom then
    LFrom := AColNum;
  if AColNum + Length(AText) < LTo then
    LTo := AColNum + Length(AText);
  if LTo <= LFrom then
    Exit;
  // Ctrl let go where no key event of the editor saw it: draw nothing.
  if not CtrlOnlyDown then
    Exit;
  if PaintedRow(AContext, AColNum, AText, LLine) <> GRow then
    Exit;
  LCanvas := AContext.Canvas;
  LOldColor := LCanvas.Font.Color;
  LOldStyle := LCanvas.Font.Style;
  // The editor's own Hot Link element; a selected run keeps the selection's
  // text colour, the one readable on that background.
  if AHilight then
    LColor := LOldColor
  else
    LColor := EditorSyntaxColor(atHotLink, LOldColor);
  if (LColor = clNone) or (LColor = clDefault) then
    LColor := LOldColor;
  // Columns -> pixels proportionally within the run's own rect, as
  // SemanticPaint does; the brush is the run's background.
  LPiece := Rect(
    ARect.Left + MulDiv(LFrom - AColNum, ARect.Width, Length(AText)),
    ARect.Top,
    ARect.Left + MulDiv(LTo - AColNum, ARect.Width, Length(AText)),
    ARect.Bottom);
  LCanvas.Font.Color := LColor;
  LCanvas.Font.Style := LOldStyle + EditorSyntaxStyle(atHotLink)
    + [fsUnderline];
  LCanvas.FillRect(LPiece);
  LCanvas.TextRect(LPiece, LPiece.Left, LPiece.Top,
    Copy(AText, LFrom - AColNum + 1, LTo - LFrom));
  LCanvas.Font.Color := LOldColor;
  LCanvas.Font.Style := LOldStyle;
end;

procedure InitializeCtrlHoverLink;
var
  LServices: INTACodeEditorServices;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  GNotifier := TCtrlHoverLinkNotifier.Create;
  GNotifierIndex := LServices.AddEditorEventsNotifier(GNotifier);
  if GNotifierIndex < 0 then
    GNotifier := nil;   // refcount frees it
end;

procedure FinalizeCtrlHoverLink;
var
  LServices: INTACodeEditorServices;
begin
  GEditor := nil;
  GMouseEditor := nil;
  if GNotifierIndex < 0 then
    Exit;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

{$ELSE}

procedure InitializeCtrlHoverLink;
begin
end;

procedure FinalizeCtrlHoverLink;
begin
end;

{$IFEND}

end.
