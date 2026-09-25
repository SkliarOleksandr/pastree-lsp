unit PasLsp.AnnotateArgs;

(*
  Argument annotation: the parameter names of a call, written into the call
  as brace comments - `Open({AFileName:} S, {var} {AMode:} M)` - the way a
  Delphi programmer already does by hand for a call whose arguments do not
  explain themselves. Other IDEs paint this as inlay hints; the RAD Studio
  editor cannot show text that is not in the buffer, so the hint IS text, and
  the user asked for exactly this spelling (Alex, 2026-09-14): `{Name:}` in
  front of the argument, and `{var}` / `{out}` between the two when the
  parameter is passed by reference - the one thing a call site never shows
  and the reader most wants to know. ALWAYS IN THAT ORDER, name then mark,
  whichever of the two was there first (Alex, 2026-09-15).

  THE CARET READS THE SCOPE, THE OPTIONS OVERRIDE IT (TLspAnnotateOptions):

  - the caret INSIDE the argument list means the ONE argument it is in;
  - the caret ON THE ROUTINE'S NAME means EVERY argument of that call;
  - an explicit mode - all / only the anonymous arguments (a literal, an
    expression, a call: not an identifier that names itself) / only the
    current one - is what the IDE's dialog sends (Alex, 2026-09-14), plus
    the `{var}`/`{out}` marks on or off and, as a layout choice about the
    whole call, one argument per line.

  The server decides everything by looking at the caret and the options, so
  the client never has to understand the call.

  THE OVERLOAD MUST BE THE RIGHT ONE, or the names are lies. The resolver's
  own choice is used whenever it made one (TPasCallInfo.BoundExact, PasTree
  0.29.0 - SelectOverload's arity-and-type winner for a call it could see
  through); when it did not - a cross-unit family bridged by name, a member
  found by lookup - the family is narrowed by ARITY here, and a family that
  two or more members still fit is REFUSED by count rather than guessed at.
  A wrong `{Count:}` is worse than none: it reads as documentation.

  IDEMPOTENT: an argument already carrying `{Name:}` (any name - the user may
  have written a better one) or `{var}`/`{out}`/`{const}` is left alone, so
  running the command twice, or over a half-annotated call, adds only what is
  missing.

  NOT ANNOTATED, deliberately:

  - an argument beyond the parameter list (a `varargs` routine's extras);
  - a NAMED argument (`Name := Expr`, OLE automation) - it names itself;
  - the VARIADIC tail of an intrinsic (Write's Args, Concat's `...`) - the
    arguments it absorbs are all "the arguments". The rest of an intrinsic's
    parameters ARE named (Alex, 2026-09-14: "the docs have names too"), from
    the engine's curated signature table, aligned to the call's argument
    count so `Inc(X)` and `Inc(X, N)` both read right - BuiltinParamsFor;
  - a call through a PROCEDURAL VALUE whose type cannot be followed to a
    `procedure(...)`. When it can - and it nearly always can: the value's
    declared type, through aliases and across units, to the nkProcType
    (ProcTypeOf) - the type's parameter names are used; a call is a call
    (Alex, 2026-09-15).

  Everything here is a pure function of one analyzed overlay model plus the
  last-good project analysis it bridges to - the same inputs signature help
  has - so it answers about the buffer as it is being typed, never about a
  build. Positions are 1-based PasTree coordinates of the MAIN file; an
  argument living in an $I include is skipped (the client applies edits to
  one buffer).
*)

interface

uses
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Complete;

type
  (* Which arguments get a name. amAuto is the caret's own reading - inside
    the list means the one argument there, on the name means all - and is
    what a client with no dialog asks for. amAnonymous is the convention the
    inlay-hint IDEs default to: only the arguments that do not name themselves
    - a literal, an expression, a call - while `DoIt(Count)` is left alone.
    amNone names nothing: the `{var}`/`{out}` marks and the layout alone,
    for a call whose names are already there or not wanted. *)
  TLspAnnotateMode = (amAuto, amAll, amAnonymous, amCurrent, amNone);

  TLspAnnotateOptions = record
    Mode: TLspAnnotateMode;
    (* `{var}` / `{out}` in front of the name for a by-reference parameter. *)
    MarkByRef: Boolean;
    { Every argument of the call on a line of its own, indented one level
      under the call's line - a layout choice about the WHOLE call, so it
      applies to every argument whatever Mode selects for naming. An argument
      already starting its line is left where it is. }
    OneArgPerLine: Boolean;
  end;

  (* One edit, 1-based PasTree coordinates, end EXCLUSIVE. A plain annotation
    is zero-length (End = start): Text goes in FRONT of the character there,
    trailing space included so `{Name:} Arg` reads with a gap. With
    OneArgPerLine the range covers the whitespace between the previous `(` or
    `,` and the argument (or its existing leading comments), and Text starts
    with the line break and the indent - a REPLACEMENT, so a client must
    honour the end. *)
  TLspAnnotateEdit = record
    Line: Integer;
    Col: Integer;
    EndLine: Integer;
    EndCol: Integer;
    Text: string;
  end;

  TLspAnnotateAnswer = record
    Edits: TArray<TLspAnnotateEdit>;
    { The CARET's reading, whatever the options then did with it: 'one' -
      inside the arguments; 'all' - on the routine's name; '' - no call at
      the caret, Provider says so. The menu gate and the dialog read this. }
    Scope: string;
    { The routine as resolved - 'TFoo.Bar(A: Integer; var B: string)' - for
      the log and the IDE's report. '' when nothing resolved. }
    Routine: string;
    { Names the outcome; every refusal says WHY. }
    Provider: string;
  end;

{ The annotation edits for the call at (APasLine, APasCol). ACompletion is a
  TPasCompletion over the overlay model AModel (both built by the caller from
  the LIVE text, exactly as signature help builds them), bridged to AProject
  (nil standalone). Never raises; every refusal is an empty edit list with a
  Provider that says why, and Scope still set when a call WAS found - the
  menu wants "this is a call, and nothing needed doing" told apart from "no
  call here". }
function AnnotateArgsAt(ACompletion: TPasCompletion; AModel: TPasSemaModel;
  AProject: TPasSemaProject; APasLine, APasCol: Integer;
  const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;

{ The options a client that asks for nothing gets: the caret decides the
  scope, by-reference parameters are marked, the layout is left alone. }
function DefaultAnnotateOptions: TLspAnnotateOptions;

implementation

uses
  System.SysUtils,
  PasTree.Types,
  PasTree.Preprocessor;

const
  cProvider = 'pastree/annotateArgs';

type
  { One declared parameter, flattened: `A, B: Integer` is two of these. }
  TParamInfo = record
    Name: string;
    Modifier: string;   // 'var' / 'out' / 'const' / '' (as declared)
    HasDefault: Boolean;
  end;

{ 1-based (line, col) of a visible token's first character, main file only -
  see PasLsp.SyncPrototypes.TokenStart for why an include's token is refused. }
function VisStart(const ATree: TPasTree; AVis: Integer;
  out ALine, ACol: Integer): Boolean;
var
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  if LVis.FileId <> 0 then
    Exit;
  ATree.Source.Files[0].OffsetToLineCol(
    ATree.Source.Files[0].Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := True;
end;

{ ... and just past its last character. }
function VisEnd(const ATree: TPasTree; AVis: Integer;
  out ALine, ACol: Integer): Boolean;
var
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  if LVis.FileId <> 0 then
    Exit;
  ATree.Source.Files[0].OffsetToLineCol(
    ATree.Source.Files[0].Tokens[LVis.TokenIndex].EndPos, ALine, ACol);
  Result := True;
end;

function PosLE(ALine, ACol, BLine, BCol: Integer): Boolean;
begin
  Result := (ALine < BLine) or ((ALine = BLine) and (ACol <= BCol));
end;

{ The NAME node of a call's designator: `Foo` in `Foo(`, the `Bar` of
  `A.B.Bar(`, the `Foo` of `Foo<T>(`; NIL_NODE when the callee is not a
  named thing (an indexed result being called, a dereference). }
function CalleeNameNode(const ATree: TPasTree; ACall: Integer): Integer;
var
  LPeel: Integer;
begin
  Result := ATree.Nodes[ACall].FirstChild;
  LPeel := 0;
  while (Result <> NIL_NODE) and (LPeel < 8) do
  begin
    case ATree.Nodes[Result].Kind of
      nkParen, nkTypeArgs:
        Result := ATree.Nodes[Result].FirstChild;
      nkMember:
        begin
          // The member name is the LAST child; the base comes first.
          Result := ATree.Nodes[Result].FirstChild;
          while (Result <> NIL_NODE) and
                (ATree.Nodes[Result].NextSibling <> NIL_NODE) do
            Result := ATree.Nodes[Result].NextSibling;
        end;
      nkIdent:
        Exit;
    else
      Exit(NIL_NODE);
    end;
    Inc(LPeel);
  end;
  Result := NIL_NODE;
end;

{ The nkCall whose designator NAME the caret sits on (or at the right edge
  of), NIL_NODE when none. A caret is on exactly one identifier token, and
  an identifier is the name of at most one call, so the first match is the
  match. }
function CallNamedAt(const ATree: TPasTree; APasLine, APasCol: Integer): Integer;
var
  LIdx, LName, LFirst, LLast: Integer;
  LStartLine, LStartCol, LEndLine, LEndCol: Integer;
begin
  Result := NIL_NODE;
  for LIdx := 0 to High(ATree.Nodes) do
  begin
    if ATree.Nodes[LIdx].Kind <> nkCall then
      Continue;
    LName := CalleeNameNode(ATree, LIdx);
    if LName = NIL_NODE then
      Continue;
    if not ATree.NodeVisRange(LName, LFirst, LLast) then
      Continue;
    if not VisStart(ATree, LFirst, LStartLine, LStartCol) or
       not VisEnd(ATree, LLast, LEndLine, LEndCol) then
      Continue;
    if PosLE(LStartLine, LStartCol, APasLine, APasCol) and
       PosLE(APasLine, APasCol, LEndLine, LEndCol) then
      Exit(LIdx);
  end;
end;

{ The routine node a symbol declares, climbed from its name. }
function RoutineNodeOf(AModel: TPasSemaModel; ASym: Integer): Integer;
begin
  Result := AModel.Symbols[ASym].DeclNode;
  while (Result <> NIL_NODE) and
        (AModel.Tree.Nodes[Result].Kind <> nkRoutine) do
    Result := AModel.Tree.Nodes[Result].Parent;
end;

function IsVarargs(AModel: TPasSemaModel; ARoutine: Integer): Boolean;
var
  LChild: Integer;
begin
  Result := False;
  LChild := AModel.Tree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if (AModel.Tree.Nodes[LChild].Kind = nkDirective) and
       AModel.Tree.NodeTextEquals(LChild, 'varargs') then
      Exit(True);
    LChild := AModel.Tree.Nodes[LChild].NextSibling;
  end;
end;

{ The declared parameters of a routine symbol, flattened one per NAME, in
  order. False when the symbol has no parameter list to read (a builtin, a
  declaration the tree lost). An empty list with True is a parameterless
  routine. }
function ParamsOfNode(AModel: TPasSemaModel; AOwner: Integer;
  out AParams: TArray<TParamInfo>): Boolean; forward;

function ParamsOf(AModel: TPasSemaModel; ASym: Integer;
  out AParams: TArray<TParamInfo>; out AVarargs: Boolean): Boolean;
var
  LRoutine: Integer;
begin
  Result := False;
  AParams := nil;
  AVarargs := False;
  if (ASym = NIL_SYM) or (sfBuiltin in AModel.Symbols[ASym].Flags) then
    Exit;
  LRoutine := RoutineNodeOf(AModel, ASym);
  if LRoutine = NIL_NODE then
    Exit;
  AVarargs := IsVarargs(AModel, LRoutine);
  Result := ParamsOfNode(AModel, LRoutine, AParams);
end;

{ The parameters declared under AOwner - an nkRoutine or an nkProcType, the
  two nodes that own an nkParams - flattened one per NAME, in order. True
  with an empty list for `procedure Foo;` (no list at all). }
function ParamsOfNode(AModel: TPasSemaModel; AOwner: Integer;
  out AParams: TArray<TParamInfo>): Boolean;
var
  LParams, LParam, LChild, LVis, LNameVis: Integer;
  LModifier: string;
  LNames: TArray<string>;
  LHasDefault: Boolean;
  LNonName: Integer;
  LIdx: Integer;
  LInfo: TParamInfo;
begin
  AParams := nil;
  if AOwner = NIL_NODE then
    Exit(False);
  LParams := AModel.Tree.Nodes[AOwner].FirstChild;
  while (LParams <> NIL_NODE) and
        (AModel.Tree.Nodes[LParams].Kind <> nkParams) do
    LParams := AModel.Tree.Nodes[LParams].NextSibling;
  Result := True;
  if LParams = NIL_NODE then
    Exit;
  LParam := AModel.Tree.Nodes[LParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if AModel.Tree.Nodes[LParam].Kind = nkParam then
    begin
      LNames := nil;
      LModifier := '';
      LHasDefault := False;
      LNonName := 0;
      LNameVis := -1;
      LChild := AModel.Tree.Nodes[LParam].FirstChild;
      while LChild <> NIL_NODE do
      begin
        case AModel.Tree.Nodes[LChild].Kind of
          nkIdent:
            // A plain type name (`: string`, `: Integer`) is an nkIdent child
            // too, and nothing but the colon in front of it tells it from a
            // parameter name - so the colon is what is checked.
            if (AModel.Tree.Nodes[LChild].FirstToken > 0) and
               AModel.Tree.Source.VisibleTextEquals(
                 AModel.Tree.Nodes[LChild].FirstToken - 1, ':') then
              Inc(LNonName)
            else
            begin
              LNames := LNames + [AModel.Tree.NodeText(LChild)];
              if LNameVis < 0 then
                LNameVis := AModel.Tree.Nodes[LChild].FirstToken;
            end;
          nkAttrGroup, nkAttribute:
            ;   // `[Ref]`, `[weak]` - not a name, not the type
        else
          // Children after the names: the TYPE, then the DEFAULT. A
          // parameter with no type (`procedure P(X)`, untyped) has neither.
          Inc(LNonName);
        end;
        if LNonName = 2 then
          LHasDefault := True;
        LChild := AModel.Tree.Nodes[LChild].NextSibling;
      end;
      // The modifier is a token in FRONT of the first name, past any
      // attribute group: var / const / out (the parser records `out` in
      // Aux because it is a directive word, but its text is enough here).
      LVis := AModel.Tree.Nodes[LParam].FirstToken;
      while (LVis >= 0) and (LVis < LNameVis) do
      begin
        if AModel.Tree.Source.VisibleTextEquals(LVis, 'var') then
          LModifier := 'var'
        else if AModel.Tree.Source.VisibleTextEquals(LVis, 'out') then
          LModifier := 'out'
        else if AModel.Tree.Source.VisibleTextEquals(LVis, 'const') then
          LModifier := 'const';
        Inc(LVis);
      end;
      for LIdx := 0 to High(LNames) do
      begin
        LInfo.Name := LNames[LIdx];
        LInfo.Modifier := LModifier;
        LInfo.HasDefault := LHasDefault;
        AParams := AParams + [LInfo];
      end;
    end;
    LParam := AModel.Tree.Nodes[LParam].NextSibling;
  end;
end;

(* The parameters of an INTRINSIC, read off the engine's display text -
  `(var F: File; var Buf; Count: Integer[; var AmtTransferred: Integer])` -
  and ALIGNED to the call's argument count, because the text has shapes a
  declaration never has:

  - `[...]` groups are OPTIONAL and may sit at either end: `(var X[; N])`
    trails, `([var F: Text;] Args)` leads. The call decides which are in
    play: every required parameter is, and optional ones are taken in order
    until the argument count is met - so `Inc(X)` names X alone, `Inc(X, 2)`
    names both, and `Read(S)` skips the file.
  - `Args` and `...` are a VARIADIC tail (Write, Concat, Format-likes): the
    arguments it absorbs get no name - they are all "the arguments" - and a
    call that reaches only the tail answers False, "nothing to name".
  - Str's `X[: Width[: Decimals]]` is a formatting suffix, not parameters:
    everything after the first colon of a segment is the type and is dropped.

  Entries beyond the aligned list are '' names, which the caller skips. *)
function BuiltinParamsFor(const AParamsText: string; AArgCount: Integer;
  out AParams: TArray<TParamInfo>): Boolean;
var
  LText, LSeg, LWord: string;
  LSegments, LNames: TArray<string>;
  LDepth, LIdx, LNameIdx, LRequired, LExtra, LColon: Integer;
  LOptional, LVariadic: TArray<Boolean>;
  LOpt, LAnyNamed: Boolean;
  LInfo: TParamInfo;
  LAll: TArray<TParamInfo>;
begin
  Result := False;
  AParams := nil;
  LText := Trim(AParamsText);
  if (LText <> '') and (LText[1] = '(') then
    LText := Copy(LText, 2, Length(LText) - 1);
  if (LText <> '') and (LText[Length(LText)] = ')') then
    LText := Copy(LText, 1, Length(LText) - 1);
  // Split on ';', remembering for each segment whether it sits inside a
  // bracket group. A segment is optional when a '[' opens before its first
  // character (`[var F: Text;]`, `[; N]` - the bracket in front of the ';'
  // opens the NEXT segment's group) or when a group is still open where it
  // starts; a ']' closing before its first character takes that back.
  LSegments := nil;
  LOptional := nil;
  LDepth := 0;
  LSeg := '';
  LOpt := False;
  for LIdx := 1 to Length(LText) do
    case LText[LIdx] of
      '[':
        begin
          Inc(LDepth);
          if Trim(LSeg) = '' then
            LOpt := True;
        end;
      ']':
        begin
          Dec(LDepth);
          if Trim(LSeg) = '' then
            LOpt := False;
        end;
      ';':
        begin
          LSegments := LSegments + [LSeg];
          LOptional := LOptional + [LOpt];
          LSeg := '';
          LOpt := LDepth > 0;
        end;
    else
      LSeg := LSeg + LText[LIdx];
    end;
  if Trim(LSeg) <> '' then
  begin
    LSegments := LSegments + [LSeg];
    LOptional := LOptional + [LOpt];
  end;

  // Each segment: [var|const|out] Name{, Name} [: anything].
  LAll := nil;
  LVariadic := nil;
  for LIdx := 0 to High(LSegments) do
  begin
    LSeg := Trim(LSegments[LIdx]);
    LColon := Pos(':', LSeg);
    if LColon > 0 then
      LSeg := Trim(Copy(LSeg, 1, LColon - 1));
    LInfo := Default(TParamInfo);
    LWord := LowerCase(Copy(LSeg, 1, Pos(' ', LSeg + ' ') - 1));
    if (LWord = 'var') or (LWord = 'const') or (LWord = 'out') then
    begin
      LInfo.Modifier := LWord;
      LSeg := Trim(Copy(LSeg, Length(LWord) + 1, MaxInt));
    end;
    LNames := LSeg.Split([','], TStringSplitOptions.ExcludeEmpty);
    for LNameIdx := 0 to High(LNames) do
    begin
      LInfo.Name := Trim(LNames[LNameIdx]);
      if LInfo.Name = '' then
        Continue;
      LInfo.HasDefault := LOptional[LIdx];
      LAll := LAll + [LInfo];
      LVariadic := LVariadic + [(LInfo.Name = '...') or
        SameText(LInfo.Name, 'Args')];
    end;
  end;

  // Align to the call: every required parameter, then optional ones in
  // order while arguments remain to be matched. The variadic tail absorbs
  // whatever is left, nameless.
  LRequired := 0;
  for LIdx := 0 to High(LAll) do
    if not LAll[LIdx].HasDefault and not LVariadic[LIdx] then
      Inc(LRequired);
  LExtra := AArgCount - LRequired;
  // A variadic tail claims at least one argument before any optional
  // parameter may: `Write(S)` is Args alone, `Write(F, S)` is F and Args.
  for LIdx := 0 to High(LAll) do
    if LVariadic[LIdx] then
    begin
      Dec(LExtra);
      Break;
    end;
  LAnyNamed := False;
  for LIdx := 0 to High(LAll) do
  begin
    if LVariadic[LIdx] then
      Break;
    if LAll[LIdx].HasDefault then
    begin
      if LExtra <= 0 then
        Continue;
      Dec(LExtra);
    end;
    AParams := AParams + [LAll[LIdx]];
    LAnyNamed := True;
  end;
  Result := LAnyNamed;
end;

function RequiredCount(const AParams: TArray<TParamInfo>): Integer;
begin
  Result := 0;
  while (Result < Length(AParams)) and not AParams[Result].HasDefault do
    Inc(Result);
end;

{ The `procedure(...)` / `function(...)` type node behind a procedural VALUE
  (a var, field, parameter or property), followed from the symbol's declared
  type expression: an inline nkProcType is the answer itself; a type NAME is
  resolved through the model's RefMap (or ExtRefMap into another unit of the
  project) to the type symbol, whose own TypeNode is followed in turn - so an
  alias chain and a cross-unit type both arrive. Bounded to a few hops. }
function ProcTypeOf(AModel: TPasSemaModel; AProject: TPasSemaProject;
  ASym: Integer; out AOwnerModel: TPasSemaModel;
  out ANode: Integer): Boolean;
var
  LModel: TPasSemaModel;
  LSym, LNode, LHops, LPeel: Integer;
  LExt: TPasExtRef;
begin
  Result := False;
  AOwnerModel := nil;
  ANode := NIL_NODE;
  LModel := AModel;
  LSym := ASym;
  LHops := 0;
  while (LModel <> nil) and (LSym <> NIL_SYM) and (LHops < 8) do
  begin
    LNode := LModel.Symbols[LSym].TypeNode;
    // A TYPE symbol carries no TypeNode; its declaration does - the last
    // child of the nkTypeDecl is the type expression (`= procedure(...)`,
    // `= TOther`), past the name and any generic parameters.
    if (LNode = NIL_NODE) and (LModel.Symbols[LSym].Kind = skType) then
    begin
      LNode := LModel.Symbols[LSym].DeclNode;
      while (LNode <> NIL_NODE) and
            (LModel.Tree.Nodes[LNode].Kind <> nkTypeDecl) do
        LNode := LModel.Tree.Nodes[LNode].Parent;
      if LNode <> NIL_NODE then
      begin
        LNode := LModel.Tree.Nodes[LNode].FirstChild;
        while (LNode <> NIL_NODE) and
              (LModel.Tree.Nodes[LNode].NextSibling <> NIL_NODE) do
          LNode := LModel.Tree.Nodes[LNode].NextSibling;
      end;
    end;
    LPeel := 0;
    while (LNode <> NIL_NODE) and (LPeel < 4) and
          (LModel.Tree.Nodes[LNode].Kind = nkParen) do
    begin
      LNode := LModel.Tree.Nodes[LNode].FirstChild;
      Inc(LPeel);
    end;
    if LNode = NIL_NODE then
    begin
      // No type expression on this symbol (a symbol typed by inference);
      // its resolved type symbol may still lead on.
      LSym := LModel.Symbols[LSym].TypeSym;
      Inc(LHops);
      Continue;
    end;
    case LModel.Tree.Nodes[LNode].Kind of
      nkProcType:
        begin
          AOwnerModel := LModel;
          ANode := LNode;
          Exit(True);
        end;
      nkIdent, nkMember:
        begin
          // The name's last identifier carries the binding.
          if LModel.Tree.Nodes[LNode].Kind = nkMember then
          begin
            LNode := LModel.Tree.Nodes[LNode].FirstChild;
            while (LNode <> NIL_NODE) and
                  (LModel.Tree.Nodes[LNode].NextSibling <> NIL_NODE) do
              LNode := LModel.Tree.Nodes[LNode].NextSibling;
            if LNode = NIL_NODE then
              Exit;
          end;
          if (AProject <> nil) and LModel.ExtRefMap.TryGetValue(LNode, LExt) then
          begin
            LModel := AProject.Model(LExt.UnitId);
            // The owner's parameter list is read as TEXT - see ModelOf.
            if (LModel <> nil) and LModel.Demoted and
               not AProject.EnsureHydrated(LExt.UnitId) then
              Exit;
            LSym := LExt.Sym;
          end
          else if (LNode <= High(LModel.RefMap)) and
                  (LModel.RefMap[LNode] <> NIL_SYM) then
            LSym := LModel.RefMap[LNode]
          else
            LSym := LModel.Symbols[LSym].TypeSym;
        end;
    else
      Exit;   // an array, a class, a record - not callable through here
    end;
    Inc(LHops);
  end;
end;

{ The model a target's symbol lives in: the overlay itself for Mid -1, the
  project's model otherwise; nil when the project no longer has it.
  Rehydrated when it is demoted: a callee in the library has had its text
  freed after the full build (TLspServer.DemoteLibraryText), and its
  parameter names and modifiers are read off its tokens. A stream that cannot
  be reproduced is nil here too - no annotation rather than a fault. }
function ModelOf(AOverlay: TPasSemaModel; AProject: TPasSemaProject;
  AMid: Integer): TPasSemaModel;
begin
  if AMid < 0 then
    Exit(AOverlay);
  if AProject = nil then
    Exit(nil);
  Result := AProject.Model(AMid);
  if (Result <> nil) and Result.Demoted and
     not AProject.EnsureHydrated(AMid) then
    Result := nil;
end;

(* The brace comments IMMEDIATELY before a visible token, over whitespace only,
  lower-cased and without their braces: `{var} {Count:} X` yields
  ['count:', 'var'] for X (nearest first). Anything else - code, a `//`
  comment, a line break is fine but a directive is not - ends the run. *)
function LeadingBraceComments(const ATree: TPasTree;
  AVis: Integer): TArray<string>;
var
  LVis: TPasVisibleToken;
  LRaw: Integer;
  LText: string;
begin
  Result := nil;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  LRaw := LVis.TokenIndex - 1;
  with ATree.Source.Files[LVis.FileId] do
    while LRaw >= 0 do
    begin
      case Tokens[LRaw].Kind of
        tkWhitespace:
          ;
        tkCommentBrace:
          begin
            LText := TokenText(Tokens[LRaw]);
            if (Length(LText) >= 2) and (LText[1] = '{') and
               (LText[Length(LText)] = '}') then
              LText := Copy(LText, 2, Length(LText) - 2);
            Result := Result + [Trim(LText).ToLowerInvariant];
          end;
      else
        Exit;
      end;
      Dec(LRaw);
    end;
end;

{ The gap in front of an argument: from the end of the previous CODE token
  (the `(` or the `,`) to the argument's first leading brace comment - or to
  the argument itself when it has none. (AGapLine, AGapCol) is the gap's
  start, (AInsLine, AInsCol) the insertion point at its end; AOnOwnLine is
  True when the whitespace between the code token and the insertion point
  already breaks the line. False when the argument is in an include file. }
function GapBefore(const ATree: TPasTree; AVis: Integer;
  out AGapLine, AGapCol, AInsLine, AInsCol: Integer;
  out AOnOwnLine: Boolean): Boolean;
var
  LVis: TPasVisibleToken;
  LRaw, LInsRaw: Integer;
begin
  Result := False;
  AOnOwnLine := False;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  if LVis.FileId <> 0 then
    Exit;
  LInsRaw := LVis.TokenIndex;
  LRaw := LInsRaw - 1;
  with ATree.Source.Files[0] do
  begin
    while LRaw >= 0 do
    begin
      case Tokens[LRaw].Kind of
        tkWhitespace:
          if TokenText(Tokens[LRaw]).Contains(#10) then
            AOnOwnLine := True;
        tkCommentBrace:
          begin
            LInsRaw := LRaw;
            AOnOwnLine := False;   // only the whitespace BEFORE the run counts
          end;
      else
        Break;
      end;
      Dec(LRaw);
    end;
    if LRaw < 0 then
      Exit;
    OffsetToLineCol(Tokens[LRaw].EndPos, AGapLine, AGapCol);
    OffsetToLineCol(Tokens[LInsRaw].Start, AInsLine, AInsCol);
  end;
  Result := True;
end;

{ The leading whitespace of the line a visible token is on - the indent an
  argument moved to its own line is based on. }
function LineIndentOf(const ATree: TPasTree; AVis: Integer): string;
var
  LLine, LCol, LIdx: Integer;
  LText: string;
begin
  Result := '';
  if not VisStart(ATree, AVis, LLine, LCol) then
    Exit;
  LText := ATree.Source.Files[0].LineText(LLine);
  LIdx := 1;
  while (LIdx <= Length(LText)) and CharInSet(LText[LIdx], [' ', #9]) do
    Inc(LIdx);
  Result := Copy(LText, 1, LIdx - 1);
end;

{ An argument that does not name itself: anything but a plain identifier or
  a member chain (`Count`, `Self.FCount`, `Rec.Field`), which read as their
  own annotation. }
function IsAnonymousArg(AModel: TPasSemaModel; AProject: TPasSemaProject;
  AArg: Integer): Boolean;
var
  LNode: Integer;
  LExt: TPasExtRef;
  LText: string;
  LKind: TSemaSymbolKind;
begin
  if not (AModel.Tree.Nodes[AArg].Kind in [nkIdent, nkMember]) then
    Exit(True);
  { A name that is a CONSTANT reads as a literal, not as a name: `True`,
    `False`, `nil`, `MaxInt`, an enum value, a declared const
    (ActiveRoutineTarget(True, ...) - Alex, 2026-09-15). The binding says
    which; an unbound True/False/nil is caught by its spelling. }
  LNode := AArg;
  if AModel.Tree.Nodes[LNode].Kind = nkMember then
  begin
    LNode := AModel.Tree.Nodes[LNode].FirstChild;
    while (LNode <> NIL_NODE) and
          (AModel.Tree.Nodes[LNode].NextSibling <> NIL_NODE) do
      LNode := AModel.Tree.Nodes[LNode].NextSibling;
    if LNode = NIL_NODE then
      Exit(False);
  end;

  if (LNode <= High(AModel.RefMap)) and (AModel.RefMap[LNode] <> NIL_SYM) then
    LKind := AModel.Symbols[AModel.RefMap[LNode]].Kind
  else if (AProject <> nil) and AModel.ExtRefMap.TryGetValue(LNode, LExt) and
          (AProject.Model(LExt.UnitId) <> nil) then
    LKind := AProject.Model(LExt.UnitId).Symbols[LExt.Sym].Kind
  else
  begin
    LText := AModel.Tree.NodeNameLower(LNode);
    Exit((LText = 'true') or (LText = 'false') or (LText = 'nil'));
  end;
  Result := LKind in [skConst, skEnumValue];
end;

function DefaultAnnotateOptions: TLspAnnotateOptions;
begin
  Result.Mode := amAuto;
  Result.MarkByRef := True;
  Result.OneArgPerLine := False;
end;

function HasNameComment(const AComments: TArray<string>): Boolean;
var
  LText: string;
begin
  Result := False;
  for LText in AComments do
    if (Length(LText) >= 2) and (LText[Length(LText)] = ':') then
      Exit(True);
end;

function HasModifierComment(const AComments: TArray<string>): Boolean;
var
  LText: string;
begin
  Result := False;
  for LText in AComments do
    if (LText = 'var') or (LText = 'out') or (LText = 'const') then
      Exit(True);
end;

function AnnotateArgsAt(ACompletion: TPasCompletion; AModel: TPasSemaModel;
  AProject: TPasSemaProject; APasLine, APasCol: Integer;
  const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;
var
  LTree: TPasTree;
  LIndent, LMark: string;
  LOwnerModel: TPasSemaModel;
  LOwnerNode: Integer;
  LGapLine, LGapCol, LInsLine, LInsCol: Integer;
  LOnOwnLine, LNameIt: Boolean;
  LInfo: TPasCallInfo;
  LCall, LOnlyArg, LArg, LArgIdx, LFirst, LLast: Integer;
  LOpenLine, LOpenCol, LLine, LCol: Integer;
  LIdx, LChosen, LFitting, LArgCount: Integer;
  LModel: TPasSemaModel;
  LParams, LCand: TArray<TParamInfo>;
  LVarargs, LCandVarargs: Boolean;
  LComments: TArray<string>;
  LText: string;
  LEdit: TLspAnnotateEdit;
begin
  Result := Default(TLspAnnotateAnswer);
  Result.Provider := cProvider + ': the caret is not in a call';
  if (AModel = nil) or (ACompletion = nil) or (APasLine < 1) or
     (APasCol < 1) then
    Exit;
  LTree := AModel.Tree;

  { WHICH CALL, AND HOW MUCH OF IT. The name first: a caret on `Bar` in
    `Foo(Bar(x))` means Bar's arguments, all of them, and CallAt asked at
    that caret would answer about Foo (it walks LEFT from the caret into
    the enclosing list). The arguments second, through CallAt, which knows
    how to count commas past nested parens and indexers. }
  LOnlyArg := -1;
  LCall := CallNamedAt(LTree, APasLine, APasCol);
  if LCall <> NIL_NODE then
  begin
    // Resolve the call as signature help would, from just inside its `(`:
    // the nkCall's own first token is the paren.
    if not VisEnd(LTree, LTree.Nodes[LCall].FirstToken, LOpenLine,
      LOpenCol) then
    begin
      Result.Provider := cProvider + ': the call is in an include file';
      Exit;
    end;
    if not ACompletion.CallAt(LOpenLine, LOpenCol, LInfo) or
       (LInfo.CallNode <> LCall) then
    begin
      Result.Provider := cProvider + ': the call did not resolve';
      Exit;
    end;
    Result.Scope := 'all';
  end
  else
  begin
    if not ACompletion.CallAt(APasLine, APasCol, LInfo) or
       (LInfo.CallNode = NIL_NODE) then
      Exit;   // not in a call, or a parse too broken to have a call node
    LCall := LInfo.CallNode;
    LOnlyArg := LInfo.ArgIndex;
    Result.Scope := 'one';
  end;

  // The arguments: every child of the call node after the callee.
  LArgCount := 0;
  LArg := LTree.Nodes[LCall].FirstChild;
  if LArg <> NIL_NODE then
    LArg := LTree.Nodes[LArg].NextSibling;
  while LArg <> NIL_NODE do
  begin
    Inc(LArgCount);
    LArg := LTree.Nodes[LArg].NextSibling;
  end;
  if LArgCount = 0 then
  begin
    Result.Provider := cProvider + ': the call has no arguments';
    Exit;
  end;
  if LOnlyArg >= LArgCount then
  begin
    Result.Provider := cProvider + ': no argument at the caret';
    Exit;
  end;

  { WHICH OVERLOAD. The resolver's when it made one; otherwise the only
    member of the family that takes this many arguments; otherwise refuse.
    Intrinsics and procedural values are refused up front - see the header. }
  if Length(LInfo.Targets) = 0 then
  begin
    Result.Provider := cProvider + ': the callee did not resolve';
    Exit;
  end;
  LChosen := -1;
  if LInfo.BoundExact then
    for LIdx := 0 to High(LInfo.Targets) do
      if (LInfo.Targets[LIdx].Mid = LInfo.BoundMid) and
         (LInfo.Targets[LIdx].Sym = LInfo.BoundSym) then
      begin
        LChosen := LIdx;
        Break;
      end;
  if LChosen < 0 then
  begin
    if Length(LInfo.Targets) = 1 then
      LChosen := 0
    else
    begin
      LFitting := 0;
      for LIdx := 0 to High(LInfo.Targets) do
      begin
        LModel := ModelOf(AModel, AProject, LInfo.Targets[LIdx].Mid);
        if (LModel = nil) or
           not ParamsOf(LModel, LInfo.Targets[LIdx].Sym, LCand,
             LCandVarargs) then
          Continue;
        if LCandVarargs or ((LArgCount >= RequiredCount(LCand)) and
           (LArgCount <= Length(LCand))) then
        begin
          Inc(LFitting);
          LChosen := LIdx;
        end;
      end;
      if LFitting <> 1 then
      begin
        Result.Provider := Format('%s: %d of the %d overloads of %s take %d '
          + 'argument(s) - ambiguous, not annotated', [cProvider, LFitting,
          Length(LInfo.Targets), LInfo.Targets[0].Name, LArgCount]);
        Exit;
      end;
    end;
  end;

  LModel := ModelOf(AModel, AProject, LInfo.Targets[LChosen].Mid);
  if LModel = nil then
  begin
    Result.Provider := cProvider + ': the callee''s unit is not analyzed';
    Exit;
  end;
  Result.Routine := LInfo.Targets[LChosen].Name
    + LInfo.Targets[LChosen].ParamsText;
  if LModel.Symbols[LInfo.Targets[LChosen].Sym].Kind <> skRoutine then
  begin
    // A procedural VALUE - a variable, field, parameter or property of a
    // procedural type: an honest call (Alex, 2026-09-15), whose parameter
    // names are the TYPE's. Followed from the value's declared type to the
    // `procedure(...)` it is, through aliases and across units.
    if not ProcTypeOf(LModel, AProject, LInfo.Targets[LChosen].Sym,
      LOwnerModel, LOwnerNode) then
    begin
      Result.Provider := cProvider + ': ' + LInfo.Targets[LChosen].Name
        + ' is a procedural value whose type could not be followed to its '
        + 'parameter list';
      Exit;
    end;
    if not ParamsOfNode(LOwnerModel, LOwnerNode, LParams) then
    begin
      Result.Provider := cProvider + ': no parameter list found for '
        + LInfo.Targets[LChosen].Name;
      Exit;
    end;
    LVarargs := False;
  end
  else if sfBuiltin in LModel.Symbols[LInfo.Targets[LChosen].Sym].Flags then
  begin
    // An intrinsic has no declaration, but the engine's curated signature
    // table spells its parameters the way the documentation does - so the
    // names come from there, aligned to THIS call's argument count (see
    // BuiltinParamsFor for the optional groups and the variadic tail).
    if not BuiltinParamsFor(LInfo.Targets[LChosen].ParamsText, LArgCount,
      LParams) then
    begin
      Result.Provider := cProvider + ': ' + LInfo.Targets[LChosen].Name
        + ' takes a variable argument list - nothing to name';
      Exit;
    end;
  end
  else if not ParamsOf(LModel, LInfo.Targets[LChosen].Sym, LParams,
    LVarargs) then
  begin
    Result.Provider := cProvider + ': no parameter list found for '
      + LInfo.Targets[LChosen].Name;
    Exit;
  end;

  { WHICH ARGUMENTS GET A NAME. The caret's reading (amAuto) is what the
    scope already says; an explicit mode overrides it - and amCurrent with
    the caret on the NAME has nothing to point at, which is a refusal, not a
    guess at the first argument. }
  case AOptions.Mode of
    amAll, amAnonymous, amNone:
      LOnlyArg := -1;
    amCurrent:
      if LOnlyArg < 0 then
      begin
        Result.Provider := cProvider + ': "current argument" needs the caret '
          + 'inside the argument list';
        Exit;
      end;
  end;

  LIndent := '';
  if AOptions.OneArgPerLine and LTree.NodeVisRange(LCall, LFirst, LLast) then
    LIndent := LineIndentOf(LTree, LFirst) + '  ';

  { THE EDITS, in argument order - which is buffer order, which is the order
    a forward-only editor writer needs them in. Two things can go in front of
    one argument - the line break and the annotation - and they are ONE edit,
    because two edits at one spot are two things a writer must order and a
    client must not reorder. }
  LArgIdx := 0;
  LArg := LTree.Nodes[LTree.Nodes[LCall].FirstChild].NextSibling;
  while LArg <> NIL_NODE do
  begin
    if LTree.NodeVisRange(LArg, LFirst, LLast) and
       GapBefore(LTree, LFirst, LGapLine, LGapCol, LInsLine, LInsCol,
         LOnOwnLine) then
    begin
      // The argument is IN SCOPE when the caret (or the mode) selects it and
      // a parameter stands behind it; the marks follow the scope, the name
      // follows the mode on top of that - amNone keeps the marks alone, and
      // amAnonymous names only what does not name itself.
      LNameIt := ((LOnlyArg < 0) or (LArgIdx = LOnlyArg)) and
        (LArgIdx < Length(LParams)) and
        (LTree.Nodes[LArg].Kind <> nkNamedArg);
      (* ONE ORDER, ALWAYS: `{Name:} {var} Arg` (Alex, 2026-09-15). The name
        goes in front of whatever comments the argument already carries; the
        mark goes right after an existing name comment - which means AFTER
        the run, at the argument itself, as a second edit - and next to a
        fresh name otherwise. *)
      LText := '';
      LMark := '';
      if LNameIt then
      begin
        LComments := LeadingBraceComments(LTree, LFirst);
        if (AOptions.Mode <> amNone) and
           ((AOptions.Mode <> amAnonymous) or
            IsAnonymousArg(AModel, AProject, LArg)) and
           not HasNameComment(LComments) then
          LText := '{' + LParams[LArgIdx].Name + ':} ';
        if AOptions.MarkByRef and (LParams[LArgIdx].Modifier <> '') and
           (LParams[LArgIdx].Modifier <> 'const') and
           not HasModifierComment(LComments) then
          if HasNameComment(LComments) then
            LMark := '{' + LParams[LArgIdx].Modifier + '} '
          else
            LText := LText + '{' + LParams[LArgIdx].Modifier + '} ';
      end;
      LEdit.Line := LInsLine;
      LEdit.Col := LInsCol;
      LEdit.EndLine := LInsLine;
      LEdit.EndCol := LInsCol;
      if AOptions.OneArgPerLine and not LOnOwnLine then
      begin
        // The whole gap goes, the break and the indent take its place: no
        // trailing space is left after the comma, and no double indent.
        LEdit.Line := LGapLine;
        LEdit.Col := LGapCol;
        LText := #13#10 + LIndent + LText;
      end;
      if LText <> '' then
      begin
        LEdit.Text := LText;
        Result.Edits := Result.Edits + [LEdit];
      end;
      if (LMark <> '') and VisStart(LTree, LFirst, LLine, LCol) then
      begin
        LEdit.Line := LLine;
        LEdit.Col := LCol;
        LEdit.EndLine := LLine;
        LEdit.EndCol := LCol;
        LEdit.Text := LMark;
        Result.Edits := Result.Edits + [LEdit];
      end;
    end;
    Inc(LArgIdx);
    LArg := LTree.Nodes[LArg].NextSibling;
  end;

  if Length(Result.Edits) = 0 then
    Result.Provider := cProvider + ': already annotated'
  else
    Result.Provider := cProvider;
end;

end.
