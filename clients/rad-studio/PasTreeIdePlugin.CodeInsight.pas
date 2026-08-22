unit PasTreeIdePlugin.CodeInsight;

{
  The Code Insight manager skeleton - phase B.2 of COMPLETION.md, and the
  vehicle for the endgame decided in SPEC.md: once this manager answers well
  enough to be the Insight Provider for Pascal, the mouse-notifier Ctrl+Click
  override and the editor-menu takeover get deleted, because the IDE calls
  the manager for both.

  ALWAYS REGISTERED (2026-08-21, revising COMPLETION.md's original
  environment-variable gate at the user's call: an uninstall is recovery
  enough for a dev-stage plugin, and the gate was one more thing to explain).
  The real safety is the IDE's own: registration alone takes nothing over -
  the manager only ANSWERS once the user selects "PasTree" under
  Tools > Options > Editor > Source > Insight Provider, and switching back
  is the same combobox. The registration is logged to the Build tab with
  that instruction, since selecting the provider is the step people miss.

  WHAT IT ANSWERS TODAY, honestly and nothing more:
    - Code completion  -> textDocument/completion via LspCompletion (the
      server's interim keyword provider; PasTree replaces that server-side,
      this unit does not change).
    - Browse (Ctrl+Click when WE are the provider) -> AsyncGotoDefinitionEx
      over the same LspDefinition path the current override uses - but
      returning the target to the IDE, which then navigates and keeps history
      itself. That is the migration seam.
    - Hint text (Tooltip Insight) -> AsyncGetHintText over the server's
      hover, stripped to tooltip plain text by the session.
    - Parameter insight -> declined (AllowCodeInsight says no), so the IDE
      shows nothing rather than something wrong. It joins when the server
      grows signatureHelp.

  The sync-interface methods (SetFilter/FindIdent on the symbol list, called
  per keystroke while the viewer is open) answer from the cached array the
  async answer filled - the constraint clients/rad-studio/SPEC.md documents:
  those calls may never round-trip.

  Registered via IOTACodeInsightServices.AddCodeInsightManager, which takes
  the SYNC interface (IOTACodeInsightManager); the async shape is offered as
  a companion the IDE queries with Supports. The sync Invoke methods
  therefore exist but decline - if a bring-up run shows the IDE using them
  instead of the async path, that finding goes here and the answer is a
  cached-list fallback, not blocking the main thread.

  COORDINATES: AsyncInvoke* hand over (ALine, ACharIndex) with no
  documentation of base, and the first live bring-up (2026-08-21) proved the
  guessed convention wrong - the parameters did not point at the text under
  the caret, so the server saw an empty prefix and answered all 64 keywords.
  Completion reads the CARET instead (EditPosition.Row/Column, IDE convention
  by definition); the second bring-up run confirmed that end to end - viewer,
  prefix filtering, accept-replaces-prefix all behave. Goto-definition still
  trusts the parameters, because a browse can be invoked at a click point
  rather than the caret; it is unexercised until the mouse-notifier override
  retires (phase C), and off-by-one there is the first thing to check.
}

interface

procedure InitializeCodeInsight;

{ Unregister before the BPL unloads - ordered BEFORE FinalizeLspSession in
  TIDEWizard.Destroy, because a viewer callback dispatched into this unit
  after the session died would ask questions nothing can answer. }
procedure FinalizeCodeInsight;

{ True when OUR manager is the IDE's current Insight Provider - the switch
  the Ctrl+Click mouse override checks to stand down (PasTreeIdePlugin.
  GotoDeclaration): with PasTree selected in Options the native click chain
  must reach AsyncGotoDefinitionEx, and intercepting it would test nothing.
  Conservative on every doubt (no manager registered, no services, nil
  current manager): False, meaning the override keeps handling the click -
  the behavior every user who never touched Options already has. }
function PasTreeIsActiveInsightProvider: Boolean;

implementation

uses
  System.SysUtils,
  System.Types,
  System.UITypes,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  Vcl.Graphics,
  ToolsAPI,
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments;

{ RE-ENTRANCY GUARD FOR THE IDE CALLBACKS. LspSession invokes a request's
  callback SYNCHRONOUSLY when the request cannot even be issued (no server
  exe, no active project, a send that fails outright). Passed straight
  through, the IDE would be called back with an operation id BEFORE the
  AsyncInvoke* call that created it has returned that id - re-entrant into
  the IDE's own bookkeeping, which has no reason to tolerate it. So every
  async entry point sets AInInvoke=True for the duration of the issuing call:
  a callback that fires inside that window is deferred one main-thread queue
  pump (ForceQueue), landing after the id has been returned; the normal
  asynchronous path is not delayed by anything. }
procedure DeliverToIde(AInInvoke: Boolean; const ADeliver: TProc);
begin
  if AInInvoke then
    TThread.ForceQueue(nil,
      procedure
      begin
        ADeliver();
      end)
  else
    ADeliver();
end;

var
  // The teardown guard for async closures. A completion callback captures
  // the manager (Self) to fill FSymbols; if the LSP session dies during
  // package unload it FAILS every pending request synchronously, and by then
  // the manager may already be gone - the dangling-Self flavour of the AV
  // this project keeps a standing rule about. Checked FIRST in every closure
  // that touches manager state, before any Self dereference.
  GAlive: Boolean = False;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ ---------------------------------------------------------------------------
  The symbol list: one async answer, filtered synchronously ever after
  --------------------------------------------------------------------------- }

