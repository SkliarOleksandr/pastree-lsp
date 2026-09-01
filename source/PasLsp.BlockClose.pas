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
  that special case).

  TWO EDITS, and the CARET LINE IS ONE OF THEM: the answer re-indents the
  caret's line to the body indent first and appends the closer second (see
  BuildEdits, and the interface comment on the order). The caret then ends up
  at the body indent rather than wherever Enter happened to leave it, which is
  the point of that edit - but it does mean the answer is only safe to apply to
  the buffer it was computed from, which is what the clients' staleness gates
  are for. The final paragraph here used to claim the opposite; it predated the
  caret re-indent.
}

interface

type
  /// <summary>
  /// One single-line edit of the plan: replace [StartChar..EndChar) on Line
  /// (0-based, UTF-16) with Text. StartChar = EndChar is a pure insertion.
  /// </summary>
  TBlockCloseEdit = record
    Line: Integer;
    StartChar: Integer;
    EndChar: Integer;
    Text: string;
  end;

/// <summary>
/// Decides the block-completion edits for a caret that just arrived on
/// ACaretLine (0-based, LSP convention) by pressing Enter. True with up to
/// two edits: the caret line's whitespace replaced by the BODY indentation
/// (the opener's plus one level of ATabSize/AInsertSpaces - and the caret,
/// sitting at the end of that whitespace, rides the replacement to the end
/// of the new indent in any client that anchors it after the replaced
/// span, which is how the cursor lands inside the block without any cursor
/// protocol), and the closer inserted at the end of the caret line. False
/// when nothing should be inserted - the common case, never an error.
/// </summary>
function PlanBlockClose(const AText: string; ACaretLine: Integer;
  ATabSize: Integer; AInsertSpaces: Boolean;
  out AEdits: TArray<TBlockCloseEdit>): Boolean;

implementation

uses
  System.SysUtils,
  PasTree.Types, PasTree.Lexer;

function PlanBlockClose(const AText: string; ACaretLine: Integer;
  ATabSize: Integer; AInsertSpaces: Boolean;
  out AEdits: TArray<TBlockCloseEdit>): Boolean;
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

  { `= class(TParent);` - AN ANCESTOR AND NO BODY, which is a declaration, not
    an opener. AVisIdx is the `class`/`interface` token.

    This was the one shape the rules above missed, and missing it is not a
    corner case: `EMyError = class(Exception);` is how most Delphi units
    declare an exception, and the hack-class idiom
    (`THackPanel = class(TPanel);`) is another. Each one pushed an opener that
    nothing ever popped, so a unit was PERMANENTLY unbalanced by however many
    it had - and the whole-file condition that is supposed to mean "the file is
    missing a closer because you just typed an opener" was then true for the
    rest of the session.

    What that costs is invisible until it is explained: the cascade guard stops
    guarding, so Enter on ANY blank line under an opener inserts a closer -
    including the blank line inside a block that was just completed, which is
    how one Enter appeared to insert two `end;` (user, 2026-09-01, AVIMain.pas
    - three such declarations at lines 98-100 of a 22 000-line unit was the
    whole story).

    Skips one balanced parenthesis group, so a multi-token ancestor list
    (`class(TFoo, IBar)`) is handled, and then asks for `;`. Anything else
    after the parens - members, a GUID literal on an interface, `end` - means a
    body. }
  function AncestorOnly(AVisIdx: Integer): Boolean;
  var
    LAt, LDepth: Integer;
  begin
    Result := False;
    LAt := AVisIdx + 1;
    if VisKind(LAt) <> tkLParen then
      Exit;
    LDepth := 0;
    while LAt < LCount do
    begin
      case VisKind(LAt) of
        tkLParen: Inc(LDepth);
        tkRParen:
          begin
            Dec(LDepth);
            if LDepth = 0 then
              Exit(VisKind(LAt + 1) = tkSemicolon);
          end;
      end;
      Inc(LAt);
    end;
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
  LModuleKind: TPasTokenKind;
  LIndent, LBodyIndent, LCloser: string;
  LLineEndChar: Integer;
  LEdit: TBlockCloseEdit;
