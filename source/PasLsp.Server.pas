unit PasLsp.Server;

{
  The LSP state machine: lifecycle, incremental document sync, and the
  navigation/diagnostics requests (SPEC.md phases 1-2). One message at a
  time on the dispatcher thread; the ANALYSIS runs on a background
  TPasAsyncSession, so a request that needs a fresh build waits on it while
  the reader thread keeps noting $/cancelRequest.

  Project state: one TPasSemaProject + TPasNavigator pair, kept across
  requests (this IS the analysis cache — the same shape as the IDE plugin's
  BuildNavigator cache). A document event only SCHEDULES a rebuild, and only
  when the text actually differs from what was analyzed; the previous project
  keeps answering until the new one is ready.

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
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.Generics.Collections,
  System.JSON,
  System.IOUtils,
  System.Hash,
  PasTree.Platforms,
  PasTree.DProj,
  PasTree.SourceManager,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Async,
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
    // Analysis state (phase 2, all touched by the DISPATCHER thread only:
    // the async session's worker builds its own project in isolation —
    // TPasAsyncSession's double-buffering contract).
    FProject: TPasSemaProject;      // last COMPLETED analysis (may be nil)
    FNav: TPasNavigator;
    FSession: TPasAsyncSession;     // in-flight analysis, nil when idle
    FDirty: Boolean;                // docs changed since FSession started
    FCancels: TLspCancelSet;        // shared with the reader thread
    // Debounce: document events SCHEDULE an analysis rather than start one,
    // so a keystroke burst costs one build, not one per keystroke. The idle
    // tick fires it when the deadline passes; a REQUEST fires it instantly
    // (the user stopped typing and asked a question — the answer must be
    // computed from the text they see, not the pre-burst snapshot).
    FPendingDue: UInt64;            // GetTickCount64 deadline; 0 = nothing
    FPendingPriority: string;
    FBuildStart: UInt64;            // for the analysis-done log line
    // The overlay signature the LAST COMPLETED analysis was built from - the
    // backstop that keeps a scheduled rebuild from running when the inputs
    // came back to what is already analyzed (an edit typed and undone).
    FBuiltSignature: string;
    FStartedSignature: string;
    // The client process, watched so a dead client cannot leave this one
    // running (see StartClientWatchdog); 0 = not watching.
    FClientHandle: THandle;
    // Work-done progress (server-initiated). Reporting is gated on the
    // client's window.workDoneProgress capability, and the token is created
    // with a REQUEST the client may refuse - see StartProgress.
    FClientProgress: Boolean;     // client supports server-initiated progress
    FProgressToken: string;       // '' = no progress stream open
    FProgressCreateId: Integer;   // id of the create request awaiting a reply
    FNextServerId: Integer;       // our own id space for server->client calls
    FProgressSeq: Integer;        // makes each token unique within a session
    FLastReportTick: UInt64;
    procedure Log(const AMsg: string);
    procedure Notify(const AJson: string);
    procedure StartClientWatchdog(APid: Integer);
    function FileMatches(const APath, AText, ADiskText: string): Boolean;
    function OverlaySignature: string;
    procedure StartProgress(const ATitle: string);
    procedure ReportProgress;
    procedure EndProgress(const AMessage: string);
    procedure Tell(AType: Integer; const AMsg: string; AShow: Boolean = False);
    function ClientGone: Boolean;
    procedure ApplyInitOptions(AOptions: TJSONValue);
    procedure InvalidateAnalysis;
    procedure StartAnalysis(const APriorityFile: string);
    procedure ScheduleAnalysis(const APriorityFile: string);
    procedure FlushPending;
    procedure FinalizeAnalysisIfDone;
    { Blocks until an up-to-date analysis is available, staying responsive
      to $/cancelRequest for ARequestIdJson. False = that request was
      cancelled while waiting (the caller answers -32800). }
    function WaitAnalyzed(const APriorityFile,
      ARequestIdJson: string): Boolean;
    procedure PublishDiagnostics;
    procedure PublishEmptyDiagnostics(const APath: string);
    function DocPathOf(AParams: TJSONValue): string;
    function HandleInitialize(const AMsg: TLspIncoming): string;
    function HandleDefinition(const AMsg: TLspIncoming): string;
    function HandleReferences(const AMsg: TLspIncoming): string;
    function HandleToggle(const AMsg: TLspIncoming;
      AToImpl: Boolean): string;
    function HandleDocumentSymbol(const AMsg: TLspIncoming): string;
    function HandleHover(const AMsg: TLspIncoming): string;
    function HandleTypeDefinition(const AMsg: TLspIncoming): string;
    function HandleDocumentHighlight(const AMsg: TLspIncoming): string;
    procedure HandleDidOpen(AParams: TJSONValue);
    procedure HandleDidChange(AParams: TJSONValue);
    procedure HandleDidClose(AParams: TJSONValue);
    procedure HandleDidChangeWatchedFiles(AParams: TJSONValue);
  public
    { ACancels is the reader thread's cancel set; not owned. }
    constructor Create(ACancels: TLspCancelSet);
    destructor Destroy; override;
    { The dispatcher's idle tick (no message for ~50ms): finalizes a finished
      background analysis so diagnostics go out without waiting for the next
      request. }
    procedure Idle;
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

constructor TLspServer.Create(ACancels: TLspCancelSet);
begin
  inherited Create;
  FCancels := ACancels;
  FDocs := TLspDocumentStore.Create;
  FOutgoing := TList<string>.Create;
  FPlatform := pfWin64;
  FTrace := GetEnvironmentVariable('PASTREE_LSP_TRACE') <> '';
  FLogPath := GetEnvironmentVariable('PASTREE_LSP_LOG');
end;

destructor TLspServer.Destroy;
begin
  if FClientHandle <> 0 then
    CloseHandle(FClientHandle);
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
  if FSession <> nil then
  begin
    FSession.Cancel;
    FreeAndNil(FSession);   // Destroy drains the worker — quick, the cancel
                            // lands mid-pass (FCancelCheck in PasTree)
  end;
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
        Tell(1, 'PasTree: failed to load the project file ' + LProjectFile,
          True);
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
  // A present-but-not-an-array value is CALLED OUT rather than skipped
  // silently: this exact shape cost a debugging round (PowerShell 5.1's
  // ConvertTo-Json wraps arrays into a value/Count object, the option
  // vanished, and the only symptom was navigation quietly not reaching the
  // RTL).
  if AOptions is TJSONObject then
  begin
    if AOptions.TryGetValue<TJSONArray>('searchPaths', LArr) then
    begin
      for LVal in LArr do
        if LVal.TryGetValue<string>(LItem) then
          FSearchPaths := FSearchPaths + [LItem];
    end
    else if TJSONObject(AOptions).GetValue('searchPaths') <> nil then
      Tell(2, 'PasTree: the searchPaths setting is not a list of strings'
        + ' - ignored', True);
    if AOptions.TryGetValue<TJSONArray>('defines', LArr) then
    begin
      for LVal in LArr do
        if LVal.TryGetValue<string>(LItem) then
          FDefines := FDefines + [LItem];
    end
    else if TJSONObject(AOptions).GetValue('defines') <> nil then
      Tell(2, 'PasTree: the defines setting is not a list of strings'
        + ' - ignored', True);
  end;
  Log(Format('configured: platform=%s main=%s paths=%d defines=%d',
    [PlatformName(FPlatform), FMainSource, Length(FSearchPaths),
     Length(FDefines)]));
end;

{ -------- analysis -------- }

{ Cancels whatever is in flight and starts a fresh background analysis over
  the current document snapshot. Non-blocking: the dispatcher keeps
  processing messages (didChange restarts, $/cancelRequest lands) while the
  session's worker builds. The PREVIOUS completed project stays live until
  the new one is taken — the demo's double-buffering discipline. }
procedure TLspServer.StartAnalysis(const APriorityFile: string);
var
  LRoots, LPriority: TArray<string>;
  LDoc: TLspDocument;
  LAlias: TPasUnitAlias;
begin
  if FSession <> nil then
  begin
    FSession.Cancel;
    FreeAndNil(FSession);
  end;

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

  FSession := TPasAsyncSession.Create(FPlatform, FSearchPaths, FDefines,
    LRoots, LPriority);
  FSession.SetNamespaces(FNamespaces);
  for LAlias in FAliases do
    FSession.AddUnitAlias(LAlias.Alias, LAlias.UnitName);
  // Document truth, stamped with the client's version — compared on
  // completion to catch a snapshot that went stale mid-build.
  for LDoc in FDocs.All do
    FSession.SetBuffer(LDoc.Path, LDoc.Text, LDoc.Version);
  FDirty := False;   // this session covers everything up to now
  FPendingDue := 0;  // whatever was scheduled is covered by this start
  FPendingPriority := '';
  FStartedSignature := OverlaySignature;
  FBuildStart := GetTickCount64;
  StartProgress('PasTree: analyzing');
  // "full rebuild" spelled out on purpose: when incremental reanalysis
  // lands, this line is where full vs incremental becomes visible.
  Log(Format('analysis started: full rebuild, %d roots, %d overlays',
    [Length(LRoots), FDocs.Count]));
  FSession.Start;
end;

const
  DEBOUNCE_MS = 300;   // one typing pause, not one build per keystroke

procedure TLspServer.ScheduleAnalysis(const APriorityFile: string);
begin
  FDirty := True;
  if APriorityFile <> '' then
    FPendingPriority := APriorityFile;
  FPendingDue := GetTickCount64 + DEBOUNCE_MS;
end;

// Fires a scheduled analysis NOW (deadline ignored) — requests call this so
// they never sit out the debounce window.
procedure TLspServer.FlushPending;
begin
  if FPendingDue = 0 then
    Exit;
  // Nothing to do if the inputs are back to what the current project was
  // built from - an edit typed and undone, or a file opened and closed.
  if (FProject <> nil) and (OverlaySignature = FBuiltSignature) then
  begin
    Log('scheduled rebuild dropped: the analyzed inputs did not change');
    FPendingDue := 0;
    FPendingPriority := '';
    FDirty := False;
    Exit;
  end;
  StartAnalysis(FPendingPriority);
end;

{ Swaps a finished session's project in (on the dispatcher thread — the
  worker is done, TakeProject is the ownership handoff) and publishes
  diagnostics. If any open document changed since the session snapshotted
  its buffers — detected via the version stamps SetBuffer carried — the
  result is already stale: swap it in anyway (better navigation than none)
  but immediately start the replacement build. }
procedure TLspServer.FinalizeAnalysisIfDone;
var
  LDoc: TLspDocument;
  LStale: Boolean;
  LError: string;
begin
  if (FSession = nil) or not FSession.IsDone then
    Exit;
  LError := FSession.LastError;
  if LError <> '' then
    Tell(1, 'PasTree: the analysis failed - ' + LError, True);
  FreeAndNil(FNav);
  FreeAndNil(FProject);
  FProject := FSession.TakeProject;
  FreeAndNil(FSession);
  if FProject = nil then
    Exit;
  FNav := TPasNavigator.Create(FProject);
  FBuiltSignature := FStartedSignature;
  // The whole-closure diagnostic count (open docs get theirs listed by
  // PublishDiagnostics below): a healthy run on a fully-pathed project is
  // near zero, so a big number here means missing search paths (F1027
  // gating) long before any individual click misbehaves.
  var LDiagTotal := 0;
  for var LMi := 0 to FProject.ModelCount - 1 do
    Inc(LDiagTotal, Length(FProject.Model(LMi).Diags));
  EndProgress(Format('%d units in %d ms',
    [FProject.ModelCount, GetTickCount64 - FBuildStart]));
  Log(Format('analysis done: %d units in %d ms, %d diagnostics in closure;'
    + ' stages %s',
    [FProject.ModelCount, GetTickCount64 - FBuildStart, LDiagTotal,
     FProject.StageTimings]));

  LStale := FDirty;
  if not LStale then
    for LDoc in FDocs.All do
      // Only documents whose text DIFFERS from disk can make a result
      // stale: a non-differing one reads identically from either source,
      // and it may legitimately have no overlay in this build at all
      // (opened after the build started, no rebuild scheduled) — comparing
      // its version against the missing overlay's -1 would spin a rebuild
      // loop out of plain tab switching.
      if LDoc.Differs and
         (FProject.BufferVersion(LDoc.Path) <> LDoc.Version) then
      begin
        LStale := True;
        Break;
      end;
  PublishDiagnostics;
  if LStale then
  begin
    Log('result is stale (documents changed mid-build) - restarting');
    StartAnalysis('');
  end;
end;

{ The client-liveness watchdog.

  Normally the session ends when the client closes our stdin: the reader
  thread sees EOF and the dispatcher stops. That covers every orderly exit and
  most disorderly ones. What it does not cover is a client that DIES while
  something else keeps the pipe's write end open — then stdin never reaches
  EOF and this process would sit here forever, holding a multi-hundred-MB
  analysis, invisible to the user who just restarted their editor. LSP exists
  for exactly this: `initialize` carries the client's own processId so a server
  can watch it.

  SYNCHRONIZE access is all that is needed to wait on a process handle; it is
  the least privilege that answers "are you still alive". A handle also pins
  the pid against reuse, which a bare "does pid exist" check would not. }
{ Opens a work-done progress stream for work NOBODY asked for - our background
  rebuild has no client request behind it, so there is no `workDoneToken` to
  reuse and the token has to be created with a `window/workDoneProgress/create`
  REQUEST. Two things follow from that, and both are honored here:

  - the client may not support server-initiated progress at all
    (capabilities.window.workDoneProgress), in which case we stay silent;
  - the client may REFUSE the create with an error, which arrives later as a
    response to our id - see the correlation in Handle, which drops the token.

  `begin` is sent immediately after the create rather than after its response:
  waiting would cost the first (and on a fast rebuild, only) report, and a
  client that refuses simply discards a token it never registered. Not
  cancellable on purpose - the machinery exists, but a cancelled build leaves
  the user with no results at all, which is worse than waiting out five
  seconds. }
{ Does the FILE hold exactly this text? Two ways to be equal, and the second
  one matters far more than it looks:

  1. the tolerant decode the analysis itself uses returns the same string;
  2. re-encoding the editor's text as UTF-8 reproduces the file's bytes.

  (2) exists because the two sides decode a source with no BOM differently and
  both are being reasonable: PasTree reads it as ANSI, which is dcc's own rule
  and the whole point of its tolerant loader, while an editor reads it as
  UTF-8. Every PasTree source with an em-dash in a comment therefore "differs"
  from its own file under (1) alone - a 3-byte UTF-8 dash becomes three ANSI
  characters - and that is not an edit, it is a disagreement about encoding.

  What it cost before this test existed: peeking a declaration (VS Code opens
  the target file, then closes it) scheduled TWO full closure rebuilds, ~14
  seconds of the editor apparently reparsing a file nobody touched. The user
  saw it as a rebuild bug; it was this.

  NB the remaining consequence is real and NOT fixed here: for a file the
  editor does NOT have open, the analysis still reads it as ANSI, so a column
  on a line that contains a non-ASCII character before the identifier is
  shifted relative to the client's UTF-16 view. That is a decode decision for
  the library (see the PasTree To-do), not something the server can paper
  over. }
function TLspServer.FileMatches(const APath, AText, ADiskText: string):
  Boolean;
var
  LFile, LEnc: TBytes;
  LOffset: Integer;
begin
  if AText = ADiskText then
    Exit(True);
  try
    LFile := TFile.ReadAllBytes(APath);
  except
    Exit(False);
  end;
  LEnc := TEncoding.UTF8.GetBytes(AText);
  LOffset := 0;
  // A UTF-8 BOM is not part of the document text on either side.
  if (Length(LFile) >= 3) and (LFile[0] = $EF) and (LFile[1] = $BB) and
     (LFile[2] = $BF) then
    LOffset := 3;
  if Length(LFile) - LOffset <> Length(LEnc) then
    Exit(False);
  Result := (Length(LEnc) = 0) or
    CompareMem(@LFile[LOffset], @LEnc[0], Length(LEnc));
end;

{ The inputs the analysis would see, as a comparable string: every open
  document whose text DIFFERS from its file, by path and content hash.

  Non-differing documents are deliberately absent. Their file holds the same
  content, so listing them would make merely LOOKING at a file (an open
  followed by a close) change the signature and force a rebuild - which is the
  churn this exists to stop. The overlay is still handed to the analysis for
  them; what it buys there is the editor's own decoding of the bytes, which is
  not worth a rebuild on its own. }
function TLspServer.OverlaySignature: string;
var
  LDoc: TLspDocument;
  LParts: TStringList;
begin
  LParts := TStringList.Create;
  try
    LParts.Sorted := True;   // dictionary order is not stable; this is
    for LDoc in FDocs.All do
      if LDoc.Differs then
        LParts.Add(Format('%s|%d|%.8x', [LowerCase(LDoc.Path),
          Length(LDoc.Text), THashFNV1a32.GetHashValue(LDoc.Text)]));
    Result := LParts.CommaText;
  finally
    LParts.Free;
  end;
end;

procedure TLspServer.StartProgress(const ATitle: string);
begin
  if not FClientProgress or (FProgressToken <> '') then
    Exit;
  Inc(FProgressSeq);
  FProgressToken := Format('pastree-%d', [FProgressSeq]);
  Inc(FNextServerId);
  FProgressCreateId := FNextServerId;
  FLastReportTick := 0;
  Notify(Format('{"jsonrpc":"2.0","id":%d,'
    + '"method":"window/workDoneProgress/create","params":{"token":%s}}',
    [FProgressCreateId, JsonQuote(FProgressToken)]));
  Notify(Format('{"jsonrpc":"2.0","method":"$/progress","params":{"token":%s,'
    + '"value":{"kind":"begin","title":%s,"cancellable":false}}}',
    [JsonQuote(FProgressToken), JsonQuote(ATitle)]));
end;

{ One `report` for the in-flight analysis, throttled.

  NO percentage, deliberately. `Total` is "modules discovered SO FAR" and grows
  as the closure opens up - the first probe of this showed 3/4 becoming 3/145
  within a second - so any percentage during discovery is arithmetic about a
  denominator that has not happened yet. Clamping it monotonic (tried first)
  only converts jitter into a number that sits at 75% while the real ratio is
  2%, which is worse: a wrong bar is read as fact. The message carries the
  phase and the real counts, and without a percentage in `begin` a client shows
  an indeterminate spinner, which is exactly the truth about this work. }
procedure TLspServer.ReportProgress;
var
  LProg: TPasStagedProgress;
  LNow: UInt64;
  LMsg: string;
begin
  if (FProgressToken = '') or (FSession = nil) then
    Exit;
  LNow := GetTickCount64;
  if (FLastReportTick <> 0) and (LNow - FLastReportTick < 200) then
    Exit;   // 200ms: visible movement without a notification per poll
  FLastReportTick := LNow;
  LProg := FSession.Progress;
  if (LProg.Total = 0) or (LProg.Phase = '') then
    LMsg := 'starting'
  else
    LMsg := Format('%s %d/%d units',
      [LProg.Phase, LProg.FullDone, LProg.Total]);
  Notify(Format('{"jsonrpc":"2.0","method":"$/progress","params":{"token":%s,'
    + '"value":{"kind":"report","message":%s}}}',
    [JsonQuote(FProgressToken), JsonQuote(LMsg)]));
end;

procedure TLspServer.EndProgress(const AMessage: string);
begin
  if FProgressToken = '' then
    Exit;
  Notify(Format('{"jsonrpc":"2.0","method":"$/progress","params":{"token":%s,'
    + '"value":{"kind":"end","message":%s}}}',
    [JsonQuote(FProgressToken), JsonQuote(AMessage)]));
  FProgressToken := '';
end;

{ Says something to the USER, not just to the log file. AType is the LSP
  MessageType (1 Error, 2 Warning, 3 Info, 4 Log).

  Every message still goes to the log; AShow additionally raises it as
  `window/showMessage`, which VS Code turns into a toast. That is reserved for
  the handful of conditions the user can actually act on - a project file that
  would not load, a configuration option of the wrong shape, an analyzer
  exception - because a toast per rebuild would be hostile. Everything else
  travels as `window/logMessage`, which lands in the client's output channel
  and is exactly where someone goes when they wonder what the server is
  doing. }
procedure TLspServer.Tell(AType: Integer; const AMsg: string; AShow: Boolean);
begin
  Log(AMsg);
  Notify(Format('{"jsonrpc":"2.0","method":"window/logMessage",'
    + '"params":{"type":%d,"message":%s}}', [AType, JsonQuote(AMsg)]));
  if AShow then
    Notify(Format('{"jsonrpc":"2.0","method":"window/showMessage",'
      + '"params":{"type":%d,"message":%s}}', [AType, JsonQuote(AMsg)]));
end;

procedure TLspServer.StartClientWatchdog(APid: Integer);
begin
  if APid <= 0 then
  begin
    Log('no client processId in initialize - liveness watchdog disabled'
      + ' (stdin EOF is still the normal exit path)');
    Exit;
  end;
  FClientHandle := OpenProcess(SYNCHRONIZE, False, APid);
  if FClientHandle = 0 then
    // Do not guess: a failure here (access denied, or a pid that already
    // vanished between spawn and initialize) is not evidence the client is
    // gone, and exiting on it would kill a healthy session.
    Log(Format('cannot watch client pid %d (error %d) - watchdog disabled',
      [APid, GetLastError]))
  else
    Log(Format('watching client pid %d', [APid]));
end;

function TLspServer.ClientGone: Boolean;
begin
  if FClientHandle = 0 then
    Exit(False);
  // Zero timeout: a poll, not a wait. Called from the 50ms idle tick and from
  // the analysis wait loop, so both an idle server and one in the middle of a
  // long build notice within a tick.
  Result := WaitForSingleObject(FClientHandle, 0) = WAIT_OBJECT_0;
end;

procedure TLspServer.Idle;
begin
  ReportProgress;
  if ClientGone then
  begin
    Log('client process is gone - exiting');
    FExitRequested := True;
    // Zero, not the no-shutdown 1: the client vanished, which is not a
    // protocol violation to report, and a nonzero code would be misleading
    // noise in whatever supervisor log outlives us.
    FExitCode := 0;
    Exit;
  end;
  if (FPendingDue <> 0) and (GetTickCount64 >= FPendingDue) then
    FlushPending;
  FinalizeAnalysisIfDone;
end;

function TLspServer.WaitAnalyzed(const APriorityFile,
  ARequestIdJson: string): Boolean;
begin
  FlushPending;   // a scheduled build must not make the answer stale
  if (FProject = nil) and (FSession = nil) then
    StartAnalysis(APriorityFile);
  // Wait out the in-flight build (if any), polling the cancel set: this is
  // exactly the moment $/cancelRequest exists for — the reader thread keeps
  // noting cancels while we sit here.
  while FSession <> nil do
  begin
    if (ARequestIdJson <> '') and FCancels.IsCancelled(ARequestIdJson) then
      Exit(False);
    if ClientGone then
      Exit(False);   // the idle tick ends the session
    ReportProgress;
    FinalizeAnalysisIfDone;   // also handles the stale->restart loop
    if FSession <> nil then
      TThread.Sleep(10);
  end;
  Result := True;
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
          // Mirror every published diagnostic into the log: the Problems
          // panel shows them too, but the log survives the panel being
          // cleared and lines up with the analysis timing lines around it.
          Log(Format('  diag %s(%d,%d): %s',
            [TPath.GetFileName(LDoc.Path), LModel.Diags[LIdx].Line,
             LModel.Diags[LIdx].Col, LModel.Diags[LIdx].Msg]));
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
  if AMsg.Params <> nil then
    FClientProgress := AMsg.Params.GetValue<Boolean>(
      'capabilities.window.workDoneProgress', False);
  if AMsg.Params <> nil then
    StartClientWatchdog(AMsg.Params.GetValue<Integer>('processId', 0));
  FInitialized := True;
  Result := BuildResponse(AMsg.IdJson,
    '{"capabilities":{' +
      '"positionEncoding":"utf-16",' +
      '"textDocumentSync":{"openClose":true,"change":2},' +   // 2 = Incremental
      '"definitionProvider":true,' +
      '"referencesProvider":true,' +
      '"implementationProvider":true,' +
      '"declarationProvider":true,' +
      '"documentSymbolProvider":true,' +
      '"hoverProvider":true,' +
      '"typeDefinitionProvider":true,' +
      '"documentHighlightProvider":true' +
    '},"serverInfo":{"name":"pastree-lsp-server","version":"0.2.0"}}');
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
  LPath, LText, LDisk: string;
  LVersion: Integer;
  LDiffers: Boolean;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  LText := AParams.GetValue<string>('textDocument.text', '');
  LVersion := AParams.GetValue<Integer>('textDocument.version', 0);
  // The rebuild gate: VS Code opens a document for every tab switch and
  // every peek popup, and the analysis already read this file from disk —
  // if the editor's text IS the disk text (decoded the same tolerant way
  // the analysis decodes it), nothing about the project changed and no
  // rebuild is due. Every real session log showed exactly this churn:
  // full rebuilds on plain clicking around.
  try
    LDisk := TPasSourceManager.LoadFileTolerant(LPath);
  except
    LDisk := '';   // unreadable/new file: treat the buffer as the truth
  end;
  // When the file HOLDS this text, remember the editor.s own string as the
  // disk text: every later comparison is then a plain string compare that
  // means "same as what is on disk", and typing-then-undoing comes back to
  // not-differing on its own.
  if FileMatches(LPath, LText, LDisk) then
    LDisk := LText;
  LDiffers := LText <> LDisk;
  FDocs.Open(LPath, LText, LVersion, LDisk, LDiffers);
  if LDiffers then
    Log(Format('didOpen %s v%d (unsaved: %d chars here, %d on disk)',
      [LPath, LVersion, Length(LText), Length(LDisk)]))
  else
    Log(Format('didOpen %s v%d', [LPath, LVersion]));
  // Schedule when this buffer is unsaved work the analysis has not seen, OR
  // when nothing has been analyzed yet - the first file opened is what starts
  // the initial build, and without this clause a workspace whose files all
  // match their disk contents would sit unanalyzed until the first request.
  if LDiffers or ((FProject = nil) and (FSession = nil)) then
    ScheduleAnalysis(LPath);
end;

procedure TLspServer.HandleDidChange(AParams: TJSONValue);
var
  LPath, LText, LNew: string;
  LVersion, LIdx, LSL, LSC, LEL, LEC: Integer;
  LChanges: TJSONArray;
  LChange, LRange: TJSONValue;
  LOld: TLspDocument;
  LHadDoc, LFullReplace: Boolean;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  if not AParams.TryGetValue<TJSONArray>('contentChanges', LChanges) or
     (LChanges.Count = 0) then
    Exit;
  LVersion := AParams.GetValue<Integer>('textDocument.version', 0);
  LHadDoc := FDocs.TryGet(LPath, LOld);
  LText := LOld.Text;

  { Incremental sync (TextDocumentSyncKind.Incremental): each change carries a
    range, and they must be applied IN ORDER — every range after the first
    refers to the text as the previous ones left it. A change with no range is
    a full replacement and is honored too: the spec allows a client to mix
    them, and a resync arrives that way.

    Correctness here is invisible until it is wrong: a mis-applied patch does
    not fail, it silently leaves the server analyzing text the editor never
    had, and LSP gives a server no way to ask for a resend. Hence the clamping
    in PositionToIndex rather than exceptions, and the log line below carrying
    the resulting length — the cheapest thing that makes a divergence
    noticeable at all. }
  LFullReplace := False;
  for LIdx := 0 to LChanges.Count - 1 do
  begin
    LChange := LChanges.Items[LIdx];
    if not LChange.TryGetValue<string>('text', LNew) then
      Continue;
    LRange := LChange.FindValue('range');
    if LRange = nil then
    begin
      LText := LNew;              // full replacement
      LFullReplace := True;
      Continue;
    end;
    if not (LRange.TryGetValue<Integer>('start.line', LSL) and
            LRange.TryGetValue<Integer>('start.character', LSC) and
            LRange.TryGetValue<Integer>('end.line', LEL) and
            LRange.TryGetValue<Integer>('end.character', LEC)) then
    begin
      Tell(2, 'PasTree: a didChange range had no line/character; the edit was'
        + ' skipped and this buffer may now differ from the editor', False);
      Continue;
    end;
    LText := ApplyRangeChange(LText, LSL, LSC, LEL, LEC, LNew);
  end;

  FDocs.Change(LPath, LText, LVersion, LOld.DiskText,
    not LHadDoc or (LText <> LOld.DiskText));
  if LFullReplace then
    Log(Format('didChange %s v%d (full, %d chars)',
      [LPath, LVersion, Length(LText)]))
  else
    Log(Format('didChange %s v%d (%d edits, now %d chars)',
      [LPath, LVersion, LChanges.Count, Length(LText)]));
  // Rebuild only on a real text change - the version always bumps, but a
  // no-op edit must not cost a build.
  if not LHadDoc or (LText <> LOld.Text) then
    ScheduleAnalysis(LPath);
end;

procedure TLspServer.HandleDidClose(AParams: TJSONValue);
var
  LPath: string;
  LDoc: TLspDocument;
  LDiffered: Boolean;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  LDiffered := FDocs.TryGet(LPath, LDoc) and LDoc.Differs;
  FDocs.Close(LPath);
  PublishEmptyDiagnostics(LPath);
  Log('didClose ' + LPath);
  // The disk file is the truth again — a rebuild is due only if the overlay
  // ever DIFFERED from it (analysis results built from unsaved text now
  // describe content that no longer exists anywhere).
  if LDiffered then
    ScheduleAnalysis('');
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

  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));   // analysis produced nothing
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
  begin
    Log('definition: file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  // Failures answer null to the client (per protocol) but SAY WHY in the
  // log — "F12 did nothing" is otherwise undebuggable from the outside.
  if not FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
  begin
    Log(Format('definition: no identifier at %s(%d,%d)',
      [TPath.GetFileName(LPath), LPasLine, LPasCol]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  if not FNav.ResolveDecl(LMid, LIdent.Node, LTarget) then
  begin
    Log(Format('definition: ''%s'' at %s(%d,%d) did not resolve to a source'
      + ' declaration (unresolved name, or a builtin with none)',
      [LIdent.Name, TPath.GetFileName(LPath), LPasLine, LPasCol]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format('definition: %s -> %s(%d,%d)',
    [LIdent.Name, TPath.GetFileName(LTarget.FilePath), LTarget.Line,
     LTarget.Col]));
  Result := BuildResponse(AMsg.IdJson,
    LocationJson(LTarget.FilePath, LTarget.Line, LTarget.Col,
      Length(LTarget.Name)));
end;

// One TPasRefHit as an LSP Location. The highlight span HiFrom..HiTo (0-based
// offsets into the snippet LINE) gives the range its length; Col is where
// that span starts, so start/end derive from Col and the span width.
function HitLocationJson(const AHit: TPasRefHit): string;
begin
  Result := LocationJson(AHit.FilePath, AHit.Line, AHit.Col,
    AHit.HiTo - AHit.HiFrom);
end;

{ textDocument/references — the three-identity model, straight from the
  navigator (see PasTree.Sema.Nav's own comments for why three): a SYMBOL
  (unit, symbol id — the normal case), a UNIT (header/uses click: each
  referrer holds its own skUnitRef symbol, so the target model id is the
  only project-wide identity), or a compiler-seeded BUILTIN (no declaration
  anywhere; the name is the identity). Tried in that order — SymbolAt
  declines the latter two by design. FindReferences never includes the
  declaration site, so context.includeDeclaration is honored by prepending
  the separate DeclHit/UnitDeclHit answer (builtins have no declaration to
  include). }
function TLspServer.HandleReferences(const AMsg: TLspIncoming): string;
var
  LPath, LName: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSym: Integer;
  LInclDecl: Boolean;
  LHits: TArray<TPasRefHit>;
  LDecl: TPasRefHit;
  LSB: TStringBuilder;
  LIdx: Integer;
  LKind: string;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'references: textDocument.uri and position required'));
  LInclDecl := AMsg.Params.GetValue<Boolean>('context.includeDeclaration',
    False);

  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);

  LHits := nil;
  // UnitAt BEFORE SymbolAt (the IDE plugin now uses the same order):
  // UnitAt only ever matches a `uses` item or the module's own header
  // name — positions where the unit identity IS the right answer — while
  // SymbolAt, tested first, CLAIMS a program's `X in '...'` uses item as an
  // ordinary symbol whose reference search then finds nothing (observed on
  // a .dpr; a unit's plain uses items it declines as documented).
  if FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) then
  begin
    LKind := 'unit';
    LHits := FNav.FindUnitReferences(LTMid);
    if LInclDecl and FNav.UnitDeclHit(LTMid, LDecl) then
      LHits := [LDecl] + LHits;
  end
  else if FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) then
  begin
    LKind := 'symbol';
    LHits := FNav.FindReferences(LTMid, LSym);
    if LInclDecl and FNav.DeclHit(LTMid, LSym, LDecl) then
      LHits := [LDecl] + LHits;
  end
  else if FNav.BuiltinNameAt(LMid, LPasLine, LPasCol, LName) then
  begin
    LKind := 'builtin';
    LHits := FNav.FindBuiltinReferences(LName);
  end
  else
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  Log(Format('references(%s): %s -> %d hits', [LKind, LName, Length(LHits)]));
  LSB := TStringBuilder.Create;
  try
    LSB.Append('[');
    for LIdx := 0 to High(LHits) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(HitLocationJson(LHits[LIdx]));
    end;
    LSB.Append(']');
    Result := BuildResponse(AMsg.IdJson, LSB.ToString);
  finally
    LSB.Free;
  end;
