unit PasLsp.ClassComplete;

{
  Class completion: the missing implementations of a unit, as text to insert.

  This is the OWN replacement for Ctrl+Shift+C (clients/rad-studio/SPEC.md's
  live queue, item 3): the native one is not gated by the Insight Provider
  selection and works badly (user, 2026-08-22), so we do not extend it, we
  replace it by keyboard binding.

  THREE DIFFERENCES FROM THE NATIVE ONE - the first two asked for, the third
  parity with it:

  1. **Free routines count.** A `procedure Foo;` declared in the unit's
     INTERFACE SECTION - not a method of anything - has its body in the
     implementation section exactly like a method does, and the native class
     completion ignores those. Here a declaration is a declaration: methods of
     a class/record/helper, free routines of the interface section, and
     `forward`-declared ones are all the same question, "is there a body for
     this key".

     (An `interface` TYPE - IFoo - has nothing to IMPLEMENT here: its methods
     are implemented by whatever class implements it. Its PROPERTIES still get
     their accessor methods declared, though - see the property pass.)

  2. **Free routines have a scope of their own.** The type at the caret is
     completed whole - every member, whichever of them the caret is on, in the
     declaration or in a body - which is what the native command does. A free
     routine belongs to no type, so the caret in one completes that one
     routine. (Until 2026-09-05 this was the WHOLE UNIT at once, on the
     argument that "what did I declare and not implement" has one answer per
     file. It does; but one press on an empty line of a 13000-line unit then
     rewrote eight classes the user had not looked at, with no way to review
     what it had decided about each. One type per press is reviewable.)

  3. **The mirror question too: what did I IMPLEMENT and not declare.**
     `procedure TFoo.Bar;` typed straight into the implementation section,
     correctly qualified to a class this unit declares, with no matching
     member in `TFoo` - the declaration goes back into the class. Native
     Delphi's Ctrl+Shift+C does this; a replacement that only fills in bodies
     is not a replacement. See ClassCompleteFor's orphan pass, and
     MemberInsertPos for where the declaration lands - the SAME rule a
     property's synthesized accessor follows: end of `private` if there is
     one, a new `private` ahead of any other section if there is not, else
     right before the type's `end`.

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
    { All FOUR the emitter produces, and the list has to be complete because a
      consumer can key off it (the RAD spec documents the sort order by these
      names): 'body' (into the implementation section), 'member' (into the
      type's declaration), 'spec' (the read/write written into a property
      line) and 'semi' (the semicolon that closes that property line once the
      specifiers are in). See EditKindRank. }
    Kind: string;
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

{ The missing implementations (and missing declarations) around the caret at
  the 1-based (APasLine, APasCol) of the buffer ATree describes: the TYPE the
  caret is in - inside its declaration, or inside the body of one of its
  methods - and every one of that type's members; or the ONE free routine the
  caret is in, declaration or body. A caret in neither answers with no edits
  and a Provider that says so. (0, 0) means the whole unit, the shape the
  request had before 2026-09-05 and the one an ordinary LSP client with no
  caret to offer still gets. Never raises; a file with nothing to do answers
  with no edits and a Provider that says so. }
function ClassCompleteFor(const ATree: TPasTree;
  APasLine, APasCol: Integer): TLspClassCompleteAnswer;

{ ---- shared with PasLsp.SyncPrototypes ------------------------------------

  Exported rather than copied. Prototype sync asks the same questions this
  unit already answers - which node is a routine, what is its name, which type
  is it a member of, what does its parameter list amount to - and each of
  these has a hard-won detail in it (the dot walk in RoutineName, the text-not-
  kinds reading in ParamsKey, E2226 in StripDefaults). A second copy is a
  second place for those to be got wrong, and they would drift silently: both
  features would keep answering, just differently. }

/// <summary>First child of ANode with kind AKind, NIL_NODE if none.</summary>
function ChildOfKind(const ATree: TPasTree; ANode: Integer;
  AKind: TPasNodeKind): Integer;

/// <summary>
/// Raw source text between two VISIBLE token indices, inclusive - what the
/// user actually wrote, comments and line breaks included. '' when the span
/// is degenerate or crosses a file boundary (an $I include).
/// </summary>
function RawSpan(const ATree: TPasTree; AFromVis, AToVis: Integer): string;

/// <summary>Whitespace runs collapsed to one space.</summary>
function Flatten(const AText: string): string;

/// <summary>
/// A parameter list as the IMPLEMENTATION must write it: every default value
/// removed, because Delphi allows them in the declaration only (E2226).
/// </summary>
function StripDefaults(const AText: string): string;

/// <summary>
/// The routine's name as the parser builds it - a chain of segments
/// (`TFoo` `.` `Bar`), generic parameters included. AFirstVis/ALastVis span
/// the whole name, so a caller can slice both it and everything after it.
/// </summary>
function RoutineName(const ATree: TPasTree; ARoutine: Integer;
  out AFirstVis, ALastVis: Integer;
  out ASegments: TArray<string>): Boolean;

/// <summary>
/// The enclosing type's name as an implementation must qualify it
/// (`TDemoStack&lt;T&gt;`), '' for a free routine. ASkip marks the one
/// container with nothing to implement - an interface type.
/// </summary>
function TypeChain(const ATree: TPasTree; ARoutine: Integer;
  out ASkip: Boolean): string;

/// <summary>
/// The parameter list as an IDENTITY: the argument TYPES, lowercased, one
/// entry per declared name. Parameter names are deliberately not in it.
/// </summary>
function ParamsKey(const ATree: TPasTree; ARoutine: Integer): string;

{ THE ONE REPAIR THIS FEATURE MAKES to a buffer it cannot parse: a missing
  semicolon. `property XX: Integer` with the `;` not yet typed is the shape
  the key gets pressed on, and refusing it would be refusing the common case -
  but generating from the broken tree is worse than refusing, because an
  unterminated declaration swallows the rest of the class and every
  implementation in the unit stops being one (measured 2026-08-23: 1339 lines
  of bodies for methods that all had them, two insertions landing inside an
  unrelated routine).

  ONE `;` per call, at AVisIndex - the position of the parser's FIRST
  diagnostic - inserted after the token BEFORE it, which is where it was
  missing from. The caller then PARSES AGAIN and only proceeds on a clean
  tree, which is what makes this safe: the repair is a guess, and a guess that
  did not work does not produce a clean parse. Not keyed on the diagnostic's
  message, because the parser does not blame the semicolon for its absence -
  `property XX: Integer` followed by `end` reads to it as a missing property
  specifier.

  ALine/ACol are in ATEXT's coordinates (which, after the first repair, is no
  longer the buffer's - see MapColToOriginal). False when the token before is
  in an $I include: the text we hold is the main file's, and rewriting a
  different file from here is not this feature's business. }
function TrySemicolonRepair(const ATree: TPasTree; AVisIndex: Integer;
  const AText: string; out ARepaired: string;
  out ALine, ACol: Integer): Boolean;

{ A column in the repaired text, back in the original buffer's coordinates:
  every `;` inserted earlier on that line shifted it right by one. }
function MapColToOriginal(ALine, ACol: Integer;
  const ARepairs: TArray<TLspClassEdit>): Integer;

{ Folds the repairs into an answer computed from the REPAIRED text: every
  position the answer carries is in repaired coordinates, and the client
  applies everything to the ORIGINAL buffer, so each column has to lose the
  semicolons inserted before it on its own line. The repairs then join the
  list, and CompareClassEdits fixes the order where several land at ONE
  position - which a bare property's three edits all do. }
procedure MergeSemicolonRepairs(var AAnswer: TLspClassCompleteAnswer;
  const ARepairs: TArray<TLspClassEdit>);

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
    TypeKey: string;    // LowerCase(StripGenerics(chain)) - '' for a free
                        // routine; what the caret's scope is matched against
    Name: string;       // display name, qualified for a method
    Header: string;     // 'procedure TFoo.Bar(const A: string): string;'
    OrderTok: Integer;  // the declaration's first visible token
    // Tie-break for the sort below. Two generated accessors of ONE property
    // share its token, and the sort is not stable - without this the setter
    // could be emitted before the getter, which is not the order anyone
    // writes them in.
    Seq: Integer;
  end;

  { An ORPHAN implementation: `procedure TFoo.Bar;` written in the
    implementation section with no matching declaration in TFoo - the mirror
    image of TDeclCandidate, computed while walking the SAME implementations
    that feed LImpls and filtered once every declaration in the unit has been
    seen (arena order is allocation order, not source order, so the real
    declaration can sit after this implementation in ATree.Nodes). Native
    Delphi's Ctrl+Shift+C writes the declaration back in this case; ours must
    too, for parity. }
  TOrphanCandidate = record
    Key: string;      // MakeKey(chain, name, params) - a real declaration with
                       // this key cancels the candidate
    TypeKey: string;  // LowerCase(StripGenerics(chain)) - which type to add to
    Header: string;   // the member declaration line, semicolon-terminated
    // 0-based offset of the routine NAME within Header - where the caret
    // goes, the same spot Go To Definition / Go To Implementation land on
    // (the identifier, not the `procedure` in front of it; live check,
    // 2026-09-05). Once several orphans of one type are joined into one
    // Header, this stays the FIRST one's.
    NameOffset: Integer;
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
  ANameLast: Integer; const AChain, AOwnName: string;
  out ANameOffset: Integer): string; overload;
var
  LChild, LTailEnd: Integer;
  LHead, LTail, LDirs, LWord, LNameText: string;
begin
  Result := '';
  ANameOffset := 0;
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
  // The name text: the whole dotted span as written, UNLESS the caller hands
  // over just its own last segment - a member DECLARATION does not repeat the
  // type's name the way an implementation must (see ClassCompleteFor's orphan
  // pass, the one caller that does).
  LNameText := AOwnName;
  if LNameText = '' then
    LNameText := Flatten(RawSpan(ATree, ANameFirst, ANameLast));
  // Where the NAME starts in the result, 0-based - the column a caret wants,
  // the same one Go To Definition lands on (the identifier, not the keyword
  // in front of it). Past the chain too: `TFoo.Bar` is the implementation's
  // name and `Bar` is what a reader looks for.
  ANameOffset := Length(LHead) + Length(AChain);
  Result := LHead + AChain + LNameText + LTail + ';' + LDirs;
end;

{ The one-result form for callers that only want the text. }
function BuildHeader(const ATree: TPasTree; ARoutine, ANameFirst,
  ANameLast: Integer; const AChain: string): string; overload;
var
  LUnused: Integer;
begin
  Result := BuildHeader(ATree, ARoutine, ANameFirst, ANameLast, AChain, '',
    LUnused);
end;

{ ---- property accessors (the second half of class completion) ------------- }

{ The type's own name as an implementation must qualify it - `TFoo`,
  `TStack<T>` - and '' when ATypeNode is not the definition of a named type. }
function TypeNameOf(const ATree: TPasTree; ATypeNode: Integer): string;
var
  LDecl, LName, LGeneric: Integer;
begin
  Result := '';
  LDecl := ATree.Nodes[ATypeNode].Parent;
  if (LDecl = NIL_NODE) or (ATree.Nodes[LDecl].Kind <> nkTypeDecl) then
    Exit;
  LName := ChildOfKind(ATree, LDecl, nkIdent);
  if LName = NIL_NODE then
    Exit;
  Result := ATree.NodeSpanText(LName);
  LGeneric := ChildOfKind(ATree, LDecl, nkGenericParams);
  if LGeneric <> NIL_NODE then
    Result := Result + Flatten(ATree.NodeSpanText(LGeneric));
end;

{ Every name the type declares itself: fields, methods, properties, nested
  types and constants. What an accessor specifier is checked against - if the
  name is already here, there is nothing to generate, whatever it names. }
procedure CollectMemberNames(const ATree: TPasTree; ATypeNode: Integer;
  ANames: TDictionary<string, Boolean>);
var
  LChild, LSub, LFirstVis, LLastVis: Integer;
  LSegments: TArray<string>;
begin
  LChild := ATree.Nodes[ATypeNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkRoutine:
        if RoutineName(ATree, LChild, LFirstVis, LLastVis, LSegments) and
           (Length(LSegments) > 0) then
          ANames.AddOrSetValue(LowerCase(LSegments[High(LSegments)]), True);
      nkPropertyDecl, nkTypeDecl, nkConstDecl:
        begin
          LSub := ChildOfKind(ATree, LChild, nkIdent);
          if LSub <> NIL_NODE then
            ANames.AddOrSetValue(LowerCase(ATree.NodeSpanText(LSub)), True);
        end;
      nkVarDecl:
        begin
          // A field declaration names one or more fields before its type;
          // the type is an nkIdent too, so the same colon rule as parameters
          // applies - but for a NAME SET, over-collecting the type's name is
          // harmless (it can only make us skip generating something that
          // would have collided anyway).
          LSub := ATree.Nodes[LChild].FirstChild;
          while LSub <> NIL_NODE do
          begin
            if ATree.Nodes[LSub].Kind = nkIdent then
              ANames.AddOrSetValue(LowerCase(ATree.NodeSpanText(LSub)), True);
            LSub := ATree.Nodes[LSub].NextSibling;
          end;
        end;
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ The property's declared type, as text. Children are name, [index params],
  [type], specifiers - so the type is the first child that is none of those. }
function PropertyTypeText(const ATree: TPasTree; AProp: Integer): string;
var
  LChild: Integer;
  LSeenName: Boolean;
begin
  Result := '';
  LSeenName := False;
  LChild := ATree.Nodes[AProp].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkPropSpec:
        Exit;   // specifiers start; there was no type
      nkParams, nkAttrGroup:
        ;
      nkIdent:
        if not LSeenName then
          LSeenName := True
        else
          Exit(Flatten(ATree.NodeSpanText(LChild)));
    else
      Exit(Flatten(ATree.NodeSpanText(LChild)));
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ The property's index parameters as a routine's would be written: `[Index:
  Integer]` -> `Index: Integer`, defaults stripped. '' for a plain property. }
function PropertyIndexParams(const ATree: TPasTree; AProp: Integer): string;
var
  LParams: Integer;
begin
  Result := '';
  LParams := ChildOfKind(ATree, AProp, nkParams);
  if LParams = NIL_NODE then
    Exit;
  Result := Flatten(ATree.NodeSpanText(LParams));
  if Result.StartsWith('[') then
    Result := Copy(Result, 2, Length(Result) - 2);
  Result := Trim(StripDefaults('(' + Result + ')'));
  Result := Copy(Result, 2, Length(Result) - 2);
end;

{ The accessor a specifier names, when the type does not declare it yet.

  WHICH KIND, and the rule is ours rather than the IDE's: a name that starts
  with `Get` or `Set` is a METHOD, anything else is a FIELD. That is what the
  convention every Delphi codebase already follows means, it is predictable
  from the name alone (so the user knows what the key will do before pressing
  it), and it needs no type analysis to decide. `read FFoo` therefore declares
  the field, `read GetFoo` the function. }
function AccessorDecl(const ATree: TPasTree; AProp: Integer;
  const AName, AWord, ATypeText, AIndexParams: string; AForceMethod: Boolean;
  out AIsMethod: Boolean): string;
var
  LClassPrefix, LParams: string;
begin
  // AForceMethod is the interface case: an interface has no fields, so a
  // specifier there can only ever name a method whatever it is called.
  AIsMethod := AForceMethod or AName.ToLower.StartsWith('get') or
    AName.ToLower.StartsWith('set');
  if not AIsMethod then
  begin
    Result := AName + ': ' + ATypeText + ';';
    Exit;
  end;
  // A class property's accessors are class methods - anything else will not
  // compile against it.
  LClassPrefix := '';
  if ATree.Nodes[AProp].Aux = 1 then
    LClassPrefix := 'class ';
  if SameText(AWord, 'read') then
  begin
    LParams := '';
    if AIndexParams <> '' then
      LParams := '(' + AIndexParams + ')';
    Result := LClassPrefix + 'function ' + AName + LParams + ': ' +
      ATypeText + ';';
  end
  else
  begin
    // The setter takes the index parameters FIRST and the new value last,
    // which is the order the compiler passes them in.
    LParams := 'const Value: ' + ATypeText;
    if AIndexParams <> '' then
      LParams := AIndexParams + '; ' + LParams;
    Result := LClassPrefix + 'procedure ' + AName + '(' + LParams + ');';
  end;
end;

{ Does the property already say how to read or write it? A property with
  NEITHER is the one class completion has to finish; one with either is the
  author's decision (a read-only property is a design, not an omission) and is
  left exactly as written. }
function PropertyHasAccessor(const ATree: TPasTree; AProp: Integer): Boolean;
var
  LChild: Integer;
  LWord: string;
begin
  Result := False;
  LChild := ATree.Nodes[AProp].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if ATree.Nodes[LChild].Kind = nkPropSpec then
    begin
      LWord := ATree.NodeText(LChild);
      if SameText(LWord, 'read') or SameText(LWord, 'write') or
         SameText(LWord, 'readonly') or SameText(LWord, 'writeonly') then
        Exit(True);
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ Where ` read GetX write SetX` goes when a property has neither: after the
  type, EXCEPT that `index` must stay in front of `read` (13.1.x fixes the
  specifier order), so an indexed-by-constant property gets them after that.
  0 = the property has no type to hang them off, which is a redeclaration
  (`property X;`) and none of our business. }
