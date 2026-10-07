unit PasLsp.Server;

{
  The LSP state machine: lifecycle, incremental document sync, and the
  navigation/diagnostics requests (SPEC.md phases 1-2). One message at a
  time on the dispatcher thread; the ANALYSIS runs on a background
  TPasAsyncSession, so a request that needs a fresh build waits on it while
  the reader thread keeps noting $/cancelRequest.

  Project state: one TPasSemaProject + TPasNavigator pair, kept across
  requests (this IS the analysis cache - the same shape as the IDE plugin's
  BuildNavigator cache). A document event only SCHEDULES a rebuild, and only
  when the text actually differs from what was analyzed; the previous project
  keeps answering until the new one is ready.

  Configuration comes from initialize's initializationOptions - an object
  with these keys (all optional):
    "projectFile" - path to a .dproj (or a bare .dpr)
    "platform"    - e.g. "Win64", overrides the project's own
    "config"      - build configuration name, .dproj only
    "searchPaths", "defines" - string arrays, appended after the project's
    "libraryPaths" - the INSTALLED library trees (RTL/VCL, third-party), as
                  a string array. Not a search path and not appended to one:
                  rename refuses to rewrite any file under one of these, and
                  the server has no way to work out which of its search paths
                  they are. Absent = no such refusal
    "host"        - free text naming the client and its version, logged next
                  to the build banner; the server cannot know it
    "logFile", "logUnits" - where the log goes, and whether it inventories
                  every unit of the closure
    "logDetail"   - False drops the configuration inventory (every search
                  path, define, namespace and alias) from the log; the
                  one-line "configured: ..." summary stays either way.
                  Defaults to True - this record predates the switch and is
                  what most log-reading starts from
    "moduleRedoLimit" - the incremental fast path's blast-radius ceiling;
                  0 keeps PasTree's measured default
  A .dproj brings its own MainSource/search paths/defines/namespaces/aliases
  (TPasDProj - the same MSBuild evaluation the CLI tools use). Without a
  projectFile the open documents themselves become the analysis roots.
}

interface

