unit PasTreeIdePlugin.GroupScope;

(*
  WHICH PROJECTS OF THE GROUP a group-wide question goes to - the list the
  scope dialog and the Rename dialog both show, and the registry memory
  behind it.

  WHY THERE IS A CHOICE AT ALL. Until 0.50.x Find References, the Find All
  family and Rename asked EVERY project of the group, starting the cold
  servers on demand (LspSession, GroupTargets). On a large group that meant
  one pastree-server.exe per project, each holding a full closure, and the
  machine ran out of memory before the answer came back (Alex, 2026-09-22).
  So the user picks: a check list of the group's projects, the project
  owning the file under the caret always ticked and greyed - only its server
  can answer for the position at all - and every other project a tick that
  says "also ask this one, starting its server if it is cold".

  REMEMBERED PER GROUP, in the registry: HKCU\<settings key>\GroupScope, one
  string value per group named by the lower-cased .groupproj path, holding the
  ticked .dproj paths separated by '|'. Per group and not one global list
  because two groups sharing a project do not share a reason to search it.
  The ticked set is stored rather than the unticked one so that a project
  added to the group later starts UNTICKED - the default is "just the owner",
  since the whole point is not to start servers the user did not ask for.
  When the value is missing (first run) nothing is ticked.

  THE DIALOG IS SHOWN ONLY FOR A GROUP OF TWO OR MORE. A single project has
  nothing to choose; ChooseGroupScope answers True at once with an empty
  list and the caller proceeds exactly as before.

  "(running)" after a name marks a project whose server is already up: a
  free tick, as opposed to one that pays for a closure build. "(current)"
  marks the owner.

  The ROWS are shared by two forms - PasTreeIdePlugin.GroupScopeForm (the
  question on its own, for Find References and Find All) and
  PasTreeIdePlugin.RenameForm (the same list beneath the new-name edit, so a
  rename is one dialog, not two). FillList / ReadList are the two halves
  either form calls, so the caption format and the owner's greyed row are
  decided here once.
*)

interface

uses
  Vcl.CheckLst;

type
  TGroupScopeProject = record
    /// <summary>The .dproj - the pool's session key and what is stored.</summary>
    FileName: string;
    /// <summary>The owner of the file under the caret: always asked.</summary>
    IsOwner: Boolean;
    /// <summary>Its server is up - ticking it starts nothing.</summary>
    IsRunning: Boolean;
    Checked: Boolean;
  end;

  TGroupScopeProjects = TArray<TGroupScopeProject>;

/// <summary>
/// The projects of the current group with the remembered ticks applied and
/// AOwnerProjectFile marked as the owner (ticked). nil when there is no group
/// or the group has one project - the callers skip their dialog then.
/// </summary>
function GroupScopeProjects(const AOwnerProjectFile: string): TGroupScopeProjects;

/// <summary>Fills a check list from the rows: owner ticked and disabled.</summary>
procedure FillGroupScopeList(AList: TCheckListBox;
  const AProjects: TGroupScopeProjects);

/// <summary>
/// Reads the ticks back into AProjects (same order as filled), remembers
/// them for the group, and returns the ticked .dproj paths - the owner
/// included - in the form the Lsp*InGroup entry points take.
/// </summary>
function ReadGroupScopeList(AList: TCheckListBox;
  var AProjects: TGroupScopeProjects): TArray<string>;

/// <summary>
/// Selects the owner's row so it is in view, and nudges the themed scroll
/// bar into appearing. Call from the form's OnShow - the list needs its
/// window for either.
/// </summary>
procedure SelectGroupScopeOwner(AList: TCheckListBox);

/// <summary>Ticks or unticks every row but the owner's.</summary>
procedure SetGroupScopeListAll(AList: TCheckListBox; AChecked: Boolean);

/// <summary>
/// Gives the list a popup menu with Check All / Uncheck All. Owned by the
/// list, so it goes with the form.
/// </summary>
procedure AttachGroupScopeMenu(AList: TCheckListBox);

/// <summary>
/// The stand-alone question, for Find References and Find All: shows the
/// scope dialog when the group has more than one project - ACaption is the
/// command's name for its title, ASubject the identifier under the caret -
/// and returns True with the ticked .dproj paths in ASelected (empty for a
/// single project or no group - the owner alone). False when the user
/// cancelled.
/// </summary>
function ChooseGroupScope(const AOwnerProjectFile, ACaption, ASubject: string;
  out ASelected: TArray<string>): Boolean;

