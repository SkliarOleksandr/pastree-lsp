unit PasTreeIdePlugin.LspSession;

{
  The package-lifetime LSP session: one server for the active project, the
  document sync that feeds it, and the two questions the features actually ask
  (declaration, references). This is what replaces
  PasTreeIdePlugin.Analysis.BuildNavigator - same role, opposite shape.

  THE SHAPE CHANGE IS THE WHOLE POINT, AND CALLERS FEEL IT. BuildNavigator
  returned an answer; these take a callback. Nothing here blocks the IDE's main
  thread waiting for the server, because that is the failure the out-of-process
  design exists to prevent (see the SingleThreaded comment in
  PasTreeIdePlugin.Analysis for what the in-process version had to promise
  instead). A feature must therefore be written to accept its answer on a later
  main-thread turn, and to cope with the editor having moved on meanwhile.

  ONE SERVER PER PROJECT CONFIGURATION. Switching the active project, platform
  or build configuration restarts the server with fresh initializationOptions
  rather than trying to reconfigure it in place: the server fixes its
  configuration at initialize, and one process per project is the spec's own
  model. EnsureSession does this check on every request, so a project switch
  costs the next navigation a restart and nothing else.

  WHAT THE SERVER IS TOLD. The .dproj itself, verbatim - the server evaluates
  it with the same MSBuild logic the CLI tools use (TPasDProj), so main source,
  search paths, defines, namespaces and unit aliases all come from the project
  file rather than being reconstructed here. That is strictly more than the
  in-process version managed: it had to resolve the real .dpr by convention and
  never read the project's defines at all. What the .dproj cannot supply is the
  IDE's own RTL/VCL/ToolsAPI source location, so that is passed as extra
  searchPaths.
}

interface

uses
  ToolsAPI;

type
  /// <summary>
  /// One navigation target, already in IDE coordinates (1-based row/column) so
  /// callers never see LSP's numbering.
  /// </summary>
  TLspHit = record
    FilePath: string;
    Row: Integer;
    Col: Integer;
  end;

  /// <summary>
  /// Delivered on the main thread, exactly once per request. On failure AHits
  /// is empty and AError says why - callers should report it rather than treat
  /// it as "nothing found", which is a different and legitimate answer
  /// (ASuccess=True with no hits).
  /// </summary>
  TLspHitsProc = reference to procedure(ASuccess: Boolean;
    const AHits: TArray<TLspHit>; const AError: string);

/// <summary>
/// Creates the session object. Call once from TIDEWizard.Create. Does NOT
/// start a server - that happens on the first request, so loading the package
/// costs nothing.
/// </summary>
procedure InitializeLspSession;

/// <summary>
/// Stops the server and frees the session. Call once from TIDEWizard.Destroy,
/// BEFORE the package unloads - the same rule that applies to the editor menu
/// action list and the Ctrl+Click notifier, and for a sharper reason here: a
/// live reader thread inside unloaded package code is an immediate crash.
/// </summary>
procedure FinalizeLspSession;

/// <summary>
/// Asks where the identifier at an IDE position is declared. AOnDone receives
/// zero or one hit.
/// </summary>
procedure LspDefinition(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHitsProc);

/// <summary>
/// Asks for every reference to the identifier at an IDE position. The
/// declaration site is included only if AIncludeDeclaration is set - the
/// server's own FindReferences never includes it on its own.
/// </summary>
procedure LspReferences(const AFileName: string; ARow, ACol: Integer;
  AIncludeDeclaration: Boolean; const AOnDone: TLspHitsProc);

/// <summary>
/// The text of AFileName as the server currently sees it: the live buffer we
/// last sent, or the file on disk if it was never open. Callers displaying a
/// line the server pointed at must use this and not read the file directly - a
/// buffer with unsaved edits has line numbers that only match the text the
/// server was given. Returns '' if neither source is available.
/// </summary>
function LspSourceTextOf(const AFileName: string): string;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  Winapi.Windows,
  PasTreeIdePlugin.LspClient,
  PasTreeIdePlugin.LspDocuments;

/// <summary>
/// Goes to the IDE's own default Messages tab (nil group = the "Build" tab),
/// tagged so it stays identifiable next to compiler output - the same
/// convention PasTreeIdePlugin.GotoDeclaration and .FindReferences already
/// use. No ShowMessageView: the server logs on start, restart and failure, and
/// forcing the panel open for that would be far more disruptive than useful.
/// </summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree-lsp] ' + AMessage);
end;

