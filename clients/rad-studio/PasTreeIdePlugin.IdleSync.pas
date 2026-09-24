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

  A RELOAD FROM DISK IS NOT A MODIFICATION. When a file changes outside the
  IDE and the IDE reloads the buffer, EditorViewModified does not fire
  (AVImark, 2026-09-24: five characters added outside, the file reloaded,
  and the log shows no didChange at all), so the server kept the old text
  and the type colouring painted the new text at the old columns. What does
  move is the buffer's own date: CheckBufferReloaded compares it per paint
  (SemanticPaint's BeginPaint hook - the reload repaints the view) and
  queues the file as RELOADED. A save moves it too, which costs one
  "sync-from-disk: unchanged" read of the file. The request path never
  needed this: Sync compares the file's disk stamp itself.

  NEVER READ A RELOADED BUFFER - four live runs, 2026-09-24. The two
  IOTAEditBuffer dates move at different moments: InitialDate when the IDE
  NOTICES the file changed (its reload prompt is about to show, the buffer
  still the old text) and CurrentDate when the reload is done. Reading the
  buffer through IOTAEditorContent put the caret on line 1 and the view at
  the top both while the prompt was up and 70 ms after the reload; at
  260 ms after it the IDE kept both - it restores the view position some
  time after the reload, and a read in between loses it. So a reload
  queues on CurrentDate only, and the tick sends the FILE's text
  (LspReloadedFromDisk), which is exactly what the buffer holds, without
  touching the buffer at all. No idle tick runs while the IDE is modal
  either (IdeIsModal): typed-in buffers wait for the dialog to close.

  Same teardown rules as every notifier in this package: unregister and
  stop the timer BEFORE the session dies, or a tick dispatches into
  unloaded code.
}

interface

uses
  ToolsAPI;

procedure InitializeIdleSync;
procedure FinalizeIdleSync;

/// <summary>
/// Queues AView's file for the idle didChange when its buffer's CurrentDate
/// moved since the last call for that file - the IDE reloaded it from disk,
/// which EditorViewModified never reports. Cheap enough for every repaint:
/// two date reads and a dictionary lookup. The first sight of a file only
/// remembers its dates.
/// </summary>
procedure CheckBufferReloaded(const AView: IOTAEditView);

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Vcl.ExtCtrls,
  Vcl.Forms,
  DockForm,
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
  // A reload has no burst to wait out: the whole new text is there at once.
  // Not zero - the tick then runs after the paint that saw the reload has
  // returned, never inside it.
  cReloadMs = 50;

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

type
  TBufferDates = record
    Initial, Current: TDateTime;
  end;

var
  // Lower-cased path -> the buffer dates CheckBufferReloaded last saw. One
  // entry per file ever painted; never pruned, a closed file's is harmless.
  GBufferDates: TDictionary<string, TBufferDates>;
  // The pending files that were RELOADED rather than typed into: the tick
  // sends them from disk (see the header) and asks their semantic tokens
  // right behind. A request makes the server start the analysis at once
  // instead of after its own 300 ms typing debounce, and the answer
  // repaints - old colours for ~0.1 s instead of ~0.65 s.
  GReloaded: TArray<string>;

{ One modification of APath's buffer, from whichever side reported it:
  counted for the request-path Sync, remembered for the tick, and the
  debounce restarted. }
procedure QueueModified(const APath: string);
var
  LPath: string;
  LKnown: Boolean;
begin
  Inc(GEdits);
  GLastEdited := APath;
  NoteBufferModified(APath);
  // Typing stays in one file, so the last entry is the fast check; the scan
  // only runs when the cursor has moved between tabs.
  LKnown := (Length(GModified) > 0) and
    SameText(GModified[High(GModified)], APath);
  if not LKnown then
    for LPath in GModified do
      if SameText(LPath, APath) then
      begin
        LKnown := True;
        Break;
      end;
  if not LKnown then
    GModified := GModified + [APath];
  // Restart: the timer fires cIdleMs after the LAST modification.
  GTimer.Enabled := False;
  GTimer.Enabled := True;
end;

procedure CheckBufferReloaded(const AView: IOTAEditView);
var
  LBuffer: IOTAEditBuffer;
  LPath, LKey: string;
  LNow, LWas: TBufferDates;
