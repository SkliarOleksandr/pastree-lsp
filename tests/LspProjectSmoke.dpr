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
  cDefaultExe = 'C:\Repos\pastree-lsp-server\out\pastree-server.exe';
  // Parsing the RTL, the VCL and ToolsAPI is not a fixture-sized job.
  cAnswerTimeoutMs = 180000;

var
  GClient: TLspClient;
  GRepoDir: string;
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
end;

procedure Run(const AExe, AIdeRoot: string);
var
  LWizard: string;
  LLine, LChar: Integer;
begin
  LWizard := TPath.Combine(GRepoDir, 'PasTreeIdePlugin.Wizard.pas');

  Check(GClient.Start(BuildOptions(AIdeRoot)), 'server started');
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
      GExe := cDefaultExe;
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