type
  TLspSession = class
  private
    FClient: TLspClient;
    FDocs: TLspDocumentSync;
    FExePath: string;
    // The configuration the running server was started for; a change means a
    // restart.
    FStartedProject: string;
    FStartedPlatform: string;
    FStartedConfig: string;
    // Outstanding request per feature, so a new one supersedes the old.
    FPendingDefinition: Int64;
    FPendingReferences: Int64;
    function BuildOptions(const AProject: IOTAProject;
      out APlatform, AConfig: string): TLspInitOptions;
    function EnsureSession: Boolean;
    procedure Ask(const AMethod: string; const AFileName: string;
      ARow, ACol: Integer; AIncludeDeclaration: Boolean;
      var APendingId: Int64; const AOnDone: TLspHitsProc);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Definition(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspHitsProc);
    procedure References(const AFileName: string; ARow, ACol: Integer;
      AIncludeDeclaration: Boolean; const AOnDone: TLspHitsProc);
    function TryGetSentText(const APath: string; out AText: string): Boolean;
  end;

var
  GSession: TLspSession;

{ ---------------------------------------------------------------------------
  ToolsAPI harvesting
  --------------------------------------------------------------------------- }

function GetActiveProject: IOTAProject;
var
  LModuleServices: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LGroup := LModuleServices.MainProjectGroup;
    if Assigned(LGroup) then
      Result := LGroup.ActiveProject;
  end;
end;

/// <summary>
/// RTL/VCL/ToolsAPI source directories, rooted at the IDE's own install
/// location (IOTAServices.GetRootDirectory - portable across machines and
/// versions, no hardcoded version number). The .dproj cannot supply these:
/// without them any identifier declared outside the project itself - anything
/// from the RTL or VCL, IOTAWizard, TActionList - fails to resolve, because
/// `uses` cannot find a unit there is no search path for.
/// </summary>
function GetIDESourcePaths: TArray<string>;
var
  LServices: IOTAServices;
  LRoot: string;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  LRoot := IncludeTrailingPathDelimiter(LServices.GetRootDirectory) + 'source\';
  Result := [LRoot + 'rtl', LRoot + 'vcl', LRoot + 'ToolsAPI'];
end;

/// <summary>
/// The active build configuration's name ('Debug', 'Release', ...), or '' if
/// it cannot be determined - in which case the server falls back to the
/// .dproj's own default, which is the right answer anyway.
/// </summary>
function GetActiveConfigName(const AProject: IOTAProject): string;
var
  LOptions: IOTAProjectOptionsConfigurations;
begin
  Result := '';
  if not Assigned(AProject) then
    Exit;
  if Supports(AProject.ProjectOptions, IOTAProjectOptionsConfigurations,
    LOptions) and Assigned(LOptions.ActiveConfiguration) then
    Result := LOptions.ActiveConfiguration.Name;
end;

/// <summary>
/// Folds the RAD Studio platform ids PasTree does not model onto the nearest
/// one it does, exactly as the in-process MapPlatform does - the server would
/// otherwise log "unknown platform" and silently default. Names PasTree knows
/// are passed through untouched and left for it to parse.
/// </summary>
function NormalizePlatformName(const APlatformId: string): string;
begin
  if SameText(APlatformId, 'Win64x') or SameText(APlatformId, 'WinARM64') or
     SameText(APlatformId, 'WinARM64EC') then
    Exit('Win64');
  Result := APlatformId;
end;

/// <summary>
/// Where the package's own BPL lives - the default place to look for
/// pastree-server.exe, so a matched pair can simply be deployed together.
/// </summary>
function PackageDir: string;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LLen: DWORD;
begin
  LLen := GetModuleFileName(HInstance, @LBuffer[0], Length(LBuffer));
  if LLen = 0 then
    Exit('');
  Result := ExtractFilePath(string(LBuffer));
end;

{ TLspSession }

constructor TLspSession.Create;
begin
  inherited Create;
  FExePath := FindServerExe(PackageDir);
  FDocs := nil;
  FClient := nil;
end;

