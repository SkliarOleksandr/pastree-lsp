unit PasTreeIdePlugin.Wizard;

{
  Adds "Find Type Declaration" and "Find References" to the editor's
  right-click menu under OUR OWN category, binds the Ctrl+Shift+Up/Down
  decl<->impl toggle, prewarms the analysis at project open, and registers
  the Code Insight manager (PasTreeIdePlugin.CodeInsight).

  PHASE C (2026-08-22, COMPLETION.md): this unit used to REPLACE the native
  "Find Declaration" menu item (UnregisterActionList on
  cEdMenuCatIdentifier, a one-way door within a session) and pair it with a
  Ctrl+Click mouse override. BOTH ARE BACK as of 2026-09-01, and for one
  reason: phase C priced declaration navigation at the whole Insight Provider
  slot, and RAD Studio gates part of the editor UI on DelphiLSP being the
  selected provider - so not everyone can pay it, and for those users phase C
  left Ctrl+Click and the menu item on the native navigation this plugin
  exists to replace. The reasoning is written out once, in
  PasTreeIdePlugin.GotoDeclaration's header.

  The two halves are NOT symmetric, and the difference is worth knowing
  before touching either:

    - Ctrl+CLICK is a mouse hook, decided per click. It stands down when
      PasTree IS the selected provider (the IDE's own chain already resolves
      through us), and it costs nothing to switch off.
    - The MENU item is a category takeover (UnregisterActionList on
      cEdMenuCatIdentifier, then our list under that same category string) -
      a one-way door within a session, because the native list cannot be put
      back. So it happens at load, only if the override is switched on. See
      the long comment in TMenuManager.Create.

  Our other three items - "Find Type Declaration", "Find References" and
  "Rename..." - replace nothing and live under cMenuCategory, registered
  alongside the native ones and unregistered cleanly at unload.

  Modelled on the official samples shipped with RAD Studio:
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Local Menu Demo
    Samples\Object Pascal\ToolsAPI\Editor Demos\Editor Raw Read Demo
}

interface

procedure Register;

implementation

uses
  System.SysUtils, System.Classes, Winapi.Windows, Vcl.ActnList, Vcl.Dialogs,
  Vcl.Forms, Vcl.Menus, ToolsAPI, ToolsAPI.UI,
  PasTreeIdePlugin.FindReferences, PasTreeIdePlugin.GotoDeclaration,
  PasTreeIdePlugin.CodeInsight, PasTreeIdePlugin.IdeInsight,
  PasTreeIdePlugin.ErrorPaint, PasTreeIdePlugin.IdleSync,
  PasTreeIdePlugin.Outline,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.ClassComplete,
  PasTreeIdePlugin.SyncPrototypes,
  PasTreeIdePlugin.BlockClose,
  PasTreeIdePlugin.Rename,
  PasTreeIdePlugin.CrashLog,
  PasTreeIdePlugin.LspSession;

const
  cMenuCategory = 'PasTreeIdePluginMenuCategory';

