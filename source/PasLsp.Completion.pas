unit PasLsp.Completion;

{
  THE COMPLETION SEAM (COMPLETION.md owns the plan): the ONLY unit that calls
  PasTree's completion engine. Everything around it - the capability, the
  handler, the plugin plumbing, the harness section - depends on this unit's
  answer shape alone, which is why swapping the interim keyword provider for
  the real engine (2026-08-21) changed nothing outside this file beyond the
  version gate.

  THE PIPELINE, per request (the recipe PasTree's own SemaCompleteSmoke
  proves): preprocess and parse the LIVE buffer text into a fresh OVERLAY
  model - so "as analyzed" and "as typed" are the same text, the engine's
  contract - then run TPasCompletion BRIDGED against the last-good project
  analysis, where every name that leaves the overlay (an inherited member,
  a used unit's type) resolves through the project. The overlay is fresh but
  alone; the project is complete but stale; the bridge is what makes locals
  typed `TStringList` complete with the real members. No project yet (first
  request racing the first analysis) degrades to standalone mode: locals,
  own-unit names and keywords still answer.

  Cost: one single-file preprocess+parse+analyze per request - the same
  per-keystroke path the PasTree demo highlighter runs, milliseconds on real
  units - never a closure rebuild (the handler's no-WaitAnalyzed rule).

  The REPLACE SPAN comes from the engine's caret primitive
  (TPasCaretInfo.PrefixColFrom/To): mid-word invocation spans the WHOLE word
  (the clangd behavior), empty-prefix positions collapse at the caret. That
  span is the one contract detail the harness pins hardest, Cyrillic columns
  included.
}

interface

uses
  PasTree.Types,
  PasTree.Platforms,
  PasTree.SourceManager,
  PasTree.Preprocessor,
  PasTree.Sema.Project,
  PasLsp.ClassComplete;

type
  TLspCompletionEntry = record
    ItemLabel: string;   // "Label" collides with the Delphi keyword
    Kind: Integer;       // LSP CompletionItemKind
    Detail: string;      // ': <declared type>' [' (+N)'] - display-verbatim
    SortText: string;    // bucket-ranked; see BucketSort
    { The routine's own head keyword ('constructor', 'operator', ...) when
      the engine knows one - richer than any LSP kind, so it rides the item's
      data field for OUR client (the RAD viewer's class column) while other
      clients simply ignore it. }
    HeadWord: string;
    { True when the item is a routine declared WITH parameters - what the
      RAD client's auto-parenthesis reads to insert `()` and step inside. }
    HasParams: Boolean;
    { The declaration's `///` doc block, RAW as the engine returns it (markers
      stripped, lines joined with #10) - rendered by PasLsp.XmlDoc at the
      point of display, so this record stays free of presentation. '' for
      keywords, unit names, builtins and undocumented declarations. }
    Doc: string;
  end;

  TLspSignatureItem = record
    SigLabel: string;         // 'Greet(const AName: string): string'
    Params: TArray<string>;   // one label per INDIVIDUAL parameter
  end;

  { textDocument/signatureHelp's answer, plus the call-open position our RAD
    client anchors its hint window to (1-based PasTree coords; Line 0 = the
    caret is not inside any call's arguments - the whole answer is empty
    then). }
  TLspSignatureHelpAnswer = record
    Signatures: TArray<TLspSignatureItem>;
    ActiveSignature: Integer;
    ActiveParam: Integer;
    CallLine: Integer;
    CallCol: Integer;
    Provider: string;
  end;

  TLspCompletionAnswer = record
    Items: TArray<TLspCompletionEntry>;
    { The replace span: the token every item replaces, on the request line.
      1-based UTF-16 columns; From inclusive, To exclusive; both equal the
      caret column when nothing is typed yet. }
    ReplaceColFrom: Integer;
    ReplaceColTo: Integer;
    Provider: string;    // names the provider+context in the server's log
  end;

  { One per server session - the preprocessor stack (source manager, defines)
    is configuration-derived, and the server's configuration is fixed at
    initialize. CompleteAt itself is stateless across calls. }
  TLspCompletionEngine = class
  private
    FPlatform: TPasPlatform;
    FSourceManager: TPasSourceManager;
    FDefines: TPasDefines;
    FPreprocessor: TPasPreprocessor;
  public
    constructor Create(APlatform: TPasPlatform;
      const ASearchPaths, ADefines: TArray<string>);
    destructor Destroy; override;
    { Replaces the engine's overlay set with the given open documents. Called
      by the server before each CompleteAt so an $I include with unsaved
      edits is preprocessed from its LIVE text, not from disk - the same
      document-truth rule the analysis session enforces via SetBuffer
      (review finding, 2026-08-22). }
    procedure SetOverlays(const APaths, ATexts: TArray<string>);
    { The completion answer at a 1-based (line, col) of AText - the LIVE
      overlay text of AFileName. AProject/AProjectMid bridge to the last-good
      analysis (nil/-1 = standalone). Never raises; a position that offers
      nothing answers empty with the span collapsed at the caret. }
    function CompleteAt(const AFileName, AText: string;
      APasLine, APasCol: Integer; AProject: TPasSemaProject;
      AProjectMid: Integer): TLspCompletionAnswer;
    { Signature help at a position: the engine's CallAt locates the innermost
      enclosing call (indexers, grouping parens and casts stepped over; a
      declaration's parameter list refuses), counts the active argument, and
      resolves the designator through the overlay+bridge - so member calls
      and freshly typed cross-unit calls answer, the two cases the interim
      backward-walk locator (retired 2026-08-22) never could. One signature
      per overload; intrinsics answer from the engine's curated table. }
    function SignatureHelpAt(const AFileName, AText: string;
      APasLine, APasCol: Integer; AProject: TPasSemaProject;
      AProjectMid: Integer): TLspSignatureHelpAnswer;
    { Class completion over the same live overlay text: the declarations of
      AFileName that have no implementation, as text to insert (see
      PasLsp.ClassComplete for what counts and what does not). No project
      bridge and no position - the question is about ONE buffer as a whole,
      and the answer must see declarations the last analysis never has:
      the user pressed the key because they just typed one. }
    function ClassCompleteAt(const AFileName, AText: string):
      TLspClassCompleteAnswer;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Parser,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Resolver,
  PasTree.Sema.Builtins,
  PasTree.Sema.Complete;

{ LSP CompletionItemKind for a PasTree symbol kind. }
function LspKindOf(AKind: TSemaSymbolKind): Integer;
begin
  case AKind of
    skType, skBuiltinType: Result := 7;    // Class
    skVar, skParam:        Result := 6;    // Variable
    skConst:               Result := 21;   // Constant
    skField:               Result := 5;    // Field
    skRoutine:             Result := 3;    // Function
    skProperty:            Result := 10;   // Property
    skEnumValue:           Result := 20;   // EnumMember
    skGenericParam:        Result := 25;   // TypeParameter
    skUnitRef:             Result := 9;    // Module
  else
    Result := 1;                           // Text - draws neutral everywhere
  end;
end;

{ sortText: the bucket's ordinal ranks first, the lower-cased name breaks
  ties - so clients that sort by sortText (VS Code) present the engine's
  resolution-precedence order (members before unit names before builtins
  before keywords), while clients that filter/sort themselves (the RAD
  viewer's SetFilter) simply ignore it. }
function BucketSort(ABucket: TPasComplBucket; const AName: string): string;
begin
  Result := Format('%.2d%s', [Ord(ABucket), LowerCase(AName)]);
end;

{ Display cap for a Detail column - the engine hands back the declaration's
  full one-line span and leaves any length cap to the host (its words). }
function CapDisplay(const AText: string): string;
const
  cCap = 100;
begin
  Result := AText;
  if Length(Result) > cCap then
    Result := Copy(Result, 1, cCap - 3) + '...';
end;

{ ---- bare-row fallbacks (user ask, 2026-08-22) -----------------------------

  Every completion row should say what it IS, and the declared-type paths
  leave real gaps: a TYPE row never had a Detail at all, a CONST row said
  its type but not its value, and a var/property whose declared type is
  anonymous (`AbstractErrorProc: procedure`) has no X-type to render. These
  read the answer straight off the declaration's PUBLIC AST - node kinds
  and NodeSpanText, nothing the engine keeps private. }

type
  TNodeKinds = set of TPasNodeKind;

{ The enclosing declaration node of a symbol - DeclNode may point at the
  name inside it, so climb until a wanted kind (the engine's own recipe). }
function DeclOfKinds(AModel: TPasSemaModel; ASym: Integer;
  const AKinds: TNodeKinds): Integer;
begin
  Result := AModel.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and
        not (AModel.Tree.Nodes[Result].Kind in AKinds) do
    Result := AModel.Tree.Nodes[Result].Parent;
end;

{ The type expression child of a var/field/param/property declaration: the
  first child whose PRECEDING visible token is the ':'. Kind alone cannot
  split it out - the names before it are nkIdent and a type alias after it
  is nkIdent too. NIL_NODE when the declaration carries no ':' (an untyped
  `var` parameter, an inferred inline var). }
function DeclTypeExprNode(AModel: TPasSemaModel; ADecl: Integer): Integer;
var
  LPrev: Integer;
begin
  Result := AModel.Tree.Nodes[ADecl].FirstChild;
  while Result <> NIL_NODE do
  begin
    LPrev := AModel.Tree.Nodes[Result].FirstToken - 1;
    if LPrev >= 0 then
      with AModel.Tree.Source.Visible[LPrev] do
        if AModel.Tree.Source.Files[FileId].Tokens[TokenIndex].Kind =
             tkColon then
          Exit;
    Result := AModel.Tree.Nodes[Result].NextSibling;
  end;
end;

{ The initializer text of a const declaration. nkConstDecl/nkInlineConst
  children are [attrs] name [TypeExpr] init [hints]; the init is the LAST
  child that is neither attribute nor hint directive, which sidesteps
  telling a leading type from an untyped value. '' when malformed. }
function ConstValueText(AModel: TPasSemaModel; ADecl: Integer): string;
var
  LChild, LInit: Integer;
  LSeenName: Boolean;
begin
  Result := '';
  LInit := NIL_NODE;
  LSeenName := False;
  LChild := AModel.Tree.Nodes[ADecl].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if not (AModel.Tree.Nodes[LChild].Kind in [nkAttrGroup, nkDirective]) then
      if not LSeenName then
        LSeenName := True
      else
        LInit := LChild;
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
  if LInit <> NIL_NODE then
    Result := CapDisplay(AModel.Tree.NodeSpanText(LInit));
end;

{ The head of a type DEFINITION for a completion row: the whole span for the
  small shapes ('tagABC', '0..255', 'set of TFoo', 'procedure of object'),
  the head word plus heritage for the struct kinds - their span is an entire
  body, and slicing whole classes for thousands of rows is exactly the cost
  NodeSpanText must not pay here. '' when the declaration is malformed. }
function TypeDefHeadText(AModel: TPasSemaModel; ADecl: Integer): string;
var
  LExpr, LChild: Integer;
  LSeenName: Boolean;
  LRefs, LLast: string;
begin
  Result := '';
  // nkTypeDecl children: [attrs] name [generic params] TypeExpr [hints].
  LExpr := AModel.Tree.Nodes[ADecl].FirstChild;
  LSeenName := False;
  while LExpr <> NIL_NODE do
  begin
    if not (AModel.Tree.Nodes[LExpr].Kind in
         [nkAttrGroup, nkGenericParams, nkDirective]) then
      if LSeenName then
        Break
      else
        LSeenName := True;
    LExpr := AModel.Tree.Nodes[LExpr].NextSibling;
  end;
  if LExpr = NIL_NODE then
    Exit;
  case AModel.Tree.Nodes[LExpr].Kind of
    nkClassType:  Result := 'class';
    nkRecordType: Result := 'record';
    nkObjectType: Result := 'object';
    nkInterfaceType:
      if AModel.Tree.Nodes[LExpr].Aux = 1 then
        Result := 'dispinterface'
      else
        Result := 'interface';
    nkHelperType:
      if AModel.Tree.Nodes[LExpr].Aux = 1 then
        Result := 'record helper'
      else
        Result := 'class helper';
  else
    Exit(CapDisplay(AModel.Tree.NodeSpanText(LExpr)));
  end;
  // Heritage: the leading type-ref children. For a helper the last of them
  // is the `for` target; for the rest they are the ancestor list.
  LRefs := '';
  LLast := '';
  LChild := AModel.Tree.Nodes[LExpr].FirstChild;
  while (LChild <> NIL_NODE) and
        (AModel.Tree.Nodes[LChild].Kind in [nkIdent, nkMember, nkTypeArgs]) do
  begin
    if LLast <> '' then
    begin
      if LRefs <> '' then
        LRefs := LRefs + ', ';
      LRefs := LRefs + LLast;
    end;
    LLast := AModel.Tree.NodeSpanText(LChild);
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
  if AModel.Tree.Nodes[LExpr].Kind = nkHelperType then
  begin
    if LLast <> '' then
      Result := Result + ' for ' + LLast;
  end
  else if LLast <> '' then
  begin
    if LRefs <> '' then
      LRefs := LRefs + ', ';
    Result := Result + '(' + LRefs + LLast + ')';
  end;
  Result := CapDisplay(Result);
end;

{ '(const A, B: Integer; var S: string)' -> individual parameter labels
  ('const A: Integer', 'const B: Integer', 'var S: string'): top-level ';'
  splits groups, ',' splits names within one, the group's modifier and type
  apply to each name. Depth-tracked over ()/[]/<> so a default value or a
  generic type argument cannot break the split. }
function SplitParamLabels(const AParamsText: string): TArray<string>;
var
  LInner, LGroup, LNames, LTail, LModifier, LName: string;
  LGroups, LNameList: TArray<string>;
  LDepth, LIdx, LFrom, LColon: Integer;

  procedure CutGroup(ATo: Integer);
  begin
    LGroup := Trim(Copy(LInner, LFrom, ATo - LFrom));
    if LGroup <> '' then
      LGroups := LGroups + [LGroup];
    LFrom := ATo + 1;
  end;

begin
  Result := nil;
  LInner := Trim(AParamsText);
  if LInner.StartsWith('(') then
    LInner := Copy(LInner, 2, Length(LInner) - 2);   // strip the parens
  LGroups := nil;
  LDepth := 0;
  LFrom := 1;
  for LIdx := 1 to Length(LInner) do
    case LInner[LIdx] of
      '(', '[', '<': Inc(LDepth);
      ')', ']', '>': Dec(LDepth);
      ';': if LDepth = 0 then CutGroup(LIdx);
    end;
  CutGroup(Length(LInner) + 1);

  for LGroup in LGroups do
  begin
    // '[const|var|out] A, B: T [= default]' - the ':' at depth 0 ends names.
    LColon := 0;
    LDepth := 0;
    for LIdx := 1 to Length(LGroup) do
      case LGroup[LIdx] of
        '(', '[', '<': Inc(LDepth);
        ')', ']', '>': Dec(LDepth);
        ':': if (LDepth = 0) and (LColon = 0) then LColon := LIdx;
      end;
    if LColon > 0 then
    begin
      LNames := Trim(Copy(LGroup, 1, LColon - 1));
      LTail := ': ' + Trim(Copy(LGroup, LColon + 1, MaxInt));
    end
    else
    begin
      LNames := LGroup;   // untyped const parameter
      LTail := '';
    end;
    LModifier := '';
    LIdx := Pos(' ', LNames);
    if LIdx > 0 then
    begin
      LName := Copy(LNames, 1, LIdx - 1);
      if SameText(LName, 'const') or SameText(LName, 'var') or
         SameText(LName, 'out') then
      begin
        LModifier := LowerCase(LName) + ' ';
        LNames := Trim(Copy(LNames, LIdx + 1, MaxInt));
      end;
    end;
    LNameList := LNames.Split([',']);
    for LName in LNameList do
      if Trim(LName) <> '' then
        Result := Result + [LModifier + Trim(LName) + LTail];
  end;
end;

function ContextName(AContext: TPasComplContext): string;
begin
  case AContext of
    ccMember:     Result := 'member';
    ccUses:       Result := 'uses';
    ccType:       Result := 'type';
    ccStatement:  Result := 'statement';
    ccExpression: Result := 'expression';
  else
    Result := 'none';
  end;
end;

{ TLspCompletionEngine }

constructor TLspCompletionEngine.Create(APlatform: TPasPlatform;
  const ASearchPaths, ADefines: TArray<string>);
var
  LDefine: string;
begin
  inherited Create;
  FPlatform := APlatform;
  FSourceManager := TPasSourceManager.Create(ASearchPaths);
  // The platform's implicit defines plus the project's own - the same set
  // the analysis preprocesses with, so an $IFDEF cannot make the overlay
  // parse a different text than the closure saw.
  FDefines := CreatePlatformDefines(APlatform);
  for LDefine in ADefines do
    FDefines.Define(LDefine);
  FPreprocessor := TPasPreprocessor.Create(FSourceManager, FDefines);
end;

destructor TLspCompletionEngine.Destroy;
begin
  FPreprocessor.Free;
  FDefines.Free;
  FSourceManager.Free;
  inherited;
end;

procedure TLspCompletionEngine.SetOverlays(const APaths,
  ATexts: TArray<string>);
var
  LIdx: Integer;
begin
  FSourceManager.ClearBuffers;
  for LIdx := 0 to High(APaths) do
    FSourceManager.SetBuffer(APaths[LIdx], ATexts[LIdx]);
end;

function TLspCompletionEngine.CompleteAt(const AFileName, AText: string;
  APasLine, APasCol: Integer; AProject: TPasSemaProject;
  AProjectMid: Integer): TLspCompletionAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LModel: TPasSemaModel;
  LCompletion: TPasCompletion;
  LInfo: TPasCaretInfo;
  LContext: TPasComplContext;
  LItems: TArray<TPasComplItem>;
  LIdx: Integer;
  LEntry: TLspCompletionEntry;
  LWithTypes: Boolean;
  LX: TSemaXType;
  LParamsText, LText: string;
  LTypeSym, LDecl: Integer;
  LItemModel: TPasSemaModel;
  LSig: TPasBuiltinSig;
begin
  Result := Default(TLspCompletionAnswer);
  Result.ReplaceColFrom := APasCol;
  Result.ReplaceColTo := APasCol;
  Result.Provider := 'pastree/none';
  // A malformed client position must not reach the engine: nothing in this
  // repository pins how it treats a zero/negative coordinate, and the old
  // provider's explicit guard was lost in the engine swap (review finding).
  if (APasLine < 1) or (APasCol < 1) then
    Exit;

  // The fresh overlay: mid-keystroke text, parsed error-tolerantly. Parse
  // diagnostics are EXPECTED here (the buffer is invalid by definition) and
  // deliberately discarded - the pushed diagnostics stay the analysis's.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
  try
    LCompletion := TPasCompletion.Create(LModel, AProject, AProjectMid);
    try
      // One caret pass: the engine hands its own classification back, span
      // included - a host must not re-derive tokenization (its words).
      if not LCompletion.CompleteAt(APasLine, APasCol, LInfo, LContext,
           LItems) then
      begin
        // ckNone keeps the span collapsed at the caret; any other refusal
        // still carries the real span.
        if LInfo.Kind <> ckNone then
        begin
          Result.ReplaceColFrom := LInfo.PrefixColFrom;
          Result.ReplaceColTo := LInfo.PrefixColTo;
        end;
        Exit;
      end;
      Result.ReplaceColFrom := LInfo.PrefixColFrom;
      Result.ReplaceColTo := LInfo.PrefixColTo;
      Result.Provider := 'pastree/' + ContextName(LContext);
      // Declared-type detail for EVERY row, no size guard: the first live
      // run hit the demo popup's 512-item guard on an ordinary statement
      // position (the whole RTL is in scope there - thousands of rows) and
      // showed no types at all, which reads as the feature missing. The
      // resolve is a per-row lookup, the request is per invocation (the RAD
      // viewer filters locally afterwards), and the completion log line
      // carries the milliseconds - if a real project proves this expensive,
      // the fix is lazy resolve, not a cliff that silently strips the list.
      LWithTypes := AProject <> nil;
      SetLength(Result.Items, Length(LItems));
      for LIdx := 0 to High(LItems) do
      begin
        LEntry := Default(TLspCompletionEntry);
        LEntry.ItemLabel := LItems[LIdx].Name;
        // The routine's real head word both refines the LSP kind and rides
        // to the RAD viewer's class column verbatim.
        if LItems[LIdx].Kind = skRoutine then
          LEntry.HeadWord := LCompletion.ItemHeadWord(LItems[LIdx]);
        case LItems[LIdx].Bucket of
          cbKeyword:  LEntry.Kind := 14;   // Keyword
          cbUnitName: LEntry.Kind := 9;    // Module
        else
          if LEntry.HeadWord = 'constructor' then
            LEntry.Kind := 4               // Constructor
          else if LEntry.HeadWord = 'operator' then
            LEntry.Kind := 24              // Operator
          else
            LEntry.Kind := LspKindOf(LItems[LIdx].Kind);
        end;
        // A routine's PARAMETER LIST as display text - the engine's own
        // accessors (0.6.0): the declaration span for real routines, the
        // curated seed-table signature for intrinsics (Copy, Inc, Writeln -
        // rows the interim hand-rolled span reader always left blank).
        // HasParams drives the RAD client's auto-parenthesis; an empty `()`
        // and an all-optional intrinsic (Exit, Halt) both answer False.
        LEntry.HasParams := LCompletion.ItemHasParams(LItems[LIdx]);
        // The `///` block for Help Insight, EAGERLY, per row - the same
        // trade, and for the same reason, as the declared-type detail above:
        // the RAD viewer asks for an item's documentation SYNCHRONOUSLY on
        // the UI thread (IOTACodeInsightSymbolList80.GetSymbolDocumentation),
        // where a round-trip is forbidden, so a completionItem/resolve pass
        // could never serve it. The walk is a backward raw-token step that
        // stops at the token before the declaration for every undocumented
        // row, which is nearly all of them.
        LEntry.Doc := LCompletion.ItemDocComment(LItems[LIdx]);
        LParamsText := LCompletion.ItemParamsText(LItems[LIdx]);
        if LParamsText <> '' then
          LEntry.Detail := CapDisplay(LParamsText);
        // ': <declared type>' - the demo's own recipe: the project resolves
        // the symbol's declared type on demand, through the instantiation
        // frame when the item came from a generic instance. For a routine
        // this is its RESULT type, appended after the parameter list.
        if LWithTypes and (LItems[LIdx].Mid >= 0) and
           (LItems[LIdx].Sym <> NIL_SYM) and
           (LItems[LIdx].Kind in [skVar, skConst, skField, skParam,
             skProperty, skRoutine]) then
        begin
          LX := AProject.SymDeclTypeX(LItems[LIdx].Mid, LItems[LIdx].Sym);
          if LItems[LIdx].Ctx <> NIL_INST then
            LX := AProject.SubstX(LX, LItems[LIdx].Ctx, 0);
          if XValid(LX) then
            LEntry.Detail := LEntry.Detail + ': ' + AProject.XTypeText(LX);
        end
        // OVERLAY-declared symbols - the edited file's own locals, params
        // and members, i.e. the rows the user looks at most - have no
        // project mid, but the fresh model resolved their declared type
        // intra-unit: TypeSym's name is the honest (if unexpanded) answer.
        // Without this branch the mixed list reads as types randomly
        // missing (review finding, 2026-08-22).
        else if (LItems[LIdx].Mid < 0) and (LItems[LIdx].Sym <> NIL_SYM) and
           (LItems[LIdx].Kind in [skVar, skConst, skField, skParam,
             skProperty, skRoutine]) then
        begin
          LTypeSym := LModel.Symbols[LItems[LIdx].Sym].TypeSym;
          if LTypeSym <> NIL_SYM then
            LEntry.Detail := LEntry.Detail + ': '
              + LModel.Symbols[LTypeSym].Name;
        end;
        // Rows the paths above leave bare still say what they ARE (user
        // ask, 2026-08-22): a type its definition head, a const its VALUE
        // (always, appended after the type when one rendered), a
        // var/property its declared type read off the declaration, a
        // builtin routine its curated result type.
        if LItems[LIdx].Sym <> NIL_SYM then
        begin
          if LItems[LIdx].Mid < 0 then
            LItemModel := LModel
          else if AProject <> nil then
            LItemModel := AProject.Model(LItems[LIdx].Mid)
          else
            LItemModel := nil;
          if LItemModel <> nil then
            case LItems[LIdx].Kind of
              skType:
                if LEntry.Detail = '' then
                begin
                  LDecl := DeclOfKinds(LItemModel, LItems[LIdx].Sym,
                    [nkTypeDecl]);
                  if LDecl <> NIL_NODE then
                  begin
                    LText := TypeDefHeadText(LItemModel, LDecl);
                    if LText <> '' then
                    begin
                      // Distinct alias (`= type Base`, nkTypeDecl Aux = 1).
                      if LItemModel.Tree.Nodes[LDecl].Aux = 1 then
                        LText := 'type ' + LText;
                      LEntry.Detail := ' = ' + LText;
                    end;
                  end;
                end;
              skConst:
                begin
                  LDecl := DeclOfKinds(LItemModel, LItems[LIdx].Sym,
                    [nkConstDecl, nkInlineConst]);
                  if LDecl <> NIL_NODE then
                  begin
                    LText := ConstValueText(LItemModel, LDecl);
                    if LText <> '' then
                      LEntry.Detail := LEntry.Detail + ' = ' + LText;
                  end;
                end;
              skVar, skField, skParam, skProperty:
                if LEntry.Detail = '' then
                begin
                  LDecl := DeclOfKinds(LItemModel, LItems[LIdx].Sym,
                    [nkVarDecl, nkParam, nkPropertyDecl, nkInlineVar]);
                  if LDecl <> NIL_NODE then
                  begin
                    LDecl := DeclTypeExprNode(LItemModel, LDecl);
                    if LDecl <> NIL_NODE then
                      LEntry.Detail := ': '
                        + CapDisplay(LItemModel.Tree.NodeSpanText(LDecl));
                  end;
                end;
              skRoutine:
                if (sfBuiltin in
                     LItemModel.Symbols[LItems[LIdx].Sym].Flags) and
                   PasBuiltinSignature(
                     LItemModel.Symbols[LItems[LIdx].Sym].NameLower, LSig) and
                   (LSig.ResultType <> '') then
                  LEntry.Detail := LEntry.Detail + ': ' + LSig.ResultType;
            end;
        end;
        if LItems[LIdx].Overloads > 0 then
          LEntry.Detail := LEntry.Detail
            + Format(' (+%d)', [LItems[LIdx].Overloads]);
        LEntry.SortText := BucketSort(LItems[LIdx].Bucket, LItems[LIdx].Name);
        Result.Items[LIdx] := LEntry;
      end;
    finally
      LCompletion.Free;
    end;
  finally
    // The tree is a managed record the model references; freeing the model
    // is the only explicit teardown.
    LModel.Free;
  end;
end;

function TLspCompletionEngine.SignatureHelpAt(const AFileName, AText: string;
  APasLine, APasCol: Integer; AProject: TPasSemaProject;
  AProjectMid: Integer): TLspSignatureHelpAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LModel: TPasSemaModel;
  LCompletion: TPasCompletion;
  LInfo: TPasCallInfo;
  LIdx: Integer;
  LSig: TLspSignatureItem;
begin
  Result := Default(TLspSignatureHelpAnswer);
  Result.Provider := 'pastree/no-call';
  if (APasLine < 1) or (APasCol < 1) then
    Exit;

  // The same overlay pipeline as CompleteAt: the LIVE text, parsed
  // error-tolerantly, bridged to the last-good analysis. CallAt does the
  // rest - locating the call, counting the argument, resolving the
  // designator (member calls and freshly typed cross-unit calls included),
  // one target per overload with display fields already materialized.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
  try
    LCompletion := TPasCompletion.Create(LModel, AProject, AProjectMid);
    try
      if not LCompletion.CallAt(APasLine, APasCol, LInfo) then
        Exit;
      Result.CallLine := LInfo.OpenLine;
      Result.CallCol := LInfo.OpenCol;
      Result.ActiveParam := LInfo.ArgIndex;
      SetLength(Result.Signatures, Length(LInfo.Targets));
      for LIdx := 0 to High(LInfo.Targets) do
      begin
        LSig.SigLabel := LInfo.Targets[LIdx].Name
          + LInfo.Targets[LIdx].ParamsText;
        if LInfo.Targets[LIdx].ResultText <> '' then
          LSig.SigLabel := LSig.SigLabel + ': '
            + LInfo.Targets[LIdx].ResultText;
        LSig.Params := SplitParamLabels(LInfo.Targets[LIdx].ParamsText);
        Result.Signatures[LIdx] := LSig;
      end;
      // Prefer the first overload that still has a parameter for the
      // argument being typed; the first one otherwise.
      Result.ActiveSignature := 0;
      for LIdx := 0 to High(Result.Signatures) do
        if Length(Result.Signatures[LIdx].Params) > LInfo.ArgIndex then
        begin
          Result.ActiveSignature := LIdx;
          Break;
        end;
      // True with no targets is CallAt's honest "a call whose name nothing
      // resolves" - the handler answers null either way, but the log line
      // should say which of the two happened.
      if Length(LInfo.Targets) = 0 then
        Result.Provider := 'pastree/callat-unresolved'
      else
        Result.Provider := 'pastree/callat';
    finally
      LCompletion.Free;
    end;
  finally
    LModel.Free;
  end;
end;

function TLspCompletionEngine.ClassCompleteAt(const AFileName, AText: string):
  TLspClassCompleteAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  // Parse only - no resolver, no bridge. Class completion is a question about
  // DECLARATIONS AND BODIES, which the CST answers on its own; running the
  // resolver for it would buy nothing and cost the analysis of every unit the
  // file uses.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  Result := ClassCompleteFor(LTree);
end;

end.
