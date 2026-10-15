unit PasTreeIdePlugin.CodeInsight;

{
  The Code Insight manager - since phase C (2026-08-22, COMPLETION.md) THE
  navigation and insight path of this plugin: the mouse-notifier Ctrl+Click
  override and the editor-menu takeover are deleted, and when the user
  selects "PasTree" as the Insight Provider the IDE routes completion,
  browse (Ctrl+Click), parameter insight and tooltips here.

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
      server answers from PasTree itself since 2026-08-21; the interim
      keyword provider is gone, and this unit did not have to change for it).
    - Browse (Ctrl+Click when WE are the provider) -> AsyncGotoDefinitionEx
      over the same LspDefinition path the current override uses - but
      returning the target to the IDE, which then navigates and keeps history
      itself. That is the migration seam.
    - Hint text (Tooltip Insight) -> AsyncGetHintText over the server's
      hover, stripped to tooltip plain text by the session - only while
      Tooltip symbol insight is OFF; with it on, our own popup is the hint
      and this one is declined (OfferHintInsight).
    - Parameter insight (Ctrl+Shift+Space, '(' and ',') ->
      AsyncInvokeParameterCodeInsight over textDocument/signatureHelp; the
      answer feeds both IOTACodeInsightParameterList views, and the active
      argument is recounted server-side per request (ParamIndex answers -1 =
      reinvoke) so it can never drift from the text.

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

/// <summary>
/// Logs to the Build tab, once per session, if the Tools > Options > Editor >
/// Source "Insight Provider" combobox does not name PasTree - completion,
/// browse and parameter insight all silently come from whichever other
/// provider is selected otherwise, and nothing else says so. Called after
/// every project open (TProjectOpenNotifier), which is a real point in time
/// to ask, unlike registration (InitializeCodeInsight runs before the user
/// could have chosen anything).
/// </summary>
procedure CheckInsightProviderSelected;

/// <summary>
/// Whether the manager registered here is the one the IDE is currently
/// asking - i.e. whether the user has selected "PasTree" in the Tools >
/// Options > Editor > Source "Insight Provider" combobox.
///
/// The Ctrl+Click override in PasTreeIdePlugin.GotoDeclaration stands down
/// when this is True: with PasTree selected, the IDE's own click chain ends
/// in AsyncGotoDefinitionEx here, so it already resolves through PasTree,
/// draws the Ctrl+hover underline and keeps history itself. Intercepting the
/// mouse as well would resolve the same position twice and push the history
/// entry twice.
/// </summary>
function PasTreeIsActiveInsightProvider: Boolean;

/// <summary>
/// Makes the IDE's Insight Provider agree with the settings' Code Insight
/// Manager choice (PasTreeInsightManagerEnabled), so the user never has to
/// find the combobox in Tools > Options > Editor > Source.
///
/// THROUGH THE ENVIRONMENT OPTION `InsightManager` (IOTAEnvironmentOptions.
/// Values), the live switch DeclarationInformation and ErrorInsightLevel are
/// flipped with. Measured on 37.0 (2026-10-13, AVImark): a string option
/// (tkLString) holding the selected manager's IDString - "Borland.CodeInsight.
/// LSP.Pascal" for DelphiLSP. A write reads back at once and is written
/// through to the registry (`Insight Manager` under Editor\Source Options\
/// Borland.EditOptions.Pascal) at once; the IDE's CURRENT manager follows
/// lazily, at the editor's next Code Insight turn - 1 s after the write it
/// still answered DelphiLSP, at 5 s PasTree, both ways. So "the current
/// manager is not ours right after the switch" is not a failure.
///
/// PasTree: registers the manager (InitializeCodeInsight) if it is not yet,
/// remembers the IDE's value under our key (SavedInsightManager) BEFORE writing
/// ours. RAD Studio: puts the remembered value back over OUR value only - a
/// provider picked in Tools > Options since is the user's. The manager stays
/// registered until the IDE restarts: unregistering one the IDE may still hold
/// as current is a crash risk nothing here needs to take. Called after the
/// dialog saves and once at package load; a value that does not read yet is
/// asked again by SyncInsightManagerChoice. FinalizeCodeInsight puts the IDE's
/// value back before unregistering, the marker kept for the next start.
/// </summary>
procedure ApplyInsightManagerChoice;

/// <summary>
/// Retries an ApplyInsightManagerChoice whose option did not read, and hands
/// its log line to the LSP log once a session can take it. Cheap when there
/// is nothing to do; called on every editor mouse move, beside
/// SyncErrorInsightChoice.
/// </summary>
procedure SyncInsightManagerChoice;

implementation

uses
  System.SysUtils,
  System.Types,
  System.UITypes,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Variants,
  System.Win.Registry,
  Winapi.Windows,
  Vcl.Graphics,
  ToolsAPI,
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.DcuNames,
  PasTreeIdePlugin.DcuSource,
  PasTreeIdePlugin.ResultRows,   // PaintSyntaxTextTyped, EditorSyntaxColor
  PasTreeIdePlugin.Settings;   // AdvancedLoggingEnabled, the type colour

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
{ Whether this manager answers the IDE's hint (Tooltip Insight) at all. Not
  while Tooltip symbol insight is ours: that hint is our own popup, shown
  under every provider, and the IDE's hint is quenched through
  DeclarationInformation - but only DelphiLSP's. With THIS manager selected
  the IDE asked it as well, and its plain-text answer ("constant -
  Winapi.Windows.pas:25534") came up under our popup (Alex, 2026-10-13, the
  first run with the manager selected since 0.51). }
function OfferHintInsight: Boolean;
begin
  Result := not TooltipSymbolInsightEnabled;
end;

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

const
  // GetIDString - and the value the environment option InsightManager is
  // given to select this manager (ApplyInsightManagerChoice).
  cOurManagerId = 'PasTreeIdePlugin.CodeInsight';

var
  // The teardown guard for async closures. A completion callback captures
  // the manager (Self) to fill FSymbols; if the LSP session dies during
  // package unload it FAILS every pending request synchronously, and by then
  // the manager may already be gone - the dangling-Self flavour of the AV
  // this project keeps a standing rule about. Checked FIRST in every closure
  // that touches manager state, before any Self dereference.
  GAlive: Boolean = False;
  // The IOTAHelpInsight readout runs once per session - see ProbeHelpInsight.
  GHelpInsightProbed: Boolean = False;
  // Edge-trigger for the "PasTree is not selected" line - see SetEnabled.
  GInsightWarned: Boolean = False;

