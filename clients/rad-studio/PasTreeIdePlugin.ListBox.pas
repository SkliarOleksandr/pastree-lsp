unit PasTreeIdePlugin.ListBox;

(*
  A virtual, owner-drawn, flat list of rows, and nothing else - the Go To
  picker's list first, and any list of ours that has to repaint per
  keystroke. It replaced a TListBox in lbVirtualOwnerDraw style there on
  2026-09-22, after a day of measuring that one (PasTreeIdePlugin.GoToForm's
  EndListUpdate has the trail): the LISTBOX class draws selection and
  scrolling synchronously outside WM_PAINT, resets itself on LB_SETCOUNT,
  decides for itself whether WM_SETREDRAW(1) is worth a repaint, and the
  VCL reassigns Canvas.Font and Canvas.Brush for every row it hands to
  OnDrawItem. Each of those was a flash or a millisecond that nothing on
  this side could reach.

  Here nothing is drawn outside Paint. Every change - the count, the
  selection, the top row - only records itself and invalidates; the
  invalidations coalesce into one WM_PAINT, which paints the visible rows
  into one bitmap and puts it on screen with one BitBlt. WM_ERASEBKGND is
  declined (the bitmap covers the client area), so there is no blank frame
  to see. BeginUpdate/EndUpdate hold even that one repaint for a caller
  that changes several things at once.

  The scrollbar is the window's own (WS_VSCROLL) and is never hidden
  (SIF_DISABLENOSCROLL): a bar that comes and goes resizes the client area
  and that resize is a repaint of its own. The IDE's dark theme paints it
  through TScrollingStyleHook, registered below - the same hook the VCL
  gives a list box.

  The rows are the owner's: OnDrawItem gets the bitmap's canvas, the row
  index, its rectangle and whether it is the selected one, with the canvas
  brush already the row's background colour and the canvas font colour the
  row's text colour - the owner may paint with the canvas or take its
  Handle and paint raw.

  Keyboard: Up/Down/PgUp/PgDn/Home/End move the selection when the list has
  the focus; Enter is left to the form's default button. The wheel scrolls
  by the system's lines-per-notch. A click selects the row under the mouse
  and fires OnClick, a double-click OnDblClick.
*)

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vcl.Graphics;

type
  TPasTreeListBox = class;

  TPasTreeListBoxDrawItem = procedure(AList: TPasTreeListBox; ACanvas: TCanvas;
    AIndex: Integer; const ARect: TRect; ASelected: Boolean) of object;

  TPasTreeListBox = class(TCustomControl)
  private
    FCount: Integer;
    FItemIndex: Integer;
    FTopIndex: Integer;
    FItemHeight: Integer;
    FBuffer: TBitmap;
    FUpdateLock: Integer;
    FDirty: Boolean;
    FSelectionColor: TColor;
    FSelectionTextColor: TColor;
    FOnDrawItem: TPasTreeListBoxDrawItem;
    procedure SetCount(AValue: Integer);
    procedure SetItemIndex(AValue: Integer);
    procedure SetTopIndex(AValue: Integer);
    procedure SetItemHeight(AValue: Integer);
    function VisibleRows: Integer;
    function MaxTopIndex: Integer;
    procedure Changed;
    procedure UpdateScrollBar;
    procedure WMEraseBkgnd(var AMsg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure WMVScroll(var AMsg: TWMVScroll); message WM_VSCROLL;
    procedure WMGetDlgCode(var AMsg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure WMSize(var AMsg: TWMSize); message WM_SIZE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Several changes, one repaint. Nested. }
    procedure BeginUpdate;
    procedure EndUpdate;
    { The rows the client area shows in full. }
    function PageRows: Integer;
    property Canvas;
    property Count: Integer read FCount write SetCount;
    { -1 for none. Setting it scrolls the row into view, as LB_SETCURSEL
      does; a caller that wants the view left alone puts TopIndex back. }
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property TopIndex: Integer read FTopIndex write SetTopIndex;
    property ItemHeight: Integer read FItemHeight write SetItemHeight;
    property SelectionColor: TColor read FSelectionColor write FSelectionColor;
    property SelectionTextColor: TColor read FSelectionTextColor
      write FSelectionTextColor;
    property OnDrawItem: TPasTreeListBoxDrawItem read FOnDrawItem write FOnDrawItem;
    property Color;
    property Font;
    property ParentFont;
    property TabStop;
    property OnClick;
    property OnDblClick;
  end;

implementation

uses
  System.Math,
  Vcl.Forms,
  Vcl.Themes;

{ TPasTreeListBox }

constructor TPasTreeListBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csSetCaption];
  FItemIndex := -1;
  FItemHeight := 20;
  FSelectionColor := clHighlight;
  FSelectionTextColor := clHighlightText;
  Color := clWindow;
  TabStop := True;
  Width := 200;
  Height := 100;
  FBuffer := TBitmap.Create;
