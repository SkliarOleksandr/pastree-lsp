program LspProjectSmoke;

{
  The harvest check: drives the server with EXACTLY the configuration
  PasTreeIdePlugin.LspSession sends - this package's own .dproj, its platform
  and configuration, plus the IDE's RTL/VCL/ToolsAPI source directories as
  extra searchPaths - and then asks for declarations that can only resolve if
  each of those parts arrived intact.

  Why this is worth its own harness. LspClientSmoke proves the session against
  a two-file fixture, which says nothing about the two decisions the session
  layer actually makes: handing the server the .dproj verbatim instead of
  resolving the real .dpr/.dpk by naming convention, and passing the IDE source
  paths that no .dproj lists. Both are exactly the kind of thing that fails
  silently - navigation just quietly resolves nothing - which is what this
  repo's README already records happening before those paths were added.

  The three targets are chosen to fail separately:
    TActionList  - the VCL search path
    IOTAWizard   - the ToolsAPI search path
    TMenuManager - the project itself, via the .dproj's own MainSource

  Usage: LspProjectSmoke.exe [path\to\pastree-server.exe] [IDE root dir]
  The IDE root defaults to %BDS% (rsvars.bat sets it).
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
  // Parsing the RTL, the VCL and ToolsAPI is not a fixture-sized job.
  cAnswerTimeoutMs = 180000;

var
  GClient: TLspClient;
  GRepoDir: string;
  GLogPath: string;
  GFailures: Integer;
  GAnswered: Boolean;
  GOk: Boolean;
  GResultJson: string;
  GError: string;

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

{ The server's own log, read while it is being written to - hence the
  share-everything open: the server holds an append handle on this file, and
  a plain ReadAllText would lose the race as a sharing violation. }
function LogContains(const AText: string): Boolean;
var
  LStream: TFileStream;
  LBytes: TBytes;
begin
  Result := False;
  if not TFile.Exists(GLogPath) then
    Exit;
  try
    LStream := TFileStream.Create(GLogPath, fmOpenRead or fmShareDenyNone);
  except
    Exit;   // being written to this instant; the caller polls again
  end;
  try
    SetLength(LBytes, LStream.Size);
    if Length(LBytes) > 0 then
      LStream.ReadBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  Result := TEncoding.UTF8.GetString(LBytes).Contains(AText);
end;

function Ask(const AMethod: string; AParams: TJSONObject): Boolean;
var
  LStart: UInt64;
begin
  GAnswered := False;
  GOk := False;
  GResultJson := '';
  GError := '';
  LStart := GetTickCount64;
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
    Writeln(Format('  !! no answer to %s within %d ms',
      [AMethod, cAnswerTimeoutMs]))
  else
    Writeln(Format('  -- %s in %d ms -> %s', [AMethod,
      GetTickCount64 - LStart, Copy(GResultJson + GError, 1, 200)]));
end;

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
        raise Exception.CreateFmt('%s: no "%s" on the line with "%s"',
          [AFile, AToken, ALineHint]);
      ALine := I;
      AChar := LCol - 1;
      Exit;
    end;
  raise Exception.CreateFmt('%s: no line containing "%s"',
    [AFile, ALineHint]);
end;

function PositionParams(const AFile: string;
  ALine, AChar: Integer): TJSONObject;
var
  LDoc, LPos: TJSONObject;
begin
  Result := TJSONObject.Create;
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFile));
  Result.AddPair('textDocument', LDoc);
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(ALine));
  LPos.AddPair('character', TJSONNumber.Create(AChar));
  Result.AddPair('position', LPos);
end;

procedure DidOpen(const AFile: string);
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
/// The same options TLspSession.BuildOptions produces, assembled the same way:
/// the .dproj verbatim, the normalised platform, the active configuration, and
/// the IDE source paths the .dproj cannot supply.
/// </summary>
function BuildOptions(const AIdeRoot: string): TLspInitOptions;
var
  LSource: string;
begin
  Result := Default(TLspInitOptions);
  Result.ProjectFile := TPath.Combine(GRepoDir, 'PasTreeIdePlugin.dproj');
  Result.Platform := 'Win32';   // a designtime package is always Win32
  Result.Config := 'Debug';
  LSource := IncludeTrailingPathDelimiter(AIdeRoot) + 'source\';
  Result.SearchPaths := [LSource + 'rtl', LSource + 'vcl',
    LSource + 'ToolsAPI'];
  Result.LogFile := TPath.Combine(TPath.GetTempPath,
    'pastree-lsp-projectsmoke.log');
  GLogPath := Result.LogFile;
