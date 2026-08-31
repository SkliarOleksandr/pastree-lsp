unit PasLsp.BlockClose;

{
  The server half of block completion - textDocument/onTypeFormatting with
  the newline as the trigger character. The user presses Enter after a
  block opener; the client (any client: the RAD Studio package, VS Code -
  the method is standard LSP, which is why it is not a pastree/* request)
  sends the caret position; this unit decides whether a closer belongs
  under it and produces exactly one insertion.

  PURELY LEXICAL, BY DESIGN. The question "is there an unclosed opener
  just above the caret" does not survive a parse of the very text that is
  mid-keystroke incomplete: a parser recovers, and its recovery MOVES the
  error away from where the user is typing. A token walk with a stack does
  not - and PasTree's lexer already knows strings, all three comment
  spellings and directives, which is everything that makes naive text
  scanning wrong.

  THE CASCADE PROBLEM, and why the trigger is two separate conditions. A
  `begin` typed above EXISTING balanced code steals the next `end`: it is
  some LATER opener that goes unclosed by end-of-file, not the one just
  typed. So "which opener is unclosed" is unanswerable locally - but two
  facts together are reliable:

    1. the file as a whole has more openers than closers (the new opener
       made the file unbalanced - if everything is closed, nothing is
       missing and nothing fires), and
    2. the LAST line with any code above the caret contains an opener
       (the Enter was pressed right after typing it - pressing Enter
       elsewhere in an unbalanced file changes nothing).

  What counts as an opener is contextual and the rules are spelled out at
  the scan: `class` opens a body only when it is not `class of`, a forward
  declaration or a member prefix; `interface` only as a type (after `=`);
  a `case` directly inside a record is a variant part and shares the
  record's own `end`; `object` after `of` is a procedure type. A wrong
  guess here inserts an `end;` the user deletes with one keystroke - the
  cost model is a typo, not a broken file - but every rule above came out
  of real Pascal, not caution.

  The insertion: new line(s) AFTER the caret's (empty) line, carrying the
  OPENER LINE'S OWN indentation plus the closer - `until ;` for repeat,
  the `finally`/`end;` skeleton for try, `end;` for everything else
  (NEVER `end.` - see the closer selection for the cascade that killed
  that special case). The edit never touches the caret line, so the caret
  stays exactly where Enter left it, in every client, without any cursor
  protocol.
}

interface

/// <summary>
/// Decides the block-completion insertion for a caret that just arrived on
/// ACaretLine (0-based, LSP convention) by pressing Enter. True with the
/// insertion point (0-based line, UTF-16 character - always the end of the
/// caret line) and the text to insert there; False when nothing should be
/// inserted - which is the common case and never an error.
/// </summary>
function PlanBlockClose(const AText: string; ACaretLine: Integer;
  out AInsertLine, AInsertChar: Integer; out ANewText: string): Boolean;

implementation

uses
  System.SysUtils,
  PasTree.Types, PasTree.Lexer;

function PlanBlockClose(const AText: string; ACaretLine: Integer;
  out AInsertLine, AInsertChar: Integer; out ANewText: string): Boolean;
var
  LStream: TPasTokenStream;
  LStack: TArray<TPasTokenKind>;
  LStackCount: Integer;

  procedure Push(AKind: TPasTokenKind);
  begin
    if LStackCount = Length(LStack) then
      SetLength(LStack, LStackCount * 2 + 8);
    LStack[LStackCount] := AKind;
    Inc(LStackCount);
  end;

  function Top: TPasTokenKind;
  begin
    if LStackCount > 0 then
      Result := LStack[LStackCount - 1]
    else
      Result := tkEndOfFile;
  end;

var
  LTokens: TArray<TPasToken>;
  LVisible: TArray<Integer>;   // indices of non-trivia tokens, in order
  LIdx, LCount: Integer;

  function VisKind(AVisIdx: Integer): TPasTokenKind;
  begin
    if (AVisIdx >= 0) and (AVisIdx < LCount) then
      Result := LTokens[LVisible[AVisIdx]].Kind
    else
      Result := tkEndOfFile;
  end;

  // 0-based line of a source offset.
  function LineOf(AOffset: Integer): Integer;
  var
    LLine, LCol: Integer;
  begin
    LStream.OffsetToLineCol(AOffset, LLine, LCol);
    Result := LLine - 1;
  end;

var
  LCaretStart, LCaretEnd, LOfs: Integer;
  LTok: TPasToken;
  LPrevKind, LNextKind: TPasTokenKind;
  LLastLineAbove: Integer;      // last line with a visible token above caret
  LCandidateKind: TPasTokenKind;
  LCandidateLine: Integer;
  LPushIt: Boolean;
  LIndent, LCloser: string;
begin
  Result := False;
  AInsertLine := 0;
  AInsertChar := 0;
  ANewText := '';

  LStream := TPasLexer.Tokenize(AText);
  if (ACaretLine < 0) or (ACaretLine > High(LStream.LineStarts)) then
    Exit;
  LCaretStart := LStream.LineStarts[ACaretLine];
  if ACaretLine < High(LStream.LineStarts) then
    LCaretEnd := LStream.LineStarts[ACaretLine + 1]
  else
    LCaretEnd := Length(AText);

  // The gesture is "opener, Enter, empty line under the caret". A line that
  // carries text (an Enter that SPLIT a line) gets nothing: inserting a
  // closer between the halves would be an edit the user did not ask for.
  for LOfs := LCaretStart to LCaretEnd - 1 do
    if not CharInSet(AText[LOfs + 1], [' ', #9, #13, #10]) then
      Exit;

  LTokens := LStream.Tokens;
  SetLength(LVisible, Length(LTokens));
  LCount := 0;
  for LIdx := 0 to High(LTokens) do
    if not IsTrivia(LTokens[LIdx].Kind) then
    begin
      LVisible[LCount] := LIdx;
      Inc(LCount);
    end;

  LStack := nil;
  LStackCount := 0;
  LPrevKind := tkEndOfFile;
  LLastLineAbove := -1;
  LCandidateKind := tkEndOfFile;
  LCandidateLine := -1;

  for LIdx := 0 to LCount - 1 do
  begin
    LTok := LTokens[LVisible[LIdx]];
    if LTok.Start < LCaretStart then
      LLastLineAbove := LineOf(LTok.Start);

    LPushIt := False;
    case LTok.Kind of
      tkUnit, tkProgram, tkLibrary:
        // The module head opens the block the final `end.` closes - without
        // this every complete unit would look one closer short the moment a
        // routine's `end;` count matched, because `end.` would eat a stack
        // entry that belonged to a routine. First token only: `unit` and
        // friends are reserved words, but only the head position opens
        // anything.
        LPushIt := LIdx = 0;
      tkBegin, tkTry, tkRepeat, tkAsm:
        LPushIt := True;
      tkCase:
        // A `case` directly inside a record/object/class body is a variant
        // part - it shares the record's own `end` and must not count.
        LPushIt := not (Top in [tkRecord, tkObject, tkClass]);
      tkRecord:
        // Plain body or `record helper` - both end with `end`.
        LPushIt := True;
      tkObject:
        // `of object` is a procedure-type suffix, not a body.
        LPushIt := LPrevKind <> tkOf;
      tkClass:
        begin
          // A body opens unless this is `class of`, a forward declaration
          // (`= class;`) or a member prefix (`class function` ... `class
          // operator` - the last spelled as an identifier, `operator` not
          // being a reserved word).
          LNextKind := VisKind(LIdx + 1);
          LPushIt := not (LNextKind in [tkOf, tkSemicolon, tkFunction,
            tkProcedure, tkConstructor, tkDestructor, tkProperty, tkVar,
            tkThreadvar, tkConst]);
          if LPushIt and (LNextKind = tkIdentifier) and
             LStream.TokenTextEquals(LTokens[LVisible[LIdx + 1]],
               'operator') then
            LPushIt := False;
        end;
      tkInterface, tkDispinterface:
        // The TYPE, not the unit section: only after `=`, and not a forward
        // declaration (`IFoo = interface;`).
        LPushIt := (LPrevKind = tkEqual) and
          (VisKind(LIdx + 1) <> tkSemicolon);
      tkEnd:
        if LStackCount > 0 then
          Dec(LStackCount);
      tkUntil:
        if Top = tkRepeat then
          Dec(LStackCount);
    end;

    if LPushIt then
    begin
      Push(LTok.Kind);
      // The last opener typed above the caret is the one the Enter was
      // pressed after - remember its kind (for until-vs-end) and its line
      // (for the trigger condition and the indentation). Not the module
      // head: `unit X;` + Enter must never grow an `end.` - the head is
      // balance bookkeeping, not a gesture.
      if (LTok.Start < LCaretStart) and
         not (LTok.Kind in [tkUnit, tkProgram, tkLibrary]) then
      begin
        LCandidateKind := LTok.Kind;
        LCandidateLine := LineOf(LTok.Start);
      end;
    end;

    LPrevKind := LTok.Kind;
  end;

  // Both conditions from the unit header: the file misses at least one
  // closer, and the last code line above the caret opened a block.
  if (LStackCount = 0) or (LCandidateLine < 0) or
     (LCandidateLine <> LLastLineAbove) then
    Exit;

  // The opener line's own leading whitespace, verbatim - tabs stay tabs.
  LIndent := '';
  LOfs := LStream.LineStarts[LCandidateLine];
  while (LOfs < Length(AText)) and CharInSet(AText[LOfs + 1], [' ', #9]) do
  begin
    LIndent := LIndent + AText[LOfs + 1];
    Inc(LOfs);
  end;

  if LCandidateKind = tkRepeat then
    LCloser := 'until ;'
  else if LCandidateKind = tkTry then
    // The whole skeleton, not just the end: a bare try is never what the
    // user is after, and the caret is already sitting on the line where
    // the protected code goes (user, 2026-08-31 - first live run asked
    // for exactly this).
    LCloser := 'finally'#13#10 + LIndent + 'end;'
  else
    // ALWAYS `end;` - never `end.`. There was a special case here ("a begin
    // sitting directly over the module head on the final stack must be the
    // main block") and the first live run disproved it the obvious-in-
    // hindsight way: a begin typed into an ordinary unit steals a later
    // closer, the file's own `end.` pops somebody else's begin, and the
    // stack bottom pairs the NEW begin with the module head - `end.` landed
    // in the middle of a unit (user, 2026-08-31). Which begin is the main
    // one is exactly the question the cascade makes unanswerable, and the
    // main begin of a program is typed once per project - the wrong `;` is
    // one keystroke there, the wrong `.` was every day.
    LCloser := 'end;';

  AInsertLine := ACaretLine;
  // End of the caret line, before its break: its full width is whitespace
  // (checked above), CR/LF excluded.
  AInsertChar := 0;
  LOfs := LCaretStart;
  while (LOfs < LCaretEnd) and not CharInSet(AText[LOfs + 1], [#13, #10]) do
  begin
    Inc(AInsertChar);
    Inc(LOfs);
  end;
  ANewText := #13#10 + LIndent + LCloser;
  Result := True;
end;

end.
