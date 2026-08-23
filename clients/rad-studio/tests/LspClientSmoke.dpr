program LspClientSmoke;

{
  Drives PasTreeIdePlugin.LspClient against a real pastree-server.exe over a
  real project (tests\fixtures\DemoApp.dpr), outside the IDE. Where
  LspTransportSmoke proves the pipes, this proves the session: the handshake,
  requests queued before the server is ready, real navigation answers, and the
  lazy restart policy.

  Both units under test depend on nothing but SysUtils/Classes/JSON/Windows -
  no ToolsAPI - which is exactly why this harness can exist and why the
  ToolsAPI glue is kept in a separate layer above them.

  Usage: LspClientSmoke.exe [path\to\pastree-server.exe]
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  PasTreeIdePlugin.LspClient;

const
  { The server this repo's own build.bat produces, as a path RELATIVE to the
    test exe's directory. Relative rather than absolute because since the
    package moved into the server's repository there is no sibling checkout to
    guess at - and an absolute C:\Repos\... default was only ever correct on
    one machine. Overridden by the first command-line argument. }
  cDefaultExeRel = '..\..\..\..\out\pastree-server.exe';
  cAnswerTimeoutMs = 30000;

var
  GClient: TLspClient;
  GFixtureDir: string;
  GFailures: Integer;
  // One outstanding request at a time is all this harness needs.
  GAnswered: Boolean;
  GOk: Boolean;
  GResultJson: string;
  GError: string;
  // Documents this harness has opened, so OnReady can re-open them against a
  // restarted server - the job the real document layer will do.
  GOpened: TArray<string>;
  GReopens: Integer;
  GVersion: Integer;   // document version counter, must only ever increase

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    Writeln('  [ok]   ' + AWhat)
  else
  begin
    Writeln('  [FAIL] ' + AWhat);
    Inc(GFailures);
  end;
end;

function PumpUntil(const ACondition: TFunc<Boolean>;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := GetTickCount64 + ATimeoutMs;
  repeat
    CheckSynchronize(50);
    if ACondition then
      Exit(True);
  until GetTickCount64 >= LDeadline;
  Result := False;
end;

function ProcessAlive(APid: DWORD): Boolean;
var
  LHandle: THandle;
  LCode: DWORD;
begin
  LHandle := OpenProcess(PROCESS_QUERY_INFORMATION, False, APid);
  if LHandle = 0 then
    Exit(False);
  try
    Result := GetExitCodeProcess(LHandle, LCode) and (LCode = STILL_ACTIVE);
  finally
    CloseHandle(LHandle);
  end;
end;

procedure KillProcess(APid: DWORD);
var
  LHandle: THandle;
begin
  LHandle := OpenProcess(PROCESS_TERMINATE, False, APid);
  if LHandle = 0 then
    Exit;
  try
    TerminateProcess(LHandle, 99);
  finally
    CloseHandle(LHandle);
  end;
end;

/// <summary>
/// Issues one request and pumps until it is answered. The result is copied to
/// a string inside the callback because the client frees the JSON the moment
/// the callback returns.
/// </summary>
function Ask(const AMethod: string; AParams: TJSONObject): Boolean;
begin
  GAnswered := False;
  GOk := False;
  GResultJson := '';
  GError := '';
  GClient.Request(AMethod, AParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      GAnswered := True;
      GOk := ASuccess;
      GError := AError;
      if Assigned(AResult) then
        GResultJson := AResult.ToJSON;
    end);
  Result := PumpUntil(function: Boolean begin Result := GAnswered end,
    cAnswerTimeoutMs);
  if not Result then
    Writeln('  !! no answer to ' + AMethod + ' within the timeout')
  else if not GOk then
    Writeln('  -- ' + AMethod + ' failed: ' + GError)
  else
    Writeln('  -- ' + AMethod + ' -> ' + GResultJson);
end;

{ ---------------------------------------------------------------------------
  Positions are found by searching the fixture text rather than hardcoded, so
  editing a fixture cannot silently make the test assert the wrong place.
  --------------------------------------------------------------------------- }

/// <summary>
/// 0-based line/character of ATokenqq inside the first line containing
/// ALineHint. Raises if either is absent - a broken fixture must not read as
/// a failed feature.
/// </summary>
/// <summary>
/// Splits on either line-ending style. The fixtures are checked in with LF but
/// git may hand them over as CRLF, so nothing here may assume one.
/// </summary>
function SplitLines(const AText: string): TArray<string>;
begin
  Result := AText.Replace(#13#10, #10).Split([#10]);
end;

procedure FindPosInText(const AText, ALineHint, AToken: string;
  out ALine, AChar: Integer);
var
  LLines: TArray<string>;
  I, LCol: Integer;
begin
  LLines := SplitLines(AText);
  for I := 0 to High(LLines) do
    if LLines[I].Contains(ALineHint) then
    begin
      LCol := Pos(AToken, LLines[I]);
      if LCol = 0 then
        raise Exception.CreateFmt('no "%s" on the line with "%s"',
          [AToken, ALineHint]);
      ALine := I;
      AChar := LCol - 1;   // Pos is 1-based, LSP characters are 0-based
      Exit;
    end;
  raise Exception.CreateFmt('no line containing "%s"', [ALineHint]);
end;

procedure FindPos(const AFile, ALineHint, AToken: string;
  out ALine, AChar: Integer);
begin
  try
    FindPosInText(TFile.ReadAllText(AFile), ALineHint, AToken, ALine, AChar);
  except
    on E: Exception do
      raise Exception.CreateFmt('fixture %s: %s', [AFile, E.Message]);
  end;
end;

/// <summary>
/// Inserts ANew right after the first line containing AHint. Raises if the hint
/// is gone: a fixture that drifted must fail loudly, not silently test nothing.
/// </summary>
function InsertAfterLine(const ALines: TArray<string>;
  const AHint: string; const ANew: TArray<string>): TArray<string>;
var
  I: Integer;
begin
  for I := 0 to High(ALines) do
    if ALines[I].Contains(AHint) then
    begin
      Result := Copy(ALines, 0, I + 1) + ANew +
        Copy(ALines, I + 1, Length(ALines) - I - 1);
      Exit;
    end;
  raise Exception.CreateFmt('fixture drifted: no line containing "%s"',
    [AHint]);
end;

/// <summary>Inserts ANew right BEFORE the first line containing AHint.</summary>
function InsertBeforeLine(const ALines: TArray<string>;
  const AHint: string; const ANew: TArray<string>): TArray<string>;
var
  I: Integer;
begin
  for I := 0 to High(ALines) do
    if ALines[I].Contains(AHint) then
    begin
      Result := Copy(ALines, 0, I) + ANew +
        Copy(ALines, I, Length(ALines) - I);
      Exit;
    end;
  raise Exception.CreateFmt('fixture drifted: no line containing "%s"',
    [AHint]);
end;

function PositionParams(const AFile: string; ALine, AChar: Integer;
  AIncludeDeclaration: Boolean = False): TJSONObject;
var
  LDoc, LPos, LCtx: TJSONObject;
begin
  Result := TJSONObject.Create;
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFile));
  Result.AddPair('textDocument', LDoc);
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(ALine));
  LPos.AddPair('character', TJSONNumber.Create(AChar));
  Result.AddPair('position', LPos);
  if AIncludeDeclaration then
  begin
    LCtx := TJSONObject.Create;
    LCtx.AddPair('includeDeclaration', TJSONBool.Create(True));
    Result.AddPair('context', LCtx);
  end;