type
  TMenuManager = class
  private
    FActionList: TActionList;
    { The SECOND action list, registered under the IDE's own 'Identifier'
      category in place of the native one - see TMenuManager.Create. Separate
      from FActionList because the two lists live under different categories
      and are registered and unregistered independently. }
    FIdentifierActionList: TActionList;
    FEditorServices: IOTAEditorServices;
    FRegistered: Boolean;
    FIdentifierRegistered: Boolean;
    procedure AddActions;
    procedure AddIdentifierActions;
    procedure OnFindDeclarationExecute(Sender: TObject);
    procedure OnFindDeclarationUpdate(Sender: TObject);
    procedure OnFindReferencesExecute(Sender: TObject);
    procedure OnFindReferencesUpdate(Sender: TObject);
    procedure OnRenameExecute(Sender: TObject);
    procedure OnRenameUpdate(Sender: TObject);
    procedure OnFindTypeDeclarationExecute(Sender: TObject);
    procedure OnFindTypeDeclarationUpdate(Sender: TObject);
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { Starts the analysis when a project finishes opening, instead of leaving the
    user's first Ctrl+Click to pay for it (~15 s on a 3757-unit project). Two
    notifications, because they are different events and only one of them fires
    for the case you care about most:

      ofnEndProjectGroupOpen  - a project group finished loading. This is the
                                one that covers "the IDE just started with my
                                project", and it fires AFTER the group is
                                usable, so the active project is resolvable.
      ofnActiveProjectChanged - switching the active project inside an open
                                group. The server is per-configuration, so this
                                is exactly the point at which it must restart -
                                which EnsureSession already handles.

    NOT gated on the IDE being otherwise idle, deliberately: measured, the
    analysis is 8 cores for ~15 s, and whether that competes noticeably with
    the IDE's own project-open work is a question about real projects on real
    machines rather than about this code. IOTACompileNotifier
    (IsBackgroundCompileActive) is the knob to reach for if it turns out to. }
  TProjectOpenNotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(ANotifyCode: TOTAFileNotification;
      const AFileName: string; var ACancel: Boolean);
    procedure BeforeCompile(const AProject: IOTAProject; var ACancel: Boolean);
    procedure AfterCompile(ASucceeded: Boolean);
  end;

  { Ctrl+Shift+Up / Ctrl+Shift+Down - RAD Studio's own keys for the decl<->impl
    jump, routed through our LSP instead, for the same reason the native "Find
    Declaration" menu item was replaced: on a large project the IDE's version is
    the thing people complain about.

    btPartial, NOT btComplete: a partial binding layers over whatever keymap the
    user has instead of replacing it, so nothing else in their bindings moves,
    and the IDE lists it on Tools > Options > Editor > Key Mappings where it can
    be reordered or switched off. btComplete would mean "this IS the keymap",
    which is emphatically not what a two-key feature should claim.

    One KeyProc for both keys, dispatching on the shortcut it was handed: the
    two directions differ by a single Boolean, and a second near-identical
    handler is a second place to forget something. }
  TToggleKeyBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure ToggleProc(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
      var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

  TIDEWizard = class(TNotifierObject, IOTAWizard)
  private
    FMenuManager: TMenuManager;
    FServices: IOTAServices;
    FNotifierIndex: Integer;
    FKeyboardServices: IOTAKeyboardServices;
    FKeyBindingIndex: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function GetIDString: string;
    procedure Execute;
    function GetName: string;
    function GetState: TWizardState;
  end;

procedure Register;
begin
  RegisterPackageWizard(TIDEWizard.Create);
end;

{ TMenuManager }

procedure TMenuManager.AddActions;
var
  LAction: TAction;
begin
  LAction := TAction.Create(FActionList);
  LAction.Name := 'PasTreeFindTypeDeclaration';
  LAction.Caption := 'Find Type Declaration';
  LAction.Category := 'PasTreeFindTypeDeclaration';
  LAction.OnUpdate := OnFindTypeDeclarationUpdate;
  LAction.OnExecute := OnFindTypeDeclarationExecute;
  LAction.Enabled := True;
  LAction.ActionList := FActionList;

  LAction := TAction.Create(FActionList);
  LAction.Name := 'PasTreeFindReferences';
  LAction.Caption := 'Find References';
  LAction.Category := 'PasTreeFindReferences';
  LAction.OnUpdate := OnFindReferencesUpdate;
  LAction.OnExecute := OnFindReferencesExecute;
  LAction.Enabled := True;
  LAction.ActionList := FActionList;

  // Also on Ctrl+Shift+E (PasTreeIdePlugin.Rename registers the binding).
  // The menu item is what makes the feature discoverable at all - a rename
  // nobody knows is there is a rename nobody uses.
  LAction := TAction.Create(FActionList);
  LAction.Name := 'PasTreeRename';
  LAction.Caption := 'Rename...';
  LAction.Category := 'PasTreeRename';
  { A LABEL, NOT A BINDING - and the distinction matters if this ever stops
    working. The IDE draws TAction.ShortCut in the menu's own right-hand
    column, which is the only reason it is set: this action list has no form
    and no owner, so VCL's shortcut dispatch never sees it and the key is
    still delivered by TPasRenameBinding (PasTreeIdePlugin.Rename). Keep the
    two spellings in step - a menu promising a key that does nothing is
    worse than a menu that promises nothing. }
  LAction.ShortCut := ShortCut(Ord('E'), [ssCtrl, ssShift]);
  LAction.OnUpdate := OnRenameUpdate;
  LAction.OnExecute := OnRenameExecute;
  LAction.Enabled := True;
  LAction.ActionList := FActionList;

  // NO MENU ITEM FOR PROTOTYPE SYNC, and no command of its own: it is a step
  // inside class completion now (Ctrl+Shift+C - see
  // PasTreeIdePlugin.SyncPrototypes for why the IDE's own broken "Sync
  // Prototypes" item cannot be fixed or replaced safely).
end;

{ Our "Find Declaration", standing where the native one stood. Same caption,
  deliberately: it is the same command, and this is the slot people already
  reach for. }
procedure TMenuManager.AddIdentifierActions;
var
  LAction: TAction;
begin
  LAction := TAction.Create(FIdentifierActionList);
  LAction.Name := 'PasTreeFindDeclaration';
  LAction.Caption := 'Find Declaration';
  LAction.Category := 'PasTreeFindDeclaration';
  LAction.OnUpdate := OnFindDeclarationUpdate;
  LAction.OnExecute := OnFindDeclarationExecute;
  LAction.Enabled := True;
  LAction.ActionList := FIdentifierActionList;
end;

constructor TMenuManager.Create;
begin
  inherited;
  FActionList := TActionList.Create(nil);

  if Supports(BorlandIDEServices, IOTAEditorServices, FEditorServices) then
  begin
    var LLocalMenuIntf := FEditorServices.GetEditorLocalMenu;
    // Our own category, ALONGSIDE the native items: "Find Type Declaration",
    // "Find References" and "Rename..." are not Code Insight concepts and
    // replace nothing, so they need no takeover and unregister cleanly.
    LLocalMenuIntf.RegisterActionList(FActionList, cMenuCategory);
    FRegistered := True;
    AddActions;

    { THE ONE TAKEOVER, AND THE ONE PLACE A SETTING IS READ AT STARTUP
      RATHER THAN AT THE POINT OF USE.

      The native "Find Declaration" is the IDE's own item and never reaches
      this package: under any Insight Provider but PasTree it runs the native
      navigation, which on a large project is the thing this plugin exists to
      replace - it silently does nothing, with nothing in any log, because
      nothing of ours ever ran. Ctrl+Click can be intercepted at the mouse; a
      menu item cannot. Taking the category over is the only way.

      IT IS A ONE-WAY DOOR WITHIN A SESSION: UnregisterActionList removes
      whatever list the IDE registered under 'Identifier' and there is no
      handle to put it back, so an Uninstall without an IDE restart leaves
      the slot empty. That is why the door is only opened when the user has
      the override switched ON, and why this is the one switch read at
      startup: with it off at load we take nothing, and the native item is
      untouched and behaves exactly as it always did.

      Turned OFF mid-session, the item cannot become native again - so it
      hides instead (OnFindDeclarationUpdate) rather than staying and acting
      against the setting. It comes back native at the next IDE start. The
      settings dialog says so. }
    if CtrlClickNavigation then
    begin
      FIdentifierActionList := TActionList.Create(nil);
      LLocalMenuIntf.UnregisterActionList(cEdMenuCatIdentifier);
      LLocalMenuIntf.RegisterActionList(FIdentifierActionList,
        cEdMenuCatIdentifier);
      FIdentifierRegistered := True;
      AddIdentifierActions;
    end;
  end
  else
    FRegistered := False;
end;

destructor TMenuManager.Destroy;
var
  LEditorServices: IOTAEditorServices;
begin
  // Must unregister before the package unloads, otherwise the IDE throws when
  // it next tries to build the local menu and calls our (freed) OnUpdate.
  if FRegistered then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    begin
      var LLocalMenuIntf := LEditorServices.GetEditorLocalMenu;
      LLocalMenuIntf.UnregisterActionList(cMenuCategory);
      if FIdentifierRegistered then
        // Leaves the 'Identifier' category empty rather than native - the
        // one-way door in Create. The package's own workflow restarts the
        // IDE after every rebuild anyway (see the README).
        LLocalMenuIntf.UnregisterActionList(cEdMenuCatIdentifier);
    end;
  end;
  FreeAndNil(FActionList);
  FreeAndNil(FIdentifierActionList);
  inherited;
end;

procedure TMenuManager.OnFindDeclarationUpdate(Sender: TObject);
begin
  // HIDDEN, not greyed, when the override was switched off after the takeover
  // already happened: the native item cannot be given back until the IDE
  // restarts, and an item that acts against the setting is worse than a
  // missing one. See the takeover comment in Create.
  TAction(Sender).Visible := CtrlClickNavigation;
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnFindDeclarationExecute(Sender: TObject);
begin
  ExecuteGotoDeclaration(FEditorServices.TopView);
end;

procedure TMenuManager.OnFindTypeDeclarationUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnFindTypeDeclarationExecute(Sender: TObject);
begin
  ExecuteTypeDefinition(FEditorServices.TopView);
end;

procedure TMenuManager.OnFindReferencesUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnFindReferencesExecute(Sender: TObject);
begin
  ExecuteFindReferences(FEditorServices.TopView);
end;

procedure TMenuManager.OnRenameUpdate(Sender: TObject);
begin
  // HIDDEN rather than greyed when the feature is off: a disabled item
  // reads as "not right now", and this one would never come back without a
  // trip to the settings dialog. Off means gone.
  TAction(Sender).Visible := RenameEnabled;
  TAction(Sender).Enabled := FEditorServices.TopView <> nil;
end;

procedure TMenuManager.OnRenameExecute(Sender: TObject);
begin
  ExecuteRename(FEditorServices.TopView);
end;

{ TToggleKeyBinding }

function TToggleKeyBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TToggleKeyBinding.GetDisplayName: string;
begin
  // What the user sees in the Key Mappings list, so it has to say which keys
  // it takes over - that page is where someone goes to find out why
  // Ctrl+Shift+Up stopped behaving the way it used to.
  Result := 'PasTree: declaration/implementation (Ctrl+Shift+Up/Down)';
end;

function TToggleKeyBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.ToggleKeyBinding';
end;

procedure TToggleKeyBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([ShortCut(VK_DOWN, [ssCtrl, ssShift])],
    ToggleProc, nil);
  ABindingServices.AddKeyBinding([ShortCut(VK_UP, [ssCtrl, ssShift])],
    ToggleProc, nil);
end;

procedure TToggleKeyBinding.ToggleProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
begin
  // krHandled unconditionally once we recognise the key, even when there is
  // nothing to jump to: krUnhandled would hand the keystroke back to the IDE,
  // which would then run ITS decl<->impl jump - so a position our analysis
  // cannot answer would silently fall back to the implementation this replaces,
  // and the two disagreeing would be indistinguishable from ours misbehaving.
  // THE OFF SWITCH, and it is the ONE place in this procedure that may answer
  // krUnhandled: that is precisely what makes "override off" mean "the IDE's
  // own jump", with no keymap to unbind and nothing to restore. It has to
  // come before ABindingResult is set below, where krHandled is deliberately
  // unconditional.
  if not OverrideDeclImplToggle then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  if not Assigned(AContext) or not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) then
    Exit;
  // Down goes to the body, Up back to the header - and either key falls back to
  // the other direction when the cursor is already at that end (see
  // ExecuteToggle).
  ExecuteToggle(LView, AKeyCode = ShortCut(VK_DOWN, [ssCtrl, ssShift]));
