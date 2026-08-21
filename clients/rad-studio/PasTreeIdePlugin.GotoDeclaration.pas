unit PasTreeIdePlugin.GotoDeclaration;

{
  Ctrl+Click "Go to Declaration" override, backed by PasTree instead of RAD
  Studio's own DelphiLSP-based navigation (reported to work poorly on large
  projects - the whole reason for this unit).

  Mechanism: INTACodeEditorServices.AddEditorEventsNotifier with a
  TNTACodeEditorNotifier subclass (ToolsAPI.Editor.pas), hooked on
  OnEditorMouseDownEx/OnEditorMouseUpEx - both carry a `var Handled: Boolean`
  documented as "Set to True to mark the event as handled and prevent
  further processing" (ToolsAPI.Editor.pas:804-806, on the 370 notifier
  interface). Same technique RAD Studio's own official "KeyboardMouse
  Events Demo" sample uses (Samples\...\Editor Demos\KeyboardMouse Events
  Demo) - just for navigation instead of a status readout.

  Split across the two events:
    - MouseDown with Ctrl+Left: only sets Handled := True (suppress
      whatever default down-side processing exists, e.g. starting a text
      selection) - no navigation here.
    - MouseUp with Ctrl+Left: sets Handled := True AND starts the actual
      resolve+navigate, now as an LSP textDocument/definition request
      (PasTreeIdePlugin.LspSession) instead of an in-process
      BuildNavigator call. A compiler builtin still navigates nowhere -
      it has no source declaration anywhere - and native behavior is
      still suppressed (Handled stays True) rather than falling back to
      the slow/broken native path.

  ASYNCHRONOUS SINCE THE LSP MOVE. The mouse handler returns immediately and
  the jump happens on a later main-thread turn, when the server answers. In
  practice that is milliseconds, but it is a real behavior change: the click
  no longer blocks the IDE while the project is analyzed, and by the time the
  answer lands the cursor may have moved. The "jumped from" position recorded
  in the history is therefore captured at click time, not at answer time -
  see the closure comment in ResolveAndNavigate.

  CONFIRMED WORKING (2026-08-15): this override does intercept RAD Studio's
  native Ctrl+Click declaration navigation via this TCodeEditorEvents mouse
  chain - not just a documented-but-untested claim anymore.

  Failures here are deliberately quiet (logged, not shown as a dialog): this
  fires on every Ctrl+Click, far more often than the Find References menu
  item, so a modal popup on every miss would be much more disruptive than
  useful. See LogDiagnostic.

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
/// Registers the Ctrl+Click override for the lifetime of the package. Call
/// once (from PasTreeIdePlugin.Wizard's TIDEWizard.Create).
/// </summary>
procedure InitializeGotoDeclaration;

/// <summary>
/// Unregisters the override. Call once (from TIDEWizard.Destroy) - must be
/// called before the package unloads, same reason the editor local menu's
/// action list must be unregistered (see PasTreeIdePlugin.Wizard).
/// </summary>
procedure FinalizeGotoDeclaration;

/// <summary>
/// Entry point for the "Find Declaration" editor menu item
/// (PasTreeIdePlugin.Wizard - the replacement for RAD Studio's native "Find
/// Declaration") - runs the exact same resolve+navigate logic as the
/// Ctrl+Click override, from the cursor position, but through an explicit
/// menu click.
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
/// Ctrl+Shift+Up in PasTreeIdePlugin.Wizard - the two keys RAD Studio uses for
/// its own version of this jump, taken over the same way the native "Find
/// Declaration" menu item was.
///
/// Navigates through the same history-aware path as Ctrl+Click, so Alt+Left /
/// Alt+Right work across these jumps too.
/// </summary>
procedure ExecuteToggle(const AView: IOTAEditView; AToImpl: Boolean);

implementation

uses
  System.SysUtils, System.Types, System.Classes, System.UITypes,
  System.Generics.Collections, Vcl.Controls, ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.CodeInsight;

type
  // AllowedEvents can only be customized by overriding it - there is no
  // event property for it on TNTACodeEditorNotifier, unlike the mouse/
  // keyboard callbacks below (see the official KeyboardMouse Events Demo,
  // which does the same subclassing for the same reason).
  TGotoDeclarationNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

function TGotoDeclarationNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents];
end;

