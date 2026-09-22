unit PasTreeIdePlugin.GoToPicker;

{
  Ctrl+G - the Go To picker (PasTreeIdePlugin.GoToForm) over the active
  source: the module's outline and the owning project's declarations, one
  filter box over both, `line N` when the filter is a number. The dialog is
  the demo's; this unit is the IDE side of it - the key, the two lists, the
  landing. A group-wide tab existed until 0.47.23 and was withdrawn after
  testing (Alex, 2026-09-22): the project scope is what the picker is for,
  and a group list cost a fan-out to every project's server.

  THE KEY. Ctrl+G, registered with the package's ONE keyboard binding
  (PasTreeIdePlugin.KeyBindings - btPartial, one row on Key Mappings for
  every key this plugin takes; its header has why there is one and not one
  per feature). The switch (Settings.GoToEnabled) is the ONE place that answers
  krUnhandled: off hands the keystroke back to whatever the keymap binds
  Ctrl+G to, so "off" means "the IDE's own", with nothing to unbind - the
  decl/impl toggle's shape. Once recognised and on, the key is krHandled
  whether or not a list could be shown, for Rename's reason: an unhandled
  key would fall through to a native command on a position ours declined.

  THE LISTS. Every list is an LSP answer on a later main-thread turn
  (pastree/outline, PasTreeIdePlugin.LspSession). The MODULE list is asked
  for FIRST and the picker opens only when it has arrived. The wait dialog
  is ARMED rather than shown (ShowWaitDialogAfter, 250 ms): a cold project
  can take seconds and the picker without its list is a blank box, but a
  warm one answers off the server's cache in tens of milliseconds and the
  dialog was appearing and vanishing in one blink. It is closed - or
  disarmed - BEFORE the modal picker opens, the WaitDialog unit's rule.
  Because the dialog no longer disables input for those first milliseconds,
  GBusy is what keeps a second Ctrl+G from starting a second picker.

  The PROJECT list is asked by the picker itself on the first switch to its
  tab (TGoToListSource), of the owning server alone (LspOutlineProject).

  THE LANDING. A module row and the `line N` row carry their position; a
  project row is placed by the server that listed it
  (LspOutlineTarget - the picker's TGoToResolve) and only then does the
  dialog close. The jump itself is NavigateHistoryAware, so Alt+Left walks
  back from it like from any other navigation of this package.

  THE CARET AND THE LINE COUNT come from the key context's buffer
  (EditPosition.Row, GetLinesInBuffer - present in every ToolsAPI this
  package compiles against). Both are read at the keystroke, before the
  list is asked for: by the time it arrives the caret may have moved, and
  "where am I" means where Ctrl+G was pressed.
}

interface

uses
  ToolsAPI;

procedure InitializeGoTo;
procedure FinalizeGoTo;

/// <summary>
/// Opens the picker for AView's buffer - the keyboard binding's body, and
/// a menu's if one is ever added.
/// </summary>
procedure ExecuteGoTo(const AView: IOTAEditView);

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Vcl.Menus,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.KeyBindings,
  PasTreeIdePlugin.WaitDialog,
  PasTreeIdePlugin.GotoDeclaration,
  PasTreeIdePlugin.GoToForm;

const
  // How long the outline may take before the wait dialog is worth showing.
  cWaitDialogDelayMs = 250;

var
  // Set by Initialize, cleared by Finalize: a callback that lands after the
  // package started unloading must do nothing (the same guard every async
  // unit here keeps).
  GAlive: Boolean = False;
  // An outline request is in flight, or its picker is open - see ExecuteGoTo.
  GBusy: Boolean = False;

{ The Build tab, tagged like every other line this package puts there. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

procedure ExecuteGoTo(const AView: IOTAEditView);
var
  LFile, LProjectName: string;
  LCaretLine, LLineCount: Integer;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  // One at a time. Until 0.47.2 the wait dialog went up at once and
  // DISABLED INPUT, which is what stopped a second Ctrl+G reaching the
  // editor while the first outline was in flight; now the dialog may never
  // appear, so the guard has to be its own. Two in flight would nest a
  // second modal picker inside the first and leave GOpenForm pointing at
  // the inner one, so the outer dialog's late answers would be dropped.
  if GBusy then
    Exit;
  LFile := AView.Buffer.FileName;
  LCaretLine := AView.Buffer.EditPosition.Row;
  LLineCount := AView.Buffer.GetLinesInBuffer;
  LProjectName := TPath.GetFileName(LspOwningProjectFile(LFile));

  // ARMED, not shown (ShowWaitDialogAfter): the outline comes off the
  // server's cache in tens of milliseconds once the project is analyzed,
  // and a wait dialog that opens and closes inside one blink is only a
  // flash (Alex, 2026-09-21). A cold project still gets it, which is what
  // it was put here for. 250 ms is Alex's number, set after trying 400:
  // AVImark warm is 65 ms end to end and a cold one takes seconds, so
  // nothing real lands near the boundary and the shorter delay only means
  // the dialog appears sooner in the case that needs it.
  ShowWaitDialogAfter(cWaitDialogDelayMs,
    'Go To: reading the outline of ' + TPath.GetFileName(LFile));
  GBusy := True;
  LspOutlineModule(LFile,
    procedure(ASuccess: Boolean; const ARows: TArray<TLspOutlineRow>;
      const AError: string)
    var
      LTargetFile: string;
      LTargetLine, LTargetCol: Integer;
    begin
      // Closed FIRST, before anything modal - the wait dialog disables input
      // and a modal window over disabled input is a stuck IDE.
      CloseWaitDialog;
      // In a finally over EVERY path, the modal picker included: a Ctrl+G
      // that cannot be pressed again is worse than the flash this replaced.
      try
        if not GAlive then
          Exit;
        if not ASuccess then
        begin
          LogDiagnostic('Go To: ' + AError);
          Exit;
        end;
        if Length(ARows) = 0 then
        begin
          // The file is not in its project's closure (a file opened from
          // disk, a unit no project compiles): no module list, and the
          // project lists would not know it either.
          LogDiagnostic('Go To: ' + TPath.GetFileName(LFile) +
            ' is not part of the analyzed project');
          Exit;
        end;
        if ShowGoTo(ARows, LFile, LCaretLine, LLineCount, LProjectName,
             // The project list, asked by the picker on the first switch to
             // its tab - the owner's alone.
             procedure(AScope: TGoToScope; const AOnDone: TLspOutlineProc)
             begin
               LspOutlineProject(LFile, AOnDone);
             end,
             // A project row's landing, from the server that listed it.
             procedure(const ARow: TLspOutlineRow; const AOnDone: TLspHitsProc)
             begin
               LspOutlineTarget(ARow, AOnDone);
             end,
             {out} LTargetFile, {out} LTargetLine, {out} LTargetCol) then
          NavigateHistoryAware(LTargetFile, LTargetLine, LTargetCol);
      finally
        GBusy := False;
      end;
    end);
end;

{ The key's handler - Ctrl+G, through PasTreeIdePlugin.KeyBindings. }
procedure GoToKeyProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
begin
  // THE OFF SWITCH - the one krUnhandled here; see the unit header.
  if not GoToEnabled then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) then
    Exit;
  ExecuteGoTo(LView);
end;

procedure InitializeGoTo;
begin
  GAlive := True;
  // Registered, not bound: the wizard binds everything at once after every
  // feature has registered (InitializeKeyBindings).
  RegisterKey(ShortCut(Ord('G'), [ssCtrl]), GoToKeyProc);
end;

procedure FinalizeGoTo;
begin
  // The binding itself is already gone (FinalizeKeyBindings runs first);
  // this gate covers a keystroke the IDE had already dispatched.
  GAlive := False;
  GBusy := False;
  // An armed wait dialog outlives nothing: disarmed here as well as in the
  // callback, since an unload can happen with a request in flight.
  CloseWaitDialog;
end;

end.
