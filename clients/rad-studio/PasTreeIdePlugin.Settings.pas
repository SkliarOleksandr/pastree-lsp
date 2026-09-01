unit PasTreeIdePlugin.Settings;

{
  The user-visible settings: a store in the registry, and the Tools > PasTree >
  Settings menu item that opens the dialog over it (the dialog itself is
  PasTreeIdePlugin.SettingsForm, which owns a .dfm so it can be laid out in the
  Form Designer).

  WHERE THEY LIVE. HKCU\<IOTAServices.GetBaseRegistryKey>\PasTree - the same
  per-installation root the IDE keeps its own settings under, read the same way
  GetIDELibraryPaths already reads the library paths. That is what makes two
  side-by-side RAD Studio versions two independent sets of settings, which is
  the behaviour anyone with two installations expects; a key of our own under
  HKCU would have quietly shared one set between them.

  DEFAULT IS ON, FOR EVERY SWITCH THAT TURNS SOMETHING OFF. Those switches
  disable something this plugin already does, so a missing value - a fresh
  installation, a user who never opened the dialog - must read as "behave as
  before". "Advanced logging" is the one exception and the rule is the same
  one seen from the other side: it turns a diagnostic ON, and its default is
  therefore OFF. Written only by the dialog: nothing else in the package
  writes to the registry.

  READ AT THE POINT OF USE, NOT CACHED AT STARTUP. Every switch is read on
  each gesture (an editor tab activating, a key being pressed), which is what
  makes a change in the dialog take effect on the next keystroke rather than at
  the next IDE start. The cost is a registry read per gesture, which is far
  below the LSP round-trip it gates - and GSettings caches the values anyway,
  so the read only happens once until the dialog writes.
}

interface

/// <summary>
/// Whether we replace the IDE's Structure pane content for Pascal sources
/// (PasTreeIdePlugin.Outline). False leaves the pane to the IDE's own
/// provider - our outline simply stops pushing, which is all it takes.
///
/// WITHDRAWN, TEMPORARILY, ON 2026-09-01: this always answers False and the
/// dialog no longer shows the checkbox. The outline is not finished, and a
/// half-finished pane is worse than the IDE's own - it looks like the
/// feature, so what it gets wrong reads as what PasTree gets wrong.
///
/// The stored value, the record field and the registry name are all left
/// alone deliberately: withdrawing a feature must not throw away the choice
/// of anyone who had it on, so switching it back on is deleting the two
/// lines below and putting the checkbox back in the .dfm - not recovering a
/// setting nobody wrote down.
/// </summary>
function OverrideStructureView: Boolean;

/// <summary>
/// Whether "Find Declaration" is OURS - both the Ctrl+Click gesture
/// (PasTreeIdePlugin.GotoDeclaration's mouse override) and the editor menu
/// item (the cEdMenuCatIdentifier takeover in PasTreeIdePlugin.Wizard).
///
/// Independent of the Insight Provider selection, and it has to be: the
/// override exists precisely for the people who cannot select PasTree there,
/// because RAD Studio gates part of the Code Insight UI on DelphiLSP being
/// the provider. When PasTree IS the selected provider the CLICK override
/// stands down on its own regardless of this switch - the IDE's own click
/// chain already resolves through us.
///
/// THE ONE SWITCH WHOSE TWO HALVES ANSWER AT DIFFERENT TIMES. The click is
/// asked per click, so turning it off takes effect immediately. The menu
/// takeover is asked once, at package load, because it cannot be undone
/// within a session - unregistering the native action list is a one-way
/// door. Turned off mid-session, our menu item hides and the slot stays
/// empty until the IDE restarts; the dialog's hint says so.
/// </summary>
function CtrlClickNavigation: Boolean;

/// <summary>
/// Whether Ctrl+Shift+Up/Down runs OUR declaration/implementation jump. False
/// hands the keystroke back to the IDE, which then runs its own - see
/// TToggleKeyBinding.ToggleProc, where that fallback is the whole mechanism.
/// </summary>
function OverrideDeclImplToggle: Boolean;

/// <summary>
/// Whether Ctrl+Shift+E and the editor menu's "Rename..." are ours. False
/// hands the keystroke back to the IDE and hides the menu item - the same
/// off switch shape as the toggle above, and for the same reason: a feature
/// that EDITS the user's code has to be refusable outright.
/// </summary>
function RenameEnabled: Boolean;