uses
  Winapi.Windows,
  Winapi.PsAPI,
  System.SysUtils,
  System.StrUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Math,
  System.JSON,
  System.IOUtils,
  System.Hash,
  PasTree.Platforms,
  PasTree.DProj,
  PasTree.SourceManager,
  PasTree.Types,
  PasTree.Preprocessor,
  PasTree.Ast,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Async,
  PasTree.Sema.Nav,
  PasTree.Sema.Dfm,
  PasTree.Dfm,
  PasTree.Outline,
  PasLsp.Protocol,
  PasLsp.Documents,
  PasLsp.Completion,
  PasLsp.ClassComplete,
  PasLsp.SyncPrototypes,
  PasLsp.AnnotateArgs,
  PasLsp.UseUnit,
  PasLsp.UnusedUnits,
  PasTree.Sema.Lint,
  PasLsp.BlockClose,
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
    the file as it is now, NewFilePath is the two combined (a `uses ... in
    '...'` path naming that file is one more of the plan's edits, PasTree's
    since 0.87.0). FormPath/NewFormPath are the unit's FORM FILE and what
    it must be called: `$R *.dfm` names the resource after the unit's file,
    so a unit whose file is renamed and whose form file is not links nothing.
    All of those are empty for a symbol rename.

    FormRole and Carried are the SYMBOL's side of form files: where the
    symbol lives in them (whose form's designer owns it) and the handlers a
    component's rename carries along (see PasTree's TPasCarriedRename) - for
    a host that must apply the form part through a live designer. }
  TLspRenamePlanned = record
    IsUnit: Boolean;
    OldName: string;
    RequiredFileName: string;
    UnitPath: string;
    NewFilePath: string;
    FormPath: string;
    NewFormPath: string;
    Edits: TArray<TPasRenameEdit>;
    FormRole: TPasFormRole;
    Carried: TArray<TPasCarriedRename>;
  end;

  { The three filtered reference searches of the Find All family that share
    one handler (HandleFindSites): same answer shape, same gate-then-search
    shape, only the PasTree call differs. }
  TFindSitesKind = (fskAssignments, fskCreations, fskDestructions);

  { One semantic token (HandleSemanticTokens' answer, and the per-line type
    spans the result surfaces carry). The legend indices live beside the
    legend constant below. }
  TSemanticToken = record
    Line, Col, Len: Integer;      // PasTree 1-based line/col, UTF-16 units
    TokenType, Modifiers: Integer;
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
    // Log the configuration inventory - the paths, defines, namespaces and
    // aliases behind the "configured:" summary? On by default; a client that
    // does not want hundreds of lines per configuration sends logDetail=false.
    FLogDetail: Boolean;
    FLogPath: string;
    FLogStarted: Boolean;
    // THE HEADER, KEPT FOR A LOG EMPTIED UNDER US. The IDE package empties the
    // log when a project is opened (ClearLogOnProjectOpen), and a server that
    // had already started for it had written its version, hardware, host and
    // configuration lines by then: the file began "project configured", and a
    // log sent in from someone else's machine said nothing about which build
    // or which machine (2026-09-25). AppendLog writes these again when the
    // file turns out SHORTER than it last left it - other writers only
    // append, so that is truncation - and FLogSize is what it last left.
    FHeaderLines: TArray<string>;
    FLogSize: Int64;
    FStartedAt: TDateTime;
    FDocs: TLspDocumentStore;
    FOutgoing: TList<string>;   // notifications queued during Handle
    FOnFlush: TProc;            // see OnFlush
    // Configuration (fixed at initialize)
    FPlatform: TPasPlatform;
    FMainSource: string;
    FSearchPaths: TArray<string>;
    FDefines: TArray<string>;
    FNamespaces: TArray<string>;
    FAliases: TArray<TPasUnitAlias>;
    // THE INSTALLED LIBRARY TREES, and only those: RTL/VCL/ToolsAPI and the
    // third-party sources the IDE knows about, never the project's own
    // directories. A rename may not rewrite a file under one of them, which
    // is a question only the CLIENT can answer - FSearchPaths above is the
    // two kinds already merged into one flat list, and by the time the server
    // sees it there is nothing left to tell them apart by. So this arrives
    // separately, as its own initializationOption, and PasTree refuses the
    // rename with the file named (TPasNavigator.LibraryPaths). Empty means no
    // file-level refusal at all, which is the right default for a client that
    // says nothing: the symbol-level gates still stand.
    FLibraryPaths: TArray<string>;
    // The project's OWN unit list (.dproj DCCReference rows, resolved) and
    // its directory. Both pin unit resolution ahead of every search path,
    // PasTree 0.31.0: a patched copy of a library unit that the project
    // carries in its tree - listed in the project, or just sitting beside the
    // .dproj - must SHADOW the library's original for every importer, as the
    // IDE compiles it. Before this, only the .dpr's own import saw the copy;
    // every library unit importing the same name resolved the original.
    FProjectFiles: TArray<string>;
    FProjectDir: string;
    // What initialize named, kept so pastree/projectChanged can read the
    // same .dproj the same way again, and what that read produced
    // (DProjSignature) - '' parts for a bare .dpr or a failed load.
    FInitProjectFile: string;
    FInitPlatform: string;
    FInitConfig: string;
    FProjectSig: TArray<string>;
    // Analysis state (phase 2, all touched by the DISPATCHER thread only:
    // the async session's worker builds its own project in isolation -
    // TPasAsyncSession's double-buffering contract).
    FProject: TPasSemaProject;      // last COMPLETED analysis (may be nil)
    FNav: TPasNavigator;
    // pastree/outline scope "project", serialized, for the FProject it was
    // built from: the list changes only when an analysis installs a new
    // project (FinalizeAnalysisIfDone), so it is dropped there - and a
    // Ctrl+G that comes back to the Group tab costs the server nothing.
    FOutlineCache: string;
    // Path (lower-cased, full) -> the file's semantic tokens, for the type
    // spans every result row carries (LineTypeSpansJson). Dropped with the
    // outline cache: both are views of one analysis.
    FLineTokenCache: TDictionary<string, TArray<TSemanticToken>>;
    // The completion seam's engine (PasLsp.Completion) - configuration-
    // derived, so created lazily once and kept for the session.
    FCompletion: TLspCompletionEngine;
    FSession: TPasAsyncSession;     // in-flight analysis, nil when idle
    FDirty: Boolean;                // docs changed since FSession started
    FCancels: TLspCancelSet;        // shared with the reader thread
    // Debounce: document events SCHEDULE an analysis rather than start one,
    // so a keystroke burst costs one build, not one per keystroke. The idle
    // tick fires it when the deadline passes; a REQUEST fires it instantly
    // (the user stopped typing and asked a question - the answer must be
    // computed from the text they see, not the pre-burst snapshot).
    FPendingDue: UInt64;            // GetTickCount64 deadline; 0 = nothing
    FPendingPriority: string;
    FBuildStart: UInt64;            // for the analysis-done log line
    // WHEN THE ANALYZED PROJECT LAST READ THE DISK: the wall-clock start of
    // the full rebuild that produced FProject (FBuildDiskReadAt while one
    // runs). An incremental run reads no disk and leaves it alone. HandleDidOpen
    // asks it: a document whose text matches the disk is only "nothing new"
    // if the disk has not moved since the analysis read it - a file rewritten
    // outside the editor and then opened (RAD Studio reloading it, 2026-09-24)
    // matches the NEW disk text the analysis never saw.
    FDiskReadAt: TDateTime;
    FBuildDiskReadAt: TDateTime;
    // A FILE MOVED ON DISK since the last full rebuild started, and the
    // overlay signature cannot show it: it describes only documents that
    // differ from disk. Without this the two "nothing changed" gates -
    // FlushPending's drop and the mid-build "changed back" - threw away the
    // very rebuild a disk change had scheduled ("scheduled rebuild dropped:
    // the analyzed inputs did not change", 2026-09-24). Set with the
    // schedule, cleared when a full rebuild starts reading.
    FDiskMoved: Boolean;
    // THE IDLE FAULT THAT REPEATS. A permanent failure inside the idle path
    // fires on every 50ms tick and never clears, so it writes the same line
    // some fifteen times a second for as long as the session lives - 295
    // identical lines in the 2026-09-02 report, which is what "the log is
    // solid errors" meant. The fault is worth one line, not a flood: the
    // flood buries the configuration record above it, which is where the
    // cause of a host-specific failure actually lives. First occurrence in
    // full, repeats counted, the count published when the message changes or
    // the run ends.
    FIdleFault: string;
    FIdleFaultRepeats: Integer;
    // The overlay signature the LAST COMPLETED analysis was built from - the
    // backstop that keeps a scheduled rebuild from running when the inputs
    // came back to what is already analyzed (an edit typed and undone).
    FBuiltSignature: string;
    // The same signature split into its per-document parts: what tells a
    // ONE-FILE edit (the incremental fast path) from any other change to the
    // inputs - a document opened, closed, saved, or two edited at once.
    FBuiltParts: TArray<string>;
    // EVERY differing document's part when the running analysis started,
    // closure or not (OverlayParts(True)). The built parts are cut from it
    // AFTER the run, against the closure the run produced - see
    // CommitBuiltParts for the unit that was outside when it started.
    FStartedParts: TArray<string>;
    // Documents with no file on disk, opened while outside the closure - a
    // unit just created in the IDE - waiting for a program that names them
    // (TakeInNamer). Case-insensitive. Armed by didOpen only, consumed when a
    // module run starts to take one in, cleared when a full rebuild starts:
    // a unit still outside after either is not one a retry can bring in.
    FTakeIn: TStringList;
    // FProject.ModelCount when the running module session started: the models
    // past it are the units that run took in (LogTakenIn).
    FModuleBaseCount: Integer;
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
    FClientRenamesFiles: Boolean;     // see the block comment above
    FProgressToken: string;       // '' = no progress stream open
    FProgressCreateId: Integer;   // id of the create request awaiting a reply
    FNextServerId: Integer;       // our own id space for server->client calls
    FProgressSeq: Integer;        // makes each token unique within a session
    FLastReportTick: UInt64;
    procedure AppendLog(const AText: string);
    procedure Log(const AMsg: string);
    { Log, and remembered as one of the header lines AppendLog repeats in a
      log that was emptied (FHeaderLines). }
    procedure LogHeader(const AMsg: string);
    procedure LogBlock(const ALines: TArray<string>);
    procedure LogParseRecord;
    procedure Notify(const AJson: string);
    procedure StartClientWatchdog(APid: Integer);
    function FileMatches(const APath, AText, ADiskText: string): Boolean;
    function OverlaySignature: string;
    function OverlayParts(AAll: Boolean = False): TArray<string>;
    procedure CommitBuiltParts;
    function AffectsAnalysis(const APath: string): Boolean;
    function DiskNewerThanAnalysis(const APath: string): Boolean;
    function ChangedDocs(out APath: string): Integer;
    function NamerOf(const ADocPath: string): string;
    function TakeInNamer(out ANamer: string): Boolean;
    procedure LogTakenIn;
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
    { The analysis state in one line, for an exception log. An
      EAccessViolation carries an address and nothing else; which phase the
      server was in when it faulted is the difference between "the analysis
      never started" and "an answer walked a broken model", and the two have
      nothing in common. Cheap and side-effect-free, so both handlers can
      call it unconditionally. }
    { THE ONLY PLACE A NAVIGATOR IS CONSTRUCTED, so the configuration that has
      to ride along with it cannot be forgotten at one of the three sites that
      used to do this by hand. Today that is LibraryPaths, whose absence is
      SILENT in the worst way: rename simply stops refusing RTL/VCL sources
      and rewrites somebody else's files instead. }
    function NewNavigator: TPasNavigator;
    procedure DemoteLibraryText;
    procedure HydrateOpenDoc(ANav: TPasNavigator; const APath: string);
    function StateLine: string;
    procedure NoteIdleFault(const AMsg: string);
    procedure FlushIdleFault;
    { Blocks until an up-to-date analysis is available, staying responsive
      to $/cancelRequest for ARequestIdJson. False = that request was
      cancelled while waiting (the caller answers -32800). }
    function WaitAnalyzed(const APriorityFile,
      ARequestIdJson: string): Boolean;
    procedure PublishDiagnostics;
    procedure PublishDiagnosticsFor(const ADoc: TLspDocument);
    procedure PublishEmptyDiagnostics(const APath: string);
    function DocPathOf(AParams: TJSONValue): string;
    function HandleInitialize(const AMsg: TLspIncoming): string;
    function HandleDefinition(const AMsg: TLspIncoming;
      ADeclarationOnly: Boolean): string;
    function HandleReferences(const AMsg: TLspIncoming): string;
    function HandleToggle(const AMsg: TLspIncoming;
      AToImpl: Boolean): string;
    function HandleDocumentSymbol(const AMsg: TLspIncoming): string;
    function HandleHover(const AMsg: TLspIncoming): string;
    function HandleTypeDefinition(const AMsg: TLspIncoming): string;
    function HandleDocumentHighlight(const AMsg: TLspIncoming): string;
    function HandleSemanticTokens(const AMsg: TLspIncoming): string;
    function CollectSemanticTokens(const APath: string;
      AInactive: Boolean): TArray<TSemanticToken>;
    function LineTypeSpansJson(const APath: string; ALine: Integer): string;
    function LocationWithTypes(const AFilePath: string;
      APasLine, APasCol, ALen: Integer): string;
    function DefineSitesJson(const ASites: TArray<TPasDefineSite>): string;
    function HandleCompletion(const AMsg: TLspIncoming): string;
    function HandleSignatureHelp(const AMsg: TLspIncoming): string;
    function HandleWorkspaceSymbol(const AMsg: TLspIncoming): string;
    function HandleClassComplete(const AMsg: TLspIncoming): string;
    function HandleSyncPrototypes(const AMsg: TLspIncoming): string;
    function AnnotateArgsAtPath(const APath: string;
      APasLine, APasCol: Integer;
      const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;
    function HandleAnnotateArgs(const AMsg: TLspIncoming): string;
    function LiveTextOf(const APath: string): string;
    function HandleUnits(const AMsg: TLspIncoming): string;
    function HandleUseUnit(const AMsg: TLspIncoming): string;
    function HandleUnusedUses(const AMsg: TLspIncoming): string;
    function HandleUnreferencedUnits(const AMsg: TLspIncoming): string;
    function ProjectUnitMids: TArray<Integer>;
    function UsesEntryNode(AMid: Integer; const AUnitName: string;
      ALine, ACol: Integer): Integer;
    procedure RemovalRefusals(const AByModel: TDictionary<Integer,
      TArray<Integer>>; ARefused: TDictionary<Int64, string>);
    function HandleUsesRemoval(const AMsg: TLspIncoming): string;
    function HandleOnTypeFormatting(const AMsg: TLspIncoming): string;
    function HandlePrepareRename(const AMsg: TLspIncoming): string;
    function HandleRename(const AMsg: TLspIncoming): string;
    function HandleRenamePlan(const AMsg: TLspIncoming): string;
    function HandleFindOverrides(const AMsg: TLspIncoming): string;
    function HandleFindImplementations(const AMsg: TLspIncoming): string;
    function HandleFindDescendants(const AMsg: TLspIncoming): string;
    function HandleFindSites(const AMsg: TLspIncoming;
      AKind: TFindSitesKind): string;
    function HandleFindAllAt(const AMsg: TLspIncoming): string;
    function HandleFindDefines(const AMsg: TLspIncoming): string;
    function HandleDefinesAt(const AMsg: TLspIncoming): string;
    function HandleDcuSource(const AMsg: TLspIncoming): string;
    function HandleProjectChanged(const AMsg: TLspIncoming): string;
    function HandleOutline(const AMsg: TLspIncoming): string;
    function HandleOutlineTarget(const AMsg: TLspIncoming): string;
    function FindAllPreamble(const AMsg: TLspIncoming; const ATag: string;
      out APath: string; out AMid, APasLine, APasCol: Integer;
      out AReply: string): Boolean;
    function PlanRenameAt(const APath: string; APasLine, APasCol: Integer;
      const ANewName: string; out APlan: TLspRenamePlanned;
      out AError: string): Boolean;
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
      request. Never raises, for the same reason Handle does not - see the
      body. }
    procedure Idle;
    { Dispatches one raw JSON message; returns the response to send, or ''
      for notifications (and for client responses we ignore). Never raises:
      a handler exception becomes a JSON-RPC InternalError for requests and
      a stderr line for notifications. }
    function Handle(const AJson: string): string;
    { Server-initiated notifications produced while handling the last
      message (publishDiagnostics, ...) - the caller sends each and the
      queue resets. Drained AFTER the Handle reply by the main loop - and
      during one, through OnFlush, while a request waits out an analysis;
      order within the queue is preserved. }
    function TakeOutgoing: TArray<string>;
    /// <summary>Drains TakeOutgoing to the wire - set by the main program,
    /// called while a request waits out an analysis (WaitAnalyzed), on the
    /// dispatcher thread like every other write.</summary>
    property OnFlush: TProc read FOnFlush write FOnFlush;
    property ExitRequested: Boolean read FExitRequested;
    property ExitCode: Integer read FExitCode;
  end;

implementation

// Defined beside StateLine, used earlier by FinalizeAnalysisIfDone.
function MemoryLine: string; forward;

{ Semantic tokens legend - the indices the ST_/SM_ constants encode MUST match
  the array positions advertised in HandleInitialize, which is why both live
  here as one constant. Every name is from the protocol's standard set, so a
  theme colours them without a semanticTokenScopes map on the client.

  Delphi has no "field" token type in the standard set; fields go out as
  `variable`, which is what they are to the eye. A const is `variable` +
  `readonly` (the spec's own idiom). `defaultLibrary` marks the compiler's
  builtins (sfBuiltin / skBuiltinType) - a unit under a library path would be
  the natural extension, but the navigator keeps that test private today. }
const
  // The `begin` titles of the two kinds of analysis run. Part of the
  // protocol: the IDE plugin tells them apart by the word "incremental"
  // (PasTreeIdePlugin.LspClient, ProgressKindOf) - see SPEC.md.
  cProgressTitleFull = 'PasTree: analyzing';
  cProgressTitleIncremental = 'PasTree: incremental';

  ST_NAMESPACE = 0;
  ST_TYPE = 1;
  ST_CLASS = 2;
  ST_ENUM = 3;
  ST_INTERFACE = 4;
  ST_STRUCT = 5;
  ST_TYPE_PARAMETER = 6;
  ST_PARAMETER = 7;
  ST_VARIABLE = 8;
  ST_PROPERTY = 9;
  ST_ENUM_MEMBER = 10;
  ST_FUNCTION = 11;
  ST_METHOD = 12;
  ST_COMMENT = 13;
  SM_DECLARATION = 1;
  SM_READONLY = 2;
  SM_DEFAULT_LIBRARY = 4;
  SEMANTIC_TOKENS_LEGEND =
    '"legend":{"tokenTypes":["namespace","type","class","enum","interface",' +
    '"struct","typeParameter","parameter","variable","property","enumMember",' +
    '"function","method","comment"],' +
    '"tokenModifiers":["declaration","readonly","defaultLibrary"]}';

// The legend type and modifiers for a resolved symbol. False for the kinds
// no editor colours (labels, and the completion-only skKeyword).
function SemanticTypeOf(const ASym: TSemaSymbol;
  out AType, AMods: Integer): Boolean;
begin
  Result := True;
  AType := ST_TYPE;
  AMods := 0;
  case ASym.Kind of
    skType:
      case ASym.TypeCat of
        tcClass, tcClassOf: AType := ST_CLASS;
        tcInterface: AType := ST_INTERFACE;
        tcRecord: AType := ST_STRUCT;
        tcEnum: AType := ST_ENUM;
      else
        AType := ST_TYPE;
      end;
    skBuiltinType: AType := ST_TYPE;
    skVar, skField: AType := ST_VARIABLE;
    skConst:
      begin
        AType := ST_VARIABLE;
        AMods := SM_READONLY;
      end;
    skRoutine:
      if sfClassMember in ASym.Flags then
        AType := ST_METHOD
      else
        AType := ST_FUNCTION;
    skParam: AType := ST_PARAMETER;
    skProperty: AType := ST_PROPERTY;
    skEnumValue: AType := ST_ENUM_MEMBER;
    skGenericParam: AType := ST_TYPE_PARAMETER;
    skUnitRef: AType := ST_NAMESPACE;
  else
    Result := False;
  end;
  if Result and ((sfBuiltin in ASym.Flags) or (ASym.Kind = skBuiltinType)) then
    AMods := AMods or SM_DEFAULT_LIBRARY;
end;

constructor TLspServer.Create(ACancels: TLspCancelSet);
begin
  inherited Create;
  FCancels := ACancels;
  FDocs := TLspDocumentStore.Create;
  FOutgoing := TList<string>.Create;
  FTakeIn := TStringList.Create;
  FTakeIn.CaseSensitive := False;
  FTakeIn.Sorted := True;
  FTakeIn.Duplicates := dupIgnore;
  FPlatform := pfWin64;
  FTrace := GetEnvironmentVariable('PASTREE_LSP_TRACE') <> '';
  FLogUnits := GetEnvironmentVariable('PASTREE_LSP_LOG_UNITS') <> '';
  FLogDetail := True;
  FLogPath := GetEnvironmentVariable('PASTREE_LSP_LOG');
  FStartedAt := Now;
end;

destructor TLspServer.Destroy;
begin
  // FIRST, while logging still works: a run that faulted every tick until the
  // client vanished has its count nowhere else.
  FlushIdleFault;
  if FClientHandle <> 0 then
    CloseHandle(FClientHandle);
  FCompletion.Free;
  InvalidateAnalysis;
  FOutgoing.Free;
  FDocs.Free;
  FTakeIn.Free;
  FLineTokenCache.Free;
  inherited;
end;

{ Diagnostics channel for the server ITSELF (not the analyzer - those go to
  the client as publishDiagnostics): stderr when PASTREE_LSP_TRACE is set
  (LSP clients capture stderr; VS Code shows it in the Output panel), and a
  file when a path is configured - PASTREE_LSP_LOG env var or the "logFile"
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
  LText, LStamp, LLine: string;
  LWas, LSize: Int64;
begin
  // No `LFile := INVALID_HANDLE_VALUE` before the loop: cRetries is a
  // positive constant, so the body always assigns it and the compiler says
  // so (H2077). If it is ever made zero, the check after the loop turns
  // into W1036 rather than reading a stale handle.
  for LTry := 1 to cRetries do
  begin
    // FILE_READ_ATTRIBUTES beside the append right: GetFileSizeEx below
    // needs it, and it takes no part in sharing.
    LFile := CreateFile(PChar(FLogPath), FILE_APPEND_DATA or
      FILE_READ_ATTRIBUTES, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
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
    LText := AText;
    // EMPTIED UNDER US - see FHeaderLines. The size this server last left
    // is read BEFORE the file's own: every other writer only appends, so a
    // file found shorter than that was truncated (or replaced), never merely
    // written to by someone else.
    LWas := FLogSize;
    if FLogStarted and (Length(FHeaderLines) > 0) and
       GetFileSizeEx(LFile, LSize) and (LSize < LWas) then
    begin
      LStamp := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ';
      LText := LStamp + Format('log emptied under a running server (up ' +
        'since %s) - its header again:',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', FStartedAt)]) + sLineBreak;
      for LLine in FHeaderLines do
        LText := LText + LStamp + LLine + sLineBreak;
      LText := LText + AText;
    end;
    LBytes := TEncoding.UTF8.GetBytes(LText);
    if Length(LBytes) > 0 then
      WriteFile(LFile, LBytes[0], Length(LBytes), LWritten, nil);
    if GetFileSizeEx(LFile, LSize) then
      FLogSize := LSize;
  finally
    CloseHandle(LFile);
  end;
end;

procedure TLspServer.LogHeader(const AMsg: string);
begin
  Log(AMsg);
  FHeaderLines := FHeaderLines + [AMsg];
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
    FreeAndNil(FSession);   // Destroy drains the worker - quick, the cancel
                            // lands mid-pass (FCancelCheck in PasTree)
  end;
  FreeAndNil(FNav);
  FreeAndNil(FProject);
  FDirty := True;
end;

{ -------- configuration -------- }

const
  // The parts of a .dproj the server takes at initialize, in the order
  // DProjSignature returns them - what pastree/projectChanged names when one
  // differs.
  cDProjParts: array[0..6] of string = ('main source', 'platform',
    'search paths', 'defines', 'unit list', 'namespaces', 'unit aliases');

{ What of a loaded .dproj the analysis depends on, one string per part of
  cDProjParts. Order-preserving on purpose: the search path order decides
  which copy of a unit wins, so a reordered path is a changed configuration. }
function DProjSignature(ADProj: TPasDProj): TArray<string>;

  function Joined(const AItems: TArray<string>): string;
  begin
    Result := string.Join(#10, AItems);
  end;

var
  LFiles: TArray<string>;
  LItem: string;
  LAliases: TArray<string>;
  LAlias: TPasUnitAlias;
begin
  // Only .pas rows, as ApplyInitOptions takes them: a .dfm/.res row is not a
  // unit, so one appearing or going changes nothing the analysis reads.
  LFiles := nil;
  for LItem in ADProj.Files do
    if SameText(TPath.GetExtension(LItem), '.pas') then
      LFiles := LFiles + [LItem];
  LAliases := nil;
  for LAlias in ADProj.UnitAliases do
    LAliases := LAliases + [LAlias.Alias + '=' + LAlias.UnitName];
  Result := [ADProj.MainSource, PlatformName(ADProj.Platform),
    Joined(ADProj.SearchPaths), Joined(ADProj.Defines), Joined(LFiles),
    Joined(ADProj.Namespaces), Joined(LAliases)];
end;

{ "process started HH:MM:SS.zzz, N ms before initialize" - see the caller. }
function ProcessStartLine: string;
var
  LCreation, LExit, LKernel, LUser: TFileTime;
  LLocal: TFileTime;
  LSys: TSystemTime;
  LStarted: TDateTime;
begin
  if not GetProcessTimes(GetCurrentProcess, LCreation, LExit, LKernel,
       LUser) or not FileTimeToLocalFileTime(LCreation, LLocal) or
     not FileTimeToSystemTime(LLocal, LSys) then
    Exit('process start time unavailable');
  LStarted := SystemTimeToDateTime(LSys);
  Result := Format('process started %s, %d ms before initialize',
    [FormatDateTime('hh:nn:ss.zzz', LStarted),
     Round((Now - LStarted) * MSecsPerDay)]);
end;

procedure TLspServer.ApplyInitOptions(AOptions: TJSONValue);
var
  LProjectFile, LPlatformStr, LConfigStr, LItem, LHost: string;
  LArr: TJSONArray;
  LVal: TJSONValue;
  LDProj: TPasDProj;
  LAlias: TPasUnitAlias;
  LDef: TPasUnitAliasDef;
begin
  LProjectFile := '';
  LPlatformStr := '';
  LConfigStr := '';
  LHost := '';
  if AOptions is TJSONObject then
  begin
    LProjectFile := AOptions.GetValue<string>('projectFile', '');
    // WHICH IDE, to the update. Free-form and unvalidated on purpose: the
    // server cannot know it (it is a separate process, and the VS Code client
    // has no IDE at all), so whoever launched us is the only authority and
    // this is a passthrough to the log. It exists because a fault reported
    // from another machine starts with "same product, different host" - the
    // 2026-09-02 report was against RAD Studio 13.1 where the analysis was
    // developed on 13.0, and the search paths alone say only "37.0", which
    // both updates share.
    LHost := AOptions.GetValue<string>('host', '');
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
    // Absent or malformed reads as True: see the header - the inventory is
    // what this log was built around, and only a client that says otherwise
    // loses it.
    FLogDetail := AOptions.GetValue<Boolean>('logDetail', True);
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
  // All three, and the configured and watching lines below, are the HEADER
  // (LogHeader): written again if the IDE empties the log under this server.
  LogHeader(PasLspVersionBanner);
  // SECOND line, next to the version: CPU, cores, RAM - a report from someone
  // else's machine needs this before "is it slow" is even askable.
  LogHeader(PasLspHardwareBanner);
  // THIRD line, next to the build that produced the log: the pair "which exe"
  // and "which IDE ran it" is what a report from someone else's machine has to
  // answer before anything else is worth reading.
  if LHost <> '' then
    LogHeader('host: ' + LHost);
  // How long this process lived before initialize reached it. The version
  // line above is the log's first, and it waits for initialize (the log path
  // comes in it), so without this a slow start - the exe loading, a virus
  // scan of a freshly built exe, a starved machine - cannot be told from a
  // client that sent initialize late (AVImark, 2026-10-01: 20 s between the
  // restart and the first line, nothing to say where they went).
  Log(ProcessStartLine);

  FInitProjectFile := LProjectFile;
  FInitPlatform := LPlatformStr;
  FInitConfig := LConfigStr;
  FProjectSig := nil;

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
        FProjectSig := DProjSignature(LDProj);
        FMainSource := LDProj.MainSource;
        FPlatform := LDProj.Platform;
        FSearchPaths := LDProj.SearchPaths;
        FDefines := LDProj.Defines;
        // Every unit the project lists, main source included - see
        // FProjectFiles. Only .pas rows can name a unit; a .dfm/.res row in
        // the list would pin a non-unit under a unit's name.
        FProjectFiles := nil;
        for LItem in LDProj.Files do
          if SameText(TPath.GetExtension(LItem), '.pas') then
            FProjectFiles := FProjectFiles + [LItem];
        FProjectDir := TPath.GetDirectoryName(TPath.GetFullPath(LProjectFile));
        // Project namespaces first, then the IDE defaults the .dproj file
        // itself never spells out (they live in the IDE's targets file).
        FNamespaces := LDProj.Namespaces + PasDefaultNamespaces(FPlatform);
        // Defaults FIRST, project entries after: AddUnitAlias overwrites on
        // collision, which gives the project the last word (dcc semantics -
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
    // A bare .dpr root: no MSBuild properties to evaluate - IDE-default
    // namespaces/aliases (see PasDefaultNamespaces: dcc itself has none,
    // they come from the project template).
    FMainSource := TPath.GetFullPath(LProjectFile);
    FProjectDir := TPath.GetDirectoryName(FMainSource);
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
    // NOT appended to searchPaths, and not derived from them: this is the
    // same question asked of a different list - "which of these directories
    // hold sources the user does not own". See FLibraryPaths.
    if AOptions.TryGetValue<TJSONArray>('libraryPaths', LArr) then
    begin
      for LVal in LArr do
        if LVal.TryGetValue<string>(LItem) then
          FLibraryPaths := FLibraryPaths + [LItem];
    end
    else if TJSONObject(AOptions).GetValue('libraryPaths') <> nil then
      Tell(2, 'PasTree: the libraryPaths setting is not a list of strings'
        + ' - ignored, so rename will not refuse library sources', True);
  end;
  LogHeader(Format('configured: platform=%s main=%s paths=%d defines=%d'
    + ' libraryPaths=%d projectFiles=%d projectDir=%s',
    [PlatformName(FPlatform), FMainSource, Length(FSearchPaths),
     Length(FDefines), Length(FLibraryPaths), Length(FProjectFiles),
     FProjectDir]));
  // A ZERO HERE IS A REAL CONDITION, not a quiet default, so it says so on
  // the summary line rather than only in the detail block: with no library
  // trees declared, a rename that reaches into the RTL is planned and applied
  // instead of refused, and nothing else in the log would hint at why.
  if Length(FLibraryPaths) = 0 then
    Log('  no libraryPaths declared - rename will not refuse RTL/VCL or'
      + ' third-party sources on the grounds of where they live');
  // THE PATHS THEMSELVES, not just how many. A count tells you nothing about
  // the failure this actually has: a plausible-looking number of paths that
  // happen to be the wrong directories (the IDE plugin sent three that did not
  // contain the RTL for months) reads as a healthy configuration right up until
  // every F1027 in the parse record. Which is exactly why the summary line
  // above is NOT part of what logDetail can switch off: turning the detail off
  // must cost you the list, never the counts that say the list is worth
  // asking for.
  if not FLogDetail then
    Exit;
  var LLines: TArray<string> := nil;
  for LItem in FSearchPaths do
    LLines := LLines + ['  path ' + LItem];
  // Listed separately from `path`, even though every entry here is normally
  // also a search path: the question "why did rename refuse this file" is
  // answered by THIS list and no other, and finding it by eye inside a
  // hundred-and-forty-line path block is not answering it.
  for LItem in FLibraryPaths do
    LLines := LLines + ['  library path ' + LItem];
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
  the new one is taken - the demo's double-buffering discipline. }
procedure TLspServer.StartAnalysis(const APriorityFile: string);
var
  LRoots, LPriority: TArray<string>;
  LDoc: TLspDocument;
  LAlias: TPasUnitAlias;
  LItem: string;
begin
  if FSession <> nil then
  begin
    // A MODULE SESSION OWNS THE LAST-GOOD PROJECT (CreateForModule took it,
    // TryStartModuleAnalysis set FProject to nil), so freeing it blind throws
    // the entire analysis cache away - and silently: every answer afterwards
    // is still correct, the rebuild below simply runs with no parse donor
    // (SetParseDonor is gated on FProject <> nil) and repares the whole
    // closure from scratch. Exactly the invisible "full rebuild on a
    // one-file edit" CLAUDE.md warns about. Destroy would block in WaitFor
    // anyway - AnalyzeModuleOnly ignores Cancel, it is one commit point - so
    // waiting here costs nothing that was not already paid, and it buys the
    // project back.
    if FModuleMode then
    begin
      FSession.WaitFor;
      FreeAndNil(FNav);
      FProject := FSession.TakeProject;
      FOutlineCache := '';   // a new project: the outline table is stale
      FreeAndNil(FLineTokenCache);
      if FProject <> nil then
      begin
        FNav := NewNavigator;
        if FSession.ModuleAccepted then
        begin
          // The run committed: the project now IS the inputs that session
          // started from, so that is what the next comparison must use.
          CommitBuiltParts;
          LogTakenIn;
        end
        else
          // Refused. FinalizeAnalysisIfDone would have set this; the fast
          // path must not be re-offered the change it just declined.
          FNoModuleOnce := True;
      end;
    end
    else
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

  // BEFORE the first call into PasTree, and it is not redundant with the
  // "analysis started" line below. Everything between here and there can
  // raise - constructing the project builds the source manager, the platform
  // defines and the seeded System scope - and a failure there used to leave
  // the log saying only "starting the initial analysis" followed by an
  // exception per idle tick forever, since FPendingDue is cleared further
  // down and every tick retries. That is exactly the shape of the 2026-09-02
  // report, and the hour it cost was spent deciding whether StartAnalysis had
  // even been reached. This line answers that; the pair of lines brackets the
  // setup, and only "analysis started" means the session is running.
  Log(Format('building the analysis session: %d roots, %d paths, %d overlays',
    [Length(LRoots), Length(FSearchPaths), FDocs.Count]));
  FSession := TPasAsyncSession.Create(FPlatform, FSearchPaths, FDefines,
    LRoots, LPriority);
  FSession.SetNamespaces(FNamespaces);
  // A member after a dot that nothing resolves (`Grid.Canvas2`) is E2003 too.
  // PasTree leaves it off by default - a false E2003 on a member is worse
  // than a missing one - and without it the squiggles missed the most common
  // typo there is (Alex, 2026-09-24, on AVImark). The library's own corpus
  // runs, AVImark's 3767 units among them, report zero under the switch.
  // Carried by the project object, so the incremental CreateForModule path
  // below inherits it.
  FSession.SetReportUnresolvedMembers(True);
  // Before Start, like every other piece of configuration: the project's
  // directory and its own unit list outrank the search paths (FProjectFiles).
  if FProjectDir <> '' then
    FSession.SetProjectDir(FProjectDir);
  for LItem in FProjectFiles do
    FSession.PinUnitFile(LItem);
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
  // Document truth, stamped with the client's version - compared on
  // completion to catch a snapshot that went stale mid-build.
  for LDoc in FDocs.All do
    FSession.SetBuffer(LDoc.Path, LDoc.Text, LDoc.Version);
  FDirty := False;   // this session covers everything up to now
  FDiskMoved := False;   // and reads every file itself
  // Every buffer goes in above, so a unit waiting to be taken in is taken in
  // here if anything names it; one still outside afterwards is not named, or
  // not resolvable, and its next didOpen arms it again.
  FTakeIn.Clear;
  FPendingDue := 0;  // whatever was scheduled is covered by this start
  FPendingPriority := '';
  FStartedParts := OverlayParts(True);
  FBuildStart := GetTickCount64;
  FBuildDiskReadAt := Now;   // before the worker reads anything
  StartProgress(cProgressTitleFull);
  // "full rebuild" spelled out on purpose: this is the line that tells a
  // full rebuild from the incremental one TryStartModuleAnalysis logs, which
  // is the first question a "the analysis got slow while typing" report asks
  // (see CLAUDE.md).
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

// Fires a scheduled analysis NOW (deadline ignored) - requests call this so
// they never sit out the debounce window.
procedure TLspServer.FlushPending;
var
  LNamer: string;
begin
  if FPendingDue = 0 then
    Exit;
  // Nothing to do if the inputs are back to what the current project was
  // built from - an edit typed and undone, or a file opened and closed.
  //
  // ONLY WITH NOTHING IN FLIGHT. FBuiltSignature describes the last COMPLETED
  // analysis; a session running right now was started from FStartedParts,
  // which the undo has just made obsolete. Dropping the plan then leaves the
  // rebuild nobody will do: the in-flight result lands, FDirty is False, and
  // the reverted document is skipped by the stamp loop in
  // FinalizeAnalysisIfDone too (its text equals its file again, so Differs is
  // False) - so both staleness branches stay silent and every answer after
  // that is computed from text the editor no longer holds, until the next
  // real edit. Type a character, start a build, Ctrl+Z: that is the whole
  // repro, and it is silent.
  //
  // Nor with a unit waiting to be taken in: its buffer is outside the closure
  // and therefore outside the signature, so the signature cannot see it.
  if (FProject <> nil) and (FSession = nil) and not FDiskMoved and
     (OverlaySignature = FBuiltSignature) and not TakeInNamer(LNamer) then
  begin
    Log('scheduled rebuild dropped: the analyzed inputs did not change');
    FPendingDue := 0;
    FPendingPriority := '';
    FDirty := False;
    Exit;
  end;
  // A FULL REBUILD IN FLIGHT IS LEFT TO FINISH. StartAnalysis would cancel it
  // and begin again from nothing, and on a machine where the rebuild takes
  // longer than a typing pause that is a rebuild that never completes: six
  // restarts in five seconds of typing on the reference project (2026-09-08
  // log), every core busy the whole time and nothing ever analyzed. FDirty
  // stays set, so FinalizeAnalysisIfDone sees the result as stale the moment
  // it lands and calls StartAnalysis itself - which, with a completed project
  // to patch, takes the incremental one-module path for a keystroke. The
  // edit therefore costs one full build plus ~70 ms instead of a restart.
  //
  // Only the FULL session: a module session takes tens of milliseconds and
  // its Cancel is a WaitFor anyway (see StartAnalysis), so restarting it is
  // what it always was. The pending priority file is dropped with the plan -
  // the running session cannot take one, and the stale restart is the
  // incremental path, which has no use for it.
  if (FSession <> nil) and not FModuleMode then
  begin
    Log('rebuild in flight - the change waits for it rather than restarting');
    FPendingDue := 0;
    FPendingPriority := '';
    Exit;
  end;
  StartAnalysis(FPendingPriority);
end;

{ WHAT WAS ACTUALLY PARSED, AND EVERYTHING WRONG WITH IT - the whole closure,
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

{ Swaps a finished session's project in (on the dispatcher thread - the
  worker is done, TakeProject is the ownership handoff) and publishes
  diagnostics. If any open document changed since the session snapshotted
  its buffers - detected via the version stamps SetBuffer carried - the
  result is already stale: swap it in anyway (better navigation than none)
  but immediately start the replacement build. }
procedure TLspServer.FinalizeAnalysisIfDone;
var
  LDoc: TLspDocument;
  LStale, LWasModule: Boolean;
  LError, LNamer: string;
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
    FOutlineCache := '';   // a new project: the outline table is stale
    FreeAndNil(FLineTokenCache);
    FreeAndNil(FSession);
    FModuleMode := False;
    if FProject <> nil then
      FNav := NewNavigator;
    // NOT IfThen: it is an ordinary function, so BOTH arms are evaluated
    // before the call and FProject.StageTimings would dereference nil in the
    // one case the expression exists to describe.
    var LWhy: string;
    if FProject = nil then
      LWhy := 'no project returned'
    else
      LWhy := FProject.StageTimings;
    Log(Format('incremental refused for %s (%s) - full rebuild',
      [FModuleFile, LWhy]));
    FNoModuleOnce := True;
    StartAnalysis(FModuleFile);
    Exit;
  end;
  FreeAndNil(FNav);
  FreeAndNil(FProject);
  FProject := FSession.TakeProject;
  FOutlineCache := '';   // a new project: the outline table is stale
  FreeAndNil(FLineTokenCache);
  FreeAndNil(FSession);
  if FProject = nil then
  begin
    // The stream has to close here too: a client showing "analyzing" off it
    // (the IDE's status panel) would otherwise say so until the next build.
    EndProgress('no result');
    Exit;
  end;
  FNav := NewNavigator;
  CommitBuiltParts;
  LWasModule := FModuleMode;
  FModuleMode := False;
  if not LWasModule then
  begin
    FDiskReadAt := FBuildDiskReadAt;
    // Before the "analysis done" line, so its memory figure is what the
    // server holds from here on.
    DemoteLibraryText;
  end;
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
    + ' stages %s %s',
    [IfThen(LWasModule, 'done (incremental)', 'done'), FProject.ModelCount,
     GetTickCount64 - FBuildStart, LDiagTotal, FProject.StageTimings,
     MemoryLine]));
  // Every unit and every diagnostic, not just the open documents' - see
  // LogParseRecord for why that difference is the whole point.
  //
  // NOT after an accepted incremental run: the closure is the one this
  // already recorded, unit for unit and file for file, and the questions the
  // record answers ("which copy of this unit won?", "what did the analysis
  // fail to load?") are rebuild questions. Writing it per keystroke would
  // walk every model of a 3676-unit project and bury the rebuild that
  // matters under a hundred repetitions of itself. The stages field above
  // carries what IS new - module=<radius>, or module=refused:<reason> - and
  // a unit the run took in is recorded on its own (LogTakenIn), since that
  // one DID change the closure.
  if not LWasModule then
    LogParseRecord
  else
    LogTakenIn;

  LStale := FDirty;
  if not LStale then
    for LDoc in FDocs.All do
      // Only documents whose text DIFFERS from disk can make a result
      // stale: a non-differing one reads identically from either source,
      // and it may legitimately have no overlay in this build at all
      // (opened after the build started, no rebuild scheduled) - comparing
      // its version against the missing overlay's -1 would spin a rebuild
      // loop out of plain tab switching.
      // Nor can a document outside this closure (AffectsAnalysis): it is
      // an overlay nothing read, so its version moving mid-build changes
      // nothing about the result.
      if LDoc.Differs and AffectsAnalysis(LDoc.Path) and
         (FProject.BufferVersion(LDoc.Path) <> LDoc.Version) then
      begin
        LStale := True;
        Break;
      end;
  PublishDiagnostics;
  if LStale then
  begin
    // Typed and undone while the build ran: the inputs are back to what this
    // result was built from, and there is nothing to restart for. Without
    // this check the restart would find no single changed document and run a
    // second FULL rebuild for an edit that no longer exists - the same trap
    // FlushPending's drop guards against, reached from the other side now
    // that an in-flight full build is left to finish instead of restarted.
    // A unit waiting to be taken in is outside the signature, so the
    // signature cannot say it is done: a new unit opened while a build ran
    // that started before its buffer existed (see TakeInNamer).
    if (OverlaySignature = FBuiltSignature) and not FDiskMoved and
       not TakeInNamer(LNamer) then
    begin
      Log('documents changed mid-build and changed back - result is current');
      FDirty := False;
    end
    else
    begin
      Log('result is stale (documents changed mid-build) - restarting');
      StartAnalysis('');
    end;
  end;
end;

{ The client-liveness watchdog.

  Normally the session ends when the client closes our stdin: the reader
  thread sees EOF and the dispatcher stops. That covers every orderly exit and
  most disorderly ones. What it does not cover is a client that DIES while
  something else keeps the pipe's write end open - then stdin never reaches
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

  (2) exists because a decode disagreement is not an edit, and the historical
  one was exactly this: PasTree read a preamble-less source as ANSI (dcc's own
  rule, and the point of its tolerant loader) while an editor read it as UTF-8,
  so every PasTree source with an em-dash in a comment "differed" from its own
  file under (1) alone - a 3-byte UTF-8 dash becoming three ANSI characters.

  What it cost before this test existed: peeking a declaration (VS Code opens
  the target file, then closes it) scheduled TWO full closure rebuilds, ~14
  seconds of the editor apparently reparsing a file nobody touched. The user
  saw it as a rebuild bug; it was this.

  THE ANSI PART OF THAT STORY IS HISTORY, and this comment said otherwise for
  long enough to be worth naming: PasTree since 0.2.3 (the pinned minimum is
  far past it - see cMinPasTreeVersion) decodes a preamble-less source whose
  bytes are valid UTF-8 AS UTF-8, which is the fix of 2026-08-20, so the
  analysis and the editor read the same text for a closed file too. Bytes stay
  the right question anyway: they are the one comparison no decoder gets to
  answer differently. }
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
{ IS THIS DOCUMENT ONE OF OURS - a file the last completed analysis loaded?

  The RAD Studio client runs one server per project of a group and sends every
  open buffer to every server (see PasTreeIdePlugin.LspSession), because the
  client cannot know which project compiles a file: the .dproj lists some of
  them, and the search path supplies the rest, silently. AVImarkServer
  compiles uaviItem.pas that way while only AVImark.dproj lists it, and the
  two routing rules the client tried before this ("the listed owner", then
  "the listed owner or the active project") each left a real edit unseen by
  a server that compiled the file (2026-09-11).

  So the SERVER decides, since it is the only party that knows its closure. A
  buffer outside it is kept as an overlay - a later edit may pull it in, and
  the rebuild that edit schedules reads every overlay - but it schedules
  nothing and does not count in the overlay signature, where it would turn the
  next one-file edit into a two-document change and cost the module fast path.
  Without a completed project the answer is True: nothing is known yet, and
  the first buffer is what starts the initial build. }
function TLspServer.AffectsAnalysis(const APath: string): Boolean;
begin
  Result := (FProject = nil) or (FProject.ModelIdOf(APath) >= 0);
end;

{ Was APath written after the newest analysis read the disk? The running full
  build counts - it reads the file itself - so a rebuild already under way
  covers a change made before it started. One stat call. False when nothing
  has read the disk yet (the first build is scheduled on its own) or the
  file has no readable date. }
function TLspServer.DiskNewerThanAnalysis(const APath: string): Boolean;
var
  LReadAt, LAge: TDateTime;
begin
  LReadAt := FDiskReadAt;
  if (FSession <> nil) and not FModuleMode then
    LReadAt := FBuildDiskReadAt;
  Result := (LReadAt > 0) and FileAge(APath, LAge) and (LAge > LReadAt);
end;

// The path of one `path|len|hash` part (see OverlayParts), lower-cased there.
function PartPath(const APart: string): string;
begin
  Result := Copy(APart, 1, Pos('|', APart) - 1);
end;

function TLspServer.OverlayParts(AAll: Boolean): TArray<string>;
var
  LDoc: TLspDocument;
  LParts: TStringList;
begin
  LParts := TStringList.Create;
  try
    // ORDINAL, and it has to be: ChangedDocs merges this list against
    // the previous build's with `<` on the strings, which is codepoint order.
    // TStringList's default comparer is AnsiCompareText - a locale word sort
    // that weighs punctuation differently - so with the two disagreeing (say
    // `ab.pas` against `a-c.pas`) common entries fail to line up, count as an
    // appearance plus a disappearance, and a genuine one-file edit loses the
    // module fast path: a full closure rebuild per keystroke, silently, with
    // every answer still correct.
    LParts.UseLocale := False;
    LParts.CaseSensitive := True;
    LParts.Sorted := True;   // dictionary order is not stable; this is
    for LDoc in FDocs.All do
      if LDoc.Differs and (AAll or AffectsAnalysis(LDoc.Path)) then
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

{ What the finished analysis was built from, cut against the closure IT
  produced: the parts of every document that differed when the run started
  (FStartedParts) and that the new project holds.

  Cut AFTER the run, not at its start, and the difference is a unit that joins
  the closure in the run - the IDE's File > New > Unit. At the start its
  buffer was outside the closure and outside the parts; afterwards it is
  inside, so the NEXT signature lists it. Parts taken at the start never did,
  so the unit read as a freshly changed document forever after: the first edit
  anywhere else was two changed documents and a full rebuild, and "typed and
  undone" could never match again. OverlayParts cuts the current documents
  with the same closure, so the two stay comparable. }
procedure TLspServer.CommitBuiltParts;
var
  LPart: string;
  LKept: TArray<string>;
begin
  LKept := nil;
  for LPart in FStartedParts do
    if AffectsAnalysis(PartPath(LPart)) then
      LKept := LKept + [LPart];
  FBuiltParts := LKept;
  FBuiltSignature := string.Join(',', FBuiltParts);
end;

{ How many documents' text changed since the last completed analysis - 0, 1,
  or 2 for "more than one" - and, for exactly one, which (APath, the
  signature's lower-cased spelling).

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
  still spends one module run on it. Cheap, and simpler than proving it.

  ZERO is an answer of its own since 0.55.0: nothing the closure holds
  changed, yet a unit waiting outside it may be due for a take-in (see
  TakeInNamer), which is a module run too. }
function TLspServer.ChangedDocs(out APath: string): Integer;
var
  LNow: TArray<string>;
  LI, LJ, LFound: Integer;
  LLeft, LRight: string;
begin
  APath := '';
  LNow := OverlayParts;
  if FProject = nil then
    Exit(2);
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
    begin
      APath := '';
      Exit(2);
    end;
  end;
  Result := LFound;
  if Result <> 1 then
    APath := '';
end;

{ The program that NAMES ADocPath and has not got it: a model of the closure
  whose `uses` entry says `X in '<ADocPath>'` and resolved to nothing - the
  program was analyzed before the unit's buffer existed. '' when there is
  none. The in-path is read the way the source manager's first probe reads
  it: rooted as it stands, otherwise beside the naming file. Every model's
  uses list is walked (a few tens of thousands of entries on a large project,
  a string test each); only a document waiting for a take-in pays for it. }
function TLspServer.NamerOf(const ADocPath: string): string;
var
  LMid, LU: Integer;
  LModel: TPasSemaModel;
  LPath: string;
begin
  Result := '';
  if FProject = nil then
    Exit;
  for LMid := 0 to FProject.ModelCount - 1 do
  begin
    LModel := FProject.Model(LMid);
    if LModel = nil then
      Continue;
    for LU := 0 to High(LModel.UsesList) do
    begin
      if (LModel.UsesList[LU].InPath = '') or
         (LModel.UsesList[LU].UnitId >= 0) then
        Continue;
      LPath := LModel.UsesList[LU].InPath;
      try
        if not TPath.IsPathRooted(LPath) then
          LPath := TPath.Combine(
            TPath.GetDirectoryName(FProject.ModelFile(LMid)), LPath);
        LPath := TPath.GetFullPath(LPath);
      except
        Continue;   // an in-string no file name can hold names no document
      end;
      if SameText(LPath, TPath.GetFullPath(ADocPath)) then
        Exit(FProject.ModelFile(LMid));
    end;
  end;
end;

{ IS A TAKE-IN DUE: a document waiting in FTakeIn that a program of the
  closure names without having it (NamerOf), and that program's path in
  ANamer.

  The IDE's New Unit writes the unit into the program's uses clause and opens
  the unit's editor, and WHICH ORDER reaches the server depends on the
  program's editor. With no view, the uses edit raises no editor event and
  rides the unit's first-sight sync: both arrive together, the program's own
  edit carries the unit in (the module path takes in a new import since
  PasTree 0.53.0) and nothing waits here. With the program open in a tab - the
  usual session - the edit fires EditorViewModified and goes out on the next
  idle tick, the unit's didOpen with the first-sight sync over a second later
  (1.6 s in the first AVImark run, 2026-09-26): the program is analyzed with
  the unit a missing import (F1027), then the unit's buffer arrives. Nothing
  about the closure's documents changes at that point, so no signature shows
  it; this does.

  Also prunes: a document no longer open, now inside the closure, or now on
  disk (saved - the rebuild the disk change schedules sees it) waits no
  more. }
function TLspServer.TakeInNamer(out ANamer: string): Boolean;
var
  LIdx: Integer;
  LDoc: TLspDocument;
begin
  ANamer := '';
  Result := False;
  if (FProject = nil) or (FTakeIn.Count = 0) then
    Exit;
  for LIdx := FTakeIn.Count - 1 downto 0 do
    if not FDocs.TryGet(FTakeIn[LIdx], LDoc) or
       (FProject.ModelIdOf(FTakeIn[LIdx]) >= 0) or
       FileExists(FTakeIn[LIdx]) then
      FTakeIn.Delete(LIdx);
  for LIdx := 0 to FTakeIn.Count - 1 do
  begin
    ANamer := NamerOf(FTakeIn[LIdx]);
    if ANamer <> '' then
      Exit(True);
  end;
end;

{ The units an accepted module run TOOK IN (PasTree 0.53.0) - the models past
  the count the run started from - with their files and diagnostics, the part
  of LogParseRecord that is new: a rebuild would have listed them there, and
  the per-keystroke runs that change nothing about the closure stay silent. }
procedure TLspServer.LogTakenIn;
var
  LLines: TArray<string>;
  LMi, LDi, LFileId: Integer;
  LModel: TPasSemaModel;
  LFile: string;
begin
  if (FProject = nil) or (FProject.ModelCount <= FModuleBaseCount) then
    Exit;
  LLines := [Format('taken in by the incremental run: %d units',
    [FProject.ModelCount - FModuleBaseCount])];
  for LMi := FModuleBaseCount to FProject.ModelCount - 1 do
  begin
    LModel := FProject.Model(LMi);
    LLines := LLines + [Format('  unit %s <- %s%s',
      [LModel.UnitNameLower, FProject.ModelFile(LMi),
       IfThen(Length(LModel.Diags) = 0, '',
         Format(' (%d diagnostics)', [Length(LModel.Diags)]))])];
    for LDi := 0 to High(LModel.Diags) do
    begin
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
  LogBlock(LLines);
  // Once per run: the count moves on with the closure.
  FModuleBaseCount := FProject.ModelCount;
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
  LPath, LNamer, LTakeInNote: string;
  LId, LChanged, LIdx: Integer;
  LDoc: TLspDocument;
begin
  Result := False;
  if FNoModuleOnce then
  begin
    FNoModuleOnce := False;
    Exit;
  end;
  if FProject = nil then
    Exit;
  // A FILE MOVED ON DISK needs the rebuild it was scheduled for: the module
  // path re-reads one unit and trusts every other file to be what the closure
  // read. Only the signature used to keep this off the fast path - a disk
  // change moves no overlay - so a disk change arriving beside an edit took
  // the module run, and FDiskMoved stayed set with nothing left to rebuild.
  if FDiskMoved then
    Exit;
  LChanged := ChangedDocs(LPath);
  LTakeInNote := '';
  if TakeInNamer(LNamer) then
  begin
    // A unit waiting to be taken in (see TakeInNamer): its program is re-run,
    // which takes the unit in - unless something else changed as well, when
    // the rebuild covers both.
    if (LChanged = 1) and
       (FProject.ModelIdOf(LPath) <> FProject.ModelIdOf(LNamer)) then
      Exit;
    if LChanged > 1 then
      Exit;
    LPath := LNamer;
    // Consumed here: whether the run takes them in or not, retrying would
    // only repeat it (see FTakeIn).
    for LIdx := FTakeIn.Count - 1 downto 0 do
      if SameText(NamerOf(FTakeIn[LIdx]), LNamer) then
      begin
        LTakeInNote := LTakeInNote + ' ' + TPath.GetFileName(FTakeIn[LIdx]);
        FTakeIn.Delete(LIdx);
      end;
    LTakeInNote := ' to take in' + LTakeInNote;
  end
  else if LChanged <> 1 then
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
  FStartedParts := OverlayParts(True);
  FModuleBaseCount := FProject.ModelCount;
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
  // A stream per incremental run as well: most finish in tens of
  // milliseconds, and it is the CLIENT that decides what is worth showing
  // (the IDE's status panel waits 250 ms). The title is what tells the two
  // kinds apart - see SPEC.md, "$/progress".
  StartProgress(cProgressTitleIncremental);
  Log(Format('analysis started: incremental, one module (%s)%s',
    [LPath, LTakeInNote]));
  FSession.Start;
  Result := True;
end;

procedure TLspServer.StartProgress(const ATitle: string);
begin
  if not FClientProgress then
    Exit;
  // A stream still open belongs to a run that was replaced (a refused
  // incremental becoming a full rebuild, a stale result restarting): close
  // it, so the title a client shows is the run actually going on.
  if FProgressToken <> '' then
    EndProgress('');
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
    LogHeader(Format('watching client pid %d', [APid]));
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

function TLspServer.NewNavigator: TPasNavigator;
var
  LDoc: TLspDocument;
begin
  Result := TPasNavigator.Create(FProject);
  Result.LibraryPaths := FLibraryPaths;
  // Every project swap passes through here, so this is where an open
  // document demoted in the project being swapped in gets its text back -
  // see HydrateOpenDoc.
  for LDoc in FDocs.All do
    HydrateOpenDoc(Result, LDoc.Path);
end;

{ Frees the text layer (sources, tokens, line tables) of every unit that is
  neither open nor the project's own - the library, which is most of a
  closure's text and what an edit rarely touches. PasTree's stage A2,
  estimated there at about 920 MB for this server. The maps and symbols
  stay, so the module fast path and the next rebuild's parse donor keep
  working; what needs a demoted unit's
  text gets it back (EnsureHydrated, ~1 ms a unit) - the navigator does that
  itself, and the few places here that read a foreign model's tokens
  directly (completion details, argument annotation) do it by hand.

  After a FULL build only, not after every accepted incremental run, although
  PasTree allows both: a module run rehydrates the consumers of the edited
  unit, which are project units and kept anyway, so demoting again there
  frees next to nothing - while it would throw away every library unit the
  last completion list rehydrated, and the next Ctrl+Space would pay ~1 ms
  per such unit again, per keystroke.

  Kept: the open documents, the main source, the .dproj's units and
  everything under the project directory (a bare .dpr lists no units). }
procedure TLspServer.DemoteLibraryText;
var
  LKeep: TList<string>;
  LDoc: TLspDocument;
  LDir, LItem: string;
  LMid, LBefore, LAfter: Integer;
  LStart: UInt64;

  function DemotedCount: Integer;
  var
    LI: Integer;
  begin
    Result := 0;
    for LI := 0 to FProject.ModelCount - 1 do
      if (FProject.Model(LI) <> nil) and FProject.Model(LI).Demoted then
        Inc(Result);
  end;

begin
  if FProject = nil then
    Exit;
  LStart := GetTickCount64;
  LBefore := DemotedCount;
  LKeep := TList<string>.Create;
  try
    for LDoc in FDocs.All do
      LKeep.Add(LDoc.Path);
    if FMainSource <> '' then
      LKeep.Add(FMainSource);
    LKeep.AddRange(FProjectFiles);
    if FProjectDir <> '' then
    begin
      LDir := IncludeTrailingPathDelimiter(TPath.GetFullPath(FProjectDir));
      for LMid := 0 to FProject.ModelCount - 1 do
      begin
        LItem := FProject.ModelFile(LMid);
        if (LItem <> '') and
           TPath.GetFullPath(LItem).StartsWith(LDir, True) then
          LKeep.Add(LItem);
      end;
    end;
    FProject.DemoteText(LKeep.ToArray);
  finally
    LKeep.Free;
  end;
  LAfter := DemotedCount;
  Log(Format('library text demoted: %d of %d units (%d newly) in %d ms',
    [LAfter, FProject.ModelCount, LAfter - LBefore,
     GetTickCount64 - LStart]));
end;

{ An open document's model with its text in place. DemoteText keeps the open
  files, but a file opened AFTER the demotion (a library unit Ctrl+Clicked
  into) was not open then, and the diagnostics and documentSymbol paths read
  an open document's tokens without asking - a demoted one would lose its
  underline positions and its whole outline, silently. Called on didOpen and
  at every project swap (NewNavigator); a no-op for a model that has its
  text. Only on the live project: a module session owns it while FProject is
  nil, and the swap after it catches up. }
procedure TLspServer.HydrateOpenDoc(ANav: TPasNavigator; const APath: string);
var
  LMid: Integer;
begin
  if (FProject = nil) or (ANav = nil) then
    Exit;
  LMid := ANav.ModelIdOf(APath);
  if (LMid >= 0) and (FProject.Model(LMid) <> nil) and
     FProject.Model(LMid).Demoted and not FProject.EnsureHydrated(LMid) then
    Log('could not rehydrate the open document ' + APath);
end;

{ This process's memory and the system's remaining commit, in MB, for the two
  lines a memory question is asked of: "analysis done" (how much one closure
  costs on THIS machine) and "EXCEPTION in" (what was left when it failed).
  Added after the 2026-09-22 AVImark report: two EOutOfMemory in one
  millisecond on different threads of a Win64 process on a 32 GB machine,
  and not one number anywhere in the log to say whether the process, the
  system, or a bogus allocation size was to blame. In a project group there
  is one server per project, each holding its own closure, so the process
  figure alone cannot answer that - the system's free commit is what says
  whether the neighbours had already taken the rest. Never raises: it runs
  while unwinding faults. }
function MemoryLine: string;
var
  LCounters: TProcessMemoryCounters;
  LStatus: TMemoryStatusEx;
begin
  Result := '';
  try
    FillChar(LCounters, SizeOf(LCounters), 0);
    LCounters.cb := SizeOf(LCounters);
    if GetProcessMemoryInfo(GetCurrentProcess, @LCounters, SizeOf(LCounters)) then
      Result := Format('mem ws=%dMB peak=%dMB commit=%dMB',
        [LCounters.WorkingSetSize shr 20, LCounters.PeakWorkingSetSize shr 20,
         LCounters.PagefileUsage shr 20]);
    FillChar(LStatus, SizeOf(LStatus), 0);
    LStatus.dwLength := SizeOf(LStatus);
    if GlobalMemoryStatusEx(LStatus) then
      Result := Result + Format(' sys-free phys=%dMB commit=%dMB load=%d%%',
        [LStatus.ullAvailPhys shr 20, LStatus.ullAvailPageFile shr 20,
         LStatus.dwMemoryLoad]);
  except
    // A diagnostic must not become the second failure.
  end;
end;

function TLspServer.StateLine: string;
var
  LSession, LProject: string;
begin
  if FSession = nil then
    LSession := 'none'
  else if FModuleMode then
    LSession := 'module(' + FModuleFile + ')'
  else
    LSession := 'full';
  // ModelCount only through a non-nil project, and NOTHING ELSE about it:
  // this runs while unwinding a fault whose cause is unknown, so it must not
  // become the second place that crashes.
  if FProject = nil then
    LProject := 'none'
  else
    LProject := Format('%d units', [FProject.ModelCount]);
  Result := Format('session=%s project=%s docs=%d dirty=%s pending=%s %s',
    [LSession, LProject, FDocs.Count, BoolToStr(FDirty, True),
     BoolToStr(FPendingDue <> 0, True), MemoryLine]);
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
  { THE SAME GUARANTEE Handle GIVES, for the same work on the background path.
    Everything below walks the model exactly as a request handler does -
    TPasNavigator.Create, IdentAt per diagnostic per open document,
    StartAnalysis - so it can raise for exactly the same reasons (the nil-scope
    AV that took out every documentSymbol on 2026-08-23 is the shape). Reached
    through WaitAnalyzed inside a request, such a failure is a polite
    InternalError; reached from the dispatcher's timeout it used to fly out of
    the program's begin..end and kill the process with nothing in the log. Log
    and keep serving: the next tick tries again, and if the fault is permanent
    the log names it instead of a vanished exe. }
  try
    if (FPendingDue <> 0) and (GetTickCount64 >= FPendingDue) then
      FlushPending;
    FinalizeAnalysisIfDone;
  except
    on E: Exception do
      NoteIdleFault('EXCEPTION in idle finalize: ' + E.ClassName + ': '
        + E.Message + ' [' + StateLine + ']');
  end;
end;

{ One line per distinct idle fault - see FIdleFault for why that matters. }
procedure TLspServer.NoteIdleFault(const AMsg: string);
begin
  if AMsg = FIdleFault then
  begin
    Inc(FIdleFaultRepeats);
    Exit;
  end;
  FlushIdleFault;
  FIdleFault := AMsg;
  FIdleFaultRepeats := 0;
  Log(AMsg);
end;

{ The repeat count, written when the fault changes or the run ends. Called
  from the exit path too, so a session that faulted until the IDE closed still
  says HOW MANY times - "once" and "every tick for eighteen seconds" are
  different failures, and without this they would read identically. }
procedure TLspServer.FlushIdleFault;
begin
  if (FIdleFault = '') or (FIdleFaultRepeats = 0) then
    Exit;
  Log(Format('  (the line above repeated %d more times)',
    [FIdleFaultRepeats]));
  FIdleFaultRepeats := 0;
end;

function TLspServer.WaitAnalyzed(const APriorityFile,
  ARequestIdJson: string): Boolean;
begin
  FlushPending;   // a scheduled build must not make the answer stale
  if (FProject = nil) and (FSession = nil) then
    StartAnalysis(APriorityFile);
  // Wait out the in-flight build (if any), polling the cancel set: this is
  // exactly the moment $/cancelRequest exists for - the reader thread keeps
  // noting cancels while we sit here.
  while FSession <> nil do
  begin
    if (ARequestIdJson <> '') and FCancels.IsCancelled(ARequestIdJson) then
      Exit(False);
    if ClientGone then
      Exit(False);   // the idle tick ends the session
    ReportProgress;
    FinalizeAnalysisIfDone;   // also handles the stale->restart loop
    // OUT NOW, not after the reply: everything queued so far - the
    // progress stream above all - would otherwise wait in FOutgoing until
    // this handler returns, so a client would see the run begin and end
    // only after the answer it waited for (the IDE's status panel said
    // "Ready" through a 38 s rebuild started by a request, 2026-10-01).
    // Inside the loop, so the iteration that finalized also sends the
    // `end` and the diagnostics ahead of the reply.
    if Assigned(FOnFlush) then
      FOnFlush;
    if FSession <> nil then
      TThread.Sleep(10);
  end;
  Result := True;
end;

// LSP DiagnosticSeverity from a PasTree diagnostic code. E/F are dcc's own
// error classes; W maps to warning; everything else (PPIF/PPBAD/PPENC/PPINT,
// our own "the ANALYZER could not decide" family) is information - calling
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
  phase-3 concern - an editor shows squiggles for what the user is looking
  at, and open docs keep the volume bounded on a big project). Publishing
  for every open doc every time - including an EMPTY array when a doc has
  none - is what clears stale squiggles after a fixing edit; LSP has no
  "unchanged" shorthand. A diagnostic raised inside an $I include is matched
  by the include's own FileId path, so it lands on the include's buffer if
  that file is open, and is dropped otherwise (its unit's main file is the
  wrong place to draw it). }
procedure TLspServer.PublishDiagnostics;
var
  LDoc: TLspDocument;
begin
  for LDoc in FDocs.All do
    PublishDiagnosticsFor(LDoc);
end;

{ One open document's share of the above. Also called by didOpen for a
  document opened AFTER the analysis finished with its text unchanged: no
  rebuild is due for it, so without this call it got no publish at all until
  the next edit anywhere - the error was in the log (every diagnostic of the
  closure is) and never on screen (Alex, 2026-09-24, AVImark: the IDE opens
  its tabs after the initial analysis has already published). }
procedure TLspServer.PublishDiagnosticsFor(const ADoc: TLspDocument);
var
  LMid, LIdx, LFileId, LLine, LChar, LEndChar, LEndLine: Integer;
  LModel: TPasSemaModel;
  LDiagFile, LKey: string;
  LSB: TStringBuilder;
  LFirst, LMainIsDoc: Boolean;
  LIdent: TPasNavIdent;
  LNameLine, LNameCol, LNameColTo: Integer;

  { The NAME a diagnostic's node stands for, when IdentAt found none at the
    diagnostic's position: a dotted name is an nkMember, whose FirstToken -
    and so the diagnostic's position, which EmitAt takes from it - is the
    DOT (by design, PasTree.Ast). `uses System.Classes2` with no such unit
    therefore drew a one-character mark under the '.' (Alex, 2026-09-24).
    The member's last token is its name, which is also exactly what dcc's own
    Error Insight underlines there: `Classes2`, not the whole dotted name.
    Only nkMember and nkIdent - a larger node's last token is not its name. }
  function NameSpanOf(AModel: TPasSemaModel; ANode, AFileId: Integer;
    out ALine, ACol, AColTo: Integer): Boolean;
  var
    LVisIdx: Integer;
    LVis: TPasVisibleToken;
    LTok: TPasToken;
  begin
    Result := False;
    if (ANode < 0) or (ANode > High(AModel.Tree.Nodes)) then
      Exit;
    case AModel.Tree.Nodes[ANode].Kind of
      nkMember: LVisIdx := AModel.Tree.Nodes[ANode].LastToken;
      nkIdent: LVisIdx := AModel.Tree.Nodes[ANode].FirstToken;
    else
      Exit;
    end;
    if (LVisIdx < 0) or (LVisIdx > High(AModel.Tree.Source.Visible)) then
      Exit;
    LVis := AModel.Tree.Source.Visible[LVisIdx];
    if LVis.FileId <> AFileId then
      Exit;
    LTok := AModel.Tree.Source.Files[LVis.FileId].Tokens[LVis.TokenIndex];
    if LTok.Len <= 0 then
      Exit;
    AModel.Tree.Source.Files[LVis.FileId].OffsetToLineCol(LTok.Start,
      ALine, ACol);
    AColTo := ACol + LTok.Len;
    Result := True;
  end;

begin
  LMid := FNav.ModelIdOf(ADoc.Path);
  LSB := TStringBuilder.Create;
  try
    LFirst := True;
    if LMid >= 0 then
    begin
      LModel := FProject.Model(LMid);
      LKey := LowerCase(ADoc.Path);
      // Whether this open doc IS the model's main file - the only space
      // IdentAt's coordinates live in. False for an open $I include.
      LMainIsDoc := LowerCase(TPath.GetFullPath(
        FProject.ModelFile(LMid))) = LKey;
      for LIdx := 0 to High(LModel.Diags) do
      begin
        // FileId indexes the MODEL'S own file table ($I includes) - see
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
        end
        // No identifier AT the position - the dot of a dotted name. The
        // node's own name then gives start AND end (see NameSpanOf).
        else if NameSpanOf(LModel, LModel.Diags[LIdx].DeclNode,
          LModel.Diags[LIdx].FileId, LNameLine, LNameCol, LNameColTo) and
          (LNameLine = LModel.Diags[LIdx].Line) then
        begin
          PasTreeToLsp(LNameLine, LNameCol, LLine, LChar);
          PasTreeToLsp(LNameLine, LNameColTo, LEndLine, LEndChar);
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
    // THE VERSION THESE WERE COMPUTED FROM, not the one the document is on
    // now. On the stale path (documents changed mid-build; we publish
    // before restarting, deliberately) those are different, and stamping
    // the current one tells the client the ranges are exact for text they
    // were never measured against - which defeats the only thing the field
    // is for. The project's own buffer stamp is that truth; -1 means this
    // build carried no overlay for the document, and then the document's
    // version is the best available answer.
    var LVer := FProject.BufferVersion(ADoc.Path);
    if LVer < 0 then
      LVer := ADoc.Version;
    Notify(Format(
      '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",' +
      '"params":{"uri":%s,"version":%d,"diagnostics":[%s]}}',
      [JsonQuote(PathToUri(ADoc.Path)), LVer, LSB.ToString]));
  finally
    LSB.Free;
  end;
end;

// didClose: the client owns no more squiggles for this doc - clear them.
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
      // Semantic colouring: full and range, no delta - see
      // HandleSemanticTokens for why the delta form is not offered.
      '"semanticTokensProvider":{' + SEMANTIC_TOKENS_LEGEND +
        ',"full":true,"range":true},' +
      '"completionProvider":{"triggerCharacters":["."]},' +
      '"signatureHelpProvider":{"triggerCharacters":["(",","]},' +
      '"workspaceSymbolProvider":true,' +
      // Block completion: Enter after an unclosed opener answers with the
      // closer. \n is the trigger the protocol was designed around for
      // exactly this (the LSP spec's own example is inserting a closer).
      '"documentOnTypeFormattingProvider":{"firstTriggerCharacter":"\n"},' +
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
  LPath, LText, LDisk, LShownNote, LNamer: string;
  LVersion: Integer;
  LDiffers, LShown, LNoFile: Boolean;
  LDoc: TLspDocument;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  // A leading BOM is not content - see StripLeadingBom. Before the gate
  // below, so a BOM'd file still compares equal to its own bytes on disk.
  LText := StripLeadingBom(AParams.GetValue<string>('textDocument.text', ''));
  LVersion := AParams.GetValue<Integer>('textDocument.version', 0);
  // The rebuild gate: VS Code opens a document for every tab switch and
  // every peek popup, and the analysis already read this file from disk -
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
  { "background" = the client says this document is loaded but not on screen.
    A RAD Studio session is full of them - opening one form pulls in its
    visual-inheritance ancestors and the datamodules its .dfm references - and
    without the word the log reads as though the user opened five files when
    they opened one. Non-standard and OPTIONAL: a client that does not send
    pastreeShown (VS Code opens what the user opened) says nothing here rather
    than being described as showing everything. }
  LShownNote := '';
  if AParams.TryGetValue<Boolean>('textDocument.pastreeShown', LShown)
     and not LShown then
    LShownNote := ' (background)';
  if LDiffers then
    Log(Format('textDocument/didOpen %s v%d%s (unsaved: %d chars here, %d on disk)',
      [LPath, LVersion, LShownNote, Length(LText), Length(LDisk)]))
  else
    Log(Format('textDocument/didOpen %s v%d%s',
      [LPath, LVersion, LShownNote]));
  HydrateOpenDoc(FNav, LPath);
  // A UNIT WITH NO FILE YET - created in the IDE and never saved - outside the
  // closure, or with no closure to ask: armed for a take-in whatever happens
  // below, so that a program naming it is re-run as soon as there is a
  // project to run it on (see TakeInNamer).
  LNoFile := LDiffers and not FileExists(LPath) and
    ((FProject = nil) or (FProject.ModelIdOf(LPath) < 0));
  if LNoFile then
    FTakeIn.Add(LPath);
  // Schedule when this buffer is unsaved work the analysis has not seen, OR
  // when nothing has been analyzed yet - the first file opened is what starts
  // the initial build, and without this clause a workspace whose files all
  // match their disk contents would sit unanalyzed until the first request.
  if (LDiffers and AffectsAnalysis(LPath)) or
     ((FProject = nil) and (FSession = nil)) then
  begin
    // No priority file for a unit with no file: a priority is loaded whether
    // or not anything uses it, and a unit nothing names must stay outside.
    if LNoFile then
      ScheduleAnalysis('')
    else
      ScheduleAnalysis(LPath);
  end
  else if not LDiffers and DiskNewerThanAnalysis(LPath) and
     AffectsAnalysis(LPath) then
  begin
    // Same as the disk, but not as the disk the analysis READ: the file was
    // rewritten after it (see FDiskReadAt). A full rebuild, not the module
    // fast path - TryStartModuleAnalysis declines while FDiskMoved is set -
    // and the parse donor keeps it to this one unit's parse.
    Log('  changed on disk since the analysis read it - rebuild scheduled');
    FDiskMoved := True;
    ScheduleAnalysis(LPath);
  end
  else if LNoFile then
  begin
    // THE IDE'S NEW UNIT. PasTree resolves an `in 'path'` to an editor buffer
    // (0.52.2) and the module path takes a new import in (0.53.0). When the
    // program's uses edit arrives beside this didOpen (a program with no
    // editor view), its incremental run brings the unit in and there is
    // nothing to do here. When it arrived FIRST (the program open in a tab:
    // its edit rides the idle tick, this didOpen the first-sight sync - see
    // TakeInNamer), the program was analyzed with the unit missing and is
    // re-run now, incrementally, to take it in. Until 0.55.0 this forced a
    // FULL rebuild either way, 4-5 s on a large project.
    if TakeInNamer(LNamer) then
    begin
      Log(Format('  not on disk yet (a new unit), and %s names it - ' +
        'reanalyzed to take it in', [ExtractFileName(LNamer)]));
      ScheduleAnalysis('');
    end
    else
      Log('  not on disk yet (a new unit), and nothing names it yet - kept ' +
        'as an overlay until a program does');
  end
  else
  begin
    if LDiffers then
      Log('  outside this closure: kept as an overlay, no rebuild');
    // No rebuild is coming for this document, so nothing else will publish
    // for it: the finished analysis already covers its text - hand over what
    // it found now. See PublishDiagnosticsFor. With no project yet, the
    // running session publishes to every open document when it lands.
    if (FProject <> nil) and FDocs.TryGet(LPath, LDoc) then
      PublishDiagnosticsFor(LDoc);
  end;
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
    range, and they must be applied IN ORDER - every range after the first
    refers to the text as the previous ones left it. A change with no range is
    a full replacement and is honored too: the spec allows a client to mix
    them, and a resync arrives that way.

    Correctness here is invisible until it is wrong: a mis-applied patch does
    not fail, it silently leaves the server analyzing text the editor never
    had, and LSP gives a server no way to ask for a resend. Hence the clamping
    in PositionToIndex rather than exceptions, and the log line below carrying
    the resulting length - the cheapest thing that makes a divergence
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
    if AffectsAnalysis(LPath) then
      ScheduleAnalysis(LPath)
    else
      Log('  outside this closure: kept as an overlay, no rebuild');
end;

procedure TLspServer.HandleDidClose(AParams: TJSONValue);
var
  LPath: string;
  LDoc: TLspDocument;
  LDiffered: Boolean;
  LIdx: Integer;
begin
  LPath := DocPathOf(AParams);
  if LPath = '' then
    Exit;
  LDiffered := FDocs.TryGet(LPath, LDoc) and LDoc.Differs and
    AffectsAnalysis(LPath);
  FDocs.Close(LPath);
  if FTakeIn.Find(LPath, LIdx) then
    FTakeIn.Delete(LIdx);
  PublishEmptyDiagnostics(LPath);
  Log('textDocument/didClose ' + LPath);
  // The disk file is the truth again - a rebuild is due only if the overlay
  // ever DIFFERED from it (analysis results built from unsaved text now
  // describe content that no longer exists anywhere).
  if LDiffered then
    ScheduleAnalysis('');
end;

{ ADeclarationOnly skips the redirect to a routine's implementation below.
  textDocument/definition wants the body (F12 behavior); pastree/declarationAt
  wants the declaration site itself - Find References labels a row
  "declaration", and asking definition for it put that row's target on the
  body of a routine (2026-09-15). Everything before the redirect is shared. }
function TLspServer.HandleDefinition(const AMsg: TLspIncoming;
  ADeclarationOnly: Boolean): string;
var
  LPath, LDefName: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LRawTok: Integer;
  LIdent: TPasNavIdent;
  LTarget, LImplTarget, LDeclTarget: TPasNavTarget;
  LResolved, LOwnHeader: Boolean;
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
  // A conditional symbol FIRST: the name in `{$IFDEF X}` sits inside what
  // IdentAt sees as a comment, so it is a miss there, while DefineAt reads
  // the preprocessor's own record of the directive (PasTree 0.27.0). The
  // target is the nearest preceding active `$DEFINE X` in this model - a
  // project or platform define has no source site, which the log says.
  if FNav.DefineAt(LMid, LPasLine, LPasCol, LDefName, LRawTok) then
  begin
    if FNav.GotoDefine(LMid, LPasLine, LPasCol, LTarget) then
    begin
      Log(Format(AMsg.Method + ': %s define ''%s'' -> %s',
        [PosTag(LPath, LPasLine, LPasCol), LDefName,
         PosTag(LTarget.FilePath, LTarget.Line, LTarget.Col)]));
      Exit(BuildResponse(AMsg.IdJson,
        LocationWithTypes(LTarget.FilePath, LTarget.Line, LTarget.Col,
          Length(LTarget.Name))));
    end;
    if FNav.IsProjectDefined(LDefName) then
      Log(Format(AMsg.Method + ': %s define ''%s'' comes from the project '
        + 'or platform - no source site to go to',
        [PosTag(LPath, LPasLine, LPasCol), LDefName]))
    else
      Log(Format(AMsg.Method + ': %s define ''%s'' has no preceding active '
        + '$DEFINE in this unit', [PosTag(LPath, LPasLine, LPasCol), LDefName]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  // Failures answer null to the client (per protocol) but SAY WHY in the
  // log - "F12 did nothing" is otherwise undebuggable from the outside.
  if FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
    LResolved := FNav.ResolveDecl(LMid, LIdent.Node, LTarget)
  else
  begin
    // Not an identifier - but the `inherited` KEYWORD isn't one either, and
    // Delphi's own Ctrl+Click resolves it (bare `inherited;` to the ancestor
    // method of the same name; on a named call, same as clicking the name).
    // Anything else that is not an identifier is a genuine miss.
    if not FNav.GotoBareInherited(LMid, LPasLine, LPasCol, LTarget) then
    begin
      Log(Format(AMsg.Method + ': %s no identifier at that position',
        [PosTag(LPath, LPasLine, LPasCol)]));
      Exit(BuildResponse(AMsg.IdJson, 'null'));
    end;
    LIdent.Name := 'inherited';
    LResolved := True;
  end;
  // The routine's OWN name in its `procedure TFoo.Bar` implementation header
  // goes the other way - to the declaration - as the IDE does: redirecting
  // into the body would put the caret right back where it already is. A
  // qualified implementation's name has no binding of its own (the resolver
  // links the class member, not the header that completes it), so this is
  // the toggle's declaration lookup for the cursor position - which answers
  // for ANY position inside an implementation, hence the name check: only
  // the header's own name (or a recursive self-call) spells the routine.
  LOwnHeader := FNav.GotoDeclaration(LMid, LPasLine, LPasCol, LDeclTarget) and
    SameText(LDeclTarget.Name, LIdent.Name) and
    (not LResolved or ((LDeclTarget.UnitId = LTarget.UnitId) and
      (LDeclTarget.Line = LTarget.Line) and (LDeclTarget.Col = LTarget.Col)));
  if LOwnHeader then
  begin
    LTarget := LDeclTarget;
    LResolved := True;
  end;
  if not LResolved then
  begin
    Log(Format(AMsg.Method + ': %s ''%s'' did not resolve to a source'
      + ' declaration (unresolved name, or a builtin with none)',
      [PosTag(LPath, LPasLine, LPasCol), LIdent.Name]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  // A routine name resolves to its FORWARD declaration (ResolveDecl always
  // answers DeclNode, set once at first declaration - see PasTree.Sema.Nav's
  // header). For F12/Ctrl+Click a reader wants the BODY, same as clicking a
  // non-Pascal symbol lands on where it is defined - so when the resolved
  // target is itself a routine header with a separate implementation,
  // redirect through the same decl<->impl toggle HandleToggle uses below.
  // Silent fallback to the header on a miss (plain routine with only one
  // half, or an unresolved position): that is not an error, just nothing to
  // redirect to. Not from the implementation's own header (LOwnHeader
  // above): there the declaration IS the answer.
  // ONLY when the target is in the model's MAIN file: GotoImplementation
  // takes a line/col and reads it in the main file's token stream (VisAt),
  // so a declaration inside an $I include - `uaviOptionValues.inc:1012`,
  // a constant - was read as line 1012 of the HOST unit, which happened to
  // be a method header, and Ctrl+Click landed in that method's body
  // (2026-09-22). A routine declared in an include and implemented in the
  // host loses the redirect and lands on its header, which is still right.
  if not ADeclarationOnly and not LOwnHeader and
     SameFileName(LTarget.FilePath, FProject.ModelFile(LTarget.UnitId)) and
     FNav.GotoImplementation(LTarget.UnitId, LTarget.Line, LTarget.Col,
       LImplTarget) then
    LTarget := LImplTarget;
  Log(Format(AMsg.Method + ': %s ''%s'' -> %s',
    [PosTag(LPath, LPasLine, LPasCol), LIdent.Name,
     PosTag(LTarget.FilePath, LTarget.Line, LTarget.Col)]));
  Result := BuildResponse(AMsg.IdJson,
    LocationWithTypes(LTarget.FilePath, LTarget.Line, LTarget.Col,
      Length(LTarget.Name)));
end;

{ textDocument/completion - the answers come from PasLsp.Completion, which
  runs PasTree's completion engine over a fresh single-file parse of the live
  overlay text, BRIDGED to the last completed analysis when this file is in
  its closure (see that unit's header for the pipeline).

  THE ONE DELIBERATE DIFFERENCE from every other request handler: NO
  WaitAnalyzed. That helper flushes the pending rebuild and blocks until the
  whole closure is analyzed - right for a click on stable code, wrong per
  keystroke (a full rebuild is ~15 s on the reference project). Completion
  answers from what exists RIGHT NOW: the live overlay text always (that is
  what the user is typing into), bridged to whatever analysis snapshot is
  ready - or standalone (locals, own-unit names, keywords) when none is. It
  does not schedule a rebuild either; didChange already did. }
// The item's data member (',"data":{...}') - our own side channel: the
// routine head word for the RAD viewer's class column, hasParams for its
// auto-parenthesis. '' when there is nothing to carry.
{ textDocument/signatureHelp - same rules as completion: never WaitAnalyzed,
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

{ workspace/symbol - project-wide symbol search by name, the Ctrl+T /
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
    // otherwise standalone - a half-bridge (project without a model id)
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

{ AObjectJson with a `typeSpans` member added - the line's type names as
  LineTypeSpansJson spells them - so a result row can paint types like the
  editor does. A member the protocol does not define, on objects the
  protocol does (a Location): every other client ignores what it did not
  ask for, and ours reads it when present. }
function WithTypeSpans(const AObjectJson, ATypeSpans: string): string;
begin
  Result := Copy(AObjectJson, 1, Length(AObjectJson) - 1) +
    ',"typeSpans":' + ATypeSpans + '}';
end;

{ A typeSpans array (`[5,7,15,7]`, 1-based column/length pairs) re-based onto
  the same line with its first AShift characters cut off - the hover's `code`
  is the declaration line without its indentation. A pair that would start
  before the cut is dropped; it cannot happen for a type name, which never
  sits in leading whitespace, but a wrong span is worse than none. }
function ShiftSpansJson(const ASpansJson: string; AShift: Integer): string;
var
  LParts: TArray<string>;
  LIdx, LCol: Integer;
  LInner: string;
begin
  LInner := Trim(ASpansJson);
  if (Length(LInner) < 2) or (AShift = 0) then
    Exit(ASpansJson);
  LInner := Copy(LInner, 2, Length(LInner) - 2);
  if Trim(LInner) = '' then
    Exit('[]');
  LParts := LInner.Split([',']);
  Result := '';
  LIdx := 0;
  while LIdx + 1 < Length(LParts) do
  begin
    LCol := StrToIntDef(Trim(LParts[LIdx]), 0) - AShift;
    if LCol >= 1 then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + IntToStr(LCol) + ',' + Trim(LParts[LIdx + 1]);
    end;
    Inc(LIdx, 2);
  end;
  Result := '[' + Result + ']';
end;

{ The rows of FindDefineReferences as plain reference hits. Kind and Active
  are dropped: an LSP Location carries neither, and a `$DEFINE` site is a
  reference like any other (PasTree's own rule - the name can have several
  or none, so there is no one "declaration" to set apart). }
function DefineHitsToRefs(const AHits: TArray<TPasDefineHit>): TArray<TPasRefHit>;
var
  LIdx: Integer;
begin
  SetLength(Result, Length(AHits));
  for LIdx := 0 to High(AHits) do
    Result[LIdx] := AHits[LIdx].Hit;
end;

{ What a FORM-FILE site is, as the plan and the references rows spell it -
  '' for a Pascal source site. A host holding a live form designer applies a
  form edit through the designer by this word (component: rename the
  component; handler: rename the method; componentRef/class: follow the
  component or class), which is why it rides with the edit at all. }
function FormKindWord(AKind: TPasFormSiteKind): string;
begin
  case AKind of
    fskComponent: Result := 'component';
    fskClass: Result := 'class';
    fskHandler: Result := 'handler';
    fskComponentRef: Result := 'componentRef';
    fskCaption: Result := 'caption';
    // A line setting a published property (PasTree 0.68.0/0.70.0) - a
    // reference-search row only, a rename of such a property is refused.
    // Before this word it went out as '', which a client reads as a Pascal
    // source row.
    fskProperty: Result := 'property';
  else
    Result := '';
  end;
end;

{ How a form-file site reaches its symbol (PasTree's TPasFormSiteVia): a
  designer propagates a rename differently along each path. }
function FormViaWord(AVia: TPasFormSiteVia): string;
begin
  case AVia of
    fsvInline: Result := 'inline';
    fsvModule: Result := 'module';
  else
    Result := 'own';
  end;
end;

{ The members a form-file row adds to its object - none for a Pascal row, so
  every existing reader sees exactly what it saw before. }
function FormMembersJson(AKind: TPasFormSiteKind; const AObject: string;
  AVia: TPasFormSiteVia; const AProp: string): string;
begin
  if AKind = fskNone then
    Exit('');
  Result := Format(',"formKind":%s,"formObject":%s,"formVia":%s,' +
    '"formProp":%s', [JsonQuote(FormKindWord(AKind)), JsonQuote(AObject),
    JsonQuote(FormViaWord(AVia)), JsonQuote(AProp)]);
end;

// A TPasFormRole as JSON - see TLspRenamePlanned.
function FormRoleJson(const ARole: TPasFormRole): string;
begin
  Result := Format('{"kind":%s,"ownerClass":%s,"formFile":%s}',
    [JsonQuote(FormKindWord(ARole.Kind)), JsonQuote(ARole.OwnerClass),
     JsonQuote(ARole.FormFile)]);
end;

{ textDocument/references - the three-identity model, straight from the
  navigator (see PasTree.Sema.Nav's own comments for why three): a SYMBOL
  (unit, symbol id - the normal case), a UNIT (header/uses click: each
  referrer holds its own skUnitRef symbol, so the target model id is the
  only project-wide identity), or a compiler-seeded BUILTIN (no declaration
  anywhere; the name is the identity). Tried in that order - SymbolAt
  declines the latter two by design. FindReferences never includes the
  declaration site, so context.includeDeclaration is honored by prepending
  the separate DeclHit/UnitDeclHit answer (builtins have no declaration to
  include).

  context.includeImplementationHeaders is OURS, not the protocol's (a client
  that does not know it never sends it, and gets the standard answer): the
  implementation headers that spell a symbol's name without using it - a
  type's name in every `procedure TFoo.Bar;`, a routine's own implementation
  header. Off by default because on a form's class it is one row per event
  handler; rename always takes them (PlanRename), whatever this says.

  FORM FILES are always searched for a symbol (FindFormSites): a component's
  `object X: TC`, a handler's `OnClick = X`, a component reference, a class
  in an object header. They are USES in every sense that matters - a handler
  with no form row looks unused, and the form is where it is used - so they
  are not behind an option. Each such row carries `formKind` and
  `formObject` (the component it is on) besides the Location, for a host
  that navigates to the component rather than to a line of text. }
function TLspServer.HandleReferences(const AMsg: TLspIncoming): string;
var
  LPath, LName: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSym, LRawTok: Integer;
  LInclDecl, LImplHeaders: Boolean;
  LHits: TArray<TPasRefHit>;
  LForms: TArray<TPasFormSite>;
  LDecl: TPasRefHit;
  LSB: TStringBuilder;
  LIdx: Integer;
  LKind, LRow: string;
begin
  LPath := DocPathOf(AMsg.Params);
  Log('textDocument/references: ' + LPath);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'references: textDocument.uri and position required'));
  LInclDecl := AMsg.Params.GetValue<Boolean>('context.includeDeclaration',
    False);
  LImplHeaders := AMsg.Params.GetValue<Boolean>(
    'context.includeImplementationHeaders', False);

  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);

  LHits := nil;
  LForms := nil;
  // UnitAt BEFORE SymbolAt (the IDE plugin now uses the same order):
  // UnitAt only ever matches a `uses` item or the module's own header
  // name - positions where the unit identity IS the right answer - while
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
    if LImplHeaders then
      LKind := 'symbol, implementation headers';
    LHits := FNav.FindReferences(LTMid, LSym, LImplHeaders);
    if LInclDecl and FNav.DeclHit(LTMid, LSym, LDecl) then
      LHits := [LDecl] + LHits;
    LForms := FNav.FindFormSites(LTMid, LSym);
  end
  else if FNav.BuiltinNameAt(LMid, LPasLine, LPasCol, LName) then
  begin
    LKind := 'builtin';
    LHits := FNav.FindBuiltinReferences(LName);
  end
  else if FNav.DefineAt(LMid, LPasLine, LPasCol, LName, LRawTok) then
  begin
    // The FOURTH identity (PasTree 0.27.0): the name in a $DEFINE / $UNDEF /
    // $IFDEF / $IFNDEF / Defined(). The $DEFINE sites are among the hits -
    // there is no separate declaration to include.
    LKind := 'define';
    LHits := DefineHitsToRefs(FNav.FindDefineReferences(LName));
  end
  else
  begin
    Log(Format('textDocument/references: %s -> no identity',
      [PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;

  Log(Format(AMsg.Method + '(%s): %s ''%s'' -> %d hits%s',
    [LKind, PosTag(LPath, LPasLine, LPasCol), LName, Length(LHits),
     IfThen(Length(LForms) > 0,
       Format(' + %d in form files', [Length(LForms)]), '')]));
  LSB := TStringBuilder.Create;
  try
    LSB.Append('[');
    for LIdx := 0 to High(LHits) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(WithTypeSpans(HitLocationJson(LHits[LIdx]),
        LineTypeSpansJson(LHits[LIdx].FilePath, LHits[LIdx].Line)));
    end;
    for LIdx := 0 to High(LForms) do
    begin
      if (LIdx > 0) or (Length(LHits) > 0) then
        LSB.Append(',');
      LRow := WithTypeSpans(LocationJson(LForms[LIdx].FilePath,
        LForms[LIdx].Line, LForms[LIdx].Col, LForms[LIdx].Len), '[]');
      LSB.Append(Copy(LRow, 1, Length(LRow) - 1))
        .Append(FormMembersJson(LForms[LIdx].Kind, LForms[LIdx].ObjectName,
          LForms[LIdx].Via, LForms[LIdx].PropName))
        .Append('}');
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

{ The text a planned edit writes - its own, never the requested name. Two
  plans write different texts at different sites: a UNIT rename (the full
  dotted name where it was written in full, the bare leaf where a namespace
  prefix resolved it) and a COMPONENT rename, which carries the handlers
  named after the component along under their own new names (Button1Click ->
  OKButtonClick - PasTree's TPasCarriedRename). Since PasTree 0.59.0 the edit
  carries it (NewText); before that it was read back out of the preview. }
function EditNewText(const AEdit: TPasRenameEdit): string;
begin
  Result := AEdit.NewText;
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
  LMid, LTMid, LSym, LRawTok: Integer;
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
    { UnitAt's own answer, not a re-derivation from the header text: since
      PasTree 0.13.2 it reports the TARGET unit's full dotted name (before
      that, `unit Foo.Bar` identified itself as "." - the dotted header is an
      nkMember chain whose first token is the dot, and that reached a user as
      the pre-filled text of this very dialog). Deriving it here as well
      would be a second answer able to disagree with the library's. }
    APlan.OldName := LOther;
    // The header hit is still needed for one thing the name cannot give: the
    // FILE the unit lives in, which is what gets renamed alongside it.
    if FNav.UnitDeclHit(LTMid, LDecl) then
      APlan.UnitPath := LDecl.FilePath;
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
    // The form file follows the unit's file (see TLspRenamePlanned).
    APlan.FormPath := PasDfmFileOfUnit(APlan.UnitPath);
    if (APlan.FormPath <> '') and (APlan.NewFilePath <> '') then
      APlan.NewFormPath := ChangeFileExt(APlan.NewFilePath,
        ExtractFileExt(APlan.FormPath));
    Exit;
  end;
  if not FNav.SymbolAt(LMid, APasLine, APasCol, LTMid, LSym, APlan.OldName)
  then
  begin
    if FNav.BuiltinNameAt(LMid, APasLine, APasCol, LOther) then
      AError := Format('''%s'' is a compiler builtin - it has no ' +
        'declaration to rename.', [LOther])
    else if FNav.DefineAt(LMid, APasLine, APasCol, LOther, LRawTok) then
      // Refused like a builtin, for PasTree's own reason: the .dproj and the
      // command line own part of a conditional symbol's identity, so a
      // source-only rename would silently split it.
      AError := Format('''%s'' is a conditional symbol - part of its ' +
        'identity lives in the project options, so it cannot be renamed ' +
        'from source.', [LOther])
    else
      AError := 'There is nothing renameable at that position.';
    Exit;
  end;
  if ANewName = '' then
    Exit(True);
  Result := FNav.PlanRename(LTMid, LSym, ANewName, {out} APlan.Edits,
    {out} APlan.Carried, {out} AError);
  if not Result then
  begin
    APlan.Edits := nil;
    APlan.Carried := nil;
    Exit;
  end;
  APlan.FormRole := FNav.FormRoleOf(LTMid, LSym);
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

  A `uses` item's `in ''<file>''` path is one more edit of the plan, and a
  path PasTree cannot read as the unit's file refuses the plan whole (since
  PasTree 0.87.0): a path left pointing at the old file name is a project
  that does not compile, so half of one is worse than none.

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
      if LPlan.NewFormPath <> '' then
        LSB.AppendFormat(',{"kind":"rename","oldUri":%s,"newUri":%s}',
          [JsonQuote(PathToUri(LPlan.FormPath)),
           JsonQuote(PathToUri(LPlan.NewFormPath))]);
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
  name the file rename the host must ALSO perform; a `uses ... in '...'`
  path is one more edit of the plan (PasTree's, since 0.87.0). Announcing
  none of that and leaving it out would be the worst outcome: text edits
  that do not compile.

  For a symbol, `formRole` says where it lives in the project's form files
  (`kind` component/handler/class or '', `ownerClass`, and `formFile`, the
  form whose root is that class), and `carried` lists the handlers a
  component's rename carries along (`oldName`, `newName`, `role`) - a form-
  file edit then also says `formVia` (own/inline/module) and `formProp`.
  What a host needs whose forms a live designer holds: the designer must
  make those renames itself, and propagates them differently by path. }
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
  Log(Format('renamePlan: %s %s ''%s'' -> ''%s'': %d edits%s%s%s',
    [PosTag(LPath, LPasLine, LPasCol), RenameKindWord(LPlan.IsUnit),
     LPlan.OldName, LNewName, Length(LPlan.Edits),
     IfThen(LPlan.IsUnit, ' + file -> ' + LPlan.RequiredFileName, ''),
     IfThen(LPlan.FormRole.Kind <> fskNone, Format(' (a %s of %s, form %s)',
       [FormKindWord(LPlan.FormRole.Kind), LPlan.FormRole.OwnerClass,
        IfThen(LPlan.FormRole.FormFile = '', '-',
          ExtractFileName(LPlan.FormRole.FormFile))]), ''),
     IfThen(Length(LPlan.Carried) > 0, Format(' + %d carried handler(s)',
       [Length(LPlan.Carried)]), '')]));
  LSB := TStringBuilder.Create;
  try
    LSB.AppendFormat('{"kind":%s,"oldName":%s,"newName":%s,' +
      '"requiredFileName":%s,"filePath":%s,"newFilePath":%s,' +
      '"formFilePath":%s,"newFormFilePath":%s,"edits":[',
      [JsonQuote(RenameKindWord(LPlan.IsUnit)), JsonQuote(LPlan.OldName),
       JsonQuote(LNewName), JsonQuote(LPlan.RequiredFileName),
       JsonQuote(LPlan.UnitPath), JsonQuote(LPlan.NewFilePath),
       JsonQuote(LPlan.FormPath), JsonQuote(LPlan.NewFormPath)]);
    for LIdx := 0 to High(LPlan.Edits) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.AppendFormat('{"uri":%s,"filePath":%s,"line":%d,"col":%d,' +
        '"len":%d,"oldText":%s,"newText":%s,"isDecl":%s,"snippet":%s,' +
        '"hiFrom":%d,"hiTo":%d,"typeSpans":%s%s}',
        [JsonQuote(PathToUri(LPlan.Edits[LIdx].FilePath)),
         JsonQuote(LPlan.Edits[LIdx].FilePath),
         LPlan.Edits[LIdx].Line, LPlan.Edits[LIdx].Col,
         LPlan.Edits[LIdx].Len,
         JsonQuote(LPlan.Edits[LIdx].OldText),
         JsonQuote(EditNewText(LPlan.Edits[LIdx])),
         LowerCase(BoolToStr(LPlan.Edits[LIdx].IsDecl, True)),
         JsonQuote(LPlan.Edits[LIdx].Snippet),
         LPlan.Edits[LIdx].HiFrom, LPlan.Edits[LIdx].HiTo,
         LineTypeSpansJson(LPlan.Edits[LIdx].FilePath,
           LPlan.Edits[LIdx].Line),
         FormMembersJson(LPlan.Edits[LIdx].FormKind,
           LPlan.Edits[LIdx].FormObject, LPlan.Edits[LIdx].FormVia,
           LPlan.Edits[LIdx].FormProp)]);
    end;
    LSB.Append('],"formRole":').Append(FormRoleJson(LPlan.FormRole))
      .Append(',"carried":[');
    for LIdx := 0 to High(LPlan.Carried) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.AppendFormat('{"oldName":%s,"newName":%s,"role":%s}',
        [JsonQuote(LPlan.Carried[LIdx].OldName),
         JsonQuote(LPlan.Carried[LIdx].NewName),
         FormRoleJson(LPlan.Carried[LIdx].Role)]);
    end;
    LSB.Append(']}');
    Result := BuildResponse(AMsg.IdJson, LSB.ToString);
  finally
    LSB.Free;
  end;
end;

{ ------------------------------------------------------------------------- }
{ The Find All family - pastree/find*: OURS, not LSP                          }
{ ------------------------------------------------------------------------- }

{ One row of any Find All answer (overrides, implementations, descendants,
  assignments, creations, destructions). A Location plus what a Location
  cannot carry and the results panel shows: the row's KIND (which side of a
  chain it is, or `declaration` against the search's own word), the type
  declaring it, and - for an inherited implementor - the class that listed
  the interface. For a descendant the row also carries `parentTypeName` and
  `depth` (heritage links from the root; 0 on the root), which is the whole
  tree: PasTree answers a flat array in breadth-first hierarchy order and a
  host that nests each row under the one named by its parent gets the tree
  without a second walk. Empty / 0 for every other kind. `snippet`/`hiFrom`/
  `hiTo` ride along as in renamePlan, so a host that has no text for a file
  it never opened can still paint the line. `filePath` is the same path the
  uri encodes, spelled for a host that does not want to decode. }
function HierarchyRowJson(const AHit: TPasRefHit; const AKind, ATypeName,
  AViaTypeName: string; const AParentTypeName: string = '';
  ADepth: Integer = 0): string;
begin
  Result := Format('{"uri":%s,"filePath":%s,"line":%d,"col":%d,"len":%d,' +
    '"kind":%s,"typeName":%s,"viaTypeName":%s,"parentTypeName":%s,' +
    '"depth":%d,"snippet":%s,"hiFrom":%d,"hiTo":%d}',
    [JsonQuote(PathToUri(AHit.FilePath)), JsonQuote(AHit.FilePath),
     AHit.Line, AHit.Col, AHit.HiTo - AHit.HiFrom, JsonQuote(AKind),
     JsonQuote(ATypeName), JsonQuote(AViaTypeName), JsonQuote(AParentTypeName),
     ADepth, JsonQuote(AHit.Snippet), AHit.HiFrom, AHit.HiTo]);
end;

{ The envelope every Find All method answers with: an object holding `name`
  and `rows`, the rows an array of HierarchyRowJson objects. }
function HierarchyAnswer(const AName: string;
  const ARows: TArray<string>): string;
var
  LSB: TStringBuilder;
  LIdx: Integer;
begin
  LSB := TStringBuilder.Create;
  try
    LSB.AppendFormat('{"name":%s,"rows":[', [JsonQuote(AName)]);
    for LIdx := 0 to High(ARows) do
    begin
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(ARows[LIdx]);
    end;
    LSB.Append(']}');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

{ The steps every positional Find All request takes before its own gate:
  parameter check, the wait for the analysis, the navigator, the model of the
  file, the position in PasTree's numbering. True means "go on"; False means
  AReply is the response to send - an error, or `null` for a file the closure
  does not hold (the same contract the individual handlers had when each
  spelled these lines out, kept in one place since the family grew to six). }
function TLspServer.FindAllPreamble(const AMsg: TLspIncoming;
  const ATag: string; out APath: string; out AMid, APasLine, APasCol: Integer;
  out AReply: string): Boolean;
var
  LLine, LChar: Integer;
begin
  Result := False;
  AMid := -1;
  APasLine := 0;
  APasCol := 0;
  APath := DocPathOf(AMsg.Params);
  if (APath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
  begin
    AReply := BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      ATag + ': textDocument.uri and position required');
    Exit;
  end;
  if not WaitAnalyzed(APath, AMsg.IdJson) then
  begin
    AReply := BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED,
      'request cancelled');
    Exit;
  end;
  if FNav = nil then
  begin
    AReply := BuildResponse(AMsg.IdJson, 'null');
    Exit;
  end;
  AMid := FNav.ModelIdOf(APath);
  if AMid < 0 then
  begin
    AReply := BuildResponse(AMsg.IdJson, 'null');
    Exit;
  end;
  LspToPasTree(LLine, LChar, APasLine, APasCol);
  Result := True;
end;

{ pastree/findOverrides - OURS, not LSP. The VMT chain of the class method at
  the position: the declaration that introduced its slot plus every override,
  reintroduce and message handler below it, across the whole closure
  (TPasNavigator.MethodAt + FindOverrides - PasTree's docs/editor-features.md
  section 4 owns what is and is not a row). NOT a reference search and not
  the decl<->impl toggle: no call site is a row, and textDocument/
  implementation is already taken by the toggle, which is why this is a
  custom method rather than an overload of a standard one.

  A CLASS PROPERTY is the same request, and answers a different chain: a bare
  redeclaration (`property Items;`, republishing an inherited property with no
  type written) is the SAME property, so the rows are its declarations, kind
  `redeclared` below the one that writes the type. There is no VMT slot
  involved - PasTree owns that distinction and the rule that a redeclaration
  WITH a type hides rather than continues; see TPasOverrideKind. The client
  needs no branch: MethodAt accepts both identities and the rows carry their
  own kind word.

  `null` when the position is neither - a plain routine, a record or interface
  method, a field - so the client can say "not a method or property" rather
  than "nothing overrides this". The two are different answers: a method
  nothing overrides still comes back with its own single `root` row. }
function TLspServer.HandleFindOverrides(const AMsg: TLspIncoming): string;
const
  { One word per TPasOverrideKind, in the enum's own order. Typed as
    array[TPasOverrideKind] ON PURPOSE rather than as a loose array of string:
    a value added to PasTree's enum then fails THIS declaration to compile
    (E2072, the element count) instead of running with an out-of-range read.
    pokRedeclared arrived in PasTree 0.21.0 and is exactly what that caught. }
  cKindWord: array[TPasOverrideKind] of string =
    ('root', 'override', 'message', 'reintroduce', 'redeclared');
var
  LPath, LName: string;
  LPasLine, LPasCol, LMid, LTMid, LSym, LIdx: Integer;
  LRows: TArray<TPasOverrideHit>;
  LJson: TArray<string>;
begin
  if not FindAllPreamble(AMsg, 'findOverrides', LPath, LMid, LPasLine,
    LPasCol, Result) then
    Exit;
  if not FNav.MethodAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) then
  begin
    Log(Format('findOverrides: %s -> not a class method or property',
      [PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LRows := FNav.FindOverrides(LTMid, LSym);
  Log(Format('findOverrides: %s ''%s'' -> %d rows',
    [PosTag(LPath, LPasLine, LPasCol), LName, Length(LRows)]));
  SetLength(LJson, Length(LRows));
  for LIdx := 0 to High(LRows) do
    LJson[LIdx] := WithTypeSpans(HierarchyRowJson(LRows[LIdx].Hit,
      cKindWord[LRows[LIdx].Kind], LRows[LIdx].TypeName, ''),
      LineTypeSpansJson(LRows[LIdx].Hit.FilePath, LRows[LIdx].Hit.Line));
  Result := BuildResponse(AMsg.IdJson, HierarchyAnswer(LName, LJson));
end;

{ pastree/findImplementations - OURS, not LSP. The interface-side twin of
  findOverrides, and a separate method for a separate identity (PasTree's
  InterfaceMethodAt against MethodAt). Two entry points, one command, as
  PasTree's own demo has it since 0.22.0:

    - an interface METHOD: the method of every class that lists the
      interface, with an implementor that inherits the method reported on
      the ancestor's declaration and `viaTypeName` naming the class that
      listed the interface (FindImplementations);
    - the interface TYPE name itself: one row per class that lists the
      interface (FindInterfaceImplementors), the interface's own declaration
      as the root.

  Both take ONE hop, to the classes that spell this interface's name: a
  class listing a DESCENDANT interface is not a row (PasTree 0.25.0 - up to
  0.24.x it was, and on a base interface the answer had no shape a list
  could show). The interfaces below one are findDescendants' axis, and the
  child's implementors are this request on the child.

  Section 5 of PasTree's docs/editor-features.md owns the rows and the
  documented gaps (method resolution clauses, `implements` delegation, type
  aliases). The method is tried first: on a method's name both cannot be true,
  and on the type's name only the second is.

  `null` when the position is neither - same contract as findOverrides, same
  reason. }
function TLspServer.HandleFindImplementations(const AMsg: TLspIncoming): string;
const
  cKindWord: array[TPasImplKind] of string =
    ('root', 'implementor', 'inherited');
var
  LPath, LName, LWhat: string;
  LPasLine, LPasCol, LMid, LTMid, LSym, LIdx: Integer;
  LRows: TArray<TPasImplHit>;
  LJson: TArray<string>;
begin
  if not FindAllPreamble(AMsg, 'findImplementations', LPath, LMid, LPasLine,
    LPasCol, Result) then
    Exit;
  if FNav.InterfaceMethodAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) then
  begin
    LRows := FNav.FindImplementations(LTMid, LSym);
    LWhat := 'interface method';
  end
  else if FNav.InterfaceAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) then
  begin
    LRows := FNav.FindInterfaceImplementors(LTMid, LSym);
    LWhat := 'interface';
  end
  else
  begin
    Log(Format('findImplementations: %s -> not an interface or interface method',
      [PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format('findImplementations: %s %s ''%s'' -> %d rows',
    [PosTag(LPath, LPasLine, LPasCol), LWhat, LName, Length(LRows)]));
  SetLength(LJson, Length(LRows));
  for LIdx := 0 to High(LRows) do
    LJson[LIdx] := WithTypeSpans(HierarchyRowJson(LRows[LIdx].Hit,
      cKindWord[LRows[LIdx].Kind], LRows[LIdx].TypeName,
      LRows[LIdx].ViaTypeName),
      LineTypeSpansJson(LRows[LIdx].Hit.FilePath, LRows[LIdx].Hit.Line));
  Result := BuildResponse(AMsg.IdJson, HierarchyAnswer(LName, LJson));
end;

{ pastree/findDescendants - OURS, not LSP. Every class below the class (or
  interface below the interface) at the position, transitively, across the
  closure (TPasNavigator.TypeAt + FindDescendants; section 6 of PasTree's
  docs/editor-features.md). Rows are TYPE declarations, never members, and
  come in breadth-first hierarchy order with `depth` and `parentTypeName` on
  each - the tree, flattened; the client rebuilds it by nesting each row under
  the row of depth-1 named by its parent. One axis only, by PasTree's rule:
  for an interface the rows are interfaces extending it, not the classes
  implementing it - that is findImplementations on the same name.

  `null` when the position is not a class, `object` or interface type name -
  a record, a helper, an alias, a variable. A type nothing descends from
  answers its own single `root` row. Always the WHOLE tree: 0.37.7-0.37.9
  briefly took an `includeIndirect` flag (PasTree 0.24.x's Ctrl modifier)
  and the direct answer was a flat list in a panel built to show a tree. }
function TLspServer.HandleFindDescendants(const AMsg: TLspIncoming): string;
const
  cKindWord: array[TPasDescendantKind] of string = ('root', 'descendant');
var
  LPath, LName: string;
  LPasLine, LPasCol, LMid, LTMid, LSym, LIdx: Integer;
  LRows: TArray<TPasDescendantHit>;
  LJson: TArray<string>;
begin
  if not FindAllPreamble(AMsg, 'findDescendants', LPath, LMid, LPasLine,
    LPasCol, Result) then
    Exit;
  if not FNav.TypeAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) then
  begin
    Log(Format('findDescendants: %s -> not a class or interface type',
      [PosTag(LPath, LPasLine, LPasCol)]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LRows := FNav.FindDescendants(LTMid, LSym);
  Log(Format('findDescendants: %s ''%s'' -> %d rows',
    [PosTag(LPath, LPasLine, LPasCol), LName, Length(LRows)]));
  SetLength(LJson, Length(LRows));
  for LIdx := 0 to High(LRows) do
    LJson[LIdx] := WithTypeSpans(HierarchyRowJson(LRows[LIdx].Hit,
      cKindWord[LRows[LIdx].Kind], LRows[LIdx].TypeName, '',
      LRows[LIdx].ParentTypeName, LRows[LIdx].Depth),
      LineTypeSpansJson(LRows[LIdx].Hit.FilePath, LRows[LIdx].Hit.Line));
  Result := BuildResponse(AMsg.IdJson, HierarchyAnswer(LName, LJson));
end;

{ pastree/findAssignments, pastree/findCreations, pastree/findDestructions -
  OURS, not LSP. Three filtered reference searches with the same answer shape
  as the hierarchy methods, so one client path paints all six:

    - assignments: the writes to the variable / field / parameter / writable
      property at the position - the left side of `:=`, the counter of a
      `for` (AssignableAt + FindAssignments; section 7 of PasTree's
      docs/editor-features.md, gaps included: a `var`/`out` argument and
      `Inc`/`Dec` are not rows);
    - creations: every `TFoo.Create(...)` constructing EXACTLY the class at
      the position, positioned on the class name in the call (ClassAt +
      FindCreations; section 8 there - a descendant's constructor and a
      class-reference variable are not rows);
    - destructions: every `X.Free` / `X.Destroy` / `FreeAndNil(X)` where X's
      STATIC type is exactly that class, positioned on X (ClassAt +
      FindDestructions; same section - an instance freed through an
      ancestor-typed variable or by an owner is a runtime fact, not a row).

  The declaration site is never one of PasTree's rows (as in FindReferences),
  so it is prepended here as kind `declaration` when DeclHit has it - a reader
  of "where is this assigned" wants the declaration pinned first, as the
  references tab pins it. Every other row carries the search's own word
  (`assignment`, `creation`, `destruction`).

  `null` when the position fails the gate: a constant, a type or a read-only
  property for assignments; anything but a class or `object` type name for the
  other two. A gate that passes with nothing found answers the declaration
  row alone - "nothing assigns this" is an answer, "not assignable" a refusal. }
function TLspServer.HandleFindSites(const AMsg: TLspIncoming;
  AKind: TFindSitesKind): string;
const
  cTag: array[TFindSitesKind] of string =
    ('findAssignments', 'findCreations', 'findDestructions');
  cRowWord: array[TFindSitesKind] of string =
    ('assignment', 'creation', 'destruction');
  cNotSubject: array[TFindSitesKind] of string =
    ('not an assignable symbol', 'not a class', 'not a class');
var
  LPath, LName: string;
  LPasLine, LPasCol, LMid, LTMid, LSym, LIdx: Integer;
  LGate: Boolean;
  LDecl: TPasRefHit;
  LRows: TArray<TPasRefHit>;
  LJson: TArray<string>;
begin
  if not FindAllPreamble(AMsg, cTag[AKind], LPath, LMid, LPasLine, LPasCol,
    Result) then
    Exit;
  if AKind = fskAssignments then
    LGate := FNav.AssignableAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName)
  else
    LGate := FNav.ClassAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  if not LGate then
  begin
    Log(Format('%s: %s -> %s',
      [cTag[AKind], PosTag(LPath, LPasLine, LPasCol), cNotSubject[AKind]]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  case AKind of
    fskAssignments:  LRows := FNav.FindAssignments(LTMid, LSym);
    fskCreations:    LRows := FNav.FindCreations(LTMid, LSym);
    fskDestructions: LRows := FNav.FindDestructions(LTMid, LSym);
  end;
  Log(Format('%s: %s ''%s'' -> %d rows',
    [cTag[AKind], PosTag(LPath, LPasLine, LPasCol), LName, Length(LRows)]));
  LJson := nil;
  if FNav.DeclHit(LTMid, LSym, LDecl) then
    LJson := LJson + [WithTypeSpans(
      HierarchyRowJson(LDecl, 'declaration', '', ''),
      LineTypeSpansJson(LDecl.FilePath, LDecl.Line))];
  for LIdx := 0 to High(LRows) do
    LJson := LJson + [WithTypeSpans(
      HierarchyRowJson(LRows[LIdx], cRowWord[AKind], '', ''),
      LineTypeSpansJson(LRows[LIdx].FilePath, LRows[LIdx].Line))];
  Result := BuildResponse(AMsg.IdJson, HierarchyAnswer(LName, LJson));
end;

function JsonBool(AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

{ pastree/findAllAt - OURS, not LSP. Which of the Find All commands apply at
  the position: the seven gates PasTree's demo greys its submenu on, asked
  once so a host can grey its own menu the same way. Answers an object with
  one Boolean per command - `references`, `overrides`, `implementations`,
  `descendants`, `assignments`, `creations`, `destructions` - and `null`
  when it cannot say.

  IT NEVER WAITS. A menu is drawn on the main thread of the host, and the
  host gives this a short budget (the RAD Studio client: a couple of hundred
  milliseconds, then every item stays enabled and the command itself is the
  gate, as before). So unlike every other request here this one does not go
  through WaitAnalyzed: an analysis in flight, or one not yet started, is
  `null` - "cannot say" - and it starts nothing either, a menu popup being no
  reason to spin up a closure. Pending edits are not flushed for the same
  reason: the verdict is over the model as it stands, and a position that
  moved since is at worst greyed wrong until the next idle rebuild. }
function TLspServer.HandleFindAllAt(const AMsg: TLspIncoming): string;
var
  LPath, LName, LAnnotate: string;
  LLine, LChar, LPasLine, LPasCol, LMid, LTMid, LSym, LRawTok: Integer;
  LRefs, LOverrides, LImpls, LDesc, LAssign, LClass: Boolean;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'findAllAt: textDocument.uri and position required'));
  if (FSession <> nil) or (FNav = nil) then
  begin
    Log('findAllAt: cannot say - analysis in flight or none');
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LMid := FNav.ModelIdOf(LPath);
  if LMid < 0 then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  // The same four identities HandleReferences tries, in its order.
  LRefs := FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) or
    FNav.SymbolAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName) or
    FNav.BuiltinNameAt(LMid, LPasLine, LPasCol, LName) or
    FNav.DefineAt(LMid, LPasLine, LPasCol, LName, LRawTok);
  LOverrides := FNav.MethodAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  LImpls := FNav.InterfaceMethodAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName)
    or FNav.InterfaceAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  LDesc := FNav.TypeAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  LAssign := FNav.AssignableAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  LClass := FNav.ClassAt(LMid, LPasLine, LPasCol, LTMid, LSym, LName);
  // The eighth gate is a different kind of question - about the LIVE buffer,
  // not the model - and answers a scope, not a Boolean: "one" (the caret is
  // in a call's arguments), "all" (on a call's name), "" (no call). The menu
  // captions its item from it; the command re-asks and applies.
  LAnnotate := AnnotateArgsAtPath(LPath, LPasLine, LPasCol,
    DefaultAnnotateOptions).Scope;
  Log(Format('findAllAt: %s -> refs=%s ovr=%s impl=%s desc=%s asg=%s cls=%s '
    + 'annotate=%s',
    [PosTag(LPath, LPasLine, LPasCol), JsonBool(LRefs), JsonBool(LOverrides),
     JsonBool(LImpls), JsonBool(LDesc), JsonBool(LAssign), JsonBool(LClass),
     LAnnotate]));
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"references":%s,"overrides":%s,"implementations":%s,"descendants":%s,' +
    '"assignments":%s,"creations":%s,"destructions":%s,"annotate":%s}',
    [JsonBool(LRefs), JsonBool(LOverrides), JsonBool(LImpls), JsonBool(LDesc),
     JsonBool(LAssign), JsonBool(LClass), JsonBool(LClass),
     JsonQuote(LAnnotate)]));
end;

{ One row of pastree/findDefines or pastree/definesAt: a TPasDefineSite. A
  project or platform origin has no source site (PasTree leaves Hit.FilePath
  empty when the analysis has no main module) - uri and filePath come back
  as '' rather than a bogus file:// for an empty path, so a client can tell
  "nothing to jump to" from a real location without parsing the path. }
function DefineSiteJson(const ASite: TPasDefineSite): string;
const
  cOrigin: array[TPasDefineOrigin] of string = ('unit', 'project', 'platform');
var
  LUri: string;
begin
  if ASite.Hit.FilePath = '' then
    LUri := ''
  else
    LUri := PathToUri(ASite.Hit.FilePath);
  Result := Format('{"uri":%s,"filePath":%s,"line":%d,"col":%d,' +
    '"name":%s,"origin":%s,"active":%s,"snippet":%s,"hiFrom":%d,"hiTo":%d}',
    [JsonQuote(LUri), JsonQuote(ASite.Hit.FilePath), ASite.Hit.Line,
     ASite.Hit.Col, JsonQuote(ASite.Name), JsonQuote(cOrigin[ASite.Origin]),
     JsonBool(ASite.Active), JsonQuote(ASite.Hit.Snippet), ASite.Hit.HiFrom,
     ASite.Hit.HiTo]);
end;

function TLspServer.DefineSitesJson(
  const ASites: TArray<TPasDefineSite>): string;
var
  LJson: TArray<string>;
  LIdx: Integer;
begin
  LJson := nil;
  for LIdx := 0 to High(ASites) do
    if ASites[LIdx].Hit.FilePath = '' then
      LJson := LJson + [DefineSiteJson(ASites[LIdx])]
    else
      LJson := LJson + [WithTypeSpans(DefineSiteJson(ASites[LIdx]),
        LineTypeSpansJson(ASites[LIdx].Hit.FilePath, ASites[LIdx].Hit.Line))];
  Result := '[' + string.Join(',', LJson) + ']';
end;

{ pastree/findDefines - OURS, not LSP. The project-wide inventory of every
  conditional-symbol DEFINITION (PasTree 0.28.0, TPasNavigator.FindDefines):
  every $DEFINE site across the closure (dead branches included, flagged
  `active: false`), then the .dproj/command-line defines and the platform's
  predefined ones, each a row with no source site of its own. Needs NO
  cursor - it is always offered, unlike the seven findAllAt commands, and
  since one server serves exactly one project (TLspSessionPool on the IDE
  side), this is naturally project-scoped: there is no group-wide variant to
  build, unlike Find References. }
function TLspServer.HandleFindDefines(const AMsg: TLspIncoming): string;
var
  LSites: TArray<TPasDefineSite>;
begin
  if not WaitAnalyzed('', AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LSites := FNav.FindDefines;
  Log(Format('pastree/findDefines: %d rows', [Length(LSites)]));
  Result := BuildResponse(AMsg.IdJson, DefineSitesJson(LSites));
end;

{ pastree/definesAt - OURS, not LSP. What DefinesAt(PasTree 0.28.0) is: the
  set of names in effect at the cursor of a model's main file, one row per
  name, the last definition (unit, then project, then platform) winning - an
  $IFDEF written right there would see exactly this. AMid < 0 (the file has
  no model of its own, e.g. an opened .inc) is not an error: DefinesAt
  answers the base set alone, so the command works in every editor. }
function TLspServer.HandleDefinesAt(const AMsg: TLspIncoming): string;
var
  LPath: string;
  LLine, LChar, LPasLine, LPasCol, LMid: Integer;
  LSites: TArray<TPasDefineSite>;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'definesAt: textDocument.uri and position required'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LMid := FNav.ModelIdOf(LPath);
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  LSites := FNav.DefinesAt(LMid, LPasLine, LPasCol);
  Log(Format('pastree/definesAt: %s -> %d names',
    [PosTag(LPath, LPasLine, LPasCol), Length(LSites)]));
  Result := BuildResponse(AMsg.IdJson, DefineSitesJson(LSites));
end;

{ pastree/dcuSource - OURS, not LSP. The interface text PasTree generates
  for a compiled unit (PasTree 0.37.0, PasTree.Dcu / PasTree.Dcu.Source),
  for a host that wants to SHOW the file a navigation answer landed in when
  that file is a .dcu. The analysis already reads such units this way:
  TPasSourceManager lists .dcu files on the search paths and falls back to
  one when no .pas exists for a unit name, so a definition into a
  third-party unit shipped compiled-only answers a Location whose uri ends
  in .dcu and whose line is a line of this text. An editor cannot open that
  path itself, so it asks here and shows what comes back read-only.

  THE SAME TEXT THE ANALYSIS RAN ON, by construction: LoadFileTolerant is
  the routine ResolveUnit's fallback goes through, so the line the Location
  names is a line of what the host shows - a second generator would be a
  second source of truth, and they would disagree exactly on the units that
  are hardest to print. The text is generated afresh per request (a class
  function has no cache); it is one unit, on a user action.

  A .dcu the reader refuses - a compiler before Delphi 11, a platform other
  than Win32/Win64, a truncated file - is an ERROR with the reader's own
  words (EPasDcuError: "Delphi 10.4 is not supported (Delphi 11 to 13 are)"),
  so the host can put the reason where the user looks, rather than an empty
  answer that reads as "nothing here". The importer's F1027 says the same
  thing in the diagnostics (SF1027_UnitDcuUnreadable); this is its twin for
  the click. Params: textDocument.uri. Answer: an object with uri, unitName
  and text. }
function TLspServer.HandleDcuSource(const AMsg: TLspIncoming): string;
var
  LPath, LText: string;
begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'dcuSource: textDocument.uri required'));
  if not TPasSourceManager.IsDcuPath(LPath) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'dcuSource: not a .dcu path: ' + LPath));
  if not TFile.Exists(LPath) then
  begin
    Log('pastree/dcuSource: no such file: ' + LPath);
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED,
      TPath.GetFileName(LPath) + ': the file does not exist'));
  end;
  try
    LText := TPasSourceManager.LoadFileTolerant(LPath);
  except
    on E: Exception do
    begin
      Log(Format('pastree/dcuSource: %s could not be read: %s',
        [LPath, E.Message]));
      Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED,
        Format('%s could not be read: %s',
          [TPath.GetFileName(LPath), E.Message])));
    end;
  end;
  Log(Format('pastree/dcuSource: %s -> %d chars', [LPath, Length(LText)]));
  Result := BuildResponse(AMsg.IdJson,
    Format('{"uri":%s,"unitName":%s,"text":%s}',
      [JsonQuote(PathToUri(LPath)),
       JsonQuote(TPath.GetFileNameWithoutExtension(LPath)),
       JsonQuote(LText)]));
end;

{ pastree/projectChanged - OURS, not LSP. The client saw the .dproj saved
  and asks whether that matters: the .dproj is read again exactly as
  initialize read it, and the answer is an object whose `changed` is false
  when every part the analysis took from it is the same, else true with
  `what` naming the parts (cDProjParts). The client restarts the server only
  on true.

  WHY ASK RATHER THAN RESTART: the IDE re-saves the .dproj with every save of
  the .dpr, and the restart that followed cost a full analysis - 38 s on
  AVImark under load, 2026-10-01, for a space typed and deleted in the .dpr.
  Re-reading the .dproj costs about a second and blocks only this server.

  NOT A RECONFIGURE. A changed configuration still goes through a restart:
  everything below initialize assumes it is fixed, and a restart is the path
  that is known to get all of it right. }
function TLspServer.HandleProjectChanged(const AMsg: TLspIncoming): string;
var
  LDProj: TPasDProj;
  LSig: TArray<string>;
  LWhat: string;
  LIdx: Integer;
  LStart: UInt64;
begin
  // A bare .dpr, or no project at all: nothing was read from a .dproj, so
  // nothing of one can have changed.
  if (FInitProjectFile = '') or
     not SameText(TPath.GetExtension(FInitProjectFile), '.dproj') then
    Exit(BuildResponse(AMsg.IdJson, '{"changed":false}'));
  LStart := GetTickCount64;
  LSig := nil;
  LDProj := TPasDProj.Create;
  try
    if LDProj.Load(FInitProjectFile, FInitPlatform, FInitConfig) then
      LSig := DProjSignature(LDProj);
  finally
    LDProj.Free;
  end;
  LWhat := '';
  if (LSig = nil) or (FProjectSig = nil) then
    // Unreadable now, or unreadable at initialize: either way this server's
    // configuration is not known to match the file, and a restart says so
    // in the place the user reads (Tell, at initialize).
    LWhat := 'unreadable'
  else
    for LIdx := 0 to High(cDProjParts) do
      if LSig[LIdx] <> FProjectSig[LIdx] then
      begin
        if LWhat <> '' then
          LWhat := LWhat + ', ';
        LWhat := LWhat + cDProjParts[LIdx];
      end;
  if LWhat = '' then
  begin
    Log(Format('pastree/projectChanged: %s re-read in %d ms - same '
      + 'configuration, nothing to restart for',
      [TPath.GetFileName(FInitProjectFile), GetTickCount64 - LStart]));
    Exit(BuildResponse(AMsg.IdJson, '{"changed":false}'));
  end;
  Log(Format('pastree/projectChanged: %s re-read in %d ms - changed: %s',
    [TPath.GetFileName(FInitProjectFile), GetTickCount64 - LStart, LWhat]));
  Result := BuildResponse(AMsg.IdJson,
    Format('{"changed":true,"what":%s}', [JsonQuote(LWhat)]));
end;

{ pastree/outline - OURS, not LSP. The Go To picker's lists (the RAD Studio
  client's Ctrl+G, copied from PasTree's demo): every row a TPasOutlineEntry,
  serialized field for field, so the picker draws the head word, the name,
  the detail, the section note and the unit the way the demo does. LSP's own
  documentSymbol cannot carry this - it has no head word, no detail, no
  routine BODIES and no landmarks - and reshaping it would have lost exactly
  what the picker is for.

  `scope` picks the list:
  - `module`: PasTree.Outline.PasModuleOutline over the analyzed tree of
    `textDocument.uri` - declarations AND bodies in source order, plus the
    `unit`/`interface`/`uses`/`implementation`/`include` landmarks, each row
    with its position (1-based, PasTree's own; the client draws `:N` from it
    and needs no conversion). A demoted model is rehydrated first.
  - `project`: TPasNavigator.ProjectOutline over the PROJECT's own units
    (the .dproj's list plus the main source - library units reached through
    the search path are not project files and are not listed), from the
    retained symbol tables, so a demoted unit costs nothing. These rows carry
    NO position (line = col = 0): a row is placed when it is chosen, by
    pastree/outlineTarget below, which hydrates that one unit. The client
    asks every project of a group for this to build its Group tab.

  THE ANSWER IS A TABLE, NOT ONE OBJECT PER ROW. The project list of a real
  project is 100k+ rows (AVImark: 113,613), and spelled out as objects it was
  33 MB that the client's System.JSON took two seconds to read on a fast
  machine. Most of a row is a repeated value - a dozen kind and head words, a
  few hundred owners, one file per unit - so those are interned once, in
  tables written BEFORE the rows, and each row is a positional array - one
  object with these members (its braces left out here, a brace would end
  this comment):

    "scope": "project"
    "kinds": [...], "heads": [...], "sections": [...], "owners": [...]
    "files": [[uri, unitName, unitId], ...]
    "rows": [[kind, head, owner, "Name", "detail", section, isImpl, file, sym, node, line, col, [typeStart, typeLen, ...]], ...]

  kind/head/owner/section/file are indices into the tables; isImpl is 0/1;
  the last element is the detail's type names as 1-based (start, len)
  pairs, flattened, empty when it names none (PasTree's DetailTypes).
  Same list: ~8 MB, and the client reads it in one pass
  (PasTreeIdePlugin.OutlineRows, the reader; TLspClient.RequestRaw hands it
  the text without a DOM). Kinds, heads and sections still travel as WORDS
  (`type`, `routine`, `include`...; `interface`, `implementation`...), just
  once each: the client is not compiled against PasTree and must not depend
  on an enum's order, only on this answer's own tables. }
function TLspServer.HandleOutline(const AMsg: TLspIncoming): string;
const
  KINDS: array[TPasOutlineKind] of string = ('module', 'section', 'uses',
    'include', 'type', 'var', 'const', 'property', 'routine');
  SECTIONS: array[TPasOutlineSection] of string = ('', 'interface',
    'implementation', 'initialization', 'finalization');
var
  LScope, LPath, LItem: string;
  LMid, LIdx, LTable, LSpan: Integer;
  LMids: TArray<Integer>;
  LEntries: TArray<TPasOutlineEntry>;
  LBuf: TJsonBuf;
  LStart, LListed: UInt64;
  LHeads, LOwners, LFiles: TDictionary<string, Integer>;
  LHeadList, LOwnerList, LFileList: TList<string>;
  LFileUnit: TList<TPair<string, Integer>>;   // per file: unit name, unit id
  LHeadIdx, LOwnerIdx, LFileIdx: TArray<Integer>;
  LKind: TPasOutlineKind;
  LSection: TPasOutlineSection;

  function Intern(ADict: TDictionary<string, Integer>; AList: TList<string>;
    const AValue: string): Integer;
  begin
    if not ADict.TryGetValue(AValue, Result) then
    begin
      Result := AList.Add(AValue);
      ADict.Add(AValue, Result);
    end;
  end;

begin
  LScope := 'module';
  if AMsg.Params <> nil then
    LScope := AMsg.Params.GetValue<string>('scope', 'module');
  if (LScope <> 'module') and (LScope <> 'project') then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'outline: scope must be "module" or "project"'));
  LPath := '';
  if LScope = 'module' then
  begin
    LPath := DocPathOf(AMsg.Params);
    if LPath = '' then
      Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
        'outline: textDocument.uri required for scope "module"'));
  end;
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if (FNav = nil) or (FProject = nil) then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  if (LScope = 'project') and (FOutlineCache <> '') then
  begin
    Log('pastree/outline project -> cached');
    Exit(BuildResponse(AMsg.IdJson, FOutlineCache));
  end;

  LStart := GetTickCount64;
  if LScope = 'module' then
  begin
    LMid := FNav.ModelIdOf(LPath);
    if LMid < 0 then
    begin
      Log('pastree/outline: file not in the analyzed closure: ' + LPath);
      Exit(BuildResponse(AMsg.IdJson, 'null'));
    end;
    if not FProject.EnsureHydrated(LMid) then
    begin
      Log('pastree/outline: could not rehydrate ' + LPath);
      Exit(BuildResponse(AMsg.IdJson, 'null'));
    end;
    LEntries := PasModuleOutline(FProject.Model(LMid).Tree);
  end
  else
  begin
    // The project's own files, the main source first and then the .dproj's
    // list in its order - a file the closure never reached (not compiled on
    // this platform, a missing unit) has no model and is silently not a row.
    LMids := nil;
    if FMainSource <> '' then
    begin
      LMid := FNav.ModelIdOf(FMainSource);
      if LMid >= 0 then
        LMids := LMids + [LMid];
    end;
    for LItem in FProjectFiles do
    begin
      LMid := FNav.ModelIdOf(LItem);
      if (LMid >= 0) and not TArray.Contains<Integer>(LMids, LMid) then
        LMids := LMids + [LMid];
    end;
    // A project with no .dproj (a bare .dpr - the harness's, or a file
    // opened from disk) lists no units; its units are then the models
    // under its own directory, which is what a .dproj would have listed.
    if (Length(FProjectFiles) = 0) and (FProjectDir <> '') then
      for LMid := 0 to FProject.ModelCount - 1 do
        if FProject.Model(LMid) <> nil then
        begin
          LItem := TPath.GetFullPath(FProject.ModelFile(LMid));
          if LItem.StartsWith(IncludeTrailingPathDelimiter(FProjectDir),
               True) and not TArray.Contains<Integer>(LMids, LMid) then
            LMids := LMids + [LMid];
        end;
    LEntries := FNav.ProjectOutline(LMids);
  end;
  LListed := GetTickCount64;

  LHeads := TDictionary<string, Integer>.Create;
  LOwners := TDictionary<string, Integer>.Create;
  LFiles := TDictionary<string, Integer>.Create;
  LHeadList := TList<string>.Create;
  LOwnerList := TList<string>.Create;
  LFileList := TList<string>.Create;
  LFileUnit := TList<TPair<string, Integer>>.Create;
  try
    // Pass 1: the tables. A file's unit name and id are the same on every
    // row of that file (a project row's file IS its unit; a module row's
    // may be an include, with UnitId -1), so they live in the file table.
    SetLength(LHeadIdx, Length(LEntries));
    SetLength(LOwnerIdx, Length(LEntries));
    SetLength(LFileIdx, Length(LEntries));
    for LIdx := 0 to High(LEntries) do
      with LEntries[LIdx] do
      begin
        LHeadIdx[LIdx] := Intern(LHeads, LHeadList, Head);
        LOwnerIdx[LIdx] := Intern(LOwners, LOwnerList, Owner);
        if not LFiles.TryGetValue(FilePath, LTable) then
        begin
          LTable := LFileList.Add(FilePath);
          LFiles.Add(FilePath, LTable);
          LFileUnit.Add(TPair<string, Integer>.Create(UnitName, UnitId));
        end;
        LFileIdx[LIdx] := LTable;
      end;

    // Pass 2: the text. ~70 chars a row; the buffer is sized for it once.
    LBuf.Init(Length(LEntries) * 80 + LFileList.Count * 120 + 1024);
    LBuf.Add('{"scope":');
    LBuf.AddQuoted(LScope);
    LBuf.Add(',"kinds":[');
    for LKind := Low(TPasOutlineKind) to High(TPasOutlineKind) do
    begin
      if LKind > Low(TPasOutlineKind) then
        LBuf.AddChar(',');
      LBuf.AddQuoted(KINDS[LKind]);
    end;
    LBuf.Add('],"heads":[');
    for LTable := 0 to LHeadList.Count - 1 do
    begin
      if LTable > 0 then
        LBuf.AddChar(',');
      LBuf.AddQuoted(LHeadList[LTable]);
    end;
    LBuf.Add('],"sections":[');
    for LSection := Low(TPasOutlineSection) to High(TPasOutlineSection) do
    begin
      if LSection > Low(TPasOutlineSection) then
        LBuf.AddChar(',');
      LBuf.AddQuoted(SECTIONS[LSection]);
    end;
    LBuf.Add('],"owners":[');
    for LTable := 0 to LOwnerList.Count - 1 do
    begin
      if LTable > 0 then
        LBuf.AddChar(',');
      LBuf.AddQuoted(LOwnerList[LTable]);
    end;
    LBuf.Add('],"files":[');
    for LTable := 0 to LFileList.Count - 1 do
    begin
      if LTable > 0 then
        LBuf.AddChar(',');
      LBuf.AddChar('[');
      LBuf.AddQuoted(PathToUri(LFileList[LTable]));
      LBuf.AddChar(',');
      LBuf.AddQuoted(LFileUnit[LTable].Key);
      LBuf.AddChar(',');
      LBuf.AddInt(LFileUnit[LTable].Value);
      LBuf.AddChar(']');
    end;
    LBuf.Add('],"rows":[');
    for LIdx := 0 to High(LEntries) do
      with LEntries[LIdx] do
      begin
        if LIdx > 0 then
          LBuf.AddChar(',');
        LBuf.AddChar('[');
        LBuf.AddInt(Ord(Kind));
        LBuf.AddChar(',');
        LBuf.AddInt(LHeadIdx[LIdx]);
        LBuf.AddChar(',');
        LBuf.AddInt(LOwnerIdx[LIdx]);
        LBuf.AddChar(',');
        LBuf.AddQuoted(Name);
        LBuf.AddChar(',');
        LBuf.AddQuoted(Detail);
        LBuf.AddChar(',');
        LBuf.AddInt(Ord(Section));
        LBuf.AddChar(',');
        LBuf.AddInt(Ord(IsImpl));
        LBuf.AddChar(',');
        LBuf.AddInt(LFileIdx[LIdx]);
        LBuf.AddChar(',');
        LBuf.AddInt(Sym);
        LBuf.AddChar(',');
        LBuf.AddInt(Node);
        LBuf.AddChar(',');
        LBuf.AddInt(Line);
        LBuf.AddChar(',');
        LBuf.AddInt(Col);
        // 13th: the detail's type names, [start, len, start, len...],
        // 1-based into the detail (PasTree 0.41.0, DetailTypes) - what the
        // picker paints in its type colour. Present on every row so the
        // reader's shape is one; empty when the detail names no type.
        LBuf.Add(',[');
        for LSpan := 0 to High(DetailTypes) do
        begin
          if LSpan > 0 then
            LBuf.AddChar(',');
          LBuf.AddInt(DetailTypes[LSpan].Start);
          LBuf.AddChar(',');
          LBuf.AddInt(DetailTypes[LSpan].Len);
        end;
        LBuf.Add(']]');
      end;
    LBuf.Add(']}');
    // Two times, because they are two different problems: the list is
    // PasTree's walk over the symbol tables, the JSON is this unit's.
    Log(Format('pastree/outline %s%s -> %d rows: list %d ms, json %d ms, %dK chars',
      [LScope, IfThen(LPath <> '', ' ' + TPath.GetFileName(LPath), ''),
       Length(LEntries), LListed - LStart, GetTickCount64 - LListed,
       LBuf.Length div 1024]));
    if LScope = 'project' then
      FOutlineCache := LBuf.ToString;
    Result := BuildResponse(AMsg.IdJson, LBuf.ToString);
  finally
    LFileUnit.Free;
    LFileList.Free;
    LOwnerList.Free;
    LHeadList.Free;
    LFiles.Free;
    LOwners.Free;
    LHeads.Free;
  end;