{ ---------------------------------------------------------------------------
  The symbol list: one async answer, filtered synchronously ever after
  --------------------------------------------------------------------------- }

type
  TPasSymbolList = class(TInterfacedObject, IOTACodeInsightSymbolList,
    IOTACodeInsightSymbolList80)
  private
    FAll: TArray<TLspCompletionItem>;
    // FAll's labels upper-cased once, parallel to it - the filter's haystack.
    FUpper: TArray<string>;
    FVisible: TArray<Integer>;   // indices into FAll, after SetFilter
    FFilter: string;             // the last SetFilter's text
    FSortOrder: TOTASortOrder;
    procedure Rebuild(const AFilter: string);
  public
    { The text the viewer filters by - DrawLine underlines it in each name. }
    property Filter: string read FFilter;
    { The type names in the visible row I's detail - DrawLine paints them. }
    function TypeSpansOf(I: Integer): TArray<Integer>;
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
var
  LIdx: Integer;
begin
  inherited Create;
  FAll := AItems;
  FSortOrder := soAlpha;
  // Sorted ONCE, here: SetFilter runs per keystroke on the UI thread with
  // whole-RTL-sized lists, and both of Rebuild's passes preserve order - so
  // Rebuild never needs to sort, only scan. (soScope grouping, when it comes,
  // means a second precomputed permutation, not a per-keystroke sort.)
  TArray.Sort<TLspCompletionItem>(FAll,
    TComparer<TLspCompletionItem>.Construct(
      function(const A, B: TLspCompletionItem): Integer
      begin
        Result := CompareText(A.ItemLabel, B.ItemLabel);
      end));
  SetLength(FUpper, Length(FAll));
  for LIdx := 0 to High(FAll) do
    FUpper[LIdx] := UpperCase(FAll[LIdx].ItemLabel);
  Rebuild('');
end;

{ BY CONTAINMENT, NOT PREFIX - the native viewer's rule (Alex, 2026-10-13,
  AVImark): "fas" lists faSysFile, but also iefFast, TIEFastDrawing and
  CC_FPFASTCALL. Until 0.68.0 this kept only the labels STARTING with the
  filter, so the list was a fraction of DelphiLSP's for the same text - the
  server sends every name in scope and never filtered; this did. Prefix
  matches first, then the rest, each alphabetical, as the native list does. }
procedure TPasSymbolList.Rebuild(const AFilter: string);
var
  LIdx, LCount, LPos: Integer;
  LNeedle: string;
  LInner: TArray<Integer>;
  LInnerCount: Integer;
begin
  // Counted growth, not per-element appends: this runs per keystroke and
  // FAll can hold thousands of rows.
  SetLength(FVisible, Length(FAll));
  LCount := 0;
  if AFilter = '' then
  begin
    for LIdx := 0 to High(FAll) do
      FVisible[LIdx] := LIdx;
    Exit;
  end;
  LNeedle := UpperCase(AFilter);
  SetLength(LInner, Length(FAll));
  LInnerCount := 0;
  for LIdx := 0 to High(FAll) do
  begin
    LPos := Pos(LNeedle, FUpper[LIdx]);
    if LPos = 1 then
    begin
      FVisible[LCount] := LIdx;
      Inc(LCount);
    end
    else if LPos > 1 then
    begin
      LInner[LInnerCount] := LIdx;
      Inc(LInnerCount);
    end;
  end;
  for LIdx := 0 to LInnerCount - 1 do
    FVisible[LCount + LIdx] := LInner[LIdx];
  SetLength(FVisible, LCount + LInnerCount);
end;

procedure TPasSymbolList.Clear;
begin
  FAll := nil;
  FUpper := nil;
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

function TPasSymbolList.TypeSpansOf(I: Integer): TArray<Integer>;
begin
  if (I < 0) or (I > High(FVisible)) then
    Exit(nil);
  Result := FAll[FVisible[I]].TypeSpans;
end;

procedure TPasSymbolList.SetFilter(const FilterText: string);
begin
  FFilter := FilterText;
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
    // EnumMember: the native list calls an enum value a 'const' (it is one,
    // typed by its enum); 'value' was ours, and no Delphi word.
    20, 21: Result := 'const';
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
  // Help Insight for the selected row. HTML, not plain text: ToolsAPI's own
  // comment on this method is "Return documentation for the symbol, in HTML"
  // (ToolsAPI.pas:8506), and the IDE's Help Insight surfaces are HTML windows
  // styled by ObjRepos\HelpInsight.css - the plain rendering arrives there as
  // one collapsed paragraph. The plain text stays the fallback for a server
  // that sent no HTML fragment.
  //
  // This call arrives on the UI thread while the viewer is open, so it may
  // never round-trip (the sync-interface rule in clients/rad-studio/SPEC.md) -
  // which is exactly why the server sends documentation with EVERY item
  // instead of deferring it to a completionItem/resolve the IDE gives us no
  // moment to make.
  if (I < 0) or (I > High(FVisible)) then
    Exit('');
  Result := FAll[FVisible[I]].DocHtml;
  if Result = '' then
    Result := FAll[FVisible[I]].Doc;
end;

{ ---------------------------------------------------------------------------
  Parameter insight: one signatureHelp answer behind the IDE's two views
  --------------------------------------------------------------------------- }

{ 'const AName: string = Default' -> modifier/name/type/has-default. The
  labels were built by the server from the declaration's own source span, so
  the shape is real Pascal. }
procedure ParseParamLabel(const ALabel: string; out AModifier, AName,
  AType: string; out AHasDefault: Boolean);
var
  LText: string;
  LIdx: Integer;
begin
  AModifier := '';
  AType := '';
  LText := Trim(ALabel);
  LIdx := Pos(' ', LText);
  if LIdx > 0 then
  begin
    AModifier := Copy(LText, 1, LIdx - 1);
    if SameText(AModifier, 'const') or SameText(AModifier, 'var') or
       SameText(AModifier, 'out') then
      LText := Trim(Copy(LText, LIdx + 1, MaxInt))
    else
      AModifier := '';
  end;
  LIdx := Pos(':', LText);
  if LIdx > 0 then
  begin
    AName := Trim(Copy(LText, 1, LIdx - 1));
    AType := Trim(Copy(LText, LIdx + 1, MaxInt));
  end
  else
    AName := LText;
  AHasDefault := Pos('=', AType) > 0;
  if AHasDefault then
    AType := Trim(Copy(AType, 1, Pos('=', AType) - 1));
