program LspTextSmoke;

{
  The server's TEXT units, tested without a server: PasLsp.Protocol's URI and
  position conversions and PasLsp.XmlDoc's doc-comment rendering.

  WHY A HARNESS OF ITS OWN. Both units are pure functions over strings, and
  neither one had any coverage at all - which is how a doc comment that spells
  `<` correctly ended up wrong in BOTH hint windows, and how a sentence
  containing `0 < Count and Count > Max` silently lost five of its words. A
  bug in this layer reaches a user as "the hint shows the wrong text", with no
  log line and nothing to reproduce from, so it belongs here where a wrong
  string is a failed check.

  Win32 like every harness in this directory, and that costs nothing: these two
  units link the RTL and nothing else. (PasLsp.XmlDoc is compiled into the
  Win64 server; the code under test is the same code either way.)

  Usage: LspTextSmoke.exe   (no arguments; exits non-zero on failure)
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasLsp.Protocol,
  PasLsp.XmlDoc,
  PasTreeIdePlugin.DirectiveText,
  PasTreeIdePlugin.TokenShift;

var
  GFailures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln('  [ok]   ', AName)
  else
  begin
    Writeln('  [FAIL] ', AName);
    Inc(GFailures);
  end;
end;

procedure CheckEq(const AGot, AWant, AName: string);
begin
  if AGot = AWant then
    Writeln('  [ok]   ', AName)
  else
  begin
    Writeln('  [FAIL] ', AName);
    Writeln('           want: ', AWant);
    Writeln('           got:  ', AGot);
    Inc(GFailures);
  end;
end;

procedure TestUri;
const
  // U+1F600, as a surrogate pair - one character, two UTF-16 code units.
  cEmoji = #$D83D#$DE00;
var
  LPath: string;
begin
  Writeln('URIs');

  // The case of the drive letter is passed through, not normalised - PathToUri
  // is the end that lower-cases it (VS Code's canonical form).
  CheckEq(UriToPath('file:///c%3A/dir/file.pas'), 'c:\dir\file.pas',
    'a percent-encoded drive letter decodes and the slashes turn round');
  CheckEq(UriToPath('file:///c:/dir/file.pas'), 'c:\dir\file.pas',
    'an unencoded colon is accepted too');
  CheckEq(UriToPath('http://example.com/x.pas'), '',
    'a non-file URI is refused rather than guessed at');
  CheckEq(UriToPath('file://server/share/x.pas'), '\\server\share\x.pas',
    'a UNC authority becomes a UNC path');

  // The round trip a client actually exercises: our own PathToUri output must
  // come back as the path we started from, or a definition answer names a
  // document the editor does not recognise.
  LPath := 'C:\Repos\проект\DemoUnit.pas';
  CheckEq(UriToPath(PathToUri(LPath)), LowerCase(LPath[1]) + Copy(LPath, 2,
    MaxInt),
    'a Cyrillic path round-trips through PathToUri (drive letter lowercased)');
  LPath := 'C:\Repos\x' + cEmoji + '\DemoUnit.pas';
  CheckEq(UriToPath(PathToUri(LPath)), LowerCase(LPath[1]) + Copy(LPath, 2,
    MaxInt),
    'and so does a path with a non-BMP character');

  { THE UNESCAPED CASE, which is the one that was broken: the spec tolerates
    raw non-ASCII in a URI and some clients send it, and the decoder walked the
    string one UTF-16 code unit at a time - so each half of a surrogate pair
    was encoded on its own, which is invalid UTF-16, and the RTL turned it into
    U+FFFD bytes. The path then matched no file, silently. }
  CheckEq(UriToPath('file:///c:/x' + cEmoji + '/a.pas'),
    'c:\x' + cEmoji + '\a.pas',
    'an unescaped non-BMP character survives the decode intact');
end;

procedure TestXmlDocEntities;
var
  LParts: TXmlDocParts;
begin
  Writeln;
  Writeln('XMLDoc: entities');

  { `&lt;` is the ONLY correct way to write a literal '<' in a doc comment, so
    every properly written comment containing one goes through here. The parser
    unescapes section text, which is what makes the plain emitter show the
    character and the HTML emitter escape it exactly once. Before that, the
    plain window showed `A &lt; B` verbatim and the HTML one double-escaped to
    `A &amp;lt; B`, which Help Insight rendered as the literal `A &lt; B`:
    wrong in both directions, for the same input. }
  LParts := ParseXmlDoc('<summary>A &lt; B &amp; C</summary>');
  CheckEq(LParts.Summary, 'A < B & C',
    'the parser unescapes entities into real characters');
  CheckEq(XmlDocDisplayText('<summary>A &lt; B &amp; C</summary>'),
    'A < B & C',
    'the plain emitter shows the characters, not the entities');
  Check(XmlDocHtml('<summary>A &lt; B &amp; C</summary>').Contains('A &lt; B')
    and not XmlDocHtml('<summary>A &lt; B</summary>').Contains('&amp;lt;'),
    'the HTML emitter escapes them exactly once');

  CheckEq(ParseXmlDoc('<summary>&#65;&quot;&apos;</summary>').Summary,
    'A"''', 'numeric and quote entities decode too');
  CheckEq(ParseXmlDoc('<summary>a &nosuch; b</summary>').Summary,
    'a &nosuch; b',
    'an unknown entity is left alone rather than eaten');
end;

procedure TestXmlDocProse;
var
  LParts: TXmlDocParts;
begin
  Writeln;
  Writeln('XMLDoc: a raw ''<'' in prose');

  { The unit header promises that a parse error never costs the user the text.
    A raw '<' with any later '>' in the block used to be treated as a tag, and
    everything between them was dropped as an unknown tag's body - so this
    entirely ordinary sentence lost five words and read "True when 0 Max". }
  LParts := ParseXmlDoc(
    '<summary>True when 0 < Count and Count > Max</summary>');
  CheckEq(LParts.Summary, 'True when 0 < Count and Count > Max',
    'a comparison in prose keeps every word');
  CheckEq(ParseXmlDoc('<summary>a < b</summary>').Summary, 'a < b',
    'an unterminated ''<'' is prose (it always was)');
  // A CAPITALISED unknown name is prose, which is what makes a generic in
  // running text survive: Delphi types are capitalised, XMLDoc tags are not.
  CheckEq(ParseXmlDoc('<summary>List<Integer> of things</summary>').Summary,
    'List<Integer> of things',
    'a generic in running text is prose, not a tag called Integer');
  CheckEq(ParseXmlDoc('<summary>a <TFoo> here</summary>').Summary,
    'a <TFoo> here', 'and so is a bare type name in angle brackets');

  // And the liberal side of the deal still holds: real tags, known or not, are
  // still tags, and an unknown one still contributes its content.
  CheckEq(ParseXmlDoc('<summary>a <b>bold</b> c</summary>').Summary,
    'a bold c', 'a known inline tag is still a tag');
  CheckEq(ParseXmlDoc('<summary>a <weird>x</weird> c</summary>').Summary,
    'a x c', 'an unknown BARE tag is still a tag, and its content is kept');
  CheckEq(ParseXmlDoc('<summary>a <weird n="1">x</weird> c</summary>').Summary,
    'a x c', 'so is an unknown tag with an attribute');

  LParts := ParseXmlDoc('<param name="AIndex">0 < AIndex</param>');
  Check((Length(LParts.Params) = 1) and (LParts.Params[0].Name = 'AIndex') and
    (LParts.Params[0].Text = '0 < AIndex'),
    'and the sections themselves still parse around it');
end;

procedure TestPositions;
var
  LLine, LChar, LPasLine, LPasCol: Integer;
begin
  Writeln;
  Writeln('positions');

  LspToPasTree(0, 0, LPasLine, LPasCol);
  Check((LPasLine = 1) and (LPasCol = 1),
    'LSP (0,0) is PasTree (1,1)');
  PasTreeToLsp(1, 1, LLine, LChar);
  Check((LLine = 0) and (LChar = 0), 'and back again');
end;


{ The conditional-symbol locator behind the plugin's Ctrl+hover underline
  (PasTreeIdePlugin.DirectiveText). Covered here because its only other
  observer is a mouse over an IDE editor. }
procedure TestDirectiveSymbol;

  procedure CheckHit(const ALine: string; ACol: Integer;
    const AWant: string; const AName: string);
  var
    LFrom, LTo: Integer;
    LGot: string;
  begin
    if DirectiveSymbolAt(ALine, ACol, LFrom, LTo) then
      LGot := Copy(ALine, LFrom, LTo - LFrom)
    else
      LGot := '';
    CheckEq(LGot, AWant, AName);
  end;

const
  cIfDef = '  {$IFDEF DEBUG_FOO} // x';
  cIf = '{$IF Defined(MSWINDOWS) and not Declared(TFoo) and Defined( X_1 )}';
begin
  Writeln;
  Writeln('directive symbols');

  CheckHit(cIfDef, 11, 'DEBUG_FOO', '{$IFDEF X}: first char of the symbol');
  CheckHit(cIfDef, 19, 'DEBUG_FOO', '{$IFDEF X}: last char of the symbol');
  CheckHit(cIfDef, 20, '', '{$IFDEF X}: the closing brace is not the symbol');
  CheckHit(cIfDef, 6, '', '{$IFDEF X}: the keyword is not the symbol');
  CheckHit(cIfDef, 24, '', 'outside the directive');
  CheckHit('{$ifndef foo}', 11, 'foo', 'lower-case keyword');
  CheckHit('{$DEFINE A}{$UNDEF B}', 10, 'A', 'two directives on a line: first');
  CheckHit('{$DEFINE A}{$UNDEF B}', 20, 'B', 'two directives on a line: second');
  CheckHit('(*$IFDEF PAREN*) x', 12, 'PAREN', '(*$ ... *) spelling');
  CheckHit('{$I foo.inc}', 5, '', '{$I} is not a conditional');
  CheckHit('{$IFOPT R+}', 8, '', '{$IFOPT} is not a conditional');
  CheckHit('{$ENDIF}', 4, '', '{$ENDIF} is not a conditional');
  CheckHit('{$ELSE}', 4, '', '{$ELSE} is not a conditional');
  CheckHit('{$IFDEF FOO', 10, '', 'unterminated on this line');
  CheckHit('{ $IFDEF FOO }', 9, '', 'a comment that is not a directive');
  CheckHit(cIf, 16, 'MSWINDOWS', '{$IF Defined(X)}');
  CheckHit(cIf, 42, '', '{$IF ...} Declared(T) is not a conditional');
  CheckHit(cIf, 61, 'X_1', '{$IF ...} Defined( X ) with spaces');
  CheckHit(cIf, 8, '', '{$IF ...} the word Defined itself is not one');
  CheckHit('{$ELSEIF Defined(B)}', 18, 'B', '{$ELSEIF Defined(X)}');
  CheckHit('{$IF FOO > 1}', 6, '', '{$IF} a bare constant is not one');
end;
{ PasTreeIdePlugin.TokenShift: the last tokens answer carried onto the text
  on screen. The base is what the answer describes; each case is a line as
  the editor holds it now, and where the TList token (row 5, [12, 17)) is
  painted - or that it is not, when the edit touched it. }
procedure TestTokenShift;
const
  cField = '    FData: TList;';
var
  LBase: TArray<string>;
  LHint: Integer;

  // Where the TList token lands on ACurrent, painted as row ARow; -1 when
  // it is left out.
  function Lands(ARow: Integer; const ACurrent: string;
    var AHint: Integer): Integer;
  var
    LShift: TLineShift;
    LFrom, LTo: Integer;
  begin
    Result := -1;
    LShift := ShiftForLine(LBase, ARow, ACurrent, AHint);
    if (LShift.BaseRow = 5) and
       ShiftToken(LShift, ACurrent, 12, 17, LFrom, LTo) and
       (LTo - LFrom = 5) then
      Result := LFrom;
  end;

  procedure CheckLands(ARow: Integer; const ACurrent: string; AWant: Integer;
    const AName: string);
  var
    LOwnHint: Integer;
  begin
    LOwnHint := 0;
    Check(Lands(ARow, ACurrent, LOwnHint) = AWant, AName);
  end;

var
  LShift: TLineShift;
  LFrom, LTo: Integer;
begin
  Writeln('--- TokenShift');
  LBase := SplitBaseLines('unit U;'#13#10'interface'#13#10'type'#13#10 +
    '  TFoo = class'#13#10 + cField + #13#10'  end;'#13#10#13#10 +
    'implementation'#13#10'end.');
  Check((Length(LBase) = 9) and (LBase[4] = cField) and (LBase[6] = ''),
    'SplitBaseLines: CRLF lines, the CR dropped, the blank line kept');

  CheckLands(5, cField, 12, 'an unchanged line paints where it was');
  CheckLands(5, '    FXData: TList;', 13,
    'a character typed in front moves the type name right');
  CheckLands(5, '    FData:  TList;', 13, 'so does a space');
  CheckLands(5, '    Data: TList;', 11, 'a deletion in front moves it left');
  CheckLands(5, '    FData: TList; // note', 12,
    'typing after it leaves it where it was');
  CheckLands(5, '    FData: XTList;', -1,
    'a letter typed against its start makes another name: left out');
  CheckLands(5, '    FData: TListX;', -1,
    'a letter typed against its end: left out');
  CheckLands(5, '    FData: TLiist;', -1, 'an edit inside it: left out');
  CheckLands(5, '    Total := Count + 1;', -1,
    'a line with nothing in common paints no token of its base line');

  // A line inserted above: the field is now row 6, and the pass's offset
  // carries the rows below it.
  LHint := 0;
  Check(Lands(6, cField, LHint) = 12,
    'a line moved down by an insertion above is found by its text');
  Check(LHint = -1, 'and the pass remembers the offset');
  LShift := ShiftForLine(LBase, 7, '  end;', LHint);
  Check(LShift.Same and (LShift.BaseRow = 6),
    'the next line is tried at that offset first');
  LHint := -1;
  Check(Lands(6, '    FXData: TList;', LHint) = 13,
    'an edited line below an insertion maps through the pass''s offset');

  LHint := 3;
  LShift := ShiftForLine(LBase, 7, '   ', LHint);
  Check((LShift.BaseRow = 0) and (LHint = 3),
    'a blank line paints nothing and does not move the offset');
  LHint := 0;
  LShift := ShiftForLine(LBase, 40, 'begin', LHint);
  Check(LShift.BaseRow = 0, 'a row past the base text paints nothing');

  // The suffix never reaches into the prefix.
  LHint := 0;
  LShift := ShiftForLine(['aa'], 1, 'aaa', LHint);
  Check((LShift.Prefix = 2) and (LShift.Suffix = 0) and (LShift.Delta = 1),
    'aa -> aaa is one insertion after the common prefix');
  Check(not ShiftToken(LShift, 'aaa', 1, 3, LFrom, LTo),
    'and a token the insertion extends is left out');
end;

begin
  GFailures := 0;
  TestUri;
  TestXmlDocEntities;
  TestXmlDocProse;
  TestPositions;
  TestDirectiveSymbol;
  TestTokenShift;

  Writeln;
  if GFailures = 0 then
    Writeln('RESULT: PASS')
  else
  begin
    Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := 1;
  end;
end.