type
  TPasSymbolList = class(TInterfacedObject, IOTACodeInsightSymbolList,
    IOTACodeInsightSymbolList80)
  private
    FAll: TArray<TLspCompletionItem>;
    FVisible: TArray<Integer>;   // indices into FAll, after SetFilter
    FSortOrder: TOTASortOrder;
    procedure Rebuild(const AFilter: string);
  public
    constructor Create(const AItems: TArray<TLspCompletionItem>);
    { IOTACodeInsightSymbolList }
    procedure Clear;
    function GetCount: Integer;
    function GetSymbolIsReadWrite(I: Integer): Boolean;
    function GetSymbolIsAbstract(I: Integer): Boolean;
    function GetViewerSymbolFlags(I: Integer): TOTAViewerSymbolFlags;
    function GetViewerVisibilityFlags(I: Integer): TOTAViewerVisibilityFlags;
    function GetProcDispatchFlags(I: Integer): TOTAProcDispatchFlags;
    procedure SetSortOrder(const Value: TOTASortOrder);
    function GetSortOrder: TOTASortOrder;
    function FindIdent(const AnIdent: string): Integer;
    function FindSymIndex(const Ident: string; var Index: Integer): Boolean;
    procedure SetFilter(const FilterText: string);
    { The full item behind a viewer row - what Done reads to decide
      auto-parenthesis. Searches ALL items, not the filtered view: the
      viewer's selected string exists regardless of the current filter. }
    function TryGetByName(const AName: string;
      out AItem: TLspCompletionItem): Boolean;
    function GetSymbolText(Index: Integer): string;
    function GetSymbolTypeText(Index: Integer): string;
    function GetSymbolClassText(I: Integer): string;
    { IOTACodeInsightSymbolList80 }
    function GetSymbolDocumentation(I: Integer): string;
  end;

constructor TPasSymbolList.Create(const AItems: TArray<TLspCompletionItem>);
begin
  inherited Create;
  FAll := AItems;
  FSortOrder := soAlpha;
  // Sorted ONCE, here: SetFilter runs per keystroke on the UI thread with
  // whole-RTL-sized lists, and a prefix filter preserves order - so Rebuild
  // never needs to sort, only scan. (soScope grouping, when it comes, means
  // a second precomputed permutation, not a per-keystroke sort.)
  TArray.Sort<TLspCompletionItem>(FAll,
    TComparer<TLspCompletionItem>.Construct(
      function(const A, B: TLspCompletionItem): Integer
      begin
        Result := CompareText(A.ItemLabel, B.ItemLabel);
      end));
  Rebuild('');
end;

procedure TPasSymbolList.Rebuild(const AFilter: string);
var
  LIdx, LCount: Integer;
begin
  // Counted growth, not per-element appends: this runs per keystroke and
  // FAll can hold thousands of rows.
  SetLength(FVisible, Length(FAll));
  LCount := 0;
  for LIdx := 0 to High(FAll) do
    if (AFilter = '') or FAll[LIdx].ItemLabel.StartsWith(AFilter, True) then
    begin
      FVisible[LCount] := LIdx;
      Inc(LCount);
    end;
  SetLength(FVisible, LCount);
end;

procedure TPasSymbolList.Clear;
begin
  FAll := nil;
  FVisible := nil;
end;

function TPasSymbolList.GetCount: Integer;
begin
  Result := Length(FVisible);
end;

function TPasSymbolList.GetSymbolIsReadWrite(I: Integer): Boolean;
begin
  Result := False;
end;

function TPasSymbolList.GetSymbolIsAbstract(I: Integer): Boolean;
begin
  Result := False;
end;

function TPasSymbolList.GetViewerSymbolFlags(I: Integer): TOTAViewerSymbolFlags;
begin
  // LSP CompletionItemKind -> viewer color class. Only the kinds the server
  // can send today and the obvious next ones; everything else draws neutral.
  if (I < 0) or (I > High(FVisible)) then
    Exit(vsfUnknown);
  case FAll[FVisible[I]].Kind of
    3:  Result := vsfFunction;    // Function
    5:  Result := vsfVariable;    // Field
    6:  Result := vsfLocalVar;    // Variable
    7:  Result := vsfType;        // Class
    8:  Result := vsfInterface;   // Interface
    9:  Result := vsfUnit;        // Module
    10: Result := vsfProperty;    // Property
    14: Result := vsfReservedWord;
    21: Result := vsfConstant;    // Constant
  else
    Result := vsfUnknown;
  end;
end;

function TPasSymbolList.GetViewerVisibilityFlags(
  I: Integer): TOTAViewerVisibilityFlags;
begin
  Result := 0;
end;

function TPasSymbolList.GetProcDispatchFlags(I: Integer): TOTAProcDispatchFlags;
begin
  Result := pdfNone;
end;

procedure TPasSymbolList.SetSortOrder(const Value: TOTASortOrder);
begin
  FSortOrder := Value;
end;

function TPasSymbolList.GetSortOrder: TOTASortOrder;
begin
  Result := FSortOrder;
end;

function TPasSymbolList.FindIdent(const AnIdent: string): Integer;
var
  LIdx: Integer;
begin
  // "Closest partial match": the first visible label the ident is a prefix
  // of; failing that, the top of the list keeps the viewer somewhere sane.
  for LIdx := 0 to High(FVisible) do
    if FAll[FVisible[LIdx]].ItemLabel.StartsWith(AnIdent, True) then
      Exit(LIdx);
  Result := 0;
end;

function TPasSymbolList.FindSymIndex(const Ident: string;
  var Index: Integer): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(FVisible) do
    if SameText(FAll[FVisible[LIdx]].ItemLabel, Ident) then
    begin
      Index := LIdx;
      Exit(True);
    end;
  Result := False;
end;

procedure TPasSymbolList.SetFilter(const FilterText: string);
begin
  Rebuild(FilterText);
end;

function TPasSymbolList.GetSymbolText(Index: Integer): string;
begin
  if (Index >= 0) and (Index <= High(FVisible)) then
    Result := FAll[FVisible[Index]].ItemLabel
  else
    Result := '';
end;

function TPasSymbolList.GetSymbolTypeText(Index: Integer): string;
begin
  // Drawn GLUED right after the symbol text - exactly where the native
  // viewer shows a symbol's type/signature, and exactly why the server
  // sends Detail display-verbatim (': TStringList (+2)').
  if (Index >= 0) and (Index <= High(FVisible)) then
    Result := FAll[FVisible[Index]].Detail
  else
    Result := '';
end;

function TPasSymbolList.GetSymbolClassText(I: Integer): string;
begin
  // The viewer's left-hand class column, in the exact vocabulary the native
  // DelphiLSP list uses ('keyword', 'function', 'const', ...) - matching it
  // is what makes our rows read like the IDE's own. A routine's REAL head
  // word (constructor/destructor/operator/...) arrives from the server in
  // the item's data field and wins over the generic kind mapping.
  if (I < 0) or (I > High(FVisible)) then
    Exit('');
  if FAll[FVisible[I]].Head <> '' then
    Exit(FAll[FVisible[I]].Head);
  case FAll[FVisible[I]].Kind of
    2, 3:   Result := 'function';    // Method, Function
    4:      Result := 'constructor';
    5, 6:   Result := 'var';         // Field, Variable
    7, 8:   Result := 'type';        // Class, Interface
    9:      Result := 'unit';        // Module
    10:     Result := 'property';
    14:     Result := 'keyword';
    20:     Result := 'value';       // EnumMember
    21:     Result := 'const';
    24:     Result := 'operator';
    25:     Result := 'type';        // TypeParameter
  else
    Result := '';
  end;
end;

function TPasSymbolList.TryGetByName(const AName: string;
  out AItem: TLspCompletionItem): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(FAll) do
    if SameText(FAll[LIdx].ItemLabel, AName) then
    begin
      AItem := FAll[LIdx];
      Exit(True);
    end;
  Result := False;
end;

function TPasSymbolList.GetSymbolDocumentation(I: Integer): string;
begin
  Result := '';   // nothing deferred server-side yet - see COMPLETION.md
end;

{ ---------------------------------------------------------------------------
  The manager
  --------------------------------------------------------------------------- }

type
  TPasCodeInsightManager = class(TInterfacedObject, IOTACodeInsightManager100,
    IOTACodeInsightManager, IOTACodeInsightSelection,
    IOTAAsyncCodeInsightManager, IOTAAsyncCodeInsightManager290,
    INTACustomDrawCodeInsightViewer)
  private
    FEnabled: Boolean;
    FSymbols: IOTACodeInsightSymbolList;
    // The same object as FSymbols, typed - Done and DrawLine need item
    // fields the interface does not expose. The interface reference owns
    // the lifetime; this one is only ever read alongside it.
    FSymbolsObj: TPasSymbolList;
    // The list the VIEWER actually pulled (GetSymbolList) - a late async
    // answer may replace FSymbols while a popup built from the previous
    // list is still open, and Done's auto-parenthesis must consult what the
    // user was LOOKING AT, not the newest answer. The interface reference
    // keeps the shown object alive.
    FShownSymbols: IOTACodeInsightSymbolList;
    FShownObj: TPasSymbolList;
    // The one in-flight async completion; a later invocation supersedes it
    // (LspSession cancels the LSP request, this id gate drops the callback).
    FNextId: Integer;
    FActiveId: Integer;
    FActiveHintId: Integer;
    function CurrentView: IOTAEditView;
  public
    constructor Create;
    { IOTACodeInsightManager100 }
    function GetName: string;
    function GetIDString: string;
    function GetEnabled: Boolean;
    procedure SetEnabled(Value: Boolean);
    function EditorTokenValidChars(PreValidating: Boolean): TSysCharSet;
    procedure AllowCodeInsight(var Allow: Boolean; const Key: Char);
    function PreValidateCodeInsight(const Str: string): Boolean;
    function IsViewerBrowsable(Index: Integer): Boolean;
    function GetMultiSelect: Boolean;
    procedure GetSymbolList(out SymbolList: IOTACodeInsightSymbolList);
    procedure OnEditorKey(Key: Char; var CloseViewer: Boolean;
      var Accept: Boolean);
    function HandlesFile(const AFileName: string): Boolean;
    function GetLongestItem: string;
    procedure GetParameterList(out ParameterList: IOTACodeInsightParameterList);
    procedure GetCodeInsightType(AChar: Char; AElement: Integer;
      out CodeInsightType: TOTACodeInsightType; out InvokeType: TOTAInvokeType);
    function InvokeCodeCompletion(HowInvoked: TOTAInvokeType;
      var Str: string): Boolean;
    function InvokeParameterCodeInsight(HowInvoked: TOTAInvokeType;
      var SelectedIndex: Integer): Boolean;
    procedure ParameterCodeInsightAnchorPos(var EdPos: TOTAEditPos);
    function ParameterCodeInsightParamIndex(EdPos: TOTAEditPos): Integer;
    function GetHintText(HintLine, HintCol: Integer): string;
    function GotoDefinition(out AFileName: string; out ALineNum: Integer;
      Index: Integer = -1): Boolean;
    procedure Done(Accepted: Boolean; out DisplayParams: Boolean);
    { IOTACodeInsightManager }
    function GetOptionSetName: string;
    { IOTACodeInsightSelection - GetIDString is shared with the manager }
    function GetDisplayName: string;
    { IOTAAsyncCodeInsightManager }
    procedure AsyncAllowCodeInsight(var AAllow: Boolean; const AKey: Char);
    function AsyncCanInvoke(AInsightType: TOTACodeInsightType): Boolean;
    function AsyncEnabled: Boolean;
    function AsyncInvokeCodeCompletion(AHowInvoked: TOTAInvokeType;
      var AStr: string; ALine, ACharIndex: Integer;
      ACallback: TOTACodeCompleteCallBack): Integer;
    function AsyncInvokeParameterCodeInsight(HowInvoked: TOTAInvokeType;
      const AFileName: string; ALine, ACharIndex: Integer;
      ACallback: TOTAParametersCallBack): Integer;
    function AsyncGetHintText(HintLine, HintCol: Integer;
      ACallBack: TOTAHintTextCallBack): Integer;
    function AsyncGotoDefinition(const AFileName: string;
      ALine, ACharIndex: Integer;
      ACallBack: TOTAGotoDefinitionCallBack): Integer;
    procedure AsyncParameterCodeInsightParamIndex(const AFileName: string;
      ALine, ACharIndex: Integer; ACallBack: TOTAParamIndexCallBack);
    procedure AsyncOperationCanceled(AId: Integer);
    function ShowCalculating: Boolean;
    { IOTAAsyncCodeInsightManager290 }
    function AsyncGotoDefinitionEx(const AFileName: string;
      ALine, ACharIndex: Integer;
      ACallBack: TOTAGotoDefinitionCallBackEx): Integer;
    { INTACustomDrawCodeInsightViewer }
    procedure DrawLine(Index: Integer; Canvas: TCanvas; var Rect: TRect;
      DrawingHintText: Boolean; DoDraw: Boolean; var DefaultDraw: Boolean);
  end;

constructor TPasCodeInsightManager.Create;
begin
  inherited Create;
  FEnabled := True;
end;

function TPasCodeInsightManager.CurrentView: IOTAEditView;
var
  LServices: IOTACodeInsightServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    LServices.GetEditView(Result);
end;

function TPasCodeInsightManager.GetName: string;
begin
  Result := 'PasTree code insight';
end;

function TPasCodeInsightManager.GetIDString: string;
begin
  Result := 'PasTreeIdePlugin.CodeInsight';
end;

function TPasCodeInsightManager.GetDisplayName: string;
begin
  Result := 'PasTree';   // the Tools > Options "Insight Provider" combobox
end;

function TPasCodeInsightManager.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure TPasCodeInsightManager.SetEnabled(Value: Boolean);
begin
  FEnabled := Value;
end;

function TPasCodeInsightManager.EditorTokenValidChars(
  PreValidating: Boolean): TSysCharSet;
begin
  Result := ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

procedure TPasCodeInsightManager.AllowCodeInsight(var Allow: Boolean;
  const Key: Char);
begin
  // #0 completion, #2 browse, #3 hints (Tooltip Insight, over the server's
  // hover), '.' the trigger character. #1 (parameters) still declines
  // honestly until the server answers signatureHelp - the IDE then shows
  // nothing rather than something wrong.
  Allow := (Key = #0) or (Key = #2) or (Key = #3) or (Key = '.');
end;

function TPasCodeInsightManager.PreValidateCodeInsight(
  const Str: string): Boolean;
begin
  Result := True;
end;

function TPasCodeInsightManager.IsViewerBrowsable(Index: Integer): Boolean;
begin
  // Deliberately not yet: real symbols DO have declarations now, but the
  // sync GotoDefinition below declines (async is the only resolve path), so
  // advertising browseability would offer a gesture that goes nowhere.
  // Revisit with phase C, when GotoDefinition becomes the one navigation.
  Result := False;
end;

function TPasCodeInsightManager.GetMultiSelect: Boolean;
begin
  Result := False;
end;

procedure TPasCodeInsightManager.GetSymbolList(
  out SymbolList: IOTACodeInsightSymbolList);
begin
  SymbolList := FSymbols;
  // Whatever the viewer takes now is what Done must judge later - see
  // FShownSymbols.
  FShownSymbols := FSymbols;
  FShownObj := FSymbolsObj;
end;

procedure TPasCodeInsightManager.OnEditorKey(Key: Char;
  var CloseViewer: Boolean; var Accept: Boolean);
begin
  // Identifier characters refine the filter; Enter/Tab accept; anything else
  // closes without accepting (Escape never reaches here).
  if CharInSet(Key, ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
  begin
    CloseViewer := False;
    Accept := False;
  end
  else
  begin
    CloseViewer := True;
    Accept := CharInSet(Key, [#13, #9]);
  end;
end;

function TPasCodeInsightManager.HandlesFile(const AFileName: string): Boolean;
begin
  Result := IsPascalSourceFile(AFileName);
end;

function TPasCodeInsightManager.GetLongestItem: string;
begin
  // Per the interface doc this is the longest CLASS text ('constructor' vs
  // 'var'), not the longest item - and 'constructor' is the widest word our
  // class column ever shows.
  Result := 'constructor';
end;

procedure TPasCodeInsightManager.GetParameterList(
  out ParameterList: IOTACodeInsightParameterList);
begin
  ParameterList := nil;   // parameter insight is declined in AllowCodeInsight
end;

procedure TPasCodeInsightManager.GetCodeInsightType(AChar: Char;
  AElement: Integer; out CodeInsightType: TOTACodeInsightType;
  out InvokeType: TOTAInvokeType);
begin
  InvokeType := itManual;
  case AChar of
    #0: CodeInsightType := citCodeInsight;
    #2: CodeInsightType := citBrowseCodeInsight;
    // Without this arm the IDE never reaches AsyncGetHintText at all: it
    // asks GetCodeInsightType(#3) BEFORE invoking a hint, and citNone here
    // vetoes the whole gesture - the first tooltip bring-up showed exactly
    // that (no popup, no request in the log).
    #3: CodeInsightType := citHintCodeInsight;
    '.':
      begin
        // The same trigger character the server advertises to LSP clients.
        CodeInsightType := citCodeInsight;
        InvokeType := itTimer;
      end;
  else
    CodeInsightType := citNone;
  end;
end;

function TPasCodeInsightManager.InvokeCodeCompletion(
  HowInvoked: TOTAInvokeType; var Str: string): Boolean;
begin
  // The SYNC invocation. Answering it truthfully would mean blocking the
  // main thread on the server, which nothing here ever does - the async
  // companion is the real path. Declining is safe: an IDE that ignored the
  // async interface would show no completion, not wrong completion, and the
  // gated bring-up exists to catch exactly that before anyone relies on it.
  Result := False;
end;

function TPasCodeInsightManager.InvokeParameterCodeInsight(
  HowInvoked: TOTAInvokeType; var SelectedIndex: Integer): Boolean;
begin
  Result := False;
end;

procedure TPasCodeInsightManager.ParameterCodeInsightAnchorPos(
  var EdPos: TOTAEditPos);
begin
  // Untouched: no parameter hints yet.
end;

function TPasCodeInsightManager.ParameterCodeInsightParamIndex(
  EdPos: TOTAEditPos): Integer;
begin
  Result := -1;
end;

function TPasCodeInsightManager.GetHintText(HintLine, HintCol: Integer): string;
begin
  Result := '';
end;

function TPasCodeInsightManager.GotoDefinition(out AFileName: string;
  out ALineNum: Integer; Index: Integer): Boolean;
begin
  // Sync browse: same reasoning as InvokeCodeCompletion - the async Ex
  // overload is the real path.
  AFileName := '';
  ALineNum := 0;
  Result := False;
end;

procedure TPasCodeInsightManager.Done(Accepted: Boolean;
  out DisplayParams: Boolean);
var
  LServices: IOTACodeInsightServices;
  LViewer: IOTACodeInsightViewer;
  LSelected: string;
  LItem: TLspCompletionItem;
  LView: IOTAEditView;
begin
  DisplayParams := False;
  if not Accepted then
    Exit;
  // Insertion is the manager's job (the interface comment says so): take the
  // viewer's selection and let the IDE replace the token under the caret -
  // the same replace-the-typed-prefix contract the LSP textEdit span carries
  // for VS Code, expressed through the IDE's own InsertText.
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LViewer := nil;
  LServices.GetViewer(LViewer);
  if not Assigned(LViewer) then
    Exit;
  LSelected := LViewer.GetSelectedString;
  if LSelected = '' then
    Exit;
  LServices.InsertText(LSelected, True);
  // AUTO-PARENTHESIS: a routine WITH parameters gets `()` and the caret
  // lands between them, mirroring the native behavior. hasParams came from
  // the server (the declaration's real nkParams), so a parameterless
  // procedure stays bare - `LoadSettings;` never becomes `LoadSettings();`.
  // Applied only on the keyboard accept (Enter/Tab, per OnEditorKey): a
  // future '(' close-key accept must not double the paren. Judged against
  // the list the VIEWER displayed (FShownObj), not the newest answer - a
  // late re-invoke may have replaced FSymbolsObj under the open popup.
  if Assigned(FShownObj) and FShownObj.TryGetByName(LSelected, LItem) and
     LItem.HasParams then
  begin
    LView := CurrentView;
    // The completed name may sit in an EXISTING call - caret inside the
    // identifier of `LoadSettings(True);` - where appending `()` would
    // produce `LoadSettings()(True)`. If a paren already follows the
    // caret, the native behavior is to add nothing.
    if Assigned(LView) and (LView.Buffer.EditPosition.Character <> '(') then
    begin
      LView.Buffer.EditPosition.InsertText('()');
      LView.Buffer.EditPosition.MoveRelative(0, -1);
      // Repaint now rather than on the next natural refresh: the insertion
      // came from a popup, and a stale caret is visibly wrong.
      LView.Paint;
    end;
  end;
end;

function TPasCodeInsightManager.GetOptionSetName: string;
begin
  Result := '';   // no Code Insight option set page of our own
end;

{ ------------------------------ async half ------------------------------ }

procedure TPasCodeInsightManager.AsyncAllowCodeInsight(var AAllow: Boolean;
  const AKey: Char);
begin
  AllowCodeInsight(AAllow, AKey);
end;

function TPasCodeInsightManager.AsyncCanInvoke(
  AInsightType: TOTACodeInsightType): Boolean;
begin
  Result := AInsightType in [citCodeInsight, citBrowseCodeInsight,
    citHintCodeInsight];
end;

function TPasCodeInsightManager.AsyncEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TPasCodeInsightManager.AsyncInvokeCodeCompletion(
  AHowInvoked: TOTAInvokeType; var AStr: string; ALine, ACharIndex: Integer;
  ACallback: TOTACodeCompleteCallBack): Integer;
var
  LId, LRow, LCol: Integer;
  LView: IOTAEditView;
  LFileName: string;
  LInInvoke: Boolean;
begin
  LView := CurrentView;
  if not Assigned(LView) then
    Exit(-1);
  LFileName := LView.Buffer.FileName;
  // THE POSITION COMES FROM THE CARET, NOT FROM THE PARAMETERS. The first
  // live bring-up (2026-08-21) showed why: with the caret after `beg` the
  // parameters carried a position whose text was NOT `beg` - the server saw
  // an empty prefix and answered all 64 keywords - and the parameters' base
  // (0- or 1-based line, char index vs column) is documented nowhere.
  // Completion is only ever invoked at the caret, and the caret's own
  // coordinates are already in IDE convention, so use those and log the raw
  // parameters alongside until the convention is understood.
  LRow := LView.Buffer.EditPosition.Row;
  LCol := LView.Buffer.EditPosition.Column;
  Inc(FNextId);
  LId := FNextId;
  FActiveId := LId;
  LInInvoke := True;
  LspCompletion(LFileName, LRow, LCol,
    procedure(ASuccess: Boolean; const AItems: TArray<TLspCompletionItem>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      // A superseded or cancelled invocation must not call back: the IDE has
      // already moved on, and LspSession has already cancelled the request.
      if FActiveId <> LId then
        Exit;
      FActiveId := 0;
      if ASuccess then
      begin
        FSymbolsObj := TPasSymbolList.Create(AItems);
        FSymbols := FSymbolsObj;
      end
      else
      begin
        FSymbols := nil;
        FSymbolsObj := nil;
      end;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallback) then
            ACallback(Self, LId, not ASuccess, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncInvokeParameterCodeInsight(
  HowInvoked: TOTAInvokeType; const AFileName: string;
  ALine, ACharIndex: Integer; ACallback: TOTAParametersCallBack): Integer;
begin
  Result := -1;   // declined in AsyncCanInvoke; nothing to start
end;

function TPasCodeInsightManager.AsyncGetHintText(HintLine, HintCol: Integer;
  ACallBack: TOTAHintTextCallBack): Integer;
var
  LId: Integer;
  LView: IOTAEditView;
  LFileName: string;
  LInInvoke: Boolean;
begin
  // Tooltip Insight: the server's hover, as plain text. The position is the
  // HOVERED token's, not the caret's, so the parameters must be trusted -
  // assumed to follow the browse convention confirmed live (1-based line,
  // 0-based char index); if a tooltip ever describes the neighbor token,
  // this conversion is the first suspect.
  LView := CurrentView;
  if not Assigned(LView) then
    Exit(-1);
  LFileName := LView.Buffer.FileName;
  Inc(FNextId);
  LId := FNextId;
  FActiveHintId := LId;
  LInInvoke := True;
  LspHover(LFileName, HintLine, HintCol + 1,
    procedure(ASuccess: Boolean; const AText: string; const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      if FActiveHintId <> LId then
        Exit;   // superseded by a newer hover
      FActiveHintId := 0;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallBack) then
            ACallBack(Self, LId, AText, not ASuccess, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncGotoDefinition(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBack): Integer;
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  LInInvoke := True;
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      DeliverToIde(LInInvoke,
        procedure
        begin
          if not (GAlive and Assigned(ACallBack)) then
            Exit;
          if ASuccess and (Length(AHits) > 0) then
            ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row, False, '')
          else
            ACallBack(Self, LId, '', 0, True, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncGotoDefinitionEx(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBackEx): Integer;
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  LInInvoke := True;
  // Browse parameters CONFIRMED live (2026-08-21): 1-based line, 0-based
  // char index - the +1 below landed the jump exactly. (Completion's
  // parameters remain untrusted; it reads the caret instead - see above.)
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      DeliverToIde(LInInvoke,
        procedure
        begin
          if not (GAlive and Assigned(ACallBack)) then
            Exit;
          if ASuccess and (Length(AHits) > 0) then
            // Col back to the 0-based char index the callback expects.
            ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row,
              AHits[0].Col - 1, False, '')
          else
            ACallBack(Self, LId, '', 0, 0, True, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

{ Draws a parameter list the way the NATIVE completion window colors one
  (matched against it live, 2026-08-22): parameter names and punctuation in
  the base text color, TYPE text (between ':' and the next ';'/'='/end) in
  the warm type accent, default VALUES in blue, the const/var/out modifiers
  bold like the editor draws reserved words. A flat tokenizer over the
  signature text is enough - the server sends the declaration's own source
  span, so the ':'/';'/'=' structure is real Pascal, not a guess. }
procedure DrawColoredSignature(ACanvas: TCanvas; var AX: Integer;
  ATop: Integer; const AText: string; ABase, ATypeColor, AValueColor: TColor);
type
  TMode = (mName, mType, mDefault);

  procedure Put(const ARun: string; AColor: TColor; ABold: Boolean = False);
  begin
    if ARun = '' then
      Exit;
    if ABold then
      ACanvas.Font.Style := [TFontStyle.fsBold];
    ACanvas.Font.Color := AColor;
    ACanvas.TextOut(AX, ATop, ARun);
    Inc(AX, ACanvas.TextWidth(ARun));
    if ABold then
      ACanvas.Font.Style := [];
  end;

var
  LIdx, LFrom: Integer;
  LMode: TMode;
  LRun: string;
begin
  LMode := mName;
  LIdx := 1;
  while LIdx <= Length(AText) do
  begin
    if CharInSet(AText[LIdx], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
    begin
      LFrom := LIdx;
      while (LIdx <= Length(AText)) and
            CharInSet(AText[LIdx], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
        Inc(LIdx);
      LRun := Copy(AText, LFrom, LIdx - LFrom);
      case LMode of
        mType:
          Put(LRun, ATypeColor);
        mDefault:
          Put(LRun, AValueColor);
      else
        // The parameter-group modifiers read as reserved words: bold.
        if SameText(LRun, 'const') or SameText(LRun, 'var') or
           SameText(LRun, 'out') then
          Put(LRun, ABase, True)
        else
          Put(LRun, ABase);
      end;
    end
    else
    begin
      case AText[LIdx] of
        ':': LMode := mType;
        ';': LMode := mName;
        '=': LMode := mDefault;
      end;
      // 'array of', 'TArray<Integer>' - keep type-mode spaces/brackets in
      // the type color so a compound type reads as one colored phrase.
      if (LMode = mType) and (AText[LIdx] <> ':') then
        Put(AText[LIdx], ATypeColor)
      else
        Put(AText[LIdx], ABase);
      Inc(LIdx);
    end;
  end;
end;

{ The rich-coloring pass (COMPLETION.md's deferred-polish item, delivered
  2026-08-22): the stock renderer draws every row in one color; the native
  DelphiLSP window dims the class word and colors the type text. This draw
  reproduces the STOCK LAYOUT exactly - fixed class column, bold name, the
  type text glued after it - and only takes over the COLORS: class word and
  the ': ' / '(+N)' furniture dimmed (clGrayText), parameter names base,
  type text in the IDE's theme-aware blue (DrawColoredSignature). On the
  selected row everything stays the viewer's own highlight color: contrast
  beats decoration there, which is also what the native window does. }
procedure TPasCodeInsightManager.DrawLine(Index: Integer; Canvas: TCanvas;
  var Rect: TRect; DrawingHintText: Boolean; DoDraw: Boolean;
  var DefaultDraw: Boolean);
const
  cPad = 4;
var
  LClass, LName, LDetail, LParamsText, LTypeText, LTail: string;
  LColWidth, LX, LTop, LCut: Integer;
  LUI: INTAIDEUIServices;
  LBase, LDim, LTypeColor, LValueColor: TColor;
begin
  if not Assigned(FSymbols) or (Index < 0) or (Index >= FSymbols.Count) then
  begin
    DefaultDraw := True;
    Exit;
  end;
  DefaultDraw := False;
  LClass := FSymbols.SymbolClassText[Index];
  LName := FSymbols.SymbolText[Index];
  LDetail := FSymbols.SymbolTypeText[Index];

  // The class column is fixed-width - rows must align down the list, and
  // 'constructor' is the widest word the column ever holds.
  Canvas.Font.Style := [];
  LColWidth := Canvas.TextWidth('constructor') + 2 * cPad;

  if not DoDraw then
  begin
    Canvas.Font.Style := [TFontStyle.fsBold];
    LX := Canvas.TextWidth(LName);
    Canvas.Font.Style := [];
    Rect.Right := Rect.Left + LColWidth + LX + Canvas.TextWidth(LDetail)
      + 3 * cPad;
    Exit;
  end;

  // The viewer prepared Canvas for this row (highlight brush on the
  // selected row) - LBase is whatever it chose. Colors STAY on the selected
  // row: the native window keeps its signature colors under the highlight
  // bar, and the first pass here that flattened them read as the coloring
  // "disappearing" on selection.
  LBase := Canvas.Font.Color;
  LDim := clGrayText;
  LTypeColor := LBase;
  LValueColor := LBase;
  if Supports(BorlandIDEServices, INTAIDEUIServices, LUI) then
  begin
    // The native palette: types in the warm accent, values in blue - both
    // theme-aware so the dark theme gets its own variants.
    LTypeColor := LUI.ThemeAwareColors[itcOrange];
    LValueColor := LUI.ThemeAwareColors[itcBlue];
  end;

  LTop := Rect.Top + (Rect.Height - Canvas.TextHeight('Ag')) div 2;
  LX := Rect.Left + cPad;

  Canvas.Font.Color := LDim;
  Canvas.TextOut(LX, LTop, LClass);
  LX := Rect.Left + LColWidth;

  Canvas.Font.Color := LBase;
  Canvas.Font.Style := [TFontStyle.fsBold];
  Canvas.TextOut(LX, LTop, LName);
  Inc(LX, Canvas.TextWidth(LName));
  Canvas.Font.Style := [];

  if LDetail <> '' then
  begin
    { The Detail shapes the server sends: '(params)', '(params): T', ': T' -
      each optionally tailed by ' (+N)'. Split into params (base color,
      regular weight - they are code, like the native window draws them),
      ': ' furniture and the overload tail (dim), and the TYPE name (accent).
      The tail is matched from the END: a parameter list could contain a
      literal ' (+' of its own. }
    LTail := '';
    LCut := LDetail.LastIndexOf(' (+');
    if (LCut >= 0) and LDetail.EndsWith(')') and
       (LCut >= LDetail.Length - 8) then
    begin
      LTail := LDetail.Substring(LCut);
      LDetail := LDetail.Substring(0, LCut);
    end;
    LParamsText := '';
    LTypeText := '';
    if LDetail.StartsWith('(') then
    begin
      LCut := LDetail.LastIndexOf('): ');
      if LCut >= 0 then
      begin
        LParamsText := LDetail.Substring(0, LCut + 1);
        LTypeText := LDetail.Substring(LCut + 3);
      end
      else
        LParamsText := LDetail;
    end
    else if LDetail.StartsWith(': ') then
      LTypeText := LDetail.Substring(2)
    else
      LParamsText := LDetail;   // unknown shape: draw plainly, never lose it

    if LParamsText <> '' then
      DrawColoredSignature(Canvas, LX, LTop, LParamsText, LBase, LTypeColor,
        LValueColor);
    if LTypeText <> '' then
    begin
      Canvas.Font.Color := LBase;   // ': ' is code furniture, like native
      Canvas.TextOut(LX, LTop, ': ');
      Inc(LX, Canvas.TextWidth(': '));
      Canvas.Font.Color := LTypeColor;
      Canvas.TextOut(LX, LTop, LTypeText);
      Inc(LX, Canvas.TextWidth(LTypeText));
    end;
    if LTail <> '' then
    begin
      Canvas.Font.Color := LDim;   // '(+N)' is ours, not code - stays dim
      Canvas.TextOut(LX, LTop, LTail);
    end;
  end;
  Canvas.Font.Color := LBase;   // leave the canvas the way the viewer set it
end;

procedure TPasCodeInsightManager.AsyncParameterCodeInsightParamIndex(
  const AFileName: string; ALine, ACharIndex: Integer;
  ACallBack: TOTAParamIndexCallBack);
begin
  // No parameter insight - never invoked while AsyncCanInvoke declines it.
end;

procedure TPasCodeInsightManager.AsyncOperationCanceled(AId: Integer);
begin
  // Drop the callback gate; LspSession's supersede-cancel already told the
  // server the moment a newer request went out.
  if FActiveId = AId then
    FActiveId := 0;
  if FActiveHintId = AId then
    FActiveHintId := 0;
end;

function TPasCodeInsightManager.ShowCalculating: Boolean;
begin
  Result := False;   // keyword answers are instant; no flicker for them
end;

{ ---------------------------------------------------------------------------
  Registration
  --------------------------------------------------------------------------- }

var
  GManager: IOTACodeInsightManager;
  GManagerIndex: Integer = -1;

procedure InitializeCodeInsight;
var
  LServices: IOTACodeInsightServices;
begin
  if Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  GManager := TPasCodeInsightManager.Create;
  GManagerIndex := LServices.AddCodeInsightManager(GManager);
  GAlive := True;
  // Loud on purpose: registering changes nothing by itself, and picking the
  // provider in Options is exactly the step people miss.
  LogDiagnostic('Code Insight manager registered. Select "PasTree" under '
    + 'Tools > Options > Editor > Source > Insight Provider to use it.');
end;

function PasTreeIsActiveInsightProvider: Boolean;
var
  LServices: IOTACodeInsightServices;
  LCurrent: IOTACodeInsightManager;
begin
  Result := False;
  if not Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LCurrent := nil;
  LServices.GetCurrentCodeInsightManager(LCurrent);
  // By IDString, not interface identity: the services may hand back a
  // different interface reference onto the same registered manager.
  Result := Assigned(LCurrent)
    and SameText(LCurrent.GetIDString, GManager.GetIDString);
end;

procedure FinalizeCodeInsight;
var
  LServices: IOTACodeInsightServices;
begin
  GAlive := False;
  if GManagerIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
      LServices.RemoveCodeInsightManager(GManagerIndex);
    GManagerIndex := -1;
  end;
  GManager := nil;
end;

end.