end;

{ textDocument/implementation and textDocument/declaration — the decl<->impl
  toggle, a Pascal-specific navigation the navigator implements as pure CST
  walks (GotoImplementation/GotoDeclaration; they never cross units, because
  the language requires the body in the same one).

  Note how this differs from textDocument/definition above: definition asks
  "where is this NAME declared" and follows a resolved reference anywhere in
  the closure, while these two ask "where is the OTHER HALF of the routine I
  am standing in" — from a method header or a `forward` to the body's first
  statement, and from anywhere inside an implementation back to its own
  header. An editor binds them to separate commands (VS Code: Go to
  Implementation / Go to Declaration), and the IDE plugin's own decl<->impl
  command maps here rather than onto definition. }
function TLspServer.HandleToggle(const AMsg: TLspIncoming;
  AToImpl: Boolean): string;
var
  LPath, LWhat: string;
  LLine, LChar, LPasLine, LPasCol, LMid: Integer;
  LTarget: TPasNavTarget;
  LFound: Boolean;
begin
  if AToImpl then
    LWhat := 'implementation'
  else
    LWhat := 'declaration';
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      LWhat + ': textDocument.uri and position required'));

  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
  begin
    Log(LWhat + ': file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if AToImpl then
    LFound := FNav.GotoImplementation(LMid, LPasLine, LPasCol, LTarget)
  else
    LFound := FNav.GotoDeclaration(LMid, LPasLine, LPasCol, LTarget);
  if not LFound then
  begin
    // Not an error: the cursor is simply not on a routine that HAS another
    // half (a plain procedure defined once has no separate header). Said in
    // the log because "the command did nothing" needs a reason.
    Log(Format('%s: nothing to toggle to at %s(%d,%d)',
      [LWhat, TPath.GetFileName(LPath), LPasLine, LPasCol]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format('%s: %s -> %s(%d,%d)',
    [LWhat, LTarget.Name, TPath.GetFileName(LTarget.FilePath), LTarget.Line,
     LTarget.Col]));
  Result := BuildResponse(AMsg.IdJson,
    LocationJson(LTarget.FilePath, LTarget.Line, LTarget.Col,
      Length(LTarget.Name)));
end;

{ LSP SymbolKind for a PasTree symbol, or 0 for "do not put this in an
  outline": parameters, labels, generic parameters, `uses` items and seeded
  builtins are all declarations, but none of them is what a reader scans a
  unit's structure for. A type's LSP kind comes from its category, so a class
  gets the class icon and a record the struct one. }
function SymbolKindOf(const ASym: TSemaSymbol): Integer;
begin
  case ASym.Kind of
    skType:
      case ASym.TypeCat of
        tcClass: Result := 5;        // Class
        tcInterface: Result := 11;   // Interface
        tcRecord: Result := 23;      // Struct
        tcEnum: Result := 10;        // Enum
        tcArray: Result := 18;       // Array
        tcProc: Result := 12;        // Function (a procedural type)
      else
        Result := 23;                // alias, subrange, set, pointer, ...
      end;
    skRoutine:
      if sfClassMember in ASym.Flags then
        Result := 6                  // Method
      else
        Result := 12;                // Function
    skVar: Result := 13;             // Variable
    skConst: Result := 14;           // Constant
    skField: Result := 8;            // Field
    skProperty: Result := 7;         // Property
    skEnumValue: Result := 22;       // EnumMember
  else
    Result := 0;
  end;
end;

{ textDocument/documentSymbol — the unit's own outline (VS Code: Outline
  pane, Ctrl+Shift+O, breadcrumbs; the IDE plugin's Structure view maps here
  too).

  Built from the model's SCOPES rather than by walking the CST: the unit and
  implementation scopes list their symbols in declaration order, which is the
  order a reader expects, and a type's MemberScope gives its fields, methods
  and properties as children with no separate traversal. Routine bodies
  (sckRoutine/sckBlock) are deliberately not descended into — locals are not
  outline material.

  Known limit: range = selectionRange = the NAME's span, because NodeSite
  gives a node's first-token position and nothing public gives a
  declaration's full extent yet. Navigation and the tree are correct; what
  suffers is breadcrumb tracking as the cursor moves inside a body, which
  needs a real span (a nav-side NodeSpan belongs in PasTree, not here). }
function TLspServer.HandleDocumentSymbol(const AMsg: TLspIncoming): string;
var
  LPath, LItems, LParts: string;
  LMid, LScopeIdx: Integer;
  LModel: TPasSemaModel;

  // The items of one scope as comma-joined DocumentSymbol JSON ('' = none).
  function ScopeItems(AScopeIdx, ADepth: Integer): string;
  var
    LScope: TSemaScope;
    LI, LSymIdx, LKind, LLine, LChar, LPasLine, LPasCol: Integer;
    LSym: TSemaSymbol;
    LFile, LChildren, LOne: string;
    LSB: TStringBuilder;
  begin
    Result := '';
    // The depth guard bounds the JSON a pathological nesting could produce;
    // every level here is recursion.
    if (ADepth > 16) or (AScopeIdx < 0) or (AScopeIdx >= LModel.Scopes.Count)
    then
      Exit;
    LScope := LModel.Scopes[AScopeIdx];
    LSB := TStringBuilder.Create;
    try
      for LI := 0 to LScope.Symbols.Count - 1 do
      begin
        LSymIdx := LScope.Symbols[LI];
        if (LSymIdx < 0) or (LSymIdx > High(LModel.Symbols)) then
          Continue;
        LSym := LModel.Symbols[LSymIdx];
        LKind := SymbolKindOf(LSym);
        if (LKind = 0) or (LSym.DeclNode = NIL_NODE) then
          Continue;
        if not FProject.NodeSite(LMid, LSym.DeclNode, LFile, LPasLine,
          LPasCol) then
          Continue;
        // A symbol declared in an $I include belongs to THAT document, not
        // this one — LSP documentSymbol is strictly per-document.
        if not SameText(TPath.GetFullPath(LFile), LPath) then
          Continue;
        // Members of a type, one level down. Asking only types for their
        // members is what keeps routine locals out.
        if LSym.Kind = skType then
          LChildren := ScopeItems(LSym.MemberScope, ADepth + 1)
        else
          LChildren := '';
        PasTreeToLsp(LPasLine, LPasCol, LLine, LChar);
        LOne := Format(
          '{"name":%s,"kind":%d,' +
          '"range":{"start":{"line":%d,"character":%d},' +
          '"end":{"line":%d,"character":%d}},' +
          '"selectionRange":{"start":{"line":%d,"character":%d},' +
          '"end":{"line":%d,"character":%d}},"children":[%s]}',
          [JsonQuote(LSym.Name), LKind,
           LLine, LChar, LLine, LChar + Length(LSym.Name),
           LLine, LChar, LLine, LChar + Length(LSym.Name),
           LChildren]);
        if LSB.Length > 0 then
          LSB.Append(',');
        LSB.Append(LOne);
      end;
      Result := LSB.ToString;
    finally
      LSB.Free;
    end;
  end;

  // Appends one scope's items to the running list.
  procedure AddScope(AScopeIdx: Integer);
  begin
    LParts := ScopeItems(AScopeIdx, 0);
    if LParts = '' then
      Exit;
    if LItems <> '' then
      LItems := LItems + ',';
    LItems := LItems + LParts;
  end;

begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'documentSymbol: textDocument.uri required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
  begin
    Log('documentSymbol: file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LPath := TPath.GetFullPath(LPath);
  LModel := FProject.Model(LMid);

  // Interface first, then implementation — source order, and the two are
  // separate sibling scopes rather than a nested pair.
  LItems := '';
  for LScopeIdx := 0 to LModel.Scopes.Count - 1 do
    if LModel.Scopes[LScopeIdx].Kind = sckUnit then
      AddScope(LScopeIdx);
  for LScopeIdx := 0 to LModel.Scopes.Count - 1 do
    if LModel.Scopes[LScopeIdx].Kind = sckImplementation then
      AddScope(LScopeIdx);
  Log(Format('documentSymbol: %s -> %d bytes of outline',
    [TPath.GetFileName(LPath), Length(LItems)]));
  Result := BuildResponse(AMsg.IdJson, '[' + LItems + ']');
end;

// The word a reader expects in front of a name, per symbol kind. Not the
// LSP SymbolKind enum (that is SymbolKindOf above) — this is prose for a
// hover card.
function KindWord(AKind: TSemaSymbolKind): string;
begin
  case AKind of
    skType: Result := 'type';
    skVar: Result := 'variable';
    skConst: Result := 'constant';
    skField: Result := 'field';
    skRoutine: Result := 'routine';
    skParam: Result := 'parameter';
    skProperty: Result := 'property';
    skEnumValue: Result := 'enum value';
    skGenericParam: Result := 'type parameter';
    skLabel: Result := 'label';
    skUnitRef: Result := 'unit reference';
    skBuiltinType: Result := 'builtin type';
  else
    Result := 'symbol';
  end;
end;

{ textDocument/hover — what is under the cursor, as a small markdown card:
  the DECLARATION's own source line in a Pascal code fence, plus a prose line
  naming the kind and where it lives.

  The declaration line comes from the navigator's DeclHit, the same snippet
  Find References shows for a declaration site — so the hover can never
  disagree with the results list, and there is no second formatter to keep in
  sync. A routine header that spans several source lines shows only its
  first: DeclHit is line-based, and inventing a multi-line reconstruction
  here would be exactly the second source of truth just avoided.

  The three identities are tried in the same order as references (unit,
  symbol, builtin) for the same reason documented there. }
function TLspServer.HandleHover(const AMsg: TLspIncoming): string;
var
  LPath, LName, LCode, LNote, LMd: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSymIdx: Integer;
  LIdent: TPasNavIdent;
  LHit: TPasRefHit;
  LStartLine, LStartChar, LEndLine, LEndChar: Integer;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'hover: textDocument.uri and position required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  // No identifier under the cursor is the COMMON case for a hover (any
  // keyword, any whitespace) — answered with null and NOT logged, or a
  // session log becomes unreadable from mouse movement alone.
  if not FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LCode := '';
  LNote := '';
  if FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) then
  begin
    LCode := 'unit ' + LName + ';';
    if FNav.UnitDeclHit(LTMid, LHit) then
      LNote := Format('unit - %s', [TPath.GetFileName(LHit.FilePath)])
    else
      LNote := 'unit';
  end
  else if FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSymIdx, LName) then
  begin
    if FNav.DeclHit(LTMid, LSymIdx, LHit) then
    begin
      LCode := Trim(LHit.Snippet);
      LNote := Format('%s - %s:%d',
        [KindWord(FProject.Model(LTMid).Symbols[LSymIdx].Kind),
         TPath.GetFileName(LHit.FilePath), LHit.Line]);
    end
    else
      // A symbol with no declaration node of its own: the implicit Result,
      // for instance. Still worth a card saying what it is.
      LNote := Format('%s %s',
        [KindWord(FProject.Model(LTMid).Symbols[LSymIdx].Kind), LName]);
  end
  else if FNav.BuiltinNameAt(LMid, LPasLine, LPasCol, LName) then
  begin
    LCode := LName;
    LNote := 'compiler builtin - no source declaration';
  end
  else
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LMd := '';
  if LCode <> '' then
    LMd := '```pascal'#10 + LCode + #10'```'#10#10;
  LMd := LMd + '_' + LNote + '_';
  // The range is the identifier's own span, so the editor underlines exactly
  // the name it is describing — including all segments of a qualified `uses`
  // name, which IdentAt reports as one span.
  PasTreeToLsp(LIdent.Line, LIdent.ColFrom, LStartLine, LStartChar);
  PasTreeToLsp(LIdent.Line, LIdent.ColTo, LEndLine, LEndChar);
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"contents":{"kind":"markdown","value":%s},' +
    '"range":{"start":{"line":%d,"character":%d},' +
    '"end":{"line":%d,"character":%d}}}',
    [JsonQuote(LMd), LStartLine, LStartChar, LEndLine, LEndChar]));
