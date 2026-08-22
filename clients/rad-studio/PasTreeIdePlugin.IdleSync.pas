unit PasTreeIdePlugin.IdleSync;

{
  IDLE-DEBOUNCED didChange - what makes diagnostics LIVE instead of
  save-fresh. Before this unit the document sync ran only in front of a
  REQUEST (every Lsp* call pairs EnsureSession+Sync), so typing without
  asking anything never reached the server, and a squiggle earned by an
  edit appeared - or cleared - only on the next save or navigation (first
  live run of the painted squiggles, 2026-08-22).

  Trigger: INTAEditServicesNotifier.EditorViewModified, the IDE's own
  "this buffer changed" event (covers typing, paste, undo - anything).
  Each modification restarts a debounce timer; the quiet gap firing it
  calls LspIdleSync, which pushes didChange for whatever differs and is a
  deliberate NO-OP when no server is up - idle typing must never spawn
  one. The server debounces its own rebuild behind that, so the timer here
  only needs to be long enough to not spam didChange per keystroke.

  Same teardown rules as every notifier in this package: unregister and
  stop the timer BEFORE the session dies, or a tick dispatches into
  unloaded code.
}

interface

procedure InitializeIdleSync;
procedure FinalizeIdleSync;

implementation

uses
  System.SysUtils,
  System.Classes,
  Vcl.ExtCtrls,
  DockForm,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments;

const
  // Long enough that a typing burst coalesces into one didChange, short
  // enough that the analysis starts while the pause still feels like one.
  cIdleMs = 600;

type
  TIdleSyncDispatch = class
  public
    procedure OnTimer(Sender: TObject);
  end;

  TIdleSyncNotifier = class(TNotifierObject, INTAEditServicesNotifier)
  public
    procedure WindowShow(const EditWindow: INTAEditWindow;
      Show, LoadedFromDesktop: Boolean);
    procedure WindowNotification(const EditWindow: INTAEditWindow;
      Operation: TOperation);
    procedure WindowActivated(const EditWindow: INTAEditWindow);
    procedure WindowCommand(const EditWindow: INTAEditWindow;
      Command, Param: Integer; var Handled: Boolean);
    procedure EditorViewActivated(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure EditorViewModified(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure DockFormVisibleChanged(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormUpdated(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormRefresh(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
  end;

var
  GNotifierIndex: Integer = -1;
  GTimer: TTimer;
  GDispatch: TIdleSyncDispatch;

{ TIdleSyncDispatch }

procedure TIdleSyncDispatch.OnTimer(Sender: TObject);
begin
  GTimer.Enabled := False;   // one shot per quiet gap
  LspIdleSync;
end;

{ TIdleSyncNotifier }

procedure TIdleSyncNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  if (GTimer = nil) or not Assigned(EditView) then
    Exit;
  if not IsPascalSourceFile(EditView.Buffer.FileName) then
    Exit;
  // Restart: the timer fires cIdleMs after the LAST modification.
  GTimer.Enabled := False;
  GTimer.Enabled := True;
end;

procedure TIdleSyncNotifier.WindowShow(const EditWindow: INTAEditWindow;
  Show, LoadedFromDesktop: Boolean);
begin
end;

procedure TIdleSyncNotifier.WindowNotification(
  const EditWindow: INTAEditWindow; Operation: TOperation);
begin
end;

procedure TIdleSyncNotifier.WindowActivated(const EditWindow: INTAEditWindow);
begin
end;

procedure TIdleSyncNotifier.WindowCommand(const EditWindow: INTAEditWindow;
  Command, Param: Integer; var Handled: Boolean);
begin
end;

procedure TIdleSyncNotifier.EditorViewActivated(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
end;

procedure TIdleSyncNotifier.DockFormVisibleChanged(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TIdleSyncNotifier.DockFormUpdated(const EditWindow: INTAEditWindow;
  DockForm: TDockableForm);
begin
end;

procedure TIdleSyncNotifier.DockFormRefresh(const EditWindow: INTAEditWindow;
  DockForm: TDockableForm);
begin
end;

procedure InitializeIdleSync;
var
  LServices: IOTAEditorServices80;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
    Exit;
  GDispatch := TIdleSyncDispatch.Create;
  GTimer := TTimer.Create(nil);
  GTimer.Enabled := False;
  GTimer.Interval := cIdleMs;
  GTimer.OnTimer := GDispatch.OnTimer;
  GNotifierIndex := LServices.AddNotifier(TIdleSyncNotifier.Create);
end;

procedure FinalizeIdleSync;
var
  LServices: IOTAEditorServices80;
begin
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
  FreeAndNil(GTimer);
  FreeAndNil(GDispatch);
end;

end.
