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
    FIRST, before any TellUser/report - the wait dialog disables input, and
    a modal message box on top of disabled input is a stuck IDE.

  - Close never throws. It can run during package unload (the same territory
    as FinalizeFindReferencesMessageGroup's shutdown guard), where the
    service may already be half-gone; a leaked wait dialog at shutdown costs
    nothing, an exception there costs the IDE.
}

interface

/// <summary>
/// Shows the IDE wait dialog with the given description under the fixed
/// 'PasTree' caption. No-op if a wait dialog (ours or anyone's) is already
/// visible, or the service is unavailable.
/// </summary>
procedure ShowWaitDialog(const ADescription: string);

/// <summary>
/// Closes the dialog IF this unit opened it; silently does nothing
/// otherwise. Safe on any path, including shutdown.
/// </summary>
procedure CloseWaitDialog;

implementation

uses
  System.SysUtils, ToolsAPI;

var
  GShown: Boolean = False;

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

procedure CloseWaitDialog;
var
  LDialog: IOTAIDEWaitDialogServices;
begin
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

end.
