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
    "logFile", "logUnits" — where the log goes, and whether it inventories
                  every unit of the closure
    "moduleRedoLimit" — the incremental fast path's blast-radius ceiling;
                  0 keeps PasTree's measured default
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
  PasLsp.Documents,
  PasLsp.Completion,
  PasLsp.ClassComplete,
  PasLsp.SourceText,
  PasLsp.XmlDoc,
  PasLsp.ProductVersion,
  PasLsp.Version,
  PasTree.Version;

type
  { A planned rename, whichever identity it turned out to be - one record
    rather than seven out-parameters, because every handler needs the same
    set and a unit rename keeps adding to it.

    IsUnit says which plan this is. For a UNIT: RequiredFileName is what the
    file MUST be called afterwards (Object Pascal ties the two), UnitPath is
    the file as it is now, NewFilePath is the two combined, and StaleInPaths
    lists the project files whose `uses ... in '...'` still spells the old
    file name - the one part of a unit rename no plan can express (see
    UsesInPathSites). All of those are empty for a symbol rename. }
  TLspRenamePlanned = record
    IsUnit: Boolean;
    OldName: string;
    RequiredFileName: string;
    UnitPath: string;
    NewFilePath: string;
    StaleInPaths: TArray<string>;
    Edits: TArray<TPasRenameEdit>;
  end;

  TLspServer = class
  private
    FInitialized: Boolean;
    FShutdownSeen: Boolean;
    FExitRequested: Boolean;
    FExitCode: Integer;
    FTrace: Boolean;
    // Log one line per unit in the closure? Off by default - see
    // LogParseRecord's header for what stays on regardless.
    FLogUnits: Boolean;
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
    // The completion seam's engine (PasLsp.Completion) - configuration-
    // derived, so created lazily once and kept for the session.
    FCompletion: TLspCompletionEngine;
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
    // The same two signatures split into their per-document parts: what tells
    // a ONE-FILE edit (the incremental fast path) from any other change to
    // the inputs - a document opened, closed, saved, or two edited at once.
    FBuiltParts: TArray<string>;
    FStartedParts: TArray<string>;
    // INCREMENTAL REANALYSIS (PasTree's stage B). When the only thing that
    // changed is the text of one already-analyzed unit, the in-flight session
    // is a TPasAsyncSession.CreateForModule one over FModuleFile instead of a
    // closure rebuild: tens of milliseconds against seconds. Since PasTree
    // 0.10.0 that covers INTERFACE edits too - the library redoes the units
    // the change can reach instead of refusing - so the fast path is the
    // ordinary case rather than the body-edit special case. It may still
    // REFUSE (a blast radius over ModuleRedoLimit, a new import, an $IF
    // oracle unit, and the rest of AnalyzeModuleOnly's guard list), and then
    // the project comes back UNTOUCHED and we start the real rebuild with it
    // as the parse donor.
    FModuleMode: Boolean;
    FModuleFile: string;
    // The blast-radius ceiling handed to the project before a module run;
    // 0 = leave PasTree's own default (128, a measured value). See the
    // "moduleRedoLimit" initialization option.
    FModuleRedoLimit: Integer;
    // Set for exactly the rebuild that follows a refusal: the inputs still
    // look like a one-file edit, so without it the next StartAnalysis would
    // hand the same edit to the same guards forever.
    FNoModuleOnce: Boolean;
    // The client process, watched so a dead client cannot leave this one
    // running (see StartClientWatchdog); 0 = not watching.
    FClientHandle: THandle;
    // Work-done progress (server-initiated). Reporting is gated on the
    // client's window.workDoneProgress capability, and the token is created
    // with a REQUEST the client may refuse - see StartProgress.
    FClientProgress: Boolean;
    { Does the client accept a FILE RENAME inside a WorkspaceEdit? Read from
      capabilities.workspace.workspaceEdit.resourceOperations at initialize.
      A unit rename is text edits AND a file rename, so a client without this
      is refused rather than handed the half that does not compile. }
    FClientRenamesFiles: Boolean;     // client supports server-initiated progress
    FProgressToken: string;       // '' = no progress stream open
    FProgressCreateId: Integer;   // id of the create request awaiting a reply
    FNextServerId: Integer;       // our own id space for server->client calls
    FProgressSeq: Integer;        // makes each token unique within a session
    FLastReportTick: UInt64;
    procedure AppendLog(const AText: string);
    procedure Log(const AMsg: string);
    procedure LogBlock(const ALines: TArray<string>);
    procedure LogParseRecord;
    procedure Notify(const AJson: string);
    procedure StartClientWatchdog(APid: Integer);
    function FileMatches(const APath, AText, ADiskText: string): Boolean;
    function OverlaySignature: string;
    function OverlayParts: TArray<string>;
    function SingleChangedDoc(out APath: string): Boolean;
    function TryStartModuleAnalysis: Boolean;
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
    function HandleCompletion(const AMsg: TLspIncoming): string;
    function HandleSignatureHelp(const AMsg: TLspIncoming): string;
    function HandleWorkspaceSymbol(const AMsg: TLspIncoming): string;
    function HandleClassComplete(const AMsg: TLspIncoming): string;
    function HandlePrepareRename(const AMsg: TLspIncoming): string;
    function HandleRename(const AMsg: TLspIncoming): string;
    function HandleRenamePlan(const AMsg: TLspIncoming): string;
    function PlanRenameAt(const APath: string; APasLine, APasCol: Integer;
      const ANewName: string; out APlan: TLspRenamePlanned;
      out AError: string): Boolean;
    function UsesInPathSites(ATargetMid: Integer;
      const AUnitPath: string): TArray<string>;
    procedure SyncCompletionOverlays;
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
  FLogUnits := GetEnvironmentVariable('PASTREE_LSP_LOG_UNITS') <> '';
  FLogPath := GetEnvironmentVariable('PASTREE_LSP_LOG');
end;

destructor TLspServer.Destroy;
begin
  if FClientHandle <> 0 then
    CloseHandle(FClientHandle);
  FCompletion.Free;
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
{ ONE APPEND, SHARED WITH THE OTHER WRITERS OF THIS FILE.

  Not TFile.AppendAllText any more, and the reason is not performance: that
  opens the file denying write to everyone else, and this log now has two more
  writers. The IDE package hands the CHILD's stderr an append handle on this
  very file (so a server that dies before it can log anything still says why,
  in the place people read), and the same package's crash recorder writes here
  when the IDE itself faults. A deny-write open turns each of those into a
  sharing violation.

  FILE_APPEND_DATA with FILE_SHARE_READ or FILE_SHARE_WRITE is what makes that
  safe rather than merely possible: a write through an append handle is atomic
  against other appenders - the OS positions it at the current end - so lines
  from three writers interleave whole, never halfway.

  A collision still loses the race for the OPEN, which is what the retries are
  for. Losing all of them drops ONE line and keeps the log; only a path that
  cannot be opened at all (a bad directory, a denied share) turns logging off,
  and only on the first attempt - a log that switches itself off mid-session
  because a tail happened to hold the file is worse than no log at all, since
  it looks exactly like a server that stopped working. }
procedure TLspServer.AppendLog(const AText: string);
const
  cRetries = 20;
  cRetryMs = 5;
var
  LFile: THandle;
  LBytes: TBytes;
  LWritten: DWORD;
  LTry: Integer;