begin
  Result := False;
  AEdits := nil;

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
  // What kind of module this is decides what the final `end.` closes -
  // see the tkEnd branch. An include file has no head and behaves like a
  // unit there (its `end.`, if any, closes nothing of ours).
  LModuleKind := tkEndOfFile;
  if LCount > 0 then
    case VisKind(0) of
      tkProgram: LModuleKind := tkProgram;
      tkLibrary: LModuleKind := tkLibrary;
      tkUnit: LModuleKind := tkUnit;
    end;

  for LIdx := 0 to LCount - 1 do
  begin
    LTok := LTokens[LVisible[LIdx]];
    if LTok.Start < LCaretStart then
      LLastLineAbove := LineOf(LTok.Start);

    LPushIt := False;
    case LTok.Kind of
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
          // A body opens unless this is `class of`, a bodyless declaration
          // (`= class;` and `= class(TParent);` - see AncestorOnly) or a
          // member prefix (`class function` ... `class operator` - the last
          // spelled as an identifier, `operator` not being a reserved word).
          LNextKind := VisKind(LIdx + 1);
          LPushIt := not (LNextKind in [tkOf, tkSemicolon, tkFunction,
            tkProcedure, tkConstructor, tkDestructor, tkProperty, tkVar,
            tkThreadvar, tkConst]);
          if LPushIt and (LNextKind = tkIdentifier) and
             LStream.TokenTextEquals(LTokens[LVisible[LIdx + 1]],
               'operator') then
            LPushIt := False;
          if LPushIt and AncestorOnly(LIdx) then
            LPushIt := False;
        end;
      tkInterface, tkDispinterface:
        // The TYPE, not the unit section: only after `=`, and not a bodyless
        // declaration - `IFoo = interface;` or `IFoo = interface(IBar);`.
        LPushIt := (LPrevKind = tkEqual) and
          (VisKind(LIdx + 1) <> tkSemicolon) and not AncestorOnly(LIdx);
      tkEnd:
        // `end` followed by `.` is the MODULE terminator and closes no
        // ordinary block - with one carve-out: in a program/library the
        // main `begin...end.` is one block, so there (and only there) it
        // pops an open begin. In a unit it pops nothing: the unit's own
        // `end.` stands alone, and even an old-style initialization
        // `begin` shares it rather than owning one. Getting this wrong in
        // either direction is not cosmetic - counting `end.` as a normal
        // closer made every COMPLETE program look one closer short (the
        // head never popped), and Enter after any opener in a balanced
        // .dpr grew a second `finally/end;` next to a correct one
        // (user, 2026-08-31, XmlDocDemo.dpr).
        if (LIdx + 1 < LCount) and (VisKind(LIdx + 1) = tkDot) then
        begin
          if (LModuleKind in [tkProgram, tkLibrary]) and (Top = tkBegin) then
            Dec(LStackCount);
        end
        else if LStackCount > 0 then
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
      // (for the trigger condition and the indentation).
      if LTok.Start < LCaretStart then
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

  // End of the caret line, before its break: its full width is whitespace
  // (checked above), CR/LF excluded.
  LLineEndChar := 0;
  LOfs := LCaretStart;
  while (LOfs < LCaretEnd) and not CharInSet(AText[LOfs + 1], [#13, #10]) do
  begin
    Inc(LLineEndChar);
    Inc(LOfs);
  end;

  // Edit 1: the caret line's whitespace becomes the body indentation - the
  // opener's own indent plus one level, in the client's declared units.
  // The caret sits at the end of that whitespace (RAD's virtual caret
  // leaves the line empty and is repositioned by the plugin explicitly),
  // so a client that anchors it after the replaced span lands it at the
  // end of the new indent: inside the block, correctly indented.
  if ATabSize < 1 then
    ATabSize := 2;   // the Delphi convention, and a shield against 0
  if AInsertSpaces then
    LBodyIndent := LIndent + StringOfChar(' ', ATabSize)
  else
    LBodyIndent := LIndent + #9;
  if LBodyIndent <> Copy(AText, LCaretStart + 1, LLineEndChar) then
  begin
    LEdit.Line := ACaretLine;
    LEdit.StartChar := 0;
    LEdit.EndChar := LLineEndChar;
    LEdit.Text := LBodyIndent;
    AEdits := AEdits + [LEdit];
  end;

  // Edit 2: the closer, on its own line(s) after the caret line.
  LEdit.Line := ACaretLine;
  LEdit.StartChar := LLineEndChar;
  LEdit.EndChar := LLineEndChar;
  LEdit.Text := #13#10 + LIndent + LCloser;
  AEdits := AEdits + [LEdit];
  Result := True;
end;

end.
