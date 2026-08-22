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
  PasTree.Sema.Nav;

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
    { Signature help at a position: the enclosing call located by a backward
      walk over VISIBLE tokens (comments and strings are single tokens there,
      nesting respected), the target resolved through the overlay's own
      RefMap or - when the analyzed text still matches - the navigator.
      INTERIM until PasTree's CallAt lands (its plan §8): a freshly typed
      call to a cross-unit routine answers empty, honestly - bridged
      designator resolution is the engine's to provide, not ours to copy. }
    function SignatureHelpAt(const AFileName, AText: string;
      APasLine, APasCol: Integer; AProject: TPasSemaProject;
      AProjectMid: Integer; ANav: TPasNavigator): TLspSignatureHelpAnswer;
  end;

implementation

uses
  System.SysUtils,
  PasTree.Parser,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Resolver,
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

{ The declaring nkRoutine node of a routine symbol - DeclNode may point at
  the name inside it, so climb (the engine's own RoutineNodeOf recipe). }
function RoutineNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
begin
  Result := AModel.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := AModel.Tree.Nodes[Result].Parent;
end;

{ The nkParams child of a routine symbol's declaration; NIL_NODE if the
  routine declares none. }
function ParamsNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
var
  LRoutine: Integer;
begin
  LRoutine := RoutineNodeOf(AModel, ASym);
  if LRoutine = NIL_NODE then
    Exit(NIL_NODE);
  Result := AModel.Tree.Nodes[LRoutine].FirstChild;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkParams) do
    Result := AModel.Tree.Nodes[Result].NextSibling;
end;

function HasParamChild(AModel: TPasSemaModel; AParamsNode: Integer): Boolean;
var
  LChild: Integer;
begin
  Result := False;
  if AParamsNode = NIL_NODE then
    Exit;
  LChild := AModel.Tree.Nodes[AParamsNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LChild].Kind = nkParam then
      Exit(True);
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

{ The source text of a node's full token span, whitespace runs collapsed to
  one space, capped for display. '' when the span crosses files (a decl split
  over an $I include - not worth reconstructing) or is degenerate. }
function NodeSpanText(const ATree: TPasTree; ANode: Integer): string;
const
  cCap = 100;
var
  LNode: TPasNode;
  LFrom, LTo: TPasVisibleToken;
  LText: string;
  LIdx, LOut: Integer;
  LCh: Char;
  LWasSpace: Boolean;
begin
  Result := '';
  LNode := ATree.Nodes[ANode];
  if (LNode.FirstToken < 0) or (LNode.LastToken < LNode.FirstToken) or
     (LNode.LastToken > High(ATree.Source.Visible)) then
    Exit;
  LFrom := ATree.Source.Visible[LNode.FirstToken];
  LTo := ATree.Source.Visible[LNode.LastToken];
  if LFrom.FileId <> LTo.FileId then
    Exit;
  with ATree.Source.Files[LFrom.FileId] do
    LText := Copy(Source, Tokens[LFrom.TokenIndex].Start + 1,
      Tokens[LTo.TokenIndex].EndPos - Tokens[LFrom.TokenIndex].Start);
  // Collapse whitespace runs in place - a multi-line param list must read
  // as one display line.
  SetLength(Result, Length(LText));
  LOut := 0;
  LWasSpace := False;
  for LIdx := 1 to Length(LText) do
  begin
    LCh := LText[LIdx];
    if CharInSet(LCh, [#9, #10, #13, ' ']) then
      LWasSpace := True
    else
    begin
      if LWasSpace and (LOut > 0) then
      begin
        Inc(LOut);
        Result[LOut] := ' ';
      end;
      LWasSpace := False;
      Inc(LOut);
      Result[LOut] := LCh;
    end;
  end;
  SetLength(Result, LOut);
  if Length(Result) > cCap then
    Result := Copy(Result, 1, cCap - 3) + '...';
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
  LItemModel: TPasSemaModel;
  LParamsNode, LTypeSym: Integer;
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
        // A routine's PARAMETER LIST, verbatim from its declaration's source
        // span - '(const AName: string; ACount: Integer)' - for the overlay
        // model and every bridged project model alike. Also decides
        // HasParams, which drives the RAD client's auto-parenthesis.
        if (LItems[LIdx].Kind = skRoutine) and
           (LItems[LIdx].Sym <> NIL_SYM) then
        begin
          if LItems[LIdx].Mid < 0 then
            LItemModel := LModel
          else if AProject <> nil then
            LItemModel := AProject.Model(LItems[LIdx].Mid)
          else
            LItemModel := nil;
          if LItemModel <> nil then
          begin
            LParamsNode := ParamsNodeOf(LItemModel, LItems[LIdx].Sym);
            LEntry.HasParams := HasParamChild(LItemModel, LParamsNode);
            if LParamsNode <> NIL_NODE then
              LEntry.Detail := NodeSpanText(LItemModel.Tree, LParamsNode);
          end;
        end;
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
  AProjectMid: Integer; ANav: TPasNavigator): TLspSignatureHelpAnswer;
var
  LPre: TPasPreprocessed;
  LTree: TPasTree;
  LDiags: TArray<TPasParseDiag>;
  LModel, LTargetModel: TPasSemaModel;
  LCompletion: TPasCompletion;
  LInfo: TPasCaretInfo;
  LCaretOfs, LVisIdx, LOpenVis, LIdentVis, LDepth, LArgs, LSteps: Integer;
  LIdentLine, LIdentCol, LTMid, LSym, LNext, LCount: Integer;
  LIdentText, LNavName, LParamsText, LSuffix: string;
  LTargetProject: Boolean;
  LSig: TLspSignatureItem;

  function VisKind(AVis: Integer): TPasTokenKind;
  begin
    with LTree.Source.Visible[AVis] do
      Result := LTree.Source.Files[FileId].Tokens[TokenIndex].Kind;
  end;

  function VisStart(AVis: Integer): Integer;
  begin
    with LTree.Source.Visible[AVis] do
      Result := LTree.Source.Files[FileId].Tokens[TokenIndex].Start;
  end;

begin
  Result := Default(TLspSignatureHelpAnswer);
  Result.Provider := 'pastree-interim/none';
  if (APasLine < 1) or (APasCol < 1) then
    Exit;

  LPre := FPreprocessor.ProcessText(AFileName, AText);
  LTree := TPasParser.ParseFile(LPre, LDiags);
  LModel := TPasSemaResolver.Analyze(LTree, False, FPlatform);
  try
    // The caret as an offset into the main file, clamped like every host
    // position (LineStarts is the lexer's own line map).
    with LTree.Source.Files[0] do
    begin
      if APasLine > Length(LineStarts) then
        Exit;
      LCaretOfs := LineStarts[APasLine - 1] + (APasCol - 1);
    end;

    { The last main-file visible token that STARTS before the caret - the
      anchor of the backward walk. Comments never appear here (visible
      stream), strings/numbers are single tokens, so the walk cannot be
      fooled by parens inside either. }
    LVisIdx := -1;
    for LIdentVis := 0 to High(LTree.Source.Visible) do
      if LTree.Source.Visible[LIdentVis].FileId = 0 then
      begin
        // Include-file tokens carry offsets into THEIR file - they must be
        // skipped, never compared against the main file's caret offset.
        if VisStart(LIdentVis) >= LCaretOfs then
          Break;
        LVisIdx := LIdentVis;
      end;
    if LVisIdx < 0 then
      Exit;

    // Backward: nesting over ()/[], top-level commas count arguments, and a
    // statement boundary at depth 0 means the caret is in no call at all.
    LOpenVis := -1;
    LDepth := 0;
    LArgs := 0;
    LSteps := 0;
    while (LVisIdx >= 0) and (LSteps < 2000) do
    begin
      if LTree.Source.Visible[LVisIdx].FileId = 0 then
        case VisKind(LVisIdx) of
          tkRParen, tkRBracket:
            Inc(LDepth);
          tkLBracket:
            begin
              if LDepth = 0 then
                Exit;   // inside an indexer, not a call - v1 declines
              Dec(LDepth);
            end;
          tkLParen:
            begin
              if LDepth = 0 then
              begin
                LOpenVis := LVisIdx;
                Break;
              end;
              Dec(LDepth);
            end;
          tkComma:
            if LDepth = 0 then
              Inc(LArgs);
          tkSemicolon, tkBegin, tkEnd, tkThen, tkDo, tkElse:
            if LDepth = 0 then
              Exit;   // left the statement without meeting an open paren
        end;
      Dec(LVisIdx);
      Inc(LSteps);
    end;
    if (LOpenVis <= 0) or
       (LTree.Source.Visible[LOpenVis - 1].FileId <> 0) or
       (VisKind(LOpenVis - 1) <> tkIdentifier) then
      Exit;   // no call, or a designator shape v1 does not resolve
    LIdentVis := LOpenVis - 1;

    with LTree.Source.Visible[LIdentVis] do
      LIdentText := LTree.Source.Files[FileId].TokenText(TokenIndex);
    LTree.Source.Files[0].OffsetToLineCol(VisStart(LIdentVis),
      LIdentLine, LIdentCol);
    LTree.Source.Files[0].OffsetToLineCol(VisStart(LOpenVis),
      Result.CallLine, Result.CallCol);

    { Resolve the name. Overlay RefMap first (locals and own-unit routines,
      correct even mid-typing); then the last-good navigator, accepted only
      when the analyzed text still holds THIS identifier at THIS position -
      otherwise a shifted buffer would show a neighbor's signature. }
    LTargetModel := nil;
    LTargetProject := False;
    LSym := NIL_SYM;
    LCompletion := TPasCompletion.Create(LModel, AProject, AProjectMid);
    try
      if LCompletion.CaretAt(LIdentLine, LIdentCol + 1, LInfo) and
         (LInfo.Kind = ckIdent) and (LInfo.Node <> NIL_NODE) and
         (LInfo.Node <= High(LModel.RefMap)) then
        LSym := LModel.RefMap[LInfo.Node];
      if (LSym <> NIL_SYM) and (LModel.Symbols[LSym].Kind = skRoutine) then
        LTargetModel := LModel
      else
      begin
        LSym := NIL_SYM;
        if (ANav <> nil) and (AProject <> nil) and (AProjectMid >= 0) and
           ANav.SymbolAt(AProjectMid, LIdentLine, LIdentCol, LTMid, LSym,
             LNavName) and SameText(LNavName, LIdentText) then
        begin
          LTargetModel := AProject.Model(LTMid);
          LTargetProject := True;
          if LTargetModel.Symbols[LSym].Kind <> skRoutine then
          begin
            LTargetModel := nil;
            LSym := NIL_SYM;
          end;
        end
        else
          LSym := NIL_SYM;
      end;

      if LTargetModel = nil then
        Exit;   // honest empty: the engine's CallAt owns this case one day

      // The overload chain, each as its own signature.
      LNext := LSym;
      LCount := 0;
      while (LNext <> NIL_SYM) and (LCount < 16) do
      begin
        LParamsText := '';
        LIdentVis := ParamsNodeOf(LTargetModel, LNext);
        if LIdentVis <> NIL_NODE then
          LParamsText := NodeSpanText(LTargetModel.Tree, LIdentVis);
        LSuffix := '';
        if LTargetProject then
        begin
          if XValid(AProject.SymDeclTypeX(LTMid, LNext)) then
            LSuffix := ': '
              + AProject.XTypeText(AProject.SymDeclTypeX(LTMid, LNext));
        end
        else if LTargetModel.Symbols[LNext].TypeSym <> NIL_SYM then
          LSuffix := ': '
            + LTargetModel.Symbols[LTargetModel.Symbols[LNext].TypeSym].Name;
        LSig.SigLabel := LTargetModel.Symbols[LNext].Name + LParamsText
          + LSuffix;
        LSig.Params := SplitParamLabels(LParamsText);
        Result.Signatures := Result.Signatures + [LSig];
        LNext := LTargetModel.Symbols[LNext].NextOverload;
        Inc(LCount);
      end;
    finally
      LCompletion.Free;
    end;

    Result.ActiveParam := LArgs;
    // Prefer the first overload that still has a parameter for the argument
    // being typed; the first one otherwise.
    Result.ActiveSignature := 0;
    for LCount := 0 to High(Result.Signatures) do
      if Length(Result.Signatures[LCount].Params) > LArgs then
      begin
        Result.ActiveSignature := LCount;
        Break;
      end;
    if LTargetProject then
      Result.Provider := 'pastree-interim/project'
    else
      Result.Provider := 'pastree-interim/overlay';
  finally
    LModel.Free;
  end;
end;

end.