destructor TLspSession.Destroy;
begin
  // Client first: it stops the server and joins the reader thread. The
  // document map is only state, but freeing it before the thread that could
  // still be delivering into this object would be the wrong order.
  FreeAndNil(FClient);
  FreeAndNil(FDocs);
  inherited;
end;

function TLspSession.BuildOptions(const AProject: IOTAProject;
  out APlatform, AConfig: string): TLspInitOptions;
begin
  Result := Default(TLspInitOptions);
  APlatform := NormalizePlatformName(AProject.CurrentPlatform);
  AConfig := GetActiveConfigName(AProject);
  // IOTAProject.FileName is the .dproj - which is exactly what we want here.
  // The in-process version had to resolve the real .dpr next to it by naming
  // convention because TPasParser cannot read a .dproj; the server reads it
  // properly and gets the project's defines and search paths with it.
  Result.ProjectFile := AProject.FileName;
  Result.Platform := APlatform;
  Result.Config := AConfig;
  Result.SearchPaths := GetIDESourcePaths;
  Result.LogFile := TPath.Combine(TPath.GetTempPath, 'pastree-lsp-server.log');
end;

function TLspSession.EnsureSession: Boolean;
var
  LProject: IOTAProject;
  LOptions: TLspInitOptions;
  LPlatform, LConfig: string;
begin
  Result := False;

  if FExePath = '' then
  begin
    // Re-look each time: the user may have set PASTREE_LSP_SERVER or dropped
    // the exe next to the BPL since the last attempt, and a package reload is
    // an expensive way to pick that up.
    FExePath := FindServerExe(PackageDir);
    if FExePath = '' then
    begin
      LogDiagnostic(Format('%s not found - put it next to the package''s BPL '
        + 'or point PASTREE_LSP_SERVER at it.', [cLspServerExeName]));
      Exit;
    end;
  end;

  LProject := GetActiveProject;
  if not Assigned(LProject) then
  begin
    LogDiagnostic('no active project.');
    Exit;
  end;

  LOptions := BuildOptions(LProject, LPlatform, LConfig);

  if not Assigned(FClient) then
  begin
    FClient := TLspClient.Create(FExePath, ExtractFilePath(FExePath),
      procedure(const AText: string)
      begin
        LogDiagnostic(AText);
      end);
    FDocs := TLspDocumentSync.Create(FClient);
    // A restarted server has no documents; re-open them before anything that
    // was queued behind the handshake gets answered from stale disk text.
    FClient.OnReady :=
      procedure
      begin
        FDocs.ResendAll;
      end;
  end;

  // A different project, platform or configuration means a different server:
  // the server fixes its configuration at initialize and cannot be retargeted.
  if (FClient.State = lcsStopped) or
     not SameText(FStartedProject, LOptions.ProjectFile) or
     not SameText(FStartedPlatform, LPlatform) or
     not SameText(FStartedConfig, LConfig) then
  begin
    if FClient.State <> lcsStopped then
      LogDiagnostic(Format('project configuration changed (%s %s %s) - '
        + 'restarting the server.',
        [ExtractFileName(LOptions.ProjectFile), LPlatform, LConfig]));
    FDocs.Forget;   // the old server's documents die with it
    if not FClient.Start(LOptions) then
      Exit;
    FStartedProject := LOptions.ProjectFile;
    FStartedPlatform := LPlatform;
    FStartedConfig := LConfig;
  end;

  Result := True;
end;

/// <summary>
/// Turns an LSP definition/references result into IDE-coordinate hits. The
/// server answers definition with a single Location (or null) and references
/// with an array, so both shapes are accepted here rather than at two call
/// sites.
/// </summary>
function ParseHits(AResult: TJSONValue): TArray<TLspHit>;

  function ParseOne(AObj: TJSONObject; out AHit: TLspHit): Boolean;
  var
    LRange, LStart: TJSONObject;
    LUri: string;
    LLine, LChar: Integer;
  begin
    Result := False;
    LUri := AObj.GetValue<string>('uri', '');
    if LUri = '' then
      Exit;
    if not AObj.TryGetValue<TJSONObject>('range', LRange) then
      Exit;
    if not LRange.TryGetValue<TJSONObject>('start', LStart) then
      Exit;
    LLine := LStart.GetValue<Integer>('line', -1);
    LChar := LStart.GetValue<Integer>('character', -1);
    if (LLine < 0) or (LChar < 0) then
      Exit;
    AHit.FilePath := LspUriToPath(LUri);
    if AHit.FilePath = '' then
      Exit;
    LspToIde(LLine, LChar, AHit.Row, AHit.Col);
    Result := True;
  end;

