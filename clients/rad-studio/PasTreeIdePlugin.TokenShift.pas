unit PasTreeIdePlugin.TokenShift;

{
  WHERE A TYPE NAME STANDS NOW - the last semantic tokens answer carried
  onto the text the editor holds while the next answer is on its way.

  An answer describes the text the server was given when it was asked (the
  BASE); typing moves the text under it, and for the ~0.5 s until the next
  answer lands the colour stayed at the old columns: a character typed in
  front of a type name slid the name right and the colour stayed behind,
  painting half of it and a piece of whatever came before (Alex, 2026-09-25,
  first run of 0.54.3). Clearing the tokens on each edit is not the answer -
  every type name in the file would flicker per keystroke (the SemanticPaint
  header).

  So each painted line is matched to its base line: unchanged in place (the
  common case, painted as it is), unchanged but moved (lines were inserted or
  deleted above - the row offset of the last match in the paint pass is tried
  first, then the rows around), or edited - then the common prefix and suffix
  of the two versions carry every token outside the edit to its new column.
  A token is painted only where the SAME identifier now stands as a whole
  word; anything the edit touched waits for the server. A wrong guess about
  which base line a line came from can therefore colour nothing but an
  identifier that is spelled exactly like the one the token was for.

  Pure string work - no ToolsAPI - so LspTextSmoke holds it to cases.
}

interface

type
  /// <summary>
  /// How one line of the editor's text relates to the tokens' base text.
  /// </summary>
  TLineShift = record
    /// <summary>1-based row of the base line, 0 = none: paint nothing.</summary>
    BaseRow: Integer;
    /// <summary>The line is its base line unchanged: every token applies as
    /// it is.</summary>
    Same: Boolean;
    /// <summary>Edited: the characters both versions share at the start and
    /// at the end, and how much longer the line is now.</summary>
    Prefix, Suffix, Delta: Integer;
    BaseLine: string;
  end;

/// <summary>
/// Where row ARow (1-based) of the editor, holding ACurrent, came from in
/// ABase (the tokens' text, one string per line). AHintOffset is the paint
/// pass's state: the row offset of the last line matched, tried first and
/// updated on a match. Start a pass with 0.
/// </summary>
function ShiftForLine(const ABase: TArray<string>; ARow: Integer;
  const ACurrent: string; var AHintOffset: Integer): TLineShift;

/// <summary>
/// The token [AFrom, ATo) - 1-based columns of the base line, ATo exclusive
/// - on the current line. False when it no longer stands there as the same
/// whole identifier.
/// </summary>
function ShiftToken(const AShift: TLineShift; const ACurrent: string;
  AFrom, ATo: Integer; out ANewFrom, ANewTo: Integer): Boolean;

/// <summary>
/// AText split into lines, a CR before each LF dropped - the shape ABase
/// takes.
/// </summary>
function SplitBaseLines(const AText: string): TArray<string>;

implementation

uses
  System.SysUtils,
  System.Character;

const
  // How far a line may have moved and still be found by its text. A paste
  // or a deletion bigger than this leaves the lines below it uncoloured
  // until the answer - no worse than an edited line.
  cSearchRows = 200;

function IsIdentChar(C: Char): Boolean;
begin
  Result := C.IsLetterOrDigit or (C = '_');
end;

function SplitBaseLines(const AText: string): TArray<string>;
var
  LIdx: Integer;
begin
  Result := AText.Split([#10]);
  for LIdx := 0 to High(Result) do
    if Result[LIdx].EndsWith(#13) then
      Result[LIdx] := Copy(Result[LIdx], 1, Length(Result[LIdx]) - 1);
end;

function ShiftForLine(const ABase: TArray<string>; ARow: Integer;
  const ACurrent: string; var AHintOffset: Integer): TLineShift;
var
  LK, LIdx, LBaseLen, LCurLen, LMin, LFound: Integer;

  function Matches(AOffset: Integer): Boolean;
  var
    LB: Integer;
  begin
    LB := ARow - 1 + AOffset;
    Result := (LB >= 0) and (LB <= High(ABase)) and (ABase[LB] = ACurrent);
  end;

begin
  Result := Default(TLineShift);
  if ARow < 1 then
    Exit;
  // A blank line carries no token, and it matches every other blank line:
  // it must not move the pass's offset either.
  if Trim(ACurrent) = '' then
    Exit;
  // The line unchanged: at the pass's offset (below an inserted line, where
  // the rest of the pass stands too), in place, or among the rows around.
  LFound := MaxInt;
  if Matches(AHintOffset) then
    LFound := AHintOffset
  else if Matches(0) then
    LFound := 0
  else
    for LK := 1 to cSearchRows do
      if Matches(-LK) then
      begin
        LFound := -LK;
        Break;
      end
      else if Matches(LK) then
      begin
        LFound := LK;
        Break;
      end;
  if LFound <> MaxInt then
  begin
    AHintOffset := LFound;
    Result.BaseRow := ARow + LFound;
    Result.Same := True;
    Exit;
  end;
  // Edited: the base line the pass's offset points at.
  LIdx := ARow - 1 + AHintOffset;
  if (LIdx < 0) or (LIdx > High(ABase)) then
    Exit;
  Result.BaseRow := LIdx + 1;
  Result.BaseLine := ABase[LIdx];
  LBaseLen := Length(Result.BaseLine);
  LCurLen := Length(ACurrent);
  LMin := LBaseLen;
  if LCurLen < LMin then
    LMin := LCurLen;
  while (Result.Prefix < LMin) and
        (Result.BaseLine[Result.Prefix + 1] = ACurrent[Result.Prefix + 1]) do
    Inc(Result.Prefix);
  // The suffix may not reach into the prefix: in `aa` -> `aaa` the edit is
  // one insertion, not two overlapping matches.
  while (Result.Suffix < LMin - Result.Prefix) and
        (Result.BaseLine[LBaseLen - Result.Suffix] =
         ACurrent[LCurLen - Result.Suffix]) do
    Inc(Result.Suffix);
  Result.Delta := LCurLen - LBaseLen;
end;

function ShiftToken(const AShift: TLineShift; const ACurrent: string;
  AFrom, ATo: Integer; out ANewFrom, ANewTo: Integer): Boolean;
var
  LLen: Integer;
begin
  ANewFrom := AFrom;
  ANewTo := ATo;
  Result := False;
  if AShift.BaseRow = 0 then
    Exit;
  if AShift.Same then
    Exit(True);
  LLen := ATo - AFrom;
  if (LLen <= 0) or (AFrom < 1) or (ATo - 1 > Length(AShift.BaseLine)) then
    Exit;
  // In 0-based offsets the token is [AFrom - 1, ATo - 1), the edit replaced
  // [Prefix, Length - Suffix) of the base line.
  if ATo - 1 <= AShift.Prefix then
    // before the edit: where it was
  else if AFrom - 1 >= Length(AShift.BaseLine) - AShift.Suffix then
  begin
    // after it: moved by the difference
    ANewFrom := AFrom + AShift.Delta;
    ANewTo := ATo + AShift.Delta;
  end
  else
    Exit;   // the edit went through it
  // The same identifier, as a whole word: a character typed right against
  // it made a different name.
  Result := (ANewFrom >= 1) and (ANewTo - 1 <= Length(ACurrent)) and
    (Copy(ACurrent, ANewFrom, LLen) = Copy(AShift.BaseLine, AFrom, LLen)) and
    ((ANewFrom = 1) or not IsIdentChar(ACurrent[ANewFrom - 1])) and
    ((ANewTo > Length(ACurrent)) or not IsIdentChar(ACurrent[ANewTo]));
end;

end.
