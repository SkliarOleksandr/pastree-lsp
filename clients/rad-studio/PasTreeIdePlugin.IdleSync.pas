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
  Each modification restarts a debounce timer and records WHICH buffer it
  was in; the quiet gap firing it calls LspIdleSync with those buffers, and
  only those are read and pushed as didChange. It is a deliberate NO-OP
  when no server is up - idle typing must never spawn one. The server
  debounces its own rebuild behind that, so the timer here only needs to
  be long enough to not spam didChange per keystroke.

  ONLY THE MODIFIED BUFFERS, not the whole open set (changed 2026-09-08).
  Reading a buffer through IOTAEditorContent.Content costs ~15 ms on a slow
  machine whatever its size, so re-reading 32 open modules on every pause
  was 480 ms of main-thread time per keystroke burst - a busy cursor while
  typing. The full pass stays where completeness matters: in front of a
  request (TLspDocumentSync.Sync).

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
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Timing;

const
  // Long enough that a typing burst coalesces into one didChange, short
  // enough that the analysis starts while the pause still feels like one.
  // 600 on the first live run read as sluggish next to the server's own
  // 300 ms rebuild debounce behind it; 250 puts the whole chain near the
  // half-second the request path already conditioned the user to.
  cIdleMs = 250;

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
  // What the pending tick is for: how many EditorViewModified events it
  // coalesces and the file the last one was in. Reported by the tick's
  // timing line (PasTreeIdePlugin.Timing) so a reader can tell one keystroke
  // from a paste and see which buffer the pause belonged to.
  GEdits: Integer = 0;
  GLastEdited: string;
  // The distinct buffers those events were in - what the tick actually
  // syncs. One keystroke is one path; a multi-file operation (a rename, a
  // paste into two tabs) is a few. Never the whole open set: that is what
  // the request path reads, and what cost half a second per pause on a
  // slow machine (see LspIdleSync).
  GModified: TArray<string>;

{ TIdleSyncDispatch }

procedure TIdleSyncDispatch.OnTimer(Sender: TObject);
var
  LStart: Double;
  LEdits: Integer;
  LFile: string;
  LPaths: TArray<string>;
begin
  GTimer.Enabled := False;   // one shot per quiet gap
  LEdits := GEdits;
  LFile := GLastEdited;
  LPaths := GModified;
  GEdits := 0;
  GLastEdited := '';
  GModified := nil;
  LStart := TimingNowMs;
  LspIdleSync(LPaths);
  // The whole main-thread cost of one typing pause, after the per-session
  // detail lines it is made of. What the 2026-09-08 busy cursor is measured
  // against: if this number is small and the cursor still shows, the time
  // is not in this package's sync at all.
  TimingLogFmt('idle tick: %d edit(s) in %d file(s), last %s, total %s',
    [LEdits, Length(LPaths), ExtractFileName(LFile), TimingSince(LStart)]);
end;

{ TIdleSyncNotifier }

procedure TIdleSyncNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
var
  LPath: string;
  LKnown: Boolean;
begin
  if (GTimer = nil) or not Assigned(EditView) then
    Exit;
  if not IsPascalSourceFile(EditView.Buffer.FileName) then
    Exit;
  Inc(GEdits);
  GLastEdited := EditView.Buffer.FileName;
  // Typing stays in one file, so the last entry is the fast check; the scan
  // only runs when the cursor has moved between tabs.
  LKnown := (Length(GModified) > 0) and
    SameText(GModified[High(GModified)], GLastEdited);
  if not LKnown then
    for LPath in GModified do
      if SameText(LPath, GLastEdited) then
      begin
        LKnown := True;
        Break;
      end;
  if not LKnown then
    GModified := GModified + [GLastEdited];
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
