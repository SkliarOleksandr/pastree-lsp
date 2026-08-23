unit PasLsp.ClassComplete;

{
  Class completion: the missing implementations of a unit, as text to insert.

  This is the OWN replacement for Ctrl+Shift+C (clients/rad-studio/SPEC.md's
  live queue, item 3): the native one is not gated by the Insight Provider
  selection and works badly (user, 2026-08-22), so we do not extend it, we
  replace it by keyboard binding.

  TWO DIFFERENCES FROM THE NATIVE ONE, both asked for:

  1. **Free routines count.** A `procedure Foo;` declared in the unit's
     INTERFACE SECTION - not a method of anything - has its body in the
     implementation section exactly like a method does, and the native class
     completion ignores those. Here a declaration is a declaration: methods of
     a class/record/helper, free routines of the interface section, and
     `forward`-declared ones are all the same question, "is there a body for
     this key".

     (An `interface` TYPE - IFoo - is the one place with nothing to generate:
     its methods are implemented by whatever class implements the interface,
     not by the unit. Those are skipped.)

  2. **The whole unit at once**, not just the type at the caret. The question
     "what did I declare and not implement" has one answer per file, and
     answering it per-caret only means pressing the key more times.

  WHAT IT DOES NOT DO. Nested routines (a `forward` inside another routine's
  body) are skipped: their body must go inside that same body, which is a
  different insertion point and a rare shape. Bodies always go at the END of
  the implementation section, in declaration order - not next to their
  neighbours in the class, because "next to" needs a policy (which sibling? in
  the class's order or the file's?) and the end is where a reader looks for
  new code. A file with no implementation section (a .dpr, a units-only
  interface) yields nothing, and says so.

  Everything here is a pure function of the TREE - no project, no analysis, no
  I/O - because the whole point is to answer about the buffer the user is
  typing in, whose declarations the last analysis has never seen. The caller
  parses the live overlay text and hands the tree over.
}

interface

uses
  PasTree.Ast;

type
  { One insertion. `Line`/`Col` are 1-based PasTree coordinates of the point
    to insert AT (nothing is ever replaced or deleted - class completion only
    ever adds), and the caller inserts `Text` there verbatim, CRLF and all.

    Edits come back ASCENDING by position, because that is the only order an
    IDE edit writer can apply them in - it cannot move backward. A client
    walking them forward with one writer gets one undo step and no
    auto-indent; a client that inserts them one at a time through the editor
    instead has to go BACKWARD, or every position after the first is stale. }
  TLspClassEdit = record
    Line: Integer;
    Col: Integer;
    Text: string;
    Kind: string;   // 'body' - the only kind so far; 'member' is phase 2
    Name: string;   // 'TFoo.Bar' / 'Foo' - for the log and the IDE's message
  end;

  TLspClassCompleteAnswer = record
    Edits: TArray<TLspClassEdit>;
    { Where to leave the caret once every edit is applied: the empty body line
      of the FIRST generated routine, already corrected for the lines the
      earlier edits insert above it. 0 = nothing was generated. }
    CaretLine: Integer;
    CaretCol: Integer;
    { Names the outcome in the server's log and in the IDE's message - a
      refusal says WHY here, because "nothing happened" is the one answer a
      user cannot debug. }
    Provider: string;
  end;

{ The missing implementations of the unit ATree describes. Never raises; a
  file with nothing to do answers with no edits and a Provider that says so. }
function ClassCompleteFor(const ATree: TPasTree): TLspClassCompleteAnswer;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  PasTree.Types,
  PasTree.Preprocessor;

type
  TDeclCandidate = record
    Key: string;        // chain.name#argcount:types - see MakeKey
    Name: string;       // display name, qualified for a method
    Header: string;     // 'procedure TFoo.Bar(const A: string): string;'
    OrderTok: Integer;  // the declaration's first visible token
  end;

{ ---- small tree helpers (all read-only over the arena) -------------------- }

function ChildOfKind(const ATree: TPasTree; ANode: Integer;
  AKind: TPasNodeKind): Integer;
begin
  Result := NIL_NODE;
  if (ANode < 0) or (ANode > High(ATree.Nodes)) then
    Exit;
  Result := ATree.Nodes[ANode].FirstChild;
  while Result <> NIL_NODE do
  begin
    if ATree.Nodes[Result].Kind = AKind then
      Exit;
    Result := ATree.Nodes[Result].NextSibling;
  end;