end;

procedure SendDidOpenText(const AFile, AText: string);
var
  LParams, LDoc: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFile));
  LDoc.AddPair('languageId', 'pascal');
  LDoc.AddPair('version', TJSONNumber.Create(1));
  LDoc.AddPair('text', AText);
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  GClient.Notify('textDocument/didOpen', LParams);
end;

procedure SendDidOpen(const AFile: string);
begin
  // TFile.ReadAllText drops a BOM as it decodes, so this is BOM-free text -
  // which is what every other test wants. TestBomIsNotContent sends its own.
  SendDidOpenText(AFile, TFile.ReadAllText(AFile));
end;

/// <summary>
/// One contentChange with NO range - a whole-document replacement. Exactly the
/// shape PasTreeIdePlugin.LspDocuments sends, and the thing worth pinning: the
/// server advertises INCREMENTAL sync, and this relies on its documented
/// willingness to accept a rangeless change as a full replace.
/// </summary>
procedure SendDidChange(const AFile, AText: string);
var
  LParams, LDoc, LChange: TJSONObject;
  LChanges: TJSONArray;
begin
  Inc(GVersion);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFile));
  LDoc.AddPair('version', TJSONNumber.Create(GVersion));
  LChange := TJSONObject.Create;
  LChange.AddPair('text', AText);
  LChanges := TJSONArray.Create;
  LChanges.Add(LChange);
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('contentChanges', LChanges);
  GClient.Notify('textDocument/didChange', LParams);
end;

/// <summary>
/// Opens a document and remembers it, the way the real document layer will -
/// so OnReady can re-open everything against a restarted server.
/// </summary>
procedure DidOpen(const AFile: string);
begin
  GOpened := GOpened + [AFile];
  SendDidOpen(AFile);
end;

procedure ReopenAll;
var
  LFile: string;
begin
  for LFile in GOpened do
  begin
    SendDidOpen(LFile);
    Inc(GReopens);
  end;
end;

function StartClient(const AExe: string): Boolean;
var
  LOptions: TLspInitOptions;
begin
  LOptions := Default(TLspInitOptions);
  // A bare .dpr root: the server takes it as MainSource directly, no MSBuild
  // evaluation, which keeps this test independent of any .dproj.
  LOptions.ProjectFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');
  LOptions.Platform := 'Win32';
  LOptions.SearchPaths := [GFixtureDir];
  Result := GClient.Start(LOptions);
end;

{ 1. The handshake, plus a request issued while it is still in flight. }
procedure TestQueuedBeforeReady(const AExe: string);
var
  LLine, LChar: Integer;
  LAppFile: string;
begin
  Writeln;
  Writeln('=== 1. handshake, with a request issued before the server is ready ===');
  LAppFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');

  Check(StartClient(AExe), 'Start spawned the server');
  Check(GClient.State = lcsStarting, 'state is Starting right after Start');

  // Deliberately NOT waiting for readiness: this is the Ctrl+Click-right-
  // after-IDE-startup case, and it must be queued rather than dropped.
  FindPos(LAppFile, 'Writeln(Greet(''world', 'Greet', LLine, LChar);
  Check(Ask('textDocument/definition',
    PositionParams(LAppFile, LLine, LChar)),
    'the queued definition request was answered');
  Check(GOk, 'the queued request succeeded');
  Check(GClient.State = lcsReady, 'state is Ready once the handshake landed');
  Check(GResultJson.Contains('DemoUnit.pas'),
    'definition of Greet points into DemoUnit.pas');
end;

{ 2. Real navigation answers over documents the client has opened. }
procedure TestNavigation;
var
  LLine, LChar: Integer;
  LAppFile, LUnitFile: string;