/// <summary>
/// Whether Ctrl+Shift+C is ours - class completion AND the prototype sync
/// that now runs in front of it (PasTreeIdePlugin.SyncPrototypes), which is
/// one keystroke and therefore one switch. False hands the keystroke back to
/// the IDE, which then runs its own class completion: the same off-switch
/// shape as the decl/impl toggle, and for the same reason - what is being
/// switched off is a REPLACEMENT of a native command, so off has to mean
/// "the native one".
/// </summary>
function ClassCompleteEnabled: Boolean;

/// <summary>
/// Whether Enter after an unclosed block opener inserts the closer (block
/// completion - PasTreeIdePlugin.BlockClose). False stops the plugin from
/// even asking the server, and Enter is never swallowed either way.
/// </summary>
function BlockCompletionEnabled: Boolean;

/// <summary>
/// Whether the server writes pastree-lsp.log beside the project at all.
/// False sends no logFile to the server, which is what "no log" means on its
/// side - nothing is written rather than written and discarded, so a
/// read-only source tree stays untouched. The IDE-side crash record
/// (PasTreeIdePlugin.CrashLog) is a different file and is NOT gated: a fault
/// nobody recorded is the one thing worse than a log nobody reads.
/// </summary>
function LoggingEnabled: Boolean;

/// <summary>
/// Whether that log carries the configuration inventory - every search path,
/// define, namespace and unit alias the analysis was handed. Meaningful only
/// while LoggingEnabled; the dialog greys it out otherwise.
///
/// OFF BY DEFAULT, unlike every other switch here, and deliberately: this one
/// does not turn a FEATURE off, it turns a diagnostic on. The inventory is
/// hundreds of lines per configuration on a real project and it answers one
/// question - "which directories did it actually search?" - which is a
/// question you go looking for rather than one you want answered every time.
/// The one-line summary (`configured: platform=... paths=N defines=N`) is
/// logged either way, so the counts never disappear.
/// </summary>
function AdvancedLoggingEnabled: Boolean;

/// <summary>Registers Tools > PasTree > Settings.</summary>
procedure InitializeSettings;

/// <summary>
/// Removes the menu item before the BPL unloads - a menu item whose OnClick
/// points into unloaded code is the same immediate crash every other
/// registration in this package is unregistered to avoid.
/// </summary>
procedure FinalizeSettings;

/// <summary>
/// Opens the modal settings dialog. Public because the menu item is not the
/// only plausible way in - a "configure" affordance elsewhere would use this
/// rather than reaching into the form unit.
/// </summary>
procedure ShowSettingsDialog;

/// <summary>
/// The current values, and the write the dialog performs on OK. A record
/// rather than two out-parameters so adding a third switch is one field and
/// its default, not a new signature everywhere.
/// </summary>
type
  TPasTreeSettings = record
    OverrideStructureView: Boolean;
    CtrlClickNavigation: Boolean;
    OverrideDeclImplToggle: Boolean;
    EnableRename: Boolean;
    EnableBlockCompletion: Boolean;
    EnableClassComplete: Boolean;
    EnableLogging: Boolean;
    AdvancedLogging: Boolean;
  end;

function LoadSettings: TPasTreeSettings;
procedure SaveSettings(const ASettings: TPasTreeSettings);

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Win.Registry,
  Winapi.Windows,
  Vcl.Menus,
  ToolsAPI,
  // Implementation-section only, and it uses this unit back the same way -
  // a cycle Delphi permits precisely here. The split is deliberate: the
  // store must be readable (OverrideStructureView, from Outline and the key
  // binding) without dragging a form and its .dfm into the caller.
  PasTreeIdePlugin.SettingsForm;

const
  cSettingsKey = 'PasTree';
  cValueStructureView = 'OverrideStructureView';
  cValueCtrlClick = 'CtrlClickNavigation';
  cValueDeclImplToggle = 'OverrideDeclImplToggle';
  cValueRename = 'EnableRename';
  cValueBlockCompletion = 'EnableBlockCompletion';
  cValueClassComplete = 'EnableClassComplete';
  cValueLogging = 'EnableLogging';
  cValueAdvancedLogging = 'AdvancedLogging';

var
  // The in-memory copy. Loaded on first read, replaced on every save, so a
  // gesture never pays for a registry round trip and never reads a stale
  // value either.
  GSettings: TPasTreeSettings;
  GLoaded: Boolean = False;
  // The two menu items we own: the "PasTree" submenu parent and its one
  // child. Held so FinalizeSettings can take them back out of the IDE's menu
  // - freeing the parent frees the child with it.
  GRootItem: TMenuItem = nil;

