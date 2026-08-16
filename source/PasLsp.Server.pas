unit PasLsp.Server;

{
  The LSP state machine, phase 1 (SPEC.md): lifecycle, full-sync document
  events, textDocument/definition. One message at a time, analysis runs
  synchronously on the dispatch thread — asynchrony and $/cancelRequest are
  phase 2, and the PasTree side (mid-pass cancellation) is already in place
  for it.

  Project state: one TPasSemaProject + TPasNavigator pair, rebuilt lazily —
  any document event only marks it dirty; the next definition request pays
  for the re-analysis, with the requested file front-loaded (AnalyzeStaged's
  APriority). The same shape as the IDE plugin's BuildNavigator cache.

  Configuration comes from initialize's initializationOptions — an object
  with these keys (all optional):
    "projectFile" — path to a .dproj (or a bare .dpr)
    "platform"    — e.g. "Win64", overrides the project's own
    "config"      — build configuration name, .dproj only
    "searchPaths", "defines" — string arrays, appended after the project's
  A .dproj brings its own MainSource/search paths/defines/namespaces/aliases
  (TPasDProj — the same MSBuild evaluation the CLI tools use). Without a
  projectFile the open documents themselves become the analysis roots.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.JSON,
  System.IOUtils,
  PasTree.Platforms,
  PasTree.DProj,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav,
  PasLsp.Protocol,
  PasLsp.Documents;

type
  TLspServer = class
  private
    FInitialized: Boolean;
    FShutdownSeen: Boolean;
    FExitRequested: Boolean;
    FExitCode: Integer;
    FTrace: Boolean;
    FLogPath: string;
    FLogStarted: Boolean;
    FDocs: TLspDocumentStore;
    FOutgoing: TList<string>;   // notifications queued during Handle
    // Configuration (fixed at initialize)
    FPlatform: TPasPlatform;
    FMainSource: string;
    FSearchPaths: TArray<string>;
    FDefines: TArray<string>;
    FNamespaces: TArray<string>;
    FAliases: TArray<TPasUnitAlias>;
    // Analysis cache
    FProject: TPasSemaProject;
    FNav: TPasNavigator;
    FDirty: Boolean;
    procedure Log(const AMsg: string);
    procedure Notify(const AJson: string);
    procedure ApplyInitOptions(AOptions: TJSONValue);
    procedure InvalidateAnalysis;
    procedure EnsureAnalyzed(const APriorityFile: string);
    procedure PublishDiagnostics;
    procedure PublishEmptyDiagnostics(const APath: string);
    function DocPathOf(AParams: TJSONValue): string;
    function HandleInitialize(const AMsg: TLspIncoming): string;
    function HandleDefinition(const AMsg: TLspIncoming): string;
    procedure HandleDidOpen(AParams: TJSONValue);
    procedure HandleDidChange(AParams: TJSONValue);
    procedure HandleDidClose(AParams: TJSONValue);
  public
    constructor Create;
    destructor Destroy; override;
    { Dispatches one raw JSON message; returns the response to send, or ''
      for notifications (and for client responses we ignore). Never raises:
      a handler exception becomes a JSON-RPC InternalError for requests and
      a stderr line for notifications. }
    function Handle(const AJson: string): string;
    { Server-initiated notifications produced while handling the last
      message (publishDiagnostics, ...) — the caller sends each and the
      queue resets. Drained AFTER the Handle reply by the main loop; order
      within the queue is preserved. }
    function TakeOutgoing: TArray<string>;
    property ExitRequested: Boolean read FExitRequested;
    property ExitCode: Integer read FExitCode;
  end;

implementation

constructor TLspServer.Create;
begin
  inherited Create;
  FDocs := TLspDocumentStore.Create;
  FOutgoing := TList<string>.Create;
  FPlatform := pfWin64;
  FTrace := GetEnvironmentVariable('PASTREE_LSP_TRACE') <> '';
  FLogPath := GetEnvironmentVariable('PASTREE_LSP_LOG');
end;

destructor TLspServer.Destroy;
begin
  InvalidateAnalysis;
  FOutgoing.Free;
  FDocs.Free;
  inherited;
end;

{ Diagnostics channel for the server ITSELF (not the analyzer — those go to
  the client as publishDiagnostics): stderr when PASTREE_LSP_TRACE is set
  (LSP clients capture stderr; VS Code shows it in the Output panel), and a
  file when a path is configured — PASTREE_LSP_LOG env var or the "logFile"
  initializationOption, the latter winning. The file survives the client
  swallowing stderr, which is exactly the situation a transport bug puts you
  in. Append per line, open/close each time: crash-safe, and the volume is
  a handful of lines per request. }
procedure TLspServer.Log(const AMsg: string);
var
  LLine: string;
begin
  if FTrace then
    Writeln(ErrOutput, '[pastree-lsp] ' + AMsg);
  if FLogPath = '' then
    Exit;
  LLine := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + AMsg +
    sLineBreak;
  try
    if not FLogStarted then
    begin
      // Separator instead of truncation: successive runs stay in one file,
      // and "which run is this" stays answerable.
      TFile.AppendAllText(FLogPath,
        StringOfChar('-', 64) + sLineBreak + LLine, TEncoding.UTF8);
      FLogStarted := True;
    end
    else
      TFile.AppendAllText(FLogPath, LLine, TEncoding.UTF8);
  except
    FLogPath := '';   // an unwritable log must not take the server down
  end;
end;

procedure TLspServer.Notify(const AJson: string);
begin
  FOutgoing.Add(AJson);
end;

function TLspServer.TakeOutgoing: TArray<string>;
begin
  Result := FOutgoing.ToArray;
  FOutgoing.Clear;
end;

procedure TLspServer.InvalidateAnalysis;
begin
  FreeAndNil(FNav);
  FreeAndNil(FProject);
  FDirty := True;
end;

{ -------- configuration -------- }

procedure TLspServer.ApplyInitOptions(AOptions: TJSONValue);
var
  LProjectFile, LPlatformStr, LConfigStr, LItem: string;
  LArr: TJSONArray;
  LVal: TJSONValue;
  LDProj: TPasDProj;
  LAlias: TPasUnitAlias;
  LDef: TPasUnitAliasDef;
begin
  LProjectFile := '';
  LPlatformStr := '';
  LConfigStr := '';
  if AOptions is TJSONObject then
  begin
    LProjectFile := AOptions.GetValue<string>('projectFile', '');
    LPlatformStr := AOptions.GetValue<string>('platform', '');
    LConfigStr := AOptions.GetValue<string>('config', '');
    LItem := AOptions.GetValue<string>('logFile', '');
    if LItem <> '' then
      FLogPath := LItem;   // beats PASTREE_LSP_LOG: per-workspace over global
  end;

  if not ((LPlatformStr = '') or
    TryParsePlatformName(LPlatformStr, FPlatform)) then
    Log('unknown platform "' + LPlatformStr + '", defaulting to Win64');

  if (LProjectFile <> '') and
     SameText(TPath.GetExtension(LProjectFile), '.dproj') then
  begin
    LDProj := TPasDProj.Create;
    try
      if LDProj.Load(LProjectFile, LPlatformStr, LConfigStr) then
      begin
        FMainSource := LDProj.MainSource;
        FPlatform := LDProj.Platform;
        FSearchPaths := LDProj.SearchPaths;
        FDefines := LDProj.Defines;
        // Project namespaces first, then the IDE defaults the .dproj file
        // itself never spells out (they live in the IDE's targets file).
        FNamespaces := LDProj.Namespaces + PasDefaultNamespaces(FPlatform);
        // Defaults FIRST, project entries after: AddUnitAlias overwrites on
        // collision, which gives the project the last word (dcc semantics —
        // see PasDefaultUnitAliases' own comment).
        FAliases := nil;
        for LDef in PasDefaultUnitAliases(FPlatform) do
        begin
          LAlias.Alias := LDef.Alias;
          LAlias.UnitName := LDef.UnitName;
          FAliases := FAliases + [LAlias];
        end;
        FAliases := FAliases + LDProj.UnitAliases;
      end
      else
        Log('failed to load project file: ' + LProjectFile);
    finally
      LDProj.Free;
    end;
  end
  else if LProjectFile <> '' then
  begin
    // A bare .dpr root: no MSBuild properties to evaluate — IDE-default
    // namespaces/aliases (see PasDefaultNamespaces: dcc itself has none,
    // they come from the project template).
    FMainSource := TPath.GetFullPath(LProjectFile);
    FNamespaces := PasDefaultNamespaces(FPlatform);
    FAliases := nil;
    for LDef in PasDefaultUnitAliases(FPlatform) do
    begin
      LAlias.Alias := LDef.Alias;
      LAlias.UnitName := LDef.UnitName;
      FAliases := FAliases + [LAlias];
    end;
  end
  else
    FNamespaces := PasDefaultNamespaces(FPlatform);

  // Extra searchPaths/defines from the client, appended after the project's.
  if AOptions is TJSONObject then
  begin
    if AOptions.TryGetValue<TJSONArray>('searchPaths', LArr) then
      for LVal in LArr do
        if LVal.TryGetValue<string>(LItem) then
          FSearchPaths := FSearchPaths + [LItem];
    if AOptions.TryGetValue<TJSONArray>('defines', LArr) then
      for LVal in LArr do
        if LVal.TryGetValue<string>(LItem) then
          FDefines := FDefines + [LItem];
  end;
  Log(Format('configured: platform=%s main=%s paths=%d defines=%d',
    [PlatformName(FPlatform), FMainSource, Length(FSearchPaths),
     Length(FDefines)]));
end;

{ -------- analysis -------- }

procedure TLspServer.EnsureAnalyzed(const APriorityFile: string);
var
  LRoots, LPriority: TArray<string>;
  LDoc: TLspDocument;
  LAlias: TPasUnitAlias;
begin
  if (FProject <> nil) and not FDirty then
    Exit;
  InvalidateAnalysis;
  FProject := TPasSemaProject.Create(FPlatform, FSearchPaths, FDefines);
  FProject.SetNamespaces(FNamespaces);
  for LAlias in FAliases do
    FProject.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
  // Document truth: every open document overlays its disk file, stamped
  // with the client's version (readable back for staleness checks once
  // requests go asynchronous in phase 2).
  for LDoc in FDocs.All do
    FProject.SetBuffer(LDoc.Path, LDoc.Text, LDoc.Version);

  if FMainSource <> '' then
    LRoots := [FMainSource]
  else
  begin
    LRoots := nil;
    for LDoc in FDocs.All do
      LRoots := LRoots + [LDoc.Path];
  end;
  if APriorityFile <> '' then
    LPriority := [APriorityFile]
  else
    LPriority := nil;

  Log(Format('analyzing (%d roots, %d overlays)...',
    [Length(LRoots), FDocs.Count]));
  FProject.AnalyzeStaged(LRoots, LPriority, nil, nil);
  FNav := TPasNavigator.Create(FProject);
  FDirty := False;
  Log('analysis done');
  PublishDiagnostics;
end;

// LSP DiagnosticSeverity from a PasTree diagnostic code. E/F are dcc's own
// error classes; W maps to warning; everything else (PPIF/PPBAD/PPENC/PPINT,
// our own "the ANALYZER could not decide" family) is information — calling
// those errors in the USER's code would be a lie (the demo draws the same
// line, DiagSeverityLabel).
function DiagSeverity(const ACode: string): Integer;
begin
  if (ACode <> '') and CharInSet(ACode[1], ['E', 'F']) then
    Result := 1   // Error
  else if (ACode <> '') and (ACode[1] = 'W') then
    Result := 2   // Warning
  else
    Result := 3;  // Information
end;

{ Analyzer diagnostics -> the client, as textDocument/publishDiagnostics for
  every OPEN document (phase 1 scope: the whole-closure report stays a
  phase-3 concern — an editor shows squiggles for what the user is looking
  at, and open docs keep the volume bounded on a big project). Publishing
  for every open doc every time — including an EMPTY array when a doc has
  none — is what clears stale squiggles after a fixing edit; LSP has no
  "unchanged" shorthand. A diagnostic raised inside an $I include is matched
  by the include's own FileId path, so it lands on the include's buffer if
  that file is open, and is dropped otherwise (its unit's main file is the
  wrong place to draw it). }
procedure TLspServer.PublishDiagnostics;
var
  LDoc: TLspDocument;
  LMid, LIdx, LFileId, LLine, LChar: Integer;
  LModel: TPasSemaModel;
  LDiagFile, LKey: string;
  LSB: TStringBuilder;
  LFirst: Boolean;
begin
  for LDoc in FDocs.All do
  begin
    LMid := FNav.ModelIdOf(LDoc.Path);
    LSB := TStringBuilder.Create;
    try
      LFirst := True;
      if LMid >= 0 then
      begin
        LModel := FProject.Model(LMid);
        LKey := LowerCase(LDoc.Path);
        for LIdx := 0 to High(LModel.Diags) do
        begin
          // FileId indexes the MODEL'S own file table ($I includes) — see
          // the demo's ReportProjectResult for why assuming the main file
          // misplaces include diagnostics.
          LFileId := LModel.Diags[LIdx].FileId;
          if (LFileId >= 0) and
             (LFileId <= High(LModel.Tree.Source.FileNames)) then
            LDiagFile := LModel.Tree.Source.FileNames[LFileId]
          else
            LDiagFile := FProject.ModelFile(LMid);
          if LowerCase(TPath.GetFullPath(LDiagFile)) <> LKey then
            Continue;
          if not LFirst then
            LSB.Append(',');
          LFirst := False;
          PasTreeToLsp(LModel.Diags[LIdx].Line, LModel.Diags[LIdx].Col,
            LLine, LChar);
          LSB.Append(Format(
            '{"range":{"start":{"line":%d,"character":%d},' +
            '"end":{"line":%d,"character":%d}},' +
            '"severity":%d,"code":%s,"source":"pastree","message":%s}',
            [LLine, LChar, LLine, LChar + 1,
             DiagSeverity(LModel.Diags[LIdx].Code),
             JsonQuote(LModel.Diags[LIdx].Code),
             JsonQuote(LModel.Diags[LIdx].Msg)]));
        end;
      end;
      Notify(Format(
        '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",' +
        '"params":{"uri":%s,"version":%d,"diagnostics":[%s]}}',
        [JsonQuote(PathToUri(LDoc.Path)), LDoc.Version, LSB.ToString]));
    finally
      LSB.Free;
    end;
  end;
end;

// didClose: the client owns no more squiggles for this doc — clear them.
procedure TLspServer.PublishEmptyDiagnostics(const APath: string);
begin
  Notify(Format(
    '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",' +
    '"params":{"uri":%s,"diagnostics":[]}}',
    [JsonQuote(PathToUri(APath))]));
end;

{ -------- handlers -------- }

function TLspServer.HandleInitialize(const AMsg: TLspIncoming): string;
begin
  if AMsg.Params <> nil then
    ApplyInitOptions(AMsg.Params.FindValue('initializationOptions'))
  else
    ApplyInitOptions(nil);
  FInitialized := True;
  Result := BuildResponse(AMsg.IdJson,
    '{"capabilities":{' +
      '"positionEncoding":"utf-16",' +
      '"textDocumentSync":{"openClose":true,"change":1},' +   // 1 = Full
      '"definitionProvider":true' +
    '},"serverInfo":{"name":"pastree-lsp-server","version":"0.1.0"}}');
end;

// textDocument.uri of AParams -> full Windows path ('' if absent/non-file).
function TLspServer.DocPathOf(AParams: TJSONValue): string;
var
  LUri: string;
begin
  Result := '';
  if (AParams <> nil) and
     AParams.TryGetValue<string>('textDocument.uri', LUri) then
    Result := UriToPath(LUri);
end;

procedure TLspServer.HandleDidOpen(AParams: TJSONValue);
var
  LPath, LText: string;
  LVersion: Integer;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  LText := AParams.GetValue<string>('textDocument.text', '');
  LVersion := AParams.GetValue<Integer>('textDocument.version', 0);
  FDocs.Open(LPath, LText, LVersion);
  FDirty := True;
  Log(Format('didOpen %s v%d', [LPath, LVersion]));
  // Analyze eagerly so diagnostics appear without waiting for a request.
  // Synchronous — acceptable at phase 1 (SPEC.md); the async session +
  // debounce + $/cancelRequest wiring is phase 2's whole point.
  EnsureAnalyzed(LPath);
end;

procedure TLspServer.HandleDidChange(AParams: TJSONValue);
var
  LPath, LText: string;
  LVersion: Integer;
  LChanges: TJSONArray;
  LLast: TJSONValue;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  if not AParams.TryGetValue<TJSONArray>('contentChanges', LChanges) or
     (LChanges.Count = 0) then
    Exit;
  // Full sync: the last change wins outright (we advertised change=1, so a
  // conforming client sends exactly one full-text change anyway).
  LLast := LChanges.Items[LChanges.Count - 1];
  if not LLast.TryGetValue<string>('text', LText) then
    Exit;
  LVersion := AParams.GetValue<Integer>('textDocument.version', 0);
  FDocs.Change(LPath, LText, LVersion);
  FDirty := True;
  Log(Format('didChange %s v%d (%d chars)',
    [LPath, LVersion, Length(LText)]));
  EnsureAnalyzed(LPath);   // see HandleDidOpen — synchronous until phase 2
end;

procedure TLspServer.HandleDidClose(AParams: TJSONValue);
var
  LPath: string;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  FDocs.Close(LPath);
  FDirty := True;   // the disk file is the truth again
  PublishEmptyDiagnostics(LPath);
  Log('didClose ' + LPath);
end;

function TLspServer.HandleDefinition(const AMsg: TLspIncoming): string;
var
  LPath: string;
  LLine, LChar, LPasLine, LPasCol, LMid: Integer;
  LIdent: TPasNavIdent;
  LTarget: TPasNavTarget;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'definition: textDocument.uri and position required'));

  EnsureAnalyzed(LPath);
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
  begin
    Log('definition: file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) and
     FNav.ResolveDecl(LMid, LIdent.Node, LTarget) then
    Result := BuildResponse(AMsg.IdJson,
      LocationJson(LTarget.FilePath, LTarget.Line, LTarget.Col,
        Length(LTarget.Name)))
  else
    Result := BuildResponse(AMsg.IdJson, 'null');
end;

{ -------- dispatch -------- }

function TLspServer.Handle(const AJson: string): string;
var
  LMsg: TLspIncoming;
begin
  Result := '';
  if not ParseIncoming(AJson, LMsg) then
    Exit(BuildError('', LSP_PARSE_ERROR, 'malformed JSON'));
  try
    try
      // A response from the client (id, no method) — phase 1 sends no
      // client-bound requests, so nothing to correlate; ignore.
      if LMsg.Method = '' then
        Exit;

      if LMsg.Method = 'initialize' then
        Exit(HandleInitialize(LMsg));
      if LMsg.Method = 'exit' then
      begin
        FExitRequested := True;
        // Spec: 0 only if shutdown was seen first.
        if FShutdownSeen then
          FExitCode := 0
        else
          FExitCode := 1;
        Exit;
      end;
      if not FInitialized then
      begin
        if LMsg.IsRequest then
          Exit(BuildError(LMsg.IdJson, LSP_SERVER_NOT_INITIALIZED,
            'server not initialized'));
        Exit;   // pre-initialize notifications are dropped by spec
      end;

      if LMsg.Method = 'initialized' then
        Exit;
      if LMsg.Method = 'shutdown' then
      begin
        FShutdownSeen := True;
        InvalidateAnalysis;
        Exit(BuildResponse(LMsg.IdJson, 'null'));
      end;
      if LMsg.Method = 'textDocument/didOpen' then
      begin
        HandleDidOpen(LMsg.Params);
        Exit;
      end;
      if LMsg.Method = 'textDocument/didChange' then
      begin
        HandleDidChange(LMsg.Params);
        Exit;
      end;
      if LMsg.Method = 'textDocument/didClose' then
      begin
        HandleDidClose(LMsg.Params);
        Exit;
      end;
      if LMsg.Method = 'textDocument/didSave' then
        Exit;   // we advertise no save interest; harmless if sent anyway
      if LMsg.Method = 'textDocument/definition' then
        Exit(HandleDefinition(LMsg));
      if LMsg.Method.StartsWith('$/') then
        Exit;   // optional protocol extensions ($/cancelRequest et al):
                // droppable by spec until phase 2 makes cancel meaningful

      if LMsg.IsRequest then
        Result := BuildError(LMsg.IdJson, LSP_METHOD_NOT_FOUND,
          'method not supported: ' + LMsg.Method);
    except
      on E: Exception do
      begin
        Log('EXCEPTION in ' + LMsg.Method + ': ' + E.ClassName + ': ' +
          E.Message);
        if LMsg.IsRequest then
          Result := BuildError(LMsg.IdJson, LSP_INTERNAL_ERROR,
            E.ClassName + ': ' + E.Message)
        else
          Result := '';
      end;
    end;
  finally
    LMsg.Root.Free;
  end;
end;

end.