end;

{ pastree/outlineTarget - OURS, not LSP. Where a `project` row of
  pastree/outline lands: `kind`, `unitId`, `sym` and `node` are the row's own
  fields handed back. A `module` row goes to the unit header
  (TPasNavigator.UnitHeaderTarget), an `include` row to the directive itself
  (IncludeSiteTarget, `node` = its IncludeRefs index), anything else to the
  declared name (DeclHit - the same call Find References pins its declaration
  row with). Each hydrates the one unit it needs, which is why the list did
  not carry positions in the first place. Answers a Location, or null when
  the row cannot be placed - the picker then stays open rather than landing
  somewhere else. }
function TLspServer.HandleOutlineTarget(const AMsg: TLspIncoming): string;
var
  LKind: string;
  LUnitId, LSym, LNode: Integer;
  LTarget: TPasNavTarget;
  LHit: TPasRefHit;
  LFile: string;
  LLine, LCol, LLen: Integer;
  LFound: Boolean;
begin
  if (AMsg.Params = nil) or
     not AMsg.Params.TryGetValue<Integer>('unitId', LUnitId) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'outlineTarget: unitId required'));
  LKind := AMsg.Params.GetValue<string>('kind', '');
  LSym := AMsg.Params.GetValue<Integer>('sym', -1);
  LNode := AMsg.Params.GetValue<Integer>('node', -1);
  if not WaitAnalyzed('', AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LLen := 0;
  LFile := '';
  LLine := 0;
  LCol := 0;
  if LKind = 'module' then
  begin
    LFound := FNav.UnitHeaderTarget(LUnitId, LTarget);
    if LFound then
    begin
      LFile := LTarget.FilePath;
      LLine := LTarget.Line;
      LCol := LTarget.Col;
      LLen := Length(LTarget.Name);
    end;
  end
  else if LKind = 'include' then
  begin
    LFound := FNav.IncludeSiteTarget(LUnitId, LNode, LTarget);
    if LFound then
    begin
      LFile := LTarget.FilePath;
      LLine := LTarget.Line;
      LCol := LTarget.Col;
    end;
  end
  else
  begin
    LFound := (LSym >= 0) and FNav.DeclHit(LUnitId, LSym, LHit);
    if LFound then
    begin
      LFile := LHit.FilePath;
      LLine := LHit.Line;
      LCol := LHit.Col;
      LLen := Max(0, LHit.HiTo - LHit.HiFrom);
    end;
  end;
  if not LFound then
  begin
    Log(Format('pastree/outlineTarget: %s unit %d sym %d node %d -> not placed',
      [LKind, LUnitId, LSym, LNode]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  Log(Format('pastree/outlineTarget: %s unit %d sym %d -> %s',
    [LKind, LUnitId, LSym, PosTag(LFile, LLine, LCol)]));
  Result := BuildResponse(AMsg.IdJson, LocationJson(LFile, LLine, LCol, LLen));
end;

{ textDocument/implementation and textDocument/declaration - the decl<->impl
  toggle, a Pascal-specific navigation the navigator implements as pure CST
  walks (GotoImplementation/GotoDeclaration; they never cross units, because
  the language requires the body in the same one).

  Note how this differs from textDocument/definition above: definition asks
  "where is this NAME declared" and follows a resolved reference anywhere in
  the closure, while these two ask "where is the OTHER HALF of the routine I
  am standing in" - from a method header or a `forward` to the body's first
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
    LocationWithTypes(LTarget.FilePath, LTarget.Line, LTarget.Col,
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

{ textDocument/documentSymbol - the unit's own outline (VS Code: Outline
  pane, Ctrl+Shift+O, breadcrumbs; the IDE plugin's Structure view maps here
  too).

  Built from the model's SCOPES rather than by walking the CST: the unit and
  implementation scopes list their symbols in declaration order, which is the
  order a reader expects, and a type's MemberScope gives its fields, methods
  and properties as children with no separate traversal. Routine bodies
  (sckRoutine/sckBlock) are deliberately not descended into - locals are not
  outline material.

  Known limit: range = selectionRange = the NAME's span, because NodeSite
  gives a node's first-token position and nothing public gives a
  declaration's full extent yet. Navigation and the tree are correct; what
  suffers is breadcrumb tracking as the cursor moves inside a body, which
  needs a real span (a nav-side NodeSpan belongs in PasTree, not here). }
{ textDocument/onTypeFormatting - block completion, standard LSP: the client
  declares us for the "\n" trigger (see HandleInitialize), sends the caret
  right after Enter, and gets zero or one TextEdit inserting the missing
  closer. The decision is PasLsp.BlockClose's, over the document truth
  exactly as completion reads it - open buffer first, file second - because
  the request exists BECAUSE the buffer just changed. Answering null (not an
  empty array) for "nothing to insert" is the spec's own idiom.

  The ch parameter is checked and anything but a newline answers null: the
  protocol allows moreTriggerCharacter registrations we do not make, but a
  client that sends one anyway must not get a closer for it. }
function TLspServer.HandleOnTypeFormatting(const AMsg: TLspIncoming): string;
var
  LPath, LText, LCh, LJson: string;
  LDoc: TLspDocument;
  LLine, LChar, LTabSize, LIdx: Integer;
  LInsertSpaces: Boolean;
  LEdits: TArray<TBlockCloseEdit>;
  LStart: UInt64;
begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'onTypeFormatting: textDocument.uri required'));
  LCh := AMsg.Params.GetValue<string>('ch', '');
  LLine := AMsg.Params.GetValue<Integer>('position.line', -1);
  LChar := AMsg.Params.GetValue<Integer>('position.character', -1);
  if (LLine < 0) or (LChar < 0) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'onTypeFormatting: position required'));
  if (LCh <> #10) and (LCh <> #13#10) and (LCh <> #13) then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  LStart := GetTickCount64;
  if FDocs.TryGet(LPath, LDoc) then
    LText := LDoc.Text
  else if not TryReadTextNoBom(LPath, LText) then
    LText := '';
  if LText = '' then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LTabSize := AMsg.Params.GetValue<Integer>('options.tabSize', 2);
  LInsertSpaces := AMsg.Params.GetValue<Boolean>('options.insertSpaces', True);

  if not PlanBlockClose(LText, LLine, LTabSize, LInsertSpaces, LEdits) then
  begin
    if FTrace then
      Log(Format('onTypeFormatting: %s line %d -> nothing',
        [TPath.GetFileName(LPath), LLine]));
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;

  LJson := '';
  for LIdx := 0 to High(LEdits) do
  begin
    if LJson <> '' then
      LJson := LJson + ',';
    LJson := LJson + Format(
      '{"range":{"start":{"line":%d,"character":%d},' +
      '"end":{"line":%d,"character":%d}},"newText":%s}',
      [LEdits[LIdx].Line, LEdits[LIdx].StartChar,
       LEdits[LIdx].Line, LEdits[LIdx].EndChar,
       JsonQuote(LEdits[LIdx].Text)]);
  end;
  Log(Format('onTypeFormatting: %s line %d -> %d edit(s), closer %s in %d ms',
    [TPath.GetFileName(LPath), LLine, Length(LEdits),
     JsonQuote(Trim(LEdits[High(LEdits)].Text)), GetTickCount64 - LStart]));
  Result := BuildResponse(AMsg.IdJson, '[' + LJson + ']');
end;

{ pastree/classComplete - OUR request, the server half of Ctrl+Shift+C.

  Not an LSP method and not pretending to be one: the protocol has no notion
  of "implement what I declared", `textDocument/codeAction` is the nearest
  thing and it would mean advertising a capability, negotiating kinds and
  round-tripping a resolve for a command exactly one client will ever send.
  A named custom request is the honest shape (the `pastree/` prefix is the
  same convention `pastreeCall` and `pastreeHtml` follow).

  Like completion, it must NOT call WaitAnalyzed: the whole point is the
  declaration typed a second ago, which no rebuild has seen. It is a parse of
  the live buffer; the last-good analysis, when there is one, is asked only
  whether a property's accessor name is inherited from another unit. }
function TLspServer.HandleClassComplete(const AMsg: TLspIncoming): string;
var
  LPath, LText, LEdits, LNames, LCaretJson: string;
  LDoc: TLspDocument;
  LAnswer: TLspClassCompleteAnswer;
  LIdx, LCaretLine, LCaretChar, LLine, LChar, LPasLine, LPasCol,
    LMid: Integer;
  LStart: UInt64;
  LBodyOrder: TLspBodyOrder;
begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'classComplete: textDocument.uri required'));
  // `position` scopes the answer to the type or free routine the caret is in
  // (2026-09-05; see PasLsp.ClassComplete). OPTIONAL, unlike syncPrototypes':
  // a client with no caret to offer - or one written against the earlier
  // shape of this request - still gets the whole unit, which (0, 0) means.
  LLine := AMsg.Params.GetValue<Integer>('position.line', -1);
  LChar := AMsg.Params.GetValue<Integer>('position.character', -1);
  LPasLine := 0;
  LPasCol := 0;
  if (LLine >= 0) and (LChar >= 0) then
    LspToPasTree(LLine, LChar, LPasLine, LPasCol);
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
  // `bodyOrder`: where a new body goes among its type's existing ones -
  // "alphabetical" (the default, the native command's) or "declaration".
  LBodyOrder := boAlphabetical;
  if SameText(AMsg.Params.GetValue<string>('bodyOrder', ''),
       'declaration') then
    LBodyOrder := boDeclaration;
  // The last-good analysis, when it holds this file, bridged exactly as
  // completion bridges it - asked only whether a name a property points at
  // is inherited from another unit. Never waited for, for the reason above.
  LMid := -1;
  if FNav <> nil then
    LMid := FNav.ModelIdOf(LPath);
  if (FProject <> nil) and (LMid >= 0) then
    LAnswer := FCompletion.ClassCompleteAt(LPath, LText, LPasLine, LPasCol,
      FProject, LMid, LBodyOrder)
  else
    LAnswer := FCompletion.ClassCompleteAt(LPath, LText, LPasLine, LPasCol,
      nil, -1, LBodyOrder);

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
  // NO CARET is `null`, never line 0 / character 0: LSP line 0 is the unit's
  // first line, and the RAD client read the old zero pair as exactly that -
  // the caret jumped to the top of the unit after a press that wrote only a
  // field (Alex, 2026-09-23).
  LCaretJson := 'null';
  if LAnswer.CaretLine > 0 then
  begin
    PasTreeToLsp(LAnswer.CaretLine, LAnswer.CaretCol, LCaretLine, LCaretChar);
    LCaretJson := Format('{"line":%d,"character":%d}',
      [LCaretLine, LCaretChar]);
  end;
  Log(Format('classComplete: %s(%d,%d) -> %d edit(s) in %d ms (%s)',
    [TPath.GetFileName(LPath), LPasLine, LPasCol, Length(LAnswer.Edits),
     GetTickCount64 - LStart, LAnswer.Provider]));
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"edits":[%s],"caret":%s,"names":%s,"count":%d,"provider":%s}',
    [LEdits, LCaretJson, JsonQuote(LNames),
     Length(LAnswer.Edits), JsonQuote(LAnswer.Provider)]));
