unit PasTreeIdePlugin.GotoDeclaration;

{
  PasTree-backed navigation entry points: the "Find Type Declaration" menu
  item and the Ctrl+Shift+Up/Down decl<->impl toggle, plus the history-aware
  NavigateToPosition/PushHistoryAndNavigate machinery they (and Alt+Left/
  Alt+Right) run on.

  THE CTRL+CLICK MOUSE OVERRIDE, AND WHY IT CAME BACK (2026-09-01). From
  2026-08-15 this unit intercepted Ctrl+Click through a TNTACodeEditorNotifier
  mouse hook; phase C (2026-08-22, COMPLETION.md) deleted it, on the reasoning
  that declaration navigation belongs to the IDE's own click chain - which
  ends in PasTreeIdePlugin.CodeInsight.AsyncGotoDefinitionEx when the user has
  selected "PasTree" under Tools > Options > Editor > Source > Insight
  Provider, so the IDE draws the Ctrl+hover underline, navigates and keeps
  history itself.

  That reasoning holds, and it is still the better path - but it costs the
  whole Insight Provider slot, and RAD Studio deliberately gates some editor
  UI on DelphiLSP being the selected provider. Selecting PasTree there is
  therefore not a trade everyone can make, and for those users phase C left
  Ctrl+Click on the native navigation this project exists to replace. So the
  hook is back, as an INDEPENDENT feature with its own switch
  (Settings.CtrlClickNavigation), not as a rival to the manager:

    - PasTree IS the selected Insight Provider -> the hook stands down
      unconditionally (PasTreeIsActiveInsightProvider), switch or no switch.
      The IDE's own chain already resolves through us, and two resolvers on
      one click means two history entries.
    - Any other provider -> the hook claims plain Ctrl+Click when the switch
      is on, and does nothing at all when it is off.

  Mechanism: INTACodeEditorServices.AddEditorEventsNotifier with a
  TNTACodeEditorNotifier subclass (ToolsAPI.Editor.pas), hooked on
  OnEditorMouseDownEx/OnEditorMouseUpEx - both carry a `var Handled: Boolean`
  documented as "Set to True to mark the event as handled and prevent further
  processing". Same technique RAD Studio's own "KeyboardMouse Events Demo"
  sample uses. Split across the two events: MouseDown only suppresses the
  default down-side processing (starting a selection drag), MouseUp suppresses
  and starts the resolve. Suppression is unconditional once the chord matches,
  even if nothing resolves - the point is to stop the native path, not to fall
  back to it on a miss.

  ASYNCHRONOUS: each entry point returns immediately and the jump happens on
  a later main-thread turn, when the server answers. By then the cursor may
  have moved, so the "jumped from" history position is captured at
  invocation time - see the closure comments below.

  Failures are deliberately quiet (logged, not shown as a dialog): these run
  on high-frequency gestures, and a modal popup per miss would be much more
  disruptive than useful. See LogDiagnostic.

  Backward/Forward history (2026-08-15): a successful jump registers with
  IOTAHistoryServices (PushHistoryAndNavigate/TPasHistoryItem), the same
  global stack the IDE's own Alt+Left/Alt+Right toolbar buttons use - so
  they work across our jumps too, not just the native ones. Every
  TPasHistoryItem we hand to the IDE is tracked (GHistoryItems) and removed
  via RemoveHistoryItem at package unload (ClearHistoryItems, called from
  FinalizeGotoDeclaration) - left registered, a stale entry would call
  .Execute on an object living in unloaded package code the next time the
  user pressed Alt-Left/Right, exactly the class of AV this project has
  already hit more than once with package hot-reload.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Registers the Ctrl+Click mouse override for the lifetime of the package.
/// Call once (from PasTreeIdePlugin.Wizard's TIDEWizard.Create). The notifier
/// is registered unconditionally; whether a given click is claimed is decided
/// per click, so toggling the setting takes effect on the next click rather
/// than at the next IDE start.
/// </summary>
procedure InitializeGotoDeclaration;

/// <summary>
/// Unregisters the mouse override and removes every history item this unit
/// handed to the IDE. Call once (from TIDEWizard.Destroy) BEFORE the package
/// unloads - a stale entry would call .Execute on freed package code from
/// Alt+Left/Alt+Right, and a live notifier would call into unloaded code on
/// the next click.
/// </summary>
procedure FinalizeGotoDeclaration;

/// <summary>
/// The declaration jump from the cursor, run explicitly rather than from a
/// click - the same resolve+navigate the Ctrl+Click override performs. Not
/// bound to a menu item of our own (the native "Find Declaration" item stays
/// the IDE's, no action-list takeover), but this is the entry point any
/// future explicit affordance would call.
/// </summary>
procedure ExecuteGotoDeclaration(const AView: IOTAEditView);

/// <summary>
/// Entry point for the "Find Type Declaration" editor menu item
/// (PasTreeIdePlugin.Wizard): jumps to the declaration of the TYPE of the
/// identifier at the cursor - `S: TStringList` on a use of S lands on
/// TStringList - through the same history-aware navigation as everything
/// else here, so Alt+Left/Alt+Right work across it.
/// </summary>
procedure ExecuteTypeDefinition(const AView: IOTAEditView);

/// <summary>
/// The decl&lt;-&gt;impl toggle, bound to Ctrl+Shift+Down (AToImpl) and
/// Ctrl+Shift+Up in PasTreeIdePlugin.Wizard - the two keys RAD Studio uses
/// for its own version of this jump. Navigates through the same
/// history-aware path as everything here, so Alt+Left/Alt+Right work across
/// these jumps too.
/// </summary>
procedure ExecuteToggle(const AView: IOTAEditView; AToImpl: Boolean);

/// <summary>
/// Jumps to a known position through the same history-aware path as every
/// navigation here - the "from" side is the active editor's caret when there
/// is one (an IDE Insight result activated from the dialog, for instance).
/// </summary>
procedure NavigateHistoryAware(const AFileName: string; ARow, ACol: Integer);

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes,
  System.Generics.Collections, Vcl.Controls, ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.CodeInsight,
  PasTreeIdePlugin.Settings;

/// <summary>
/// Goes to the IDE's own default Messages tab (nil group = the "Build" tab)
/// rather than a dedicated tab of our own, tagged "[pastree]" to stay
/// identifiable alongside compiler/linker noise - same convention as
/// PasTreeIdePlugin.FindReferences's own LogDiagnostic. Deliberately no
/// ShowMessageView: these run on high-frequency gestures, so forcing the
/// Messages panel open on a miss would be far more disruptive than the miss.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

/// <summary>
/// Standalone so the menu items, the toggle, and TPasHistoryItem.Execute
/// (below - what actually runs when the user presses Alt+Left/Alt+Right
/// through the history stack) all share the exact same logic and logging.
/// Takes a plain file/row/col so a history item (which only ever stores and
/// replays a position, never re-resolves anything) can call it without
/// depending on PasTree.Sema.Nav.
/// </summary>
procedure NavigateToPosition(const AFileName: string; ARow, ACol: Integer);
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LSourceEditor: IOTASourceEditor;
  LView: IOTAEditView;
begin
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LogDiagnostic('Goto Declaration: IOTAModuleServices unavailable.');
    Exit;
  end;
  LModule := LModuleServices.OpenModule(AFileName);
  if not Assigned(LModule) then
  begin
    LogDiagnostic(Format('Goto Declaration: OpenModule("%s") returned nil.', [AFileName]));
    Exit;
  end;

  // OpenModule loads the module but doesn't itself create a visible editor
  // view for a file that wasn't already open - EditViewCount is 0 right
  // after OpenModule alone. Show[Filename] creates/reveals the editor (and
  // its view) for the module; only after that does EditViews[0] exist.
  //
  // Deliberately ShowFilename(AFileName), not the plain Show: for a module
  // with an associated form (Unit1.pas + Unit1.dfm), Show shows the
  // module's "default editor" - which for a form-owning unit is the Form
  // Designer, exactly mirroring the well-known Project Manager behavior
  // where double-clicking such a unit opens the form, not the code. Since
  // AFileName here is always the .pas we're navigating into, ShowFilename
  // pins the reveal to that source file specifically, never the form.
  LModule.ShowFilename(AFileName);

  if not Supports(LModule.GetModuleFileEditor(0), IOTASourceEditor, LSourceEditor) then
  begin
    LogDiagnostic(Format('Goto Declaration: "%s" has no IOTASourceEditor at file index 0.',
      [AFileName]));
    Exit;
  end;
  if LSourceEditor.EditViewCount = 0 then
  begin
    LogDiagnostic(Format('Goto Declaration: "%s" has no edit views even after Show.',
      [AFileName]));
    Exit;
  end;

  LView := LSourceEditor.EditViews[0];
  LView.Position.GotoLine(ARow);
  LView.Position.Move(ARow, ACol);
  LView.MoveViewToCursor;
end;

type
  /// <summary>
  /// Narrow interface TPasHistoryItem also implements, purely so IsEqual can
  /// compare two history items' positions without an unsafe cast back to a
  /// concrete class through an interface reference - Supports(Item,
  /// IPasHistoryPosition, ...) is the correct way to ask "is this one of
  /// ours, and if so, what position does it hold", and correctly returns
  /// False (not equal) for the IDE's own or another plugin's history items.
  /// </summary>
  IPasHistoryPosition = interface
    ['{5C1E5F5D-8B7A-4B7E-9C6C-4B8E1A2F9D01}']
    function GetFileName: string;
    function GetRow: Integer;
    function GetCol: Integer;
  end;

  /// <summary>
  /// One entry in the IDE's global Backward/Forward navigation stack
  /// (IOTAHistoryServices) - what makes Alt+Left/Alt+Right return to (and
  /// back out of) a Go to Declaration jump, the same way they already do
  /// for the IDE's own native navigation. Execute just replays the stored
  /// position via NavigateToPosition; nothing is re-resolved through
  /// PasTree - a history entry is a plain (file, row, col) fact.
  /// </summary>
  TPasHistoryItem = class(TNotifierObject, IOTAHistoryItem, IPasHistoryPosition)
  private
    FFileName: string;
    FRow, FCol: Integer;
  public
    constructor Create(const AFileName: string; ARow, ACol: Integer);
    { IOTAHistoryItem }
    procedure Execute;
    function GetItemCaption: string;
    function IsEqual(const Item: IOTAHistoryItem): Boolean;
    { IPasHistoryPosition }
    function GetFileName: string;
    function GetRow: Integer;
    function GetCol: Integer;
  end;

constructor TPasHistoryItem.Create(const AFileName: string; ARow, ACol: Integer);
begin
  inherited Create;
  FFileName := AFileName;
  FRow := ARow;
  FCol := ACol;
end;

procedure TPasHistoryItem.Execute;
begin
  NavigateToPosition(FFileName, FRow, FCol);
end;

function TPasHistoryItem.GetItemCaption: string;
begin
  Result := Format('%s (%d)', [ExtractFileName(FFileName), FRow]);
end;

function TPasHistoryItem.IsEqual(const Item: IOTAHistoryItem): Boolean;
var
  LOther: IPasHistoryPosition;
begin
  Result := Supports(Item, IPasHistoryPosition, LOther)
    and SameText(LOther.GetFileName, FFileName)
    and (LOther.GetRow = FRow)
    and (LOther.GetCol = FCol);
end;

function TPasHistoryItem.GetFileName: string;
begin
  Result := FFileName;
end;

function TPasHistoryItem.GetRow: Integer;
begin
  Result := FRow;
end;

function TPasHistoryItem.GetCol: Integer;
begin
  Result := FCol;
end;

var
  // Every TPasHistoryItem we've ever handed to IOTAHistoryServices - tracked
  // so ClearHistoryItems can remove them all at package unload. Left
  // registered, they'd be exactly the kind of dangling-object AV this
  // project has already hit more than once, which is also why a rebuild here
  // means restarting the IDE rather than reinstalling the package (see the
  // README): pressing Alt-Left/Right after an unload would call
  // .Execute on an instance living in unloaded package code.
  GHistoryItems: TList<IOTAHistoryItem>;

procedure TrackHistoryItem(const AItem: IOTAHistoryItem);
begin
  if not Assigned(GHistoryItems) then
    GHistoryItems := TList<IOTAHistoryItem>.Create;
  GHistoryItems.Add(AItem);
end;

procedure ClearHistoryItems;
var
  LHistoryServices: IOTAHistoryServices;
  LItem: IOTAHistoryItem;
begin
  if not Assigned(GHistoryItems) then
    Exit;
  if Supports(BorlandIDEServices, IOTAHistoryServices, LHistoryServices) then
    for LItem in GHistoryItems do
      LHistoryServices.RemoveHistoryItem(LItem);
  FreeAndNil(GHistoryItems);
end;

/// <summary>
/// Registers the jump with the IDE's Backward/Forward history (so
/// Alt+Left/Alt+Right work across it, same as the IDE's own navigation),
/// then performs it by calling NewItem.Execute directly.
///
/// NOT IOTAHistoryServices.Execute(NewItem) - that was the code until
/// 2026-09-03 and it is what made "Back does nothing after Ctrl+Click"
/// depend on where you had already been. A stack dump showed two things:
/// AddHistoryItem alone already leaves the stack pointer on NewItem (it
/// appears in neither the backward nor the forward list afterwards), and
/// Execute(AItem) then re-finds "this position" by scanning the stack with
/// IsEqual and taking the FIRST match. Our IsEqual compares positions, so a
/// jump to a declaration already visited earlier in the session matched the
/// old entry near the bottom, the pointer moved there, everything newer
/// became "forward", and Back was disabled (back=0, fwd=3 in the dump).
/// Calling the item's own Execute performs the navigation and leaves the
/// pointer where AddHistoryItem put it.
///
/// Falls back to a direct NavigateToPosition call only if the history service
/// is unavailable (defensive - it's a core IDE service, expected to always be
/// there).
/// </summary>
procedure PushHistoryAndNavigate(const AFromFile: string; AFromRow, AFromCol: Integer;
  const AToFile: string; AToRow, AToCol: Integer);
var
  LHistoryServices: IOTAHistoryServices;
  LCurItem, LNewItem: IOTAHistoryItem;
begin
  LCurItem := TPasHistoryItem.Create(AFromFile, AFromRow, AFromCol);
  LNewItem := TPasHistoryItem.Create(AToFile, AToRow, AToCol);
  if Supports(BorlandIDEServices, IOTAHistoryServices, LHistoryServices) then
  begin
    LHistoryServices.AddHistoryItem(LCurItem, LNewItem);
    TrackHistoryItem(LCurItem);
    TrackHistoryItem(LNewItem);
    LNewItem.Execute;
  end
  else
    NavigateToPosition(AToFile, AToRow, AToCol);
end;

/// <summary>
/// The actual resolve+navigate logic, shared by the Ctrl+Click override
/// (DoMouseUp) and ExecuteGotoDeclaration. Only logs on failure - this fires
/// on every claimed Ctrl+Click, so logging every successful step would be far
/// noisier than useful; a miss is still always visible and says where it
/// happened.
/// </summary>
procedure ResolveAndNavigate(const AFileName: string; ARow, ACol: Integer);
begin
  try
    // The three-identity resolve (unit before symbol, builtins declining to
    // have a declaration at all) lives in the server's HandleDefinition - one
    // implementation for this plugin and any other LSP client, instead of the
    // same ordering rule written twice.
    LspDefinition(AFileName, ARow, ACol,
      // Captures AFileName/ARow/ACol, which are parameters of THIS call, so
      // every Ctrl+Click gets its own closure frame and its own "jumped from"
      // position. Capturing a shared local instead would send the history
      // entry to wherever the cursor happened to be when the answer arrived.
      procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
        const AError: string)
      begin
        if not ASuccess then
          LogDiagnostic('Goto Declaration: ' + AError)
        else if Length(AHits) = 0 then
          // Also the honest answer for a compiler builtin: no source
          // declaration exists anywhere, so there is nothing to navigate to.
          LogDiagnostic('Goto Declaration: no identifier/declaration '
            + 'resolved at cursor.')
        else
          PushHistoryAndNavigate(AFileName, ARow, ACol, AHits[0].FilePath,
            AHits[0].Row, AHits[0].Col);
      end);
  except
    on E: Exception do
      LogDiagnostic(Format('Goto Declaration: unhandled %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

procedure ExecuteGotoDeclaration(const AView: IOTAEditView);
begin
  if not Assigned(AView) then
    Exit;
  ResolveAndNavigate(AView.Buffer.FileName, AView.Buffer.EditPosition.Row,
    AView.Buffer.EditPosition.Column);
end;

procedure ExecuteTypeDefinition(const AView: IOTAEditView);
var
  LFileName: string;
  LRow, LCol: Integer;
begin
  if not Assigned(AView) then
    Exit;
  LFileName := AView.Buffer.FileName;
  LRow := AView.Buffer.EditPosition.Row;
  LCol := AView.Buffer.EditPosition.Column;
  try
    LspTypeDefinition(LFileName, LRow, LCol,
      // Same closure-per-call discipline as ResolveAndNavigate: the history's
      // "jumped from" is where the menu was invoked, not where the cursor
      // sits when the answer lands.
      procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
        const AError: string)
      begin
        if not ASuccess then
          LogDiagnostic('Type Declaration: ' + AError)
        else if Length(AHits) = 0 then
          // Legitimate for a unit name, a keyword, or a builtin whose type
          // has no source declaration - logged so "the click did nothing"
          // has a reason somewhere.
          LogDiagnostic('Type Declaration: no typed identifier resolved '
            + 'at cursor.')
        else
          PushHistoryAndNavigate(LFileName, LRow, LCol, AHits[0].FilePath,
            AHits[0].Row, AHits[0].Col);
      end);
  except
    on E: Exception do
      LogDiagnostic(Format('Type Declaration: unhandled %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

{ The toggle, with ONE RETRY IN THE OPPOSITE DIRECTION.

  The server answers a direction: implementation is header -> body, declaration
  is body -> header, and each says "nothing here" for the other case. Bound
  literally, Ctrl+Shift+Down would do nothing whenever the cursor is already in
  a body - which is most of the time, and reads as a broken key rather than as a
  direction that did not apply. So a null answer retries the other way, and both
  keys behave as the toggle people expect from the IDE while still preferring
  the direction that was actually pressed when both are possible.

  The retry costs a second round trip only in the case that would otherwise have
  done nothing at all, and the analysis is already built by then, so it is
  answered from the same in-memory model. }
procedure ToggleAndNavigate(const AFileName: string; ARow, ACol: Integer;
  AToImpl, ARetried: Boolean);
begin
  try
    LspToggle(AFileName, ARow, ACol, AToImpl,
      // Same closure-per-call discipline as ResolveAndNavigate above: the
      // "jumped from" position must be where the key was pressed, not wherever
      // the cursor sits when the answer lands.
      procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
        const AError: string)
      begin
        if not ASuccess then
          LogDiagnostic('Toggle decl/impl: ' + AError)
        else if Length(AHits) = 0 then
        begin
          if not ARetried then
            ToggleAndNavigate(AFileName, ARow, ACol, not AToImpl, True)
          // ELSE: SILENCE, DELIBERATELY. Both directions came back empty,
          // which the server answers as success-with-null and means only
          // that the cursor is not inside a routine with two halves - a
          // constant, a type, a comment, blank space. That is the ORDINARY
          // outcome of pressing a key that does not apply here, not a
          // failure, and it used to put a line in the Build tab every time.
          //
          // Nothing is lost, and this is why the empty case may be silent
          // while the branch above may not: a real refusal - no server, a
          // cancelled request, a dead connection - arrives as ASuccess=False
          // with a reason, and still logs. The protocol already tells the
          // two apart, so no server or PasTree change was needed. And "the
          // key did nothing" keeps its recorded reason where a diagnosis
          // would look for it: the server logs `nothing to toggle to at
          // that position` into pastree-lsp.log for exactly this answer.
        end
        else
          PushHistoryAndNavigate(AFileName, ARow, ACol, AHits[0].FilePath,
            AHits[0].Row, AHits[0].Col);
      end);
  except
    on E: Exception do
      LogDiagnostic(Format('Toggle decl/impl: unhandled %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

procedure ExecuteToggle(const AView: IOTAEditView; AToImpl: Boolean);
begin
  if not Assigned(AView) then
    Exit;
  ToggleAndNavigate(AView.Buffer.FileName, AView.Buffer.EditPosition.Row,
    AView.Buffer.EditPosition.Column, AToImpl, False);
end;

procedure NavigateHistoryAware(const AFileName: string; ARow, ACol: Integer);
var
  LEditorServices: IOTAEditorServices;
  LView: IOTAEditView;
begin
  LView := nil;
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    LView := LEditorServices.TopView;
  if Assigned(LView) then
    PushHistoryAndNavigate(LView.Buffer.FileName,
      LView.Buffer.EditPosition.Row, LView.Buffer.EditPosition.Column,
      AFileName, ARow, ACol)
  else
    NavigateToPosition(AFileName, ARow, ACol);
end;

{ THE CTRL+CLICK OVERRIDE ITSELF. See this unit's header for why it exists
  alongside the Code Insight manager rather than instead of it. }

type
  // AllowedEvents can only be customized by overriding it - there is no
  // event property for it on TNTACodeEditorNotifier, unlike the mouse
  // callbacks below (see the official KeyboardMouse Events Demo, which does
  // the same subclassing for the same reason).
  TGotoDeclarationNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

  TGotoDeclarationManager = class
  private
    FEditorServices: INTACodeEditorServices;
    FNotifier: TGotoDeclarationNotifier;
    FNotifierIndex: Integer;
    function TryGetPosition(const Editor: TWinControl; X, Y: Integer;
      out AView: IOTAEditView; out ARow, ACol: Integer): Boolean;
    procedure DoMouseDown(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
    procedure DoMouseUp(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  GManager: TGotoDeclarationManager;

function TGotoDeclarationNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents];
end;

function TGotoDeclarationManager.TryGetPosition(const Editor: TWinControl;
  X, Y: Integer; out AView: IOTAEditView; out ARow, ACol: Integer): Boolean;
var
  LState: INTACodeEditorState;
  LLineState: INTACodeEditorLineState;
  LColumn, LVisibleLine: Integer;
begin
  Result := False;
  AView := FEditorServices.GetViewForEditor(Editor);
  if not Assigned(AView) then
    Exit;

  LState := FEditorServices.EditorState[Editor];
  if not Assigned(LState) then
    Exit;
  if not LState.PointToCharacterPos(Point(X, Y), LColumn, LVisibleLine) then
    Exit;

  // LVisibleLine is a screen-visible line index, which can differ from the
  // file's own line numbering under code folding (elided sections). Convert
  // through LineState to get the LogicalLineNum PasTree's row numbers
  // actually correspond to.
  LLineState := LState.LineState[LVisibleLine];
  if not Assigned(LLineState) then
    Exit;

  ARow := LLineState.LogicalLineNum;
  ACol := LColumn;
  Result := True;
end;

/// <summary>
/// True only for a left click whose keyboard chord is EXACTLY Ctrl - masking
/// to the modifier keys first, because in mouse events Shift also carries
/// button-state flags (ssLeft etc.) that must not affect the comparison. A
/// bare `ssCtrl in Shift` would also swallow Ctrl+Shift+Click and
/// Ctrl+Alt+Click, silently taking those chords away from the IDE or any
/// other plugin that binds them; this override claims plain Ctrl+Click and
/// nothing else.
/// </summary>
function IsPlainCtrlLeftClick(Shift: TShiftState; Button: TMouseButton): Boolean;
begin
  Result := (Button = mbLeft)
    and (Shift * [ssShift, ssCtrl, ssAlt] = [ssCtrl]);
end;

/// <summary>
/// Whether THIS click is ours: the right chord, the feature switched on, and
/// PasTree not already serving the IDE's own click chain as the selected
/// Insight Provider. Asked identically on down and up, so the two events can
/// never disagree about who owns the click.
/// </summary>
function ClaimsClick(Shift: TShiftState; Button: TMouseButton): Boolean;
begin
  Result := IsPlainCtrlLeftClick(Shift, Button)
    and CtrlClickNavigation
    and not PasTreeIsActiveInsightProvider;
end;

procedure TGotoDeclarationManager.DoMouseDown(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  // Suppress default down-side handling only (e.g. starting a text selection
  // drag) - the actual navigation happens on mouse-up, below.
  if ClaimsClick(Shift, Button) then
    Handled := True;
end;

procedure TGotoDeclarationManager.DoMouseUp(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
var
  LView: IOTAEditView;
  LRow, LCol: Integer;
begin
  if not ClaimsClick(Shift, Button) then
    Exit;

  // Always suppress the native handler once the click is ours, even if we end
  // up resolving nothing below - the whole point is to stop the slow/broken
  // native path from running, not to fall back to it on a miss.
  Handled := True;

  if not TryGetPosition(Editor, X, Y, LView, LRow, LCol) then
  begin
    LogDiagnostic('Goto Declaration: could not resolve click position to a '
      + 'file/row/col.');
    Exit;
  end;

  ResolveAndNavigate(LView.Buffer.FileName, LRow, LCol);
end;

constructor TGotoDeclarationManager.Create;
begin
  inherited;
  FNotifierIndex := -1;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, FEditorServices) then
    Exit;
  FNotifier := TGotoDeclarationNotifier.Create;
  FNotifier.OnEditorMouseDownEx := DoMouseDown;
  FNotifier.OnEditorMouseUpEx := DoMouseUp;
  FNotifierIndex := FEditorServices.AddEditorEventsNotifier(FNotifier);
end;

destructor TGotoDeclarationManager.Destroy;
begin
  if Assigned(FEditorServices) and (FNotifierIndex >= 0) then
    FEditorServices.RemoveEditorEventsNotifier(FNotifierIndex);
  inherited;
end;

procedure InitializeGotoDeclaration;
begin
  if not Assigned(GManager) then
    GManager := TGotoDeclarationManager.Create;
end;

procedure FinalizeGotoDeclaration;
begin
  FreeAndNil(GManager);
  ClearHistoryItems;
end;

end.