end;

{ TProjectOpenNotifier }

procedure TProjectOpenNotifier.FileNotification(
  ANotifyCode: TOTAFileNotification; const AFileName: string;
  var ACancel: Boolean);
begin
  if ANotifyCode in [ofnEndProjectGroupOpen, ofnActiveProjectChanged] then
  begin
    LspProjectOpened;
    CheckInsightProviderSelected;
    { A RETRY, and idempotent - see InitializeSettings. At package load the
      IDE's menu (and the Build tab any complaint would go to) may not be
      built yet, so a first attempt there can fail invisibly. This is the
      first moment the IDE is demonstrably up, so it is where the attempt
      actually has to succeed - and where its diagnostics land somewhere the
      user can read them. A no-op once the menu item exists. }
    InitializeSettings;
  end
  // BEGIN, not END: at ofnEndProjectGroupClose the project is already gone, so
  // the line could not name it - and naming which project went away is the
  // entire value of logging a close.
  else if ANotifyCode = ofnBeginProjectGroupClose then
  begin
    LspProjectClosed;
    // THE RESULT TABS GO WITH THE PROJECT THEY DESCRIBE. Both are IDE message
    // groups, so nothing removes them on their own: they sit through the
    // close and are still on screen when the next project opens, listing
    // file/line rows into a project that is no longer loaded. The rename tab
    // is the worse of the two - it claims sites were CHANGED, and closing
    // without saving is precisely how those changes are thrown away, so what
    // stands there afterwards is a record of edits that never happened.
    CloseRenameResults;
    CloseFindReferencesResults;
  end;