end;

{ workspace/didChangeWatchedFiles — a file changed on disk, outside any
  editor buffer we hold.

  The CLIENT owns the watching: an editor already knows about file system
  events, and the IDE plugin gets the same news from ToolsAPI, so a watcher
  inside the server would be a second (polling, platform-specific) source of
  truth for something both clients already have. The VS Code client registers
  the glob in its `synchronize.fileEvents`; any other client just sends this
  notification.

  What matters here is deciding whether a rebuild is actually due:

  - a file we hold OPEN cannot change the analysis, because the analysis reads
    the OVERLAY for it, not the disk (document truth). No rebuild — but the
    cached disk text is refreshed, or the rebuild gate and didClose would keep
    comparing against a file that no longer exists in that form;
  - a file we do NOT hold open was read from disk by the analysis, so its
    change (or creation, or deletion — both move unit resolution) does mean a
    rebuild;
  - anything that is not Pascal source is ignored outright: a build writing
    .dcu/.exe next to the sources would otherwise restart the analysis
    continuously.

  A changed .dproj is called out rather than acted on: search paths, defines
  and namespaces are read once at initialize, so honoring it would need a
  reconfigure the protocol gives us no clean moment for. Saying so beats
  either silence or a rebuild that quietly uses the old configuration. }
procedure TLspServer.HandleDidChangeWatchedFiles(AParams: TJSONValue);
var
  LChanges: TJSONArray;
  LItem: TJSONValue;
  LUri, LPath, LExt, LDisk: string;
  LDoc: TLspDocument;
  LRebuild: Boolean;
  LTouched: Integer;