begin
  if (GTimer = nil) or (GBufferDates = nil) or not Assigned(AView) then
    Exit;
  try
    LBuffer := AView.Buffer;
    if not Assigned(LBuffer) then
      Exit;
    LPath := LBuffer.FileName;
    if not IsPascalSourceFile(LPath) then
      Exit;
    LNow.Initial := LBuffer.GetInitialDate;
    LNow.Current := LBuffer.GetCurrentDate;
  except
    Exit;   // a buffer we cannot ask about is left to the request path
  end;
  LKey := LowerCase(LPath);
  if GBufferDates.TryGetValue(LKey, LWas) and
     ((LWas.Initial <> LNow.Initial) or (LWas.Current <> LNow.Current)) then
  begin
    // Both dates logged: which one moved when is what the header's
    // account of a reload rests on.
    TimingLogFmt('buffer dates moved: %s (initial %s -> %s, current %s -> %s)%s',
      [ExtractFileName(LPath),
       FormatDateTime('hh:nn:ss.zzz', LWas.Initial),
       FormatDateTime('hh:nn:ss.zzz', LNow.Initial),
       FormatDateTime('hh:nn:ss.zzz', LWas.Current),
       FormatDateTime('hh:nn:ss.zzz', LNow.Current),
       IfThen(LWas.Current <> LNow.Current, ' - reloaded, queued',
         ' - noticed only')]);
    // InitialDate alone is the IDE noticing, with the old text still in
    // the buffer: nothing to send yet (see the header).
    if LWas.Current <> LNow.Current then
    begin
      if IndexText(LPath, GReloaded) < 0 then
        GReloaded := GReloaded + [LPath];
      GTimer.Interval := cReloadMs;
      GTimer.Enabled := False;
      GTimer.Enabled := True;
    end;
  end;
  GBufferDates.AddOrSetValue(LKey, LNow);
end;

{ A modal dialog is up - the IDE's own "reload?" prompt, or anything else.
  ModalLevel covers ShowModal; a message box or task dialog disables the
  main window without touching it, so that is asked as well. }
function IdeIsModal: Boolean;
begin
  Result := (Application.ModalLevel > 0) or
    ((Application.MainFormHandle <> 0) and
     not IsWindowEnabled(Application.MainFormHandle));
end;

{ TIdleSyncDispatch }

procedure TIdleSyncDispatch.OnTimer(Sender: TObject);
var
  LStart: Double;
  LEdits: Integer;
  LFile: string;
  LPaths, LReloaded: TArray<string>;
  LPath: string;
begin
  // Not while a dialog is up: the timer stays armed and the pending set
  // stays pending, so the read happens one interval after the dialog
  // closes. See the header on what a read in the middle of a reload did.
  if IdeIsModal then
    Exit;
  GTimer.Enabled := False;   // one shot per quiet gap
  GTimer.Interval := cIdleMs;   // a reload's short one is spent
  LEdits := GEdits;
  LFile := GLastEdited;
  LPaths := GModified;
  LReloaded := GReloaded;
  // A buffer typed into and then reloaded holds the file now: it goes the
  // reload's way only, never through a buffer read.
  for LPath in LReloaded do
    if IndexText(LPath, LPaths) >= 0 then
      Delete(LPaths, IndexText(LPath, LPaths), 1);
  GEdits := 0;
  GLastEdited := '';
  GModified := nil;
  GReloaded := nil;
  LStart := TimingNowMs;
  LspIdleSync(LPaths);
  LspReloadedFromDisk(LReloaded);
  // Behind the didChange on the same pipe, so the server answers about the
  // new text - see GReloaded.
  for LPath in LReloaded do
    LspRefreshSemanticTokens(LPath);
  // The whole main-thread cost of one typing pause, after the per-session
  // detail lines it is made of. What the 2026-09-08 busy cursor is measured
  // against: if this number is small and the cursor still shows, the time
  // is not in this package's sync at all.
  TimingLogFmt('idle tick: %d edit(s) in %d file(s), last %s, %d reloaded, ' +
    'total %s', [LEdits, Length(LPaths), ExtractFileName(LFile),
    Length(LReloaded), TimingSince(LStart)]);
end;

{ TIdleSyncNotifier }

procedure TIdleSyncNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  if (GTimer = nil) or not Assigned(EditView) then
    Exit;
  if not IsPascalSourceFile(EditView.Buffer.FileName) then
    Exit;
  QueueModified(EditView.Buffer.FileName);
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
  GBufferDates := TDictionary<string, TBufferDates>.Create;
  GNotifierIndex := LServices.AddNotifier(TIdleSyncNotifier.Create);
  // From here every buffer modification is reported to the document layer,
  // which lets the request-path Sync skip reading buffers nobody touched.
  // Off again in FinalizeIdleSync, and never on without the notifier: with no
  // reports, "not reported modified" would mean nothing.
  SetBufferChangeTracking(GNotifierIndex >= 0);
end;

procedure FinalizeIdleSync;
var
  LServices: IOTAEditorServices80;
begin
  SetBufferChangeTracking(False);
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
  FreeAndNil(GTimer);
  FreeAndNil(GDispatch);
  FreeAndNil(GBufferDates);
end;

end.
