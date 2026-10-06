unit PasTreeIdePlugin.RenameToolbar;

{
  A Revert toolbar INSIDE the IDE's Messages window, shown while the
  "PasTree Rename" tab is the selected one - the one button that takes a
  rename back (see PasTreeIdePlugin.Rename's header: since 0.39.0 a rename
  changes files nobody has open and opens no tabs, so there is no editor to
  press Ctrl+Z in for most of what it did).

  SINCE 0.62.0 ANY RESULT TAB CAN HAVE ONE (ShowResultToolbar): one host per
  tab, keyed by the tab's caption, with the buttons the caller passes - the
  Unused Units tab's Remove and Revert. The Rename calls are wrappers.

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

type
  /// <summary>One button of a result tab's toolbar: ACaption beside the
  /// glyph of the IDE action named AIdeAction (caption alone when there is
  /// no such action), AOnClick its handler.</summary>
  TResultToolButton = record
    Caption: string;
    IdeAction: string;
    OnClick: TProc;
  end;

function ResultToolButton(const ACaption, AIdeAction: string;
  const AOnClick: TProc): TResultToolButton;

/// <summary>
/// The general form, since 0.62.0 (the Unused Units tab - Remove and
/// Revert): a toolbar with AButtons above the rows of the tab named
/// AGroupCaption, one per tab. An earlier toolbar for the same tab is
/// dropped first; another tab's is left alone. Silent when the window
/// cannot be found, as below.
/// </summary>
procedure ShowResultToolbar(const AGroupCaption: string;
  const AButtons: array of TResultToolButton);

/// <summary>Enables or greys out button AIndex of that tab's toolbar.</summary>
procedure SetResultToolbarEnabled(const AGroupCaption: string;
  AIndex: Integer; AEnabled: Boolean);

/// <summary>Removes that tab's toolbar, if it still exists.</summary>
procedure HideResultToolbar(const AGroupCaption: string);

/// <summary>
/// The row focused in the Messages window's tree in front - the tab's own
/// while its toolbar is clicked. AChain: per row, the focused one first,
/// then its parent, up to the top level - the pointers that may be the one
/// AddCustomMessage handed back for it: the tree node itself, then what its
/// data holds. On 13.1 the node is NOT that pointer - a row under a
/// top-level row was told only by its top-level position until 0.62.1, so
/// Remove on one entry took its whole section (Alex, 2026-10-06).
/// ATopIndex: the top-level row's position (0 = the group's first), -1 when
/// unknown. False when nothing is focused or the tree cannot be read (it is
/// the IDE's, through RTTI - see the implementation); the log says why.
/// </summary>
function ResultFocusedRow(out AChain: TArray<TArray<Pointer>>;
  out ATopIndex: Integer): Boolean;

/// <summary>
/// Focuses and selects, in the Messages window's tree in front, the row
/// AddCustomMessage handed back ARow for, and scrolls it into view - the
/// reverse of ResultFocusedRow, for a tab that was rebuilt (the ToolsAPI
/// can only clear a group and fill it again) and wants its selection on the
/// row after the one removed. False, and a log line, when it cannot.
/// </summary>
function ResultSelectRow(ARow: Pointer): Boolean;

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
  System.Classes, System.TypInfo, System.Rtti, System.StrUtils,
  System.Generics.Collections, System.Math,
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
    FButtons: TArray<TToolButton>;   // Tag = the index into FHandlers
    FHandlers: TArray<TProc>;
    FTabs: TTabSet;
    FTimer: TTimer;
    FCaption: string;
    procedure ButtonClick(ASender: TObject);
    procedure Poll(ASender: TObject);
    procedure SyncVisible;
  protected
    procedure Notification(AComponent: TComponent;
      AOperation: TOperation); override;
  end;

var
  // One host per result tab, by lower-cased caption.
  GHosts: TDictionary<string, TRenameToolbarHost> = nil;
  // The tab the Rename wrappers below speak for.
  GRenameCaption: string = '';

function ResultToolButton(const ACaption, AIdeAction: string;
  const AOnClick: TProc): TResultToolButton;
begin
  Result.Caption := ACaption;
  Result.IdeAction := AIdeAction;
  Result.OnClick := AOnClick;
end;

function HostOf(const ACaption: string): TRenameToolbarHost;
begin
  Result := nil;
  if Assigned(GHosts) then
    GHosts.TryGetValue(LowerCase(ACaption), Result);
end;

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
    FButtons := nil;
    if Assigned(FTimer) then
      FTimer.Enabled := False;
  end;
  if AComponent = FTabs then
    FTabs := nil;
end;

procedure TRenameToolbarHost.ButtonClick(ASender: TObject);
var
  LIdx: Integer;
begin
  LIdx := TComponent(ASender).Tag;
  if (LIdx >= 0) and (LIdx < Length(FHandlers)) and
     Assigned(FHandlers[LIdx]) then
    FHandlers[LIdx]();
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

procedure HideResultToolbar(const AGroupCaption: string);
var
  LHost: TRenameToolbarHost;
begin
  LHost := HostOf(AGroupCaption);
  if not Assigned(LHost) then
    Exit;
  GHosts.Remove(LowerCase(AGroupCaption));
  try
    if Assigned(LHost.FTimer) then
      LHost.FTimer.Enabled := False;
    // Freeing the toolbar sends the notification that nils the fields, so
    // the order here is deliberate: the toolbar first, the host after.
    LHost.FToolbar.Free;
  except
    // Teardown on a control the IDE may already have destroyed.
  end;
  LHost.Free;
end;

procedure SetResultToolbarEnabled(const AGroupCaption: string;
  AIndex: Integer; AEnabled: Boolean);
var
  LHost: TRenameToolbarHost;
begin
  LHost := HostOf(AGroupCaption);
  if not Assigned(LHost) or not Assigned(LHost.FToolbar) or (AIndex < 0) or
     (AIndex >= Length(LHost.FButtons)) then
    Exit;
  LHost.FButtons[AIndex].Enabled := AEnabled;
end;

procedure HideRenameToolbar;
begin
  if GRenameCaption <> '' then
    HideResultToolbar(GRenameCaption);
end;

procedure SetRenameToolbarEnabled(AEnabled: Boolean);
begin
  SetResultToolbarEnabled(GRenameCaption, 0, AEnabled);
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

procedure BuildResultToolbar(const AGroupCaption: string;
  const AButtons: array of TResultToolButton);
var
  LForm: TCustomForm;
  LTabs: TTabSet;
  LTheming: IOTAIDEThemingServices;
  LServices: INTAServices;
  LHost: TRenameToolbarHost;
  LButton: TToolButton;
begin
  HideResultToolbar(AGroupCaption);
  LForm := FindMessageForm;
  if not Assigned(LForm) then
  begin
    Trace('no ' + cMessageFormClass + ' among the forms - no toolbar');
    LogDiagnostic(AGroupCaption + ': the Messages window was not found, so ' +
      'there is no toolbar - see the pastree-lsp.log');
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
    LogDiagnostic(AGroupCaption + ': no place for the toolbar in the ' +
      'Messages window - its control tree is in the pastree-lsp.log');
    Exit;
  end;
  Trace(Format('tab set: %s "%s", %d tab(s), selected %d, tabs: %s',
    [LTabs.ClassName, LTabs.Name, LTabs.Tabs.Count, LTabs.TabIndex,
     LTabs.Tabs.CommaText]));

  LHost := TRenameToolbarHost.Create(nil);
  if not Assigned(GHosts) then
    GHosts := TDictionary<string, TRenameToolbarHost>.Create;
  GHosts.AddOrSetValue(LowerCase(AGroupCaption), LHost);
  LHost.FCaption := AGroupCaption;
  LHost.FTabs := LTabs;
  LTabs.FreeNotification(LHost);
  LHost.FToolbar := TToolBar.Create(LHost);
  LHost.FToolbar.FreeNotification(LHost);
  LHost.FToolbar.Visible := False;
  // PARENT FIRST, EVERYTHING ELSE AFTER. A TToolBar talks to its window
  // handle for its buttons, its image list and its List style, and it has no
  // handle until it has a parent window: each of those set before this line
  // raised EInvalidOperation "has no parent window" in a live run
  // (2026-09-11, twice - once for the buttons, once for Images).
  LHost.FToolbar.Parent := LForm;
  Trace('toolbar parented');
  LHost.FToolbar.ShowCaptions := True;
  // Caption beside the glyph rather than under it: one row, like the IDE's
  // own toolbars with captions on.
  LHost.FToolbar.List := True;
  if Supports(BorlandIDEServices, INTAServices, LServices) then
    LHost.FToolbar.Images := LServices.ImageList;
  LHost.FToolbar.AutoSize := True;
  LHost.FToolbar.EdgeBorders := [ebBottom];
  LHost.FToolbar.AlignWithMargins := True;   // breathing room, like the IDE's own
  LHost.FToolbar.Align := alTop;
  // Under the IDE's own top panel (its search box, hidden by default):
  // Top := 0 among alTop siblings puts this one above, so ordered after it.
  LHost.FToolbar.Top := LForm.ClientHeight;
  // Added in reverse: a TToolBar lays a new button out in FRONT of the ones
  // already there, so the last added is the first shown.
  SetLength(LHost.FButtons, Length(AButtons));
  SetLength(LHost.FHandlers, Length(AButtons));
  for var LIdx := High(AButtons) downto 0 do
  begin
    LButton := AddButton(LHost.FToolbar, AButtons[LIdx].Caption,
      AButtons[LIdx].IdeAction, LHost.ButtonClick);
    LButton.Tag := LIdx;
    LHost.FButtons[LIdx] := LButton;
    LHost.FHandlers[LIdx] := AButtons[LIdx].OnClick;
  end;
  Trace('toolbar buttons added');
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled then
    try
      LTheming.ApplyTheme(LHost.FToolbar);
    except
      // Colours. An unthemed toolbar is a blemish; a result that fails to
      // report because of one would be a bug.
    end;
  Trace('toolbar themed');
  LHost.SyncVisible;
  LHost.FTimer := TTimer.Create(LHost);
  LHost.FTimer.Interval := cPollMs;
  LHost.FTimer.OnTimer := LHost.Poll;
  LHost.FTimer.Enabled := True;
end;

{ GUARDED, because everything above touches controls the IDE owns and an
  exception there must not take the result's report and its document sync
  down with it - which is exactly what happened to a rename on 2026-09-11:
  the toolbar raised after finding its tab set, the buffers were changed, and
  the server was never told. The toolbar is decoration on the result; the
  result is not decoration on the toolbar. }
procedure ShowResultToolbar(const AGroupCaption: string;
  const AButtons: array of TResultToolButton);
begin
  try
    BuildResultToolbar(AGroupCaption, AButtons);
  except
    on E: Exception do
    begin
      Trace(Format('FAILED with %s: %s', [E.ClassName, E.Message]));
      LogDiagnostic(Format('%s: the toolbar could not be created (%s: %s) - ' +
        'see the pastree-lsp.log', [AGroupCaption, E.ClassName, E.Message]));
      HideResultToolbar(AGroupCaption);
    end;
  end;
end;

{ THE FOCUSED ROW. The ToolsAPI says nothing about the selection of a
  message group (INTAMessageNotifier hands the focused row to a right-click
  menu only), and a toolbar button needs it. The rows are a VirtualTrees
  tree of the IDE's own (TBetterHintWindowVirtualDrawTree, in vclide), one
  per group, the shown one brought to the front - so the LAST visible tree
  among the form's controls. The package does not link VirtualTrees; its
  public properties are reached through RTTI by name: FocusedNode (a
  PVirtualNode) and NodeParent[Node] (nil at the top level). A
  TVirtualNode starts with its Index among its siblings (a Cardinal) in
  every VirtualTrees there has been - that is the top-level position. Every
  step that fails says so in the log and answers False: a Remove that does
  not know the row does nothing rather than a guess. }

function NodeParentOf(ATree: TObject; AProp: TRttiIndexedProperty;
  ANode: Pointer): Pointer;
var
  LArg, LValue: TValue;
  LParamType: TRttiType;
begin
  LParamType := AProp.ReadMethod.GetParameters[0].ParamType;
  if Assigned(LParamType) then
    TValue.Make(@ANode, LParamType.Handle, LArg)
  else
    TValue.Make(@ANode, TypeInfo(Pointer), LArg);
  LValue := AProp.GetValue(ATree, [LArg]);
  Result := PPointer(LValue.GetReferenceToRawData)^;
end;

{ What may be the AddCustomMessage pointer of tree node ANode: the node,
  then - through GetNodeData by RTTI, when the tree has it - the node's data
  and the pointer at its start, then the first words of the node's block,
  which VirtualTrees allocates with the data in it. The caller matches them
  against the pointers it was handed. A node field is another node, never a
  message line - but the words read past the node's own block can be the
  NEXT node's, its data included: the earlier a candidate, the surer it is
  the node's own (ResultSelectRow picks by that). }
function RowCandidates(ATree: TObject; AGetData: TRttiMethod;
  ANode: Pointer): TArray<Pointer>;
const
  cScanWords = 32;
var
  LArg, LValue: TValue;
  LParamType: TRttiType;
  LData: Pointer;
begin
  Result := [ANode];
  if Assigned(AGetData) then
    try
      LParamType := AGetData.GetParameters[0].ParamType;
      if Assigned(LParamType) then
        TValue.Make(@ANode, LParamType.Handle, LArg)
      else
        TValue.Make(@ANode, TypeInfo(Pointer), LArg);
      LValue := AGetData.Invoke(ATree, [LArg]);
      LData := PPointer(LValue.GetReferenceToRawData)^;
      if LData <> nil then
        Result := Result + [LData, PPointer(LData)^];
    except
      on E: Exception do
        Trace(Format('focused row: GetNodeData failed with %s: %s',
          [E.ClassName, E.Message]));
    end;
  try
    for var LIdx := 0 to cScanWords - 1 do
      Result := Result + [PPointer(PByte(ANode) + LIdx * SizeOf(Pointer))^];
  except
    // Past the end of a mapped block: what was read is what there is.
  end;
end;

function ResultFocusedRow(out AChain: TArray<TArray<Pointer>>;
  out ATopIndex: Integer): Boolean;
var
  LForm: TCustomForm;
  LTree: TControl;
  LCtx: TRttiContext;
  LType: TRttiType;
  LFocused: TRttiProperty;
  LParent: TRttiIndexedProperty;
  LGetData: TRttiMethod;
  LValue: TValue;
  LNode, LUp: Pointer;
begin
  Result := False;
  AChain := nil;
  LGetData := nil;
  ATopIndex := -1;
  try
    LForm := FindMessageForm;
    if not Assigned(LForm) then
    begin
      Trace('focused row: no Messages window');
      Exit;
    end;
    LTree := nil;
    for var LIdx := 0 to LForm.ControlCount - 1 do
      if LForm.Controls[LIdx].Visible and
         ContainsText(LForm.Controls[LIdx].ClassName, 'VirtualDrawTree') then
        LTree := LForm.Controls[LIdx];
    if not Assigned(LTree) then
    begin
      Trace('focused row: no visible VirtualDrawTree in the Messages window');
      DumpControls(LForm, 1);
      Exit;
    end;
    LCtx := TRttiContext.Create;
    LType := LCtx.GetType(LTree.ClassType);
    LFocused := nil;
    LParent := nil;
    if Assigned(LType) then
    begin
      LFocused := LType.GetProperty('FocusedNode');
      LParent := LType.GetIndexedProperty('NodeParent');
      for var LMethod in LType.GetMethods('GetNodeData') do
        if (Length(LMethod.GetParameters) = 1) and
           Assigned(LMethod.ReturnType) and
           (LMethod.ReturnType.TypeKind = tkPointer) then
          LGetData := LMethod;
    end;
    if not Assigned(LFocused) then
    begin
      Trace(Format('focused row: %s "%s" has no FocusedNode in its RTTI',
        [LTree.ClassName, LTree.Name]));
      Exit;
    end;
    LValue := LFocused.GetValue(LTree);
    LNode := PPointer(LValue.GetReferenceToRawData)^;
    if LNode = nil then
    begin
      Trace(Format('focused row: nothing focused in %s', [LTree.Name]));
      Exit;
    end;
    AChain := [RowCandidates(LTree, LGetData, LNode)];
    if Assigned(LParent) then
    begin
      LUp := NodeParentOf(LTree, LParent, LNode);
      while LUp <> nil do
      begin
        LNode := LUp;
        AChain := AChain + [RowCandidates(LTree, LGetData, LNode)];
        LUp := NodeParentOf(LTree, LParent, LNode);
      end;
      ATopIndex := Integer(PCardinal(LNode)^);
    end
    else
      Trace('focused row: no NodeParent in the RTTI - the focused row only');
    if AdvancedLoggingEnabled then
      Trace(Format('focused row: %s, depth %d, top index %d, GetNodeData ' +
        '%s', [LTree.Name, Length(AChain) - 1, ATopIndex,
        IfThen(Assigned(LGetData), 'found', 'not in the RTTI')]));
    Result := True;
  except
    on E: Exception do
      Trace(Format('focused row: FAILED with %s: %s', [E.ClassName,
        E.Message]));
  end;
end;

// The tree's method AName taking a node first (any further parameters are
// Booleans, passed as False), or nil.
function NodeMethod(AType: TRttiType; const AName: string;
  AWithNode: Boolean): TRttiMethod;
begin
  Result := nil;
  for var LMethod in AType.GetMethods(AName) do
  begin
    var LParams := LMethod.GetParameters;
    var LOk := (Length(LParams) > 0) = AWithNode;
    for var LIdx := 0 to High(LParams) do
      if Assigned(LParams[LIdx].ParamType) and
         (((LIdx = 0) and AWithNode and
           (LParams[LIdx].ParamType.TypeKind <> tkPointer)) or
          (((LIdx > 0) or not AWithNode) and
           (LParams[LIdx].ParamType.Handle <> TypeInfo(Boolean)))) then
        LOk := False;
    if LOk then
      Exit(LMethod);
  end;
end;

function NodeArg(AParam: TRttiParameter; ANode: Pointer): TValue;
begin
  if Assigned(AParam.ParamType) then
    TValue.Make(@ANode, AParam.ParamType.Handle, Result)
  else
    TValue.Make(@ANode, TypeInfo(Pointer), Result);
end;

// Calls AMethod on ATree with ANode (when it takes one) and False for the
// rest; the pointer it answers, nil when it answers none.
function CallNodeMethod(AMethod: TRttiMethod; ATree: TObject;
  ANode: Pointer): Pointer;
var
  LArgs: TArray<TValue>;
  LParams: TArray<TRttiParameter>;
  LValue: TValue;
begin
  LParams := AMethod.GetParameters;
  SetLength(LArgs, Length(LParams));
  for var LIdx := 0 to High(LParams) do
    if (LIdx = 0) and (LParams[0].ParamType.TypeKind = tkPointer) then
      LArgs[0] := NodeArg(LParams[0], ANode)
    else
      LArgs[LIdx] := TValue.From<Boolean>(False);
  LValue := AMethod.Invoke(ATree, LArgs);
  Result := nil;
  if Assigned(AMethod.ReturnType) and
     (AMethod.ReturnType.TypeKind = tkPointer) then
    Result := PPointer(LValue.GetReferenceToRawData)^;
end;

function ResultSelectRow(ARow: Pointer): Boolean;
var
  LForm: TCustomForm;
  LTree: TControl;
  LCtx: TRttiContext;
  LType: TRttiType;
  LFocused: TRttiProperty;
  LSelected: TRttiIndexedProperty;
  LGetData, LFirst, LNext, LClear, LScroll: TRttiMethod;
  LNode, LFound: Pointer;
  LValue: TValue;
  LCount, LBest: Integer;
begin
  Result := False;
  if ARow = nil then
    Exit;
  try
    LForm := FindMessageForm;
    if not Assigned(LForm) then
      Exit;
    LTree := nil;
    for var LIdx := 0 to LForm.ControlCount - 1 do
      if LForm.Controls[LIdx].Visible and
         ContainsText(LForm.Controls[LIdx].ClassName, 'VirtualDrawTree') then
        LTree := LForm.Controls[LIdx];
    if not Assigned(LTree) then
    begin
      Trace('select row: no visible VirtualDrawTree in the Messages window');
      Exit;
    end;
    LCtx := TRttiContext.Create;
    LType := LCtx.GetType(LTree.ClassType);
    if not Assigned(LType) then
      Exit;
    LFocused := LType.GetProperty('FocusedNode');
    LSelected := LType.GetIndexedProperty('Selected');
    LGetData := nil;
    for var LMethod in LType.GetMethods('GetNodeData') do
      if (Length(LMethod.GetParameters) = 1) and
         Assigned(LMethod.ReturnType) and
         (LMethod.ReturnType.TypeKind = tkPointer) then
        LGetData := LMethod;
    LFirst := NodeMethod(LType, 'GetFirst', False);
    LNext := NodeMethod(LType, 'GetNext', True);
    LClear := NodeMethod(LType, 'ClearSelection', False);
    LScroll := NodeMethod(LType, 'ScrollIntoView', True);
    if not Assigned(LFocused) or not LFocused.IsWritable or
       not Assigned(LFirst) or not Assigned(LNext) then
    begin
      Trace(Format('select row: %s lacks FocusedNode/GetFirst/GetNext in ' +
        'its RTTI', [LTree.ClassName]));
      Exit;
    end;
    // Every node, children of collapsed rows too: GetNext walks them all.
    // The node whose candidates hold ARow EARLIEST wins: the words scanned
    // past a node's own block can be the next node's, data included - the
    // first match in walk order put the selection on the row BEFORE the one
    // meant (Alex, 2026-10-06).
    LFound := nil;
    LBest := MaxInt;
    LCount := 0;
    LNode := CallNodeMethod(LFirst, LTree, nil);
    while (LNode <> nil) and (LCount < 100000) do
    begin
      var LCandidates := RowCandidates(LTree, LGetData, LNode);
      for var LSlot := 0 to Min(High(LCandidates), LBest - 1) do
        if LCandidates[LSlot] = ARow then
        begin
          LFound := LNode;
          LBest := LSlot;
          Break;
        end;
      LNode := CallNodeMethod(LNext, LTree, LNode);
      Inc(LCount);
    end;
    if LFound = nil then
    begin
      Trace(Format('select row: the row is not among %d nodes', [LCount]));
      Exit;
    end;
    if Assigned(LClear) then
      CallNodeMethod(LClear, LTree, nil);
    TValue.Make(@LFound, LFocused.PropertyType.Handle, LValue);
    LFocused.SetValue(LTree, LValue);
    if Assigned(LSelected) and LSelected.IsWritable then
      LSelected.SetValue(LTree, [NodeArg(LSelected.ReadMethod.GetParameters[0],
        LFound)], TValue.From<Boolean>(True));
    if Assigned(LScroll) then
      CallNodeMethod(LScroll, LTree, LFound);
    Result := True;
  except
    on E: Exception do
      Trace(Format('select row: FAILED with %s: %s', [E.ClassName,
        E.Message]));
  end;
end;

procedure ShowRenameToolbar(const AGroupCaption: string;
  const AOnRevert: TProc);
begin
  GRenameCaption := AGroupCaption;
  ShowResultToolbar(AGroupCaption,
    [ResultToolButton('Revert', 'EditUndoCommand', AOnRevert)]);
end;

initialization

finalization
  if Assigned(GHosts) then
    for var LCaption in GHosts.Keys.ToArray do
      HideResultToolbar(LCaption);
  FreeAndNil(GHosts);

end.