end;

destructor TPasTreeListBox.Destroy;
begin
  FBuffer.Free;
  inherited;
end;

procedure TPasTreeListBox.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  // The list box's look: a sunken client edge and a vertical bar.
  Params.Style := Params.Style or WS_VSCROLL or WS_CLIPCHILDREN;
  Params.ExStyle := Params.ExStyle or WS_EX_CLIENTEDGE;
end;

procedure TPasTreeListBox.CreateWnd;
begin
  inherited CreateWnd;
  UpdateScrollBar;
end;

procedure TPasTreeListBox.BeginUpdate;
begin
  Inc(FUpdateLock);
end;

procedure TPasTreeListBox.EndUpdate;
begin
  if FUpdateLock = 0 then
    Exit;
  Dec(FUpdateLock);
  if (FUpdateLock = 0) and FDirty then
  begin
    FDirty := False;
    UpdateScrollBar;
    Invalidate;
  end;
end;

procedure TPasTreeListBox.Changed;
begin
  if FUpdateLock > 0 then
    FDirty := True
  else
  begin
    UpdateScrollBar;
    Invalidate;
  end;
end;

function TPasTreeListBox.VisibleRows: Integer;
begin
  // Rows the client area shows, the partial one at the bottom included.
  Result := (ClientHeight + FItemHeight - 1) div Max(1, FItemHeight);
end;

function TPasTreeListBox.PageRows: Integer;
begin
  Result := Max(1, ClientHeight div Max(1, FItemHeight));
end;

function TPasTreeListBox.MaxTopIndex: Integer;
begin
  Result := Max(0, FCount - PageRows);
end;

procedure TPasTreeListBox.SetCount(AValue: Integer);
begin
  AValue := Max(0, AValue);
  if AValue = FCount then
    Exit;
  FCount := AValue;
  if FItemIndex >= FCount then
    FItemIndex := -1;
  FTopIndex := EnsureRange(FTopIndex, 0, MaxTopIndex);
  Changed;
end;

procedure TPasTreeListBox.SetItemIndex(AValue: Integer);
begin
  if (AValue < 0) or (AValue >= FCount) then
    AValue := -1;
  if AValue <> FItemIndex then
  begin
    FItemIndex := AValue;
    Changed;
  end;
  // Into view, as LB_SETCURSEL does - the selection is what the user is
  // looking for. Even when unchanged: the caller may have scrolled it out.
  if FItemIndex >= 0 then
  begin
    if FItemIndex < FTopIndex then
      SetTopIndex(FItemIndex)
    else if FItemIndex >= FTopIndex + PageRows then
      SetTopIndex(FItemIndex - PageRows + 1);
  end;
end;

procedure TPasTreeListBox.SetTopIndex(AValue: Integer);
begin
  AValue := EnsureRange(AValue, 0, MaxTopIndex);
  if AValue = FTopIndex then
    Exit;
  FTopIndex := AValue;
  Changed;
end;

procedure TPasTreeListBox.SetItemHeight(AValue: Integer);
begin
  AValue := Max(1, AValue);
  if AValue = FItemHeight then
    Exit;
  FItemHeight := AValue;
  FTopIndex := EnsureRange(FTopIndex, 0, MaxTopIndex);
  Changed;
end;

procedure TPasTreeListBox.UpdateScrollBar;
var
  LInfo: TScrollInfo;
begin
  if not HandleAllocated then
    Exit;
  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.cbSize := SizeOf(LInfo);
  // SIF_DISABLENOSCROLL: a list that fits keeps a disabled bar rather than
  // losing it - the client width stays put across every filter change.
  LInfo.fMask := SIF_RANGE or SIF_PAGE or SIF_POS or SIF_DISABLENOSCROLL;
  LInfo.nMin := 0;
  LInfo.nMax := Max(0, FCount - 1);
  LInfo.nPage := PageRows;
  LInfo.nPos := FTopIndex;
  SetScrollInfo(Handle, SB_VERT, LInfo, True);
end;

procedure TPasTreeListBox.WMEraseBkgnd(var AMsg: TWMEraseBkgnd);
begin
  // Paint covers the whole client area from the bitmap: nothing to erase,
  // and an erase here is exactly the blank frame this control exists to
  // avoid.
  AMsg.Result := 1;
end;

procedure TPasTreeListBox.WMGetDlgCode(var AMsg: TWMGetDlgCode);
begin
  // The arrows are ours; Enter and Tab stay the dialog's.
  AMsg.Result := DLGC_WANTARROWS;
end;

procedure TPasTreeListBox.WMSize(var AMsg: TWMSize);
begin
  inherited;
  FTopIndex := EnsureRange(FTopIndex, 0, MaxTopIndex);
  UpdateScrollBar;
  // Every row anchors its right-hand columns to the edge, so the whole
  // client area repaints - which a resize invalidates anyway, in one go.
  Invalidate;
