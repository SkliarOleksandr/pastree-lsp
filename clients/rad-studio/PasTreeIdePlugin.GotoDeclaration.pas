unit PasTreeIdePlugin.GotoDeclaration;

{
  PasTree-backed navigation entry points: the "Find Type Declaration" menu
  item and the Ctrl+Shift+Up/Down decl<->impl toggle, plus the history-aware
  NavigateToPosition/PushHistoryAndNavigate machinery they (and Alt+Left/
  Alt+Right) run on.

  THE CTRL+CLICK MOUSE OVERRIDE IS GONE - PHASE C (2026-08-22, COMPLETION.md).
  From 2026-08-15 to phase C this unit intercepted Ctrl+Click through a
  TNTACodeEditorNotifier mouse hook (with a stepping-stone period where the
  hook stood down when PasTree was the selected Insight Provider). Since
  phase C, Ctrl+Click navigation belongs entirely to the IDE's own click
  chain, which ends in PasTreeIdePlugin.CodeInsight.AsyncGotoDefinitionEx
  when the user has selected "PasTree" under Tools > Options > Editor >
  Source > Insight Provider - the IDE draws the Ctrl+hover underline,
  navigates, and keeps history itself. With another provider selected, the
  native navigation runs; that is the provider contract, not a regression:
  one combobox decides the whole insight family.

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
/// Removes every history item this unit handed to the IDE. Call once (from
/// TIDEWizard.Destroy) BEFORE the package unloads - a stale entry would
/// call .Execute on freed package code from Alt+Left/Alt+Right.
/// </summary>
procedure FinalizeGotoDeclaration;

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
  System.SysUtils, System.Generics.Collections,
  PasTreeIdePlugin.LspSession;

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

procedure FinalizeGotoDeclaration;
begin
  ClearHistoryItems;
end;

end.