/// <summary>
/// Goes to the IDE's own default Messages tab (nil group = the "Build" tab)
/// rather than a dedicated tab of our own, tagged "[pastree]" to stay
/// identifiable alongside compiler/linker noise - same convention as
/// PasTreeIdePlugin.FindReferences's own LogDiagnostic. Deliberately no
/// ShowMessageView: this fires on every Ctrl+Click, so forcing the Messages
/// panel open on a miss would be far more disruptive than the miss itself.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

type
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

function TGotoDeclarationManager.TryGetPosition(const Editor: TWinControl; X, Y: Integer;
  out AView: IOTAEditView; out ARow, ACol: Integer): Boolean;
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
/// Standalone (not tied to the mouse-notifier instance) so the Ctrl+Click
/// path, the explicit menu item, and TPasHistoryItem.Execute (below - what
/// actually runs when the user presses Alt+Left/Alt+Right through the
/// history stack) all share the exact same logic and logging. Takes a
/// plain file/row/col rather than a TPasRefHit so a history item (which
/// only ever stores/replays a position, never re-resolves anything) can
/// call it without depending on PasTree.Sema.Nav.
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
/// then performs it via IOTAHistoryServices.Execute - which both sets the
/// stack pointer to the new position AND calls NewItem.Execute for us, so
/// this does not also call NavigateToPosition itself. Falls back to a
/// direct NavigateToPosition call only if the history service is
/// unavailable (defensive - it's a core IDE service, expected to always be
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
    LHistoryServices.Execute(LNewItem);
  end
  else
    NavigateToPosition(AToFile, AToRow, AToCol);
end;

/// <summary>
/// The actual resolve+navigate logic, shared by the Ctrl+Click override
/// (DoMouseUp) and the "Find Declaration" menu item
/// (ExecuteGotoDeclaration) - see this unit's header for why both exist.
/// Only logs on failure (LogDiagnostic/[pastree]) - this fires on every
/// Ctrl+Click, so logging every successful step would be far noisier than
/// useful; a miss is still always visible and says where it happened.
/// </summary>
procedure ResolveAndNavigate(const AFileName: string; ARow, ACol: Integer);
begin
  try
    // The three-identity resolve (unit before symbol, builtins declining to
    // have a declaration at all) now lives in the server's HandleDefinition -
    // one implementation for both this plugin and any other LSP client,
    // instead of the same ordering rule written twice.
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
          else
            // Both directions came back empty: the cursor is not inside a
            // routine that has two halves. Logged, because "the key did
            // nothing" needs a reason somewhere.
            LogDiagnostic('Toggle decl/impl: no routine with a separate '
              + 'declaration and body at cursor.');
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

procedure TGotoDeclarationManager.DoMouseDown(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
begin
  // Suppress default down-side handling only (e.g. starting a text
  // selection drag) - the actual navigation happens on mouse-up, below.
  // Stands down when OUR Code Insight manager is the selected provider -
  // see the matching check in DoMouseUp for the whole story.
  if IsPlainCtrlLeftClick(Shift, Button)
     and not PasTreeIsActiveInsightProvider then
    Handled := True;
end;

procedure TGotoDeclarationManager.DoMouseUp(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer; var Handled: Boolean);
var
  LView: IOTAEditView;
  LRow, LCol: Integer;
begin
  if not IsPlainCtrlLeftClick(Shift, Button) then
    Exit;

  { THE PHASE-C STEPPING STONE (COMPLETION.md): when the user has selected
    PasTree as the IDE's Insight Provider, this override stands down and the
    native click chain runs - which now ends in OUR manager's
    AsyncGotoDefinitionEx, so the resolver is the same and the IDE draws the
    Ctrl+hover underline, navigates and keeps history itself. That exercises
    the manager's browse path for real, which is the last unknown before the
    endgame deletes this unit's mouse machinery entirely. With any other
    provider selected (or none resolvable), behavior is unchanged: intercept
    and navigate ourselves. }
  if PasTreeIsActiveInsightProvider then
    Exit;

  // Always suppress the native handler for Ctrl+Left-click, even if we end
  // up resolving nothing below - the whole point is to stop the slow/broken
  // LSP-based one from running, not to fall back to it on a miss.
  Handled := True;

  if not TryGetPosition(Editor, X, Y, LView, LRow, LCol) then
  begin
    LogDiagnostic('Goto Declaration: could not resolve click position to a file/row/col.');
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
