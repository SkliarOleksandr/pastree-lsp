unit PasLsp.SyncPrototypes;

{
  Prototype sync: a signature edited on ONE side, mirrored onto the other.

  The gesture is the one the IDE calls "Sync Prototypes" and has never made
  work here (user, 2026-09-01): change `procedure Foo(A: Integer);` in the
  class - or in the implementation - and the other half is rewritten to
  match. It is the natural companion to class completion (Ctrl+Shift+C
  declares the missing bodies; this keeps an existing pair in step), and it is
  reached the same way: a keyboard binding plus a local-menu item, both in the
  IDE package.

  THE SIDE UNDER THE CARET WINS. That is the whole conflict policy, and it
  needs no other: the caret is where the user just typed, and the other side
  is by definition the stale copy. There is no attempt to guess which of two
  differing signatures is "newer" - nothing in the buffer knows that, and a
  wrong guess silently reverts work.

  ONE PAIR PER PRESS, not the whole unit. Class completion answers about a
  file because "what did I declare and not implement" has one answer per file;
  "what did I just change" has exactly one answer per caret. Rewriting every
  mismatched pair in the unit would also rewrite the ones the user is midway
  through editing elsewhere, which is a way to lose work.

  A TEXT SPLICE, NOT A RE-EMISSION. The new header keeps the TARGET's own
  keyword line-up and its own name (`TFoo.Bar` in the implementation, `Bar` in
  the class) and takes everything after the name from the SOURCE, exactly as
  the source spells it: parameter names, attributes, `array of const`, a
  multi-line list flattened to one. Re-deriving the text from the model
  instead would quietly reformat code the user did not ask to have reformatted.

  WHAT IT DOES NOT MIRROR, deliberately:

  - THE NAME. The pair is FOUND by name, so a rename in one place has no
    counterpart to find - it reads as a new routine, and this feature declines
    rather than renaming the other half (that is what Rename is for). What
    IS mirrored is everything from the name onwards, plus the routine word
    itself: procedure -> function and back, `class` gained or lost.
  - DIRECTIVES AFTER THE HEADER'S SEMICOLON. `virtual`, `override`,
    `overload`, `stdcall` and the rest belong to the side that declares them -
    the declaration carries `virtual;`, the implementation must not - so the
    replacement ends AT the semicolon and everything past it is left exactly
    as it was.
  - DEFAULT VALUES INTO AN IMPLEMENTATION. E2226: they are legal in the
    declaration only, so a header copied into the implementation loses them
    (StripDefaults, shared with class completion). The other direction keeps
    whatever the declaration already had - a default the implementation cannot
    carry is not information the implementation can have destroyed.

  OVERLOADS ARE REFUSED, not guessed at. Two declarations of one name mean the
  pairing is ambiguous the moment a signature differs - which is precisely
  when this feature is used - and picking the "closest" one is how an edit
  lands on the wrong overload. The refusal names the count, and the user can
  still edit both sides by hand. (An overload set whose signatures all still
  match is not ambiguous in the way that matters: nothing needs mirroring, and
  the answer says so.)

  Everything here is a pure function of the TREE - no project, no analysis, no
  I/O - for the same reason class completion is: the whole point is the
  signature typed a second ago, which no rebuild has seen.
}

interface

uses
  PasTree.Ast;

type
  { One replacement. Unlike class completion's insert-only edit this one has
    an END: the target's existing header is REPLACED, so the range is real and
    the client must honour it. All four coordinates are 1-based PasTree
    coordinates; the end is EXCLUSIVE (it is the position just past the last
    character to go). }
  TLspSyncEdit = record
    Line: Integer;
    Col: Integer;
    EndLine: Integer;
    EndCol: Integer;
    Text: string;
    Name: string;    // 'TFoo.Bar' - for the log and the IDE's message
  end;

  TLspSyncAnswer = record
    { At most one, today and by design - see the header. An array anyway,
      because that is what the client already knows how to apply and because
      "one" is a property of the gesture, not of the protocol. }
    Edits: TArray<TLspSyncEdit>;
    { Names the outcome, and a refusal says WHY: "nothing happened" is the one
      answer a user cannot debug. }
    Provider: string;
  end;

{ The mirror edit for the routine at the 1-based (APasLine, APasCol) of the
  buffer ATree describes. Never raises; every refusal comes back as an empty
  edit list and a Provider that names the reason. }
function SyncPrototypeAt(const ATree: TPasTree;
  APasLine, APasCol: Integer): TLspSyncAnswer;

implementation

uses
  System.SysUtils,
  PasTree.Types,
  PasTree.Preprocessor,
  PasLsp.ClassComplete;