begin
  if (AParams = nil) or
     not AParams.TryGetValue<TJSONArray>('changes', LChanges) then
    Exit;
  LRebuild := False;
  LTouched := 0;
  for LItem in LChanges do
  begin
    if not LItem.TryGetValue<string>('uri', LUri) then
      Continue;
    LPath := UriToPath(LUri);
    if LPath = '' then
      Continue;
    LExt := LowerCase(TPath.GetExtension(LPath));
    if LExt = '.dproj' then
    begin
      Log('note: ' + TPath.GetFileName(LPath) + ' changed on disk; search'
        + ' paths and defines are read at initialize, so restart the server'
        + ' to pick them up');
      Continue;
    end;
    if (LExt <> '.pas') and (LExt <> '.dpr') and (LExt <> '.dpk') and
       (LExt <> '.inc') then
      Continue;
    Inc(LTouched);
    if FDocs.TryGet(LPath, LDoc) then
    begin
      try
        LDisk := TPasSourceManager.LoadFileTolerant(LPath);
      except
        LDisk := '';   // deleted or locked: the overlay is all we have
      end;
      if FileMatches(LPath, LDoc.Text, LDisk) then
        LDisk := LDoc.Text;   // see FileMatches: a decode difference is not an edit
      FDocs.SetDiskText(LPath, LDisk);
      Log('watched: ' + TPath.GetFileName(LPath) +
        ' changed on disk but is open here - overlay still wins');
    end
    else
      LRebuild := True;
  end;
  if LRebuild then
  begin
    Log(Format('watched: %d file(s) changed on disk - rebuild scheduled',
      [LTouched]));
    ScheduleAnalysis('');
  end;
