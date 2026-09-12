unit PasTreeIdePlugin.RenameToolbar;

{
  A Revert toolbar INSIDE the IDE's Messages window, shown while the
  "PasTree Rename" tab is the selected one - the one button that takes a
  rename back (see PasTreeIdePlugin.Rename's header: since 0.39.0 a rename
  changes files nobody has open and opens no tabs, so there is no editor to
  press Ctrl+Z in for most of what it did).

  THE TOOLSAPI HAS NO SURFACE FOR THIS. IOTAMessageServices puts rows into a
  group and INTAMessageNotifier lets us add items to the rows' right-click
  menu; nothing lets a plugin put a control above its rows. So this unit
  reaches into the Messages window as a plain VCL form.

  WHAT THE WINDOW IS, as dumped from RAD Studio 13 on 2026-09-11 (the dump
  is what this unit logs when it cannot find its way, see below):

    TMessageViewForm "MessageViewForm"
      TPanel "pnBottom" alBottom
        TTabSet "MessageGroups" alClient        <- one tab per message group
      TPanel "pnTop" alTop (hidden)             <- the IDE's own search box
      TBetterHintWindowVirtualDrawTree "MessageTreeView0" alClient
      TBetterHintWindowVirtualDrawTree "MessageTreeView1" alClient
      ...                                       <- one tree per group

  There is NO container per group whose caption is the group's name - the
  groups are tabs of a Vcl.Tabs.TTabSet at the bottom and one alClient tree
  each, brought to the front as the tab changes. So the toolbar is parented
  into the FORM, top-aligned (every tree is alClient and gives way), and it
  is VISIBLE only while the tab set's selected tab is ours. A timer polls
  that four times a second: the IDE's own OnChange on the tab set is an
  event it may reassign, and chaining into it is exactly the kind of
  coupling this unit avoids - the poll costs nothing measurable and cannot
  break anything.

  THAT IS UNDOCUMENTED, AND THE CODE KNOWS IT. The only IDE class named is
  the form's, by string; the tab set is found as "a TTabSet somewhere in
  the form" (a VCL class this package links anyway). Everything the walk
  finds, and the whole control tree when it does not, goes to the log - so
  when an IDE version changes the shape, the fix starts from data rather than
  from another round trip through a live IDE. If nothing is found the toolbar
  does not appear and one line in the Build tab says so; the rest of the
  rename (the rows, the changed buffers) does not depend on this unit.

  THE TOOLBAR IS PARENTED INTO A FORM THE IDE OWNS, so the IDE may destroy it
  at any moment. A TWinControl frees the controls parented to it whatever
  their Owner, so the toolbar goes with the form and this unit must not hold
  a stale reference: it registers for the toolbar's FreeNotification and nils
  its variable when the notification arrives. Every public entry point
  tolerates a toolbar that is already gone.

  THEMED THROUGH IOTAIDEThemingServices.ApplyTheme, the same call the
  settings dialog uses, so the buttons follow the IDE's light and dark
  themes. The glyph is the IDE's own Undo icon, by way of its EditUndoCommand
  action, which is what Revert is at heart.
}

interface

uses
  System.SysUtils;

/// <summary>
/// Puts (or re-creates) the Revert toolbar into the Messages window,
/// shown while the tab named AGroupCaption is selected. Any earlier toolbar
/// is dropped first. Silent when the window cannot be found - see the unit
/// header; the log has the form's control tree in that case.
/// </summary>
procedure ShowRenameToolbar(const AGroupCaption: string;
  const AOnRevert: TProc);

/// <summary>Greys Revert out - the rename has been taken back.</summary>
procedure SetRenameToolbarEnabled(AEnabled: Boolean);

/// <summary>Removes the toolbar, if it still exists.</summary>
procedure HideRenameToolbar;

implementation

uses
  System.Classes, System.TypInfo, System.StrUtils,
  Vcl.Controls, Vcl.Forms, Vcl.ComCtrls, Vcl.Graphics, Vcl.ToolWin, Vcl.Tabs,
  Vcl.ExtCtrls, Vcl.ActnList,
  ToolsAPI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.Settings;

const
  // The Messages window's form class. Not linked, only compared by name; the
  // whole unit is written so that a wrong name here costs a missing toolbar
  // and a log line rather than anything worse.
  cMessageFormClass = 'TMessageViewForm';
  cPollMs = 250;