type
  { One side of a pair, located and sliced. }
  TRoutineSide = record
    Node: Integer;
    NameFirst: Integer;   // visible-token index of the name's first token
    NameLast: Integer;    // ... and its last, generic parameters included
    HeadFirst: Integer;   // where the replacement starts: the routine word,
                          // or the `class` in front of it when there is one
    TailEnd: Integer;     // last token of the header - the one before the `;`
    IsImpl: Boolean;      // has a body: this side is the implementation
    Chain: string;        // 'TFoo' / '' for a free routine
    Name: string;         // the last name segment
    IsClass: Boolean;     // `class procedure` - see the Aux note below
  end;

{ The `class` in `class procedure` is NOT inside the routine node's span - the
  parser consumes it before opening the node and records it as Aux=1 (the same
  trap class completion documents). Two consequences, both handled here: the
  word has to be re-emitted when the source has it, and the target's own
  `class` has to be swallowed by the replacement range, or turning a class
  method into an instance one would leave a stray `class` behind. }
function IsClassRoutine(const ATree: TPasTree; ARoutine: Integer): Boolean;
begin
  Result := ATree.Nodes[ARoutine].Aux = 1;
end;

{ The visible token holding `class` in front of ARoutine, -1 when there is
  none. Checked by TEXT rather than assumed from Aux: Aux=1 is also set for
  shapes where the word is somewhere else, and a range that starts one token
  too early eats whatever that token actually was. }
function ClassWordVis(const ATree: TPasTree; ARoutine: Integer): Integer;
var
  LFirst: Integer;
begin
  Result := -1;
  LFirst := ATree.NodeLeftmostVis(ARoutine);
  if LFirst <= 0 then
    Exit;
  if SameText(RawSpan(ATree, LFirst - 1, LFirst - 1), 'class') then
    Result := LFirst - 1;
end;