end;

procedure Run(const AExe, AIdeRoot: string);
var
  LWizard: string;
  LLine, LChar: Integer;
  LOptions: TLspInitOptions;
begin
  LWizard := TPath.Combine(GRepoDir, 'PasTreeIdePlugin.Wizard.pas');

  LOptions := BuildOptions(AIdeRoot);
  // Emptied rather than appended to: every check below asks whether THIS run
  // wrote a line, and the server's own run separator is not something a
  // Contains() can tell one side of.
  try
    TFile.WriteAllText(LOptions.LogFile, '');
  except
    // Held open by a previous run's server; the checks below still work,
    // they simply cannot distinguish this run's lines from that one's.
  end;
  Check(GClient.Start(LOptions), 'server started');

  Writeln;
  Writeln('=== the project alone starts the analysis ===');
  { NOTHING IS SENT HERE - no didOpen, no request. That is the whole check:
    the client hands over a projectFile at initialize and the closure is
    parsed on the strength of that, so the user's first Ctrl+Click is fast
    rather than being the thing that pays for the build. Before this, the
    first request (or the first didOpen) was what started it, and in RAD
    Studio neither happens until the user does something. }
  Check(PumpUntil(function: Boolean
      begin Result := LogContains('analysis done') end, cAnswerTimeoutMs),
    'the analysis ran with no request and no document open');

  DidOpen(LWizard);

  Writeln;
  Writeln('=== the VCL search path: TActionList ===');
  FindPos(LWizard, 'FActionList: TActionList', 'TActionList', LLine, LChar);
  Check(Ask('textDocument/definition', PositionParams(LWizard, LLine, LChar)),
    'definition answered');
  Check(GOk and GResultJson.ToLower.Contains('actnlist'),
    'TActionList resolves into Vcl.ActnList');

  Writeln;
  Writeln('=== the ToolsAPI search path: IOTAWizard ===');
  FindPos(LWizard, 'TNotifierObject, IOTAWizard', 'IOTAWizard', LLine, LChar);
  Check(Ask('textDocument/definition', PositionParams(LWizard, LLine, LChar)),
    'definition answered');
  Check(GOk and GResultJson.ToLower.Contains('toolsapi'),
    'IOTAWizard resolves into ToolsAPI');

  Writeln;
  Writeln('=== the project itself, via the .dproj MainSource: TMenuManager ===');
  FindPos(LWizard, 'FMenuManager: TMenuManager', 'TMenuManager', LLine, LChar);
  Check(Ask('textDocument/definition', PositionParams(LWizard, LLine, LChar)),
    'definition answered');
  Check(GOk and GResultJson.ToLower.Contains('wizard.pas'),
    'TMenuManager resolves inside the package''s own unit');
end;

var
  GExe, GIdeRoot: string;
begin
  try
    GExe := ParamStr(1);
    if GExe = '' then
      GExe := TPath.GetFullPath(TPath.Combine(
        ExtractFilePath(ParamStr(0)), cDefaultExeRel));
    GIdeRoot := ParamStr(2);
    if GIdeRoot = '' then
      GIdeRoot := GetEnvironmentVariable('BDS');
    if GIdeRoot = '' then
      raise Exception.Create('pass the IDE root directory, or run under '
        + 'rsvars.bat so %BDS% is set');

    GRepoDir := TPath.GetFullPath(TPath.Combine(
      TPath.GetDirectoryName(ParamStr(0)), '..\..'));

    Writeln('server:   ' + GExe);
    Writeln('IDE root: ' + GIdeRoot);
    Writeln('repo:     ' + GRepoDir);
    if not TFile.Exists(TPath.Combine(GRepoDir, 'PasTreeIdePlugin.dproj')) then
      raise Exception.Create('PasTreeIdePlugin.dproj not found at ' + GRepoDir);

    GFailures := 0;
    GClient := TLspClient.Create(GExe, ExtractFilePath(GExe),
      procedure(const AText: string)
      begin
        Writeln('  [log] ' + AText);
      end);
    try
      Run(GExe, GIdeRoot);
    finally
      FreeAndNil(GClient);
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