end;

{ Raw source text between two VISIBLE token indices, inclusive - declared
  early because the name walk below needs it to look at one token. }
function RawSpan(const ATree: TPasTree; AFromVis, AToVis: Integer): string;
  forward;

{ The routine's NAME, as the parser actually builds it: a chain of nkIdent
  SEGMENTS (`TFoo` `.` `Bar`), each optionally followed by its own
  nkGenericParams. There is no single "name node" to point at - reading only
  the first child is what made `procedure TBase.Done;` key as `TBase`, so
  every implemented method looked unimplemented (first live run, 2026-08-23).

  A DOT is what continues the chain, and that test matters: the result type of
  `function Foo: Integer` is an nkIdent child too, adjacent in kind and
  indistinguishable from a name segment by anything except the ':' in front of
  it. So the walk only takes another segment when the token right after the
  current one is a dot.

  AFirstVis/ALastVis span the whole name including generic parameters, so the
  caller can slice both the name and everything after it. }
function RoutineName(const ATree: TPasTree; ARoutine: Integer;
  out AFirstVis, ALastVis: Integer;
  out ASegments: TArray<string>): Boolean;
var
  LChild: Integer;
begin
  Result := False;
  ASegments := nil;
  AFirstVis := -1;
  ALastVis := -1;
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkAttrGroup:
        ;   // attributes precede the name and are not part of it
      nkIdent:
        begin
          // A second or later segment only continues the name if a dot got us
          // here; otherwise this nkIdent is the result type and the name ended.
          if (ALastVis >= 0) and (RawSpan(ATree, ALastVis + 1,
            ALastVis + 1) <> '.') then
            Break;
          if AFirstVis < 0 then
            AFirstVis := ATree.NodeLeftmostVis(LChild);
          ALastVis := ATree.Nodes[LChild].LastToken;
          ASegments := ASegments + [ATree.NodeSpanText(LChild)];
          Result := True;
        end;
      nkGenericParams:
        begin
          // The name's own type parameters - `TStack<T>.Push` or
          // `procedure Map<U>` - but only when they sit right against it.
          if (ALastVis < 0) or
             (ATree.NodeLeftmostVis(LChild) <> ALastVis + 1) then
            Break;
          ALastVis := ATree.Nodes[LChild].LastToken;
          if Length(ASegments) > 0 then
            ASegments[High(ASegments)] := ASegments[High(ASegments)] +
              ATree.NodeSpanText(LChild);
        end;
    else
      Break;   // parameters, result type, directives, body
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ Raw source text between two VISIBLE token indices, inclusive. '' when the
  span is degenerate or crosses files (a declaration split over an $I include
  - not worth reconstructing, same call the AST's own NodeSpanText makes). }
function RawSpan(const ATree: TPasTree; AFromVis, AToVis: Integer): string;
var
  LFrom, LTo: TPasVisibleToken;
begin
  Result := '';
  if (AFromVis < 0) or (AToVis < AFromVis) or
     (AToVis > High(ATree.Source.Visible)) then
    Exit;
  LFrom := ATree.Source.Visible[AFromVis];
  LTo := ATree.Source.Visible[AToVis];
  if LFrom.FileId <> LTo.FileId then
    Exit;
  with ATree.Source.Files[LFrom.FileId] do
    Result := Copy(Source, Tokens[LFrom.TokenIndex].Start + 1,
      Tokens[LTo.TokenIndex].EndPos - Tokens[LFrom.TokenIndex].Start);
end;

{ Whitespace runs to one space, so a parameter list written across three lines
  becomes one line in the generated header - which is what a reader of the
  implementation section expects, and what the native completion does. }
function Flatten(const AText: string): string;
var
  LIdx: Integer;
  LSpace: Boolean;
begin
  Result := '';
  LSpace := False;
  for LIdx := 1 to Length(AText) do
    if CharInSet(AText[LIdx], [#9, #10, #13, ' ']) then
      LSpace := Result <> ''
    else
    begin
      if LSpace then
        Result := Result + ' ';
      LSpace := False;
      Result := Result + AText[LIdx];
    end;
end;

{ `TDemoStack<T>` -> `tdemostack`: a key must not care about the type
  parameters, because the declaration writes `<T>` on the class and the
  implementation writes it again on the qualified name. }
function StripGenerics(const AText: string): string;
var
  LIdx, LDepth: Integer;
begin
  Result := '';
  LDepth := 0;
  for LIdx := 1 to Length(AText) do
    if AText[LIdx] = '<' then
      Inc(LDepth)
    else if AText[LIdx] = '>' then
    begin
      if LDepth > 0 then
        Dec(LDepth);
    end
    else if LDepth = 0 then
      Result := Result + AText[LIdx];
end;

{ The parameter list as an IDENTITY: one entry per declared argument (a
  `const A, B: string` is two), each the argument's TYPE text, lowercased and
  space-free. Names are deliberately NOT in the key - a user mid-edit may have
  renamed a parameter in one of the two places, and the honest reading of that
  is still "this routine is implemented". }
{ One parameter's contribution to the key, from its SOURCE TEXT: the type,
  once per name it declares. `const A, B: string = ''` -> `string;string;`.

  Text, not node kinds, and that is the whole point. A parameter's children are
  [attrs] name+ [type] [default], and the TYPE of `A: Integer` is an nkIdent
  exactly like the name is - so "the first child that is not a name" reads
  `Integer` as a second name and the DEFAULT VALUE as the type. That is not a
  hypothetical: it made `function Bar(A: Integer; const S: string = '')` key
  differently from its own implementation (which may not repeat the default),
  and the first live run generated a duplicate body for a routine that had one
  (2026-08-23). The colon is what separates names from type, and the `=` is
  where the default starts; both are in the text and neither is in the kinds. }
function ParamEntry(const AText: string): string;
var
  LIdx, LDepth, LColon, LEq, LNames: Integer;
  LNamesText, LTypeText: string;
begin
  Result := '';
  // Cut the default off first: it belongs to the declaration alone.
  LDepth := 0;
  LEq := 0;
  LColon := 0;
  for LIdx := 1 to Length(AText) do
  begin
    case AText[LIdx] of
      '(', '[', '<': Inc(LDepth);
      ')', ']', '>': Dec(LDepth);
      ':':
        if (LDepth = 0) and (LEq = 0) then
          LColon := LIdx;   // the LAST top-level colon is the type separator
      '=':
        if (LDepth = 0) and (LEq = 0) then
          LEq := LIdx;
    end;
  end;
  if LEq > 0 then
    LNamesText := Copy(AText, 1, LEq - 1)
  else
    LNamesText := AText;
  if (LColon > 0) and (LColon <= Length(LNamesText)) then
  begin
    LTypeText := Copy(LNamesText, LColon + 1, MaxInt);
    LNamesText := Copy(LNamesText, 1, LColon - 1);
  end
  else
    LTypeText := '';   // an untyped `var X` - legal, and its own type
  LTypeText := LowerCase(Flatten(LTypeText).Replace(' ', '', [rfReplaceAll]));
  // One entry per NAME: `const A, B: string` is two arguments.
  LNames := 1;
  for LIdx := 1 to Length(LNamesText) do
    if LNamesText[LIdx] = ',' then
      Inc(LNames);
  while LNames > 0 do
  begin
    Result := Result + LTypeText + ';';
    Dec(LNames);
  end;
end;

function ParamsKey(const ATree: TPasTree; ARoutine: Integer): string;
var
  LParams, LParam: Integer;
begin
  Result := '';
  LParams := ChildOfKind(ATree, ARoutine, nkParams);
  if LParams = NIL_NODE then
    Exit;
  LParam := ATree.Nodes[LParams].FirstChild;
  while LParam <> NIL_NODE do
  begin
    if ATree.Nodes[LParam].Kind = nkParam then
      Result := Result + ParamEntry(ATree.NodeSpanText(LParam));
    LParam := ATree.Nodes[LParam].NextSibling;
  end;
end;

{ The parameter list as the IMPLEMENTATION must write it: the declaration's
  own text with every default value removed. Delphi requires the defaults to
  appear in the interface ONLY (E2226), so copying the declaration verbatim -
  as the first version did - produces a header that does not compile. }
function StripDefaults(const AText: string): string;
var
  LIdx, LDepth: Integer;
  LSkipping: Boolean;
  LQuote: Boolean;
begin
  Result := '';
  LDepth := 0;
  LSkipping := False;
  LQuote := False;
  for LIdx := 1 to Length(AText) do
  begin
    if LQuote then
    begin
      // Inside a string literal nothing is punctuation - a default of ');'
      // must not be read as the end of the parameter list.
      if not LSkipping then
        Result := Result + AText[LIdx];
      if AText[LIdx] = '''' then
        LQuote := False;
      Continue;
    end;
    case AText[LIdx] of
      '''':
        begin
          LQuote := True;
          if not LSkipping then
            Result := Result + AText[LIdx];
          Continue;
        end;
      '(', '[':
        Inc(LDepth);
      ')', ']':
        begin
          Dec(LDepth);
          LSkipping := False;   // the parameter ended with its list
        end;
      ';', ',':
        LSkipping := False;     // the next parameter starts
      '=':
        if LDepth > 0 then
        begin
          LSkipping := True;
          Continue;
        end;
    end;
    if not LSkipping then
    begin
      // `A: Integer = 7` loses its default and would keep the space in front
      // of it: `(A: Integer )`. Nothing in a signature ever wants a space
      // before a separator, so drop it as the separator goes in.
      if CharInSet(AText[LIdx], [')', ']', ';', ',']) and
         Result.EndsWith(' ') then
        Result := Result.TrimRight;
      Result := Result + AText[LIdx];
    end;
  end;
end;

function MakeKey(const AChain, AName, AParams: string): string;
begin
  Result := LowerCase(StripGenerics(AChain)) + '.' + LowerCase(AName) +
    '(' + AParams + ')';
end;

{ The enclosing type's name as the implementation must qualify it, generic
  parameters included: `TDemoStack<T>`. '' when the routine is not a member of
  a type. ASkip is set for the one container that has nothing to implement. }
function TypeChain(const ATree: TPasTree; ARoutine: Integer;
  out ASkip: Boolean): string;
var
  LNode, LDecl, LName, LGeneric: Integer;
  LSegment: string;
begin
  Result := '';
  ASkip := False;
  LNode := ATree.Nodes[ARoutine].Parent;
  while LNode <> NIL_NODE do
  begin
    case ATree.Nodes[LNode].Kind of
      nkInterfaceType:
        begin
          // An interface's methods are implemented by implementors, elsewhere.
          ASkip := True;
          Exit;
        end;
      nkRoutineBody:
        begin
          // A nested declaration - its body belongs inside this body, not at
          // the end of the unit (see the unit header).
          ASkip := True;
          Exit;
        end;
      nkClassType, nkRecordType, nkObjectType, nkHelperType:
        begin
          LDecl := ATree.Nodes[LNode].Parent;
          if (LDecl <> NIL_NODE) and
             (ATree.Nodes[LDecl].Kind = nkTypeDecl) then
          begin
            LName := ChildOfKind(ATree, LDecl, nkIdent);
            if LName <> NIL_NODE then
            begin
              LSegment := ATree.NodeSpanText(LName);
              LGeneric := ChildOfKind(ATree, LDecl, nkGenericParams);
              if LGeneric <> NIL_NODE then
                LSegment := LSegment + Flatten(ATree.NodeSpanText(LGeneric));
              // PREPENDED, so a method of a nested type comes out as the
              // implementation must write it: TOuter.TInner.Method.
              if Result = '' then
                Result := LSegment
              else
                Result := LSegment + '.' + Result;
            end;
          end;
        end;
    end;
    LNode := ATree.Nodes[LNode].Parent;
  end;
end;

{ Directives the IMPLEMENTATION must or may repeat. The rest belong to the
  declaration alone: `virtual`, `override`, `abstract`, `reintroduce`,
  `dynamic`, `message`, `deprecated`, `final`, `export`, `external`,
  `forward`. Repeating one of those is a compile error or a lie, and leaving
  out one of THESE is a compile error the other way - `static` in particular
  (a class static method's implementation must say so again). }
function RepeatableDirective(const AWord: string): Boolean;
begin
  Result := SameText(AWord, 'static') or SameText(AWord, 'overload') or
    SameText(AWord, 'inline') or SameText(AWord, 'varargs') or
    SameText(AWord, 'stdcall') or SameText(AWord, 'cdecl') or
    SameText(AWord, 'pascal') or SameText(AWord, 'register') or
    SameText(AWord, 'safecall') or SameText(AWord, 'winapi');
end;

{ True when the declaration has a directive that means "there is no body
  here": an abstract method, or one implemented outside Pascal. }
function HasNoBodyDirective(const ATree: TPasTree; ARoutine: Integer): Boolean;
var
  LChild: Integer;
  LWord: string;
begin
  Result := False;
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if ATree.Nodes[LChild].Kind = nkDirective then
    begin
      LWord := ATree.NodeText(LChild);
      if SameText(LWord, 'abstract') or SameText(LWord, 'external') then
        Exit(True);
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ The implementation header for a declaration: its own text, with the type
  name spliced in front of the routine name and the declaration-only
  directives dropped.

  Built from the SOURCE SPAN rather than reassembled from the model, for the
  same reason the completion seam reads ItemParamsText instead of rebuilding
  it: whatever the user wrote - default values, `array of const`, an
  attributed parameter, a multiline list - comes back out as they wrote it. }
function BuildHeader(const ATree: TPasTree; ARoutine, ANameFirst,
  ANameLast: Integer; const AChain: string): string;
var
  LChild, LTailEnd: Integer;
  LHead, LTail, LDirs, LWord: string;
begin
  Result := '';
  if (ANameFirst < 0) or (ANameLast < ANameFirst) then
    Exit;
  // `procedure ` / `function ` / `constructor ` - the keyword the user wrote.
  LHead := RawSpan(ATree, ATree.NodeLeftmostVis(ARoutine), ANameFirst - 1);
  if LHead = '' then
    Exit;
  // `class` is NOT inside the node's span - the parser consumes it before
  // opening the nkRoutine and records it as Aux=1 - so the implementation
  // header has to put it back, or a class method comes out as an instance one
  // (first live run, 2026-08-23: `class function TBase.Make` lost its class).
  if ATree.Nodes[ARoutine].Aux = 1 then
    LHead := 'class ' + Flatten(LHead)
  else
    LHead := Flatten(LHead);
  LHead := LHead + ' ';
  // Parameter list and result type: every child past the name that is not a
  // directive and not a body.
  LTailEnd := ANameLast;
  LDirs := '';
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkRoutineBody: ;
      nkDirective:
        begin
          LWord := ATree.NodeText(LChild);
          if RepeatableDirective(LWord) then
            LDirs := LDirs + ' ' + Flatten(ATree.NodeSpanText(LChild)) + ';';
        end;
    else
      if (ATree.NodeLeftmostVis(LChild) > ANameLast) and
         (ATree.Nodes[LChild].LastToken > LTailEnd) then
        LTailEnd := ATree.Nodes[LChild].LastToken;
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
  LTail := '';
  if LTailEnd > ANameLast then
    LTail := StripDefaults(Flatten(RawSpan(ATree, ANameLast + 1, LTailEnd)));
  Result := LHead + AChain + Flatten(RawSpan(ATree, ANameFirst, ANameLast)) +
    LTail + ';' + LDirs;
end;

{ The point to insert bodies at: just past the last token of the
  implementation section, so new routines land after the existing ones and
  before `initialization`/`finalization`/`end.`. }
function ImplInsertPos(const ATree: TPasTree; out ALine, ACol: Integer):
  Boolean;
var
  LSec, LVisIdx: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  LSec := ChildOfKind(ATree, 0, nkImplementationSec);
  if LSec = NIL_NODE then
    Exit;
  LVisIdx := ATree.Nodes[LSec].LastToken;
  // An empty implementation section: its span degenerates to the keyword
  // itself, which is exactly where the first body should go.
  if LVisIdx < ATree.Nodes[LSec].FirstToken then
    LVisIdx := ATree.Nodes[LSec].FirstToken;
  if (LVisIdx < 0) or (LVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[LVisIdx];
  ATree.Source.Files[LVis.FileId].OffsetToLineCol(
    ATree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex].EndPos,
    ALine, ACol);
  Result := True;
end;

function ClassCompleteFor(const ATree: TPasTree): TLspClassCompleteAnswer;
var
  LImpls: TDictionary<string, Boolean>;
  LDecls: TList<TDeclCandidate>;
  LIdx, LNameFirst, LNameLast, LBody, LLine, LCol: Integer;
  LChain, LName, LKey: string;
  LSkip: Boolean;
  LCand: TDeclCandidate;
  LEdit: TLspClassEdit;
  LText: string;
  LDots, LCount: Integer;
  LSegments: TArray<string>;
begin
  Result := Default(TLspClassCompleteAnswer);
  Result.Provider := 'pastree/classComplete';
  LImpls := TDictionary<string, Boolean>.Create;
  LDecls := TList<TDeclCandidate>.Create;
  try
    for LIdx := 0 to High(ATree.Nodes) do
    begin
      if ATree.Nodes[LIdx].Kind <> nkRoutine then
        Continue;
      if not RoutineName(ATree, LIdx, LNameFirst, LNameLast, LSegments) then
        Continue;
      LDots := Length(LSegments);
      LBody := ChildOfKind(ATree, LIdx, nkRoutineBody);
      if LBody <> NIL_NODE then
      begin
        // An implementation. Its OWN name carries the qualification (a method
        // is implemented at unit level, not inside its class), so the chain
        // comes from the leading segments.
        LChain := '';
        if LDots > 1 then
          LChain := string.Join('.', LSegments, 0, LDots - 1);
        LImpls.AddOrSetValue(MakeKey(LChain, LSegments[LDots - 1],
          ParamsKey(ATree, LIdx)), True);
        Continue;
      end;
      if HasNoBodyDirective(ATree, LIdx) then
        Continue;
      LChain := TypeChain(ATree, LIdx, LSkip);
      if LSkip then
        Continue;
      // A declaration is never qualified (`procedure IFoo.Bar = Baz` parses as
      // a method resolution, not a routine), so its name is the last segment.
      LName := LSegments[LDots - 1];
      LCand.Key := MakeKey(LChain, LName, ParamsKey(ATree, LIdx));
      LCand.Name := LName;
      if LChain <> '' then
        LCand.Name := LChain + '.' + LName;
      LCand.OrderTok := ATree.NodeLeftmostVis(LIdx);
      if LChain = '' then
        LCand.Header := BuildHeader(ATree, LIdx, LNameFirst, LNameLast, '')
      else
        LCand.Header := BuildHeader(ATree, LIdx, LNameFirst, LNameLast,
          LChain + '.');
      if LCand.Header = '' then
        Continue;
      LDecls.Add(LCand);
    end;

    // Declaration order is source order, and the arena is not in source
    // order (leaves are allocated first) - so sort by the first token.
    LDecls.Sort(TComparer<TDeclCandidate>.Construct(
      function(const A, B: TDeclCandidate): Integer
      begin
        Result := A.OrderTok - B.OrderTok;
      end));

    LText := '';
    LName := '';
    LCount := 0;
    for LIdx := 0 to LDecls.Count - 1 do
    begin
      LKey := LDecls[LIdx].Key;
      if LImpls.ContainsKey(LKey) then
        Continue;
      // A duplicate declaration (the same routine declared twice) must not
      // produce two bodies.
      LImpls.AddOrSetValue(LKey, True);
      // Blank line, header, begin, an indented empty line for the caret, end.
      // The FIRST stub needs two line breaks, not one: the insertion point is
      // at the END of the last existing line (just past its final token), so
      // one break only terminates that line and the body would sit directly
      // against the previous `end;` (first live run, 2026-08-23).
      if LText = '' then
        LText := sLineBreak;
      LText := LText + sLineBreak + LDecls[LIdx].Header + sLineBreak +
        'begin' + sLineBreak + '  ' + sLineBreak + 'end;' + sLineBreak;
      Inc(LCount);
      if LName = '' then
        LName := LDecls[LIdx].Name
      else
        LName := LName + ', ' + LDecls[LIdx].Name;
    end;

    if LText = '' then
    begin
      Result.Provider := 'pastree/classComplete: nothing to implement';
      Exit;
    end;
    if not ImplInsertPos(ATree, LLine, LCol) then
    begin
      Result.Provider :=
        'pastree/classComplete: no implementation section to insert into';
      Exit;
    end;
    LEdit.Line := LLine;
    LEdit.Col := LCol;
    LEdit.Text := LText;
    LEdit.Kind := 'body';
    LEdit.Name := LName;
    Result.Edits := [LEdit];
    // The caret goes on the indented empty line of the FIRST body. Counting
    // from the insertion point's own line L: the first break ends L, so L+1 is
    // the blank separator, L+2 the header, L+3 `begin`, L+4 the body line.
    Result.CaretLine := LLine + 4;
    Result.CaretCol := 3;
    Result.Provider := Format('pastree/classComplete: %d to implement',
      [LCount]);
  finally
    LDecls.Free;
    LImpls.Free;
  end;
end;

end.