begin
  Writeln;
  Writeln('=== 2. definition / references / the unit identity ===');
  LAppFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');

  DidOpen(LAppFile);
  DidOpen(LUnitFile);

  // References on the declaration itself, asking for the declaration too:
  // two call sites in DemoApp plus the implementation and the declaration.
  FindPos(LUnitFile, 'function Greet', 'Greet', LLine, LChar);
  Check(Ask('textDocument/references',
    PositionParams(LUnitFile, LLine, LChar, True)),
    'references answered');
  Check(GOk and GResultJson.Contains('DemoApp.dpr'),
    'references reach the call sites in DemoApp.dpr');

  // The three-identity model: on a program's `X in ''...''` uses item the unit
  // identity is the right answer. SymbolAt would claim this position and find
  // nothing - the bug this repo fixed by testing UnitAt first.
  FindPos(LAppFile, 'DemoUnit in ', 'DemoUnit', LLine, LChar);
  Check(Ask('textDocument/definition',
    PositionParams(LAppFile, LLine, LChar)),
    'definition on the uses item answered');
  Check(GOk and GResultJson.Contains('DemoUnit.pas'),
    'the uses item resolves to the unit itself');
end;

{ 3. Lazy restart: no timer, the next request revives the server. }
procedure TestLazyRestart;
var
  LPid, LNewPid: DWORD;
  LLine, LChar: Integer;
  LAppFile: string;
begin
  Writeln;
  Writeln('=== 3. server killed, next request restarts it ===');
  LAppFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');
  LPid := GClient.ProcessId;
  Check(LPid <> 0, 'have a server pid to kill');

  KillProcess(LPid);
  Check(PumpUntil(function: Boolean
    begin
      Result := GClient.State = lcsFailed;
    end, 5000), 'client noticed the server died');
  Check(not ProcessAlive(LPid), 'the killed server is gone');

  // The restart is not scheduled; it happens because we ask for something.
  GReopens := 0;
  FindPos(LAppFile, 'Writeln(Greet(''again', 'Greet', LLine, LChar);
  Check(Ask('textDocument/definition',
    PositionParams(LAppFile, LLine, LChar)),
    'the request after the crash was answered');
  LNewPid := GClient.ProcessId;
  Check((LNewPid <> 0) and (LNewPid <> LPid),
    Format('a new server was spawned (pid %d -> %d)', [LPid, LNewPid]));
  Check(GClient.State = lcsReady, 'client is Ready again');
  Check(GReopens = Length(GOpened),
    Format('OnReady re-opened all %d documents on the new server',
      [Length(GOpened)]));
  Check(GOk and GResultJson.Contains('DemoUnit.pas'),
    'navigation works again after the restart');
end;

{ 4. Positions on a line containing non-ASCII text.

  The one risk the LSP move inherited rather than introduced: LSP columns are
  UTF-16 code units, and a chain that counted UTF-8 bytes anywhere would land
  off by the extra bytes. DemoUnicode.Shout puts 13 Cyrillic characters (26
  UTF-8 bytes) before the identifier Wrap on one line - a byte-counting bug
  would resolve nothing, or something inside the string literal. }
procedure TestNonAsciiPositions;
var
  LLine, LChar, LDeclLine, LDeclChar: Integer;
  LFile: string;
begin
  Writeln;
  Writeln('=== 4. columns on a line with a Cyrillic literal ===');
  LFile := TPath.Combine(GFixtureDir, 'DemoUnicode.pas');
  DidOpen(LFile);

  // Where Wrap is CALLED - the line whose leading Cyrillic literal is the point
  // of the fixture - and where it is DECLARED, both read from the file so
  // editing the fixture cannot make this assert the wrong place.
  FindPos(LFile, 'Wrap(AText)', 'Wrap(AText)', LLine, LChar);
  FindPos(LFile, 'function Wrap(', 'Wrap', LDeclLine, LDeclChar);

  Check(Ask('textDocument/definition', PositionParams(LFile, LLine, LChar)),
    'definition answered');
  Check(GOk and GResultJson.Contains('DemoUnicode.pas'),
    'Wrap resolves despite the Cyrillic literal earlier on the line');
  // Landing in the right FILE is not enough: a column error could still hit
  // some other identifier. Only the exact declaration position proves the
  // request was aimed where we meant.
  Check(GOk and GResultJson.Contains(
    Format('"line":%d,"character":%d', [LDeclLine, LDeclChar])),
    Format('and lands exactly on Wrap''s declaration (%d,%d)',
      [LDeclLine, LDeclChar]));
end;

{ 4b. A leading BOM in didOpen text is not content.

  This one goes through the raw notification rather than the plugin's document
  layer ON PURPOSE: PasTreeIdePlugin.LspDocuments strips the BOM in
  ReadBufferText, so the IDE could never reach the flaw and the server's own
  behaviour went untested. Any other LSP client is free to hand its buffer over
  with the U+FEFF included, and a UTF-8-with-BOM .pas is ordinary in Delphi.

  Measured 2026-08-20, before the fix in PasLsp.Documents: one BOM character
  made the identifier scan find NOTHING at any position in the whole file - not
  merely on line 1 - and the only trace was "no identifier at ...", which reads
  like a resolver bug. Silent and total, hence a check of its own. }
procedure TestBomIsNotContent;
var
  LLine, LChar: Integer;
  LUnitFile: string;