implementation

uses
  System.SysUtils, System.Classes, System.Win.Registry, Winapi.Windows,
  Winapi.Messages, Vcl.Menus,
  ToolsAPI,
  PasTreeIdePlugin.Settings, PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.GroupScopeForm;

const
  cSubKey = 'GroupScope';
  cSeparator = '|';

function GroupScopeRegistryKey: string;
begin
  Result := SettingsRegistryKey;
  if Result <> '' then
    Result := IncludeTrailingPathDelimiter(Result) + cSubKey;
end;

function CurrentGroup: IOTAProjectGroup;
var
  LModuleServices: IOTAModuleServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Result := LModuleServices.MainProjectGroup;
end;

{ The registry value name for a group. An unsaved group has no file name
  worth the name; it still gets one slot so the choice survives within the
  session at least. }
function GroupValueName(const AGroup: IOTAProjectGroup): string;
begin
  Result := LowerCase(AGroup.FileName);
  if Result = '' then
    Result := '(unsaved group)';
end;

function LoadTicked(const AGroup: IOTAProjectGroup): TArray<string>;
var
  LReg: TRegistry;
  LKey: string;
begin
  Result := nil;
  LKey := GroupScopeRegistryKey;
  if LKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKeyReadOnly(LKey) and
         LReg.ValueExists(GroupValueName(AGroup)) then
        Result := LReg.ReadString(GroupValueName(AGroup)).Split([cSeparator],
          TStringSplitOptions.ExcludeEmpty);
    except
      Result := nil;
    end;
  finally
    LReg.Free;
  end;
end;

procedure SaveTicked(const AGroup: IOTAProjectGroup;
  const ATicked: TArray<string>);
var
  LReg: TRegistry;
  LKey: string;
begin
  LKey := GroupScopeRegistryKey;
  if LKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKey(LKey, True) then
        LReg.WriteString(GroupValueName(AGroup),
          string.Join(cSeparator, ATicked));
    except
      // As for the settings themselves: a tick that does not survive a
      // restart is not worth an exception into the IDE.
    end;
  finally
    LReg.Free;
  end;
end;

function GroupScopeProjects(const AOwnerProjectFile: string): TGroupScopeProjects;
var
  LGroup: IOTAProjectGroup;
  LProject: IOTAProject;
  LTicked: TArray<string>;
  LRow: TGroupScopeProject;
  LIdx, LTick: Integer;
begin
  Result := nil;
  LGroup := CurrentGroup;
  if not Assigned(LGroup) or (LGroup.ProjectCount < 2) then
    Exit;
  LTicked := LoadTicked(LGroup);
  for LIdx := 0 to LGroup.ProjectCount - 1 do
  begin
    LProject := LGroup.Projects[LIdx];
    if not Assigned(LProject) or (LProject.FileName = '') then
      Continue;
    LRow := Default(TGroupScopeProject);
    LRow.FileName := LProject.FileName;
    LRow.IsOwner := SameText(LRow.FileName, AOwnerProjectFile);
    LRow.IsRunning := LspProjectServerRunning(LRow.FileName);
    LRow.Checked := LRow.IsOwner;
    if not LRow.IsOwner then
      for LTick := 0 to High(LTicked) do
        if SameText(LTicked[LTick], LRow.FileName) then
        begin
          LRow.Checked := True;
          Break;
        end;
    // In the group's own order (Alex, 2026-09-22: not owner-first); the
    // owner is scrolled into view by selecting it, see SelectGroupScopeOwner.
    Result := Result + [LRow];
  end;
end;

function RowCaption(const ARow: TGroupScopeProject): string;
begin
  Result := ChangeFileExt(ExtractFileName(ARow.FileName), '');
  if ARow.IsOwner then
    Result := Result + '  (current)'
  else if ARow.IsRunning then
    Result := Result + '  (running)';
end;

procedure FillGroupScopeList(AList: TCheckListBox;
  const AProjects: TGroupScopeProjects);
var
  LIdx: Integer;