end;

{ pastree/syncPrototypes - OUR request, the server half of Sync Prototypes.

  Same shape and same reasoning as classComplete above: a named custom request
  rather than a codeAction, and NO WaitAnalyzed - the signature it is asked
  about was edited a keystroke ago, so the only text that can answer is the
  live buffer, parsed on the spot.

  The one structural difference is in the answer: these edits REPLACE. Each
  carries a real end position, so a client must not treat the range as the
  zero-length insertion point classComplete's edits are. }
function TLspServer.HandleSyncPrototypes(const AMsg: TLspIncoming): string;
var
  LPath, LText, LEdits: string;
  LDoc: TLspDocument;
  LAnswer: TLspSyncAnswer;
  LIdx, LLine, LChar, LPasLine, LPasCol: Integer;
  LStartLine, LStartChar, LEndLine, LEndChar: Integer;
  LCaretLine, LCaretChar: Integer;
  LStart: UInt64;
begin
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'syncPrototypes: textDocument.uri required'));
  LLine := AMsg.Params.GetValue<Integer>('position.line', -1);
  LChar := AMsg.Params.GetValue<Integer>('position.character', -1);
  if (LLine < 0) or (LChar < 0) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'syncPrototypes: position required'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  LStart := GetTickCount64;
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
  LAnswer := FCompletion.SyncPrototypeAt(LPath, LText, LPasLine, LPasCol);

  LEdits := '';
  for LIdx := 0 to High(LAnswer.Edits) do
  begin
    if LEdits <> '' then
      LEdits := LEdits + ',';
    PasTreeToLsp(LAnswer.Edits[LIdx].Line, LAnswer.Edits[LIdx].Col,
      LStartLine, LStartChar);
    PasTreeToLsp(LAnswer.Edits[LIdx].EndLine, LAnswer.Edits[LIdx].EndCol,
      LEndLine, LEndChar);
    LEdits := LEdits + Format(
      '{"range":{"start":{"line":%d,"character":%d},'
      + '"end":{"line":%d,"character":%d}},"newText":%s,"name":%s}',
      [LStartLine, LStartChar, LEndLine, LEndChar,
       JsonQuote(LAnswer.Edits[LIdx].Text), JsonQuote(LAnswer.Edits[LIdx].Name)]);
  end;
  Log(Format('syncPrototypes: %s(%d,%d) -> %d edit(s) in %d ms (%s)',
    [TPath.GetFileName(LPath), LPasLine, LPasCol, Length(LAnswer.Edits),
     GetTickCount64 - LStart, LAnswer.Provider]));
  // `caret` exactly as classComplete reports it: LSP coordinates, 0/0 when
  // there is nothing to move to, so one client-side rule reads both.
  LCaretLine := 0;
  LCaretChar := 0;
  if LAnswer.CaretLine > 0 then
    PasTreeToLsp(LAnswer.CaretLine, LAnswer.CaretCol, LCaretLine, LCaretChar);
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"edits":[%s],"caret":{"line":%d,"character":%d},"count":%d,'
    + '"provider":%s}',
    [LEdits, LCaretLine, LCaretChar, Length(LAnswer.Edits),
     JsonQuote(LAnswer.Provider)]));