end;

procedure TProjectOpenNotifier.BeforeCompile(const AProject: IOTAProject;
  var ACancel: Boolean);
begin
end;

procedure TProjectOpenNotifier.AfterCompile(ASucceeded: Boolean);
begin
end;

{ TIDEWizard }

constructor TIDEWizard.Create;
begin
  // FIRST, before anything that could fault: the vectored AV recorder. It
  // observes only - every access violation in the process is written to
  // pastree-ide-crash.log with a stack, and nothing about the IDE's own
  // handling changes. See the unit header.
  InitializeCrashLog;
  FMenuManager := TMenuManager.Create;
  // Creates the session object only - the server is spawned by the first
  // prewarm or the first navigation request, so loading this package costs
  // nothing on its own.
  InitializeLspSession;
  // Registers the Code Insight manager; inert until the user selects
  // "PasTree" as the Insight Provider in Options - and since phase C that
  // selection is what carries ALL declaration navigation.
  InitializeCodeInsight;
  // Ctrl+Click in the editor, as a mouse override independent of the Insight
  // Provider selection - for the users who cannot give that combobox up (RAD
  // Studio gates part of the editor UI on DelphiLSP being the provider). It
  // stands down by itself whenever PasTree IS the selected provider, so the
  // two paths never both run; see PasTreeIdePlugin.GotoDeclaration's header.
  InitializeGotoDeclaration;
  // Project-wide symbol search in the IDE Insight dialog (Ctrl+.).
  InitializeIdeInsight;
  // Painted error squiggles over the server's pushed diagnostics. (The
  // native IOTAModuleErrors trait was spiked and ruled out 2026-08-22 -
  // the module answers that interface natively; SPEC.md, closed
  // experiment.)
  InitializeErrorPaint;
  // Idle-debounced didChange - keeps the squiggles (and every other answer)
  // tracking the buffer as it is typed, not as it was last saved.
  InitializeIdleSync;
  // The Structure pane outline for the active source file.
  InitializeOutline;
  // Ctrl+Shift+C: our class completion, replacing the native one by keyboard
  // binding (it is not gated by the Insight Provider selection, so this is
  // the only way to take it over).
  InitializeClassComplete;
  InitializeSyncPrototypes;
  // Enter after an unclosed block opener: the server (standard LSP
  // onTypeFormatting) answers with the closer - see
  // PasTreeIdePlugin.BlockClose. An editor-events OBSERVER, not a key
  // binding - a binding on plain Enter killed the key editor-wide once.
  InitializeBlockClose;
  // Ctrl+Shift+E (and an editor menu item): rename a symbol across the
  // project, then show every changed line in its own Messages tab. The
  // ToolsAPI has no refactoring surface, so this is a plain command -
  // see PasTreeIdePlugin.Rename.
  InitializeRename;
  // Tools > PasTree > Settings. Last of the registrations because it is the
  // only one that is pure UI - nothing above it reads the settings at
  // startup, they are read at the point of use.
  InitializeSettings;

  FNotifierIndex := -1;
  if Supports(BorlandIDEServices, IOTAServices, FServices) then
    FNotifierIndex := FServices.AddNotifier(TProjectOpenNotifier.Create);

  FKeyBindingIndex := -1;
  if Supports(BorlandIDEServices, IOTAKeyboardServices, FKeyboardServices) then
    FKeyBindingIndex :=
      FKeyboardServices.AddKeyboardBinding(TToggleKeyBinding.Create);

  // A project can already be open when this package loads - installing it into
  // a running IDE, or an IDE that restored its project group before the
  // packages finished loading. No notification is coming for that one, so it
  // is prewarmed here. Harmless when there is no project: LspPrewarm is silent.
  LspPrewarm;