type
  // The OnClick target has to live on an object, and a TComponent one is
  // freed with the menu item that references it. A plain class with a class
  // procedure would do as well; this keeps the handler next to nothing else.
  TMenuHandler = class
    procedure SettingsClick(ASender: TObject);
    procedure ToolsMenuClick(ASender: TObject);
  end;

var
  GHandler: TMenuHandler = nil;
  { The Tools menu itself, and whatever OnClick it already had.

    HOOKED SO THE REPAIR RUNS WHEN IT MATTERS. The child of our submenu is
    wiped some time during IDE startup - the probe caught children going 1
    -> 0 between package load and the first project opening - and repairing
    it on a timer would only be a guess about when that happens. The moment
    the answer is actually needed is the moment the user drops the Tools
    menu down, so that is where the check goes: OnClick on a top-level menu
    item fires as it opens.

    CHAINED, never replaced: the IDE's own handler is kept and called after
    ours, and FinalizeSettings puts it back. Dropping it would silently
    break whatever the IDE does there. }
  GToolsMenu: TMenuItem = nil;
  GPrevToolsClick: TNotifyEvent = nil;

{ The Build tab, tagged like every other line this package puts there - see
  PasTreeIdePlugin.LspSession's LogDiagnostic for the convention. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function SettingsRegistryKey: string;
var
  LServices: IOTAServices;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  Result := IncludeTrailingPathDelimiter(LServices.GetBaseRegistryKey)
    + cSettingsKey;
end;

function LoadSettings: TPasTreeSettings;
var
  LReg: TRegistry;
  LKey: string;

  // A value that is absent, or holds something that is not a number, reads
  // as the default. Both are the same case in practice - a key written by an
  // older version, a hand-edited value - and both mean "we were not told
  // otherwise", which is exactly the default.
  function ReadFlag(ALReg: TRegistry; const AName: string;
    ADefault: Boolean): Boolean;
  begin
    Result := ADefault;
    if not ALReg.ValueExists(AName) then
      Exit;
    try
      Result := ALReg.ReadInteger(AName) <> 0;
    except
      Result := ADefault;
    end;
  end;

begin
  // DEFAULTS FIRST, so every early exit below lands on them.
  Result.OverrideStructureView := True;
  Result.CtrlClickNavigation := True;
  Result.OverrideDeclImplToggle := True;
  Result.EnableRename := True;
  Result.EnableBlockCompletion := True;
  Result.EnableClassComplete := True;
  Result.EnableLogging := True;
  // See AdvancedLoggingEnabled: the one default that is False.
  Result.AdvancedLogging := False;

  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;

  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if not LReg.OpenKeyReadOnly(LKey) then
      Exit;   // never saved - the defaults stand
    try
      Result.OverrideStructureView :=
        ReadFlag(LReg, cValueStructureView, Result.OverrideStructureView);
      Result.CtrlClickNavigation :=
        ReadFlag(LReg, cValueCtrlClick, Result.CtrlClickNavigation);
      Result.OverrideDeclImplToggle :=
        ReadFlag(LReg, cValueDeclImplToggle, Result.OverrideDeclImplToggle);
      Result.EnableRename :=
        ReadFlag(LReg, cValueRename, Result.EnableRename);
      Result.EnableBlockCompletion :=
        ReadFlag(LReg, cValueBlockCompletion, Result.EnableBlockCompletion);
      Result.EnableClassComplete :=
        ReadFlag(LReg, cValueClassComplete, Result.EnableClassComplete);
      Result.EnableLogging :=
        ReadFlag(LReg, cValueLogging, Result.EnableLogging);
      Result.AdvancedLogging :=
        ReadFlag(LReg, cValueAdvancedLogging, Result.AdvancedLogging);
    finally
      LReg.CloseKey;
    end;
  finally
    LReg.Free;
  end;
end;

procedure SaveSettings(const ASettings: TPasTreeSettings);
var
  LReg: TRegistry;
  LKey: string;
begin
  // The cache is updated FIRST and unconditionally: a registry that cannot be
  // written (a locked-down machine, a policy) must still leave the dialog's
  // choice in effect for this session rather than silently reverting it.
  GSettings := ASettings;
  GLoaded := True;

  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;

  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if not LReg.OpenKey(LKey, True) then
        Exit;
      try
        LReg.WriteInteger(cValueStructureView,
          Ord(ASettings.OverrideStructureView));
        LReg.WriteInteger(cValueCtrlClick, Ord(ASettings.CtrlClickNavigation));
        LReg.WriteInteger(cValueDeclImplToggle,
          Ord(ASettings.OverrideDeclImplToggle));
        LReg.WriteInteger(cValueRename, Ord(ASettings.EnableRename));
        LReg.WriteInteger(cValueBlockCompletion,
          Ord(ASettings.EnableBlockCompletion));
        LReg.WriteInteger(cValueClassComplete,
          Ord(ASettings.EnableClassComplete));
        LReg.WriteInteger(cValueLogging, Ord(ASettings.EnableLogging));
        LReg.WriteInteger(cValueAdvancedLogging,
          Ord(ASettings.AdvancedLogging));
      finally
        LReg.CloseKey;
      end;
    except
      // A settings write is never worth an exception into the IDE: the choice
      // is already live (above), and the only thing lost is that it does not
      // survive a restart.
    end;
  finally
    LReg.Free;
  end;
end;

function CurrentSettings: TPasTreeSettings;
begin
  if not GLoaded then
  begin
    GSettings := LoadSettings;
    GLoaded := True;
  end;
  Result := GSettings;
end;

function OverrideStructureView: Boolean;
begin
  // WITHDRAWN - see the declaration. To bring the feature back, this becomes
  //   Result := CurrentSettings.OverrideStructureView;
  // again; CurrentSettings still holds the user's real choice throughout.
  Result := False;
end;

function CtrlClickNavigation: Boolean;
begin
  Result := CurrentSettings.CtrlClickNavigation;
end;

function OverrideDeclImplToggle: Boolean;
begin
  Result := CurrentSettings.OverrideDeclImplToggle;
end;

function RenameEnabled: Boolean;
begin
  Result := CurrentSettings.EnableRename;
end;

function BlockCompletionEnabled: Boolean;
begin
  Result := CurrentSettings.EnableBlockCompletion;
end;

function ClassCompleteEnabled: Boolean;
begin
  Result := CurrentSettings.EnableClassComplete;
end;

function LoggingEnabled: Boolean;
begin
  Result := CurrentSettings.EnableLogging;
end;

function AdvancedLoggingEnabled: Boolean;
begin
  // The dependency is enforced HERE as well as in the dialog: the stored pair
  // can legally be (logging off, advanced on) - the dialog leaves the value
  // it was given alone when it greys the box out - and a caller asking "should
  // I log the inventory?" must get False for that, not the stale tick.
  Result := CurrentSettings.EnableLogging and CurrentSettings.AdvancedLogging;
end;

procedure ShowSettingsDialog;
begin
  ExecuteSettingsDialog;
end;

{ TMenuHandler }

procedure TMenuHandler.SettingsClick(ASender: TObject);
begin
  ShowSettingsDialog;
end;

{ The Tools menu is opening. Make sure our item is there and populated
  BEFORE it paints, then let the IDE's own handler run.

  InitializeSettings is idempotent and self-repairing, so the ordinary case
  costs one liveness check and nothing else. }
procedure TMenuHandler.ToolsMenuClick(ASender: TObject);
begin
  try
    InitializeSettings;
  except
    // A menu that is being opened is the worst possible place to raise: the
    // repair is best-effort, the IDE's handler below is not.
  end;
  if Assigned(GPrevToolsClick) then
    GPrevToolsClick(ASender);
end;

{ ---------------------------------------------------------------------------
  The Tools menu item
  --------------------------------------------------------------------------- }

{ INTAServices.AddActionMenu, NOT MainMenu.Items[...].Add.

  THIS WAS THE BUG, and it was invisible in exactly the way that made it
  expensive: walking MainMenu.Items for the Tools item and calling .Add on it
  DOES parent the item - GRootItem.Parent came back assigned, so the
  idempotence check below was satisfied and every retry exited quietly - and
  the item still never appeared in the menu. Nothing failed, nothing logged,
  and there was nothing to read.

  The IDE keeps its own bookkeeping over the main menu (that is what
  MenuBeginUpdate/MenuEndUpdate on this same interface exist for), and a
  TMenuItem grafted straight onto the VCL tree is not in it. AddActionMenu is
  the documented way in, and it is positional rather than parental:

    Name          an EXISTING menu item's COMPONENT NAME to position against
                  ('ToolsMenu'), and it RAISES if that name is not found -
                  which is why the try/except below is load-bearing, not
                  decoration.
    NewAction     nil: this item has an OnClick, not an action.
    InsertAfter,  together: make it the LAST CHILD of ToolsMenu - the
    InsertAsChild bottom of the Tools menu, which is where it was asked for.

  See https://docwiki.embarcadero.com/RADStudio/Sydney/en/
  Adding_an_Item_to_the_Main_Menu_of_the_IDE and ToolsAPI.pas's own comment
  on INTAServices90.AddActionMenu. }

const
  // The IDE's Tools menu, by component name. Not localised (the CAPTION is),
  // which is the entire reason the API addresses menus this way.
  cToolsMenuName = 'ToolsMenu';
  // Our own two items' component names - REQUIRED, not decoration: the child
  // is anchored to the parent by name, and AddActionMenu has no other way to
  // address it.
  cRootItemName = 'PasTreeToolsMenuItem';
  cSettingsItemName = 'PasTreeToolsSettingsItem';

{ Is AItem reachable from the menu the IDE is showing RIGHT NOW?

  ASKING ABOUT Parent IS NOT ENOUGH. A parented item is not necessarily one
  on the live tree: if the IDE replaces its main menu, an item added to the
  old one keeps a Parent pointing into the discarded tree, so an
  Assigned(Parent) gate would report success over a menu nobody can open.
  Walking up to the root and comparing it with the CURRENT MainMenu.Items is
  the question a stale pointer cannot answer wrongly.

  NECESSARY BUT NOT SUFFICIENT - see the caller, which also requires the
  submenu to still have children. That second half is the one that actually
  mattered here: the item stayed on the live tree throughout and was emptied
  instead. }
function MenuItemIsLive(AItem: TMenuItem): Boolean;
var
  LServices: INTAServices;
  LMenu: TMainMenu;
  LRoot: TMenuItem;
begin
  Result := False;
  if not Assigned(AItem) then
    Exit;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LMenu := LServices.MainMenu;
  if not Assigned(LMenu) then
    Exit;
  LRoot := AItem;
  while Assigned(LRoot.Parent) do
    LRoot := LRoot.Parent;
  Result := LRoot = LMenu.Items;
end;

procedure InitializeSettings;
var
  LServices: INTAServices;
  LSettings: TMenuItem;
begin
  LSettings := nil;   // the except block below reads it
  if Assigned(GRootItem) then
  begin
    { LIVE AND STILL POPULATED. The second half is not pedantry: the submenu
      loses its only child during IDE startup, and a childless submenu
      renders as nothing - so "in the tree" alone was the check that kept
      reporting success over an invisible menu. }
    if MenuItemIsLive(GRootItem) and (GRootItem.Count > 0) then
      Exit;
    // On a tree the IDE threw away. Drop ours and build it again against the
    // live menu - this is the repair the Parent check could never make.
    FreeAndNil(GRootItem);
    { GHandler DELIBERATELY SURVIVES: the Tools-menu OnClick hook below holds
      a method pointer into it, and freeing it here would leave that hook
      dangling - a crash the next time the menu is opened. It is stateless
      and process-lifetime; only FinalizeSettings frees it, after unhooking. }
  end;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
  begin
    LogDiagnostic('no INTAServices - Tools > PasTree > Settings not added.');
    Exit;
  end;

  { MAY NOT THROW PAST HERE. InitializeSettings runs inside TIDEWizard.Create,
    and an exception out of that fails RegisterPackageWizard - which would
    take the ENTIRE plugin down (no analysis, no navigation, no outline)
    because a menu item could not be placed. A settings shortcut is never
    worth that trade. AddActionMenu raising on an unknown menu name is a real
    possibility rather than a theoretical one, so this catch is the mechanism
    by which a renamed IDE menu costs a log line instead of the product. }
  try
    if not Assigned(GHandler) then
      GHandler := TMenuHandler.Create;

    // Owned by nothing: AddActionMenu takes them into the IDE's menu, and
    // FinalizeSettings frees the root before the BPL unloads - which takes
    // the child with it, since TMenuItem.Destroy frees its own items.
    { BOTH LEVELS GO IN THROUGH AddActionMenu, AND BOTH ARE NAMED.

      Measured, 2026-08-29: a hand-Add-ed child survived the call and was
      GONE by the time the IDE had finished starting, leaving a childless
      'PasTree' submenu, which renders as nothing. Every sibling under Tools
      is named - ToolsOptionsItem, GetItMenuItem, CustomToolsItem - and ours
      was the only one with an empty Name, i.e. the only one the IDE had no
      record of. So the child goes in the same way the parent does, anchored
      to the parent BY NAME, which is the only thing AddActionMenu can
      anchor to.

      The names are therefore REQUIRED now, where an earlier version dropped
      them as pointless. They can collide after a package reload that left
      the old items registered - that is what the try/except around this
      block is for, and FinalizeSettings frees both so the ordinary path
      never gets there. }
    GRootItem := TMenuItem.Create(nil);
    GRootItem.Name := cRootItemName;
    GRootItem.Caption := 'PasTree';
    // InsertAsChild + InsertAfter = the last child of Tools, as asked for.
    LServices.AddActionMenu(cToolsMenuName, nil, GRootItem, True, True);

    LSettings := TMenuItem.Create(nil);
    LSettings.Name := cSettingsItemName;
    LSettings.Caption := 'Settings...';
    LSettings.OnClick := GHandler.SettingsClick;
    // Anchored to OUR root, as its only child.
    LServices.AddActionMenu(cRootItemName, nil, LSettings, True, True);
    { Hook the Tools menu ONCE, now that we know which item it is. From here
      on the repair runs whenever the menu is opened, so the item is correct
      before the user ever opens a project - which is when the wipe used to
      leave it empty and unreachable. }
    { RE-RESOLVED, NOT SET ONCE. The guard used to be `if not
      Assigned(GToolsMenu)`, which is exactly wrong on the path this unit
      exists to handle: after the IDE rebuilds its main menu, the repair above
      adds our items to the NEW tree while GToolsMenu still points at the item
      of the OLD one. Both consequences are real - the hook sits on a discarded
      item and never fires again, so the self-repair it exists for is dead from
      that moment; and FinalizeSettings writes OnClick into that item at
      unload, which is a write to freed memory if the IDE has released the old
      tree. So the hook moves to whatever the live parent is, handing the old
      item its own handler back first if it is still alive. }
    if Assigned(GRootItem.Parent) and (GRootItem.Parent <> GToolsMenu) then
    begin
      if Assigned(GToolsMenu) and MenuItemIsLive(GToolsMenu) then
        GToolsMenu.OnClick := GPrevToolsClick;
      GToolsMenu := GRootItem.Parent;
      GPrevToolsClick := GToolsMenu.OnClick;
      GToolsMenu.OnClick := GHandler.ToolsMenuClick;
    end;
  except
    on E: Exception do
    begin
      // LSettings is owned by nothing until AddActionMenu parents it, so a
      // throw from that call - the name collision the comment above predicts
      // after a package reload - leaks it. Only while UNparented: once it is
      // in the tree, freeing GRootItem below takes it, and freeing it here as
      // well would be the double free.
      if Assigned(LSettings) and not Assigned(LSettings.Parent) then
        FreeAndNil(LSettings);
      FreeAndNil(GRootItem);   // GHandler survives - see the rebuild path
      LogDiagnostic(Format('could not add Tools > PasTree > Settings '
        + '(anchor menu "%s"): %s: %s',
        [cToolsMenuName, E.ClassName, E.Message]));
    end;
  end;
end;

procedure FinalizeSettings;
begin
  { UNHOOK FIRST. The IDE keeps its menu; an OnClick pointing into a BPL that
    has unloaded is an immediate crash the next time Tools is opened, and
    that is the one handler here the IDE will definitely call again. }
  if Assigned(GToolsMenu) then
  begin
    // Only if the item is still in the live tree: the hook is re-resolved on
    // every menu rebuild (see InitializeSettings), so this pointer is normally
    // current - but a rebuild that happened with no repair pass since would
    // make this a write into a menu the IDE has released.
    if MenuItemIsLive(GToolsMenu) then
      GToolsMenu.OnClick := GPrevToolsClick;
    GToolsMenu := nil;
    GPrevToolsClick := nil;
  end;
  // Freeing the item unparents it from the Tools menu and takes its children
  // with it - which is the whole point here: an OnClick pointing into a BPL
  // that has unloaded is an immediate crash the next time the menu opens.
  FreeAndNil(GRootItem);
  FreeAndNil(GHandler);
end;

end.
