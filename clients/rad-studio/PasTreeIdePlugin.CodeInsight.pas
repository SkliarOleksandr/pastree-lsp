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
    - Parameter insight and hint text -> declined (AllowCodeInsight says no),
      so the IDE shows nothing rather than something wrong. They join when
      the server grows signatureHelp/hover-for-hints.

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
  System.Generics.Collections,
  System.Generics.Defaults,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments;

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
  Rebuild('');
end;

procedure TPasSymbolList.Rebuild(const AFilter: string);
var
  LIdx: Integer;
begin
  FVisible := nil;
  for LIdx := 0 to High(FAll) do
    if (AFilter = '') or FAll[LIdx].ItemLabel.StartsWith(AFilter, True) then
      FVisible := FVisible + [LIdx];
  // Alphabetical either way: the only scope the interim provider knows is
  // "reserved word", so soScope has nothing to group by yet.
  TArray.Sort<Integer>(FVisible, TComparer<Integer>.Construct(
    function(const A, B: Integer): Integer
    begin
      Result := CompareText(FAll[A].ItemLabel, FAll[B].ItemLabel);
    end));
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
  // Drawn GLUED right after the symbol text (the first bring-up rendered
  // "beginreserved word" when the annotation sat here). That glued slot is
  // exactly where the native viewer shows a symbol's signature -
  // "(pFileName: ...): THandle;" straight after the bold name - so this
  // stays empty until the server sends real signatures, and then they go
  // here verbatim, separator included.
  Result := '';
end;

function TPasSymbolList.GetSymbolClassText(I: Integer): string;
begin
  // The viewer's left-hand class column, in the exact vocabulary the native
  // DelphiLSP list uses ('keyword', 'function', 'const', ...) - matching it
  // is what makes our rows read like the IDE's own.
  if (I < 0) or (I > High(FVisible)) then
    Exit('');
  case FAll[FVisible[I]].Kind of
    2, 3:   Result := 'function';    // Method, Function
    4:      Result := 'constructor';
    5, 6:   Result := 'var';         // Field, Variable
    7, 8:   Result := 'type';        // Class, Interface
    9:      Result := 'unit';        // Module
    10:     Result := 'property';
    14:     Result := 'keyword';
    21:     Result := 'const';
  else
    Result := '';
  end;
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
    IOTAAsyncCodeInsightManager, IOTAAsyncCodeInsightManager290)
  private
    FEnabled: Boolean;
    FSymbols: IOTACodeInsightSymbolList;
    // The one in-flight async completion; a later invocation supersedes it
    // (LspSession cancels the LSP request, this id gate drops the callback).
    FNextId: Integer;
    FActiveId: Integer;
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
  // #0 completion, #2 browse, '.' the trigger character. #1 (parameters) and
  // #3 (hints) decline honestly until the server answers them - the IDE then
  // shows nothing rather than something wrong.
  Allow := (Key = #0) or (Key = #2) or (Key = '.');
end;

function TPasCodeInsightManager.PreValidateCodeInsight(
  const Str: string): Boolean;
begin
  Result := True;
end;

function TPasCodeInsightManager.IsViewerBrowsable(Index: Integer): Boolean;
begin
  Result := False;   // a reserved word has no declaration to browse to
end;

function TPasCodeInsightManager.GetMultiSelect: Boolean;
begin
  Result := False;
end;

procedure TPasCodeInsightManager.GetSymbolList(
  out SymbolList: IOTACodeInsightSymbolList);
begin
  SymbolList := FSymbols;
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
  Result := 'resourcestring';   // the widest thing the keyword provider sends
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
begin
  DisplayParams := False;
  if not Accepted then
    Exit;
  // Insertion is the manager's job (the interface comment says so): take the
  // viewer's selection and let the IDE replace the token under the caret -
  // the same replace-the-typed-prefix contract the LSP textEdit span carries
  // for VS Code, expressed through the IDE's own InsertText.
  if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
  begin
    LViewer := nil;
    LServices.GetViewer(LViewer);
    if Assigned(LViewer) and (LViewer.GetSelectedString <> '') then
      LServices.InsertText(LViewer.GetSelectedString, True);
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
  Result := AInsightType in [citCodeInsight, citBrowseCodeInsight];
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
        FSymbols := TPasSymbolList.Create(AItems)
      else
        FSymbols := nil;
      if Assigned(ACallback) then
        ACallback(Self, LId, not ASuccess, AError);
    end);
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
begin
  Result := -1;
end;

function TPasCodeInsightManager.AsyncGotoDefinition(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBack): Integer;
var
  LId: Integer;
begin
  Inc(FNextId);
  LId := FNextId;
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not Assigned(ACallBack) then
        Exit;
      if ASuccess and (Length(AHits) > 0) then
        ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row, False, '')
      else
        ACallBack(Self, LId, '', 0, True, AError);
    end);
  Result := LId;
end;

function TPasCodeInsightManager.AsyncGotoDefinitionEx(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBackEx): Integer;
var
  LId: Integer;
begin
  Inc(FNextId);
  LId := FNextId;
  // Bring-up diagnostic for the browse path (the mouse override stands down
  // when we are the provider, so this firing at all is the thing under
  // test), plus the raw parameters - completion's parameters proved
  // untrustworthy, and this is where the browse convention gets pinned.
  // Remove once a live run confirms where the jump lands.
  LogDiagnostic(Format('browse via Code Insight manager: %s raw params (%d,%d)',
    [ExtractFileName(AFileName), ALine, ACharIndex]));
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not Assigned(ACallBack) then
        Exit;
      if ASuccess and (Length(AHits) > 0) then
        // Col back to the 0-based char index the callback expects.
        ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row,
          AHits[0].Col - 1, False, '')
      else
        ACallBack(Self, LId, '', 0, 0, True, AError);
    end);
  Result := LId;
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