end;

{ The annotation answer for a position, over the live text - shared by the
  request proper and by findAllAt's menu gate, so the menu and the command
  cannot disagree about whether the caret is in a call. }
function TLspServer.AnnotateArgsAtPath(const APath: string;
  APasLine, APasCol: Integer;
  const AOptions: TLspAnnotateOptions): TLspAnnotateAnswer;
var
  LText: string;
  LDoc: TLspDocument;
  LMid: Integer;
begin
  Result := Default(TLspAnnotateAnswer);
  if FDocs.TryGet(APath, LDoc) then
    LText := LDoc.Text
  else if not TryReadTextNoBom(APath, LText) then
    LText := '';
  if LText = '' then
  begin
    Result.Provider := 'pastree/annotateArgs: no text';
    Exit;
  end;
  if FCompletion = nil then
    FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
      FDefines);
  SyncCompletionOverlays;
  LMid := -1;
  if FNav <> nil then
    LMid := FNav.ModelIdOf(APath);
  if (FProject <> nil) and (LMid >= 0) then
    Result := FCompletion.AnnotateArgsAt(APath, LText, APasLine, APasCol,
      FProject, LMid, AOptions)
  else
    Result := FCompletion.AnnotateArgsAt(APath, LText, APasLine, APasCol,
      nil, -1, AOptions);
