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
  PasLsp.ClassComplete,
  PasLsp.SyncPrototypes,
  PasLsp.AnnotateArgs,
  PasLsp.UseUnit,
  PasLsp.UnusedUnits;

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

{ A symbol's one-line signature as the native hint spells it - `var Name:
  Type`, `property TOwner.Name: Type`, `function TOwner.Name(params): Type`,
  `const Name = Value`, `type Name = class(TBase)` - composed from the analysis
  rather than read off the declaration line, which for a variable is
  `LName, LDetail, LKind: string;` (Alex, 2026-10-07). The detail after the
  name is the completion row's own (ItemDetailText). ATypeSpans are the type
  names in it, 1-based column/length pairs; AHeadLen the length of the lead
  (`var`, `param [in/out]`), painted as a keyword. An enum value reads
  `const Unit.Name = TEnum(1)`, AUnitFile naming the unit. '' for a kind it
  does not compose (a label) - the caller keeps the declaration line. }
function SymbolSignatureText(AProject: TPasSemaProject; AMid, ASym: Integer;
  const AUnitFile: string; out ATypeSpans: TArray<Integer>;
  out AHeadLen: Integer): string;

type
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
      PasLsp.ClassComplete for what counts and what does not). The answer is
      the buffer's, because it must see declarations the last analysis never
      has - the user pressed the key because they just typed one. AProject/
      AProjectMid (nil/-1 = none) are asked ONE thing only: whether a name a
      property points at is inherited from an ancestor in another unit, which
      the buffer alone cannot see. }
    function ClassCompleteAt(const AFileName, AText: string;
      APasLine, APasCol: Integer; AProject: TPasSemaProject;
      AProjectMid: Integer; ABodyOrder: TLspBodyOrder):
      TLspClassCompleteAnswer;
    { Prototype sync at a position: the routine under the caret, mirrored onto
      its other half (PasLsp.SyncPrototypes). Same live-buffer, parse-only
      reading as class completion - and for the sharper version of the same
      reason: the signature it is asked about was edited a keystroke ago. }
    function SyncPrototypeAt(const AFileName, AText: string;
      APasLine, APasCol: Integer): TLspSyncAnswer;
    (* Argument annotation for the call at the caret - `{Name:}` and
      `{var}`/`{out}` in front of the arguments (PasLsp.AnnotateArgs has the
      rules). The signature-help pipeline exactly: the LIVE text, resolved
      through the overlay+bridge, so the call typed a second ago answers,
      and the overload is the one the resolver bound. *)
    function AnnotateArgsAt(const AFileName, AText: string;
      APasLine, APasCol: Integer; AProject: TPasSemaProject;
      AProjectMid: Integer;
      const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;
    { What the LIVE text is and what it uses (PasLsp.UseUnit) - parse only,
      so the unit list can leave out what the buffer already names, a
      keystroke ago included. }
    function UsesInfoAt(const AFileName, AText: string): TLspUsesInfo;
    { Use Unit: the one edit that adds AUnitName to the live text's uses
      (PasLsp.UseUnit has the rules and the refusals). }
    function UseUnitAt(const AFileName, AText, AUnitName: string;
      AImplementation: Boolean; const AIndent: string;
      ARightMargin: Integer): TLspUseUnitAnswer;
    { Unused Units' Remove: the clause rewrites that take ANames out of the
      live text's uses (PasLsp.UnusedUnits.UsesRemovalByName). }
    function UsesRemovalAt(const AFileName, AText: string;
      const ANames: TArray<string>; out ARefused, AMissing: TArray<string>)
      : TArray<TLspUsesRemoval>;
  end;

implementation

uses
  System.SysUtils,
  System.Math,
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

{ What a completion row says after its name - and, from the hover, what
  follows a symbol's name in its one-line signature: a routine's parameter
  list and result type, a variable's or field's declared type, a constant's
  value, a type's definition head. AOverlay is the model of the live buffer
  (Mid = -1 items); AWithTypes says a project is there to resolve declared
  types through. Moved out of CompleteAt unchanged when the hover needed the
  same text (2026-10-07). }
function ItemDetailText(ACompletion: TPasCompletion; AProject: TPasSemaProject;
  AOverlay: TPasSemaModel; const AItem: TPasComplItem;
  AWithTypes: Boolean): string;
var
  LX: TSemaXType;
  LParamsText, LText: string;
  LTypeSym, LDecl: Integer;
  LItemModel: TPasSemaModel;
  LSig: TPasBuiltinSig;
begin
  Result := '';
  LParamsText := ACompletion.ItemParamsText(AItem);
  if LParamsText <> '' then
    Result := CapDisplay(LParamsText);
  // ': <declared type>' - the demo's own recipe: the project resolves
  // the symbol's declared type on demand, through the instantiation
  // frame when the item came from a generic instance. For a routine
  // this is its RESULT type, appended after the parameter list.
  if AWithTypes and (AItem.Mid >= 0) and
     (AItem.Sym <> NIL_SYM) and
     (AItem.Kind in [skVar, skConst, skField, skParam,
       skProperty, skRoutine]) then
  begin
    LX := AProject.SymDeclTypeX(AItem.Mid, AItem.Sym);
    if AItem.Ctx <> NIL_INST then
      LX := AProject.SubstX(LX, AItem.Ctx, 0);
    if XValid(LX) then
      Result := Result + ': ' + AProject.XTypeText(LX);
  end
  // OVERLAY-declared symbols - the edited file's own locals, params
  // and members, i.e. the rows the user looks at most - have no
  // project mid, but the fresh model resolved their declared type
  // intra-unit: TypeSym's name is the honest (if unexpanded) answer.
  // Without this branch the mixed list reads as types randomly
  // missing (review finding, 2026-08-22).
  else if (AItem.Mid < 0) and (AItem.Sym <> NIL_SYM) and
     (AItem.Kind in [skVar, skConst, skField, skParam,
       skProperty, skRoutine]) then
  begin
    LTypeSym := AOverlay.Symbols[AItem.Sym].TypeSym;
    if LTypeSym <> NIL_SYM then
      Result := Result + ': '
        + AOverlay.Symbols[LTypeSym].Name;
  end;
  // Rows the paths above leave bare still say what they ARE (user
  // ask, 2026-08-22): a type its definition head, a const its VALUE
  // (always, appended after the type when one rendered), a
  // var/property its declared type read off the declaration, a
  // builtin routine its curated result type.
  if AItem.Sym <> NIL_SYM then
  begin
    if AItem.Mid < 0 then
      LItemModel := AOverlay
    else if AProject <> nil then
    begin
      LItemModel := AProject.Model(AItem.Mid);
      // Library units have their text demoted after a full build
      // (TLspServer.DemoteLibraryText), and every helper below reads
      // text - on a demoted model the token layer is nil. A unit whose
      // stream cannot be reproduced stays demoted: no detail, not a
      // fault.
      if (LItemModel <> nil) and LItemModel.Demoted and
         not AProject.EnsureHydrated(AItem.Mid) then
        LItemModel := nil;
    end
    else
      LItemModel := nil;
    if LItemModel <> nil then
      case AItem.Kind of
        skType:
          if Result = '' then
          begin
            LDecl := DeclOfKinds(LItemModel, AItem.Sym,
              [nkTypeDecl]);
            if LDecl <> NIL_NODE then
            begin
              LText := TypeDefHeadText(LItemModel, LDecl);
              if LText <> '' then
              begin
                // Distinct alias (`= type Base`, nkTypeDecl Aux = 1).
                if LItemModel.Tree.Nodes[LDecl].Aux = 1 then
                  LText := 'type ' + LText;
                Result := ' = ' + LText;
              end;
            end;
          end;
        skConst:
          begin
            LDecl := DeclOfKinds(LItemModel, AItem.Sym,
              [nkConstDecl, nkInlineConst]);
            if LDecl <> NIL_NODE then
            begin
              LText := ConstValueText(LItemModel, LDecl);
              if LText <> '' then
                Result := Result + ' = ' + LText;
            end;
          end;
        skVar, skField, skParam, skProperty:
          if Result = '' then
          begin
            LDecl := DeclOfKinds(LItemModel, AItem.Sym,
              [nkVarDecl, nkParam, nkPropertyDecl, nkInlineVar]);
            if LDecl <> NIL_NODE then
            begin
              LDecl := DeclTypeExprNode(LItemModel, LDecl);
              if LDecl <> NIL_NODE then
                Result := ': '
                  + CapDisplay(LItemModel.Tree.NodeSpanText(LDecl));
            end;
          end;
        skRoutine:
          if (sfBuiltin in
               LItemModel.Symbols[AItem.Sym].Flags) and
             PasBuiltinSignature(
               LItemModel.Symbols[AItem.Sym].NameLower, LSig) and
             (LSig.ResultType <> '') then
            Result := Result + ': ' + LSig.ResultType;
      end;
  end;
end;

{ The type a member is declared in - the symbol of the struct whose member
  scope ASym's scope is - or NIL_SYM for anything that is not a member. A
  struct's member scope is a child of the scope its type is declared in, so
  that one scope's symbols are the only candidates. }
function OwnerTypeSym(AModel: TPasSemaModel; ASym: Integer): Integer;
var
  LScope, LParent, LIdx, LCand: Integer;
  LList: TSemaSymList;
begin
  Result := NIL_SYM;
  LScope := AModel.Symbols[ASym].Scope;
  if (LScope < 0) or (LScope >= AModel.Scopes.Count) or
     (AModel.Scopes[LScope].Kind <> sckStruct) then
    Exit;
  LParent := AModel.Scopes[LScope].Parent;
  if LParent = NIL_SCOPE then
    Exit;
  LList := AModel.Scopes[LParent].Symbols;
  for LIdx := 0 to LList.Count - 1 do
  begin
    LCand := LList[LIdx];
    if (AModel.Symbols[LCand].Kind = skType) and
       (AModel.Symbols[LCand].MemberScope = LScope) then
      Exit(LCand);
  end;
end;

{ The identifiers of ASig that name types, as 1-based (column, length) pairs:
  one right after a `:` or `of`, the owner qualifier in front of the dot, for
  a type its own name and the ancestors in `class(...)` / `interface(...)`,
  and anywhere a segment spelled AKnownType - the declared type of a
  constant, which its value writes as `System.UITypes.TMsgDlgBtn.mbCancel`
  (Alex, 2026-10-07). Of a dotted name only the segment that is the type is
  marked, never the unit qualifier in front of it. A heuristic over text the
  server composed itself, where those are the only places a type can stand -
  the hover paints them in the type colour as the editor would. }
function SignatureTypeSpans(const ASig: string; AOwnerLen, ANameStart,
  ANameLen: Integer; AIsType: Boolean;
  const AKnownType: string = ''): TArray<Integer>;
var
  LIdx, LFrom, LPrev, LSeg, LLastSeg: Integer;
  LWord, LPrevWord: string;
  LInHeritage, LTypePos: Boolean;
  LResult: TArray<Integer>;

  procedure Add(AFrom, ALen: Integer);
  begin
    LResult := LResult + [AFrom, ALen];
  end;

begin
  LResult := nil;
  if AOwnerLen > 0 then
    Add(ANameStart - AOwnerLen - 1, AOwnerLen);
  if AIsType then
    Add(ANameStart, ANameLen);
  LIdx := ANameStart + ANameLen;
  LPrevWord := '';
  LInHeritage := False;
  while LIdx <= Length(ASig) do
  begin
    if CharInSet(ASig[LIdx], ['A'..'Z', 'a'..'z', '_']) then
    begin
      LFrom := LIdx;
      while (LIdx <= Length(ASig)) and
            CharInSet(ASig[LIdx], ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
        Inc(LIdx);
      LWord := Copy(ASig, LFrom, LIdx - LFrom);
      // What stands right before the word, spaces skipped.
      LPrev := LFrom - 1;
      while (LPrev >= 1) and (ASig[LPrev] = ' ') do
        Dec(LPrev);
      LTypePos := ((LPrev >= 1) and (ASig[LPrev] = ':')) or
        SameText(LPrevWord, 'of') or
        (LInHeritage and (LPrev >= 1) and CharInSet(ASig[LPrev], ['(', ',']));
      // Segment by segment: in a type position the last one is the type, and
      // a segment spelled AKnownType is one wherever it stands.
      LLastSeg := LFrom;
      for LSeg := LFrom to LIdx - 1 do
        if ASig[LSeg] = '.' then
          LLastSeg := LSeg + 1;
      LSeg := LFrom;
      while LSeg < LIdx do
      begin
        LPrev := LSeg;
        while (LPrev < LIdx) and (ASig[LPrev] <> '.') do
          Inc(LPrev);
        if (LTypePos and (LSeg = LLastSeg)) or ((AKnownType <> '') and
           SameText(Copy(ASig, LSeg, LPrev - LSeg), AKnownType)) then
          Add(LSeg, LPrev - LSeg);
        LSeg := LPrev + 1;
      end;
      if AIsType and (SameText(LWord, 'class') or SameText(LWord, 'interface')
         or SameText(LWord, 'record')) and (LIdx <= Length(ASig)) and
         (ASig[LIdx] = '(') then
        LInHeritage := True;
      LPrevWord := LWord;
    end
    else
    begin
      if ASig[LIdx] = ')' then
        LInHeritage := False;
      if ASig[LIdx] <> ' ' then
        LPrevWord := '';
      Inc(LIdx);
    end;
  end;
  Result := LResult;
end;

{ An enum value's ordinal as the native hint writes it, `TEnum(1)`: counted
  along its enum's values, restarting at an explicit `= N`; a value set by an
  expression that is not a plain integer is shown as that expression. '' when
  the declaration cannot be read. }
function EnumValueText(AModel: TPasSemaModel; ASym: Integer): string;
var
  LValue, LEnum, LChild, LName, LExpr, LOrd, LLit: Integer;
  LExprText: string;
begin
  Result := '';
  LValue := AModel.Symbols[ASym].DeclNode;
  while (LValue <> NIL_NODE) and
        (AModel.Tree.Nodes[LValue].Kind <> nkEnumValue) do
    LValue := AModel.Tree.Nodes[LValue].Parent;
  if LValue = NIL_NODE then
    Exit;
  LEnum := AModel.Tree.Nodes[LValue].Parent;
  if LEnum = NIL_NODE then
    Exit;
  LOrd := -1;
  LChild := AModel.Tree.Nodes[LEnum].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LChild].Kind = nkEnumValue then
    begin
      LExprText := '';
      LName := AModel.Tree.Nodes[LChild].FirstChild;
      LExpr := NIL_NODE;
      if LName <> NIL_NODE then
        LExpr := AModel.Tree.Nodes[LName].NextSibling;
      if LExpr <> NIL_NODE then
      begin
        LExprText := Trim(AModel.Tree.NodeSpanText(LExpr));
        if TryStrToInt(LExprText, LLit) then
        begin
          LOrd := LLit;
          LExprText := '';
        end;
      end
      else
        Inc(LOrd);
      if LChild = LValue then
      begin
        if LExprText <> '' then
          Exit(LExprText);
        Exit(IntToStr(LOrd));
      end;
    end;
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

function SymbolSignatureText(AProject: TPasSemaProject; AMid, ASym: Integer;
  const AUnitFile: string; out ATypeSpans: TArray<Integer>;
  out AHeadLen: Integer): string;
var
  LModel: TPasSemaModel;
  LCompletion: TPasCompletion;
  LItem: TPasComplItem;
  LHead, LName, LDetail, LUnit, LOrdinal: string;
  LOwner, LOwnerLen, LNameStart, LDecl, LTypeSym: Integer;
  LX: TSemaXType;
  LKnownType: string;
begin
  Result := '';
  ATypeSpans := nil;
  AHeadLen := 0;
  if (AProject = nil) or (AMid < 0) or (AMid >= AProject.ModelCount) or
     (ASym = NIL_SYM) then
    Exit;
  LModel := AProject.Model(AMid);
  if (LModel = nil) or (LModel.Demoted and not AProject.EnsureHydrated(AMid)) then
    Exit;

  // An enum value as the native hint has it: `const Unit.mpIsService =
  // TMoreStuffParentIs(1)` (Alex, 2026-10-07) - unit-qualified, the ordinal
  // cast to its enum. An anonymous enum's value has no type to cast to.
  if LModel.Symbols[ASym].Kind = skEnumValue then
  begin
    LOrdinal := EnumValueText(LModel, ASym);
    if LOrdinal = '' then
      Exit;
    LUnit := ChangeFileExt(ExtractFileName(AUnitFile), '');
    LName := LModel.Symbols[ASym].Name;
    if LUnit <> '' then
      LName := LUnit + '.' + LName;
    Result := 'const ' + LName + ' = ';
    LTypeSym := LModel.Symbols[ASym].TypeSym;
    if LTypeSym <> NIL_SYM then
    begin
      ATypeSpans := [Length(Result) + 1, Length(LModel.Symbols[LTypeSym].Name)];
      Result := Result + LModel.Symbols[LTypeSym].Name + '(' + LOrdinal + ')';
    end
    else
      Result := Result + LOrdinal;
    AHeadLen := Length('const');
    Exit;
  end;

  LItem := Default(TPasComplItem);
  LItem.Name := LModel.Symbols[ASym].Name;
  LItem.Kind := LModel.Symbols[ASym].Kind;
  LItem.Bucket := cbUnitSym;
  LItem.Mid := AMid;
  LItem.Sym := ASym;
  LItem.Ctx := NIL_INST;
  LCompletion := TPasCompletion.Create(LModel, AProject, AMid);
  try
    case LItem.Kind of
      skRoutine:
        begin
          LHead := LCompletion.ItemHeadWord(LItem);
          if LHead = '' then
            LHead := 'procedure';
        end;
      skVar, skField:
        LHead := 'var';
      // The native hint's own spelling (Alex, 2026-10-07): `param [in/out]
      // CanExecute: Boolean` for a var parameter, the mode in brackets.
      skParam:
        begin
          LHead := 'param';
          LDecl := LModel.Symbols[ASym].DeclNode;
          while (LDecl <> NIL_NODE) and
                (LModel.Tree.Nodes[LDecl].Kind <> nkParam) do
            LDecl := LModel.Tree.Nodes[LDecl].Parent;
          if LDecl <> NIL_NODE then
            if nfVar in LModel.Tree.Nodes[LDecl].Flags then
              LHead := 'param [in/out]'
            else if nfOut in LModel.Tree.Nodes[LDecl].Flags then
              LHead := 'param [out]'
            else if nfConst in LModel.Tree.Nodes[LDecl].Flags then
              LHead := 'param [const]';
        end;
      skConst:
        LHead := 'const';
      skProperty:
        LHead := 'property';
      skType:
        LHead := 'type';
    else
      Exit;   // the caller keeps the declaration line
    end;
    LDetail := ItemDetailText(LCompletion, AProject, LModel, LItem, True);
  finally
    LCompletion.Free;
  end;
  // An inline variable with no written type - `var AMessage := ''` - has the
  // type the analysis INFERRED from its initializer; the declaration read
  // above has none to give (Alex, 2026-10-07: the hint showed no type).
  if (LItem.Kind = skVar) and (LDetail = '') then
  begin
    LX := AProject.DeclTypeX(AMid, ASym);
    if XValid(LX) then
      LDetail := ': ' + AProject.XTypeText(LX);
  end;
  // A member reads as the native hint has it - TOpenDialog.FileName.
  LName := LItem.Name;
  LOwnerLen := 0;
  LOwner := OwnerTypeSym(LModel, ASym);
  if LOwner <> NIL_SYM then
  begin
    LName := LModel.Symbols[LOwner].Name + '.' + LName;
    LOwnerLen := Length(LModel.Symbols[LOwner].Name);
  end;
  Result := LHead + ' ' + LName + LDetail;
  AHeadLen := Length(LHead);
  LNameStart := Length(LHead) + 2 + IfThen(LOwnerLen > 0, LOwnerLen + 1, 0);
  // A constant's value may name its own type inside a qualified value
  // (`System.UITypes.TMsgDlgBtn.mbCancel`): that segment is a type too.
  LKnownType := '';
  if LItem.Kind = skConst then
  begin
    LX := AProject.DeclTypeX(AMid, ASym);
    if XValid(LX) then
    begin
      LKnownType := AProject.XTypeText(LX);
      if LastDelimiter('.', LKnownType) > 0 then
        LKnownType := Copy(LKnownType, LastDelimiter('.', LKnownType) + 1,
          MaxInt);
    end;
  end;
  ATypeSpans := SignatureTypeSpans(Result, LOwnerLen, LNameStart,
    Length(LItem.Name), LItem.Kind = skType, LKnownType);
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
        LEntry.Detail := ItemDetailText(LCompletion, AProject, LModel,
          LItems[LIdx], LWithTypes);
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

function TLspCompletionEngine.ClassCompleteAt(const AFileName, AText: string;
  APasLine, APasCol: Integer; AProject: TPasSemaProject;
  AProjectMid: Integer; ABodyOrder: TLspBodyOrder): TLspClassCompleteAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LRepairs: TArray<TLspClassEdit>;
  LEdit: TLspClassEdit;
  LFixed, LNext: string;
  LIdx, LLine, LCol: Integer;
  LOptions: TLspClassCompleteOptions;
  LModel: TPasSemaModel;
begin
  // Parse first - class completion is a question about DECLARATIONS AND
  // BODIES, which the CST answers on its own. The resolver runs only if the
  // probe below is actually asked, which is only for a type with an ancestor
  // in another unit.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  { A BROKEN PARSE GENERATES NOTHING - except for the one break this feature
    repairs itself, a missing semicolon.

    Class completion WRITES code, and it decides what to write from the shape
    of the tree, so a tree the parser had to guess at produces guesses.
    Measured on a buffer where `property XX: Integer` had been typed and the
    `;` had not (2026-08-23): the unterminated property swallowed the rest of
    the class, every implementation in the unit stopped being one, and the
    answer was 1339 lines of bodies for methods that all already had them,
    two insertions landing inside an unrelated routine. Error tolerance is
    exactly right for the READING features - a half-typed line must still
    complete and still navigate - and exactly wrong for a generator.

    But "type the semicolon yourself first" is a bad answer to the commonest
    press of the key, so the semicolons go in AS EDITS and the file is parsed
    again. Anything still wrong after that, and the answer is a refusal that
    says where to look. }
  LFixed := AText;
  LIdx := 0;
  // Three attempts: enough for the "I typed two declarations and no
  // semicolons" case, few enough that a file which simply does not parse is
  // refused promptly rather than rewritten by guesswork.
  while (Length(LDiags) > 0) and (LIdx < 3) do
  begin
    Inc(LIdx);
    // A separate variable for the result, NOT LFixed twice: `out` clears its
    // argument before the call, so passing one variable as both the text and
    // the repaired text hands the function an empty string (cost: one
    // debugging round, 2026-08-23).
    if not TrySemicolonRepair(LTree, LDiags[0].VisIndex, LFixed, LNext,
      LLine, LCol) then
      Break;
    LFixed := LNext;
    LEdit := Default(TLspClassEdit);
    LEdit.Line := LLine;
    // Back into the ORIGINAL buffer's columns, past the repairs already made.
    LEdit.Col := MapColToOriginal(LLine, LCol, LRepairs);
    LEdit.Text := ';';
    LEdit.Kind := 'semi';
    LRepairs := LRepairs + [LEdit];
    LPre := FPreprocessor.ProcessText(AFileName, LFixed);
    LTree := TPasParser.ParseFile(LPre, LDiags);
  end;
  if Length(LDiags) > 0 then
  begin
    Result := Default(TLspClassCompleteAnswer);
    Result.Provider := Format('pastree/classComplete: refused - %d parse ' +
      'error(s) in this file, first: %s', [Length(LDiags), LDiags[0].Msg]);
    Exit;
  end;
  // The caret is in the ORIGINAL text's coordinates and the tree is the
  // repaired text's; a repair only ever adds a `;` to the right of what was
  // typed on its line, so a caret at or left of it is unmoved, and one to the
  // right of it on the same line is off by one column - which cannot move
  // it out of the type or routine it was in. Good enough to name the scope.
  LOptions := Default(TLspClassCompleteOptions);
  LOptions.BodyOrder := ABodyOrder;
  LModel := nil;
  try
    { THE PROBE: is a name `read`/`write` points at already a member the
      property can use - the type's own or any ancestor's, visible from here?
      Answered by the completion engine's own accessor position (ccPropRead/
      ccPropWrite), which walks the struct chain through the bridge into the
      unit that declares the ancestor and applies visibility - so a private
      field of a base in another unit counts as absent, which is what the
      compiler thinks too. Without it every property on a TForm or
      TInterfacedObject descendant pointing at a new field got nothing: an
      ancestor in another unit is unknown to the parse, and an unknown
      ancestor may be the field's owner (PasLsp.ClassComplete, uaviTypes).
      Only with a bridge - a standalone file keeps the conservative rule. }
    if AProject <> nil then
      LOptions.Probe :=
        function(ALine, ACol: Integer; const AName: string): Boolean
        var
          LCompletion: TPasCompletion;
          LContext: TPasComplContext;
          LItems: TArray<TPasComplItem>;
          LItem: Integer;
        begin
          Result := False;
          if LModel = nil then
            LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
          LCompletion := TPasCompletion.Create(LModel, AProject, AProjectMid);
          try
            if not LCompletion.CompleteAt(ALine, ACol, LContext, LItems) or
               not (LContext in [ccPropRead, ccPropWrite]) then
              Exit;
            for LItem := 0 to High(LItems) do
              if SameText(LItems[LItem].Name, AName) then
                Exit(True);
          finally
            LCompletion.Free;
          end;
        end;
    Result := ClassCompleteFor(LTree, APasLine, APasCol, LOptions);
  finally
    LModel.Free;
  end;
  // The answer's positions are in the REPAIRED text; the client edits the
  // original. MergeSemicolonRepairs maps them back and adds the semicolons.
  MergeSemicolonRepairs(Result, LRepairs);
