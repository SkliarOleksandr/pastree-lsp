unit PasTreeIdePlugin.WaitDialog;

{
  The IDE's own wait dialog (IOTAIDEWaitDialogServices), wrapped for the two
  async commands that can sit on a cold project for seconds with nothing
  visible happening - Find References and Rename (user, 2026-08-31). The
  alternative - a synchronous call with an hourglass cursor - was considered
  and rejected: the LSP answer is marshalled to the main thread
  (TThread.Queue, see PasTreeIdePlugin.LspTransport), so blocking the main
  thread to wait for it is a deadlock, and pumping messages to avoid the
  deadlock is reentrancy under an editor caret. The wait dialog is the IDE's
  designed answer: modal-looking, themed, and its message loop still
  delivers queued callbacks.

  RULES OF THE WRAPPER:

  - One dialog at a time, ours. GShown is the only state: Show when nothing
    of ours is up AND the service reports no dialog visible (someone else's
    wait dialog must not be stomped - CloseDialog closes THE dialog, not "our"
    dialog), Close only what we opened.

  - EVERY callback that can be the end of the operation closes the dialog
    FIRST, before any MODAL report - the wait dialog disables input, and a
    modal message box on top of disabled input is a stuck IDE. Filling a
    docked panel is not modal and is the exception: see
    ReportUnderWaitDialog, which deliberately keeps the dialog up for it.

  - Close never throws. It can run during package unload (the same territory
    as FinalizeFindReferencesMessageGroup's shutdown guard), where the
    service may already be half-gone; a leaked wait dialog at shutdown costs
    nothing, an exception there costs the IDE.

  - ShowWaitDialogAfter ARMS the dialog rather than showing it: it appears
    only if the delay passes with the operation still running. A command
    that is usually instant and occasionally slow - Go To, which answers in
    tens of milliseconds off the server's cache and in seconds on a cold
    project - otherwise opens and closes the dialog within one blink, and
    the flash reads as a glitch (Alex, 2026-09-21: "when it starts cold it
    makes sense, afterwards it is just flicker"). Close cancels an armed
    dialog as readily as it closes a shown one, so a caller pairs the two
    the same way whichever happened.
}

interface

uses
  System.SysUtils;   // TProc, for ReportUnderWaitDialog

/// <summary>
/// Shows the IDE wait dialog with the given description under the fixed
/// 'PasTree' caption. No-op if a wait dialog (ours or anyone's) is already
/// visible, or the service is unavailable.
/// </summary>
procedure ShowWaitDialog(const ADescription: string);

/// <summary>
/// Arms the same dialog for ADelayMs from now: it is shown when the delay
/// elapses and NOT shown at all if CloseWaitDialog runs first. For a
/// command whose answer is usually immediate - see the unit header. The
/// timer is a plain VCL one on the main thread, so the delay is measured
/// against the same message loop the LSP answer is queued to. ADelayMs of
/// zero or less shows the dialog outright.
/// </summary>
procedure ShowWaitDialogAfter(ADelayMs: Integer; const ADescription: string);

/// <summary>
/// The "current work" line under the description - one file name at a time
/// during a long synchronous loop (a rename saving fifty files on a slow
/// disk, user 2026-09-12). No-op unless this unit opened the dialog - an
/// armed one has no line to write on yet.
/// </summary>
procedure UpdateWaitDialogWork(const AWork: string);

/// <summary>
/// Closes the dialog IF this unit opened it, and disarms one armed by
/// ShowWaitDialogAfter that has not appeared yet; silently does nothing
/// otherwise. Safe on any path, including shutdown.
/// </summary>
procedure CloseWaitDialog;

/// <summary>
/// Runs AReport - the step that fills a results tab - with the wait dialog
/// STILL UP, saying how many rows it is laying out, and closes it afterwards
/// (in a finally: a report that raises must not leave the IDE with input
/// disabled).
///
/// Closing the dialog the moment the answer arrived left a gap in which the
/// dialog was gone and the tab still empty - 200-300 ms on a few dozen rows,
/// far more on a real reference list - which reads as the command having
/// done nothing (Alex, 2026-09-14). Building the rows is the slow half:
/// each one is an owner-drawn message the panel then lays out and paints.
///
/// For a PANEL only. A modal report - MessageDlg, "no identifier under the
/// cursor" - still closes the dialog first, per the rule in the unit header.
/// </summary>
procedure ReportUnderWaitDialog(ARowCount: Integer; const AReport: TProc);

implementation

uses
  Vcl.ExtCtrls,   // TTimer, for ShowWaitDialogAfter
  ToolsAPI;       // System.SysUtils is in the interface, for TProc

type
  // TTimer.OnTimer wants a method, and this unit has no object of its own;
  // one instance, created with the timer and freed with it.
  TWaitDialogTimer = class
    procedure Elapsed(ASender: TObject);
  end;

var
  GShown: Boolean = False;
  // The armed dialog: one at a time, like the shown one. GTimer is created
  // on the first ShowWaitDialogAfter and lives until finalization - a timer
  // is a window handle, and arming happens on every Ctrl+G.
  GTimer: TTimer = nil;
  GTimerOwner: TWaitDialogTimer = nil;
  GArmedText: string = '';

procedure ShowWaitDialog(const ADescription: string);
var
  LDialog: IOTAIDEWaitDialogServices;
begin
  if GShown then
    Exit;
  if not Supports(BorlandIDEServices, IOTAIDEWaitDialogServices, LDialog) then
    Exit;
  if LDialog.IsVisible then
    Exit;   // someone else's dialog - see the unit header
  LDialog.Show('PasTree', ADescription);
  GShown := True;
end;

{ Disarms an armed dialog. Called by Close and by a Show that overtakes the
  timer, so the two states never both hold. }
procedure Disarm;
begin
  GArmedText := '';
  if Assigned(GTimer) then
    GTimer.Enabled := False;
end;

procedure TWaitDialogTimer.Elapsed(ASender: TObject);
var
  LText: string;
begin
  LText := GArmedText;
  Disarm;   // one shot: the delay has passed, armed becomes shown or nothing
  if LText <> '' then
    ShowWaitDialog(LText);
end;

procedure ShowWaitDialogAfter(ADelayMs: Integer; const ADescription: string);
begin
  if GShown then
    Exit;   // already up - the same rule as Show
  if ADelayMs <= 0 then
  begin
    ShowWaitDialog(ADescription);
    Exit;
  end;
  if not Assigned(GTimer) then
  begin
    GTimerOwner := TWaitDialogTimer.Create;
    GTimer := TTimer.Create(nil);
    GTimer.Enabled := False;
    GTimer.OnTimer := GTimerOwner.Elapsed;
  end;
  GArmedText := ADescription;
  // Disabled before the interval: a running timer keeps its old deadline
  // when only the interval is written.
  GTimer.Enabled := False;
  GTimer.Interval := ADelayMs;
  GTimer.Enabled := True;
end;

procedure UpdateWaitDialogWork(const AWork: string);
var
  LDialog: IOTAIDEWaitDialogServices;
begin
  if not GShown then
    Exit;
  try
    if Supports(BorlandIDEServices, IOTAIDEWaitDialogServices, LDialog) then
      LDialog.UpdateCurrentWork(AWork);
  except
    // Cosmetic, like Close: a progress line must never become the error.
  end;
end;

procedure CloseWaitDialog;
var
  LDialog: IOTAIDEWaitDialogServices;
begin
  // Before the GShown gate: an armed dialog that never appeared still has
  // to be called off, and that is the whole point of arming it.
  Disarm;
  if not GShown then
    Exit;
  GShown := False;
  try
    if Supports(BorlandIDEServices, IOTAIDEWaitDialogServices, LDialog) then
      LDialog.CloseDialog;
  except
    // Never let a cosmetic close take anything down - see the unit header.
  end;
end;

procedure ReportUnderWaitDialog(ARowCount: Integer; const AReport: TProc);
begin
  UpdateWaitDialogWork(Format('Listing %d result(s)...', [ARowCount]));
  try
    AReport();
  finally
    CloseWaitDialog;
  end;
end;

initialization
  // Nothing to set up - a unit cannot have a finalization without one.

finalization
  // The timer owns a window handle; a package that unloads with one armed
  // would fire into freed code. Nothing modal here - see Close's rule.
  if Assigned(GTimer) then
  begin
    GTimer.Enabled := False;
    GTimer.OnTimer := nil;
    FreeAndNil(GTimer);
  end;
  FreeAndNil(GTimerOwner);

end.