type
  // Caption is protected on TControl; this is the customary crack.
  TControlCracker = class(TControl);

  { The toolbar's owner, its button handler and its visibility poll. A
    TComponent so it can receive the toolbar's FreeNotification - which is how
    this unit learns that the IDE destroyed the form and the toolbar with it. }
  TRenameToolbarHost = class(TComponent)
  private
    FToolbar: TToolBar;
    FRevert: TToolButton;
    FTabs: TTabSet;
    FTimer: TTimer;
    FCaption: string;
    FOnRevert: TProc;
    procedure RevertClick(ASender: TObject);
    procedure Poll(ASender: TObject);
    procedure SyncVisible;
  protected
    procedure Notification(AComponent: TComponent;
      AOperation: TOperation); override;
  end;

var
  GHost: TRenameToolbarHost = nil;

procedure Trace(const AWhat: string);
begin
  LspLogToServer('rename toolbar: ' + AWhat);
end;

{ The Build tab, tagged like every other line this package puts there - see
  PasTreeIdePlugin.LspSession's LogDiagnostic for the convention. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ The Messages window, as a VCL form. Screen.CustomForms rather than
  Screen.Forms: a docked IDE window is still a TCustomForm and still
  registered there, whatever it is parented to. }
function FindMessageForm: TCustomForm;
var
  LIdx: Integer;
begin
  for LIdx := 0 to Screen.CustomFormCount - 1 do
    if SameText(Screen.CustomForms[LIdx].ClassName, cMessageFormClass) then
      Exit(Screen.CustomForms[LIdx]);
  Result := nil;
end;

function CaptionOf(AControl: TControl): string;
begin
  try
    Result := TControlCracker(AControl).Caption;
  except
    Result := '';
  end;
end;

{ The control tree of AControl, one line each, into the log. This is the
  diagnostic the unit header promises: when the window is not shaped as this
  code expects, the answer to "how is it shaped then" is here rather than
  another round trip through a live IDE. }
procedure DumpControls(AControl: TControl; ADepth: Integer);
var
  LIdx: Integer;
  LWin: TWinControl;
begin
  Trace(Format('%s%s "%s" caption="%s" align=%s visible=%s bounds=%d,%d %dx%d',
    [StringOfChar(' ', ADepth * 2), AControl.ClassName, AControl.Name,
     CaptionOf(AControl),
     GetEnumName(TypeInfo(TAlign), Ord(AControl.Align)),
     BoolToStr(AControl.Visible, True),
     AControl.Left, AControl.Top, AControl.Width, AControl.Height]));
  if not (AControl is TWinControl) then
    Exit;
  LWin := TWinControl(AControl);
  for LIdx := 0 to LWin.ControlCount - 1 do
    DumpControls(LWin.Controls[LIdx], ADepth + 1);
end;

{ The tab set that lists the message groups: the first TTabSet anywhere in
  the form. Depth first. }
function FindTabSet(AControl: TWinControl): TTabSet;
var
  LIdx: Integer;
  LChild: TControl;
begin
  Result := nil;
  for LIdx := 0 to AControl.ControlCount - 1 do
  begin
    LChild := AControl.Controls[LIdx];
    if LChild is TTabSet then
      Exit(TTabSet(LChild));
    if LChild is TWinControl then
    begin
      Result := FindTabSet(TWinControl(LChild));
      if Assigned(Result) then
        Exit;
    end;
  end;
end;

{ TRenameToolbarHost }

procedure TRenameToolbarHost.Notification(AComponent: TComponent;
  AOperation: TOperation);
begin
  inherited;
  if AOperation <> opRemove then
    Exit;
  // The IDE took the window down and the toolbar with it. Forget the
  // controls and stop asking after them; everything public here checks for
  // nil before touching them.
  if AComponent = FToolbar then
  begin
    Trace('the IDE destroyed the toolbar''s form');
    FToolbar := nil;
    FRevert := nil;
    if Assigned(FTimer) then
      FTimer.Enabled := False;
  end;
  if AComponent = FTabs then
    FTabs := nil;
end;

procedure TRenameToolbarHost.RevertClick(ASender: TObject);
begin
  if Assigned(FOnRevert) then
    FOnRevert();