end;

{ textDocument/typeDefinition — "go to the TYPE of the thing under the cursor",
  as distinct from definition's "go to where this name is declared". For
  `FProj: TPasSemaProject` on the field's own name, definition stays on the
  field and this jumps to the class. The resolved type is already on the
  symbol (`TypeSym`), so the work is one hop plus the same declaration lookup
  definition uses; a symbol whose type never resolved, or a type symbol itself
  (its "type" is itself), answers null rather than something invented. }
function TLspServer.HandleTypeDefinition(const AMsg: TLspIncoming): string;
var
  LPath, LName: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSymIdx: Integer;
  LSym: TSemaSymbol;
  LTarget: TPasNavTarget;
  LHit: TPasRefHit;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'typeDefinition: textDocument.uri and position required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if not FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSymIdx, LName) then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LSym := FProject.Model(LTMid).Symbols[LSymIdx];

  // Route 1: resolve the declaration's TYPE EXPRESSION node with the very
  // call `definition` uses. That matters because it is the one that reaches
  // ACROSS units - `TypeSym` below is a model-local index, so on its own it
  // could only ever answer for a type declared in the same file, which is the
  // minority of interesting cases (`FProj: TPasSemaProject` lives in another
  // unit). A type ALIAS is deliberately allowed through here: jumping from
  // `TFoo = TBar` to TBar is the useful answer.
  if (LSym.TypeNode <> NIL_NODE) and
     FNav.ResolveDecl(LTMid, LSym.TypeNode, LTarget) then
  begin
    Log(Format('typeDefinition: %s -> %s(%d,%d)',
      [LName, TPath.GetFileName(LTarget.FilePath), LTarget.Line,
       LTarget.Col]));
    Exit(BuildResponse(AMsg.IdJson,
      LocationJson(LTarget.FilePath, LTarget.Line, LTarget.Col,
        Length(LTarget.Name))));
  end;

  // Route 2: the resolved type symbol, for the same-unit case where the type
  // expression itself did not resolve to a declaration (an inferred inline
  // `var`, say). Not for a type symbol - its own type is itself.
  if (LSym.Kind <> skType) and (LSym.TypeSym <> NIL_SYM) and
     FNav.DeclHit(LTMid, LSym.TypeSym, LHit) then
  begin
    Log(Format('typeDefinition: %s -> %s(%d,%d) via the resolved type symbol',
      [LName, TPath.GetFileName(LHit.FilePath), LHit.Line, LHit.Col]));
    Exit(BuildResponse(AMsg.IdJson,
      LocationJson(LHit.FilePath, LHit.Line, LHit.Col,
        LHit.HiTo - LHit.HiFrom)));
  end;

  Log(Format('typeDefinition: no type declaration reachable for %s', [LName]));
  Result := BuildResponse(AMsg.IdJson, 'null');