begin
  Writeln;
  Writeln('=== 4b. a leading BOM in didOpen text ===');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');

  SendDidOpenText(LUnitFile, #$FEFF + TFile.ReadAllText(LUnitFile));
  try
    // Line 1 is where a BOM could plausibly cost a column; the point of the
    // bug was that a LATER line broke too, so ask about one.
    FindPos(LUnitFile, 'function Greet', 'Greet', LLine, LChar);
    Check(Ask('textDocument/definition',
      PositionParams(LUnitFile, LLine, LChar)),
      'definition answered for a BOM-prefixed document');
    Check(GOk and GResultJson.Contains('DemoUnit.pas'),
      'a leading BOM does not stop identifiers resolving');
  finally
    SendDidOpen(LUnitFile);   // back to the text the later tests expect
  end;
end;

{ 5. Document overlay: a full-replacement didChange must beat what is on disk.

  This is the "document truth" rule the whole plugin leans on - once a file is
  open, the buffer is the truth. It also pins an assumption verified so far only
  by READING the server: the plugin sends one contentChange with no range (a
  whole-document replacement) even though the server advertises INCREMENTAL
  sync. The test adds a function that exists ONLY in the sent text; if the
  overlay were ignored, the server would resolve nothing, because nothing on
  disk mentions it. Nothing here writes to the fixture files. }
procedure TestOverlayBeatsDisk;
var
  LUnitFile, LAppFile, LUnitText, LAppText: string;
  LLine, LChar: Integer;
begin
  Writeln;
  Writeln('=== 5. didChange overlay beats the text on disk ===');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  LAppFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');

  // A new exported function, in the buffer only - declaration after Greet's,
  // body before the final `end.`.
  LUnitText := string.Join(#13#10, InsertBeforeLine(
    InsertAfterLine(SplitLines(TFile.ReadAllText(LUnitFile)),
      'function Greet(const AName: string): string;',
      ['function Farewell: string;']),
    'end.',
    ['function Farewell: string;', 'begin', '  Result := ''Bye'';', 'end;',
     '']));
  Check(LUnitText.Contains('function Farewell'),
    'fixture patch applied (declaration and body added in memory)');

  LAppText := string.Join(#13#10, InsertAfterLine(
    SplitLines(TFile.ReadAllText(LAppFile)), 'Writeln(Shout(',
    ['  Writeln(Farewell);']));
  Check(LAppText.Contains('Writeln(Farewell)'), 'call site added in memory');

  SendDidChange(LUnitFile, LUnitText);
  SendDidChange(LAppFile, LAppText);

  // Position of the call site in the PATCHED text, which is what the server
  // now holds - not in the file.
  FindPosInText(LAppText, 'Writeln(Farewell)', 'Farewell', LLine, LChar);
  Check(Ask('textDocument/definition',
    PositionParams(LAppFile, LLine, LChar)),
    'definition answered');
  Check(GOk and GResultJson.Contains('DemoUnit.pas'),
    'a function that exists only in the buffer resolves into DemoUnit.pas');

  // Put both documents back to their on-disk text so later scenarios (and
  // reruns) see the fixtures as written.
  SendDidChange(LUnitFile, TFile.ReadAllText(LUnitFile));
  SendDidChange(LAppFile, TFile.ReadAllText(LAppFile));
end;

{ 5b. Completion: PasTree's engine over the live overlay, bridged.

  What is pinned here is the CONTRACT (COMPLETION.md): the request answers
  without waiting for any analysis; a mid-word invocation's textEdit range
  covers the WHOLE word (the clangd behavior - the client filters by the
  typed prefix, the server does not); scope symbols prove the real engine
  answers (a keyword list knows no parameters); a comment interior refuses;
  and the replace span survives the UTF-16 column conversion on a line with
  a Cyrillic literal - the same line the definition columns are pinned on. }
procedure TestCompletion;
var
  LUnitFile, LUniFile, LPatched: string;
  LLine, LChar, LDocCount: Integer;