{ 1-based (line, col) of a visible token's first character. False when the
  token is outside the MAIN file - a declaration living in an $I include is
  not something this feature may rewrite: the text the client holds, and the
  coordinates it applies edits in, are the main file's. }
function TokenStart(const ATree: TPasTree; AVis: Integer;
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
  with ATree.Source.Files[LVis.FileId] do
    OffsetToLineCol(Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := True;
end;

{ ... and just PAST its last character, which is what an exclusive range end
  wants. }
function TokenEnd(const ATree: TPasTree; AVis: Integer;
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
  with ATree.Source.Files[LVis.FileId] do
    OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos, ALine, ACol);
  Result := True;
end;

{ Is (ALine, ACol) at or after (AStartLine, AStartCol) and before
  (AEndLine, AEndCol)? Plain lexicographic order on a pair - the only
  comparison this unit needs, and spelling it once keeps the three uses of it
  honest about which end is inclusive. }
function PosInRange(ALine, ACol, AStartLine, AStartCol,
  AEndLine, AEndCol: Integer): Boolean;
begin
  Result := False;
  if (ALine < AStartLine) or ((ALine = AStartLine) and (ACol < AStartCol)) then
    Exit;
  if (ALine > AEndLine) or ((ALine = AEndLine) and (ACol > AEndCol)) then
    Exit;
  Result := True;
end;

{ The end of the HEADER: the last token that is neither a directive nor the
  body - the parameter list, or the result type, or the name when there is
  neither. The token after it is the header's semicolon, which is where the
  replacement deliberately stops. }
function HeaderTailEnd(const ATree: TPasTree; ARoutine,
  ANameLast: Integer): Integer;
var
  LChild: Integer;
begin
  Result := ANameLast;
  LChild := ATree.Nodes[ARoutine].FirstChild;
  while LChild <> NIL_NODE do
  begin
    case ATree.Nodes[LChild].Kind of
      nkRoutineBody, nkDirective, nkAttrGroup: ;
    else
      if (ATree.NodeLeftmostVis(LChild) > ANameLast) and
         (ATree.Nodes[LChild].LastToken > Result) then
        Result := ATree.Nodes[LChild].LastToken;
    end;
    LChild := ATree.Nodes[LChild].NextSibling;
  end;
end;

{ Everything this unit needs to know about one routine node, or False if it is
  not a routine it can work with (an unnamed one, a name that crosses an
  include). }
function DescribeRoutine(const ATree: TPasTree; ARoutine: Integer;
  out ASide: TRoutineSide): Boolean;
var
  LSegments: TArray<string>;
  LSkip: Boolean;
  LClassVis: Integer;
begin
  Result := False;
  ASide := Default(TRoutineSide);
  if not RoutineName(ATree, ARoutine, ASide.NameFirst, ASide.NameLast,
    LSegments) then
    Exit;
  if Length(LSegments) = 0 then
    Exit;
  ASide.Node := ARoutine;
  ASide.IsImpl := ChildOfKind(ATree, ARoutine, nkRoutineBody) <> NIL_NODE;
  ASide.Name := LSegments[High(LSegments)];
  ASide.IsClass := IsClassRoutine(ATree, ARoutine);
  if ASide.IsImpl then
  begin
    // An implementation carries its own qualification: `TFoo.Bar` is one
    // routine at unit level, not a member of anything the tree nests it in.
    ASide.Chain := '';
    if Length(LSegments) > 1 then
      ASide.Chain := string.Join('.', LSegments, 0, Length(LSegments) - 1);
  end
  else
  begin
    ASide.Chain := TypeChain(ATree, ARoutine, LSkip);
    if LSkip then
      Exit;   // a method of an interface type: implemented elsewhere entirely
  end;
  ASide.HeadFirst := ATree.NodeLeftmostVis(ARoutine);
  LClassVis := ClassWordVis(ATree, ARoutine);
  if LClassVis >= 0 then
    ASide.HeadFirst := LClassVis;
  ASide.TailEnd := HeaderTailEnd(ATree, ARoutine, ASide.NameLast);
  Result := (ASide.HeadFirst >= 0) and (ASide.TailEnd >= ASide.NameLast);
end;

{ The two halves are paired by CHAIN + NAME, case-insensitively and with
  generic parameters ignored on the chain - `TStack<T>` in the class is
  `TStack<T>` on the implementation but the two spellings need not match
  character for character. Parameters are deliberately NOT part of this: they
  are the thing that just changed. }
function SameRoutineIdentity(const A, B: TRoutineSide): Boolean;
begin
  Result := SameText(A.Name, B.Name) and SameText(A.Chain, B.Chain);
end;

{ The header text the TARGET should now read, built from the SOURCE's tail and
  the target's own head. }
function MirroredHeader(const ATree: TPasTree; const ASource,
  ATarget: TRoutineSide): string;
var
  LWord, LName, LTail: string;
  LWordFirst: Integer;
begin
  Result := '';
  // The routine word as the SOURCE spells it - this is what mirrors a
  // procedure that became a function. Sliced from the source's node start
  // (which excludes `class`, see IsClassRoutine) up to its name.
  LWordFirst := ATree.NodeLeftmostVis(ASource.Node);
  LWord := Flatten(RawSpan(ATree, LWordFirst, ASource.NameFirst - 1));
  if LWord = '' then
    Exit;
  if ASource.IsClass then
    LWord := 'class ' + LWord;
  // The target's OWN name, untouched: the qualification differs between the
  // two sides and is not the source's to dictate.
  LName := Flatten(RawSpan(ATree, ATarget.NameFirst, ATarget.NameLast));
  if LName = '' then
    Exit;
  LTail := '';
  if ASource.TailEnd > ASource.NameLast then
    LTail := Flatten(RawSpan(ATree, ASource.NameLast + 1, ASource.TailEnd));
  if ATarget.IsImpl then
    LTail := StripDefaults(LTail);
  Result := LWord + ' ' + LName + LTail;
end;

function SyncPrototypeAt(const ATree: TPasTree;
  APasLine, APasCol: Integer): TLspSyncAnswer;
var
  LIdx, LStartLine, LStartCol, LEndLine, LEndCol: Integer;
  LBestSpan, LSpan: Integer;
  LSide, LSource, LTarget, LMatch: TRoutineSide;
  LFound, LHaveSource: Boolean;
  LCandidates, LInSync: Integer;
  LSourceKey, LNewText, LOldText: string;
  LEdit: TLspSyncEdit;
begin
  Result := Default(TLspSyncAnswer);
  Result.Provider := 'pastree/syncPrototypes';

  { THE ROUTINE UNDER THE CARET, innermost first. "Innermost" is not a detail:
    a nested routine sits inside another one's span, and the outer routine
    would otherwise win every caret inside it. }
  LHaveSource := False;
  LBestSpan := MaxInt;
  for LIdx := 0 to High(ATree.Nodes) do
  begin
    if ATree.Nodes[LIdx].Kind <> nkRoutine then
      Continue;
    if not DescribeRoutine(ATree, LIdx, LSide) then
      Continue;
    if not TokenStart(ATree, LSide.HeadFirst, LStartLine, LStartCol) then
      Continue;
    if not TokenEnd(ATree, ATree.Nodes[LIdx].LastToken, LEndLine, LEndCol) then
      Continue;
    if not PosInRange(APasLine, APasCol, LStartLine, LStartCol,
      LEndLine, LEndCol) then
      Continue;
    LSpan := LEndLine - LStartLine;
    if LSpan < LBestSpan then
    begin
      LBestSpan := LSpan;
      LSource := LSide;
      LHaveSource := True;
    end;
  end;
  if not LHaveSource then
  begin
    Result.Provider := 'pastree/syncPrototypes: the caret is not in a '
      + 'routine';
    Exit;
  end;

  { ITS COUNTERPART. A declaration looks for the body, a body for the
    declaration - never for another of its own kind, which is what keeps two
    implementations of one name (a legal thing across a conditional-compilation
    directive) from pairing with each other. }
  LCandidates := 0;
  LInSync := 0;
  LFound := False;
  LSourceKey := ParamsKey(ATree, LSource.Node);
  for LIdx := 0 to High(ATree.Nodes) do
  begin
    if ATree.Nodes[LIdx].Kind <> nkRoutine then
      Continue;
    if LIdx = LSource.Node then
      Continue;
    if not DescribeRoutine(ATree, LIdx, LSide) then
      Continue;
    if LSide.IsImpl = LSource.IsImpl then
      Continue;
    if not SameRoutineIdentity(LSide, LSource) then
      Continue;
    Inc(LCandidates);
    if ParamsKey(ATree, LIdx) = LSourceKey then
      Inc(LInSync);
    if not LFound then
    begin
      LMatch := LSide;
      LFound := True;
    end;
  end;

  if LCandidates = 0 then
  begin
    // Not a failure to report as a bug: this is what an unimplemented
    // declaration looks like, and class completion is the feature for it.
    if LSource.IsImpl then
      Result.Provider := Format('pastree/syncPrototypes: no declaration of '
        + '%s to update', [LSource.Name])
    else
      Result.Provider := Format('pastree/syncPrototypes: %s has no '
        + 'implementation yet - Ctrl+Shift+C writes one', [LSource.Name]);
    Exit;
  end;
  if LCandidates > 1 then
  begin
    if LInSync = LCandidates then
    begin
      Result.Provider := Format('pastree/syncPrototypes: %d overloads of %s, '
        + 'all already in step', [LCandidates, LSource.Name]);
      Exit;
    end;
    Result.Provider := Format('pastree/syncPrototypes: %d overloads named %s '
      + '- which one to update is ambiguous, so nothing was changed',
      [LCandidates, LSource.Name]);
    Exit;
  end;

  LTarget := LMatch;
  if not TokenStart(ATree, LTarget.HeadFirst, LStartLine, LStartCol) then
  begin
    Result.Provider := 'pastree/syncPrototypes: the other half is in an '
      + 'include file - not rewritten from here';
    Exit;
  end;
  if not TokenEnd(ATree, LTarget.TailEnd, LEndLine, LEndCol) then
  begin
    Result.Provider := 'pastree/syncPrototypes: the other half is in an '
      + 'include file - not rewritten from here';
    Exit;
  end;

  LNewText := MirroredHeader(ATree, LSource, LTarget);
  if LNewText = '' then
  begin
    Result.Provider := 'pastree/syncPrototypes: could not read the signature '
      + 'under the caret';
    Exit;
  end;
  // ALREADY EQUAL, compared as the replacement would leave it: a target
  // written across three lines is not "different" from a one-line source
  // whose text it already matches once flattened, and rewriting it anyway
  // would reformat the file on a key that changed nothing.
  LOldText := Flatten(RawSpan(ATree, LTarget.HeadFirst, LTarget.TailEnd));
  if LOldText = LNewText then
  begin
    Result.Provider := Format('pastree/syncPrototypes: %s is already in step',
      [LSource.Name]);
    Exit;
  end;

  LEdit := Default(TLspSyncEdit);
  LEdit.Line := LStartLine;
  LEdit.Col := LStartCol;
  LEdit.EndLine := LEndLine;
  LEdit.EndCol := LEndCol;
  LEdit.Text := LNewText;
  if LTarget.Chain <> '' then
    LEdit.Name := LTarget.Chain + '.' + LTarget.Name
  else
    LEdit.Name := LTarget.Name;
  Result.Edits := [LEdit];
  if LTarget.IsImpl then
    Result.Provider := Format('pastree/syncPrototypes: %s implementation '
      + 'updated from its declaration', [LEdit.Name])
  else
    Result.Provider := Format('pastree/syncPrototypes: %s declaration '
      + 'updated from its implementation', [LEdit.Name]);
end;

end.