end;


{ textDocument/documentHighlight — every occurrence of the symbol under the
  cursor WITHIN this document, which is what an editor paints when the caret
  rests on a name.

  It is the reference search, filtered to one file, and it deliberately reuses
  the same three-identity resolution: highlighting a `uses` item should light
  up that unit's other mentions here, not nothing. The declaration site is
  included when it lives in this file (`DeclHit`), because an occurrence is an
  occurrence. No read/write kinds are reported: the analyzer knows what a name
  RESOLVES to, not whether a given mention is being assigned, and guessing
  from context would be a different (and wrong-half-the-time) feature. }
function TLspServer.HandleDocumentHighlight(const AMsg: TLspIncoming): string;
var
  LPath, LName, LKey: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSymIdx, LIdx: Integer;
  LHits: TArray<TPasRefHit>;
  LDecl: TPasRefHit;
  LSB: TStringBuilder;
  LCount: Integer;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'documentHighlight: textDocument.uri and position required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);

  LHits := nil;
  if FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) then
  begin
    LHits := FNav.FindUnitReferences(LTMid);
    if FNav.UnitDeclHit(LTMid, LDecl) then
      LHits := [LDecl] + LHits;
  end
  else if FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSymIdx, LName) then
  begin
    LHits := FNav.FindReferences(LTMid, LSymIdx);
    if FNav.DeclHit(LTMid, LSymIdx, LDecl) then
      LHits := [LDecl] + LHits;
  end
  else if FNav.BuiltinNameAt(LMid, LPasLine, LPasCol, LName) then
    LHits := FNav.FindBuiltinReferences(LName)
  else
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LKey := LowerCase(TPath.GetFullPath(LPath));
  LCount := 0;
  LSB := TStringBuilder.Create;
  try
    LSB.Append('[');
    for LIdx := 0 to High(LHits) do
    begin
      if LowerCase(TPath.GetFullPath(LHits[LIdx].FilePath)) <> LKey then
        Continue;
      if LCount > 0 then
        LSB.Append(',');
      Inc(LCount);
      LSB.Append(Format('{"range":%s}',
        [RangeJson(LHits[LIdx].Line, LHits[LIdx].Col,
          LHits[LIdx].HiTo - LHits[LIdx].HiFrom)]));
    end;
    LSB.Append(']');
    Log(Format('documentHighlight: %s -> %d in this file', [LName, LCount]));
    Result := BuildResponse(AMsg.IdJson, LSB.ToString);
  finally
    LSB.Free;
  end;
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
      // A response from the client (id, no method). The only request we
      // send is the progress-create; a client that REFUSED it must not then
      // be sent $/progress under a token it never registered, so drop the
      // stream and stop offering progress for the rest of the session.
      if LMsg.Method = '' then
      begin
        if (FProgressCreateId <> 0) and
           (LMsg.IdJson = IntToStr(FProgressCreateId)) and
           (LMsg.Root.FindValue('error') <> nil) then
        begin
          Log('client refused window/workDoneProgress/create - no progress');
          FProgressToken := '';
          FClientProgress := False;
        end;
        Exit;
      end;

      // A cancel that arrived before we even started this request (the
      // reader noted it while earlier messages were being handled).
      if LMsg.IsRequest and FCancels.IsCancelled(LMsg.IdJson) then
        Exit(BuildError(LMsg.IdJson, LSP_REQUEST_CANCELLED,
          'request cancelled'));

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
      if LMsg.Method = 'workspace/didChangeWatchedFiles' then
      begin
        HandleDidChangeWatchedFiles(LMsg.Params);
        Exit;
      end;
      if LMsg.Method = 'textDocument/didSave' then
        Exit;   // we advertise no save interest; harmless if sent anyway
      if LMsg.Method = 'textDocument/definition' then
        Exit(HandleDefinition(LMsg));
      if LMsg.Method = 'textDocument/references' then
        Exit(HandleReferences(LMsg));
      if LMsg.Method = 'textDocument/implementation' then
        Exit(HandleToggle(LMsg, {AToImpl} True));
      if LMsg.Method = 'textDocument/declaration' then
        Exit(HandleToggle(LMsg, {AToImpl} False));
      if LMsg.Method = 'textDocument/documentSymbol' then
        Exit(HandleDocumentSymbol(LMsg));
      if LMsg.Method = 'textDocument/hover' then
        Exit(HandleHover(LMsg));
      if LMsg.Method = 'textDocument/typeDefinition' then
        Exit(HandleTypeDefinition(LMsg));
      if LMsg.Method = 'textDocument/documentHighlight' then
        Exit(HandleDocumentHighlight(LMsg));
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
    // Answered (or never will be) — late cancels for this id are meaningless.
    if LMsg.IsRequest then
      FCancels.Retire(LMsg.IdJson);
    LMsg.Root.Free;
  end;
end;

end.