end;

{ Shown while our tab is the selected one. The tab set's Tabs are the group
  names, which is how ours is recognised - by the caption the group was
  created with, never by position. }
procedure TRenameToolbarHost.SyncVisible;
var
  LVisible: Boolean;
begin
  if not Assigned(FToolbar) then
    Exit;
  LVisible := Assigned(FTabs) and (FTabs.TabIndex >= 0) and
    (FTabs.TabIndex < FTabs.Tabs.Count) and
    SameText(FTabs.Tabs[FTabs.TabIndex], FCaption);
  if FToolbar.Visible <> LVisible then
  begin
    FToolbar.Visible := LVisible;
    if LVisible then
      FToolbar.BringToFront;
    // Every flip, with what the toolbar then measures: this is the line
    // that says whether "not visible" means hidden or means zero-sized.
    Trace(Format('visible=%s (tab %d "%s") bounds=%d,%d %dx%d parent=%s',
      [BoolToStr(LVisible, True), FTabs.TabIndex,
       IfThen(FTabs.TabIndex >= 0, FTabs.Tabs[FTabs.TabIndex], ''),
       FToolbar.Left, FToolbar.Top, FToolbar.Width, FToolbar.Height,
       FToolbar.Parent.ClassName]));
  end;
end;

procedure TRenameToolbarHost.Poll(ASender: TObject);
begin
  try
    SyncVisible;
  except
    // A timer tick must never surface an exception into the IDE's loop; the
    // worst outcome here is a toolbar shown on the wrong tab until the next
    // tick.
  end;
end;

procedure HideRenameToolbar;
begin
  if not Assigned(GHost) then
    Exit;
  try
    if Assigned(GHost.FTimer) then
      GHost.FTimer.Enabled := False;
    // Freeing the toolbar sends the notification that nils the fields, so
    // the order here is deliberate: the toolbar first, the host after.
    GHost.FToolbar.Free;
  except
    // Teardown on a control the IDE may already have destroyed.
  end;
  FreeAndNil(GHost);
end;

procedure SetRenameToolbarEnabled(AEnabled: Boolean);
begin
  if not Assigned(GHost) or not Assigned(GHost.FToolbar) then
    Exit;
  GHost.FRevert.Enabled := AEnabled;
end;

{ The image index of one of the IDE's OWN actions - FileSaveCommand's floppy,
  EditUndoCommand's arrow - in INTAServices.ImageList, so the buttons wear
  the IDE's glyphs in the IDE's theme and scale rather than a bitmap of ours
  that would age with the first new icon set. -1 when the action is not there
  (names are a convention, not a contract): the button then shows its caption
  alone, which is still a button. }
function IdeActionImageIndex(const AActionName: string): Integer;
var
  LServices: INTAServices;
  LIdx: Integer;
begin
  Result := -1;
  if not Supports(BorlandIDEServices, INTAServices, LServices) or
     not Assigned(LServices.ActionList) then
    Exit;
  for LIdx := 0 to LServices.ActionList.ActionCount - 1 do
    if SameText(LServices.ActionList.Actions[LIdx].Name, AActionName) and
       (LServices.ActionList.Actions[LIdx] is TCustomAction) then
      Exit(TCustomAction(LServices.ActionList.Actions[LIdx]).ImageIndex);
end;

function AddButton(AToolbar: TToolBar; const ACaption, AIdeAction: string;
  AOnClick: TNotifyEvent): TToolButton;
begin
  Result := TToolButton.Create(AToolbar);
  Result.Caption := ACaption;
  Result.ImageIndex := IdeActionImageIndex(AIdeAction);
  Result.AutoSize := True;
  Result.OnClick := AOnClick;
  Result.Parent := AToolbar;
  Trace(Format('button %s: image %d from %s',
    [ACaption, Result.ImageIndex, AIdeAction]));
end;

procedure BuildRenameToolbar(const AGroupCaption: string;
  const AOnRevert: TProc);
var
  LForm: TCustomForm;
  LTabs: TTabSet;
  LTheming: IOTAIDEThemingServices;
  LServices: INTAServices;