end;

(* pastree/annotateArgs - OUR request, the server half of "Annotate
  argument(s)": `{Name:}` and `{var}`/`{out}` written in front of a call's
  arguments (PasLsp.AnnotateArgs has every rule). Same shape as classComplete
  - zero-length insertion edits in ascending order - and the same reason for
  NO WaitAnalyzed: the call under the caret may have been typed a second ago,
  and only the live buffer resolved through the overlay knows it. `scope` says
  what the caret meant: "one" (inside the arguments - that argument) or "all"
  (on the routine's name - every argument); "" when there is no call. *)
function TLspServer.HandleAnnotateArgs(const AMsg: TLspIncoming): string;
var
  LPath, LEdits, LMode, LDetail: string;
  LAnswer: TLspAnnotateAnswer;
  LOptions: TLspAnnotateOptions;
  LIdx, LLine, LChar, LPasLine, LPasCol: Integer;
  LStartLine, LStartChar, LEndLine, LEndChar: Integer;
  LStart: UInt64;
begin
  LPath := DocPathOf(AMsg.Params);
  if (LPath = '') or
     not AMsg.Params.TryGetValue<Integer>('position.line', LLine) or
     not AMsg.Params.TryGetValue<Integer>('position.character', LChar) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'annotateArgs: textDocument.uri and position required'));
  LspToPasTree(LLine, LChar, LPasLine, LPasCol);
  { The options, every one OPTIONAL: a client that sends only the position
    gets the caret's own reading, by-reference marks, and the layout left
    alone - the shape this request had before the dialog (0.42.0). `mode` is
    "auto" | "all" | "anonymous" | "current" | "none" (marks and layout only); an
    unknown word reads as auto. }
  LOptions := DefaultAnnotateOptions;
  LMode := AMsg.Params.GetValue<string>('mode', 'auto');
  if LMode = 'all' then
    LOptions.Mode := amAll
  else if LMode = 'anonymous' then
    LOptions.Mode := amAnonymous
  else if LMode = 'current' then
    LOptions.Mode := amCurrent;
  if LMode = 'none' then
    LOptions.Mode := amNone;
  LOptions.MarkByRef := AMsg.Params.GetValue<Boolean>('byRef', True);
  LOptions.OneArgPerLine := AMsg.Params.GetValue<Boolean>('multiline', False);
  LStart := GetTickCount64;
  LAnswer := AnnotateArgsAtPath(LPath, LPasLine, LPasCol, LOptions);
  LEdits := '';
  for LIdx := 0 to High(LAnswer.Edits) do
  begin
    if LEdits <> '' then
      LEdits := LEdits + ',';
    // A REAL end, as syncPrototypes sends: with `multiline` the edit
    // replaces the whitespace in front of the argument. Zero-length
    // otherwise, so a client that already applies insertions is unchanged.
    PasTreeToLsp(LAnswer.Edits[LIdx].Line, LAnswer.Edits[LIdx].Col,
      LStartLine, LStartChar);
    PasTreeToLsp(LAnswer.Edits[LIdx].EndLine, LAnswer.Edits[LIdx].EndCol,
      LEndLine, LEndChar);
    LEdits := LEdits + Format(
      '{"range":{"start":{"line":%d,"character":%d},'
      + '"end":{"line":%d,"character":%d}},"newText":%s}',
      [LStartLine, LStartChar, LEndLine, LEndChar,
       JsonQuote(LAnswer.Edits[LIdx].Text)]);
  end;
  LDetail := '';
  if LAnswer.Detail <> '' then
    LDetail := ': ' + LAnswer.Detail;
  Log(Format('annotateArgs: %s -> scope %s, %d edit(s), %s in %d ms (%s%s)',
    [PosTag(LPath, LPasLine, LPasCol), LAnswer.Scope, Length(LAnswer.Edits),
     LAnswer.Routine, GetTickCount64 - LStart, LAnswer.Provider, LDetail]));
  // `detail` is the log's longer why; a client shows `provider`.
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"edits":[%s],"count":%d,"scope":%s,"routine":%s,"provider":%s,'
    + '"detail":%s}',
    [LEdits, Length(LAnswer.Edits), JsonQuote(LAnswer.Scope),
     JsonQuote(LAnswer.Routine), JsonQuote(LAnswer.Provider),
     JsonQuote(LAnswer.Detail)]));
end;

{ The text a parse-only request reads: the open document's overlay, else the
  file on disk (BOM stripped, PasLsp.SourceText's rule), else ''. }
function TLspServer.LiveTextOf(const APath: string): string;
var
  LDoc: TLspDocument;
begin
  if FDocs.TryGet(APath, LDoc) then
    Result := LDoc.Text
  else if not TryReadTextNoBom(APath, Result) then
    Result := '';
end;

(* pastree/units - OURS, not LSP. The list behind the RAD Studio client's
  View Unit (Ctrl+F12) and Use Unit (Alt+F11) dialogs - PasTree's demo View
  Unit picker, whose two scopes this keeps:

  - `project`: the main source and the .dproj's units. Answered WITHOUT
    waiting for the analysis when the .dproj listed units - they are known
    from initialize, and the dialog should open on a cold server at once. A
    project with no .dproj (a bare .dpr) has no list, and then waits and
    takes the models under the project's directory, as pastree/outline does.
  - `closure`: every unit the analysis reached - the project's, the search
    path's, the IDE's Library Path's, `.dcu`-only ones included. This is
    what the stock dialogs cannot offer (they list the .dproj alone), and
    why these dialogs exist. Waits for the analysis.

  With `textDocument`, that document's LIVE text is parsed (no analysis) and
  each row says whether the document already uses it and whether it is the
  document itself, so Use Unit can leave both out. A uses item matches a
  row by name, directly or behind one of the project's unit-scope prefixes
  (`Classes` is the row `System.Classes`) - never by bare suffix, which
  would make `Types` hide `Vcl.Types` as well as `System.Types`.

  The answer - one object, braces left out of this comment:
    "scope": "closure",
    "document": {"kind": "unit", "name": "Foo"} or null,
    "units": [["System.Classes", uri, flags], ...]
  flags: 1 a project unit, 2 compiled-only (`.dcu`), 4 used by the document,
  8 the document itself. Rows are in no particular order; the client sorts. *)
function TLspServer.HandleUnits(const AMsg: TLspIncoming): string;
var
  LScope, LDocPath, LPath, LItem, LName: string;
  LProjectSet, LUsedNames, LInPaths: TDictionary<string, Boolean>;
  LPaths: TList<string>;
  LInfo: TLspUsesInfo;
  LHasDoc: Boolean;
  LMid, LFlags: Integer;
  LBuf: TJsonBuf;
  LStart: UInt64;

  { ONE LOOKUP PER ROW. The first cut compared every row with every uses
    item under every unit-scope prefix - on AVImark.dpr that is 1554 rows x
    1556 items x a dozen prefixes, 30 million SameText calls on concatenated
    strings: 1.7 s for the project list, 6 s for the closure (2026-09-25).
    The keys are built once instead: every item's name, lower-cased, as
    written and behind each prefix, and the file name of every `in` path. }
  procedure BuildUsedKeys;
  var
    LU: TLspUsesItem;
    LN: string;
  begin
    for LU in LInfo.Items do
    begin
      if LU.InPath <> '' then
        LInPaths.AddOrSetValue(LowerCase(ExtractFileName(LU.InPath)), True);
      LUsedNames.AddOrSetValue(LowerCase(LU.Name), True);
      if Pos('.', LU.Name) = 0 then
        for LN in FNamespaces do
          if LN <> '' then
            LUsedNames.AddOrSetValue(LowerCase(LN + '.' + LU.Name), True);
    end;
  end;

  function UsedByDoc(const AUnitName, AFilePath: string): Boolean;
  begin
    Result := LUsedNames.ContainsKey(LowerCase(AUnitName)) or
      ((LInPaths.Count > 0) and
       LInPaths.ContainsKey(LowerCase(ExtractFileName(AFilePath))));
  end;

  procedure AddProjectPath(const APath: string);
  var
    LFull: string;
  begin
    if APath = '' then
      Exit;
    LFull := TPath.GetFullPath(APath);
    if not LProjectSet.ContainsKey(LowerCase(LFull)) then
    begin
      LProjectSet.Add(LowerCase(LFull), True);
      if LScope = 'project' then
        LPaths.Add(LFull);
    end;
  end;

begin
  LScope := 'project';
  if AMsg.Params <> nil then
    LScope := AMsg.Params.GetValue<string>('scope', 'project');
  if (LScope <> 'project') and (LScope <> 'closure') then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'units: scope must be "project" or "closure"'));
  LDocPath := DocPathOf(AMsg.Params);
  LStart := GetTickCount64;

  // The closure needs the analysis; so does a project that listed nothing.
  if (LScope = 'closure') or (Length(FProjectFiles) = 0) then
  begin
    if not WaitAnalyzed(LDocPath, AMsg.IdJson) then
      Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  end;

  LInfo := Default(TLspUsesInfo);
  LHasDoc := False;
  if LDocPath <> '' then
  begin
    LItem := LiveTextOf(LDocPath);
    if LItem <> '' then
    begin
      if FCompletion = nil then
        FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
          FDefines);
      SyncCompletionOverlays;
      LInfo := FCompletion.UsesInfoAt(LDocPath, LItem);
      LHasDoc := LInfo.Kind <> '';
    end;
  end;

  LProjectSet := TDictionary<string, Boolean>.Create;
  LUsedNames := TDictionary<string, Boolean>.Create;
  LInPaths := TDictionary<string, Boolean>.Create;
  LPaths := TList<string>.Create;
  try
    if LHasDoc then
      BuildUsedKeys;
    AddProjectPath(FMainSource);
    for LItem in FProjectFiles do
      AddProjectPath(LItem);
    // No .dproj list: the project's units are the models under its directory.
    if (Length(FProjectFiles) = 0) and (FProjectDir <> '') and
       (FProject <> nil) then
      for LMid := 0 to FProject.ModelCount - 1 do
        if FProject.Model(LMid) <> nil then
        begin
          LItem := TPath.GetFullPath(FProject.ModelFile(LMid));
          if LItem.StartsWith(IncludeTrailingPathDelimiter(FProjectDir),
               True) then
            AddProjectPath(LItem);
        end;
    if (LScope = 'closure') and (FProject <> nil) then
      for LMid := 0 to FProject.ModelCount - 1 do
        if FProject.Model(LMid) <> nil then
          LPaths.Add(TPath.GetFullPath(FProject.ModelFile(LMid)));

    LBuf.Init(LPaths.Count * 160 + 256);
    LBuf.Add('{"scope":');
    LBuf.AddQuoted(LScope);
    LBuf.Add(',"document":');
    if LHasDoc then
    begin
      LBuf.Add('{"kind":');
      LBuf.AddQuoted(LInfo.Kind);
      LBuf.Add(',"name":');
      LBuf.AddQuoted(LInfo.SelfName);
      LBuf.AddChar('}');
    end
    else
      LBuf.Add('null');
    LBuf.Add(',"units":[');
    for LMid := 0 to LPaths.Count - 1 do
    begin
      LPath := LPaths[LMid];
      LName := ChangeFileExt(ExtractFileName(LPath), '');
      LFlags := 0;
      if LProjectSet.ContainsKey(LowerCase(LPath)) then
        LFlags := LFlags or 1;
      if TPasSourceManager.IsDcuPath(LPath) then
        LFlags := LFlags or 2;
      if LHasDoc then
      begin
        if UsedByDoc(LName, LPath) then
          LFlags := LFlags or 4;
        if SameText(LPath, LDocPath) or SameText(LName, LInfo.SelfName) then
          LFlags := LFlags or 8;
      end;
      if LMid > 0 then
        LBuf.AddChar(',');
      LBuf.AddChar('[');
      LBuf.AddQuoted(LName);
      LBuf.AddChar(',');
      LBuf.AddQuoted(PathToUri(LPath));
      LBuf.AddChar(',');
      LBuf.AddInt(LFlags);
      LBuf.AddChar(']');
    end;
    LBuf.Add(']}');
    Log(Format('pastree/units %s for %s -> %d rows, the document uses %d, '
      + 'in %d ms', [LScope, ExtractFileName(LDocPath), LPaths.Count,
       Length(LInfo.Items), GetTickCount64 - LStart]));
    Result := BuildResponse(AMsg.IdJson, LBuf.ToString);
  finally
    LPaths.Free;
    LInPaths.Free;
    LUsedNames.Free;
    LProjectSet.Free;
  end;
end;

(* pastree/useUnit - OURS, not LSP. Use Unit's write: `unit` added to the
  `section` ("interface" | "implementation"; ignored for a program) uses
  clause of the LIVE text, as ONE zero-length insertion edit (PasLsp.UseUnit
  has the layout and every refusal). No WaitAnalyzed, for Annotate's reason:
  the clause may have been edited a second ago and only the buffer knows.
  `options` is the client's layout - tabSize/insertSpaces for the one indent
  step a new clause or a wrapped name needs, rightMargin for when `, Name`
  no longer fits on the `;` line. An empty `edits` is a refusal, and
  `provider` says why. *)