end;

procedure TPasTreeListBox.WMVScroll(var AMsg: TWMVScroll);
var
  LInfo: TScrollInfo;
begin
  case AMsg.ScrollCode of
    SB_LINEUP: TopIndex := FTopIndex - 1;
    SB_LINEDOWN: TopIndex := FTopIndex + 1;
    SB_PAGEUP: TopIndex := FTopIndex - PageRows;
    SB_PAGEDOWN: TopIndex := FTopIndex + PageRows;
    SB_TOP: TopIndex := 0;
    SB_BOTTOM: TopIndex := MaxTopIndex;
    SB_THUMBTRACK, SB_THUMBPOSITION:
      begin
        // Through GetScrollInfo, not AMsg.Pos: the message carries 16 bits
        // and a group list is longer than that.
        FillChar(LInfo, SizeOf(LInfo), 0);
        LInfo.cbSize := SizeOf(LInfo);
        LInfo.fMask := SIF_TRACKPOS;
        if GetScrollInfo(Handle, SB_VERT, LInfo) then
          TopIndex := LInfo.nTrackPos;
      end;
  end;
  AMsg.Result := 0;
end;

function TPasTreeListBox.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  LLines: Integer;
begin
  Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  if Result then
    Exit;
  LLines := Mouse.WheelScrollLines;
  if LLines <= 0 then
    LLines := 3;
  if WheelDelta > 0 then
    TopIndex := FTopIndex - LLines
  else
    TopIndex := FTopIndex + LLines;
  Result := True;
end;

procedure TPasTreeListBox.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  LRow: Integer;
begin
  if CanFocus then
    SetFocus;
  if Button = mbLeft then
  begin
    LRow := FTopIndex + Y div Max(1, FItemHeight);
    if (LRow >= 0) and (LRow < FCount) then
      ItemIndex := LRow;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TPasTreeListBox.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if FCount = 0 then
    Exit;
  case Key of
    VK_DOWN: ItemIndex := Min(FCount - 1, Max(0, FItemIndex) + 1);
    VK_UP: ItemIndex := Max(0, FItemIndex - 1);
    VK_NEXT: ItemIndex := Min(FCount - 1, Max(0, FItemIndex) + PageRows);
    VK_PRIOR: ItemIndex := Max(0, FItemIndex - PageRows);
    VK_HOME: ItemIndex := 0;
    VK_END: ItemIndex := FCount - 1;
  else
    Exit;
  end;
  Key := 0;
  Click;
end;

procedure TPasTreeListBox.Paint;
var
  LWidth, LHeight, LIdx, LLast, LY: Integer;
  LCanvas: TCanvas;
  LRect: TRect;
  LSelected: Boolean;
begin
  LWidth := ClientWidth;
  LHeight := ClientHeight;
  if (LWidth <= 0) or (LHeight <= 0) then
    Exit;
  // The bitmap is kept between paints and only regrown: a keystroke
  // changes the rows, not the window.
  if (FBuffer.Width < LWidth) or (FBuffer.Height < LHeight) then
    FBuffer.SetSize(Max(FBuffer.Width, LWidth), Max(FBuffer.Height, LHeight));
  LCanvas := FBuffer.Canvas;
  LCanvas.Brush.Style := bsSolid;
  LCanvas.Brush.Color := Color;
  LCanvas.FillRect(Rect(0, 0, LWidth, LHeight));
  LCanvas.Font := Font;
  LLast := Min(FCount - 1, FTopIndex + VisibleRows - 1);
  LY := 0;
  for LIdx := FTopIndex to LLast do
  begin
    LRect := Rect(0, LY, LWidth, LY + FItemHeight);
    LSelected := LIdx = FItemIndex;
    if LSelected then
    begin
      LCanvas.Brush.Color := FSelectionColor;
      LCanvas.Font.Color := FSelectionTextColor;
    end
    else
    begin
      LCanvas.Brush.Color := Color;
      LCanvas.Font.Color := Font.Color;
    end;
    if Assigned(FOnDrawItem) then
      FOnDrawItem(Self, LCanvas, LIdx, LRect, LSelected)
    else
      LCanvas.FillRect(LRect);
    Inc(LY, FItemHeight);
  end;
  BitBlt(Canvas.Handle, 0, 0, LWidth, LHeight, LCanvas.Handle, 0, 0, SRCCOPY);
end;

initialization
  // The themed scrollbar, as the VCL gives a list box.
  TCustomStyleEngine.RegisterStyleHook(TPasTreeListBox, TScrollingStyleHook);

finalization
  TCustomStyleEngine.UnRegisterStyleHook(TPasTreeListBox, TScrollingStyleHook);

end.