end;

type
  TPasParamQuery = class(TInterfacedObject, IOTACodeInsightParamQuery)
  private
    FSig: TLspSignatureItem;
    FRetVal: string;
  public
    constructor Create(const ASig: TLspSignatureItem);
    { IOTACodeInsightParamQuery }
    function GetQueryParamCount: Integer;
    function GetQueryRetVal: string;
    function GetQueryParamSymText(Index: Integer): string;
    function GetQueryParamTypeText(Index: Integer): string;
    function GetQueryParamHasDefaultVal(Index: Integer): Boolean;
    function GetQueryParamInvokeTypeText(Index: Integer): string;
  end;

  TPasParameterList = class(TInterfacedObject, IOTACodeInsightParameterList,
    IOTACodeInsightParameterList100)
  private
    FHelp: TLspSignatureHelp;
    function ActiveParams: TArray<string>;
  public
    constructor Create(const AHelp: TLspSignatureHelp);
    property Help: TLspSignatureHelp read FHelp;
    { IOTACodeInsightParameterList }
    procedure GetParameterQuery(ProcIndex: Integer;
      out ParamQuery: IOTACodeInsightParamQuery);
    function GetParamDelimiter: Char;
    function GetProcedureCount: Integer;
    function GetProcedureParamsText(I: Integer): string;
    { IOTACodeInsightParameterList100 }
    function GetParmPos(Index: Integer): TOTACharPos;
    function GetParmCount: Integer;
    function GetParmName(Index: Integer): string;
    function GetParmHint(Index: Integer): string;
    function GetCallStartPos: TOTACharPos;
    function GetCallEndPos: TOTACharPos;
  end;

constructor TPasParamQuery.Create(const ASig: TLspSignatureItem);
var
  LIdx: Integer;
begin
  inherited Create;
  FSig := ASig;
  // The result type is the label's tail after the params' closing '): ' (or
  // after 'Name: ' for a parameterless function).
  //
  // THE FALLBACK ONLY APPLIES WITH NO PARAMETER LIST AT ALL, which is the case
  // the sentence above describes and the condition the first version left out.
  // A PROCEDURE with typed parameters has no '): ' either -
  // `Foo(const S: string; Index: Integer)` - so the fallback found the first
  // PARAMETER's ': ' inside the brackets and handed the IDE's parameter
  // insight `string; Index: Integer)` as the routine's result type.
  LIdx := FSig.SigLabel.LastIndexOf('): ');
  if LIdx >= 0 then
    FRetVal := FSig.SigLabel.Substring(LIdx + 3)
  else if FSig.SigLabel.IndexOf('(') < 0 then
  begin
    LIdx := FSig.SigLabel.IndexOf(': ');
    if LIdx >= 0 then
      FRetVal := FSig.SigLabel.Substring(LIdx + 2);
  end;
end;

function TPasParamQuery.GetQueryParamCount: Integer;
begin
  Result := Length(FSig.Params);
end;

function TPasParamQuery.GetQueryRetVal: string;
begin
  Result := FRetVal;
end;

function TPasParamQuery.GetQueryParamSymText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LName;
  end;
end;

function TPasParamQuery.GetQueryParamTypeText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LType;
  end;
end;

function TPasParamQuery.GetQueryParamHasDefaultVal(Index: Integer): Boolean;
var
  LModifier, LName, LType: string;
begin
  Result := False;
  if (Index >= 0) and (Index <= High(FSig.Params)) then
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, Result);
end;

function TPasParamQuery.GetQueryParamInvokeTypeText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LModifier;
  end;
end;

constructor TPasParameterList.Create(const AHelp: TLspSignatureHelp);
begin
  inherited Create;
  FHelp := AHelp;
end;

function TPasParameterList.ActiveParams: TArray<string>;
begin
  Result := nil;
  if (FHelp.ActiveSignature >= 0) and
     (FHelp.ActiveSignature <= High(FHelp.Signatures)) then
    Result := FHelp.Signatures[FHelp.ActiveSignature].Params;
end;

procedure TPasParameterList.GetParameterQuery(ProcIndex: Integer;
  out ParamQuery: IOTACodeInsightParamQuery);
begin
  ParamQuery := nil;
  if (ProcIndex >= 0) and (ProcIndex <= High(FHelp.Signatures)) then
    ParamQuery := TPasParamQuery.Create(FHelp.Signatures[ProcIndex]);
end;

function TPasParameterList.GetParamDelimiter: Char;
begin
  Result := ';';
end;

function TPasParameterList.GetProcedureCount: Integer;
begin
  Result := Length(FHelp.Signatures);
end;

function TPasParameterList.GetProcedureParamsText(I: Integer): string;
begin
  // Per the interface doc: the parameters of procedure I, "delimited by a
  // line ending".
  Result := '';
  if (I >= 0) and (I <= High(FHelp.Signatures)) then
    Result := string.Join(sLineBreak, FHelp.Signatures[I].Params);
end;

function TPasParameterList.GetParmPos(Index: Integer): TOTACharPos;
begin
  // Per-parameter source positions are undocumented; the call's own open
  // paren is the one position the interim provider knows. Bring-up decides
  // whether the viewer needs more.
  Result := GetCallStartPos;
end;

function TPasParameterList.GetParmCount: Integer;
begin
  Result := Length(ActiveParams);
end;

function TPasParameterList.GetParmName(Index: Integer): string;
var
  LParams: TArray<string>;
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  LParams := ActiveParams;
  if (Index >= 0) and (Index <= High(LParams)) then
  begin
    ParseParamLabel(LParams[Index], LModifier, LName, LType, LHasDefault);
    Result := LName;
  end;
end;

function TPasParameterList.GetParmHint(Index: Integer): string;
var
  LParams: TArray<string>;
begin
  Result := '';
  LParams := ActiveParams;
  if (Index >= 0) and (Index <= High(LParams)) then
    Result := LParams[Index];
end;