end;

destructor TIDEWizard.Destroy;
begin
  // Before anything else, and for the same reason the editor notifier and the
  // history items are unregistered: a notification arriving after this BPL
  // unloads calls into freed code. RemoveNotifier releases our instance.
  if (FNotifierIndex >= 0) and Assigned(FServices) then
    FServices.RemoveNotifier(FNotifierIndex);
  FServices := nil;
  // Same rule as every other registration here: a keystroke dispatched into
  // unloaded package code is an immediate crash, so the binding goes before
  // anything it could call.
  if (FKeyBindingIndex >= 0) and Assigned(FKeyboardServices) then
    FKeyboardServices.RemoveKeyboardBinding(FKeyBindingIndex);
  FKeyboardServices := nil;
  // Early, with the other things the IDE can dispatch into: a Tools menu
  // item whose OnClick points into an unloaded BPL is the same crash as a
  // keystroke or a notification arriving late.
  FinalizeSettings;
  FinalizeGotoDeclaration;
  // Before FinalizeLspSession, both of these: the session's teardown fails
  // every pending request synchronously, and those callbacks must find the
  // manager and the Insight notifier already unregistered (and their
  // closures gated off - see the GAlive flags in each unit).
  FinalizeClassComplete;
  FinalizeSyncPrototypes;
  FinalizeBlockClose;
  FinalizeOutline;
  FinalizeIdeInsight;
  FinalizeCodeInsight;
  // The idle timer before the session: a tick after FinalizeLspSession
  // would sync against a dead client.
  FinalizeIdleSync;
  FinalizeErrorPaint;
  FinalizeRename;
  FinalizeFindReferencesMessageGroup;
  // Last of the teardowns and the least forgiving one: this stops the server
  // and joins the transport's reader thread. A reader thread still running
  // inside this package's code when the BPL unloads is an immediate crash, so
  // it must not outlive this call.
  FinalizeLspSession;
  FreeAndNil(FMenuManager);
  // DRAIN THE MAIN-THREAD SYNC QUEUE before the BPL unloads. The teardown
  // above fails every pending request, and those callbacks defer their IDE
  // delivery via TThread.ForceQueue(nil, ...) - entries no thread owns, so
  // nothing removes them. Left in the queue at IDE shutdown, they are freed
  // by the RTL's own finalization AFTER this package is gone: releasing a
  // closure whose code has been unloaded, which is the intermittent
  // shutdown AV first seen 2026-08-22. Draining runs them NOW instead -
  // each exits immediately on its GAlive/session gates - and leaves the
  // queue with nothing of ours.
  while CheckSynchronize do ;
  // LAST, mirroring Create: the handler is a pointer into this BPL, so it
  // must be unregistered before the BPL can go - and keeping it live through
  // the teardown above is the point, since the shutdown AV is one of the two
  // it was written for.
  FinalizeCrashLog;
  inherited;
end;

procedure TIDEWizard.Execute;
begin
end;

function TIDEWizard.GetIDString: string;
begin
  Result := '[9E6C7B9A-6F1D-4C3E-9A2A-5B7B7C6E9C10]';
end;

function TIDEWizard.GetName: string;
begin
  Result := 'PasTreeIdePlugin.Wizard';
end;

function TIDEWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

end.