begin
  LFile := INVALID_HANDLE_VALUE;
  for LTry := 1 to cRetries do
  begin
    LFile := CreateFile(PChar(FLogPath), FILE_APPEND_DATA,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if LFile <> INVALID_HANDLE_VALUE then
      Break;
    if GetLastError <> ERROR_SHARING_VIOLATION then
    begin
      // Unwritable, not busy. Only give up on the log if we never wrote to
      // it - a path that worked and then broke is worth retrying next line.
      if not FLogStarted then
        FLogPath := '';
      Exit;
    end;
    Sleep(cRetryMs);
  end;
  if LFile = INVALID_HANDLE_VALUE then
    Exit;   // busy for 100 ms; drop the line, keep the log
  try
    LBytes := TEncoding.UTF8.GetBytes(AText);
    if Length(LBytes) > 0 then
      WriteFile(LFile, LBytes[0], Length(LBytes), LWritten, nil);
  finally
    CloseHandle(LFile);
  end;
end;

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
  if not FLogStarted then
  begin
    // Separator instead of truncation: successive runs stay in one file,
    // and "which run is this" stays answerable.
    LLine := StringOfChar('-', 64) + sLineBreak + LLine;
  end;
  AppendLog(LLine);
  // After the write, not before: AppendLog decides "unwritable path" by
  // whether anything has ever been logged, and clears FLogPath if not.
  if FLogPath <> '' then
    FLogStarted := True;
end;

{ Many lines, ONE file write.

  Log() opens and closes the file per line, which is the right trade for the
  handful of lines a request produces but the wrong one for the parse record:
  a project with missing search paths can produce thousands of diagnostics, and
  a thousand open/close cycles is slow enough to be felt in the analysis timing
  the log is there to report. Same append-with-separator semantics otherwise. }
procedure TLspServer.LogBlock(const ALines: TArray<string>);
var
  LSB: TStringBuilder;
  LLine, LStamp: string;
begin
  if Length(ALines) = 0 then
    Exit;
  if not FTrace and (FLogPath = '') then
    Exit;   // nothing to write it to; do not pay for the formatting
  LStamp := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ';
  LSB := TStringBuilder.Create;
  try
    for LLine in ALines do
    begin
      if FTrace then
        Writeln(ErrOutput, '[pastree-lsp] ' + LLine);
      LSB.Append(LStamp).Append(LLine).Append(sLineBreak);
    end;
    if FLogPath = '' then
      Exit;
    if not FLogStarted then
      AppendLog(StringOfChar('-', 64) + sLineBreak + LSB.ToString)
    else
      AppendLog(LSB.ToString);
    if FLogPath <> '' then
      FLogStarted := True;
  finally
    LSB.Free;
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
    // The closure inventory: verbose enough to bury the rest of the log, so a
    // client asks for it explicitly (the environment variable stays as the
    // no-client escape hatch).
    if AOptions.GetValue<Boolean>('logUnits', False) then
      FLogUnits := True;
    // The incremental fast path's blast-radius ceiling: over this many
    // affected units an interface edit rebuilds instead. PasTree's default
    // (128) is measured rather than guessed - about 300 ms fixed plus ~57 ms
    // per unit against a 29 s rebuild on a 3676-unit closure, so break-even
    // is near 500 - and the reason to name it here is that the right value
    // depends on the closure: a project whose core types unit reaches a
    // third of the closure wants a lower one, a small project can lift it
    // entirely with a negative value. 0 = say nothing, keep the library's.
    FModuleRedoLimit := AOptions.GetValue<Integer>('moduleRedoLimit', 0);
  end;

  // FIRST line of the run, before anything that could go wrong: a log whose
  // opening line does not say which build produced it is worth much less than
  // one that does - especially across a rebuild, where "did my fix even get
  // into the exe the IDE is running" is the first question worth asking.
  Log(PasLspVersionBanner);

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
  // THE PATHS THEMSELVES, not just how many. A count tells you nothing about
  // the failure this actually has: a plausible-looking number of paths that
  // happen to be the wrong directories (the IDE plugin sent three that did not
  // contain the RTL for months) reads as a healthy configuration right up until
  // every F1027 in the parse record.
  var LLines: TArray<string> := nil;
  for LItem in FSearchPaths do
    LLines := LLines + ['  path ' + LItem];
  for LItem in FDefines do
    LLines := LLines + ['  define ' + LItem];
  for LItem in FNamespaces do
    LLines := LLines + ['  namespace ' + LItem];
  for LAlias in FAliases do
    LLines := LLines + [Format('  alias %s=%s', [LAlias.Alias, LAlias.UnitName])];
  LogBlock(LLines);
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
  FModuleMode := False;
  FModuleFile := '';
  // The keystroke case first: one already-analyzed unit's text changed and
  // nothing else did. If PasTree's guards accept it this costs tens of
  // milliseconds; if they refuse, the rebuild below runs instead, one
  // finalize later, with the untouched project as its parse donor.
  if TryStartModuleAnalysis then
    Exit;

  // The tripwire for the 4.5x described in SPEC.md, deliberately placed FAR
  // from the assignment it guards (the first statement of pastree-server.dpr):
  // a guard next to the line it checks catches nothing, since deleting one
  // deletes the other. Logged rather than raised - a slow analysis is still a
  // working one, and the log is where a slowdown is diagnosed anyway.
  if not System.NeverSleepOnMMThreadContention then
    Log('WARNING: NeverSleepOnMMThreadContention is False. The analysis will'
      + ' run several times slower than it should (measured 4.5x) because the'
      + ' memory manager sleeps on allocation contention instead of spinning.'
      + ' Set it at startup - see pastree-server.dpr and SPEC.md.');
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
  // PARSE REUSE (PasTree's stage A): the last-good project donates the parse
  // of every unit whose text - main file and every $I include - is byte-for-
  // byte what this run would read. It must outlive the build, and it does:
  // FProject is only freed in FinalizeAnalysisIfDone, after the worker is
  // done. AFTER the namespace/alias calls above, which the donor gate
  // compares. False means the configuration moved and the donor was refused;
  // the run then parses everything, which is only the old cost.
  if FProject <> nil then
    if not FSession.SetParseDonor(FProject) then
      Log('parse donor refused: the analysis configuration changed');
  // Document truth, stamped with the client's version — compared on
  // completion to catch a snapshot that went stale mid-build.
  for LDoc in FDocs.All do
    FSession.SetBuffer(LDoc.Path, LDoc.Text, LDoc.Version);
  FDirty := False;   // this session covers everything up to now
  FPendingDue := 0;  // whatever was scheduled is covered by this start
  FPendingPriority := '';
  FStartedParts := OverlayParts;
  FStartedSignature := string.Join(',', FStartedParts);
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

{ WHAT WAS ACTUALLY PARSED, AND EVERYTHING WRONG WITH IT — the whole closure,
  every unit and every diagnostic, written once per completed analysis.

  Not a debug-only extra. The client sees a null answer and can say only "no
  identifier/declaration resolved at cursor"; the reason lives here or nowhere.
  Two questions come up over and over and both are answered by this block and
  nothing else:

    - "Is the unit this identifier comes from even in the closure, and WHICH
      FILE was picked for it?" A wrong file on the search path (an older copy
      of a library, two SynEdit checkouts) resolves to real declarations in the
      wrong place, which no per-request line can reveal.
    - "Which diagnostics does the analysis have?" PublishDiagnostics sends only
      the OPEN documents' to the editor - that is the right scope for squiggles
      and the wrong one for debugging, because an F1027 on a unit nobody has
      open is precisely what breaks navigation in the file they do have open.

  THE PER-UNIT LINES ARE OFF BY DEFAULT since 2026-08-23, at the user's call:
  on a real project they are ~200 (3757 on the reference one) lines of "unit x
  <- path" per rebuild, and a log nobody can skim is a log nobody reads. What
  stays unconditional is everything that reports a PROBLEM - the unit count,
  every diagnostic with its position, and the units that could not be loaded -
  so the log still answers "is the analysis healthy" on its own. Turn the
  inventory back on for the one question it exists for ("which file won for
  this unit name?") with the `logUnits` initialization option, or
  PASTREE_LSP_LOG_UNITS=1 in the environment for a session where no client
  passes options. Both are read once, at initialize. }
procedure TLspServer.LogParseRecord;
var
  LLines: TArray<string>;
  LMi, LDi, LFileId, LTotal: Integer;
  LModel: TPasSemaModel;
  LFile: string;
begin
  if FProject = nil then
    Exit;
  LLines := ['parsed closure: ' + IntToStr(FProject.ModelCount) + ' units'];
  LTotal := 0;
  for LMi := 0 to FProject.ModelCount - 1 do
  begin
    LModel := FProject.Model(LMi);
    Inc(LTotal, Length(LModel.Diags));
    // The FULL path, not the file name: which of several copies on the search
    // path won is exactly the thing this line exists to answer. Logged for
    // EVERY unit only when asked (see the header); a unit that has
    // diagnostics is logged either way, because the position lines under it
    // are meaningless without knowing which file they are in.
    if FLogUnits or (Length(LModel.Diags) > 0) then
      LLines := LLines + [Format('  unit %s <- %s%s',
        [LModel.UnitNameLower, FProject.ModelFile(LMi),
         IfThen(Length(LModel.Diags) = 0, '',
           Format(' (%d diagnostics)', [Length(LModel.Diags)]))])];
    for LDi := 0 to High(LModel.Diags) do
    begin
      // FileId indexes the model's own file table, so a diagnostic raised
      // inside an $I include is attributed to the include - same rule
      // PublishDiagnostics follows, for the same reason.
      LFileId := LModel.Diags[LDi].FileId;
      if (LFileId >= 0) and (LFileId <= High(LModel.Tree.Source.FileNames)) then
        LFile := LModel.Tree.Source.FileNames[LFileId]
      else
        LFile := FProject.ModelFile(LMi);
      LLines := LLines + [Format('    %s %s: %s',
        [PosTag(LFile, LModel.Diags[LDi].Line, LModel.Diags[LDi].Col),
         LModel.Diags[LDi].Code, LModel.Diags[LDi].Msg])];
    end;
  end;
  LLines := LLines + [Format('parsed closure: %d diagnostics total', [LTotal])];
  LogBlock(LLines);
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
  LStale, LWasModule: Boolean;
  LError: string;
begin
  if (FSession = nil) or not FSession.IsDone then
    Exit;
  LError := FSession.LastError;
  if LError <> '' then
    Tell(1, 'PasTree: the analysis failed - ' + LError, True);
  // A REFUSED module session (see TryStartModuleAnalysis): the project comes
  // back exactly as it went in, so nothing about the analyzed state changed -
  // no diagnostics to republish, no parse record to re-log, and the built
  // signature still describes what this project holds. Take it back, then
  // start the real rebuild, which picks it up as the parse donor.
  if FModuleMode and not FSession.ModuleAccepted then
  begin
    FProject := FSession.TakeProject;
    FreeAndNil(FSession);
    FModuleMode := False;
    if FProject <> nil then
      FNav := TPasNavigator.Create(FProject);
    Log(Format('incremental refused for %s (%s) - full rebuild',
      [FModuleFile, IfThen(FProject = nil, 'no project returned',
        FProject.StageTimings)]));
    FNoModuleOnce := True;
    StartAnalysis(FModuleFile);
    Exit;
  end;
  FreeAndNil(FNav);
  FreeAndNil(FProject);
  FProject := FSession.TakeProject;
  FreeAndNil(FSession);
  if FProject = nil then
    Exit;
  FNav := TPasNavigator.Create(FProject);
  FBuiltSignature := FStartedSignature;
  FBuiltParts := FStartedParts;
  LWasModule := FModuleMode;
  FModuleMode := False;
  // The whole-closure diagnostic count (open docs get theirs listed by
  // PublishDiagnostics below): a healthy run on a fully-pathed project is
  // near zero, so a big number here means missing search paths (F1027
  // gating) long before any individual click misbehaves.
  var LDiagTotal := 0;
  for var LMi := 0 to FProject.ModelCount - 1 do
    Inc(LDiagTotal, Length(FProject.Model(LMi).Diags));
  EndProgress(Format('%d units in %d ms',
    [FProject.ModelCount, GetTickCount64 - FBuildStart]));
  Log(Format('analysis %s: %d units in %d ms, %d diagnostics in closure;'
    + ' stages %s',
    [IfThen(LWasModule, 'done (incremental)', 'done'), FProject.ModelCount,
     GetTickCount64 - FBuildStart, LDiagTotal, FProject.StageTimings]));
  // Every unit and every diagnostic, not just the open documents' - see
  // LogParseRecord for why that difference is the whole point.
  //
  // NOT after an accepted incremental run: the closure is the one this
  // already recorded, unit for unit and file for file, and the questions the
  // record answers ("which copy of this unit won?", "what did the analysis
  // fail to load?") are rebuild questions. Writing it per keystroke would
  // walk every model of a 3676-unit project and bury the rebuild that
  // matters under a hundred repetitions of itself. The stages field above
  // carries what IS new - module=<radius>, or module=refused:<reason>.
  if not LWasModule then
    LogParseRecord;

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
begin
  // The cheap answer first: the two decoded strings are already equal, so no
  // file needs reading. Only a decode DISAGREEMENT gets as far as the bytes.
  Result := (AText = ADiskText) or FileHoldsText(APath, AText);
end;

{ The inputs the analysis would see, as a comparable string: every open
  document whose text DIFFERS from its file, by path and content hash.

  Non-differing documents are deliberately absent. Their file holds the same
  content, so listing them would make merely LOOKING at a file (an open
  followed by a close) change the signature and force a rebuild - which is the
  churn this exists to stop. The overlay is still handed to the analysis for
  them; what it buys there is the editor's own decoding of the bytes, which is
  not worth a rebuild on its own. }
function TLspServer.OverlayParts: TArray<string>;
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
    Result := LParts.ToStringArray;
  finally
    LParts.Free;
  end;
end;

function TLspServer.OverlaySignature: string;
begin
  Result := string.Join(',', OverlayParts);
end;

{ Did EXACTLY ONE document's text change since the last completed analysis?

  The parts are sorted and one per differing document, `path|len|hash`, so the
  two lists line up position by position and the answer is a single walk: same
  length, and exactly one position where the parts differ while their PATHS
  match. Anything else - a document opened, closed, saved back to its file, or
  two edited between builds - is not a one-file edit and gets the full
  rebuild. Deliberately strict: the fast path is only sound for a change the
  guards in AnalyzeModuleOnly actually inspected, and they inspect one unit. }
function PartPath(const APart: string): string;
begin
  Result := Copy(APart, 1, Pos('|', APart) - 1);
end;

{ Did EXACTLY ONE document's text change since the last completed analysis?

  A MERGE OF TWO SORTED SETS, not a position-by-position compare, and the
  difference is the whole point. Each list holds one entry per document whose
  text OVERRIDES its file (`path|len|hash`, see OverlayParts), so a single
  file's text can change in three ways, and the first version of this
  recognised only one of them:

    hash differs   - an edit on top of an edit
    path APPEARS   - the FIRST edit to a file: it stops matching its disk
                     text and joins the set
    path DISAPPEARS - the file was saved, or closed unsaved: it stops
                     overriding, and the text that counts is the file's again

  Comparing by position made an appearance or a disappearance look like a set
  change and rebuilt the closure - so the first keystroke in each file, and
  every save, paid a full rebuild. On a 3676-unit project that is 29 seconds
  for the one keystroke that begins a session in a file.

  All three are ONE FILE's text changing, which is exactly what the fast path
  handles: AnalyzeModuleOnly re-reads that path's current effective text
  (buffer overlay if there is one, the file if not), so a disappearance is as
  correct a fast-path input as an edit. Two or more differing paths, in any
  combination, disqualify it - PasTree's entry point takes one path, and its
  guards inspected one unit.

  A save where the buffer already held the file's text produces a
  disappearance with nothing behind it: no rebuild is needed at all, and this
  still spends one module run on it. Cheap, and simpler than proving it. }
function TLspServer.SingleChangedDoc(out APath: string): Boolean;
var
  LNow: TArray<string>;
  LI, LJ, LFound: Integer;
  LLeft, LRight: string;
begin
  APath := '';
  LNow := OverlayParts;
  if FProject = nil then
    Exit(False);
  LI := 0;
  LJ := 0;
  LFound := 0;
  // Both lists are sorted by their whole `path|len|hash` string, so they are
  // sorted by path, so this walks them in step.
  while (LI <= High(LNow)) or (LJ <= High(FBuiltParts)) do
  begin
    if LI > High(LNow) then
      LLeft := ''
    else
      LLeft := PartPath(LNow[LI]);
    if LJ > High(FBuiltParts) then
      LRight := ''
    else
      LRight := PartPath(FBuiltParts[LJ]);
    if (LRight = '') or ((LLeft <> '') and (LLeft < LRight)) then
    begin
      APath := LLeft;          // appeared: the first edit to this file
      Inc(LFound);
      Inc(LI);
    end
    else if (LLeft = '') or (LRight < LLeft) then
    begin
      APath := LRight;         // disappeared: saved, or closed unsaved
      Inc(LFound);
      Inc(LJ);
    end
    else
    begin
      if LNow[LI] <> FBuiltParts[LJ] then
      begin
        APath := LLeft;        // same file, different text
        Inc(LFound);
      end;
      Inc(LI);
      Inc(LJ);
    end;
    if LFound > 1 then
      Exit(False);
  end;
  Result := LFound = 1;
  if not Result then
    APath := '';
end;

{ The keystroke path: re-analyze ONE unit in place instead of rebuilding the
  closure. True = a module session is now running and StartAnalysis is done.

  Ownership: CreateForModule TAKES the project, so FProject/FNav go to nil for
  the (tens of milliseconds) the session runs - requests reach it through
  WaitAnalyzed like any other in-flight build. The project comes back through
  TakeProject either updated or untouched; FinalizeAnalysisIfDone reads
  ModuleAccepted to tell which, and rebuilds for real on a refusal. }
function TLspServer.TryStartModuleAnalysis: Boolean;
var
  LPath: string;
  LId: Integer;
  LDoc: TLspDocument;
begin
  Result := False;
  if FNoModuleOnce then
  begin
    FNoModuleOnce := False;
    Exit;
  end;
  if (FProject = nil) or not SingleChangedDoc(LPath) then
    Exit;
  // It has to be a unit this project already analyzed - a file the closure
  // never reached has no model to swap.
  LId := FProject.ModelIdOf(LPath);
  if LId < 0 then
    Exit;
  // THE PROJECT'S SPELLING OF THE PATH, not the signature's. OverlayParts
  // lowercases so two spellings of one file compare equal; handing that key
  // to the analysis makes the re-analyzed model carry it, and every position
  // answered out of that model then comes back as file:///c%3A/repos/.../
  // demounit.pas - a different document as far as an editor is concerned,
  // which is how this was caught (LspClientSmoke 5c, the URI changed case
  // after the first incremental run). ModelFile is the path the closure
  // loaded, so the swap keeps the model's identity exactly as it was.
  LPath := FProject.ModelFile(LId);
  FStartedParts := OverlayParts;
  FStartedSignature := string.Join(',', FStartedParts);
  FModuleFile := LPath;
  FModuleMode := True;
  // Set on the project rather than kept by the session, and set here rather
  // than once at startup: every full rebuild produces a NEW project carrying
  // PasTree's default, so the configured ceiling has to be re-applied to
  // whichever project is about to take the module run.
  if FModuleRedoLimit <> 0 then
    FProject.ModuleRedoLimit := FModuleRedoLimit;
  FSession := TPasAsyncSession.CreateForModule(FProject, LPath);
  FProject := nil;          // the session owns it now
  FreeAndNil(FNav);         // and the navigator pointed into it
  // Every overlay, not just the edited one: the project's buffer table has to
  // stay the truth about what the editor holds, exactly as a full session
  // leaves it.
  for LDoc in FDocs.All do
    FSession.SetBuffer(LDoc.Path, LDoc.Text, LDoc.Version);
  FDirty := False;
  FPendingDue := 0;
  FPendingPriority := '';
  FBuildStart := GetTickCount64;
  Log(Format('analysis started: incremental, one module (%s)', [LPath]));
  FSession.Start;
  Result := True;
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
  LMid, LIdx, LFileId, LLine, LChar, LEndChar, LEndLine: Integer;
  LModel: TPasSemaModel;
  LDiagFile, LKey: string;
  LSB: TStringBuilder;
  LFirst, LMainIsDoc: Boolean;
  LIdent: TPasNavIdent;
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
        // Whether this open doc IS the model's main file - the only space
        // IdentAt's coordinates live in. False for an open $I include.
        LMainIsDoc := LowerCase(TPath.GetFullPath(
          FProject.ModelFile(LMid))) = LKey;
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
          // Deliberately NOT logged here any more: LogParseRecord already
          // wrote every diagnostic in the closure, including these, right
          // above. Logging them a second time only made the open documents'
          // subset look like the whole picture, which is the misreading that
          // cost a debugging session.
          if not LFirst then
            LSB.Append(',');
          LFirst := False;
          PasTreeToLsp(LModel.Diags[LIdx].Line, LModel.Diags[LIdx].Col,
            LLine, LChar);
          // The range END: most diagnostics anchor on an identifier
          // (E2003 and family), and a one-character range draws as a
          // stub of a squiggle (first live run of the painted route,
          // 2026-08-22 - the "very small line" was THIS, not the client's
          // pixel math). IdentAt at the diagnostic's own position hands
          // back the identifier's full span; anything without one
          // (a missing ';', a structural error) keeps the one-character
          // range, which is also what dcc's own caret amounts to.
          LEndChar := LChar + 1;
          if LMainIsDoc and
             FNav.IdentAt(LMid, LModel.Diags[LIdx].Line,
               LModel.Diags[LIdx].Col, LIdent) and
             (LIdent.Line = LModel.Diags[LIdx].Line) and
             (LIdent.ColTo > LIdent.ColFrom) then
          begin
            PasTreeToLsp(LIdent.Line, LIdent.ColTo, LEndLine, LEndChar);
            if LEndChar <= LChar then
              LEndChar := LChar + 1;
          end;
          LSB.Append(Format(
            '{"range":{"start":{"line":%d,"character":%d},' +
            '"end":{"line":%d,"character":%d}},' +
            '"severity":%d,"code":%s,"source":"pastree","message":%s}',
            [LLine, LChar, LLine, LEndChar,
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

{ Does this client accept a file rename inside a WorkspaceEdit?

  capabilities.workspace.workspaceEdit.resourceOperations is an array of the
  operations the client can apply - "create", "rename", "delete". Absent
  means the client supports NONE of them (the specification says so
  explicitly), which is why the default here is False rather than
  permissive: a unit rename sent to a client that then drops the rename
  operation leaves the text edits applied and the file misnamed, i.e. a
  project that no longer compiles. VS Code advertises all three. }
function ClientRenamesFiles(AParams: TJSONValue): Boolean;
var
  LOps: TJSONArray;
  LOp: TJSONValue;
begin
  Result := False;
  if (AParams = nil) or not AParams.TryGetValue<TJSONArray>(
    'capabilities.workspace.workspaceEdit.resourceOperations', LOps) then
    Exit;
  for LOp in LOps do
    if SameText(LOp.Value, 'rename') then
      Exit(True);
end;

function TLspServer.HandleInitialize(const AMsg: TLspIncoming): string;
begin
  if AMsg.Params <> nil then
    ApplyInitOptions(AMsg.Params.FindValue('initializationOptions'))
  else
    ApplyInitOptions(nil);
  if AMsg.Params <> nil then
  begin
    FClientProgress := AMsg.Params.GetValue<Boolean>(
      'capabilities.window.workDoneProgress', False);
    FClientRenamesFiles := ClientRenamesFiles(AMsg.Params);
    StartClientWatchdog(AMsg.Params.GetValue<Integer>('processId', 0));
  end;
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
      '"documentHighlightProvider":true,' +
      '"completionProvider":{"triggerCharacters":["."]},' +
      '"signatureHelpProvider":{"triggerCharacters":["(",","]},' +
      '"workspaceSymbolProvider":true,' +
      '"renameProvider":{"prepareProvider":true}' +
    // pastreeVersion is ours, not LSP's. It rides along inside serverInfo
    // because a client's real question is never "which server build is this"
    // but "does it have the analysis fix I need", and that lives in PasTree.
    // Unknown members of serverInfo are ignored by every conforming client.
    '},"serverInfo":{"name":"pastree-lsp-server","version":' +
      JsonQuote(PasTreeLspVersion) + ',"pastreeVersion":' +
      JsonQuote(PasTreeVersion) + '}}');
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
  // A leading BOM is not content — see StripLeadingBom. Before the gate
  // below, so a BOM'd file still compares equal to its own bytes on disk.
  LText := StripLeadingBom(AParams.GetValue<string>('textDocument.text', ''));
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
    Log(Format('textDocument/didOpen %s v%d (unsaved: %d chars here, %d on disk)',
      [LPath, LVersion, Length(LText), Length(LDisk)]))
  else
    Log(Format('textDocument/didOpen %s v%d', [LPath, LVersion]));
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
      LText := StripLeadingBom(LNew);   // full replacement (resync)
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
    Log(Format('textDocument/didChange %s v%d (full, %d chars)',
      [LPath, LVersion, Length(LText)]))
  else
    Log(Format('textDocument/didChange %s v%d (%d edits, now %d chars)',
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
  Log('textDocument/didClose ' + LPath);
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
    Log(AMsg.Method + ': file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  // Failures answer null to the client (per protocol) but SAY WHY in the
  // log — "F12 did nothing" is otherwise undebuggable from the outside.
  if not FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
  begin
    Log(Format(AMsg.Method + ': %s no identifier at that position',
      [PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  if not FNav.ResolveDecl(LMid, LIdent.Node, LTarget) then
  begin
    Log(Format(AMsg.Method + ': %s ''%s'' did not resolve to a source'
      + ' declaration (unresolved name, or a builtin with none)',
      [PosTag(LPath, LPasLine, LPasCol), LIdent.Name]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format(AMsg.Method + ': %s ''%s'' -> %s',
    [PosTag(LPath, LPasLine, LPasCol), LIdent.Name,
     PosTag(LTarget.FilePath, LTarget.Line, LTarget.Col)]));
  Result := BuildResponse(AMsg.IdJson,
    LocationJson(LTarget.FilePath, LTarget.Line, LTarget.Col,
      Length(LTarget.Name)));
end;

{ textDocument/completion — the answers come from PasLsp.Completion, which
  runs PasTree's completion engine over a fresh single-file parse of the live
  overlay text, BRIDGED to the last completed analysis when this file is in
  its closure (see that unit's header for the pipeline).

  THE ONE DELIBERATE DIFFERENCE from every other request handler: NO
  WaitAnalyzed. That helper flushes the pending rebuild and blocks until the
  whole closure is analyzed — right for a click on stable code, wrong per
  keystroke (a full rebuild is ~15 s on the reference project). Completion
  answers from what exists RIGHT NOW: the live overlay text always (that is
  what the user is typing into), bridged to whatever analysis snapshot is
  ready — or standalone (locals, own-unit names, keywords) when none is. It
  does not schedule a rebuild either; didChange already did. }
// The item's data member (',"data":{...}') - our own side channel: the
// routine head word for the RAD viewer's class column, hasParams for its
// auto-parenthesis. '' when there is nothing to carry.
{ textDocument/signatureHelp — same rules as completion: never WaitAnalyzed,
  the live overlay text is the truth, answered by the engine's CallAt
  through the seam (member calls and freshly typed cross-unit calls both
  resolve; the interim locator this replaced could do neither).
  The call-open position rides the answer as "pastreeCall" for the RAD
  client's hint anchor; standard clients ignore unknown members. }
function TLspServer.HandleSignatureHelp(const AMsg: TLspIncoming): string;
var
  LPath, LText: string;
  LLine, LChar, LPasLine, LPasCol, LIdx, LPrm, LMid: Integer;
  LDoc: TLspDocument;
  LAnswer: TLspSignatureHelpAnswer;
  LStart: UInt64;
  LSB: TStringBuilder;
  LCallLine, LCallChar: Integer;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'signatureHelp: textDocument.uri and position required'));

  LStart := GetTickCount64;
  if FDocs.TryGet(LPath, LDoc) then
    LText := LDoc.Text
  else if not TryReadTextNoBom(LPath, LText) then
    LText := '';

  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if LText = '' then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  if FCompletion = nil then
    FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
      FDefines);
  SyncCompletionOverlays;
  LMid := -1;
  if FNav <> nil then
    LMid := FNav.ModelIdOf(LPath);
  if (FProject <> nil) and (LMid >= 0) then
    LAnswer := FCompletion.SignatureHelpAt(LPath, LText, LPasLine, LPasCol,
      FProject, LMid)
  else
    LAnswer := FCompletion.SignatureHelpAt(LPath, LText, LPasLine, LPasCol,
      nil, -1);

  Log(Format('signatureHelp: %s -> %d signatures, arg %d in %d ms (%s)',
    [PosTag(LPath, LPasLine, LPasCol), Length(LAnswer.Signatures),
     LAnswer.ActiveParam, GetTickCount64 - LStart, LAnswer.Provider]));
  if Length(LAnswer.Signatures) = 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LSB := TStringBuilder.Create;
  try
    for LIdx := 0 to High(LAnswer.Signatures) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append('{"label":')
         .Append(JsonQuote(LAnswer.Signatures[LIdx].SigLabel))
         .Append(',"parameters":[');
      for LPrm := 0 to High(LAnswer.Signatures[LIdx].Params) do
      begin
        if LPrm > 0 then
          LSB.Append(',');
        LSB.Append('{"label":')
           .Append(JsonQuote(LAnswer.Signatures[LIdx].Params[LPrm]))
           .Append('}');
      end;
      LSB.Append(']}');
    end;
    PasTreeToLsp(LAnswer.CallLine, LAnswer.CallCol, LCallLine, LCallChar);
    Result := BuildResponse(AMsg.IdJson, Format(
      '{"signatures":[%s],"activeSignature":%d,"activeParameter":%d,'
      + '"pastreeCall":{"line":%d,"character":%d}}',
      [LSB.ToString, LAnswer.ActiveSignature, LAnswer.ActiveParam,
       LCallLine, LCallChar]));
  finally
    LSB.Free;
  end;
end;

// LSP SymbolKind (NOT CompletionItemKind - different table) for a PasTree
// symbol, refined by the type category where the model knows one.
function WorkspaceSymbolKind(AKind: TSemaSymbolKind;
  ACat: TSemaTypeCat): Integer;
begin
  case AKind of
    skType, skBuiltinType:
      case ACat of
        tcInterface: Result := 11;  // Interface
        tcRecord:    Result := 23;  // Struct
        tcEnum:      Result := 10;  // Enum
      else
        Result := 5;                // Class
      end;
    skVar:       Result := 13;      // Variable
    skConst:     Result := 14;      // Constant
    skField:     Result := 8;       // Field
    skRoutine:   Result := 12;      // Function
    skProperty:  Result := 7;       // Property
    skEnumValue: Result := 22;      // EnumMember
  else
    Result := 13;
  end;
end;

{ workspace/symbol — project-wide symbol search by name, the Ctrl+T /
  Ctrl+. question. Unit-level names and struct members from every model in
  the closure; locals, params, builtins and unit refs are noise at project
  scope and stay out. Empty query legitimately means "everything" - the RAD
  client prefetches on it and filters locally in the IDE Insight dialog -
  so the cap is high and NEVER silent (the log carries the drop count). }
function TLspServer.HandleWorkspaceSymbol(const AMsg: TLspIncoming): string;
const
  cMaxResults = 20000;
var
  LQuery, LFile: string;
  LMid, LIdx, LCount, LDropped: Integer;
  LModel: TPasSemaModel;
  LHit: TPasRefHit;
  LSB: TStringBuilder;
  LStart: UInt64;
begin
  LQuery := '';
  if AMsg.Params <> nil then
    LQuery := LowerCase(AMsg.Params.GetValue<string>('query', ''));

  if not WaitAnalyzed('', AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if (FNav = nil) or (FProject = nil) then
    Exit(BuildResponse(AMsg.IdJson, '[]'));

  LStart := GetTickCount64;
  LCount := 0;
  LDropped := 0;
  LSB := TStringBuilder.Create;
  try
    for LMid := 0 to FProject.ModelCount - 1 do
    begin
      LModel := FProject.Model(LMid);
      if LModel = nil then
        Continue;
      LFile := TPath.GetFileName(FProject.ModelFile(LMid));
      for LIdx := 0 to LModel.SymCount - 1 do
        with LModel.Symbols[LIdx] do
        begin
          if (Name = '') or (sfBuiltin in Flags) or
             (Kind in [skParam, skLabel, skGenericParam, skUnitRef]) then
            Continue;
          // Project scope means unit-level declarations and struct members;
          // everything scoped inside a routine is local noise here.
          if (Scope < 0) or (Scope >= LModel.Scopes.Count) or
             not (LModel.Scopes[Scope].Kind in
               [sckUnit, sckImplementation, sckStruct, sckEnum]) then
            Continue;
          if (LQuery <> '') and (Pos(LQuery, NameLower) = 0) then
            Continue;
          if LCount >= cMaxResults then
          begin
            Inc(LDropped);
            Continue;
          end;
          if not FNav.DeclHit(LMid, LIdx, LHit) then
            Continue;
          if LCount > 0 then
            LSB.Append(',');
          LSB.Append(Format(
            '{"name":%s,"kind":%d,"containerName":%s,"location":%s}',
            [JsonQuote(Name),
             WorkspaceSymbolKind(Kind, TypeCat),
             JsonQuote(LFile),
             LocationJson(LHit.FilePath, LHit.Line, LHit.Col,
               Length(Name))]));
          Inc(LCount);
        end;
    end;
    Log(Format('workspace/symbol "%s" -> %d symbols in %d ms%s',
      [LQuery, LCount, GetTickCount64 - LStart,
       IfThen(LDropped > 0,
         Format(' (%d MORE dropped by the %d cap)', [LDropped, cMaxResults]),
         '')]));
    Result := BuildResponse(AMsg.IdJson, '[' + LSB.ToString + ']');
  finally
    LSB.Free;
  end;
end;

procedure TLspServer.SyncCompletionOverlays;
var
  LDocs: TArray<TLspDocument>;
  LPaths, LTexts: TArray<string>;
  LIdx: Integer;
begin
  LDocs := FDocs.All;
  SetLength(LPaths, Length(LDocs));
  SetLength(LTexts, Length(LDocs));
  for LIdx := 0 to High(LDocs) do
  begin
    LPaths[LIdx] := LDocs[LIdx].Path;
    LTexts[LIdx] := LDocs[LIdx].Text;
  end;
  FCompletion.SetOverlays(LPaths, LTexts);
end;

{ completionItem.documentation for a row that has a `///` block - markdown,
  because that is what every LSP client renders and what our own RAD client's
  plain-text strip is built for (PasLsp.XmlDoc's header explains why the
  rendering carries no emphasis markers). Empty for the vast majority of rows,
  and then the field is omitted rather than sent empty. }
function CompletionDocJson(const AItem: TLspCompletionEntry): string;
var
  LText: string;
begin
  Result := '';
  LText := XmlDocDisplayText(AItem.Doc);
  if LText <> '' then
    Result := ',"documentation":{"kind":"markdown","value":' +
      JsonQuote(LText) + '}';
end;

function CompletionDataJson(const AItem: TLspCompletionEntry): string;
var
  LHtml: string;
begin
  Result := '';
  if AItem.HeadWord <> '' then
    Result := '"head":' + JsonQuote(AItem.HeadWord);
  if AItem.HasParams then
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + '"hasParams":true';
  end;
  // The same doc as an HTML fragment, for the RAD viewer's documentation
  // surface: IOTACodeInsightSymbolList80.GetSymbolDocumentation is documented
  // as returning HTML, and the plain rendering we send as
  // completionItem.documentation arrives there with its line structure
  // collapsed. It rides in `data` because it is ours - a client that did not
  // ask for it never sees it.
  LHtml := XmlDocHtml(AItem.Doc);
  if LHtml <> '' then
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + '"docHtml":' + JsonQuote(LHtml);
  end;
  if Result <> '' then
    Result := ',"data":{' + Result + '}';
end;

function TLspServer.HandleCompletion(const AMsg: TLspIncoming): string;
var
  LPath, LText, LRangeJson, LQuotedLabel: string;
  LLine, LChar, LPasLine, LPasCol, LIdx, LMid: Integer;
  LDoc: TLspDocument;
  LAnswer: TLspCompletionAnswer;
  LStart: UInt64;
  LSB: TStringBuilder;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'completion: textDocument.uri and position required'));

  LStart := GetTickCount64;
  // The overlay is the truth for an open document; a file nobody opened is
  // its disk text (tolerant decode, BOM never content). Unreadable answers
  // empty rather than erroring: mid-typing is the wrong moment for a toast.
  if FDocs.TryGet(LPath, LDoc) then
    LText := LDoc.Text
  else if not TryReadTextNoBom(LPath, LText) then
    LText := '';

  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if LText = '' then
  begin
    LAnswer := Default(TLspCompletionAnswer);
    LAnswer.Provider := 'no text';
  end
  else
  begin
    if FCompletion = nil then
      FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
        FDefines);
    // Document truth for the overlay parse too: an $I include open with
    // unsaved edits must be preprocessed from its live text, exactly as the
    // analysis session sees it.
    SyncCompletionOverlays;
    // Bridge only when the last-good analysis actually holds this file;
    // otherwise standalone — a half-bridge (project without a model id)
    // has nothing to anchor cross-unit answers to.
    LMid := -1;
    if FNav <> nil then
      LMid := FNav.ModelIdOf(LPath);
    if (FProject <> nil) and (LMid >= 0) then
      LAnswer := FCompletion.CompleteAt(LPath, LText, LPasLine, LPasCol,
        FProject, LMid)
    else
      LAnswer := FCompletion.CompleteAt(LPath, LText, LPasLine, LPasCol,
        nil, -1);
  end;

  LSB := TStringBuilder.Create;
  try
    // Loop-invariant: the replace range is the same for every item, and the
    // label is quoted once per item (it appears as both label and newText) -
    // this loop runs thousands of times for a statement-scope answer.
    LRangeJson := RangeJson(LPasLine, LAnswer.ReplaceColFrom,
      LAnswer.ReplaceColTo - LAnswer.ReplaceColFrom);
    for LIdx := 0 to High(LAnswer.Items) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LQuotedLabel := JsonQuote(LAnswer.Items[LIdx].ItemLabel);
      // Always textEdit, never bare insertText: the replace span is the
      // provider's to declare, and it survives a cursor that moved while the
      // answer was in flight (COMPLETION.md). The routine head word rides
      // the item's data field - our RAD client reads it for the viewer's
      // class column, every other client ignores data it did not create.
      LSB.Append(Format(
        '{"label":%s,"kind":%d,"detail":%s,"sortText":%s,'
        + '"textEdit":{"range":%s,"newText":%s}%s%s}',
        [LQuotedLabel, LAnswer.Items[LIdx].Kind,
         JsonQuote(LAnswer.Items[LIdx].Detail),
         JsonQuote(LAnswer.Items[LIdx].SortText),
         LRangeJson, LQuotedLabel,
         CompletionDocJson(LAnswer.Items[LIdx]),
         CompletionDataJson(LAnswer.Items[LIdx])]));
    end;
    Log(Format('completion: %s -> %d items in %d ms (%s)',
      [PosTag(LPath, LPasLine, LPasCol), Length(LAnswer.Items),
       GetTickCount64 - LStart, LAnswer.Provider]));
    Result := BuildResponse(AMsg.IdJson,
      '{"isIncomplete":false,"items":[' + LSB.ToString + ']}');
  finally
    LSB.Free;
  end;
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

  Log(Format(AMsg.Method + '(%s): %s ''%s'' -> %d hits',
    [LKind, PosTag(LPath, LPasLine, LPasCol), LName, Length(LHits)]));
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

{ 'unit' or 'symbol' - the word the log and the plan both use, spelled once
  so the two can never disagree. }
function RenameKindWord(AIsUnit: Boolean): string;
begin
  if AIsUnit then
    Result := 'unit'
  else
    Result := 'symbol';
end;

{ The text a planned edit writes. PasTree does not carry it as a field, and
  does not need to: the preview snippet already holds the line as it will
  read, so the new spelling is the highlighted span of it. That matters most
  for a UNIT rename, where two sites on one line can legally get DIFFERENT
  texts - the full dotted name where it was written in full, the bare leaf
  where a namespace prefix resolved it - so nothing here may assume the
  requested name is what lands. }
function EditNewText(const AEdit: TPasRenameEdit): string;
begin
  Result := Copy(AEdit.Snippet, AEdit.HiFrom + 1, AEdit.HiTo - AEdit.HiFrom);
end;

{ The file a renamed unit must end up in: the required name, in the folder the
  unit lives in now. A unit rename never MOVES a file - the name decides the
  file name and nothing else. '' in, '' out, because the callers use that to
  mean "no file rename". }
function RenamedFilePath(const AOldPath, ARequiredFileName: string): string;
begin
  Result := '';
  if (AOldPath = '') or (ARequiredFileName = '') then
    Exit;
  Result := TPath.Combine(TPath.GetDirectoryName(AOldPath),
    ARequiredFileName);
end;

{ Rename, the one place this server produces EDITS rather than answers.

  TWO IDENTITIES, TWO PLANS, one entry point. A SYMBOL rename is DeclHit +
  FindReferences turned into replacements, so it can never reach further than
  the references panel already showed. A UNIT rename is the module's own
  header name plus every `uses` item that resolved to it - and, unavoidably,
  the FILE, because Object Pascal ties a unit's name to its file name. That
  obligation rides in RequiredFileName and must never be dropped silently:
  the text edits alone leave a project that does not compile.

  A compiler builtin is the one thing declined outright - it has no
  declaration site anywhere to rename.

  ANewName = '' means "identity check only": resolve the target and say
  whether it COULD be renamed, without judging a name. prepareRename asks
  exactly that, and asking it through this one function is what keeps
  prepareRename from green-lighting a position that rename then refuses. }
function TLspServer.PlanRenameAt(const APath: string;
  APasLine, APasCol: Integer; const ANewName: string;
  out APlan: TLspRenamePlanned; out AError: string): Boolean;
var
  LMid, LTMid, LSym: Integer;
  LOther: string;
  LDecl: TPasRefHit;
begin
  Result := False;
  APlan := Default(TLspRenamePlanned);
  AError := '';
  if FNav = nil then
  begin
    AError := 'The project has not been analyzed yet.';
    Exit;
  end;
  LMid := FNav.ModelIdOf(APath);
  if LMid < 0 then
  begin
    AError := 'This file is not part of the analyzed project.';
    Exit;
  end;
  // UnitAt before SymbolAt, for the reason HandleReferences states: on a
  // .dpr, SymbolAt claims an `X in '...'` uses item as an ordinary symbol.
  if FNav.UnitAt(LMid, APasLine, APasCol, LTMid, LOther) then
  begin
    APlan.IsUnit := True;
    // The placeholder is the unit's FULL dotted name as its own header spells
    // it - not what this `uses` item happens to say, which may be the bare
    // leaf under a namespace prefix.
    if FNav.UnitDeclHit(LTMid, LDecl) then
    begin
      APlan.OldName := Copy(LDecl.Snippet, LDecl.HiFrom + 1,
        LDecl.HiTo - LDecl.HiFrom);
      APlan.UnitPath := LDecl.FilePath;
    end
    else
      APlan.OldName := LOther;
    if ANewName = '' then
      Exit(True);
    Result := FNav.PlanUnitRename(LTMid, ANewName, {out} APlan.Edits,
      {out} APlan.RequiredFileName, {out} AError);
    if not Result then
    begin
      APlan.Edits := nil;
      APlan.RequiredFileName := '';
      Exit;
    end;
    APlan.NewFilePath := RenamedFilePath(APlan.UnitPath,
      APlan.RequiredFileName);
    APlan.StaleInPaths := UsesInPathSites(LTMid, APlan.UnitPath);
    Exit;
  end;
  if not FNav.SymbolAt(LMid, APasLine, APasCol, LTMid, LSym, APlan.OldName)
  then
  begin
    if FNav.BuiltinNameAt(LMid, APasLine, APasCol, LOther) then
      AError := Format('''%s'' is a compiler builtin - it has no ' +
        'declaration to rename.', [LOther])
    else
      AError := 'There is nothing renameable at that position.';
    Exit;
  end;
  if ANewName = '' then
    Exit(True);
  Result := FNav.PlanRename(LTMid, LSym, ANewName, {out} APlan.Edits,
    {out} AError);
  if not Result then
    APlan.Edits := nil;
end;

{ Every `uses` item that names the renamed unit with an explicit
  `in '<file>'` - the ONE thing a rename plan cannot express today, and the
  reason it is reported rather than ignored.

  A .dpr written by RAD Studio spells every unit that way, so this is the
  ordinary case rather than an exotic one: `DemoUnit in 'DemoUnit.pas'`
  becomes `DemoUnitRenamed in 'DemoUnit.pas'` after the plan is applied, and
  the file no longer exists under that name. PasTree records the path
  (TPasUsesRef.InPath) but not a POSITION for the literal, so an edit for it
  cannot be planned here - which is why this returns the SITES, for a host to
  fix its own way. The RAD Studio client does: renaming the file through
  IOTAProject.RemoveFile/AddFile makes the IDE rewrite the entry itself.
  textDocument/rename has no such lever and refuses instead.

  A position for the literal belongs in PasTree, next to the name node; then
  this becomes one more edit and both hosts stop caring. }
function TLspServer.UsesInPathSites(ATargetMid: Integer;
  const AUnitPath: string): TArray<string>;
var
  LMi, LIdx: Integer;
  LModel: TPasSemaModel;
  LOldFile: string;
  LSites: TList<string>;
begin
  Result := nil;
  if (FProject = nil) or (AUnitPath = '') then
    Exit;
  LOldFile := TPath.GetFileName(AUnitPath);
  LSites := TList<string>.Create;
  try
    for LMi := 0 to FProject.ModelCount - 1 do
    begin
      LModel := FProject.Model(LMi);
      for LIdx := 0 to High(LModel.UsesList) do
        if (LModel.UsesList[LIdx].UnitId = ATargetMid) and
           (LModel.UsesList[LIdx].InPath <> '') and
           SameText(TPath.GetFileName(LModel.UsesList[LIdx].InPath),
             LOldFile) then
          LSites.Add(FProject.ModelFile(LMi));
    end;
    Result := LSites.ToArray;
  finally
    LSites.Free;
  end;
end;

{ textDocument/prepareRename - the range F2 pre-fills from, and the earliest
  point a refusal can be shown. Answered as an ERROR rather than null when the
  position resolves to something unrenameable, because "a builtin has no
  declaration" is the whole content of the answer: a client puts an error's
  message in front of the user, a null only greys the command out. }
function TLspServer.HandlePrepareRename(const AMsg: TLspIncoming): string;
var
  LPath, LError: string;
  LLine, LChar, LPasLine, LPasCol, LMid: Integer;
  LIdent: TPasNavIdent;
  LPlan: TLspRenamePlanned;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'prepareRename: textDocument.uri and position required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if not PlanRenameAt(LPath, LPasLine, LPasCol, '', {out} LPlan,
    {out} LError) then
  begin
    Log(Format('prepareRename: %s refused - %s',
      [PosTag(LPath, LPasLine, LPasCol), LError]));
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED, LError));
  end;
  // The span comes from IdentAt, not from the symbol's declaration: it must
  // be the identifier UNDER THE CURSOR, in this file. For a dotted `uses`
  // name IdentAt reports the whole span as one identifier, which is exactly
  // right here - the new name replaces all of it.
  if not FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED,
      'There is nothing renameable at that position.'));
  Log(Format('prepareRename: %s %s ''%s'' ok',
    [PosTag(LPath, LPasLine, LPasCol), RenameKindWord(LPlan.IsUnit),
     LPlan.OldName]));
  Result := BuildResponse(AMsg.IdJson, Format('{"range":%s,"placeholder":%s}',
    [RangeJson(LIdent.Line, LIdent.ColFrom, LIdent.ColTo - LIdent.ColFrom),
     JsonQuote(LPlan.OldName)]));
end;

{ One file's edits as the BODY of a TextEdit array - the elements, without
  brackets - the shape both WorkspaceEdit forms need, spelled once. Walks
  from AFrom while the file stays the same and reports where it stopped. }
function AppendFileEdits(ASB: TStringBuilder;
  const AEdits: TArray<TPasRenameEdit>; AFrom: Integer): Integer;
begin
  Result := AFrom;
  while (Result <= High(AEdits)) and
        SameText(AEdits[Result].FilePath, AEdits[AFrom].FilePath) do
  begin
    if Result > AFrom then
      ASB.Append(',');
    ASB.AppendFormat('{"range":%s,"newText":%s}',
      [RangeJson(AEdits[Result].Line, AEdits[Result].Col,
        AEdits[Result].Len),
       JsonQuote(EditNewText(AEdits[Result]))]);
    Inc(Result);
  end;
end;

{ textDocument/rename -> WorkspaceEdit. The plan arrives sorted by (file,
  line, col), so the per-file grouping is one walk.

  A SYMBOL rename is `changes`, the shape every client understands. A UNIT
  rename cannot be: it must also RENAME THE FILE, which only
  `documentChanges` can express (a `rename` resource operation), and it is
  refused outright for a client that has not advertised support for one -
  applying the text half of a unit rename leaves a project that does not
  compile, which is worse than doing nothing.

  It is refused for the same reason when a `uses` item spells this unit with
  an explicit `in '<file>'`: that literal is not in the plan (see
  UsesInPathSites) and a WorkspaceEdit has no way to fix it. Our own IDE
  client does not come this way at all - it uses pastree/renamePlan and lets
  the IDE rewrite the project entry.

  Every newText comes from the plan rather than from the request: see
  EditNewText. }
function TLspServer.HandleRename(const AMsg: TLspIncoming): string;
var
  LPath, LNewName, LError: string;
  LLine, LChar, LPasLine, LPasCol, LIdx: Integer;
  LPlan: TLspRenamePlanned;
  LSB: TStringBuilder;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) or
     not AMsg.Params.TryGetValue<string>('newName', LNewName) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'rename: textDocument.uri, position and newName required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if not PlanRenameAt(LPath, LPasLine, LPasCol, LNewName, {out} LPlan,
    {out} LError) then
  begin
    Log(Format('rename: %s -> ''%s'' refused - %s',
      [PosTag(LPath, LPasLine, LPasCol), LNewName, LError]));
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED, LError));
  end;
  if LPlan.IsUnit and not FClientRenamesFiles then
  begin
    Log('rename: unit rename refused - the client advertised no rename '
      + 'resource operation');
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED, Format(
      'Renaming unit %s also renames its file to %s, and this editor did ' +
      'not advertise support for file renames in a workspace edit. Nothing ' +
      'was changed.', [LPlan.OldName, LPlan.RequiredFileName])));
  end;
  if LPlan.IsUnit and (Length(LPlan.StaleInPaths) > 0) then
  begin
    Log('rename: unit rename refused - uses ... in ''...'' in '
      + string.Join(', ', LPlan.StaleInPaths));
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED, Format(
      '%s names unit %s as `in ''%s''`, and a workspace edit cannot update ' +
      'that path - the rename would leave the project unable to compile. ' +
      'Nothing was changed.',
      [TPath.GetFileName(LPlan.StaleInPaths[0]), LPlan.OldName,
       TPath.GetFileName(LPlan.UnitPath)])));
  end;
  Log(Format('rename: %s %s ''%s'' -> ''%s'': %d edits%s',
    [PosTag(LPath, LPasLine, LPasCol), RenameKindWord(LPlan.IsUnit),
     LPlan.OldName, LNewName, Length(LPlan.Edits),
     IfThen(LPlan.IsUnit, ' + file -> ' + LPlan.RequiredFileName, '')]));
  LSB := TStringBuilder.Create;
  try
    if LPlan.IsUnit then
    begin
      // documentChanges: text edits per file, then the file rename LAST - a
      // client applies them in order, and renaming the file first would
      // invalidate every URI above it.
      LSB.Append('{"documentChanges":[');
      LIdx := 0;
      while LIdx <= High(LPlan.Edits) do
      begin
        if LIdx > 0 then
          LSB.Append(',');
        LSB.AppendFormat('{"textDocument":{"uri":%s,"version":null},' +
          '"edits":[', [JsonQuote(PathToUri(LPlan.Edits[LIdx].FilePath))]);
        LIdx := AppendFileEdits(LSB, LPlan.Edits, LIdx);
        LSB.Append(']}');
      end;
      if Length(LPlan.Edits) > 0 then
        LSB.Append(',');
      LSB.AppendFormat('{"kind":"rename","oldUri":%s,"newUri":%s}',
        [JsonQuote(PathToUri(LPlan.UnitPath)),
         JsonQuote(PathToUri(LPlan.NewFilePath))]);
      LSB.Append(']}');
    end
    else
    begin
      LSB.Append('{"changes":{');
      LIdx := 0;
      while LIdx <= High(LPlan.Edits) do
      begin
        if LIdx > 0 then
          LSB.Append(',');
        LSB.Append(JsonQuote(PathToUri(LPlan.Edits[LIdx].FilePath)))
          .Append(':[');
        LIdx := AppendFileEdits(LSB, LPlan.Edits, LIdx);
        LSB.Append(']');
      end;
      LSB.Append('}}');
    end;
    Result := BuildResponse(AMsg.IdJson, LSB.ToString);
  finally
    LSB.Free;
  end;
end;

{ pastree/renamePlan - OURS, for a host that applies the rename itself and
  wants to SHOW what it did. The same two plans as textDocument/rename, but
  every edit keeps what a WorkspaceEdit throws away: `oldText`, so the host
  can verify each site against its own buffer before touching it, `newText`
  per site (a unit rename writes different texts at different sites), and
  `snippet`/`hiFrom`/`hiTo` - the line as it reads AFTER the rename, with the
  new name highlighted. That is what lets the RAD client fill a Find
  References-shaped results tab with the OUTCOME rather than a promise.

  For a unit, `kind` is `unit`, `requiredFileName`/`filePath`/`newFilePath`
  name the file rename the host must ALSO perform, and `staleInPaths` lists
  the project files whose `uses ... in '...'` still points at the old file
  name. Announcing none of that and leaving it out would be the worst
  outcome: text edits that do not compile. }
function TLspServer.HandleRenamePlan(const AMsg: TLspIncoming): string;
var
  LPath, LNewName, LError: string;
  LLine, LChar, LPasLine, LPasCol, LIdx: Integer;
  LPlan: TLspRenamePlanned;
  LSB: TStringBuilder;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) or
     not AMsg.Params.TryGetValue<string>('newName', LNewName) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'renamePlan: textDocument.uri, position and newName required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  if not PlanRenameAt(LPath, LPasLine, LPasCol, LNewName, {out} LPlan,
    {out} LError) then
  begin
    Log(Format('renamePlan: %s -> ''%s'' refused - %s',
      [PosTag(LPath, LPasLine, LPasCol), LNewName, LError]));
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED, LError));
  end;
  Log(Format('renamePlan: %s %s ''%s'' -> ''%s'': %d edits%s',
    [PosTag(LPath, LPasLine, LPasCol), RenameKindWord(LPlan.IsUnit),
     LPlan.OldName, LNewName, Length(LPlan.Edits),
     IfThen(LPlan.IsUnit, ' + file -> ' + LPlan.RequiredFileName, '')]));
  LSB := TStringBuilder.Create;
  try
    LSB.AppendFormat('{"kind":%s,"oldName":%s,"newName":%s,' +
      '"requiredFileName":%s,"filePath":%s,"newFilePath":%s,' +
      '"staleInPaths":[',
      [JsonQuote(RenameKindWord(LPlan.IsUnit)), JsonQuote(LPlan.OldName),
       JsonQuote(LNewName), JsonQuote(LPlan.RequiredFileName),
       JsonQuote(LPlan.UnitPath), JsonQuote(LPlan.NewFilePath)]);
    for LIdx := 0 to High(LPlan.StaleInPaths) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(JsonQuote(LPlan.StaleInPaths[LIdx]));
    end;
    LSB.Append('],"edits":[');
    for LIdx := 0 to High(LPlan.Edits) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.AppendFormat('{"uri":%s,"filePath":%s,"line":%d,"col":%d,' +
        '"len":%d,"oldText":%s,"newText":%s,"isDecl":%s,"snippet":%s,' +
        '"hiFrom":%d,"hiTo":%d}',
        [JsonQuote(PathToUri(LPlan.Edits[LIdx].FilePath)),
         JsonQuote(LPlan.Edits[LIdx].FilePath),
         LPlan.Edits[LIdx].Line, LPlan.Edits[LIdx].Col,
         LPlan.Edits[LIdx].Len,
         JsonQuote(LPlan.Edits[LIdx].OldText),
         JsonQuote(EditNewText(LPlan.Edits[LIdx])),
         LowerCase(BoolToStr(LPlan.Edits[LIdx].IsDecl, True)),
         JsonQuote(LPlan.Edits[LIdx].Snippet),
         LPlan.Edits[LIdx].HiFrom, LPlan.Edits[LIdx].HiTo]);
    end;
    LSB.Append(']}');
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
  // The method as it came off the wire, not a label of our own: every log line
  // and error message in here then names something a person can grep for in
  // SPEC.md or in a client's own trace, and it cannot drift from what was
  // actually asked (which a hand-written 'implementation' silently could).
  LWhat := AMsg.Method;
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
    Log(Format('%s: %s nothing to toggle to at that position',
      [LWhat, PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format('%s: %s ''%s'' -> %s',
    [LWhat, PosTag(LPath, LPasLine, LPasCol), LTarget.Name,
     PosTag(LTarget.FilePath, LTarget.Line, LTarget.Col)]));
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
{ pastree/classComplete — OUR request, the server half of Ctrl+Shift+C.

  Not an LSP method and not pretending to be one: the protocol has no notion
  of "implement what I declared", `textDocument/codeAction` is the nearest
  thing and it would mean advertising a capability, negotiating kinds and
  round-tripping a resolve for a command exactly one client will ever send.
  A named custom request is the honest shape (the `pastree/` prefix is the
  same convention `pastreeCall` and `pastreeHtml` follow).

  Like completion, it must NOT call WaitAnalyzed: the whole point is the
  declaration typed a second ago, which no rebuild has seen. It is a parse of
  the live buffer, nothing more — the answer never depends on the closure. }
function TLspServer.HandleClassComplete(const AMsg: TLspIncoming): string;
var
  LPath, LText, LEdits, LNames: string;
  LDoc: TLspDocument;
  LAnswer: TLspClassCompleteAnswer;
  LIdx, LCaretLine, LCaretChar: Integer;
  LStart: UInt64;
begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'classComplete: textDocument.uri required'));
  LStart := GetTickCount64;
  // Document truth, exactly as completion reads it: the open buffer if we
  // hold one, the file on disk otherwise.
  if FDocs.TryGet(LPath, LDoc) then
    LText := LDoc.Text
  else if not TryReadTextNoBom(LPath, LText) then
    LText := '';
  if LText = '' then
    Exit(BuildResponse(AMsg.IdJson,
      '{"edits":[],"count":0,"provider":"no text"}'));
  if FCompletion = nil then
    FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
      FDefines);
  SyncCompletionOverlays;
  LAnswer := FCompletion.ClassCompleteAt(LPath, LText);

  LEdits := '';
  for LIdx := 0 to High(LAnswer.Edits) do
  begin
    if LEdits <> '' then
      LEdits := LEdits + ',';
    // A zero-length range at the insertion point: an ordinary TextEdit, so a
    // client that already applies those needs no new code path.
    LEdits := LEdits + Format('{"range":%s,"newText":%s,"kind":%s,"name":%s}',
      [RangeJson(LAnswer.Edits[LIdx].Line, LAnswer.Edits[LIdx].Col, 0),
       JsonQuote(LAnswer.Edits[LIdx].Text),
       JsonQuote(LAnswer.Edits[LIdx].Kind),
       JsonQuote(LAnswer.Edits[LIdx].Name)]);
    if LNames <> '' then
      LNames := LNames + ', ';
    LNames := LNames + LAnswer.Edits[LIdx].Name;
  end;
  LCaretLine := 0;
  LCaretChar := 0;
  if LAnswer.CaretLine > 0 then
    PasTreeToLsp(LAnswer.CaretLine, LAnswer.CaretCol, LCaretLine, LCaretChar);
  Log(Format('classComplete: %s -> %d edit(s) in %d ms (%s)',
    [TPath.GetFileName(LPath), Length(LAnswer.Edits),
     GetTickCount64 - LStart, LAnswer.Provider]));
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"edits":[%s],"caret":{"line":%d,"character":%d},' +
    '"names":%s,"count":%d,"provider":%s}',
    [LEdits, LCaretLine, LCaretChar, JsonQuote(LNames),
     Length(LAnswer.Edits), JsonQuote(LAnswer.Provider)]));
end;

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
    // A scope's containers are created LAZILY by the model (Names/Symbols are
    // nil until something is declared into it), so an EMPTY scope has no list
    // at all — reading Count there is an access violation, not an empty loop.
    // Cost of learning this: every documentSymbol answered with an
    // EAccessViolation once a closure contained such a scope (2026-08-23).
    if (LScope = nil) or (LScope.Symbols = nil) then
      Exit;
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
  Log(Format(AMsg.Method + ': %s -> %d bytes of outline',
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
  LPath, LName, LCode, LNote, LMd, LDoc, LRawDoc, LDeclFile: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSymIdx: Integer;
  LDeclLine, LDeclCol: Integer;
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
  LDoc := '';
  LRawDoc := '';
  LDeclFile := '';
  LDeclLine := 0;
  LDeclCol := 0;
  if FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) then
  begin
    LCode := 'unit ' + LName + ';';
    if FNav.UnitDeclHit(LTMid, LHit) then
    begin
      LNote := Format('unit - %s', [TPath.GetFileName(LHit.FilePath)]);
      LDeclFile := LHit.FilePath;
      LDeclLine := LHit.Line;
      LDeclCol := LHit.Col;
    end
    else
      LNote := 'unit';
  end
  else if FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSymIdx, LName) then
  begin
    // Help Insight: the `///` block above the declaration, from the engine
    // (SymDocComment) and rendered here. A symbol is the only identity that
    // can have one - a unit reference names a file and a builtin has no
    // source at all.
    LRawDoc := FProject.SymDocComment(LTMid, LSymIdx);
    LDoc := XmlDocDisplayText(LRawDoc);
    if FNav.DeclHit(LTMid, LSymIdx, LHit) then
    begin
      LCode := Trim(LHit.Snippet);
      LNote := Format('%s - %s:%d',
        [KindWord(FProject.Model(LTMid).Symbols[LSymIdx].Kind),
         TPath.GetFileName(LHit.FilePath), LHit.Line]);
      LDeclFile := LHit.FilePath;
      LDeclLine := LHit.Line;
      LDeclCol := LHit.Col;
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

  // Reading order: what it is (the declaration line), what it does (the doc),
  // then where it lives. The provenance note goes LAST because it is the one
  // part the reader already knows they can go look up; the doc is what they
  // hovered for. The fence and the note's underscores are contract - the RAD
  // client's HoverPlainText strips exactly this shape.
  LMd := '';
  if LCode <> '' then
    LMd := '```pascal'#10 + LCode + #10'```'#10#10;
  if LDoc <> '' then
    LMd := LMd + LDoc + #10#10;
  LMd := LMd + '_' + LNote + '_';
  // The range is the identifier's own span, so the editor underlines exactly
  // the name it is describing — including all segments of a qualified `uses`
  // name, which IdentAt reports as one span.
  PasTreeToLsp(LIdent.Line, LIdent.ColFrom, LStartLine, LStartChar);
  PasTreeToLsp(LIdent.Line, LIdent.ColTo, LEndLine, LEndChar);
  { `pastreeHtml` is OURS, alongside the standard contents: the same card as a
    Help Insight page, in the shape the IDE's own HelpInsight.xsl emits (see
    PasLsp.XmlDoc). The RAD client hands it to the IDE where an HTML surface
    exists; every other client ignores a field it did not ask for, exactly as
    with signatureHelp's `pastreeCall`. It is sent for every hover, not only
    documented ones - the caption line and its source link are the half of
    the native look that does not depend on a `///` block existing. }
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"contents":{"kind":"markdown","value":%s},' +
    '"pastreeHtml":%s,' +
    '"range":{"start":{"line":%d,"character":%d},' +
    '"end":{"line":%d,"character":%d}}}',
    [JsonQuote(LMd),
     JsonQuote(HelpInsightPage(LCode, LDeclFile,
       TPath.GetFileName(LDeclFile), LDeclLine, LDeclCol, LRawDoc)),
     LStartLine, LStartChar, LEndLine, LEndChar]));
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
    Log(Format(AMsg.Method + ': %s ''%s'' -> %s',
      [PosTag(LPath, LPasLine, LPasCol), LName,
       PosTag(LTarget.FilePath, LTarget.Line, LTarget.Col)]));
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
    Log(Format(AMsg.Method + ': %s ''%s'' -> %s via the resolved type symbol',
      [PosTag(LPath, LPasLine, LPasCol), LName,
       PosTag(LHit.FilePath, LHit.Line, LHit.Col)]));
    Exit(BuildResponse(AMsg.IdJson,
      LocationJson(LHit.FilePath, LHit.Line, LHit.Col,
        LHit.HiTo - LHit.HiFrom)));
  end;

  Log(Format(AMsg.Method + ': %s no type declaration reachable for ''%s''',
    [PosTag(LPath, LPasLine, LPasCol), LName]));
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
    Log(Format(AMsg.Method + ': %s ''%s'' -> %d in this file',
      [PosTag(LPath, LPasLine, LPasCol), LName, LCount]));
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
      if LMsg.Method = 'textDocument/completion' then
        Exit(HandleCompletion(LMsg));
      if LMsg.Method = 'textDocument/signatureHelp' then
        Exit(HandleSignatureHelp(LMsg));
      if LMsg.Method = 'workspace/symbol' then
        Exit(HandleWorkspaceSymbol(LMsg));
      if LMsg.Method = 'pastree/classComplete' then
        Exit(HandleClassComplete(LMsg));
      if LMsg.Method = 'textDocument/typeDefinition' then
        Exit(HandleTypeDefinition(LMsg));
      if LMsg.Method = 'textDocument/documentHighlight' then
        Exit(HandleDocumentHighlight(LMsg));
      if LMsg.Method = 'textDocument/prepareRename' then
        Exit(HandlePrepareRename(LMsg));
      if LMsg.Method = 'textDocument/rename' then
        Exit(HandleRename(LMsg));
      if LMsg.Method = 'pastree/renamePlan' then
        Exit(HandleRenamePlan(LMsg));
      { A HOST-SIDE EVENT, WRITTEN INTO THIS LOG. The client sends one when
        something happens that the server cannot see but a reader of this log
        needs as a boundary: the IDE opening or closing a project. Reopening
        the SAME project restarts nothing here - the configuration is
        identical - so without this the log runs straight from one session's
        requests into the next's with nothing between them, which is exactly
        the confusion it was added for (2026-08-29).

        Prefixed on the way in rather than trusted as-is: a line in this file
        that did not come from the server must say so. }
      if LMsg.Method = '$/pastree.hostEvent' then
      begin
        if LMsg.Params is TJSONObject then
          Log('host: ' + LMsg.Params.GetValue<string>('message', ''));
        Exit;
      end;
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
