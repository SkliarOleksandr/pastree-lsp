unit PasTreeIdePlugin.DirectiveText;

{
  Which identifier in a line of source is a CONDITIONAL SYMBOL - the pure
  string test behind the Ctrl+Click override's PointOnDefine (PasTreeIdePlugin.
  GotoDeclaration), kept apart because it links nothing, so LspTextSmoke can
  hold it to cases. Recognized: $IFDEF X, $IFNDEF X, $DEFINE X, $UNDEF X
  (the one symbol after the keyword) and X inside Defined(X) in $IF and
  $ELSEIF, in brace and (*$...*) spelling alike. (Directives are spelled
  without braces in these comments: a brace would end the comment.)
  One line at a time - a directive continued on the next line is not seen.
}

interface

/// <summary>
/// Locates a conditional symbol at 1-based column ACol of ALine. On success
/// AFrom/ATo bracket the identifier, ATo exclusive.
/// </summary>
function DirectiveSymbolAt(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;

implementation

uses
  System.SysUtils,
  System.Character;

function IsIdentStart(C: Char): Boolean;
begin
  Result := C.IsLetter or (C = '_');
end;

function IsIdentChar(C: Char): Boolean;
begin
  Result := C.IsLetterOrDigit or (C = '_');
end;

{ The identifier run covering 1-based ACol in S, or False if ACol is not on
  one. A digit-led run is not an identifier. }
function IdentRunAt(const S: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;
begin
  Result := False;
  if (ACol < 1) or (ACol > Length(S)) or not IsIdentChar(S[ACol]) then
    Exit;
  AFrom := ACol;
  while (AFrom > 1) and IsIdentChar(S[AFrom - 1]) do
    Dec(AFrom);
  if not IsIdentStart(S[AFrom]) then
    Exit;
  ATo := ACol + 1;
  while (ATo <= Length(S)) and IsIdentChar(S[ATo]) do
    Inc(ATo);
  Result := True;
end;

{ The directive - brace-dollar or (*$...*) - whose body contains 1-based ACol.
  ABodyFrom is the index of the first character after `$`, ABodyTo the
  index of the closing brace (or the * of *)), exclusive. }
function DirectiveAround(const S: string; ACol: Integer;
  out ABodyFrom, ABodyTo: Integer): Boolean;
var
  I, LClose: Integer;
  LParen: Boolean;
begin
  Result := False;
  I := 1;
  while I < Length(S) do
  begin
    LParen := False;
    if (S[I] = '{') and (S[I + 1] = '$') then
      ABodyFrom := I + 2
    else if (S[I] = '(') and (I + 2 <= Length(S)) and (S[I + 1] = '*')
      and (S[I + 2] = '$') then
    begin
      ABodyFrom := I + 3;
      LParen := True;
    end
    else
    begin
      Inc(I);
      Continue;
    end;
    if LParen then
      LClose := Pos('*)', S, ABodyFrom)
    else
      LClose := Pos('}', S, ABodyFrom);
    if LClose = 0 then
      Exit;   // unterminated on this line: nothing further can match
    ABodyTo := LClose;
    if (ACol >= ABodyFrom) and (ACol < ABodyTo) then
      Exit(True);
    I := LClose + 1;
  end;
end;

{ The word starting at AFrom (an identifier run), upper-cased; AAfter is the
  index just past it. }
function WordAt(const S: string; AFrom: Integer; out AAfter: Integer): string;
begin
  AAfter := AFrom;
  while (AAfter <= Length(S)) and IsIdentChar(S[AAfter]) do
    Inc(AAfter);
  Result := UpperCase(Copy(S, AFrom, AAfter - AFrom));
end;

function SkipBlanks(const S: string; AFrom, ALimit: Integer): Integer;
begin
  Result := AFrom;
  while (Result < ALimit) and (S[Result] <= ' ') do
    Inc(Result);
end;

function DirectiveSymbolAt(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;
var
  LBodyFrom, LBodyTo, LAfter, LArg, LBefore, LWordFrom: Integer;
  LKeyword: string;
begin
  Result := False;
  if not DirectiveAround(ALine, ACol, LBodyFrom, LBodyTo) then
    Exit;
  LKeyword := WordAt(ALine, LBodyFrom, LAfter);
  if (LKeyword = 'IFDEF') or (LKeyword = 'IFNDEF') or (LKeyword = 'DEFINE')
    or (LKeyword = 'UNDEF') then
  begin
    // Exactly one symbol, the first identifier after the keyword; the hover
    // must be on it, not on the keyword or the braces.
    LArg := SkipBlanks(ALine, LAfter, LBodyTo);
    if (LArg >= LBodyTo) or not IsIdentStart(ALine[LArg]) then
      Exit;
    if not IdentRunAt(ALine, LArg, AFrom, ATo) then
      Exit;
    Result := (ACol >= AFrom) and (ACol < ATo) and (ATo <= LBodyTo);
    Exit;
  end;
  if (LKeyword = 'IF') or (LKeyword = 'ELSEIF') then
  begin
    // Any identifier at the hover that is the argument of Defined(...):
    // the token before it is `(`, and the word before that is DEFINED.
    // Declared(...), SizeOf and plain constants in the expression are not
    // conditional symbols and stay dark.
    if not IdentRunAt(ALine, ACol, AFrom, ATo) then
      Exit;
    if (AFrom <= LAfter) or (ATo > LBodyTo) then
      Exit;
    LBefore := AFrom - 1;
    while (LBefore >= LAfter) and (ALine[LBefore] <= ' ') do
      Dec(LBefore);
    if (LBefore < LAfter) or (ALine[LBefore] <> '(') then
      Exit;
    Dec(LBefore);
    while (LBefore >= LAfter) and (ALine[LBefore] <= ' ') do
      Dec(LBefore);
    if LBefore < LAfter then
      Exit;
    LWordFrom := LBefore;
    while (LWordFrom > LAfter) and IsIdentChar(ALine[LWordFrom - 1]) do
      Dec(LWordFrom);
    Result := UpperCase(Copy(ALine, LWordFrom, LBefore - LWordFrom + 1))
      = 'DEFINED';
  end;
end;

end.