begin
  Writeln;
  Writeln('=== 5b. completion: the PasTree engine over the overlay ===');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  LUniFile := TPath.Combine(GFixtureDir, 'DemoUnicode.pas');

  // Cursor after 'beg' of Greet's 'begin' - a prefix inside a keyword.
  FindPos(LUnitFile, 'begin', 'begin', LLine, LChar);
  Check(Ask('textDocument/completion',
    PositionParams(LUnitFile, LLine, LChar + 3)),
    'completion answered');
  Check(GOk and GResultJson.Contains('"label":"begin"'),
    'the statement keyword is offered');
  Check(GOk and GResultJson.Contains('"label":"AName"'),
    'the enclosing routine''s parameter is offered - the real engine, '
    + 'not a word list');
  // The routine's row carries its declaration's real signature and the
  // hasParams flag the RAD client's auto-parenthesis reads.
  Check(GOk and GResultJson.Contains('(const AName: string)'),
    'Greet''s row carries its parameter list verbatim');
  Check(GOk and GResultJson.Contains('"hasParams":true'),
    'and the hasParams flag');
  // Help Insight on a completion row (2026-08-23): documentation ships with
  // EVERY item, because the RAD viewer asks for it synchronously on the UI
  // thread and a completionItem/resolve round-trip is not available there.
  Check(GOk and GResultJson.Contains('"documentation":{"kind":"markdown"'),
    'the documented row carries completionItem.documentation');
  Check(GOk and GResultJson.Contains('Greets a person by name.'),
    'and it holds the rendered XMLDoc summary');
  // Undocumented rows must not pay for the field: a keyword answers empty by
  // engine contract, and the field is then omitted rather than sent empty -
  // Greet is the only documented declaration in the fixture.
  LDocCount := (Length(GResultJson) -
    Length(GResultJson.Replace('"documentation"', ''))) div
    Length('"documentation"');
  Check(GOk and (LDocCount = 1),
    'and it is the ONLY row carrying the field');
  // The viewer's documentation surface is HTML too (GetSymbolDocumentation is
  // documented as returning HTML), so the fragment rides in our data field.
  Check(GOk and GResultJson.Contains('"docHtml":"<table width='),
    'the row also carries the doc as an HTML fragment');
  // The pane sizes itself to the min-content width of what it is given, so
  // the fragment must impose its own - measured live 2026-08-23.
  Check(GOk and GResultJson.Contains('<p>Greets a person by name.</p>'),
    'with the summary as a paragraph inside the fixed-width wrapper');
  // The bare-row fallbacks (2026-08-22): a type row names its definition's
  // head, a const row its value, a builtin routine its curated result.
  Check(GOk and GResultJson.Contains('"label":"TBox"'), 'TBox is offered');
  Check(GOk and GResultJson.Contains(' = record'),
    'and its row names the definition head');
  Check(GOk and GResultJson.Contains('"label":"CAnswer"'),
    'CAnswer is offered');
  Check(GOk and GResultJson.Contains(' = 42'), 'and its row shows the value');
  Check(GOk and GResultJson.Contains('(const S: <string|array>): Integer'),
    'the Length builtin shows params AND the curated result type');
  Check(GOk and GResultJson.Contains(
    Format('"start":{"line":%d,"character":%d}', [LLine, LChar])),
    'the textEdit range starts where the word starts');
  Check(GOk and GResultJson.Contains(
    Format('"end":{"line":%d,"character":%d}', [LLine, LChar + 5])),
    'and covers the whole word, not just the typed prefix');

  // A comment interior is a refusal, not a keyword dump.
  FindPos(LUnitFile, 'Fixture for tests', 'Fixture', LLine, LChar);
  Check(Ask('textDocument/completion',
    PositionParams(LUnitFile, LLine, LChar + 3)),
    'completion answered inside a comment');
  Check(GOk and GResultJson.Contains('"items":[]'),
    'and honestly offered nothing there');

  // The same span discipline past a Cyrillic literal: append a token to the
  // Shout line IN THE OVERLAY ONLY and complete right after it. A byte-counting
  // bug anywhere in the chain would misplace the range by the literal's extra
  // UTF-8 bytes.
  LPatched := TFile.ReadAllText(LUniFile)
    .Replace('Wrap(AText);', 'Wrap(AText); tr');
  Check(LPatched.Contains('; tr'), 'fixture patch applied in memory');
  SendDidChange(LUniFile, LPatched);
  try
    FindPosInText(LPatched, 'Wrap(AText); tr', '; tr', LLine, LChar);
    Inc(LChar, 2);   // the 'tr' after '; '
    Check(Ask('textDocument/completion',
      PositionParams(LUniFile, LLine, LChar + 2)),
      'completion answered on the Cyrillic line');
    Check(GOk and GResultJson.Contains('"label":"try"'),
      'prefix ''tr'' has try among the statement keywords');
    Check(GOk and GResultJson.Contains(
      Format('"start":{"line":%d,"character":%d}', [LLine, LChar])),
      'the replace span lands on ''tr'' despite the Cyrillic literal');
  finally
    SendDidChange(LUniFile, TFile.ReadAllText(LUniFile));
  end;
end;

{ 5c. Hover: the shape Tooltip Insight parses.

  The RAD plugin's hint path (PasTreeIdePlugin.LspSession.HoverPlainText)
  strips exactly this shape - a ```pascal fence around the declaration line
  plus an italic note - so the fence markers and the note's underscores are
  part of the contract, not decoration. }
procedure TestHover;
var
  LUnitFile: string;
  LLine, LChar: Integer;
begin
  Writeln;
  Writeln('=== 5c. hover carries the declaration line and a kind note ===');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  FindPos(LUnitFile, 'Result := ''Hello', 'Result', LLine, LChar);
  // Hover over Greet's call-site-free body is dull; ask about Greet itself
  // at its implementation header instead.
  FindPos(LUnitFile, 'function Greet', 'Greet', LLine, LChar);
  Check(Ask('textDocument/hover', PositionParams(LUnitFile, LLine, LChar)),
    'hover answered');
  Check(GOk and GResultJson.Contains('```pascal'),
    'the declaration rides in a pascal code fence');
  Check(GOk and GResultJson.Contains('function Greet'),
    'and is the declaration line itself');
  // Help Insight (2026-08-23): the fixture's `///` block, rendered by
  // PasLsp.XmlDoc. The summary is collapsed across its two source lines - a
  // doc section must read as a sentence, not as the author's margin - and the
  // param/returns sections carry their labels. The note stays LAST, so the
  // hint reads declaration, documentation, provenance.
  Check(GOk and GResultJson.Contains('Greets a person by name.'),
    'the XMLDoc summary rides along, collapsed to one paragraph');
  Check(GOk and GResultJson.Contains('- AName - the name to greet'),
    'and the parameter section');
  Check(GOk and GResultJson.Contains('Returns: the greeting line'),
    'and the returns section');
  Check(GOk and not GResultJson.Contains('<summary>'),
    'no XML tag survives into the display text');
  // The IDE's hint surface is an HTML window (ObjRepos\HelpInsight.xsl/.css),
  // so the same card rides as `pastreeHtml` in the shape that transform
  // emits: the maincaption div, a codelink to the declaration, then the
  // sections. Our field, alongside the standard contents - a foreign client
  // ignores it, exactly like signatureHelp's pastreeCall.
  Check(GOk and GResultJson.Contains('"pastreeHtml"'),
    'hover carries the Help Insight page as well');
  Check(GOk and GResultJson.Contains('class=\"maincaption\"'),
    'with the IDE stylesheet''s own caption class');
  Check(GOk and GResultJson.Contains('helpinsight:/filelink:'),
    'and the IDE''s own source-link scheme');
  Check(GOk and GResultJson.Contains('<dt><b>AName</b></dt>'),
    'and the parameters as a definition list, not as text');