function TLspServer.HandleUseUnit(const AMsg: TLspIncoming): string;
var
  LPath, LText, LUnit, LIndent, LEdits: string;
  LAnswer: TLspUseUnitAnswer;
  LTabSize, LMargin, LLine, LChar: Integer;
  LImpl: Boolean;
begin
  LPath := DocPathOf(AMsg.Params);
  LUnit := '';
  if AMsg.Params <> nil then
    LUnit := AMsg.Params.GetValue<string>('unit', '');
  if (LPath = '') or (LUnit = '') then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'useUnit: textDocument.uri and unit required'));
  LImpl := SameText(AMsg.Params.GetValue<string>('section', 'interface'),
    'implementation');
  LTabSize := AMsg.Params.GetValue<Integer>('options.tabSize', 2);
  if (LTabSize < 1) or (LTabSize > 16) then
    LTabSize := 2;
  if AMsg.Params.GetValue<Boolean>('options.insertSpaces', True) then
    LIndent := StringOfChar(' ', LTabSize)
  else
    LIndent := #9;
  LMargin := AMsg.Params.GetValue<Integer>('options.rightMargin', 80);
  LAnswer := Default(TLspUseUnitAnswer);

  LText := LiveTextOf(LPath);
  if LText = '' then
    LAnswer.Provider := 'pastree/useUnit: no text'
  else
  begin
    if FCompletion = nil then
      FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
        FDefines);
    SyncCompletionOverlays;
    LAnswer := FCompletion.UseUnitAt(LPath, LText, LUnit, LImpl, LIndent,
      LMargin);
  end;
  LEdits := '';
  if LAnswer.Text <> '' then
  begin
    PasTreeToLsp(LAnswer.Line, LAnswer.Col, LLine, LChar);
    LEdits := Format('{"range":{"start":{"line":%d,"character":%d},'
      + '"end":{"line":%d,"character":%d}},"newText":%s}',
      [LLine, LChar, LLine, LChar, JsonQuote(LAnswer.Text)]);
  end;
  Log(Format('useUnit: %s + %s (%s) -> %s',
    [ExtractFileName(LPath), LUnit, IfThen(LImpl, 'implementation',
     'interface'), LAnswer.Provider]));
  Result := BuildResponse(AMsg.IdJson, Format(
    '{"edits":[%s],"section":%s,"provider":%s}',
    [LEdits, JsonQuote(LAnswer.Section), JsonQuote(LAnswer.Provider)]));
end;

{ -------- unused units -------- }

{ The units of the project the "in the project" checks look at: every model
  outside LibraryPaths that is a source (not a .dcu) - what the demo's Unused
  Units in the Project takes. }
function TLspServer.ProjectUnitMids: TArray<Integer>;
var
  LPath: string;
begin
  Result := nil;
  if FNav = nil then
    Exit;
  for var LMid := 0 to FProject.ModelCount - 1 do
  begin
    LPath := FProject.ModelFile(LMid);
    if TPasSourceManager.IsDcuPath(LPath) or FNav.IsUnderLibraryPath(LPath)
    then
      Continue;
    Result := Result + [LMid];
  end;
end;

// Where a node's first visible token starts in the main file, 1-based;
// False for a node in an include or out of range.
function NodeMainPos(AModel: TPasSemaModel; ANode: Integer;
  out ALine, ACol: Integer): Boolean;
var
  LVisIdx: Integer;
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  LVisIdx := AModel.Tree.NodeLeftmostVis(ANode);
  if (LVisIdx < 0) or (LVisIdx > High(AModel.Tree.Source.Visible)) then
    Exit;
  LVis := AModel.Tree.Source.Visible[LVisIdx];
  if LVis.FileId <> 0 then
    Exit;
  AModel.Tree.Source.Files[0].OffsetToLineCol(
    AModel.Tree.Source.Files[0].Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := True;
end;

{ The name node of model AMid's `uses` entry for AUnitName that starts at
  ALine:ACol - the row PasTree.Sema.Lint answered with, back to the tree an
  edit is computed on. NIL_NODE when there is none. }
function TLspServer.UsesEntryNode(AMid: Integer; const AUnitName: string;
  ALine, ACol: Integer): Integer;
var
  LModel: TPasSemaModel;
  LLine, LCol: Integer;
begin
  Result := NIL_NODE;
  if (AMid < 0) or (AMid >= FProject.ModelCount) then
    Exit;
  LModel := FProject.Model(AMid);
  for var LU in LModel.UsesList do
    if (LU.NameNode <> NIL_NODE) and SameText(LU.NameFull, AUnitName) and
       NodeMainPos(LModel, LU.NameNode, LLine, LCol) and (LLine = ALine) and
       (LCol = ACol) then
      Exit(LU.NameNode);
end;

{ Why an entry AByModel names (model -> name nodes) could not be removed by
  an edit, into ARefused (model shl 32 or name node -> why) - the edits
  themselves are computed when the client removes (pastree/usesRemoval), on
  the text as it is then. }
procedure TLspServer.RemovalRefusals(const AByModel: TDictionary<Integer,
  TArray<Integer>>; ARefused: TDictionary<Int64, string>);
var
  LRefused: TArray<TLspUsesRefusal>;
begin
  for var LPair in AByModel do
  begin
    if not FProject.EnsureHydrated(LPair.Key) then
      Continue;
    UsesRemovalEdits(FProject.Model(LPair.Key).Tree, LPair.Value, LRefused);
    for var LR in LRefused do
      ARefused.AddOrSetValue((Int64(LPair.Key) shl 32) or
        Cardinal(LR.NameNode), LR.Reason);
  end;
end;

function StringsJson(const AItems: TArray<string>): string;
begin
  Result := '';
  for var LS in AItems do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + JsonQuote(LS);
  end;
  Result := '[' + Result + ']';
end;

// AObjectJson with the members AMembers (',"a":1,...') appended.
function WithMembers(const AObjectJson, AMembers: string): string;
begin
  Result := Copy(AObjectJson, 1, Length(AObjectJson) - 1) + AMembers + '}';
end;

{ pastree/unusedUses - OURS. The `uses` entries a unit does not need
  (PasTree.Sema.Lint.FindUnusedUses): `scope` "unit" checks the document,
  "project" every unit of the analysis outside LibraryPaths. Rows are
  Locations of the entry's name with typeSpans, `unitName`, `section`
  (interface / implementation), `doubts` (why removing it may be wrong -
  such a row is shown, never removed) and `refused` (why no edit removes it,
  '' when one does). The edits come later, from pastree/usesRemoval.

  loHideGlobalInit, always: an entry naming a unit whose initialization
  reaches outside itself, or whose removal would take one out of the
  program, is not offered at all (Alex, 2026-10-05) - it is in `uses` for what it
  registers. }
function TLspServer.HandleUnusedUses(const AMsg: TLspIncoming): string;
var
  LPath, LScope, LReason: string;
  LMids, LNodes: TArray<Integer>;
  LRows: TArray<TPasUnusedUse>;
  LMid, LNode: Integer;
  LByModel: TDictionary<Integer, TArray<Integer>>;
  LRefused: TDictionary<Int64, string>;
  LRowMid, LRowNode: TArray<Integer>;
  LSB: TStringBuilder;
  LStart: UInt64;
begin
  LPath := DocPathOf(AMsg.Params);
  LScope := 'unit';
  if AMsg.Params <> nil then
    LScope := AMsg.Params.GetValue<string>('scope', 'unit');
  if (LScope <> 'unit') and (LScope <> 'project') then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'unusedUses: scope must be "unit" or "project"'));
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, '{"rows":[]}'));
  LStart := GetTickCount64;
  if LScope = 'unit' then
  begin
    LMid := FNav.ModelIdOf(LPath);
    if LMid < 0 then
      Exit(BuildError(AMsg.IdJson, LSP_REQUEST_FAILED,
        TPath.GetFileName(LPath) + ' is not part of the analysis'));
    LMids := [LMid];
  end
  else
    LMids := ProjectUnitMids;
  LRows := FindUnusedUses(FNav, LMids, [loHideGlobalInit]);

  LByModel := TDictionary<Integer, TArray<Integer>>.Create;
  LRefused := TDictionary<Int64, string>.Create;
  LSB := TStringBuilder.Create;
  try
    SetLength(LRowMid, Length(LRows));
    SetLength(LRowNode, Length(LRows));
    for var LIdx := 0 to High(LRows) do
    begin
      LMid := FNav.ModelIdOf(LRows[LIdx].Hit.FilePath);
      LNode := UsesEntryNode(LMid, LRows[LIdx].UnitName, LRows[LIdx].Hit.Line,
        LRows[LIdx].Hit.Col);
      LRowMid[LIdx] := LMid;
      LRowNode[LIdx] := LNode;
      if (LRows[LIdx].Doubts <> nil) or (LNode = NIL_NODE) then
        Continue;
      if not LByModel.TryGetValue(LMid, LNodes) then
        LNodes := nil;
      LByModel.AddOrSetValue(LMid, LNodes + [LNode]);
    end;
    RemovalRefusals(LByModel, LRefused);
    for var LIdx := 0 to High(LRows) do
    begin
      LReason := '';
      if LRows[LIdx].Doubts = nil then
        if LRowNode[LIdx] = NIL_NODE then
          LReason := 'the entry was not found in the tree'
        else
          LRefused.TryGetValue((Int64(LRowMid[LIdx]) shl 32) or
            Cardinal(LRowNode[LIdx]), LReason);
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(WithMembers(WithTypeSpans(HitLocationJson(LRows[LIdx].Hit),
        LineTypeSpansJson(LRows[LIdx].Hit.FilePath, LRows[LIdx].Hit.Line)),
        Format(',"unitName":%s,"section":%s,"doubts":%s,"refused":%s',
        [JsonQuote(LRows[LIdx].UnitName),
         JsonQuote(IfThen(LRows[LIdx].InInterface, 'interface',
           'implementation')), StringsJson(LRows[LIdx].Doubts),
         JsonQuote(LReason)])));
    end;
    LMid := 0;
    for var LRow in LRows do
      if LRow.Doubts <> nil then
        Inc(LMid);
    Log(Format('pastree/unusedUses %s: %d units checked -> %d entries, %d ' +
      'with a doubt, in %d ms', [LScope, Length(LMids), Length(LRows), LMid,
      GetTickCount64 - LStart]));
    Result := BuildResponse(AMsg.IdJson, '{"rows":[' + LSB.ToString + ']}');
  finally
    LSB.Free;
    LRefused.Free;
    LByModel.Free;
  end;
end;

{ pastree/unreferencedUnits - OURS. The project units nobody uses
  (PasTree.Sema.Lint.FindUnreferencedUnits, with loHideGlobalInit as
  pastree/unusedUses): a row is the unit's name in its own header, with
  `unitName`, `doubts` and `listedBy` - every `uses` entry naming it, a
  Location each with `note` (PasTree's words: "no name of it used",
  "itself unreferenced") and `program` (true for the .dpr/.dpk, whose entry
  the client removes by taking the unit out of the project). The client
  removes the other entries through pastree/usesRemoval, so the project
  still compiles once the unit is out of it. }
function TLspServer.HandleUnreferencedUnits(const AMsg: TLspIncoming): string;
var
  LPath, LNote, LFileName, LLister: string;
  LMids: TArray<Integer>;
  LRows: TArray<TPasUnreferencedUnit>;
  LRowMid: Integer;
  LModel: TPasSemaModel;
  LHit: TPasRefHit;
  LIsProgram: Boolean;
  LSB, LListed: TStringBuilder;
  LStart: UInt64;
  LLine, LCol: Integer;
begin
  LPath := DocPathOf(AMsg.Params);
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, '{"rows":[]}'));
  LStart := GetTickCount64;
  LMids := ProjectUnitMids;
  LRows := FindUnreferencedUnits(FNav, LMids, [loHideGlobalInit]);

  LSB := TStringBuilder.Create;
  LListed := TStringBuilder.Create;
  try
    for var LIdx := 0 to High(LRows) do
    begin
      LListed.Clear;
      LRowMid := FNav.ModelIdOf(LRows[LIdx].Hit.FilePath);
      if LRowMid >= 0 then
        for var LM := 0 to FProject.ModelCount - 1 do
        begin
          if LM = LRowMid then
            Continue;
          LModel := FProject.Model(LM);
          for var LU in LModel.UsesList do
          begin
            if (LU.UnitId <> LRowMid) or (LU.NameNode = NIL_NODE) or
               not NodeMainPos(LModel, LU.NameNode, LLine, LCol) then
              Continue;
            LFileName := FProject.ModelFile(LM);
            LIsProgram := MatchText(ExtractFileExt(LFileName),
              ['.dpr', '.dpk']);
            // PasTree's note for this lister, matched by its file name.
            LNote := '';
            for LLister in LRows[LIdx].ListedBy do
              if StartsText(ExtractFileName(LFileName) + ' (', LLister) then
              begin
                LNote := Copy(LLister, Length(ExtractFileName(LFileName)) + 3,
                  MaxInt);
                if EndsText(')', LNote) then
                  SetLength(LNote, Length(LNote) - 1);
              end;
            LHit := Default(TPasRefHit);
            LHit.FilePath := LFileName;
            LHit.Line := LLine;
            LHit.Col := LCol;
            LHit.HiFrom := LCol - 1;
            LHit.HiTo := LHit.HiFrom + Length(LU.NameFull);
            if LListed.Length > 0 then
              LListed.Append(',');
            LListed.Append(WithMembers(WithTypeSpans(HitLocationJson(LHit),
              LineTypeSpansJson(LFileName, LLine)),
              Format(',"note":%s,"program":%s', [JsonQuote(LNote),
              IfThen(LIsProgram, 'true', 'false')])));
            Break;   // listed twice (E2004): one row
          end;
        end;
      if LIdx > 0 then
        LSB.Append(',');
      LSB.Append(WithMembers(WithTypeSpans(HitLocationJson(LRows[LIdx].Hit),
        LineTypeSpansJson(LRows[LIdx].Hit.FilePath, LRows[LIdx].Hit.Line)),
        Format(',"unitName":%s,"doubts":%s,"listedBy":[%s]',
        [JsonQuote(LRows[LIdx].UnitName), StringsJson(LRows[LIdx].Doubts),
         LListed.ToString])));
    end;
    Log(Format('pastree/unreferencedUnits: %d units checked -> %d nobody ' +
      'uses, in %d ms', [Length(LMids), Length(LRows),
      GetTickCount64 - LStart]));
    Result := BuildResponse(AMsg.IdJson, '{"rows":[' + LSB.ToString + ']}');
  finally
    LListed.Free;
    LSB.Free;
  end;
end;

{ pastree/usesRemoval - OURS. Unused Units' Remove: `files`, each a `uri`
  and the `names` to take out of its `uses` clauses, answered with the
  clause rewrites (uri, range, oldText, newText - PasLsp.UnusedUnits) on
  the text as it is NOW - the open document, or the file on disk. Parse
  only, no analysis to wait for: one Remove after another rewrites the same
  clause again, and an edit computed with the search would no longer match
  the clause the first one left. `refused` (why an entry stays, "File:
  Name: why") and `missing` ("File: Name", a name no clause holds any
  more) are for the client to say. }
function TLspServer.HandleUsesRemoval(const AMsg: TLspIncoming): string;
var
  LFiles, LNames: TJSONArray;
  LPath, LText: string;
  LWanted, LRefused, LMissing, LAllRefused, LAllMissing: TArray<string>;
  LEdits: TArray<TLspUsesRemoval>;
  LLine, LChar, LEndLine, LEndChar, LCount: Integer;
  LSB: TStringBuilder;
begin
  if (AMsg.Params = nil) or
     not AMsg.Params.TryGetValue<TJSONArray>('files', LFiles) then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'usesRemoval: files required'));
  if FCompletion = nil then
    FCompletion := TLspCompletionEngine.Create(FPlatform, FSearchPaths,
      FDefines);
  SyncCompletionOverlays;
  LAllRefused := nil;
  LAllMissing := nil;
  LCount := 0;
  LSB := TStringBuilder.Create;
  try
    for var LFile in LFiles do
    begin
      LPath := UriToPath(LFile.GetValue<string>('uri', ''));
      LWanted := nil;
      if LFile.TryGetValue<TJSONArray>('names', LNames) then
        for var LName in LNames do
          LWanted := LWanted + [LName.Value];
      if (LPath = '') or (LWanted = nil) then
        Continue;
      LText := LiveTextOf(LPath);
      if LText = '' then
      begin
        LAllRefused := LAllRefused + [ExtractFileName(LPath) +
          ': the file could not be read'];
        Continue;
      end;
      LEdits := FCompletion.UsesRemovalAt(LPath, LText, LWanted, LRefused,
        LMissing);
      for var LS in LRefused do
        LAllRefused := LAllRefused + [ExtractFileName(LPath) + ': ' + LS];
      for var LS in LMissing do
        LAllMissing := LAllMissing + [ExtractFileName(LPath) + ': ' + LS];
      for var LE in LEdits do
      begin
        PasTreeToLsp(LE.Line, LE.Col, LLine, LChar);
        PasTreeToLsp(LE.EndLine, LE.EndCol, LEndLine, LEndChar);
        if LSB.Length > 0 then
          LSB.Append(',');
        LSB.Append(Format('{"uri":%s,"range":{"start":{"line":%d,' +
          '"character":%d},"end":{"line":%d,"character":%d}},' +
          '"oldText":%s,"newText":%s}', [JsonQuote(PathToUri(LPath)), LLine,
          LChar, LEndLine, LEndChar, JsonQuote(LE.OldText),
          JsonQuote(LE.NewText)]));
        Inc(LCount);
      end;
    end;
    Log(Format('pastree/usesRemoval: %d file(s) -> %d edit(s), %d refused, ' +
      '%d missing', [LFiles.Count, LCount, Length(LAllRefused),
      Length(LAllMissing)]));
    for var LS in LAllRefused do
      Log('pastree/usesRemoval: refused ' + LS);
    Result := BuildResponse(AMsg.IdJson, '{"edits":[' + LSB.ToString +
      '],"refused":' + StringsJson(LAllRefused) + ',"missing":' +
      StringsJson(LAllMissing) + '}');
  finally
    LSB.Free;
  end;
end;

function TLspServer.HandleDocumentSymbol(const AMsg: TLspIncoming): string;
var
  LPath, LItems, LParts: string;
  LMid, LScopeIdx: Integer;
  LModel: TPasSemaModel;

  // The items of one scope as comma-joined DocumentSymbol JSON ('' = none).
  function ScopeItems(AScopeIdx, ADepth: Integer): string;
  var
    LScope: PSemaScope;
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
    // An EMPTY scope. Until PasTree 0.42.0 its containers were lazy objects,
    // nil until something was declared into it, and reading Count there was
    // an access violation - every documentSymbol answered with one once a
    // closure held such a scope (2026-08-23). Since 0.42.0 Symbols is a
    // record (TSemaSymList) and empty means Count = 0; cMinPasTreeVersion
    // keeps an older library from linking against this test.
    if (LScope = nil) or (LScope.Symbols.Count = 0) then
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
        // this one - LSP documentSymbol is strictly per-document.
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

  // Interface first, then implementation - source order, and the two are
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
// LSP SymbolKind enum (that is SymbolKindOf above) - this is prose for a
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

{ textDocument/hover - what is under the cursor, as a small markdown card:
  the DECLARATION's own source line in a Pascal code fence, plus a prose line
  naming the kind and where it lives.

  The declaration line comes from the navigator's DeclHit, the same snippet
  Find References shows for a declaration site - so the hover can never
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
  LDeclLine, LDeclCol, LRawTok, LIdx: Integer;
  LIsDefine: Boolean;
  LDefHits: TArray<TPasDefineHit>;
  LTarget: TPasNavTarget;
  LIdent: TPasNavIdent;
  LHit: TPasRefHit;
  LStartLine, LStartChar, LEndLine, LEndChar: Integer;
  LKind, LHitSnippet, LHoverCode, LTypeSpans, LHoverJson: string;
  LIsSymbolHit, LIsSymbol: Boolean;
  LIndent, LSpanIdx, LHeadLen, LSysMid: Integer;
  LSigSpans: TArray<Integer>;
  LBuiltinCode: string;
begin
  LBuiltinCode := '';
  LHeadLen := 0;
  LSigSpans := nil;
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
  // keyword, any whitespace) - answered with null and NOT logged, or a
  // session log becomes unreadable from mouse movement alone.
  //
  // A conditional symbol is not an identifier to IdentAt (its directive is
  // a comment to the lexer), so it is asked first, and its span is taken
  // from its own reference row on this line - DefineAt reports only the
  // whole `{$...}` token, and the card should underline the name alone.
  LIsDefine := FNav.DefineAt(LMid, LPasLine, LPasCol, LName, LRawTok);
  if LIsDefine then
  begin
    LDefHits := FNav.FindDefineReferences(LName);
    LIdent := Default(TPasNavIdent);
    LIdent.Name := LName;
    LIdent.Line := LPasLine;
    LIdent.ColFrom := LPasCol;
    LIdent.ColTo := LPasCol;
    for LIdx := 0 to High(LDefHits) do
      if (LDefHits[LIdx].Hit.Line = LPasLine) and
         (LPasCol >= LDefHits[LIdx].Hit.Col) and
         (LPasCol <= LDefHits[LIdx].Hit.Col
           + LDefHits[LIdx].Hit.HiTo - LDefHits[LIdx].Hit.HiFrom) and
         SameText(LDefHits[LIdx].Hit.FilePath, LPath) then
      begin
        LIdent.ColFrom := LDefHits[LIdx].Hit.Col;
        LIdent.ColTo := LDefHits[LIdx].Hit.Col
          + LDefHits[LIdx].Hit.HiTo - LDefHits[LIdx].Hit.HiFrom;
        Break;
      end;
  end
  else if not FNav.IdentAt(LMid, LPasLine, LPasCol, LIdent) then
    Exit(BuildResponse(AMsg.IdJson, 'null'));

  LCode := '';
  LNote := '';
  LDoc := '';
  LRawDoc := '';
  LDeclFile := '';
  LDeclLine := 0;
  LDeclCol := 0;
  LKind := '';
  LHitSnippet := '';
  LIsSymbolHit := False;
  LIsSymbol := False;
  if LIsDefine then
  begin
    // What it is, then where it comes from: the `$DEFINE` this directive
    // sees, the project/platform, or nowhere (a name that is never on).
    LCode := '{$DEFINE ' + LName + '}';
    LKind := 'conditional symbol';
    // Where it comes from: a project/platform define lands on the main
    // module's header (PasTree 0.27.2 - the project is its home, as
    // System.pas is a builtin's), a unit-local one on the $DEFINE this
    // directive sees; a name that is never on has neither.
    if FNav.GotoDefine(LMid, LPasLine, LPasCol, LTarget) then
    begin
      if FNav.IsProjectDefined(LName) then
        LNote := Format('conditional symbol - defined by the project (%s)',
          [TPath.GetFileName(LTarget.FilePath)])
      else
        LNote := Format('conditional symbol - %s:%d',
          [TPath.GetFileName(LTarget.FilePath), LTarget.Line]);
      LDeclFile := LTarget.FilePath;
      LDeclLine := LTarget.Line;
      LDeclCol := LTarget.Col;
    end
    else if FNav.IsProjectDefined(LName) then
      LNote := 'conditional symbol - defined by the project or platform'
    else
      LNote := 'conditional symbol - not defined here';
  end
  else if FNav.UnitAt(LMid, LPasLine, LPasCol, LTMid, LName) then
  begin
    LCode := 'unit ' + LName + ';';
    LKind := 'unit';
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
    LKind := KindWord(FProject.Model(LTMid).Symbols[LSymIdx].Kind);
    LIsSymbol := True;
    if FNav.DeclHit(LTMid, LSymIdx, LHit) then
    begin
      LCode := Trim(LHit.Snippet);
      LHitSnippet := TrimRight(LHit.Snippet);
      LIsSymbolHit := True;
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
    LKind := 'compiler builtin';
    // An intrinsic TYPE reads as the native hint has it - `type
    // System.Integer = -2147483648..2147483647` - and links to System.pas's
    // unit header, where the native hint goes too: System.pas says there
    // that these are "treated as if they were declared" there (Alex,
    // 2026-10-07).
    LBuiltinCode := BuiltinTypeSignatureText(FProject, LMid,
      FProject.Model(LMid).RefMap[LIdent.Node], LSigSpans, LHeadLen);
    if LBuiltinCode <> '' then
    begin
      LCode := LBuiltinCode;
      LKind := 'type';
      LSysMid := FProject.EnsureSystemUnit;
      if FNav.UnitDeclHit(LSysMid, LHit) then
      begin
        LNote := Format('compiler builtin - %s',
          [TPath.GetFileName(LHit.FilePath)]);
        LDeclFile := LHit.FilePath;
        LDeclLine := LHit.Line;
        LDeclCol := LHit.Col;
      end;
    end;
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
  // the name it is describing - including all segments of a qualified `uses`
  // name, which IdentAt reports as one span.
  PasTreeToLsp(LIdent.Line, LIdent.ColFrom, LStartLine, LStartChar);
  PasTreeToLsp(LIdent.Line, LIdent.ColTo, LEndLine, LEndChar);
  { `pastreeHover` is OURS too: the same card as fields, for a client that
    paints the hint itself (the RAD Studio plugin's hover window) rather than
    rendering markdown or HTML. `code` is the symbol's one-line signature as
    the native hint spells it (SymbolSignatureText: `var LName: string`, not
    the declaration line `LName, LDetail, LKind: string;`), or - for a kind it
    does not compose - the declaration's source line without its indentation;
    `typeSpans` are the type names in it, so they can be painted as the
    editor paints them; `headLen` is the length of its lead (`var`,
    `param [in/out]`), painted as a keyword; `file`/`line`/`col`
    (1-based) is where the link in the hint goes; `kind` and `note` say what
    it is. }
  if LBuiltinCode <> '' then
    LHoverCode := LBuiltinCode
  else
  begin
    LHeadLen := 0;
    LHoverCode := '';
  end;
  if LIsSymbol then
    LHoverCode := SymbolSignatureText(FProject, LTMid, LSymIdx, LDeclFile,
      LSigSpans, LHeadLen);
  if LHoverCode <> '' then
  begin
    LTypeSpans := '';
    for LSpanIdx := 0 to High(LSigSpans) do
    begin
      if LTypeSpans <> '' then
        LTypeSpans := LTypeSpans + ',';
      LTypeSpans := LTypeSpans + IntToStr(LSigSpans[LSpanIdx]);
    end;
    LTypeSpans := '[' + LTypeSpans + ']';
  end
  else if LIsSymbolHit then
  begin
    LIndent := Length(LHitSnippet) - Length(TrimLeft(LHitSnippet));
    LTypeSpans := ShiftSpansJson(LineTypeSpansJson(LDeclFile, LDeclLine),
      LIndent);
    LHoverCode := Trim(LHitSnippet);
  end
  else
  begin
    LTypeSpans := '[]';
    LHoverCode := LCode;
  end;
  LHoverJson := Format('{"code":%s,"typeSpans":%s,"headLen":%d,"doc":%s,' +
    '"kind":%s,"note":%s,"file":%s,"line":%d,"col":%d}',
    [JsonQuote(LHoverCode), LTypeSpans, LHeadLen, JsonQuote(LDoc),
     JsonQuote(LKind), JsonQuote(LNote), JsonQuote(LDeclFile), LDeclLine,
     LDeclCol]);
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
    '"pastreeHover":%s,' +
    '"range":{"start":{"line":%d,"character":%d},' +
    '"end":{"line":%d,"character":%d}}}',
    [JsonQuote(LMd),
     JsonQuote(HelpInsightPage(LCode, LDeclFile,
       TPath.GetFileName(LDeclFile), LDeclLine, LDeclCol, LRawDoc)),
     LHoverJson,
     LStartLine, LStartChar, LEndLine, LEndChar]));
end;

