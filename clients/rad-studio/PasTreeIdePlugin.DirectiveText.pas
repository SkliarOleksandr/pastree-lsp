unit PasTreeIdePlugin.DirectiveText;

{
  Which identifier in a line of source is a NAME INSIDE A DIRECTIVE - the pure
  string test behind the Ctrl+Click override's PointOnDirectiveName
  (PasTreeIdePlugin.GotoDeclaration), kept apart because it links nothing, so
  LspTextSmoke can hold it to cases. Recognized: $IFDEF X, $IFNDEF X,
  $DEFINE X, $UNDEF X (the one symbol after the keyword) and every name of a
  $IF / $ELSEIF expression - a Defined(X) argument, a constant like
  CompilerVersion, a Declared(X) argument - in brace and (*$...*) spelling
  alike. (Directives are spelled without braces in these comments: a brace
  would end the comment.) One line at a time - a directive continued on the
  next line is not seen.
}

interface

/// <summary>
/// Locates a conditional symbol at 1-based column ACol of ALine. On success
/// AFrom/ATo bracket the identifier, ATo exclusive.
/// </summary>
function DirectiveNameAt(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;

/// <summary>
/// The identifier run covering 1-based ACol of S - letters, digits and
/// underscores, not digit-led - AFrom/ATo bracketing it, ATo exclusive. Purely
/// lexical: a keyword or a word in a comment is a run too. The hover hint
/// uses it to ask the server only where an answer can come from.
/// </summary>
function IdentRunAt(const S: string; ACol: Integer;
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

function DirectiveNameAt(const ALine: string; ACol: Integer;
  out AFrom, ATo: Integer): Boolean;
var
  LBodyFrom, LBodyTo, LAfter, LArg, LNext: Integer;
  LKeyword, LWord: string;
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
    // Any NAME of the expression: a Defined(X) argument, a constant
    // (CompilerVersion), a Declared(X) or SizeOf(T) argument - the server
    // answers each (PasTree's DefineAt and IfNameAt). Not an operator word,
    // and not a callee (Defined, Declared, SizeOf - a word followed by `(`).
    if not IdentRunAt(ALine, ACol, AFrom, ATo) then
      Exit;
    if (AFrom <= LAfter) or (ATo > LBodyTo) then
      Exit;
    LWord := UpperCase(Copy(ALine, AFrom, ATo - AFrom));
    if (LWord = 'AND') or (LWord = 'OR') or (LWord = 'NOT') or
       (LWord = 'XOR') or (LWord = 'DIV') or (LWord = 'MOD') or
       (LWord = 'SHL') or (LWord = 'SHR') or (LWord = 'IN') then
      Exit;
    LNext := SkipBlanks(ALine, ATo, LBodyTo);
    Result := (LNext >= LBodyTo) or (ALine[LNext] <> '(');
  end;
end;

end.