end;

{ 5d. Signature help: the engine's CallAt through the seam.

  Pinned: a caret inside a call's arguments answers the target's real
  signature with individual parameter labels and the active argument; the
  call-open position rides as pastreeCall for the RAD hint anchor; a
  position in no call answers null. The 'Greet' target resolves through the
  bridged overlay (cross-unit), an intrinsic answers its curated table
  signature, and the INNERMOST enclosing call wins - the three behaviors
  that replaced the interim backward-walk locator on 2026-08-22. }
procedure TestSignatureHelp;
var
  LAppFile: string;
  LLine, LChar: Integer;
begin
  Writeln;
  Writeln('=== 5d. signatureHelp inside a call''s arguments ===');
  LAppFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');

  FindPos(LAppFile, 'Writeln(Greet(''world', 'world', LLine, LChar);
  Check(Ask('textDocument/signatureHelp',
    PositionParams(LAppFile, LLine, LChar)),
    'signatureHelp answered');
  Check(GOk and GResultJson.Contains(
    '"label":"Greet(const AName: string): string"'),
    'the cross-unit target''s full signature');
  Check(GOk and GResultJson.Contains('"label":"const AName: string"'),
    'with the individual parameter label');
  Check(GOk and GResultJson.Contains('"activeParameter":0'),
    'and the first argument active');
  Check(GOk and GResultJson.Contains('"pastreeCall"'),
    'and the call anchor for the RAD hint window');

  // On the 'Greet' designator itself the caret sits in WRITELN's argument
  // list, not Greet's - the innermost-call rule - and Writeln answers from
  // the engine's curated intrinsic signature table.
  FindPos(LAppFile, 'Writeln(Greet(''world', 'Greet', LLine, LChar);
  Check(Ask('textDocument/signatureHelp',
    PositionParams(LAppFile, LLine, LChar)),
    'signatureHelp answered on the enclosing intrinsic call');
  Check(GOk and GResultJson.Contains('"label":"Writeln([var F: Text;] Args)"'),
    'the intrinsic''s curated signature');

  // A position inside no call is a null, not an invented signature.
  FindPos(LAppFile, 'begin', 'begin', LLine, LChar);
  Check(Ask('textDocument/signatureHelp',
    PositionParams(LAppFile, LLine, LChar + 3)),
    'signatureHelp answered outside any call');
  // A JSON null result reaches the harness as an empty GResultJson (the
  // client hands the callback nil for null results).
  Check(GOk and ((GResultJson = '') or (GResultJson = 'null')),
    'and honestly answered null there');
end;

{ 5d-bis. documentSymbol: the outline behind the Structure pane.

  It had NO coverage here until 2026-08-23, and that is exactly how a crash
  reached a user: a scope's symbol list is created lazily by the model and is
  legally nil for an empty scope, the handler read its Count anyway, and every
  documentSymbol in the session came back as an EAccessViolation. One request
  per unit is all it takes to notice - the reason this section exists. }
procedure TestDocumentSymbol;
var
  LUnitFile: string;
  LParams, LDoc: TJSONObject;
begin
  Writeln;
  Writeln('=== 5d-bis. documentSymbol answers an outline, not an error ===');
  LUnitFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  LParams := TJSONObject.Create;
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(LUnitFile));
  LParams.AddPair('textDocument', LDoc);
  Check(Ask('textDocument/documentSymbol', LParams),
    'documentSymbol answered');
  Check(GOk, 'and did not fail the request');
  Check(GOk and GResultJson.Contains('"name":"Greet"'),
    'the routine is in the outline');
  Check(GOk and GResultJson.Contains('"name":"TBox"'),
    'and the record type');
  Check(GOk and GResultJson.Contains('"name":"Value"'),
    'with its field as a child - types report their members');
end;

{ 5f. pastree/classComplete: the server half of Ctrl+Shift+C.

  Asked about a fixture that is NOT in the project's closure, deliberately:
  class completion is a parse of one buffer, and if this section needed the
  analysis it would be testing the wrong thing. Every rule the fixture's own
  header lists is checked here, including the two that must NOT produce a
  body and the free routine the native completion ignores. }
procedure TestClassComplete;
var
  LFile: string;
  LParams, LDoc: TJSONObject;
begin
  Writeln;
  Writeln('=== 5f. classComplete implements what is declared, once ===');
  LFile := TPath.Combine(GFixtureDir, 'DemoClassComplete.pas');
  LParams := TJSONObject.Create;
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(LFile));
  LParams.AddPair('textDocument', LDoc);
  Check(Ask('pastree/classComplete', LParams), 'classComplete answered');
  Check(GOk and GResultJson.Contains('"count":1'),
    'one edit - every body goes in one insertion at the end of the section');
  Check(GOk and GResultJson.Contains(
    'procedure TBase.Missing(const A: string; B: Integer);'),
    'the missing method, with its parameter list verbatim');
  Check(GOk and GResultJson.Contains(
    'class function TBase.Make: TBase; static;'),
    'a class static method repeats `static` - required on the implementation');
  Check(GOk and GResultJson.Contains(
    'function TBase.Overloaded(A: Integer): Integer;'),
    'the overload that has no body');
  Check(GOk and not GResultJson.Contains('function TBase.Overloaded: Integer'),
    'and NOT the overload that has one');
  Check(GOk and GResultJson.Contains('procedure TStack<T>.Push(const AItem: T);'),
    'a generic type''s method is qualified with its parameters');
  Check(GOk and GResultJson.Contains('procedure FreeRoutine(AValue: Integer);'),
    'a FREE routine of the interface section counts - the whole point');
  Check(GOk and not GResultJson.Contains('TBase.Done'),
    'an implemented method is not implemented twice');
  Check(GOk and not GResultJson.Contains('Abstracted'),
    'an abstract method has no body by definition');
  Check(GOk and not GResultJson.Contains('Work'),
    'an interface''s methods are not the unit''s to implement');
  Check(GOk and GResultJson.Contains('begin\r\n  \r\nend;'),
    'each body is begin/blank/end, with the blank line indented for the caret');