begin
  AList.Items.BeginUpdate;
  try
    AList.Items.Clear;
    for LIdx := 0 to High(AProjects) do
    begin
      AList.Items.Add(RowCaption(AProjects[LIdx]));
      AList.Checked[LIdx] := AProjects[LIdx].Checked;
      // The owner cannot be unticked: the question is about its file.
      AList.ItemEnabled[LIdx] := not AProjects[LIdx].IsOwner;
    end;
  finally
    AList.Items.EndUpdate;
  end;
end;

procedure SelectGroupScopeOwner(AList: TCheckListBox);
var
  LIdx: Integer;
begin
  // The owner is the one disabled row.
  for LIdx := 0 to AList.Items.Count - 1 do
    if not AList.ItemEnabled[LIdx] then
    begin
      AList.ItemIndex := LIdx;   // scrolls it into view
      Break;
    end;
  // THE SCROLL BAR. Under the IDE's theme the list's bars are painted by
  // TScrollingStyleHook, which repaints them on WM_VSCROLL and the like -
  // and a list filled before its window existed showed no bar until a key
  // moved the selection (Alex, 2026-09-22, a group of nine). An end-scroll
  // notification with nothing to scroll is the cheapest such message.
  if AList.HandleAllocated then
    AList.Perform(WM_VSCROLL, SB_ENDSCROLL, 0);
end;

procedure SetGroupScopeListAll(AList: TCheckListBox; AChecked: Boolean);
var
  LIdx: Integer;
begin
  for LIdx := 0 to AList.Items.Count - 1 do
    if AList.ItemEnabled[LIdx] then
      AList.Checked[LIdx] := AChecked;
end;

type
  { The two menu handlers need an object to hang off; the menu owns it, the
    list owns the menu. }
  TGroupScopeMenu = class(TComponent)
  private
    FList: TCheckListBox;
    procedure CheckAll(ASender: TObject);
    procedure UncheckAll(ASender: TObject);
  end;

procedure TGroupScopeMenu.CheckAll(ASender: TObject);
begin
  SetGroupScopeListAll(FList, True);
end;

procedure TGroupScopeMenu.UncheckAll(ASender: TObject);
begin
  SetGroupScopeListAll(FList, False);
end;

procedure AttachGroupScopeMenu(AList: TCheckListBox);
var
  LMenu: TPopupMenu;
  LHandlers: TGroupScopeMenu;
  LItem: TMenuItem;
begin
  LMenu := TPopupMenu.Create(AList);
  LHandlers := TGroupScopeMenu.Create(LMenu);
  LHandlers.FList := AList;
  LItem := TMenuItem.Create(LMenu);
  LItem.Caption := 'Check All';
  LItem.OnClick := LHandlers.CheckAll;
  LMenu.Items.Add(LItem);
  LItem := TMenuItem.Create(LMenu);
  LItem.Caption := 'Uncheck All';
  LItem.OnClick := LHandlers.UncheckAll;
  LMenu.Items.Add(LItem);
  AList.PopupMenu := LMenu;
end;

function ReadGroupScopeList(AList: TCheckListBox;
  var AProjects: TGroupScopeProjects): TArray<string>;
var
  LIdx: Integer;
  LTicked: TArray<string>;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  LTicked := nil;
  for LIdx := 0 to High(AProjects) do
  begin
    if LIdx < AList.Items.Count then
      AProjects[LIdx].Checked := AProjects[LIdx].IsOwner or AList.Checked[LIdx];
    if AProjects[LIdx].Checked then
    begin
      Result := Result + [AProjects[LIdx].FileName];
      // The owner is not stored: it is whichever project holds the NEXT
      // caret, and storing it would tick it as an extra next time.
      if not AProjects[LIdx].IsOwner then
        LTicked := LTicked + [AProjects[LIdx].FileName];
    end;
  end;
  LGroup := CurrentGroup;
  if Assigned(LGroup) then
    SaveTicked(LGroup, LTicked);
end;

function ChooseGroupScope(const AOwnerProjectFile, ACaption, ASubject: string;
  out ASelected: TArray<string>): Boolean;
var
  LProjects: TGroupScopeProjects;
begin
  ASelected := nil;
  LProjects := GroupScopeProjects(AOwnerProjectFile);
  if LProjects = nil then
    Exit(True);   // no group, or a group of one: nothing to ask
  Result := ExecuteGroupScopeDialog(LProjects, ACaption, ASubject, ASelected);
end;

end.