begin
  HideRenameToolbar;
  LForm := FindMessageForm;
  if not Assigned(LForm) then
  begin
    Trace('no ' + cMessageFormClass + ' among the forms - no toolbar');
    LogDiagnostic('rename: the Messages window was not found, so there is ' +
      'no Revert toolbar - see the pastree-lsp.log');
    Exit;
  end;
  LTabs := FindTabSet(LForm);
  if AdvancedLoggingEnabled or not Assigned(LTabs) then
  begin
    Trace(Format('control tree of %s (looking for a TTabSet):',
      [LForm.ClassName]));
    DumpControls(LForm, 1);
  end;
  if not Assigned(LTabs) then
  begin
    Trace('no TTabSet in the form - no toolbar');
    LogDiagnostic('rename: no place for the Revert toolbar in the ' +
      'Messages window - its control tree is in the pastree-lsp.log');
    Exit;
  end;
  Trace(Format('tab set: %s "%s", %d tab(s), selected %d, tabs: %s',
    [LTabs.ClassName, LTabs.Name, LTabs.Tabs.Count, LTabs.TabIndex,
     LTabs.Tabs.CommaText]));

  GHost := TRenameToolbarHost.Create(nil);
  GHost.FCaption := AGroupCaption;
  GHost.FOnRevert := AOnRevert;
  GHost.FTabs := LTabs;
  LTabs.FreeNotification(GHost);
  GHost.FToolbar := TToolBar.Create(GHost);
  GHost.FToolbar.FreeNotification(GHost);
  GHost.FToolbar.Visible := False;
  // PARENT FIRST, EVERYTHING ELSE AFTER. A TToolBar talks to its window
  // handle for its buttons, its image list and its List style, and it has no
  // handle until it has a parent window: each of those set before this line
  // raised EInvalidOperation "has no parent window" in a live run
  // (2026-09-11, twice - once for the buttons, once for Images).
  GHost.FToolbar.Parent := LForm;
  Trace('toolbar parented');
  GHost.FToolbar.ShowCaptions := True;
  // Caption beside the glyph rather than under it: one row, like the IDE's
  // own toolbars with captions on.
  GHost.FToolbar.List := True;
  if Supports(BorlandIDEServices, INTAServices, LServices) then
    GHost.FToolbar.Images := LServices.ImageList;
  GHost.FToolbar.AutoSize := True;
  GHost.FToolbar.EdgeBorders := [ebBottom];
  GHost.FToolbar.AlignWithMargins := True;   // breathing room, like the IDE's own
  GHost.FToolbar.Align := alTop;
  // Under the IDE's own top panel (its search box, hidden by default):
  // Top := 0 among alTop siblings puts this one above, so ordered after it.
  GHost.FToolbar.Top := LForm.ClientHeight;
  GHost.FRevert := AddButton(GHost.FToolbar, 'Revert', 'EditUndoCommand',
    GHost.RevertClick);
  Trace('toolbar buttons added');
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled then
    try
      LTheming.ApplyTheme(GHost.FToolbar);
    except
      // Colours. An unthemed toolbar is a blemish; a rename that fails to
      // report because of one would be a bug.
    end;
  Trace('toolbar themed');
  GHost.SyncVisible;
  GHost.FTimer := TTimer.Create(GHost);
  GHost.FTimer.Interval := cPollMs;
  GHost.FTimer.OnTimer := GHost.Poll;
  GHost.FTimer.Enabled := True;
end;

{ GUARDED, because everything above touches controls the IDE owns and an
  exception there must not take the rename's report and its document sync
  down with it - which is exactly what happened on 2026-09-11: the toolbar
  raised after finding its tab set, the buffers were changed, and the server
  was never told. The toolbar is decoration on the result; the result is not
  decoration on the toolbar. }
procedure ShowRenameToolbar(const AGroupCaption: string;
  const AOnRevert: TProc);
begin
  try
    BuildRenameToolbar(AGroupCaption, AOnRevert);
  except
    on E: Exception do
    begin
      Trace(Format('FAILED with %s: %s', [E.ClassName, E.Message]));
      LogDiagnostic(Format('rename: the Revert toolbar could not be ' +
        'created (%s: %s) - see the pastree-lsp.log', [E.ClassName, E.Message]));
      HideRenameToolbar;
    end;
  end;
end;

initialization

finalization
  HideRenameToolbar;

end.