end;

{ 5e. workspace/symbol: the project-wide index behind Ctrl+. }
procedure TestWorkspaceSymbol;
var
  LParams: TJSONObject;
begin
  Writeln;
  Writeln('=== 5e. workspace/symbol finds the cross-unit declaration ===');
  LParams := TJSONObject.Create;
  LParams.AddPair('query', 'gree');
  Check(Ask('workspace/symbol', LParams), 'workspace/symbol answered');
  Check(GOk and GResultJson.Contains('"name":"Greet"'),
    'the substring query finds Greet');
  Check(GOk and GResultJson.Contains('"kind":12'),
    'as a Function symbol');
  Check(GOk and GResultJson.Contains('"containerName":"DemoUnit.pas"'),
    'with its declaring unit as the container');

  // The empty query is the RAD client's prefetch: everything, capped and
  // logged server-side - here it must at least carry both fixture units.
  LParams := TJSONObject.Create;
  LParams.AddPair('query', '');
  Check(Ask('workspace/symbol', LParams), 'the prefetch query answered');
  Check(GOk and GResultJson.Contains('"name":"Shout"'),
    'and carries symbols from other units');
end;

{ 6. Cancellation hygiene.

  TLspSession cancels a superseded request on every new one, so the invariant
  that matters is not "the answer is an error" - the server may well finish
  first - but that the callback fires EXACTLY ONCE either way and the client
  stays usable. A double-fire or a dropped callback would leave a feature
  either reporting twice or waiting forever. }
procedure TestCancelHygiene;
var
  LFile: string;
  LLine, LChar: Integer;
  LCalls: Integer;
  LId: Int64;
begin
  Writeln;
  Writeln('=== 6. a cancelled request still answers exactly once ===');
  LFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  FindPos(LFile, 'function Greet', 'Greet', LLine, LChar);

  LCalls := 0;
  LId := GClient.Request('textDocument/references',
    PositionParams(LFile, LLine, LChar, True),
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      Inc(LCalls);
      if ASuccess then
        Writeln('  -- answered normally (server finished before the cancel)')
      else
        Writeln('  -- answered as cancelled: ' + AError);
    end);
  Check(LId <> 0, 'request was issued');
  GClient.Cancel(LId);

  Check(PumpUntil(function: Boolean begin Result := LCalls > 0 end,
    cAnswerTimeoutMs), 'the cancelled request produced an answer');
  // Give any stray second delivery a chance to show up before asserting.
  PumpUntil(function: Boolean begin Result := LCalls > 1 end, 500);
  Check(LCalls = 1, Format('callback fired exactly once (fired %d)', [LCalls]));

  // Still usable afterwards - a botched cancel could leave stale pending state.
  Check(Ask('textDocument/definition', PositionParams(LFile, LLine, LChar)),
    'the client still answers requests after a cancel');
end;

{ 7. Restart on a configuration change, with a request in flight.

  TLspSession calls Start again whenever the active project, platform or build
  configuration changes, because the server fixes its configuration at
  initialize and cannot be retargeted. That path tears down a LIVE client, so
  two things have to hold: the old server must go, and a request that was still
  outstanding must fail exactly once rather than leave a feature waiting for an
  answer that can never come. The in-flight case is the interesting one - it is
  what "the user switched project mid-Ctrl+Click" looks like. }
procedure TestRestartOnConfigChange(const AExe: string);
var
  LOldPid, LNewPid: DWORD;
  LFile: string;
  LLine, LChar: Integer;
  LOrphaned: Integer;
  LOptions: TLspInitOptions;
begin
  Writeln;
  Writeln('=== 7. Start again for a new configuration, request in flight ===');
  LFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  FindPos(LFile, 'function Greet', 'Greet', LLine, LChar);
  LOldPid := GClient.ProcessId;

  LOrphaned := 0;
  GClient.Request('textDocument/references',
    PositionParams(LFile, LLine, LChar, True),
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      Inc(LOrphaned);
      Writeln(Format('  -- in-flight request answered: success=%s %s',
        [BoolToStr(ASuccess, True), AError]));
    end);

  // Same project, different platform: a different server by the session's
  // rules. Start tears the old one down.
  LOptions := Default(TLspInitOptions);
  LOptions.ProjectFile := TPath.Combine(GFixtureDir, 'DemoApp.dpr');
  LOptions.Platform := 'Win64';
  LOptions.SearchPaths := [GFixtureDir];
  GOpened := nil;   // the new server starts with no documents
  Check(GClient.Start(LOptions), 'Start succeeded for the new configuration');

  Check(LOrphaned = 1,
    Format('the in-flight request was failed exactly once (%d)', [LOrphaned]));
  Sleep(300);
  Check(not ProcessAlive(LOldPid), 'the previous server was shut down');

  LNewPid := GClient.ProcessId;
  Check((LNewPid <> 0) and (LNewPid <> LOldPid),
    Format('a different server is running (pid %d -> %d)',
      [LOldPid, LNewPid]));

  DidOpen(LFile);
  Check(Ask('textDocument/definition', PositionParams(LFile, LLine, LChar)),
    'navigation works against the reconfigured server');
  Check(GOk and GResultJson.Contains('DemoUnit.pas'),
    'and resolves correctly');