{ workspace/didChangeWatchedFiles - a file changed on disk, outside any
  editor buffer we hold.

  The CLIENT owns the watching: an editor already knows about file system
  events, and the IDE plugin gets the same news from ToolsAPI, so a watcher
  inside the server would be a second (polling, platform-specific) source of
  truth for something both clients already have. The VS Code client registers
  the glob in its `synchronize.fileEvents`; any other client just sends this
  notification.

  What matters here is deciding whether a rebuild is actually due:

  - a file we hold OPEN cannot change the analysis, because the analysis reads
    the OVERLAY for it, not the disk (document truth). No rebuild - but the
    cached disk text is refreshed, or the rebuild gate and didClose would keep
    comparing against a file that no longer exists in that form;
  - a file we do NOT hold open was read from disk by the analysis, so its
    change (or creation, or deletion - both move unit resolution) does mean a
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
    else if (LItem.GetValue<Integer>('type', 0) = 2) and
       not AffectsAnalysis(LPath) then
      // A REWRITTEN file this closure never read changes nothing here. The
      // RAD Studio client tells every running server about a reload (it
      // cannot know which projects compile the file), and a group of nine
      // must not answer with nine full rebuilds. Created and deleted files
      // still rebuild: either can change how a unit name resolves.
      Log('watched: ' + TPath.GetFileName(LPath) +
        ' changed on disk, outside this closure - no rebuild')
    else
      LRebuild := True;
  end;
  if LRebuild then
  begin
    FDiskMoved := True;
    Log(Format('watched: %d file(s) changed on disk - rebuild scheduled',
      [LTouched]));
    ScheduleAnalysis('');
  end;
end;

{ textDocument/typeDefinition - "go to the TYPE of the thing under the cursor",
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
  LX: TSemaXType;
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
      LocationWithTypes(LTarget.FilePath, LTarget.Line, LTarget.Col,
        Length(LTarget.Name))));
  end;

  // Route 2: the resolved type symbol, for the same-unit case where the type
  // expression itself did not resolve to a declaration. Not for a type
  // symbol - its own type is itself.
  if (LSym.Kind <> skType) and (LSym.TypeSym <> NIL_SYM) and
     FNav.DeclHit(LTMid, LSym.TypeSym, LHit) then
  begin
    Log(Format(AMsg.Method + ': %s ''%s'' -> %s via the resolved type symbol',
      [PosTag(LPath, LPasLine, LPasCol), LName,
       PosTag(LHit.FilePath, LHit.Line, LHit.Col)]));
    Exit(BuildResponse(AMsg.IdJson,
      LocationWithTypes(LHit.FilePath, LHit.Line, LHit.Col,
        LHit.HiTo - LHit.HiFrom)));
  end;

  { Route 3: the type the CROSS pass computed, for a symbol that NAMES no
    type at all.

    The two routes above read the DECLARATION: a type expression to resolve,
    or a model-local TypeSym written from one. A symbol whose type was never
    written has neither - an inline `var L := MakeHolder` (PasTree 0.17.0)
    and a bare `property Items;` promotion typed from its ancestor (0.17.1)
    both name their type nowhere - so both answered null here while member
    resolution THROUGH the same name worked perfectly, because that path asks
    the cross pass and this one did not (measured 2026-09-07: `LFromCall.Items`
    resolved, typeDefinition on `LFromCall` did not).

    BOTH library calls, because they answer different halves and neither
    covers the other: DeclTypeX reads the model's SymTypeX, which is where an
    INFERRED type lands, and SymDeclTypeX walks the ancestor chain but returns
    nothing for a typeless symbol that is not a property. Ordered inference
    first, promotion second, and only reached when the declaration said
    nothing - the routes above are the better answer when they have one, since
    they cross units and follow an alias. }
  if LSym.Kind <> skType then
  begin
    LX := FProject.DeclTypeX(LTMid, LSymIdx);
    if (LX.UnitId = NIL_SYM) or (LX.Sym = NIL_SYM) then
      LX := FProject.SymDeclTypeX(LTMid, LSymIdx);
    if (LX.UnitId <> NIL_SYM) and (LX.Sym <> NIL_SYM) and
       FNav.DeclHit(LX.UnitId, LX.Sym, LHit) then
    begin
      Log(Format(AMsg.Method + ': %s ''%s'' -> %s via the cross type pass',
        [PosTag(LPath, LPasLine, LPasCol), LName,
         PosTag(LHit.FilePath, LHit.Line, LHit.Col)]));
      Exit(BuildResponse(AMsg.IdJson,
        LocationWithTypes(LHit.FilePath, LHit.Line, LHit.Col,
          LHit.HiTo - LHit.HiFrom)));
    end;
  end;

  Log(Format(AMsg.Method + ': %s no type declaration reachable for ''%s''',
    [PosTag(LPath, LPasLine, LPasCol), LName]));
  Result := BuildResponse(AMsg.IdJson, 'null');
end;


{ textDocument/semanticTokens/full and /range - what every identifier in the
  document RESOLVED to, so the editor can colour a field, a local, a type and
  a unit name differently. This is the half of syntax colouring a grammar
  cannot do: a regex sees the same word in `FCount`, `Count` and `TCount`,
  the model knows which is a field, a property and a type. Keywords, strings,
  comments and numbers are NOT emitted - the client's TextMate grammar paints
  those before any answer arrives, and re-sending them would only make the
  answer heavier.

  Two passes over the model, both O(nodes), no resolution at request time:
  1. Every symbol declared in this model whose DeclNode names it in THIS file
     (an $I include's declarations belong to that document) - marked
     `declaration`. The name token is verified to spell the symbol's name, so
     a declaration node whose first token is a keyword (an anonymous
     `record ... end` in a type slot) emits nothing rather than colouring the
     keyword.
  2. Every nkIdent node, classified through RefMap (this unit) or ExtRefMap
     (another unit) - the same two maps TPasNavigator.ResolveSymbolAt reads.
     An unresolved name emits nothing and keeps the grammar's colour, which
     is the honest answer: the resolver does not know what it is either.
  A position both passes hit (the declaring nkIdent) is emitted once, the
  declaration winning - the sort key puts it first.

  Plus the $IFDEF'd-out regions of the file as `comment` tokens, one per line
  they cover (a token cannot span lines without multilineTokenSupport). That
  is the IDE's flat grey for dead code and the demo highlighter's precedent;
  nothing inside a skipped region is a visible token, so nothing there
  competes.

  No `full/delta`: it needs the previous answer kept per document and
  resultId, and VS Code already debounces and keeps the last colouring until
  a full answer arrives. Measured cost first, then decide; the range form is
  offered so a client that wants the viewport quickly can have it.

  Columns: token offsets are UTF-16 code units in PasTree (Start/Len into a
  Delphi string), which is exactly LSP's utf-16 positionEncoding, so no
  conversion beyond 1-based -> 0-based. }
{ Every semantic token of one document, sorted by position and deduplicated
  (a declaring nkIdent is hit by both passes; the declaration wins). Empty
  when the file is not in the closure or has no token layer. AInactive adds
  the $IFDEF'd-out lines as `comment` tokens - the semanticTokens answer
  wants them, a line's type spans do not. Shared by HandleSemanticTokens and
  LineTypeSpansJson (the result surfaces' type colouring). }
function TLspServer.CollectSemanticTokens(const APath: string;
  AInactive: Boolean): TArray<TSemanticToken>;
var
  LPath: string;
  LMid, LFileId, LIdx, LNode, LSymIdx, LResMid, LResSym, LCount: Integer;
  LModel: TPasSemaModel;
  LExt: TPasExtRef;
  LTokens: TList<TSemanticToken>;
  LTok: TSemanticToken;

  // The model's stream for the document's own file - the node token
  // positions are offsets into THIS text.
  function Stream: TPasTokenStream;
  begin
    Result := LModel.Tree.Source.Files[LFileId];
  end;

  // One identifier token for ANode, if it lies in this file and its symbol
  // (declared in model ASymMid) has a legend type. ADeclaration additionally
  // requires the token to spell the symbol's name (see the header).
  procedure AddIdent(ANode, ASymMid, ASymIdx: Integer; ADeclaration: Boolean);
  var
    LVisIdx, LType, LMods: Integer;
    LVis: TPasVisibleToken;
    LT: TPasToken;
    LSymModel: TPasSemaModel;
    LOne: TSemanticToken;
  begin
    if (ANode < 0) or (ANode > High(LModel.Tree.Nodes)) then
      Exit;
    LVisIdx := LModel.Tree.Nodes[ANode].FirstToken;
    if (LVisIdx < 0) or (LVisIdx > High(LModel.Tree.Source.Visible)) then
      Exit;
    LVis := LModel.Tree.Source.Visible[LVisIdx];
    if LVis.FileId <> LFileId then
      Exit;
    LSymModel := FProject.Model(ASymMid);
    if (LSymModel = nil) or (ASymIdx < 0) or
       (ASymIdx >= LSymModel.SymCount) then
      Exit;
    if not SemanticTypeOf(LSymModel.Symbols[ASymIdx], LType, LMods) then
      Exit;
    if (LVis.TokenIndex < 0) or (LVis.TokenIndex > High(Stream.Tokens)) then
      Exit;
    LT := Stream.Tokens[LVis.TokenIndex];
    if ADeclaration then
    begin
      if not Stream.TokenTextEquals(LT, LSymModel.Symbols[ASymIdx].Name) then
        Exit;
      LMods := LMods or SM_DECLARATION;
    end;
    Stream.OffsetToLineCol(LT.Start, LOne.Line, LOne.Col);
    LOne.Len := LT.Len;
    LOne.TokenType := LType;
    LOne.Modifiers := LMods;
    LTokens.Add(LOne);
  end;

  // The navigator's answer for the identifier at ANode's token - SymbolAt,
  // the Ctrl+Click resolution, by position, since the node-level resolver
  // is the navigator's private business. Only for nodes neither map knows.
  function NavResolve(ANode: Integer; out AMid, ASym: Integer): Boolean;
  var
    LVisIdx, LLine, LCol: Integer;
    LVis: TPasVisibleToken;
    LName: string;
  begin
    Result := False;
    if (FNav = nil) or (ANode < 0) or (ANode > High(LModel.Tree.Nodes)) then
      Exit;
    LVisIdx := LModel.Tree.Nodes[ANode].FirstToken;
    if (LVisIdx < 0) or (LVisIdx > High(LModel.Tree.Source.Visible)) then
      Exit;
    LVis := LModel.Tree.Source.Visible[LVisIdx];
    if (LVis.FileId <> LFileId) or (LVis.TokenIndex < 0) or
       (LVis.TokenIndex > High(Stream.Tokens)) then
      Exit;
    Stream.OffsetToLineCol(Stream.Tokens[LVis.TokenIndex].Start, LLine, LCol);
    Result := FNav.SymbolAt(LMid, LLine, LCol, AMid, ASym, LName);
  end;

  // A skipped ($IFDEF'd-out) region as comment tokens, one per covered line,
  // each clipped to its line's text (the break excluded).
  procedure AddInactive(const ARegion: TPasSkippedRegion);
  var
    LFirstLine, LFirstCol, LLastLine, LLastCol, LLine, LLineStart, LLineEnd,
      LFrom, LToExcl: Integer;
    LOne: TSemanticToken;
  begin
    if ARegion.EndPos <= ARegion.Start then
      Exit;
    Stream.OffsetToLineCol(ARegion.Start, LFirstLine, LFirstCol);
    Stream.OffsetToLineCol(ARegion.EndPos - 1, LLastLine, LLastCol);
    for LLine := LFirstLine to LLastLine do
    begin
      if (LLine < 1) or (LLine > Length(Stream.LineStarts)) then
        Break;
      LLineStart := Stream.LineStarts[LLine - 1];
      if LLine < Length(Stream.LineStarts) then
        LLineEnd := Stream.LineStarts[LLine]
      else
        LLineEnd := Length(Stream.Source);
      // Offset o is Source[o + 1]; LLineEnd is exclusive, so Source[LLineEnd]
      // is the last character of the line - a break character to drop.
      while (LLineEnd > LLineStart) and
            CharInSet(Stream.Source[LLineEnd], [#10, #13]) do
        Dec(LLineEnd);
      if LLine = LFirstLine then
        LFrom := LFirstCol
      else
        LFrom := 1;
      LToExcl := LLineEnd - LLineStart + 1;          // 1-based, exclusive
      if (LLine = LLastLine) and (LLastCol + 1 < LToExcl) then
        LToExcl := LLastCol + 1;
      if LToExcl <= LFrom then
        Continue;
      LOne.Line := LLine;
      LOne.Col := LFrom;
      LOne.Len := LToExcl - LFrom;
      LOne.TokenType := ST_COMMENT;
      LOne.Modifiers := 0;
      LTokens.Add(LOne);
    end;
  end;

begin
  Result := nil;
  if (FNav = nil) or (FProject = nil) then
    Exit;
  LMid := FNav.ModelIdOf(APath);
  if LMid < 0 then
    Exit;
  LModel := FProject.Model(LMid);
  if LModel = nil then
    Exit;
  // An open document is never demoted, but the request is legal for any
  // file in the closure - and a demoted model has no token layer to
  // position anything in.
  if LModel.Demoted then
    FProject.EnsureHydrated(LMid);
  if (Length(LModel.Tree.Source.Files) = 0) or
     (Length(LModel.Tree.Source.Visible) = 0) then
    Exit;

  // Which of the model's files IS this document - normally [0], the main
  // file, but a request for an $I include is a legal request too.
  LPath := TPath.GetFullPath(APath);
  LFileId := 0;
  for LIdx := 0 to High(LModel.Tree.Source.FileNames) do
    if SameText(TPath.GetFullPath(LModel.Tree.Source.FileNames[LIdx]), LPath)
    then
    begin
      LFileId := LIdx;
      Break;
    end;

  LTokens := TList<TSemanticToken>.Create;
  try
    // 1. declarations
    for LSymIdx := 0 to LModel.SymCount - 1 do
      if (LModel.Symbols[LSymIdx].DeclNode <> NIL_NODE) and
         (LModel.Symbols[LSymIdx].Name <> '') then
        AddIdent(LModel.Symbols[LSymIdx].DeclNode, LMid, LSymIdx, True);
    // 2. references
    for LNode := 0 to High(LModel.Tree.Nodes) do
    begin
      if LModel.Tree.Nodes[LNode].Kind <> nkIdent then
        Continue;
      LSymIdx := NIL_SYM;
      if LNode <= High(LModel.RefMap) then
        LSymIdx := LModel.RefMap[LNode];
      if LSymIdx <> NIL_SYM then
        AddIdent(LNode, LMid, LSymIdx, False)
      else if LModel.ExtRefMap.TryGetValue(LNode, LExt) then
        AddIdent(LNode, LExt.UnitId, LExt.Sym, False)
      // Neither map: the navigator's own resolution, which is what
      // Ctrl+Click does - it also knows the names the two maps do not
      // carry, a class header's heritage list first of all (`TDog =
      // class(TAnimal)` painted TAnimal in nothing on the first live run,
      // 2026-09-22, while the same name in a field's type coloured).
      else if NavResolve(LNode, LResMid, LResSym) then
        AddIdent(LNode, LResMid, LResSym, False);
    end;
    // 3. inactive code
    if AInactive and (LFileId <= High(LModel.Tree.Source.Skipped)) then
      for LIdx := 0 to High(LModel.Tree.Source.Skipped[LFileId]) do
        AddInactive(LModel.Tree.Source.Skipped[LFileId][LIdx]);

    // Source order; the declaration pass is symbol order and the skipped
    // regions come last, so sort - declarations first at a shared position,
    // which is what the duplicate filter keeps.
    LTokens.Sort(TComparer<TSemanticToken>.Construct(
      function(const A, B: TSemanticToken): Integer
      begin
        Result := A.Line - B.Line;
        if Result = 0 then
          Result := A.Col - B.Col;
        if Result = 0 then
          Result := (B.Modifiers and SM_DECLARATION) -
            (A.Modifiers and SM_DECLARATION);
      end));
    SetLength(Result, LTokens.Count);
    LCount := 0;
    LTok.Line := -1;
    LTok.Col := -1;
    for LIdx := 0 to LTokens.Count - 1 do
    begin
      if (LTokens[LIdx].Line = LTok.Line) and (LTokens[LIdx].Col = LTok.Col)
      then
        Continue;                                    // the duplicate filter
      LTok := LTokens[LIdx];
      Result[LCount] := LTok;
      Inc(LCount);
    end;
    SetLength(Result, LCount);
  finally
    LTokens.Free;
  end;
end;

{ The type names on one line of a file, as a JSON array of 1-based
  (column, length) pairs, flattened - `[5,7,15,7]` - for a result row's
  snippet; `[]` when the line names none. Every result surface (references,
  the Find All family, defines, rename) attaches one to each hit so the
  IDE's Messages rows can paint types like the editor does. The tokens of a
  file are collected ONCE per analysis and kept in FLineTokenCache - a
  search answers hundreds of hits in a handful of files, and the collection
  is a full pass over the model; the cache is dropped when the analysis is
  replaced (InvalidateAnalysis) or refreshed (PublishDiagnostics). }
function TLspServer.LineTypeSpansJson(const APath: string;
  ALine: Integer): string;
var
  LKey: string;
  LTokens: TArray<TSemanticToken>;
  LLo, LHi, LMid: Integer;
  LSB: TStringBuilder;
begin
  LKey := LowerCase(TPath.GetFullPath(APath));
  if FLineTokenCache = nil then
    FLineTokenCache := TDictionary<string, TArray<TSemanticToken>>.Create;
  if not FLineTokenCache.TryGetValue(LKey, LTokens) then
  begin
    LTokens := CollectSemanticTokens(APath, False);
    FLineTokenCache.Add(LKey, LTokens);
  end;
  // The first token of ALine, by binary search on the sorted array.
  LLo := 0;
  LHi := Length(LTokens);
  while LLo < LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if LTokens[LMid].Line < ALine then
      LLo := LMid + 1
    else
      LHi := LMid;
  end;
  LSB := TStringBuilder.Create;
  try
    LSB.Append('[');
    while (LLo < Length(LTokens)) and (LTokens[LLo].Line = ALine) do
    begin
      if LTokens[LLo].TokenType in [ST_TYPE, ST_CLASS, ST_ENUM, ST_INTERFACE,
         ST_STRUCT, ST_TYPE_PARAMETER] then
      begin
        if LSB.Length > 1 then
          LSB.Append(',');
        LSB.Append(LTokens[LLo].Col).Append(',').Append(LTokens[LLo].Len);
      end;
      Inc(LLo);
    end;
    LSB.Append(']');
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

{ A single-target answer (definition, declarationAt, typeDefinition) as a
  Location carrying its line's type spans - the Find References tab shows
  the declaration row from declarationAt, not from the references list
  (found on the first live run of the coloured rows, 2026-09-22: every
  row coloured but that one). }
function TLspServer.LocationWithTypes(const AFilePath: string;
  APasLine, APasCol, ALen: Integer): string;
begin
  Result := WithTypeSpans(LocationJson(AFilePath, APasLine, APasCol, ALen),
    LineTypeSpansJson(AFilePath, APasLine));
end;

function TLspServer.HandleSemanticTokens(const AMsg: TLspIncoming): string;
var
  LPath: string;
  LIdx, LFromLine, LToLine, LCount, LLspLine, LLspChar, LPrevLine,
    LPrevChar: Integer;
  LTokens: TArray<TSemanticToken>;
  LTok: TSemanticToken;
  LSB: TStringBuilder;
  LStart: UInt64;
  LIsRange: Boolean;
begin
  LStart := GetTickCount64;
  LIsRange := AMsg.Method.EndsWith('/range');
  LPath := DocPathOf(AMsg.Params);
  if LPath = '' then
    Exit(BuildError(AMsg.IdJson, LSP_INVALID_PARAMS,
      'semanticTokens: textDocument.uri required'));
  LFromLine := 0;
  LToLine := MaxInt;
  if LIsRange then
  begin
    LFromLine := AMsg.Params.GetValue<Integer>('range.start.line', 0);
    LToLine := AMsg.Params.GetValue<Integer>('range.end.line', MaxInt);
  end;
  if not WaitAnalyzed(LPath, AMsg.IdJson) then
    Exit(BuildError(AMsg.IdJson, LSP_REQUEST_CANCELLED, 'request cancelled'));
  if FNav = nil then
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  if FNav.ModelIdOf(LPath) < 0 then
  begin
    Log('semanticTokens: file not in the analyzed closure: ' + LPath);
    Exit(BuildResponse(AMsg.IdJson, 'null'));
  end;
  LTokens := CollectSemanticTokens(LPath, True);

  LSB := TStringBuilder.Create;
  try
    LSB.Append('{"data":[');
    LCount := 0;
    LPrevLine := 0;
    LPrevChar := 0;
    for LIdx := 0 to High(LTokens) do
    begin
      LTok := LTokens[LIdx];
      PasTreeToLsp(LTok.Line, LTok.Col, LLspLine, LLspChar);
      if (LLspLine < LFromLine) or (LLspLine > LToLine) then
        Continue;
      if LCount > 0 then
        LSB.Append(',');
      if LLspLine = LPrevLine then
        LSB.AppendFormat('0,%d,%d,%d,%d',
          [LLspChar - LPrevChar, LTok.Len, LTok.TokenType, LTok.Modifiers])
      else
        LSB.AppendFormat('%d,%d,%d,%d,%d',
          [LLspLine - LPrevLine, LLspChar, LTok.Len, LTok.TokenType,
           LTok.Modifiers]);
      LPrevLine := LLspLine;
      LPrevChar := LLspChar;
      Inc(LCount);
    end;
    LSB.Append(']}');
    Log(Format(AMsg.Method + ': %s -> %d tokens, %d ms',
      [TPath.GetFileName(LPath), LCount, GetTickCount64 - LStart]));
    Result := BuildResponse(AMsg.IdJson, LSB.ToString);
  finally
    LSB.Free;
  end;
end;

{ textDocument/documentHighlight - every occurrence of the symbol under the
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
  LRawTok: Integer;
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
  else if FNav.DefineAt(LMid, LPasLine, LPasCol, LName, LRawTok) then
    LHits := DefineHitsToRefs(FNav.FindDefineReferences(LName))
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

      { THE PROJECT IS THE ROOT, SO START ON IT - do not wait to be asked.

        Until now the first build was kicked off by whichever came first: a
        didOpen (HandleDidOpen's "nothing analyzed yet" clause) or a request
        reaching WaitAnalyzed. Both are the wrong moment for a client that
        opens a PROJECT rather than a folder of files: RAD Studio hands us the
        .dproj at project-open time and may send no didOpen at all until the
        user activates a tab, so the whole closure was parsed on the first
        Ctrl+Click - the one gesture that is then slow, and slow for a reason
        the user cannot see. The inputs are complete the moment initialize
        answered; `initialized` is the first point the spec allows us to act
        on them.

        SCHEDULED, NOT STARTED: the debounce window is what lets the didOpen
        burst most clients send right after `initialized` fold into this same
        build instead of superseding it with a second one. Only with a project
        configured - a document-roots session has nothing to analyze yet, and
        its first didOpen still starts the build as before. }
      if LMsg.Method = 'initialized' then
      begin
        if (FMainSource <> '') and (FProject = nil) and (FSession = nil) then
        begin
          Log('project configured - starting the initial analysis');
          ScheduleAnalysis('');
        end;
        Exit;
      end;
      if LMsg.Method = 'shutdown' then
      begin
        FShutdownSeen := True;
        InvalidateAnalysis;
        Exit(BuildResponse(LMsg.IdJson, 'null'));
      end;
      { AFTER shutdown, before exit: InvalidRequest, which the spec asks for
        and this server needs for its own sake. `shutdown` freed the project
        and the navigator on purpose, so a straggler request - editors do send
        them while tearing a session down - would walk into WaitAnalyzed with
        nothing analyzed, start a FULL rebuild of the project just
        invalidated, block the dispatcher for its whole duration and delay
        `exit` by that much. Everything it rebuilt is guaranteed garbage. }
      if FShutdownSeen then
      begin
        if LMsg.IsRequest then
          Exit(BuildError(LMsg.IdJson, LSP_INVALID_REQUEST,
            'server is shutting down'));
        Exit;   // notifications after shutdown are simply dropped
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
        Exit(HandleDefinition(LMsg, {ADeclarationOnly} False));
      if LMsg.Method = 'pastree/declarationAt' then
        Exit(HandleDefinition(LMsg, {ADeclarationOnly} True));
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
      if LMsg.Method = 'pastree/syncPrototypes' then
        Exit(HandleSyncPrototypes(LMsg));
      if LMsg.Method = 'pastree/annotateArgs' then
        Exit(HandleAnnotateArgs(LMsg));
      if LMsg.Method = 'pastree/units' then
        Exit(HandleUnits(LMsg));
      if LMsg.Method = 'pastree/unusedUses' then
        Exit(HandleUnusedUses(LMsg));
      if LMsg.Method = 'pastree/unreferencedUnits' then
        Exit(HandleUnreferencedUnits(LMsg));
      if LMsg.Method = 'pastree/usesRemoval' then
        Exit(HandleUsesRemoval(LMsg));
      if LMsg.Method = 'pastree/useUnit' then
        Exit(HandleUseUnit(LMsg));
      if LMsg.Method = 'textDocument/onTypeFormatting' then
        Exit(HandleOnTypeFormatting(LMsg));
      if LMsg.Method = 'textDocument/typeDefinition' then
        Exit(HandleTypeDefinition(LMsg));
      if LMsg.Method = 'textDocument/documentHighlight' then
        Exit(HandleDocumentHighlight(LMsg));
      if (LMsg.Method = 'textDocument/semanticTokens/full') or
         (LMsg.Method = 'textDocument/semanticTokens/range') then
        Exit(HandleSemanticTokens(LMsg));
      if LMsg.Method = 'textDocument/prepareRename' then
        Exit(HandlePrepareRename(LMsg));
      if LMsg.Method = 'textDocument/rename' then
        Exit(HandleRename(LMsg));
      if LMsg.Method = 'pastree/renamePlan' then
        Exit(HandleRenamePlan(LMsg));
      if LMsg.Method = 'pastree/findOverrides' then
        Exit(HandleFindOverrides(LMsg));
      if LMsg.Method = 'pastree/findImplementations' then
        Exit(HandleFindImplementations(LMsg));
      if LMsg.Method = 'pastree/findDescendants' then
        Exit(HandleFindDescendants(LMsg));
      if LMsg.Method = 'pastree/findAssignments' then
        Exit(HandleFindSites(LMsg, fskAssignments));
      if LMsg.Method = 'pastree/findCreations' then
        Exit(HandleFindSites(LMsg, fskCreations));
      if LMsg.Method = 'pastree/findDestructions' then
        Exit(HandleFindSites(LMsg, fskDestructions));
      if LMsg.Method = 'pastree/findDefines' then
        Exit(HandleFindDefines(LMsg));
      if LMsg.Method = 'pastree/definesAt' then
        Exit(HandleDefinesAt(LMsg));
      if LMsg.Method = 'pastree/dcuSource' then
        Exit(HandleDcuSource(LMsg));
      if LMsg.Method = 'pastree/projectChanged' then
        Exit(HandleProjectChanged(LMsg));
      if LMsg.Method = 'pastree/outline' then
        Exit(HandleOutline(LMsg));
      if LMsg.Method = 'pastree/outlineTarget' then
        Exit(HandleOutlineTarget(LMsg));
      if LMsg.Method = 'pastree/findAllAt' then
        Exit(HandleFindAllAt(LMsg));
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
      { THE CANCEL FRAME ITSELF, arriving in order behind the request it
        cancels. The reader thread already noted it the moment it was read -
        that is the whole reason the reader exists, since the dispatcher may
        be sitting inside an analysis wait - so there is nothing left to do
        here but FORGET the id. It matters: frames are dispatched in arrival
        order, so by now the request is answered and retired, and a cancel
        noted after that retire would otherwise sit in the set forever and
        reject a legitimate reuse of the id (JSON-RPC allows reuse after a
        response) with an instant, false -32800. }
      if LMsg.Method = '$/cancelRequest' then
      begin
        if LMsg.Params <> nil then
        begin
          var LCancelled := LMsg.Params.FindValue('id');
          if LCancelled <> nil then
            FCancels.Retire(LCancelled.ToJSON);
        end;
        Exit;
      end;
      if LMsg.Method.StartsWith('$/') then
        Exit;   // optional protocol extensions: droppable by spec

      if LMsg.IsRequest then
        Result := BuildError(LMsg.IdJson, LSP_METHOD_NOT_FOUND,
          'method not supported: ' + LMsg.Method);
    except
      on E: Exception do
      begin
        // The pending idle-fault count first, so the two are not interleaved
        // out of order - a request fault arriving mid-flood is a different
        // event from the flood, and the log has to keep them apart.
        FlushIdleFault;
        Log('EXCEPTION in ' + LMsg.Method + ': ' + E.ClassName + ': ' +
          E.Message + ' [' + StateLine + ']');
        if LMsg.IsRequest then
          Result := BuildError(LMsg.IdJson, LSP_INTERNAL_ERROR,
            E.ClassName + ': ' + E.Message)
        else
          Result := '';
      end;
    end;
  finally
    // Answered (or never will be) - late cancels for this id are meaningless.
    //
    // AND ONLY FOR A REQUEST WE HANDLED. IsRequest is just `IdJson <> ''`,
    // which is equally true of a RESPONSE from the client (an id and no
    // method) - our window/workDoneProgress/create being the one we send.
    // Server ids and client ids are both small integers from the same-looking
    // space, so retiring on a response would clear a genuine cancel for the
    // client request that happens to carry the same number and is still
    // queued behind us: that request then runs to completion, waiting out a
    // whole analysis, instead of being cancelled. Work lost, not answers.
    if LMsg.IsRequest and (LMsg.Method <> '') then
      FCancels.Retire(LMsg.IdJson);
    LMsg.Root.Free;
  end;
end;

end.
