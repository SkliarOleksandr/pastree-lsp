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
  cDefaultExe = 'C:\Repos\pastree-lsp-server\out\pastree-server.exe';
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
procedure FindPos(const AFile, ALineHint, AToken: string;
  out ALine, AChar: Integer);
var
  LLines: TArray<string>;
  I, LCol: Integer;
begin
  LLines := TFile.ReadAllLines(AFile);
  for I := 0 to High(LLines) do
    if LLines[I].Contains(ALineHint) then
    begin
      LCol := Pos(AToken, LLines[I]);
      if LCol = 0 then
        raise Exception.CreateFmt('fixture %s: no "%s" on the line with "%s"',
          [AFile, AToken, ALineHint]);
      ALine := I;
      AChar := LCol - 1;   // Pos is 1-based, LSP characters are 0-based
      Exit;
    end;
  raise Exception.CreateFmt('fixture %s: no line containing "%s"',
    [AFile, ALineHint]);
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

procedure SendDidOpen(const AFile: string);
var
  LParams, LDoc: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFile));
  LDoc.AddPair('languageId', 'pascal');
  LDoc.AddPair('version', TJSONNumber.Create(1));
  LDoc.AddPair('text', TFile.ReadAllText(AFile));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  GClient.Notify('textDocument/didOpen', LParams);
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

var
  GExe: string;
begin
  try
    GExe := ParamStr(1);
    if GExe = '' then
      GExe := cDefaultExe;
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
      TestLazyRestart;
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