end;

{ 8. The server dies while a request is queued behind the handshake.

  The regression this pins: a queued frame that gets discarded used to leave its
  pending entry behind, so the callback documented as firing exactly once fired
  NEVER - the feature that asked would wait forever and the user's click would
  vanish with no message at all. Reaching it is possible only because nothing is
  dispatched until we pump: Start sends initialize, the request queues behind
  it, and killing the server before the first CheckSynchronize guarantees the
  handshake cannot have been acted on.

  Either internal path may run - the reply never arrives, or it arrives and the
  flush then fails on a broken pipe - and the assertion is the same for both,
  which is the point. }
procedure TestDeathDuringHandshake(const AExe: string);
var
  LFile: string;
  LLine, LChar: Integer;
  LCalls: Integer;
  LOk: Boolean;
  LPid: DWORD;
begin
  Writeln;
  Writeln('=== 8. server dies with a request queued behind the handshake ===');
  LFile := TPath.Combine(GFixtureDir, 'DemoUnit.pas');
  FindPos(LFile, 'function Greet', 'Greet', LLine, LChar);

  GOpened := nil;
  Check(StartClient(AExe), 'server started');
  LPid := GClient.ProcessId;
  Check(GClient.State = lcsStarting, 'handshake still in flight');

  LCalls := 0;
  LOk := True;
  GClient.Request('textDocument/definition', PositionParams(LFile, LLine, LChar),
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      Inc(LCalls);
      LOk := ASuccess;
      Writeln(Format('  -- queued request answered: success=%s %s',
        [BoolToStr(ASuccess, True), AError]));
    end);

  // Not pumped yet, so nothing the server said has been acted on.
  KillProcess(LPid);

  Check(PumpUntil(function: Boolean begin Result := LCalls > 0 end, 10000),
    'the queued request''s callback fired rather than being stranded');
  PumpUntil(function: Boolean begin Result := LCalls > 1 end, 500);
  Check(LCalls = 1, Format('and fired exactly once (fired %d)', [LCalls]));
  Check(not LOk, 'and reported failure rather than a bogus success');

  { And the client is not wedged - but not instantly, either, and that is
    correct: this server died before ever completing a handshake, so the attempt
    counter was never cleared and the restart backoff applies. An immediate
    retry is expected to be refused; the recovery only proves something once the
    backoff has elapsed. Pump through it rather than sleeping, so the reader
    thread's deliveries keep being dispatched. }
  Check(not GClient.IsReady, 'client is not ready immediately after the death');
  PumpUntil(function: Boolean begin Result := False end, 1300);

  DidOpen(LFile);
  Check(Ask('textDocument/definition', PositionParams(LFile, LLine, LChar)),
    'once the backoff elapses the next request restarts the server');
  Check(GOk and GResultJson.Contains('DemoUnit.pas'), 'and resolves correctly');
end;

var
  GExe: string;
begin
  try
    GExe := ParamStr(1);
    if GExe = '' then
      GExe := TPath.GetFullPath(TPath.Combine(
        ExtractFilePath(ParamStr(0)), cDefaultExeRel));
    GFixtureDir := TPath.Combine(
      TPath.GetDirectoryName(ParamStr(0)), '..\fixtures');
    GFixtureDir := TPath.GetFullPath(GFixtureDir);

    Writeln('server:   ' + GExe);
    Writeln('fixtures: ' + GFixtureDir);
    if not TFile.Exists(TPath.Combine(GFixtureDir, 'DemoApp.dpr')) then
      raise Exception.Create('fixtures not found next to the test exe');

    GFailures := 0;
    GClient := TLspClient.Create(GExe, ExtractFilePath(GExe),
      procedure(const AText: string)
      begin
        Writeln('  [log] ' + AText);
      end);
    try
      GClient.OnNotification :=
        procedure(const AMethod: string; AParams: TJSONValue)
        begin
          // Diagnostics arrive unprompted; just show that they do.
          Writeln('  [notify] ' + AMethod);
        end;
      // The seam the real document layer uses: a restarted server starts with
      // no open documents, so they are re-sent on every handshake.
      GClient.OnReady := ReopenAll;

      TestQueuedBeforeReady(GExe);
      TestNavigation;
      TestNonAsciiPositions;
      TestBomIsNotContent;
      TestOverlayBeatsDisk;
      TestCompletion;
      TestHover;
      TestSignatureHelp;
      TestDocumentSymbol;
      TestClassComplete;
      TestWorkspaceSymbol;
      TestCancelHygiene;
      // These three each kill or replace the server, so they go last.
      TestLazyRestart;
      TestRestartOnConfigChange(GExe);
      TestDeathDuringHandshake(GExe);
    finally
      Writeln;
      Writeln('stopping client');
      FreeAndNil(GClient);
      Writeln('stopped');
    end;

    Writeln;
    if GFailures = 0 then
      Writeln('RESULT: PASS')
    else
      Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := Ord(GFailures <> 0);
  except
    on E: Exception do
    begin
      Writeln(Format('RESULT: FAIL - %s: %s', [E.ClassName, E.Message]));
      ExitCode := 2;
    end;
  end;
end.