function TPasParameterList.GetCallStartPos: TOTACharPos;
begin
  Result.Line := FHelp.CallRow;
  Result.CharIndex := FHelp.CallCol - 1;   // TOTACharPos is zero-based
end;

function TPasParameterList.GetCallEndPos: TOTACharPos;
begin
  // The call is still being typed - there is no closing paren to report;
  // the open paren is the only honest fixed point.
  Result := GetCallStartPos;
end;

{ ---------------------------------------------------------------------------
  The manager
  --------------------------------------------------------------------------- }

type
  TPasCodeInsightManager = class(TInterfacedObject, IOTACodeInsightManager100,
    IOTACodeInsightManager, IOTACodeInsightSelection,
    IOTAAsyncCodeInsightManager, IOTAAsyncCodeInsightManager290,
    IOTACodeInsightManager90, INTACustomDrawCodeInsightViewer,
    IOTAPrimaryCodeInsightManager)
  private
    FEnabled: Boolean;
    // GetContext's first call this session went to the log - see there.
    FContextAsked: Boolean;
    FSymbols: IOTACodeInsightSymbolList;
    // The same object as FSymbols, typed - the callers that need item fields
    // the interface does not expose. The interface reference owns the
    // lifetime; this one is only ever read alongside it. (Those callers all
    // read the SHOWN pair below, not this one - see there.)
    FSymbolsObj: TPasSymbolList;
    // The list the VIEWER actually pulled (GetSymbolList) - a late async
    // answer may replace FSymbols while a popup built from the previous
    // list is still open, and Done's auto-parenthesis must consult what the
    // user was LOOKING AT, not the newest answer. The interface reference
    // keeps the shown object alive.
    FShownSymbols: IOTACodeInsightSymbolList;
    FShownObj: TPasSymbolList;
    // The last signatureHelp answer, behind the two views the IDE pulls
    // (GetParameterList / the 100 interface). Same pairing rule as
    // FSymbols/FSymbolsObj.
    FParamList: IOTACodeInsightParameterList;
    FParamListObj: TPasParameterList;
    FActiveParamId: Integer;
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
    { IOTACodeInsightManager90 - the viewer's Help Insight pane, in HTML }
    function GetHelpInsightHtml: WideString;
    { INTACustomDrawCodeInsightViewer }
    procedure DrawLine(Index: Integer; Canvas: TCanvas; var Rect: TRect;
      DrawingHintText: Boolean; DoDraw: Boolean; var DefaultDraw: Boolean);
    { IOTAPrimaryCodeInsightManager - see GetContext }
    function GetContext: TOTACodeCompletionContext;
    { IDispatch, which IOTAPrimaryCodeInsightManager derives from: nothing
      here is scriptable, every call answers E_NOTIMPL. }
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
      stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
      stdcall;
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
  Result := cOurManagerId;
end;

function TPasCodeInsightManager.GetDisplayName: string;
begin
  Result := 'PasTree';   // the Tools > Options "Insight Provider" combobox
end;

function TPasCodeInsightManager.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

{ NOT where "is PasTree selected" is answered - tried that first, and the IDE
  does not call this with False for a manager the user never selected at all
  (only ever observed True, on selection). CheckInsightProviderSelected below
  asks IOTACodeInsightServices60 directly instead. }
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
  // #0 completion, #1 parameters (signatureHelp), #2 browse, #3 hints
  // (Tooltip Insight, over the server's hover), plus the trigger characters
  // '.' (completion) and '('/',' (parameter insight re-anchoring).
  Allow := (Key = #0) or (Key = #1) or (Key = #2) or
    ((Key = #3) and OfferHintInsight) or
    (Key = '.') or (Key = '(') or (Key = ',');
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
  // Not a phase-C question any more (phase C shipped 2026-08-22): it stays
  // False until the sync GotoDefinition can answer, which is a decision about
  // this interface, not about the migration.
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
  ParameterList := FParamList;   // the last signatureHelp answer, or nil
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
    #1: CodeInsightType := citParameterCodeInsight;
    #3: CodeInsightType := citHintCodeInsight;
    '.':
      begin
        // The same trigger character the server advertises to LSP clients.
        CodeInsightType := citCodeInsight;
        InvokeType := itTimer;
      end;
    '(', ',':
      begin
        // Typing into an argument list re-anchors the parameter hint - the
        // same trigger characters the server advertises for signatureHelp.
        CodeInsightType := citParameterCodeInsight;
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
  // Anchor the hint at the call's own open paren when we know it.
  if Assigned(FParamListObj) and FParamListObj.Help.Valid then
  begin
    EdPos.Line := FParamListObj.Help.CallRow;
    EdPos.Col := FParamListObj.Help.CallCol;
  end;
end;

function TPasCodeInsightManager.ParameterCodeInsightParamIndex(
  EdPos: TOTAEditPos): Integer;
begin
  // -1 = "reinvoke me" (the interface's own protocol): the server recounts
  // the active argument from the live text, which is always right, where a
  // cached index would drift the moment the user edits mid-call.
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

function TPasCodeInsightManager.GetHelpInsightHtml: WideString;
var
  LServices: IOTACodeInsightServices;
  LViewer: IOTACodeInsightViewer;
  LSelected: string;
  LItem: TLspCompletionItem;
begin
  // The viewer's own Help Insight pane for the SELECTED row - HTML by
  // contract ("Retrieves help insight information for the current Viewer's
  // selected item", ToolsAPI.pas:8864), and the same fragment
  // GetSymbolDocumentation hands over, so the two surfaces cannot disagree.
  //
  // Read from the list the viewer is DISPLAYING (FShownObj), for the same
  // reason Done does: a late async answer may have replaced FSymbolsObj under
  // the open popup, and the pane must describe the row the user is looking at.
  Result := '';
  if not GAlive or not Assigned(FShownObj) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LViewer := nil;
  LServices.GetViewer(LViewer);
  if not Assigned(LViewer) then
    Exit;
  LSelected := LViewer.GetSelectedString;
  if (LSelected = '') or not FShownObj.TryGetByName(LSelected, LItem) then
    Exit;
  if LItem.DocHtml <> '' then
    Result := LItem.DocHtml
  else
    Result := LItem.Doc;
end;

function TPasCodeInsightManager.GetOptionSetName: string;
begin
  { The Code Insight options are stored PER OPTION SET, and the set name is
    the registry subkey: under <BaseRegistryKey>\Code Insight the IDE keeps
    `Borland.EditOptions.Pascal` (the classic Pascal provider) and
    `Borland.EditOptions.Borland.CodeInsight.LSP.Pascal` (DelphiLSP), each
    holding `Help Insight`, `Auto Invoke`, `CodeCompleteAutoParens`,
    `Declaration Information` and the rest. Returning '' - which this did
    until 2026-08-23 - means our provider has NO set, so every one of those
    settings reads as its bare default for us, whatever the user ticked.
    That is the first suspect for a feature that "should work because the
    method exists": the method is called, the option behind it is off.

    We name the CLASSIC Pascal set deliberately, rather than inventing one:
    the whole point of this provider is to behave like the native one
    (user, 2026-08-21: "один в один"), and a set of our own would start with
    every box unticked and would have to be configured twice. The cost is
    that changes made on our page land in the shared set - acceptable while
    the two providers mean the same thing by each option, and the line to
    revisit if they ever do not. }
  Result := 'Borland.EditOptions.Pascal';
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
  Result := (AInsightType in [citCodeInsight, citParameterCodeInsight,
    citBrowseCodeInsight]) or
    ((AInsightType = citHintCodeInsight) and OfferHintInsight);
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
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  FActiveParamId := LId;
  LInInvoke := True;
  // Position parameters trusted per the browse-confirmed convention
  // (1-based line, 0-based char index).
  LspSignatureHelp(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHelp: TLspSignatureHelp;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      if FActiveParamId <> LId then
        Exit;   // superseded by a newer invocation
      FActiveParamId := 0;
      if ASuccess and AHelp.Valid then
      begin
        FParamListObj := TPasParameterList.Create(AHelp);
        FParamList := FParamListObj;
      end
      else
      begin
        FParamList := nil;
        FParamListObj := nil;
      end;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallback) then
            ACallback(Self, LId, AHelp.ActiveSignature,
              not (ASuccess and AHelp.Valid), AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

{ ONE-TIME READOUT, first hover of a session: does the active module offer
  IOTAHelpInsight? That interface ("Allows Help Insight to show documentation
  information from the current symbol in the code editor. Query for it from the
  IOTAModule. If it isn't present, then this feature is not present",
  ToolsAPI.pas:6787) is the OTHER way into the editor's Help Insight window -
  the one that takes a `member` document rather than a hint string. It is
  queried FROM the module, so if the IDE's own module already implements it the
  path is occupied and not ours to take, exactly as the 2026-08-22 file-trait
  spike found for IOTAModuleErrors. Answering that question costs one Supports
  call, and guessing it has already cost this project one spike. }
procedure ProbeHelpInsight;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LHelpInsight: IOTAHelpInsight;

  // INTO THE SERVER LOG, not the Build tab. This is a readout: it answers a
  // question about the IDE that mattered while the feature was being designed
  // and may matter again in a year, and it says nothing the user can act on
  // today. The panel is for things worth interrupting somebody with (user,
  // 2026-08-29 - and the same call retired two other lines that day).
  procedure Readout(const AText: string);
  begin
    if not LspLogToServer('IOTAHelpInsight probe: ' + AText) then
      // No server yet, so this went nowhere: unmark, and the next hover asks
      // again. A readout that reports into the void is not a readout.
      GHelpInsightProbed := False;
  end;

begin
  if GHelpInsightProbed then
    Exit;
  GHelpInsightProbed := True;
  // Wrapped whole: the first version of this probe produced NO line at all on
  // a live run (user, 2026-08-23). Everything here talks to IDE objects we do
  // not own - Supports on the module, and IsEnabled is `safecall` on an
  // IDispatch, so a raise on the other side arrives as an exception here -
  // and an exception thrown out of a hover would be swallowed by the IDE with
  // the probe silently never reporting. A readout that can fail silently is
  // not a readout.
  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices)
    then
    begin
      Readout('no IOTAModuleServices');
      Exit;
    end;
    LModule := LModuleServices.CurrentModule;
    if not Assigned(LModule) then
    begin
      GHelpInsightProbed := False;   // no module yet - ask again next hover
      Exit;
    end;
    if not Supports(LModule, IOTAHelpInsight, LHelpInsight) then
    begin
      Readout('absent on module ' + LModule.FileName
        + ' - the hint string is the only editor Help Insight feed for us');
      Exit;
    end;
    // Two lines, not one: presence is the finding, and IsEnabled is a second
    // call that may fail on its own. Reported separately so a failure in the
    // second cannot hide the first.
    Readout('PRESENT on module ' + LModule.FileName
      + ' - the editor Help Insight window has a native feed');
    try
      Readout('IsEnabled = ' + BoolToStr(LHelpInsight.IsEnabled, True));
    except
      on E: Exception do
        Readout('IsEnabled raised ' + E.ClassName + ': ' + E.Message);
    end;
  except
    on E: Exception do
      Readout('raised ' + E.ClassName + ': ' + E.Message);
  end;
end;

function TPasCodeInsightManager.AsyncGetHintText(HintLine, HintCol: Integer;
  ACallBack: TOTAHintTextCallBack): Integer;
var
  LId: Integer;
  LView: IOTAEditView;
  LFileName: string;
  LInInvoke: Boolean;
begin
  ProbeHelpInsight;
  // Declined above already while our own hint is on; this is the backstop for
  // an IDE that asks anyway.
  if not OfferHintInsight then
    Exit(-1);
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
          begin
            // A COMPILED UNIT: the IDE will open whatever file name it is
            // handed, and it cannot open a .dcu. The generated tab is made
            // first (one more asynchronous hop, only the first time) and
            // the IDE is handed its module name instead - it finds the open
            // module by that name and lands on the line like any other.
            if IsDcuPath(AHits[0].FilePath) then
            begin
              EnsureDcuModule(AHits[0].FilePath,
                procedure(AModuleName: string)
                begin
                  if not (GAlive and Assigned(ACallBack)) then
                    Exit;
                  if AModuleName <> '' then
                    ACallBack(Self, LId, AModuleName, AHits[0].Row,
                      AHits[0].Col - 1, False, '')
                  else
                    ACallBack(Self, LId, '', 0, 0, True,
                      'the .dcu could not be read - see the Build tab');
                end);
              Exit;
            end;
            // Col back to the 0-based char index the callback expects.
            ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row,
              AHits[0].Col - 1, False, '');
          end
          else
            ACallBack(Self, LId, '', 0, 0, True, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

{ A detail's overload tail ` (+N)` cut off into ATail - it is ours, not code,
  and is drawn dim. Matched from the END: a parameter list could contain a
  literal ' (+' of its own. }
procedure SplitOverloadTail(var ADetail: string; out ATail: string);
var
  LCut: Integer;
begin
  ATail := '';
  LCut := ADetail.LastIndexOf(' (+');
  if (LCut >= 0) and ADetail.EndsWith(')') and
     (LCut >= ADetail.Length - 8) then
  begin
    ATail := ADetail.Substring(LCut);
    ADetail := ADetail.Substring(0, LCut);
  end;
end;

{ The row as the hover hint paints a declaration (Alex, 2026-10-13: "paint
  everything the way the tooltips do"): the stock LAYOUT - fixed class
  column, bold name, the detail glued after it - with the hint's COLOURS. The
  class word in the editor's reserved-word colour; the detail through
  PaintSyntaxTextTyped, the editor's own palette for keywords, numbers,
  strings and symbols, with the type names the server marked (data.typeSpans)
  in the Highlighting tab's colour and style. Until 0.68.0 a hand-rolled
  tokenizer coloured `:`-to-`;` in a violet and values in blue, which matched
  neither the editor nor the hint. Colours stay on the selected row, as the
  native window keeps them. }
procedure TPasCodeInsightManager.DrawLine(Index: Integer; Canvas: TCanvas;
  var Rect: TRect; DrawingHintText: Boolean; DoDraw: Boolean;
  var DefaultDraw: Boolean);
const
  cPad = 4;
var
  LClass, LName, LDetail, LTail: string;
  LColWidth, LX, LTop, LMatch: Integer;
  LRun: string;
  LBase, LDim, LTypeColor: TColor;
  LTypeStyle: TFontStyles;
  LSpans: TArray<Integer>;
begin
  // FShownSymbols, NOT FSymbols - the list the viewer is actually painting,
  // for the same reason Done and GetHelpInsightHtml read it: a late async
  // answer replaces FSymbols under a popup built from the previous list, and a
  // failed re-invoke nils it outright. Indexing the newest list to draw rows
  // of the displayed one paints the wrong text where the two happen to be the
  // same length.
  //
  // A row past the list's end is drawn BLANK, never handed back with
  // DefaultDraw: the IDE's DefaultViewerDrawLine resolves the same index
  // through its own SymbolListAndSymbolFromIndex, which walks off the end of
  // its symbol-list TInterfaceList and raises "List index out of bounds"
  // (Alex, 2026-10-15, AVImarkServer, arrowing through a 51-item member list
  // - one request, no late answer). The viewer's row count can run ahead of
  // the list's for a paint, after a SetFilter shrank it; the next recount
  // removes the row.
  if not Assigned(FShownSymbols) or (Index < 0) or
     (Index >= FShownSymbols.Count) then
  begin
    DefaultDraw := False;
    Exit;
  end;
  DefaultDraw := False;
  LClass := FShownSymbols.SymbolClassText[Index];
  LName := FShownSymbols.SymbolText[Index];
  LDetail := FShownSymbols.SymbolTypeText[Index];
  LSpans := nil;
  if Assigned(FShownObj) then
    LSpans := FShownObj.TypeSpansOf(Index);

  // The class column is fixed-width - rows must align down the list, and
  // 'constructor' is the widest word the column ever holds.
  Canvas.Font.Style := [];
  LColWidth := Canvas.TextWidth('constructor') + 2 * cPad;

  if not DoDraw then
  begin
    // Measured with the runs' own styles - a bold `const` in a parameter
    // list is wider than a plain TextWidth of the detail.
    Canvas.Font.Style := [TFontStyle.fsBold];
    LX := Canvas.TextWidth(LName);
    SplitOverloadTail(LDetail, LTail);
    PaintSyntaxTextTyped(Canvas, LX, 0, LDetail, Canvas.Font.Color,
      LSpans, TypeHighlightColor, TypeHighlightStyle, False);
    Canvas.Font.Style := [];
    Inc(LX, Canvas.TextWidth(LTail));
    Rect.Right := Rect.Left + LColWidth + LX + 3 * cPad;
    Exit;
  end;

  // The viewer prepared Canvas for this row (highlight brush on the
  // selected row) - LBase is whatever it chose. Colors STAY on the selected
  // row: the native window keeps its signature colors under the highlight
  // bar, and the first pass here that flattened them read as the coloring
  // "disappearing" on selection.
  LBase := Canvas.Font.Color;
  LDim := clNavy;
  // Type names as the hint paints them: the Highlighting tab's colour and
  // style, or the editor's identifier colour when type colouring is off.
  if TypeHighlightEnabled then
    LTypeColor := TypeHighlightColor
  else
    LTypeColor := clNone;
  LTypeStyle := TypeHighlightStyle;

  LTop := Rect.Top + (Rect.Height - Canvas.TextHeight('Ag')) div 2;
  LX := Rect.Left + cPad;

  // The class word in the editor's reserved-word colour, as the hint draws
  // its lead - regular weight, so the fixed column measured above holds.
  Canvas.Font.Color := EditorSyntaxColor(atReservedWord, LDim);
  Canvas.TextOut(LX, LTop, LClass);
  LX := Rect.Left + LColWidth;

  // The name, bold, with the part the filter matched UNDERLINED - the native
  // window's mark, and the only way to see why a row whose name does not start
  // with the typed text is listed (the filter matches anywhere, see
  // TPasSymbolList.Rebuild). Drawn in three runs so the underline covers the
  // match alone; a name without one (no filter yet) is a single run.
  Canvas.Font.Color := LBase;
  Canvas.Font.Style := [TFontStyle.fsBold];
  LMatch := 0;
  if Assigned(FShownObj) and (FShownObj.Filter <> '') then
    LMatch := Pos(UpperCase(FShownObj.Filter), UpperCase(LName));
  if LMatch > 0 then
  begin
    LRun := Copy(LName, 1, LMatch - 1);
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
    LRun := Copy(LName, LMatch, Length(FShownObj.Filter));
    Canvas.Font.Style := [TFontStyle.fsBold, TFontStyle.fsUnderline];
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
    Canvas.Font.Style := [TFontStyle.fsBold];
    LRun := Copy(LName, LMatch + Length(FShownObj.Filter), MaxInt);
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
  end
  else
  begin
    Canvas.TextOut(LX, LTop, LName);
    Inc(LX, Canvas.TextWidth(LName));
  end;
  Canvas.Font.Style := [];

  if LDetail <> '' then
  begin
    SplitOverloadTail(LDetail, LTail);
    PaintSyntaxTextTyped(Canvas, LX, LTop, LDetail, LBase, LSpans,
      LTypeColor, LTypeStyle, True);
    if LTail <> '' then
    begin
      Canvas.Font.Color := LDim;   // '(+N)' is ours, not code - stays dim
      Canvas.Font.Style := [];
      Canvas.TextOut(LX, LTop, LTail);
    end;
  end;
  Canvas.Font.Color := LBase;   // leave the canvas the way the viewer set it
  Canvas.Font.Style := [];
end;

procedure TPasCodeInsightManager.AsyncParameterCodeInsightParamIndex(
  const AFileName: string; ALine, ACharIndex: Integer;
  ACallBack: TOTAParamIndexCallBack);
var
  LInInvoke: Boolean;
begin
  // The IDE asks this while the hint is up and the user types: recount the
  // active argument from the live text - a fresh signatureHelp round trip,
  // which the overlay pipeline answers in milliseconds.
  LInInvoke := True;
  LspSignatureHelp(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHelp: TLspSignatureHelp;
      const AError: string)
    begin
      if not GAlive then
        Exit;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallBack) then
            if ASuccess and AHelp.Valid then
              ACallBack(Self, AHelp.ActiveParam)
            else
              ACallBack(Self, -1);
        end);
    end);
  LInInvoke := False;
end;

procedure TPasCodeInsightManager.AsyncOperationCanceled(AId: Integer);
begin
  // Drop the callback gate; LspSession's supersede-cancel already told the
  // server the moment a newer request went out.
  if FActiveId = AId then
    FActiveId := 0;
  if FActiveHintId = AId then
    FActiveHintId := 0;
  if FActiveParamId = AId then
    FActiveParamId := 0;
end;

{ THE PRIMARY-MANAGER CONTRACT. ToolsAPI documents that alternate managers -
  Code Templates is one, registered beside every provider - "may query the
  current manager from the services to get invocation context information"
  through IOTAPrimaryCodeInsightManager. Until 0.68.0 this manager did not
  implement it, and with PasTree selected the IDE crashed twice in the Code
  Templates manager's own GetHelpInsightHtml, from the completion list's
  Help Insight timer (Alex, 2026-10-13; our BPL was not on the stack, and no
  AV was seen while DelphiLSP, a primary manager, was selected). ccAny - the
  invocation filters nothing - is the honest answer for a list that offers
  every name in scope. The first question of a session is logged, so whether
  the templates manager really asks is on record. }
function TPasCodeInsightManager.GetContext: TOTACodeCompletionContext;
begin
  Result := ccAny;
  if not FContextAsked then
  begin
    FContextAsked := True;
    LspLogToServer('code insight: an alternate manager asked the invocation'
      + ' context (IOTAPrimaryCodeInsightManager), answered ccAny');
  end;
end;

function TPasCodeInsightManager.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.GetTypeInfo(Index, LocaleID: Integer;
  out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.GetIDsOfNames(const IID: TGUID;
  Names: Pointer; NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.Invoke(DispID: Integer; const IID: TGUID;
  LocaleID: Integer; Flags: Word; var Params; VarResult, ExcepInfo,
  ArgErr: Pointer): HResult;
begin
  Result := E_NOTIMPL;
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
  // NOT ANNOUNCED. This used to say "registered - now select PasTree under
  // Tools > Options ...", loud on purpose because picking the provider is the
  // step people miss. It is the wrong trade at every IDE start after the
  // first: the provider is already selected, so the line is a step report
  // nobody needs, and this panel earns its keep only if what appears in it is
  // worth reading. Log failures, not steps.
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

{ ---------------------------------------------------------------------------
  Selecting the Insight Provider - see ApplyInsightManagerChoice
  --------------------------------------------------------------------------- }

const
  cEnvInsightManager = 'InsightManager';
  // What RAD Studio selects for Delphi, put back when nothing was remembered.
  cDelphiLspManagerId = 'Borland.CodeInsight.LSP.Pascal';
  // Under <BaseRegistryKey>\PasTree, the settings' own key.
  cSettingsKey = 'PasTree';
  cValueSavedInsightManager = 'SavedInsightManager';
  cApplyRetryMs = 1000;

var
  // ApplyInsightManagerChoice's option did not read: retried no sooner than
  // GProviderRetryAt by SyncInsightManagerChoice. Reported once.
  GProviderPending: Boolean = False;
  GProviderRetryAt: UInt64 = 0;
  GProviderUnreadableNoted: Boolean = False;
  // The last line for the LSP log, until a session takes it - the call at
  // package load runs before any project is open.
  GProviderLogLine: string = '';

procedure ProviderLog(const AText: string);
begin
  GProviderLogLine := 'insight provider: ' + AText;
  if LspLogToServer(GProviderLogLine) then
    GProviderLogLine := '';
end;

{ A failure: the provider the IDE uses now disagrees with the settings, so
  it is worth the Build tab as well as the log. }
procedure ProviderFailure(const AText: string);
var
  LMessages: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessages) then
    LMessages.AddTitleMessage('[pastree] could not set the Insight Provider: '
      + AText);
  ProviderLog('FAILED: ' + AText);
end;

function EnvOptions: IOTAEnvironmentOptions;
var
  LServices: IOTAServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    Result := LServices.GetEnvironmentOptions;
end;

function OpenOurKey(AReg: TRegistry): Boolean;
var
  LServices: IOTAServices;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  AReg.RootKey := HKEY_CURRENT_USER;
  Result := AReg.OpenKey(IncludeTrailingPathDelimiter(
    LServices.GetBaseRegistryKey) + cSettingsKey, True);
end;

function ReadSavedManager: string;
var
  LReg: TRegistry;
begin
  Result := '';
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    if OpenOurKey(LReg) and LReg.ValueExists(cValueSavedInsightManager) then
      Result := LReg.ReadString(cValueSavedInsightManager);
  finally
    LReg.Free;
  end;
end;

{ '' deletes the marker. }
procedure WriteSavedManager(const AValue: string);
var
  LReg: TRegistry;
begin
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    if OpenOurKey(LReg) then
      if AValue = '' then
        LReg.DeleteValue(cValueSavedInsightManager)
      else
        LReg.WriteString(cValueSavedInsightManager, AValue);
  finally
    LReg.Free;
  end;
end;

{ The provider PasTree replaced: the marker, or DelphiLSP without one. }
function ManagerToRestore: string;
begin
  Result := ReadSavedManager;
  if (Result = '') or SameText(Result, cOurManagerId) then
    Result := cDelphiLspManagerId;
end;

procedure ApplyInsightManagerChoice;
var
  LWant: Boolean;
  LOptions: IOTAEnvironmentOptions;
  LBefore, LAfter, LRestore: string;
begin
  GProviderPending := False;
  try
    LWant := PasTreeInsightManagerEnabled;
    // Nothing of ours anywhere: nothing to do or say.
    if not LWant and not Assigned(GManager) and (ReadSavedManager = '') then
      Exit;
    if LWant and not Assigned(GManager) then
      InitializeCodeInsight;
    LOptions := EnvOptions;
    LBefore := '';
    if Assigned(LOptions) then
      LBefore := Trim(VarToStrDef(LOptions.Values[cEnvInsightManager], ''));
    if LBefore = '' then
    begin
      // A value we cannot read is one we cannot put back: leave the IDE's
      // provider alone for now and ask again - it may not be loaded yet.
      GProviderPending := True;
      GProviderRetryAt := GetTickCount64 + cApplyRetryMs;
      if not GProviderUnreadableNoted then
      begin
        GProviderUnreadableNoted := True;
        ProviderLog('the IDE''s ' + cEnvInsightManager
          + ' does not read yet - asked again');
      end;
      Exit;
    end;
    if LWant then
    begin
      if SameText(LBefore, cOurManagerId) then
      begin
        ProviderLog('PasTree, already selected');
        Exit;
      end;
      // Remembered BEFORE the switch: the other order, interrupted, loses
      // the user's provider.
      WriteSavedManager(LBefore);
      LOptions.Values[cEnvInsightManager] := cOurManagerId;
      LAfter := Trim(VarToStrDef(LOptions.Values[cEnvInsightManager], ''));
      if SameText(LAfter, cOurManagerId) then
        ProviderLog('PasTree selected in place of "' + LBefore + '"')
      else
        ProviderFailure('"' + cOurManagerId + '" was written over "' + LBefore
          + '" and the option reads "' + LAfter + '"');
    end
    else
    begin
      // Only over OUR value: a provider the user has picked since in
      // Tools > Options is theirs, and wins.
      if SameText(LBefore, cOurManagerId) then
      begin
        LRestore := ManagerToRestore;
        LOptions.Values[cEnvInsightManager] := LRestore;
        ProviderLog('RAD Studio - put back "' + LRestore + '"; PasTree stays'
          + ' registered until the IDE restarts');
      end
      else
        ProviderLog('RAD Studio - "' + LBefore + '" is the user''s, kept');
      WriteSavedManager('');
    end;
  except
    on E: Exception do
      ProviderFailure(E.ClassName + ': ' + E.Message);
  end;
end;

procedure SyncInsightManagerChoice;
begin
  if (GProviderLogLine <> '') and LspLogToServer(GProviderLogLine) then
    GProviderLogLine := '';
  if GProviderPending and (GetTickCount64 >= GProviderRetryAt) then
    ApplyInsightManagerChoice;
end;

{ At unload: the IDE's own provider back over ours, the marker kept. The
  option writes through to the registry at once (measured 2026-10-13), so
  without this an IDE started without the package would find a provider that
  does not exist; with it, the next start selects PasTree again. }
procedure RestoreProviderAtUnload;
var
  LOptions: IOTAEnvironmentOptions;
  LRestore: string;
begin
  try
    LOptions := EnvOptions;
    if not Assigned(LOptions) or not SameText(Trim(VarToStrDef(
      LOptions.Values[cEnvInsightManager], '')), cOurManagerId) then
      Exit;
    LRestore := ManagerToRestore;
    LOptions.Values[cEnvInsightManager] := LRestore;
    LspLogToServer('insight provider: unload - put back "' + LRestore + '"');
  except
    // Unload: nobody to tell, and nothing worth an exception into the IDE.
  end;
end;

procedure FinalizeCodeInsight;
var
  LServices: IOTACodeInsightServices;
begin
  GProviderPending := False;
  // Before the unregister: the IDE must not be left selecting a manager that
  // is about to be gone.
  if Assigned(GManager) then
    RestoreProviderAtUnload;
  GAlive := False;
  if GManagerIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
      LServices.RemoveCodeInsightManager(GManagerIndex);
    GManagerIndex := -1;
  end;
  GManager := nil;
end;

procedure CheckInsightProviderSelected;
var
  LServices: IOTACodeInsightServices60;
  LCurrent: IOTACodeInsightManager;
  LSelection: IOTACodeInsightSelection;
  LCurrentName: string;
begin
  if not GAlive or not Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices60, LServices) then
    Exit;
  LServices.GetCurrentCodeInsightManager(LCurrent);
  if LCurrent = GManager then
  begin
    // Selected again after a warning earlier this session - the next time it
    // is switched away should say so again, not stay silent because of an
    // old flag.
    GInsightWarned := False;
    Exit;
  end;
  if GInsightWarned then
    Exit;
  LCurrentName := 'no provider';
  if Assigned(LCurrent) and Supports(LCurrent, IOTACodeInsightSelection,
    LSelection) then
    LCurrentName := '"' + LSelection.GetDisplayName + '"';
  // Into the server's log, under Advanced Logging only - never the Build
  // tab. Until completion is complete, not being the provider is the normal
  // state, and a Build-tab line about it was noise on every load (Alex,
  // 2026-09-21). GInsightWarned is set either way so the check stays cheap.
  if AdvancedLoggingEnabled then
    LspLogToServer(Format('PasTree is not selected as the Insight Provider - '
      + 'completion, browse and parameter insight come from %s instead '
      + 'until it is selected under Tools > Options > Editor > Source.',
      [LCurrentName]));
  GInsightWarned := True;
end;

end.