end;

function TLspCompletionEngine.SyncPrototypeAt(const AFileName, AText: string;
  APasLine, APasCol: Integer): TLspSyncAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  { NO SEMICOLON REPAIR, unlike class completion, and no tolerance for a
    broken parse either. The two features fail differently: class completion
    ADDS code and can be talked into adding it in the wrong place, which the
    repair pass exists to prevent; this one REPLACES an existing header, and a
    tree the parser had to guess at is a tree whose header spans are guesses -
    a replacement range off by a token eats the code next to it. A refusal
    that names the parse error is the only safe answer. }
  if Length(LDiags) > 0 then
  begin
    Result := Default(TLspSyncAnswer);
    Result.Provider := Format('pastree/syncPrototypes: refused - %d parse '
      + 'error(s) in this file, first: %s', [Length(LDiags), LDiags[0].Msg]);
    Exit;
  end;
  Result := PasLsp.SyncPrototypes.SyncPrototypeAt(LTree, APasLine, APasCol);
end;

function TLspCompletionEngine.AnnotateArgsAt(const AFileName, AText: string;
  APasLine, APasCol: Integer; AProject: TPasSemaProject;
  AProjectMid: Integer;
  const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LModel: TPasSemaModel;
  LCompletion: TPasCompletion;
begin
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
  try
    LCompletion := TPasCompletion.Create(LModel, AProject, AProjectMid);
    try
      Result := PasLsp.AnnotateArgs.AnnotateArgsAt(LCompletion, LModel,
        AProject, APasLine, APasCol, AOptions);
    finally
      LCompletion.Free;
    end;
  finally
    LModel.Free;
  end;
end;

function TLspCompletionEngine.UsesInfoAt(const AFileName,
  AText: string): TLspUsesInfo;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  Result := ReadUsesInfo(LTree);
end;

function TLspCompletionEngine.UseUnitAt(const AFileName, AText,
  AUnitName: string; AImplementation: Boolean; const AIndent: string;
  ARightMargin: Integer): TLspUseUnitAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  // Parse errors elsewhere in the file do not matter here; one inside the
  // clause does, and UseUnitEdit refuses it through the clause's own flag.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  Result := UseUnitEdit(LTree, AText, AUnitName, AImplementation, AIndent,
    ARightMargin);
end;

function TLspCompletionEngine.UsesRemovalAt(const AFileName, AText: string;
  const ANames: TArray<string>; out ARefused, AMissing: TArray<string>)
  : TArray<TLspUsesRemoval>;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
begin
  // As UseUnitAt: a parse error inside a clause is the clause's refusal.
  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  Result := UsesRemovalByName(LTree, ANames, ARefused, AMissing);
end;

end.