function PropertySpecInsertVis(const ATree: TPasTree; AProp: Integer): Integer;
var
  LChild: Integer;
  LSeenName: Boolean;
begin
  Result := 0;
  LSeenName := False;
  LChild := ATree.Nodes[AProp].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkAttrGroup:
        ;
      nkParams:
        ;   // the index PARAMETER list - `[Index: Integer]`, not the `index`
            // specifier; the type still follows it
      nkIdent:
        if not LSeenName then
          LSeenName := True
        else
          Result := ATree.Nodes[LChild].LastToken;   // the type
      nkPropSpec:
        if SameText(ATree.NodeText(LChild), 'index') then
          Result := ATree.Nodes[LChild].LastToken
        else
          Break;   // read/write/stored/... - we are past where these go
    else
      Result := ATree.Nodes[LChild].LastToken;       // a non-ident type
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ The leading whitespace of the line a token sits on - so generated members
  line up with the ones already there instead of with a guess. }
function IndentOfToken(const ATree: TPasTree; AVisIdx: Integer): string;
var
  LVis: TPasVisibleToken;
  LLine, LCol, LIdx: Integer;
  LText: string;
begin
  Result := '';
  if (AVisIdx < 0) or (AVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVisIdx];
  with ATree.Source.Files[LVis.FileId] do
  begin
    OffsetToLineCol(Tokens[LVis.TokenIndex].Start, LLine, LCol);
    LText := LineText(LLine);
  end;
  for LIdx := 1 to Length(LText) do
    if CharInSet(LText[LIdx], [' ', #9]) then
      Result := Result + LText[LIdx]
    else
      Break;
end;

{ A member declaration's node ends on its TYPE, not on the `;` after it -
  `FNewProvider: Boolean` is the nkVarDecl and the `;` is the parser's, not
  the node's. Anchoring an insertion at the node's last token therefore lands
  BEFORE the semicolon: `FNewProvider: Boolean` + CRLF + `Code: string;` +
  `;` (uaviTypes.pas, 2026-09-05 - a field left unterminated and a `;;` two
  lines down). So step over the `;` when it is there. }
function PastSemicolon(const ATree: TPasTree; AVisIdx: Integer): Integer;
begin
  Result := AVisIdx;
  if RawSpan(ATree, AVisIdx + 1, AVisIdx + 1) = ';' then
    Result := AVisIdx + 1;
end;

{ Where new members go - a method's body-less declaration (the orphan pass)
  exactly as much as a property's synthesized accessor: the END of the type's
  `private` section when it has one; failing that, a NEW `private` section,
  placed BEFORE any other section the type already has (a reader expects
  private members first, and appending after `public`/`protected`/`published`
  would instead bury them behind everything the type already declares);
  failing THAT - no visibility sections at all, only bare fields/methods in
  the type's implicit default section, or an empty type - right before the
  type's `end`. ANeedsSection says whether a `private` header had to be
  written, because the text differs (a new section also re-indents whatever
  used to follow the insertion point). }
function MemberInsertPos(const ATree: TPasTree; ATypeNode: Integer;
  AAllowSection: Boolean; out ALine, ACol: Integer; out AIndent: string;
  out ANeedsSection: Boolean): Boolean;
var
  LChild, LLevel, LAnchor, LFirstSection, LVisIdx: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  // An INTERFACE has no visibility sections at all - its members are simply
  // listed - so there is no `private` to write and nothing to look for.
  ANeedsSection := AAllowSection;
  LAnchor := NIL_NODE;
  if not AAllowSection then
  begin
    // After the LAST member, exactly as the private branch does - not in front
    // of the type's `end`, which would leave `end` sitting on the same line as
    // the last thing we wrote.
    LChild := ATree.Nodes[ATypeNode].FirstChild;
    while LChild <> NIL_NODE do
    begin
      if not (ATree.Nodes[LChild].Kind in [nkVisibility, nkGuid]) then
        LAnchor := LChild;
      LChild := ATree.Nodes[LChild].NextSibling;
    end;
    if LAnchor = NIL_NODE then
      Exit;   // an empty interface has no property to need an accessor
    ANeedsSection := False;
    LVisIdx := PastSemicolon(ATree, ATree.Nodes[LAnchor].LastToken);
    AIndent := IndentOfToken(ATree, ATree.NodeLeftmostVis(LAnchor));
    if (LVisIdx < 0) or (LVisIdx > High(ATree.Source.Visible)) then
      Exit;
    LVis := ATree.Source.Visible[LVisIdx];
    with ATree.Source.Files[LVis.FileId] do
      OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos, ALine, ACol);
    Exit(True);
  end;
  LLevel := 0;
  LFirstSection := NIL_NODE;
  LChild := ATree.Nodes[ATypeNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    if ATree.Nodes[LChild].Kind = nkVisibility then
    begin
      if LFirstSection = NIL_NODE then
        LFirstSection := LChild;              // the first section, whichever
      LLevel := ATree.Nodes[LChild].Aux;       // 1 = private (the parser's map)
    end
    else if LLevel = 1 then
      LAnchor := LChild;                       // last member of a private run
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
  if LAnchor <> NIL_NODE then
  begin
    ANeedsSection := False;
    LVisIdx := PastSemicolon(ATree, ATree.Nodes[LAnchor].LastToken);
    AIndent := IndentOfToken(ATree, ATree.NodeLeftmostVis(LAnchor));
  end
  else if LFirstSection <> NIL_NODE then
  begin
    // No private section, but the type has some OTHER one - private goes
    // FIRST, ahead of it.
    LVisIdx := ATree.Nodes[LFirstSection].FirstToken;
    AIndent := IndentOfToken(ATree, ATree.NodeLeftmostVis(LFirstSection));
  end
  else
  begin
    // No visibility sections at all: land right before the type's `end`,
    // whose own indentation is what the new section header should use.
    LVisIdx := ATree.Nodes[ATypeNode].LastToken;
    AIndent := IndentOfToken(ATree, LVisIdx);
  end;
  if (LVisIdx < 0) or (LVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[LVisIdx];
  with ATree.Source.Files[LVis.FileId] do
    if ANeedsSection then
      // In front of whatever follows - the type's `end`, or its first
      // existing section - not after it.
      OffsetToLineCol(Tokens[LVis.TokenIndex].Start, ALine, ACol)
    else
      OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos, ALine, ACol);
  Result := True;
end;

{ The order two edits go in when they are at the SAME position - and they can
  be: a property that is the last member of its section anchors the member
  insertion at its own end, which is exactly where its `read`/`write` and its
  `;` go too. Left undefined (an unstable sort), that produced
  `procedure SetXX(const Value: Integer); read GetXX write SetXX;` on a live
  run (2026-08-23).

  The order is the order the text has to read in: the specifiers belong inside
  the declaration, the semicolon closes it, and only then can new members
  follow. }
function EditKindRank(const AKind: string): Integer;
begin
  if AKind = 'spec' then
    Result := 0
  else if AKind = 'semi' then
    Result := 1
  else if AKind = 'member' then
    Result := 2
  else
    Result := 3;   // 'body' - a different place entirely
end;

function CompareClassEdits(const A, B: TLspClassEdit): Integer;
begin
  Result := A.Line - B.Line;
  if Result = 0 then
    Result := A.Col - B.Col;
  if Result = 0 then
    Result := EditKindRank(A.Kind) - EditKindRank(B.Kind);
end;

{ Every line of AText prefixed with AIndent - generated members have to line
  up with the ones already in the type. }
function IndentLines(const AText, AIndent: string): string;
var
  LLines: TArray<string>;
  LIdx: Integer;
begin
  Result := '';
  LLines := AText.Split([sLineBreak]);
  for LIdx := 0 to High(LLines) do
  begin
    if LIdx > 0 then
      Result := Result + sLineBreak;
    Result := Result + AIndent + LLines[LIdx];
  end;
end;

{ A generated member declaration as its IMPLEMENTATION header: the same text
  with the type name spliced in front of the routine name. One source for
  both, so a generated declaration and its generated body cannot disagree. }
function AccessorImplHeader(const ADecl, AChain: string): string;
var
  LHead, LRest: string;
  LSpace: Integer;
begin
  LRest := ADecl;
  LHead := '';
  // `class ` is a word of its own in front of the routine keyword.
  if LRest.ToLower.StartsWith('class ') then
  begin
    LHead := Copy(LRest, 1, 6);
    LRest := Copy(LRest, 7, MaxInt);
  end;
  LSpace := Pos(' ', LRest);
  if LSpace = 0 then
    Exit(ADecl);
  LHead := LHead + Copy(LRest, 1, LSpace);        // 'function ' / 'procedure '
  LRest := Copy(LRest, LSpace + 1, MaxInt);       // 'GetFoo: TBar;'
  Result := LHead + AChain + '.' + LRest;
end;

{ How many lines the edits positioned strictly BEFORE ALine insert. The caret
  is a position in the finished text, and every one of those pushes it down. }
function InsertedLinesBefore(const AEdits: TArray<TLspClassEdit>;
  ALine: Integer): Integer;
var
  LIdx, LChar: Integer;
begin
  Result := 0;
  for LIdx := 0 to High(AEdits) do
    if AEdits[LIdx].Line < ALine then
      for LChar := 1 to Length(AEdits[LIdx].Text) do
        if AEdits[LIdx].Text[LChar] = #10 then
          Inc(Result);
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

{ ---- the caret's scope --------------------------------------------------- }

{ Line/column of a visible token's start or end, 1-based, main file only. }
function TokenPos(const ATree: TPasTree; AVisIdx: Integer; AEnd: Boolean;
  out ALine, ACol: Integer): Boolean;
var
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  if (AVisIdx < 0) or (AVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVisIdx];
  if LVis.FileId <> 0 then
    Exit;   // an $I include: not the buffer the caret is in
  with ATree.Source.Files[0] do
    if AEnd then
      OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos, ALine, ACol)
    else
      OffsetToLineCol(Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := True;
end;

{ Does ANode's span (leftmost visible token to last token, inclusive at both
  ends) contain the 1-based caret? ASize is the span in tokens, so the caller
  can keep the INNERMOST of several containing nodes. }
function NodeContains(const ATree: TPasTree; ANode, ALine, ACol: Integer;
  out ASize: Integer): Boolean;
var
  LFirst, L1, C1, L2, C2: Integer;
begin
  Result := False;
  ASize := MaxInt;
  LFirst := ATree.NodeLeftmostVis(ANode);
  if not TokenPos(ATree, LFirst, False, L1, C1) then
    Exit;
  if not TokenPos(ATree, ATree.Nodes[ANode].LastToken, True, L2, C2) then
    Exit;
  if (ALine < L1) or ((ALine = L1) and (ACol < C1)) then
    Exit;
  if (ALine > L2) or ((ALine = L2) and (ACol > C2)) then
    Exit;
  ASize := ATree.Nodes[ANode].LastToken - LFirst;
  Result := True;
end;

{ ---- inherited members ---------------------------------------------------- }

{ The names a type's ANCESTOR clause lists - `class(TBase, IFoo)`,
  `interface(IBase)`, a helper's `for TFoo` - as the parser leaves them: the
  nkIdent/nkMember children ahead of the GUID, the first visibility word or
  the first member. Last segment only, generics stripped, lowercased, which is
  how the in-unit type map is keyed. }
function AncestorKeys(const ATree: TPasTree; ATypeNode: Integer):
  TArray<string>;
var
  LChild, LDot: Integer;
  LText: string;
begin
  Result := nil;
  LChild := ATree.Nodes[ATypeNode].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkIdent, nkMember:
        begin
          LText := StripGenerics(Flatten(ATree.NodeSpanText(LChild)));
          LDot := LText.LastIndexOf('.');
          if LDot >= 0 then
            LText := Copy(LText, LDot + 2, MaxInt);
          Result := Result + [LowerCase(LText)];
        end;
      nkAttrGroup, nkGenericParams:
        ;
    else
      Break;   // nkGuid, nkVisibility, the first member: the clause is over
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ Adds every ancestor's own member names to ANames, recursively, for the
  ancestors THIS UNIT declares. False when the chain reaches a type it does
  not: the set is then incomplete, and a specifier naming something not in it
  may well name an inherited member. That is exactly what happened in
  uaviTypes.pas (2026-09-05): eight descendants of a TLabNameObject declared in
  another unit, each with `property X: string read Code write Code`, and each
  got a `Code: string` field written into it - the parent's field, seen from
  here as an unknown name. TObject and the interface roots count as known
  and memberless. ASeen breaks a cycle a broken buffer could contain. }
function WalkAncestors(const ATree: TPasTree; ATypeNode: Integer;
  const ATypeByKey: TDictionary<string, Integer>;
  ANames, ASeen: TDictionary<string, Boolean>): Boolean;
var
  LKey: string;
  LNode: Integer;
begin
  Result := True;
  for LKey in AncestorKeys(ATree, ATypeNode) do
  begin
    if ASeen.ContainsKey(LKey) then
      Continue;
    ASeen.AddOrSetValue(LKey, True);
    if (LKey = 'tobject') or (LKey = 'iinterface') or (LKey = 'iunknown') or
       (LKey = 'idispatch') then
      Continue;
    if not ATypeByKey.TryGetValue(LKey, LNode) then
    begin
      Result := False;
      Continue;
    end;
    CollectMemberNames(ATree, LNode, ANames);
    if not WalkAncestors(ATree, LNode, ATypeByKey, ANames, ASeen) then
      Result := False;
  end;
end;

function ClassCompleteFor(const ATree: TPasTree;
  APasLine, APasCol: Integer): TLspClassCompleteAnswer;
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
  // ---- the orphan-implementation pass (declaration from a stray body)
  LDeclaredKeys: TDictionary<string, Boolean>;
  LOrphans: TList<TOrphanCandidate>;
  // TypeKey -> the joined declaration lines plus the FIRST one's NameOffset.
  LOrphansByType: TDictionary<string, TOrphanCandidate>;
  LOrphanCand: TOrphanCandidate;
  LOrphanIdx: Integer;
  LOrphanGroup: TOrphanCandidate;
  LHasOrphan: Boolean;
  LMemberIndent: string;
  // Where an orphan's OWN declaration lands, raw (pre-shift) - see the caret
  // rule below the two passes. LOrphanEditRawLine is the CONTAINING edit's
  // own raw line, kept separately so InsertedLinesBefore is asked about the
  // right one - see the comment where these are set.
  LOrphanCaretRawLine, LOrphanCaretRawCol, LOrphanEditRawLine: Integer;
  // ---- the property-accessor pass
  LTypeName, LMemberText, LPropType, LIndexParams, LWord, LAccessor,
    LIndent: string;
  LProp, LSpec, LTarget, LPropName, LSpecVis, LWhich: Integer;
  LSpecText, LAccessorName: string;
  LVis: TPasVisibleToken;
  LMembers: TDictionary<string, Boolean>;
  LIsMethod, LNeedsSection, LIsInterface: Boolean;
  LMemberEdits: TArray<TLspClassEdit>;
  // ---- the caret's scope
  LScopeAll, LScopeIsRoutine: Boolean;
  LScopeKey, LScopeName, LTypeKey: string;
  LBestNode, LBestSize, LSize: Integer;
  // ---- inherited members
  LTypeByKey: TDictionary<string, Integer>;
  LSeen: TDictionary<string, Boolean>;
  LAncestorsUnknown: Boolean;
begin
  Result := Default(TLspClassCompleteAnswer);
  Result.Provider := 'pastree/classComplete';
  LImpls := TDictionary<string, Boolean>.Create;
  LDecls := TList<TDeclCandidate>.Create;
  LDeclaredKeys := TDictionary<string, Boolean>.Create;
  LOrphans := TList<TOrphanCandidate>.Create;
  LOrphansByType := TDictionary<string, TOrphanCandidate>.Create;
  LTypeByKey := TDictionary<string, Integer>.Create;
  try
    { THE SCOPE: the type the caret is in, or the one free routine it is in.
      Not the whole unit - that was the first design (one answer per file,
      fewer presses) and it is what turned one press on an empty line of
      uaviTypes.pas into eight classes' worth of edits the user had not asked
      about and could not review (2026-09-05). The native command completes
      the class at the caret, and so, now, does this one; a free routine is
      its own scope because it belongs to no class. (0, 0) keeps the
      whole-unit answer for a client with no caret to send. }
    LScopeAll := APasLine <= 0;
    LScopeIsRoutine := False;
    LScopeKey := '';
    LScopeName := '';
    if not LScopeAll then
    begin
      // The innermost routine around the caret: a body, or a declaration.
      LBestNode := NIL_NODE;
      LBestSize := MaxInt;
      for LIdx := 0 to High(ATree.Nodes) do
        if (ATree.Nodes[LIdx].Kind = nkRoutine) and
           NodeContains(ATree, LIdx, APasLine, APasCol, LSize) and
           (LSize < LBestSize) then
        begin
          LBestNode := LIdx;
          LBestSize := LSize;
        end;
      LSkip := False;
      LChain := '';
      if LBestNode <> NIL_NODE then
      begin
        // A member declaration knows its type from its parents; an
        // implementation carries it in its own dotted name.
        LChain := TypeChain(ATree, LBestNode, LSkip);
        if (LChain = '') and not LSkip and
           RoutineName(ATree, LBestNode, LNameFirst, LNameLast, LSegments) then
        begin
          if Length(LSegments) > 1 then
            LChain := string.Join('.', LSegments, 0, Length(LSegments) - 1)
          else
          begin
            LScopeIsRoutine := True;
            LScopeKey := MakeKey('', LSegments[0],
              ParamsKey(ATree, LBestNode));
            LScopeName := LSegments[0];
          end;
        end;
      end;
      // No routine, or one whose type the walk could not name (an
      // interface's method, a nested routine): the innermost TYPE, then.
      if (LChain = '') and not LScopeIsRoutine then
      begin
        LBestNode := NIL_NODE;
        LBestSize := MaxInt;
        for LIdx := 0 to High(ATree.Nodes) do
          if (ATree.Nodes[LIdx].Kind in [nkClassType, nkRecordType,
               nkObjectType, nkHelperType, nkInterfaceType]) and
             NodeContains(ATree, LIdx, APasLine, APasCol, LSize) and
             (LSize < LBestSize) then
          begin
            LBestNode := LIdx;
            LBestSize := LSize;
          end;
        if LBestNode <> NIL_NODE then
        begin
          LTypeName := TypeNameOf(ATree, LBestNode);
          LChain := TypeChain(ATree, LBestNode, LSkip);
          if LChain <> '' then
            LChain := LChain + '.' + LTypeName
          else
            LChain := LTypeName;
        end;
      end;
      if not LScopeIsRoutine then
      begin
        if LChain = '' then
        begin
          Result.Provider := 'pastree/classComplete: the caret is not in a '
            + 'class or a routine - nothing to complete';
          Exit;
        end;
        LScopeKey := LowerCase(StripGenerics(LChain));
        LScopeName := LChain;
      end;
    end;

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
        LKey := MakeKey(LChain, LSegments[LDots - 1], ParamsKey(ATree, LIdx));
        LImpls.AddOrSetValue(LKey, True);
        { An ORPHAN candidate - `TFoo.Bar` with no declaration in TFoo. Built
          unconditionally here and filtered once every declaration in the
          unit has been seen (below), because the real declaration can sit
          AFTER this implementation in ATree.Nodes (arena order, not source
          order). A free routine (LDots = 1) has no class to be orphaned
          from - a missing forward declaration there is a compile error, not
          this feature's business. }
        if LDots > 1 then
        begin
          LOrphanCand := Default(TOrphanCandidate);
          LOrphanCand.Key := LKey;
          LOrphanCand.TypeKey := LowerCase(StripGenerics(LChain));
          LOrphanCand.Header := BuildHeader(ATree, LIdx, LNameFirst, LNameLast,
            '', LSegments[LDots - 1], LOrphanCand.NameOffset);
          if LOrphanCand.Header <> '' then
            LOrphans.Add(LOrphanCand);
        end;
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
      LCand.TypeKey := LowerCase(StripGenerics(LChain));
      LCand.Name := LName;
      if LChain <> '' then
        LCand.Name := LChain + '.' + LName;
      LCand.OrderTok := ATree.NodeLeftmostVis(LIdx);
      LCand.Seq := LDecls.Count;
      if LChain = '' then
        LCand.Header := BuildHeader(ATree, LIdx, LNameFirst, LNameLast, '')
      else
        LCand.Header := BuildHeader(ATree, LIdx, LNameFirst, LNameLast,
          LChain + '.');
      if LCand.Header = '' then
        Continue;
      LDecls.Add(LCand);
      LDeclaredKeys.AddOrSetValue(LCand.Key, True);
    end;

    { Which orphan candidates truly have no declaration anywhere in the unit,
      now that every declaration has been seen. Grouped by TYPE, so a type
      with several orphaned methods gets its declarations in ONE member edit -
      the same rule the property pass below follows, and for the same reason:
      one edit per PLACE, not one per routine. }
    for LOrphanIdx := 0 to LOrphans.Count - 1 do
    begin
      LOrphanCand := LOrphans[LOrphanIdx];
      if LDeclaredKeys.ContainsKey(LOrphanCand.Key) then
        Continue;
      // Only the caret's own type gets its orphans back.
      if not LScopeAll and
         (LScopeIsRoutine or (LOrphanCand.TypeKey <> LScopeKey)) then
        Continue;
      if LOrphansByType.TryGetValue(LOrphanCand.TypeKey, LOrphanGroup) then
      begin
        // Joined onto the type's group; the group keeps the FIRST orphan's
        // NameOffset, since that is the line the caret will go to.
        LOrphanGroup.Header := LOrphanGroup.Header + sLineBreak +
          LOrphanCand.Header;
        LOrphansByType[LOrphanCand.TypeKey] := LOrphanGroup;
      end
      else
        LOrphansByType.Add(LOrphanCand.TypeKey, LOrphanCand);
    end;

    { PROPERTY ACCESSORS. A second kind of edit, and the half the user called
      the one that is really missing: `read GetFoo` with no GetFoo declares
      the method (and gets a body like any other), `read FFoo` with no FFoo
      declares the field. Each type gets ONE member edit carrying everything
      planned for it, so its private section is touched once. }
    LOrphanCaretRawLine := 0;
    LOrphanCaretRawCol := 0;
    // Every named type this unit declares, by bare name - what an ancestor
    // clause is resolved against (WalkAncestors). A forward declaration
    // (`TFoo = class;`) has no members and must not shadow the real one.
    for LIdx := 0 to High(ATree.Nodes) do
    begin
      if not (ATree.Nodes[LIdx].Kind in [nkClassType, nkRecordType,
        nkObjectType, nkHelperType, nkInterfaceType]) then
        Continue;
      LTypeKey := LowerCase(StripGenerics(TypeNameOf(ATree, LIdx)));
      if LTypeKey = '' then
        Continue;
      if ((ATree.Nodes[LIdx].Kind = nkClassType) and
          (ATree.Nodes[LIdx].Aux = 1)) or
         ((ATree.Nodes[LIdx].Kind = nkInterfaceType) and
          (ATree.Nodes[LIdx].Aux and 2 <> 0)) then
      begin
        if not LTypeByKey.ContainsKey(LTypeKey) then
          LTypeByKey.Add(LTypeKey, LIdx);
      end
      else
        LTypeByKey.AddOrSetValue(LTypeKey, LIdx);
    end;
    for LIdx := 0 to High(ATree.Nodes) do
    begin
      if not (ATree.Nodes[LIdx].Kind in [nkClassType, nkRecordType,
        nkObjectType, nkHelperType, nkInterfaceType]) then
        Continue;
      // An INTERFACE takes part here even though it takes no part in the body
      // pass: its properties still need accessor METHODS declared - it has no
      // fields to point at and no bodies of its own, so a specifier there can
      // only be a method, and only its implementors write it.
      LIsInterface := ATree.Nodes[LIdx].Kind = nkInterfaceType;
      LTypeName := TypeNameOf(ATree, LIdx);
      if LTypeName = '' then
        Continue;   // an anonymous/inline type has no implementation to write
      LChain := TypeChain(ATree, LIdx, LSkip);
      if LSkip and not LIsInterface then
        Continue;
      if LChain <> '' then
        LChain := LChain + '.' + LTypeName
      else
        LChain := LTypeName;
      LTypeKey := LowerCase(StripGenerics(LChain));
      // Only the caret's own type - see the scope block above.
      if not LScopeAll and (LScopeIsRoutine or (LTypeKey <> LScopeKey)) then
        Continue;
      LMembers := TDictionary<string, Boolean>.Create;
      LSeen := TDictionary<string, Boolean>.Create;
      try
        CollectMemberNames(ATree, LIdx, LMembers);
        LAncestorsUnknown := not WalkAncestors(ATree, LIdx, LTypeByKey,
          LMembers, LSeen);
        // Orphan declarations for THIS type, if any - seeded first so the
        // property accessors below join them with the same sLineBreak rule
        // they already use for each other. An interface never orphans (it
        // has no implementations of its own to be missing a declaration
        // for).
        LMemberText := '';
        LHasOrphan := not LIsInterface and
          LOrphansByType.TryGetValue(LowerCase(StripGenerics(LChain)),
            LOrphanGroup);
        if LHasOrphan then
          LMemberText := LOrphanGroup.Header;
        LProp := ATree.Nodes[LIdx].FirstChild;
        while LProp <> NIL_NODE do
        begin
          if ATree.Nodes[LProp].Kind <> nkPropertyDecl then
          begin
            LProp := ATree.Nodes[LProp].NextSibling;
            Continue;
          end;
          LPropType := PropertyTypeText(ATree, LProp);
          LIndexParams := PropertyIndexParams(ATree, LProp);
          { A property with NEITHER read NOR write is the shape the user
            actually types first - `property X: Integer;` - and it does not
            compile until something backs it. Both accessors are synthesized
            from the property's own name (`GetX`/`SetX`), declared, given
            bodies where the container has bodies, and `read`/`write` are
            written into the property line itself: an accessor the property
            does not point at would be dead code, so the two edits go
            together or not at all.

            METHODS rather than a field, by the user's call (2026-08-23), and
            it is the only answer an interface could take anyway - so one rule
            covers both containers. }
          if (LPropType <> '') and not PropertyHasAccessor(ATree, LProp) then
          begin
            LPropName := ChildOfKind(ATree, LProp, nkIdent);
            LSpecVis := PropertySpecInsertVis(ATree, LProp);
            if (LPropName <> NIL_NODE) and (LSpecVis > 0) then
            begin
              LName := Flatten(ATree.NodeSpanText(LPropName));
              LSpecText := '';
              for LWhich := 0 to 1 do
              begin
                if LWhich = 0 then
                  LWord := 'read'
                else
                  LWord := 'write';
                // Get/Set, not Read/Write: the convention the whole language
                // writes accessors in, and the one our own Get/Set rule
                // recognises when the user writes the specifier by hand.
                if LWhich = 0 then
                  LAccessorName := 'Get' + LName
                else
                  LAccessorName := 'Set' + LName;
                if LMembers.ContainsKey(LowerCase(LAccessorName)) then
                begin
                  // The name is taken by something else in this type - point
                  // the property at it rather than declaring a second one.
                  LSpecText := LSpecText + ' ' + LWord + ' ' + LAccessorName;
                  Continue;
                end;
                LMembers.AddOrSetValue(LowerCase(LAccessorName), True);
                LAccessor := AccessorDecl(ATree, LProp, LAccessorName, LWord,
                  LPropType, LIndexParams, True, LIsMethod);
                if LMemberText <> '' then
                  LMemberText := LMemberText + sLineBreak;
                LMemberText := LMemberText + LAccessor;
                LSpecText := LSpecText + ' ' + LWord + ' ' + LAccessorName;
                if not LIsInterface then
                begin
                  LCand := Default(TDeclCandidate);
                  LCand.Key := MakeKey(LChain, LAccessorName, '');
                  LCand.Name := LChain + '.' + LAccessorName;
                  LCand.OrderTok := ATree.NodeLeftmostVis(LProp);
                  LCand.Seq := LDecls.Count;
                  LCand.TypeKey := LTypeKey;
                  LCand.Header := AccessorImplHeader(LAccessor, LChain);
                  LDecls.Add(LCand);
                end;
              end;
              if LSpecText <> '' then
              begin
                LEdit := Default(TLspClassEdit);
                LVis := ATree.Source.Visible[LSpecVis];
                with ATree.Source.Files[LVis.FileId] do
                  OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos,
                    LEdit.Line, LEdit.Col);
                LEdit.Text := LSpecText;
                LEdit.Kind := 'spec';
                LEdit.Name := LChain + '.' + LName;
                LMemberEdits := LMemberEdits + [LEdit];
              end;
            end;
          end;
          LSpec := ATree.Nodes[LProp].FirstChild;
          while LSpec <> NIL_NODE do
          begin
            if (ATree.Nodes[LSpec].Kind = nkPropSpec) and (LPropType <> '') then
            begin
              LWord := ATree.NodeText(LSpec);
              LTarget := ChildOfKind(ATree, LSpec, nkIdent);
              if (SameText(LWord, 'read') or SameText(LWord, 'write')) and
                 (LTarget <> NIL_NODE) then
              begin
                LName := Flatten(ATree.NodeSpanText(LTarget));
                // A dotted specifier (`read FInner.Value`) names something
                // that is not this type's to declare. And a name that is not
                // in the member set may still be INHERITED when an ancestor
                // lives in another unit (WalkAncestors): then a FIELD name
                // is left alone - `read Code` on a TLabNameObject descendant
                // is the parent's Code, not a field to invent - while a
                // Get/Set-shaped name still gets its method, since pointing a
                // new property at a foreign base's accessor is not how
                // anyone writes Delphi. An interface with a foreign ancestor
                // gets nothing: its specifiers are methods, and inheriting
                // the getter from the base interface is the common case.
                if (Pos('.', LName) = 0) and
                   not LMembers.ContainsKey(LowerCase(LName)) and
                   (not LAncestorsUnknown or
                    (not LIsInterface and
                     (LName.ToLower.StartsWith('get') or
                      LName.ToLower.StartsWith('set')))) then
                begin
                  // Claimed immediately: two properties may share an
                  // accessor, and it is declared once.
                  LMembers.AddOrSetValue(LowerCase(LName), True);
                  LAccessor := AccessorDecl(ATree, LProp, LName, LWord,
                    LPropType, LIndexParams, LIsInterface, LIsMethod);
                  if LMemberText <> '' then
                    LMemberText := LMemberText + sLineBreak;
                  LMemberText := LMemberText + LAccessor;
                  // An interface's accessors get NO body here: whoever
                  // implements the interface writes them.
                  if LIsMethod and not LIsInterface then
                  begin
                    // The generated method needs a body like any other
                    // declaration - ordered where the property sits.
                    LCand := Default(TDeclCandidate);
                    LCand.Key := MakeKey(LChain, LName, '');
                    LCand.Name := LChain + '.' + LName;
                    LCand.OrderTok := ATree.NodeLeftmostVis(LProp);
                    LCand.Seq := LDecls.Count;
                    // The member text minus its trailing ';' is the header,
                    // with the type spliced in - one source for both, so the
                    // declaration and its body can never disagree.
                    LCand.TypeKey := LTypeKey;
                  LCand.Header := AccessorImplHeader(LAccessor, LChain);
                    LDecls.Add(LCand);
                  end;
                end;
              end;
            end;
            LSpec := ATree.Nodes[LSpec].NextSibling;
          end;
          LProp := ATree.Nodes[LProp].NextSibling;
        end;
        if LMemberText = '' then
          Continue;
        if not MemberInsertPos(ATree, LIdx, not LIsInterface, LLine, LCol,
          LIndent, LNeedsSection) then
          Continue;
        LEdit := Default(TLspClassEdit);
        LEdit.Line := LLine;
        LEdit.Col := LCol;
        LEdit.Kind := 'member';
        LEdit.Name := LChain;
        // The members' own indent: one level under a section header we
        // write, level with their neighbours when they join an existing
        // section. ONE variable for both the text and the caret column
        // below, so the two cannot disagree (they did: the first caret
        // column assumed the header shape for both, 2026-09-05).
        if LNeedsSection then
          LMemberIndent := LIndent + '  '
        else
          LMemberIndent := LIndent;
        if LNeedsSection then
          // Before the type's `end`: write the section, the members, then the
          // indentation the `end` had, since we are standing on its column.
          LEdit.Text := 'private' + sLineBreak +
            IndentLines(LMemberText, LMemberIndent) + sLineBreak + LIndent
        else
          // After the last private member: a line break puts us on a fresh
          // line, and that line needs the same indent as its neighbours.
          LEdit.Text := sLineBreak +
            IndentLines(LMemberText, LMemberIndent);
        LMemberEdits := LMemberEdits + [LEdit];
        { The orphan pass seeds LMemberText FIRST (before any property
          accessor lines), so its own declaration is always the block's FIRST
          line - one line below LEdit.Line either way, `private` header or
          not. Recorded here, raw, because a client that just typed the
          implementation wants the caret ON the declaration it asked for -
          the symmetric answer to syncPrototypes putting the caret on the
          OTHER half when a declaration is what was edited. Earliest wins,
          when more than one type has an orphan.

          LOrphanEditRawLine is this SAME edit's own (pre-shift) line, kept
          alongside the declaration's - InsertedLinesBefore below must be
          asked about THAT line, not the declaration's: asking about the
          declaration's own line (one past the edit's) would count this
          edit's own inserted breaks a SECOND time, on top of the "+ 1"
          already applied here, and land the caret one line too far (a live
          check, 2026-09-05: the declaration itself was right, the caret
          landed on the member after it). The body-caret rule above avoids
          the same trap by asking about ITS edit's own raw line too, for the
          same reason. }
        if LHasOrphan and ((LOrphanCaretRawLine = 0) or
           (LEdit.Line + 1 < LOrphanCaretRawLine)) then
        begin
          LOrphanEditRawLine := LEdit.Line;
          LOrphanCaretRawLine := LEdit.Line + 1;
          // 1-based: past the indent, past `procedure `/`class function `,
          // ON the identifier - where Go To Definition would put it.
          LOrphanCaretRawCol := Length(LMemberIndent) + 1 +
            LOrphanGroup.NameOffset;
        end;
      finally
        LSeen.Free;
        LMembers.Free;
      end;
    end;

    // Declaration order is source order, and the arena is not in source
    // order (leaves are allocated first) - so sort by the first token.
    LDecls.Sort(TComparer<TDeclCandidate>.Construct(
      function(const A, B: TDeclCandidate): Integer
      begin
        Result := A.OrderTok - B.OrderTok;
        if Result = 0 then
          Result := A.Seq - B.Seq;
      end));

    LText := '';
    LName := '';
    LCount := 0;
    for LIdx := 0 to LDecls.Count - 1 do
    begin
      LKey := LDecls[LIdx].Key;
      // The caret's scope: the type's members, or the one free routine.
      if not LScopeAll then
        if LScopeIsRoutine then
        begin
          if LKey <> LScopeKey then
            Continue;
        end
        else if LDecls[LIdx].TypeKey <> LScopeKey then
          Continue;
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

    // No trailing break: the insertion point sits just after a token, so the
    // text that follows it already begins with the line's own ending. Keeping
    // ours would leave a second blank line in front of whatever came next -
    // usually the unit's `end.` (first live run, 2026-08-23).
    if LText.EndsWith(sLineBreak) then
      LText := Copy(LText, 1, Length(LText) - Length(sLineBreak));
    if (LText = '') and (Length(LMemberEdits) = 0) then
    begin
      Result.Provider := 'pastree/classComplete: nothing to implement';
      if LScopeName <> '' then
        Result.Provider := Result.Provider + ' in ' + LScopeName;
      Exit;
    end;
    Result.Edits := LMemberEdits;
    if LText <> '' then
    begin
      if not ImplInsertPos(ATree, LLine, LCol) then
      begin
        Result.Provider :=
          'pastree/classComplete: no implementation section to insert into';
        Exit;
      end;
      LEdit := Default(TLspClassEdit);
      LEdit.Line := LLine;
      LEdit.Col := LCol;
      LEdit.Text := LText;
      LEdit.Kind := 'body';
      LEdit.Name := LName;
      Result.Edits := Result.Edits + [LEdit];
      // The caret goes on the indented empty line of the FIRST body. From the
      // insertion point's own line L: the first break ends L, L+1 is the blank
      // separator, L+2 the header, L+3 `begin`, L+4 the body line. Plus every
      // line the MEMBER edits insert above it - they are applied too, and the
      // caret is a position in the finished text.
      Result.CaretLine := LLine + 4 + InsertedLinesBefore(Result.Edits, LLine);
      Result.CaretCol := 3;
    end
    else if LOrphanCaretRawLine > 0 then
    begin
      // No bodies to write, but at least one orphan got its declaration back:
      // the caret goes there - the mirror of syncPrototypes landing on the
      // OTHER half, and of the body caret above landing on the stub just
      // generated from a declaration.
      Result.CaretLine := LOrphanCaretRawLine +
        InsertedLinesBefore(Result.Edits, LOrphanEditRawLine);
      Result.CaretCol := LOrphanCaretRawCol;
    end
    else
      // Members only (a property whose accessors are all fields, and no
      // orphan): the caret has nowhere better to be than where the user left
      // it.
      Result.CaretLine := 0;
    // Ascending by position, which is the order an edit writer can apply.
    TArray.Sort<TLspClassEdit>(Result.Edits,
      TComparer<TLspClassEdit>.Construct(CompareClassEdits));
    Result.Provider := Format(
      'pastree/classComplete: %d to implement, %d member edit(s)',
      [LCount, Length(LMemberEdits)]);
    if LScopeName <> '' then
      Result.Provider := Result.Provider + ' in ' + LScopeName;
  finally
    LTypeByKey.Free;
    LOrphansByType.Free;
    LOrphans.Free;
    LDeclaredKeys.Free;
    LDecls.Free;
    LImpls.Free;
  end;
end;

function TrySemicolonRepair(const ATree: TPasTree; AVisIndex: Integer;
  const AText: string; out ARepaired: string;
  out ALine, ACol: Integer): Boolean;
var
  LVisIdx, LOffset: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  ARepaired := AText;
  ALine := 0;
  ACol := 0;
  // The `;` belongs after the token BEFORE the one that tripped the parser:
  // the diagnostic points at what it found instead.
  LVisIdx := AVisIndex - 1;
  if (LVisIdx < 0) or (LVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[LVisIdx];
  if LVis.FileId <> 0 then
    Exit;   // an $I include - not the text we were handed
  LOffset := ATree.Source.Files[0].Tokens[LVis.TokenIndex].EndPos;
  if (LOffset < 0) or (LOffset > Length(AText)) then
    Exit;
  ATree.Source.Files[0].OffsetToLineCol(LOffset, ALine, ACol);
  ARepaired := Copy(AText, 1, LOffset) + ';' +
    Copy(AText, LOffset + 1, MaxInt);
  Result := True;
end;

function MapColToOriginal(ALine, ACol: Integer;
  const ARepairs: TArray<TLspClassEdit>): Integer;
var
  LIdx: Integer;
begin
  Result := ACol;
  for LIdx := 0 to High(ARepairs) do
    if (ARepairs[LIdx].Line = ALine) and (ARepairs[LIdx].Col < ACol) then
      Dec(Result);
end;

procedure MergeSemicolonRepairs(var AAnswer: TLspClassCompleteAnswer;
  const ARepairs: TArray<TLspClassEdit>);
var
  LIdx, LJdx, LShift: Integer;
begin
  if Length(ARepairs) = 0 then
    Exit;
  for LIdx := 0 to High(AAnswer.Edits) do
  begin
    LShift := 0;
    for LJdx := 0 to High(ARepairs) do
      if (ARepairs[LJdx].Line = AAnswer.Edits[LIdx].Line) and
         (ARepairs[LJdx].Col < AAnswer.Edits[LIdx].Col) then
        Inc(LShift);
    Dec(AAnswer.Edits[LIdx].Col, LShift);
  end;
  AAnswer.Edits := AAnswer.Edits + ARepairs;
  // CompareClassEdits fixes the order at an identical position - which the
  // three edits of one bare property all share.
  TArray.Sort<TLspClassEdit>(AAnswer.Edits,
    TComparer<TLspClassEdit>.Construct(CompareClassEdits));
end;

end.
