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
  PasLsp.XmlDoc;

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

begin
  GFailures := 0;
  TestUri;
  TestXmlDocEntities;
  TestXmlDocProse;
  TestPositions;

  Writeln;
  if GFailures = 0 then
    Writeln('RESULT: PASS')
  else
  begin
    Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := 1;
  end;
end.