var
  LItem: TJSONValue;
  LHit: TLspHit;
begin
  Result := nil;
  if AResult is TJSONArray then
  begin
    for LItem in TJSONArray(AResult) do
      if (LItem is TJSONObject) and ParseOne(TJSONObject(LItem), LHit) then
        Result := Result + [LHit];
  end
  else if AResult is TJSONObject then
  begin
    if ParseOne(TJSONObject(AResult), LHit) then
      Result := [LHit];
  end;
  // A null result is "nothing here", which is a successful empty answer.
end;

procedure TLspSession.Ask(const AMethod: string; const AFileName: string;
  ARow, ACol: Integer; AIncludeDeclaration: Boolean; var APendingId: Int64;
  const AOnDone: TLspHitsProc);
var
  LParams, LDoc, LPos, LCtx: TJSONObject;
  LLine, LChar: Integer;
begin
  if not EnsureSession then
  begin
    AOnDone(False, nil, 'no LSP server available');
    Exit;
  end;

  // The editor's live text, as of right now - see the header of
  // PasTreeIdePlugin.LspDocuments on why this is pulled here instead of pushed
  // on every keystroke.
  FDocs.Sync;

  // A new question supersedes the old one: the user Ctrl+Clicked somewhere
  // else, and the previous answer is now noise the server can stop computing.
  if APendingId <> 0 then
    FClient.Cancel(APendingId);

  IdeToLsp(ARow, ACol, LLine, LChar);

  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);
  if AIncludeDeclaration then
  begin
    LCtx := TJSONObject.Create;
    LCtx.AddPair('includeDeclaration', TJSONBool.Create(True));
    LParams.AddPair('context', LCtx);
  end;

  APendingId := FClient.Request(AMethod, LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      // Whatever happens, this request is no longer outstanding - clearing it
      // before the callback means a callback that asks another question does
      // not cancel its own successor.
      if AMethod = 'textDocument/definition' then
        FPendingDefinition := 0
      else
        FPendingReferences := 0;
      if ASuccess then
        AOnDone(True, ParseHits(AResult), '')
      else
        AOnDone(False, nil, AError);
    end);
end;

procedure TLspSession.Definition(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHitsProc);
begin
  Ask('textDocument/definition', AFileName, ARow, ACol, False,
    FPendingDefinition, AOnDone);
end;

procedure TLspSession.References(const AFileName: string; ARow, ACol: Integer;
  AIncludeDeclaration: Boolean; const AOnDone: TLspHitsProc);
begin
  Ask('textDocument/references', AFileName, ARow, ACol, AIncludeDeclaration,
    FPendingReferences, AOnDone);
end;

function TLspSession.TryGetSentText(const APath: string;
  out AText: string): Boolean;
begin
  Result := Assigned(FDocs) and FDocs.TryGetSentText(APath, AText);
end;

{ ---------------------------------------------------------------------------
  Unit-level entry points
  --------------------------------------------------------------------------- }

procedure InitializeLspSession;
begin
  if not Assigned(GSession) then
    GSession := TLspSession.Create;
end;

procedure FinalizeLspSession;
begin
  FreeAndNil(GSession);
end;

procedure LspDefinition(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHitsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.Definition(AFileName, ARow, ACol, AOnDone);
end;

procedure LspReferences(const AFileName: string; ARow, ACol: Integer;
  AIncludeDeclaration: Boolean; const AOnDone: TLspHitsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.References(AFileName, ARow, ACol, AIncludeDeclaration, AOnDone);
end;

function LspSourceTextOf(const AFileName: string): string;
begin
  Result := '';
  if Assigned(GSession) and GSession.TryGetSentText(AFileName, Result) then
    Exit;
  // Never opened in an editor, so disk IS what the server read.
  try
    if TFile.Exists(AFileName) then
      Result := TFile.ReadAllText(AFileName);
  except
    Result := '';   // unreadable: callers degrade to no snippet
  end;
end;

end.
