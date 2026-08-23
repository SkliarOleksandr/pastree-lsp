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
  never read the project's defines at all. What the .dproj cannot supply is
  everything the IDE finds through its own Library configuration - RTL/VCL/
  ToolsAPI source and every third-party library on the Search/Browsing Path -
  so those are read from the IDE and passed as extra searchPaths. See
  GetIDELibraryPaths: getting that list wrong is indistinguishable, from the
  editor, from navigation being broken.

  WHERE THE SERVER LOG GOES. Next to the project being analyzed, as
  pastree-lsp.log (LogPathFor), with the server's stderr beside it. The log is
  the only place the real cause of a failed navigation appears - the editor only
  ever says "nothing resolved" - so it is deliberately somewhere a person will
  actually look, not a timestamped file in %TEMP%.
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
  /// One completion item, already in IDE coordinates. The replace span
  /// (Row/ColFrom..ColTo, 1-based, ColTo exclusive) is the partially-typed
  /// token the item replaces - the server always answers with a textEdit, so
  /// a consumer inserts by REPLACING that span with ItemLabel, never by
  /// appending at the caret (which would double the prefix already typed).
  /// </summary>
  TLspCompletionItem = record
    ItemLabel: string;
    Kind: Integer;      // LSP CompletionItemKind (14 = keyword, ...)
    Detail: string;     // display-verbatim, e.g. ': TStringList (+2)'
    // The routine's head keyword ('constructor', 'operator', ...) when the
    // server knows one - carried in the item's data field; '' otherwise.
    Head: string;
    // True for a routine declared WITH parameters - what auto-parenthesis
    // reads on accept.
    HasParams: Boolean;
    // The declaration's XMLDoc as DISPLAY text, already rendered by the
    // server (PasLsp.XmlDoc): what Help Insight shows for the selected row.
    // '' whenever the declaration carries no `///` block, which is most of
    // them - the viewer shows no documentation then.
    Doc: string;
    Row: Integer;
    ColFrom: Integer;
    ColTo: Integer;
  end;

  /// <summary>Same delivery contract as TLspHitsProc.</summary>
  TLspCompletionProc = reference to procedure(ASuccess: Boolean;
    const AItems: TArray<TLspCompletionItem>; const AError: string);

  TLspSignatureItem = record
    SigLabel: string;
    Params: TArray<string>;   // one label per individual parameter
  end;

  /// <summary>
  /// A signatureHelp answer in IDE coordinates. Valid=False means "the caret
  /// is not inside a call the server could resolve" - the parameter hint
  /// simply does not show, which is a legitimate answer, not an error.
  /// </summary>
  TLspSignatureHelp = record
    Valid: Boolean;
    Signatures: TArray<TLspSignatureItem>;
    ActiveSignature: Integer;
    ActiveParam: Integer;
    CallRow: Integer;   // the call's '(' - the hint window's anchor
    CallCol: Integer;
  end;

  TLspSignatureHelpProc = reference to procedure(ASuccess: Boolean;
    const AHelp: TLspSignatureHelp; const AError: string);

  /// <summary>
  /// One project-wide symbol for the IDE Insight (Ctrl+.) integration, in
  /// IDE coordinates. KindWord is display vocabulary ('function', 'type',
  /// ...), derived here so every consumer words it identically.
  /// </summary>
  TLspWorkspaceSymbol = record
    Name: string;
    KindWord: string;
    Container: string;   // the declaring unit's file name
    FilePath: string;
    Row: Integer;
    Col: Integer;
  end;

  TLspWorkspaceSymbolsProc = reference to procedure(ASuccess: Boolean;
    const ASymbols: TArray<TLspWorkspaceSymbol>; const AError: string);

  /// <summary>
  /// One node of a document's outline (textDocument/documentSymbol), in IDE
  /// coordinates. Children are the type's members, one level deep - the
  /// same shape the server builds.
  /// </summary>
  TLspDocSymbol = record
    Name: string;
    KindWord: string;
    Row: Integer;
    Col: Integer;
    Children: TArray<TLspDocSymbol>;
  end;

  TLspDocSymbolsProc = reference to procedure(ASuccess: Boolean;
    const ASymbols: TArray<TLspDocSymbol>; const AError: string);

  /// <summary>
  /// One diagnostic of an open document, in IDE coordinates (1-based row and
  /// columns, ColTo exclusive). Severity is LSP's: 1 error, 2 warning,
  /// 3 information/hint.
  /// </summary>
  TLspDiagnostic = record
    Row: Integer;
    ColFrom: Integer;
    ColTo: Integer;
    Severity: Integer;
    Text: string;
  end;

  /// <summary>
  /// Hover delivery: AText is PLAIN text ready for a tooltip - the session
  /// strips the server's markdown dressing (code fence, italics) so no
  /// caller renders markup. '' with ASuccess=True means "nothing under the
  /// cursor", the common case for any hover machinery.
  /// </summary>
  TLspHoverProc = reference to procedure(ASuccess: Boolean;
    const AText: string; const AError: string);

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
/// The Pascal decl&lt;-&gt;impl toggle: from a routine's header to its body
/// (AToImpl) or from anywhere inside the body back to its header. AOnDone
/// receives zero or one hit - zero is a legitimate answer, not a failure: a
/// routine declared only once has no other half.
///
/// Deliberately NOT definition. Definition asks "where is this name declared"
/// and follows a resolved reference across the closure; this asks about the
/// routine the cursor is standing in and never leaves the unit, because the
/// language puts the body there. Same distinction the server draws.
/// </summary>
procedure LspToggle(const AFileName: string; ARow, ACol: Integer;
  AToImpl: Boolean; const AOnDone: TLspHitsProc);

/// <summary>
/// Asks where the TYPE of the identifier at an IDE position is declared -
/// `var S: TStringList` on a use of S lands on TStringList's declaration,
/// crossing units. Zero or one hit; zero is legitimate (the identifier has
/// no resolvable type, e.g. a unit name or a keyword).
/// </summary>
procedure LspTypeDefinition(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHitsProc);

/// <summary>
/// Asks for APath's outline (unit-level declarations, types with their
/// members) - what the Structure pane shows.
/// </summary>
procedure LspDocumentSymbols(const AFileName: string;
  const AOnDone: TLspDocSymbolsProc);

/// <summary>
/// The last diagnostics the server PUSHED for APath (publishDiagnostics
/// arrives unsolicited after every analysis). False when the server never
/// reported for that file - distinct from an empty array, which means "it
/// reported: clean". Read by the painted-squiggle layer (ErrorPaint).
/// </summary>
function LspTryGetDiagnostics(const APath: string;
  out ADiags: TArray<TLspDiagnostic>): Boolean;

type
  TLspDiagnosticsChangedProc = reference to procedure(const APath: string);

/// <summary>
/// Registers the ONE listener called (main thread) right after each
/// publishDiagnostics lands in the cache - the painted-squiggle layer's
/// repaint trigger. nil unregisters. Deliberately single: the day a second
/// consumer exists, this becomes a list, not a second variable.
/// </summary>
procedure LspSetDiagnosticsChangedListener(
  const AListener: TLspDiagnosticsChangedProc);

/// <summary>
/// Pushes the live open-document texts to a RUNNING server - didChange for
/// whatever differs from the last sent text. The idle-typing hook behind
/// live diagnostics (PasTreeIdePlugin.IdleSync). No server, or one still in
/// its handshake, makes this a silent no-op: idle typing never STARTS a
/// server.
/// </summary>
procedure LspIdleSync;

/// <summary>
/// Asks for every project-level symbol matching AQuery ('' = all, capped and
/// logged server-side) - the data behind the IDE Insight (Ctrl+.) category.
/// The answer can be tens of thousands of records; callers cache it rather
/// than re-asking per keystroke (the Insight dialog filters locally).
/// </summary>
procedure LspWorkspaceSymbols(const AQuery: string;
  const AOnDone: TLspWorkspaceSymbolsProc);

/// <summary>
/// Asks which call encloses an IDE position and for its target's
/// signature(s) - the parameter-insight question (Ctrl+Shift+Space). A new
/// request supersedes an unanswered one, same as every other feature here.
/// </summary>
procedure LspSignatureHelp(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspSignatureHelpProc);

/// <summary>
/// Asks what is under an IDE position - the declaration's source line plus a
/// kind/location note, as tooltip-ready plain text. Feeds the Code Insight
/// manager's hint path (Tooltip Insight).
/// </summary>
procedure LspHover(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHoverProc);

/// <summary>
/// Asks for completion items at an IDE position - the plumbing half of
/// COMPLETION.md, ahead of any IDE surface that shows them (the Code Insight
/// manager is that surface, and it is gated until the server answers well).
/// Today the server's interim provider returns Delphi's reserved words
/// filtered by the typed prefix; the call shape will not change when PasTree
/// starts answering for real. A new request supersedes an unanswered one,
/// same as every other feature here.
/// </summary>
procedure LspCompletion(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspCompletionProc);

/// <summary>
/// Starts the server for the active project and lets its first analysis begin,
/// without any question to answer. Called when a project group finishes opening
/// and when the active project changes.
///
/// This exists because the analysis is the expensive part and it used to be
/// paid for by the user's first Ctrl+Click: on a 3757-unit project that is a
/// ~15 s wait at the worst possible moment. Starting at project open spends the
/// same time while nobody is waiting on an answer. It does NOT make the
/// analysis cheaper - the work is identical - and a project opened only to be
/// compiled now pays for an analysis nobody asked for. Deliberate: the wait it
/// removes is the one a person actually feels.
///
/// Safe to call when there is no project, no server on disk, or a session
/// already running. Nothing is queued: the server begins its build off the
/// didOpen catch-up (see TLspDocumentSync.ResendAll), so there is no request to
/// correlate and nothing to wait for.
///
/// SILENT when there is no active project - that is the normal state when this
/// package loads, and saying so in the Build tab would be reporting a non-event
/// (see Prewarm). A missing server exe is still reported.
/// </summary>
procedure LspPrewarm;

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
  System.Generics.Collections,
  System.Win.Registry,
  Winapi.Windows,
  PasTreeIdePlugin.LspClient,
  PasLsp.ProductVersion,
  PasLsp.SourceText,
  PasTreeIdePlugin.LspDocuments;

const
  // Persistent, so it can be left open in a tail across server restarts.
  cLspLogName = 'pastree-lsp.log';

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
    // Both directions of the decl<->impl toggle share one slot: they are the
    // same gesture, so a jump the other way supersedes an unanswered one.
    FPendingToggle: Int64;
    FPendingTypeDefinition: Int64;
    FPendingCompletion: Int64;
    FPendingHover: Int64;
    FPendingSignature: Int64;
    FPendingWorkspace: Int64;
    FPendingDocSymbols: Int64;
    // Path (lower-cased, full) -> the server's last publishDiagnostics for
    // it. Filled by the notification handler, read by the file-trait spike.
    FDiagnostics: TDictionary<string, TArray<TLspDiagnostic>>;
    FDestroying: Boolean;
    function BuildOptions(const AProject: IOTAProject;
      out APlatform, AConfig: string): TLspInitOptions;
    function EnsureSession: Boolean;
    procedure StoreDiagnostics(AParams: TJSONValue);
    procedure Ask(const AMethod: string; const AFileName: string;
      ARow, ACol: Integer; AIncludeDeclaration: Boolean;
      var APendingId: Int64; const AOnDone: TLspHitsProc);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Prewarm;
    procedure Definition(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspHitsProc);
    procedure References(const AFileName: string; ARow, ACol: Integer;
      AIncludeDeclaration: Boolean; const AOnDone: TLspHitsProc);
    procedure Toggle(const AFileName: string; ARow, ACol: Integer;
      AToImpl: Boolean; const AOnDone: TLspHitsProc);
    procedure TypeDefinition(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspHitsProc);
    procedure Completion(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspCompletionProc);
    procedure Hover(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspHoverProc);
    procedure SignatureHelp(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspSignatureHelpProc);
    procedure WorkspaceSymbols(const AQuery: string;
      const AOnDone: TLspWorkspaceSymbolsProc);
    procedure DocumentSymbols(const AFileName: string;
      const AOnDone: TLspDocSymbolsProc);
    function TryGetSentText(const APath: string; out AText: string): Boolean;
    function TryGetDiagnostics(const APath: string;
      out ADiags: TArray<TLspDiagnostic>): Boolean;
    procedure IdleSync;
  end;

var
  GSession: TLspSession;
  // The painted-squiggle layer's repaint trigger; see
  // LspSetDiagnosticsChangedListener.
  GDiagnosticsListener: TLspDiagnosticsChangedProc;

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
/// Where the server log goes: beside the project file, fixed name. See the
/// comment at the assignment in BuildOptions for why that beats %TEMP%.
/// </summary>
function LogPathFor(const AProjectFile: string): string;
var
  LDir: string;
begin
  LDir := ExtractFilePath(AProjectFile);
  if (LDir = '') or not TDirectory.Exists(LDir) then
    LDir := TPath.GetTempPath;
  Result := TPath.Combine(LDir, cLspLogName);
end;

/// <summary>
/// Every directory the IDE itself would search for source outside the project:
/// the Library <b>Search Path</b> and <b>Browsing Path</b> for APlatform, read
/// from the IDE's own configuration and macro-expanded.
///
/// THIS IS WHAT MAKES ANYTHING OUTSIDE THE PROJECT RESOLVE AT ALL, and an
/// earlier version of it got the shape wrong in a way worth recording. It
/// passed three fixed directories - source\rtl, source\vcl, source\ToolsAPI -
/// on the assumption that the RTL sources sit in source\rtl. They do not: they
/// sit in source\rtl\sys, \common, \win, \net, so System.SysUtils was NOT on
/// the search path, and neither was any third-party library the user had added
/// to the IDE (SynEdit, VirtualTreeView). The visible symptom was Ctrl+Click
/// answering "no identifier/declaration resolved at cursor" for practically
/// every type not declared in the project's own units, with the real cause
/// only in the server log as a wall of F1027 "Unit not found".
///
/// The two registry values together are exactly the right answer, and for two
/// distinct reasons: Browsing Path is where the IDE keeps the RTL/VCL/ToolsAPI
/// source subdirectories (its whole purpose is source the compiler does not
/// need but navigation does), and Search Path is where third-party source
/// lives. Read via IOTAServices.GetBaseRegistryKey rather than a hardcoded
/// key, so this follows whatever IDE version and installation the package is
/// loaded into.
/// </summary>
function GetIDELibraryPaths(const APlatform, AFallbackPlatform: string): TArray<string>;
var
  LServices: IOTAServices;
  LSeen: TDictionary<string, Byte>;
  LResult: TStringList;
  LReg: TRegistry;
  LKey, LRoot, LSubDir: string;
  LMacros, LNames: TStringList;

  /// <summary>
  /// $(name) expansion for one path. Three sources, in this order, because
  /// each covers what the previous cannot:
  ///   1. $(Platform) - not a variable at all, it is the platform the paths are
  ///      being read for.
  ///   2. The IDE's own "Environment Variables" overrides (Tools > Options >
  ///      Environment Variables). These are the ones a real installation
  ///      actually depends on - this machine resolves every third-party library
  ///      through a $(avi3rdlib) override - and they are IDE settings, not
  ///      process environment variables, so nothing outside the IDE's own
  ///      configuration knows them.
  ///   3. ExpandRootMacro for the built-ins ($(BDS), $(BDSLIB),
  ///      $(BDSCOMMONDIR), ...).
  /// Applied repeatedly because an override may itself be written in terms of
  /// another one; a fixed small bound rather than "until stable" so a variable
  /// defined in terms of itself cannot spin here.
  /// </summary>
  function ExpandMacros(const APath: string): string;
  var
    LPass, LIdx: Integer;
  begin
    Result := APath;
    for LPass := 1 to 4 do
    begin
      if not Result.Contains('$(') then
        Break;
      Result := StringReplace(Result, '$(Platform)', APlatform,
        [rfReplaceAll, rfIgnoreCase]);
      for LIdx := 0 to LMacros.Count - 1 do
        Result := StringReplace(Result,
          '$(' + LMacros.Names[LIdx] + ')', LMacros.ValueFromIndex[LIdx],
          [rfReplaceAll, rfIgnoreCase]);
      Result := LServices.ExpandRootMacro(Result);
    end;
  end;

  procedure AddPathList(const AValue: string);
  var
    LRaw, LPath: string;
  begin
    for LRaw in AValue.Split([';']) do
    begin
      LPath := Trim(LRaw);
      if LPath = '' then
        Continue;
      LPath := ExpandMacros(LPath);
      // An unexpanded macro left over means a variable we cannot resolve;
      // passing it on would just make the server look for a literal '$'.
      if LPath.Contains('$(') then
        Continue;
      // GetFullPath throws on a syntactically invalid path, and these lists
      // are hand-edited settings that accumulate junk over an installation's
      // life - one bad entry must cost that entry, not the whole path list.
      try
        LPath := ExcludeTrailingPathDelimiter(TPath.GetFullPath(LPath));
      except
        Continue;
      end;
      // Only real directories: same reason, plus every path the server accepts
      // is a directory it stats on each unit lookup.
      if not TDirectory.Exists(LPath) then
        Continue;
      if LSeen.ContainsKey(LowerCase(LPath)) then
        Continue;
      LSeen.Add(LowerCase(LPath), 0);
      LResult.Add(LPath);
    end;
  end;

begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;

  LSeen := TDictionary<string, Byte>.Create;
  LResult := TStringList.Create;
  LMacros := TStringList.Create;
  try
    LReg := TRegistry.Create(KEY_READ);
    try
      LReg.RootKey := HKEY_CURRENT_USER;

      // The user's own macro overrides, loaded before any path is expanded -
      // see ExpandMacros for why ExpandRootMacro alone is not enough.
      LMacros.NameValueSeparator := '=';
      LKey := IncludeTrailingPathDelimiter(LServices.GetBaseRegistryKey)
        + 'Environment Variables';
      if LReg.OpenKeyReadOnly(LKey) then
      begin
        LNames := TStringList.Create;
        try
          LReg.GetValueNames(LNames);
          for LSubDir in LNames do
            LMacros.Values[LSubDir] := LReg.ReadString(LSubDir);
        finally
          LNames.Free;
        end;
        LReg.CloseKey;
      end;

      LRoot := IncludeTrailingPathDelimiter(LServices.GetBaseRegistryKey)
        + 'Library\';
      LKey := LRoot + APlatform;
      // A platform the IDE offers but has no Library key for (never selected,
      // so never written) falls back to the folded name, which for the Win64
      // family is the same paths anyway.
      if not LReg.KeyExists(LKey) and (AFallbackPlatform <> '') then
        LKey := LRoot + AFallbackPlatform;
      if LReg.OpenKeyReadOnly(LKey) then
      begin
        // Browsing Path first: RTL/VCL/ToolsAPI source, i.e. the paths most
        // lookups will hit. Order is only a performance hint - the server
        // resolves a unit by the first path that has it, and a unit present on
        // both lists is the same file either way.
        AddPathList(LReg.ReadString('Browsing Path'));
        AddPathList(LReg.ReadString('Search Path'));
      end;
    finally
      LReg.Free;
    end;

    // Last resort if the configuration could not be read at all: the source
    // tree under the IDE root, enumerated rather than assumed flat (the bug
    // described above). Better than nothing, and nothing is what the previous
    // three-path version effectively gave for the RTL.
    if LResult.Count = 0 then
    begin
      LRoot := IncludeTrailingPathDelimiter(LServices.GetRootDirectory)
        + 'source';
      if TDirectory.Exists(LRoot) then
      begin
        AddPathList(LRoot);
        for LSubDir in TDirectory.GetDirectories(LRoot, '*',
          TSearchOption.soAllDirectories) do
          AddPathList(LSubDir);
      end;
    end;

    Result := LResult.ToStringArray;
  finally
    LMacros.Free;
    LResult.Free;
    LSeen.Free;
  end;
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
/// <summary>
/// The directory this BPL sits in - where a matched pastree-server.exe is
/// looked for. The path itself comes from PasLsp.ProductVersion.ThisBinaryPath,
/// which both halves of the product share.
/// </summary>
function PackageDir: string;
begin
  Result := ExtractFilePath(ThisBinaryPath);
end;

{ TLspSession }

constructor TLspSession.Create;
begin
  inherited Create;
  FExePath := FindServerExe(PackageDir);
  FDocs := nil;
  FClient := nil;
  // NOTHING IS ANNOUNCED HERE. This used to log "package <version>, built
  // <stamp>" on every package load, to distinguish "the fix is in" from "the
  // IDE is still running the BPL from before the rebuild" - a real distinction,
  // since rebuilding this package inside a live IDE session does not reliably
  // take effect. But it paid that cost on every single IDE start, to answer a
  // question nobody has except in the minutes after a rebuild, and the version
  // mismatch check at the handshake already catches the case that matters (a
  // fresh server against a stale package, which is what build.bat produces).
  // The build stamp now rides along with THAT warning, where it is actionable.
end;

destructor TLspSession.Destroy;
begin
  { Set BEFORE anything is freed. Freeing the client fails its outstanding
    requests, which invokes their callbacks; a callback that responds by asking
    another question would otherwise reach EnsureSession, find FClient already
    nil, and build a fresh client, document map and SERVER PROCESS from inside
    this destructor - leaving a live reader thread behind after
    FinalizeLspSession returns and the BPL unloads. That is precisely the crash
    class the teardown ordering in PasTreeIdePlugin.Wizard exists to prevent. }
  FDestroying := True;

  // Client first: it stops the server and joins the reader thread. The
  // document map is only state, but freeing it before the thread that could
  // still be delivering into this object would be the wrong order.
  FreeAndNil(FClient);
  FreeAndNil(FDocs);
  FreeAndNil(FDiagnostics);
  inherited;
end;

{ publishDiagnostics params -> the per-file cache: uri, then per diagnostic
  range.start/end (LSP 0-based) and severity/message. Diagnostics never span
  lines in this server; one that somehow did would degrade to its first
  line's tail. }
procedure TLspSession.StoreDiagnostics(AParams: TJSONValue);
var
  LUri, LPath: string;
  LArr: TJSONArray;
  LValue: TJSONValue;
  LDiags: TArray<TLspDiagnostic>;
  LDiag: TLspDiagnostic;
  LLine, LChar, LCount, LDummyRow: Integer;
begin
  if (AParams = nil) or
     not AParams.TryGetValue<string>('uri', LUri) then
    Exit;
  LPath := LspUriToPath(LUri);
  if LPath = '' then
    Exit;
  if not AParams.TryGetValue<TJSONArray>('diagnostics', LArr) then
    Exit;
  SetLength(LDiags, LArr.Count);
  LCount := 0;
  for LValue in LArr do
  begin
    LLine := LValue.GetValue<Integer>('range.start.line', -1);
    LChar := LValue.GetValue<Integer>('range.start.character', -1);
    if (LLine < 0) or (LChar < 0) then
      Continue;
    LspToIde(LLine, LChar, LDiag.Row, LDiag.ColFrom);
    LChar := LValue.GetValue<Integer>('range.end.character', LChar);
    LspToIde(LLine, LChar, LDummyRow, LDiag.ColTo);
    if LDiag.ColTo < LDiag.ColFrom then
      LDiag.ColTo := LDiag.ColFrom;
    LDiag.Severity := LValue.GetValue<Integer>('severity', 3);
    if (LDiag.Severity < 1) or (LDiag.Severity > 3) then
      LDiag.Severity := 3;
    LDiag.Text := LValue.GetValue<string>('message', '');
    LDiags[LCount] := LDiag;
    Inc(LCount);
  end;
  SetLength(LDiags, LCount);
  if FDiagnostics = nil then
    FDiagnostics := TDictionary<string, TArray<TLspDiagnostic>>.Create;
  FDiagnostics.AddOrSetValue(LowerCase(LPath), LDiags);
  if Assigned(GDiagnosticsListener) then
    GDiagnosticsListener(LPath);
end;

function TLspSession.TryGetDiagnostics(const APath: string;
  out ADiags: TArray<TLspDiagnostic>): Boolean;
begin
  ADiags := nil;
  Result := (FDiagnostics <> nil) and
    FDiagnostics.TryGetValue(LowerCase(APath), ADiags);
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
  // The IDE's own platform id, NOT the normalized one: the registry key and
  // the $(Platform) macro are named after what the IDE calls the platform
  // (Win64x has its own Library key), while APlatform has already been folded
  // onto the nearest name PasTree can parse.
  Result.SearchPaths := GetIDELibraryPaths(AProject.CurrentPlatform, APlatform);
  // NEXT TO THE PROJECT, under a fixed name - not %TEMP%. The log only earns
  // its keep if it is where someone looks: the same folder as the .dproj being
  // analyzed, so "which project was this" needs no timestamp archaeology, and
  // a stable name so it can be left open in a tail/editor across restarts. The
  // server appends with a separator per run rather than truncating, so history
  // survives too. Falls back to %TEMP% only for a project with no directory,
  // which in practice means an unsaved one.
  Result.LogFile := LogPathFor(Result.ProjectFile);
end;

function TLspSession.EnsureSession: Boolean;
var
  LProject: IOTAProject;
  LOptions: TLspInitOptions;
  LPlatform, LConfig: string;
begin
  Result := False;

  // Never resurrect a session that is being torn down - see Destroy.
  if FDestroying then
    Exit;

  if FExePath = '' then
  begin
    // Re-look each time: the user may have set PASTREE_LSP_SERVER or dropped
    // the exe next to the BPL since the last attempt, and a package reload is
    // an expensive way to pick that up.
    FExePath := FindServerExe(PackageDir);
    if FExePath = '' then
    begin
      if ServerExeOverride <> '' then
        // The variable is set and the file is not there. Naming the path is the
        // whole point: this is nearly always a typo or a moved build output,
        // and the generic message sends people to check the BPL directory that
        // is not even being looked at.
        LogDiagnostic(Format('%s points at "%s", which does not exist.',
          [cLspServerEnvVar, ServerExeOverride]))
      else
        LogDiagnostic(Format('%s not found next to the package''s BPL (%s) - '
          + 'put it there or point %s at it.',
          [cLspServerExeName, PackageDir, cLspServerEnvVar]));
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

    { publishDiagnostics is CACHED here for the painted-squiggle layer
      (PasTreeIdePlugin.ErrorPaint): the server pushes them after every
      analysis, unsolicited by design; the cache is the pull side PaintText
      reads and the listener hook is its repaint trigger. (The native
      IOTAModuleErrors route was spiked and ruled out 2026-08-22 - the
      module answers it natively inside the IDE, see SPEC.md's closed
      experiment.) Anything else the server starts notifying about surfaces
      in the Build tab instead of vanishing silently. }
    FClient.OnNotification :=
      procedure(const AMethod: string; AParams: TJSONValue)
      begin
        if AMethod = 'textDocument/publishDiagnostics' then
        begin
          StoreDiagnostics(AParams);
          Exit;
        end;
        LogDiagnostic('unhandled server notification: ' + AMethod);
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
  // Captured by the response closure. Initialised because a send that fails
  // synchronously invokes that closure from inside Request, before the
  // assignment below has run - it would otherwise read an undefined value.
  LIssuedId: Int64;
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

  LIssuedId := 0;
  LIssuedId := FClient.Request(AMethod, LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      { Clear the outstanding-request slot only if it still holds THIS request.

        A cancelled request is still answered - with an error - so answers
        arrive for requests that have already been superseded. Clearing
        unconditionally would wipe the id of the request that superseded this
        one, and the NEXT click would then find nothing to cancel: two
        definition requests would be in flight at once, and both would
        eventually call PushHistoryAndNavigate. The editor would jump to the
        stale target and push a bogus Backward/Forward entry alongside the real
        one. }
      // Dispatched by method rather than through the var parameter: an
      // anonymous method cannot capture a var parameter, which is what a
      // "clear whichever slot this was" closure would need.
      if AMethod = 'textDocument/definition' then
      begin
        if FPendingDefinition = LIssuedId then
          FPendingDefinition := 0;
      end
      else if AMethod = 'textDocument/references' then
      begin
        if FPendingReferences = LIssuedId then
          FPendingReferences := 0;
      end
      else if AMethod = 'textDocument/typeDefinition' then
      begin
        if FPendingTypeDefinition = LIssuedId then
          FPendingTypeDefinition := 0;
      end
      else
        // implementation / declaration - the toggle, one slot for both.
        if FPendingToggle = LIssuedId then
          FPendingToggle := 0;

      if ASuccess then
        AOnDone(True, ParseHits(AResult), '')
      else
        AOnDone(False, nil, AError);
    end);
  APendingId := LIssuedId;
end;

/// <summary>
/// A CompletionList (or a bare item array - both are legal result shapes)
/// into IDE-coordinate items. Items without a textEdit are dropped: OUR
/// server always sends one, so its absence means a server this plugin does
/// not match, and an item with no replace span cannot be inserted correctly
/// anyway (see TLspCompletionItem).
/// </summary>
function ParseCompletionItems(AResult: TJSONValue): TArray<TLspCompletionItem>;
var
  LItems: TJSONArray;
  LValue: TJSONValue;
  LObj, LRange, LStart, LEnd: TJSONObject;
  LItem: TLspCompletionItem;
  LLine, LChar, LEndLine, LEndChar, LDummyRow, LCount: Integer;
begin
  Result := nil;
  LItems := nil;
  if AResult is TJSONArray then
    LItems := TJSONArray(AResult)
  else if (AResult is TJSONObject) and
     not TJSONObject(AResult).TryGetValue<TJSONArray>('items', LItems) then
    Exit;
  if LItems = nil then
    Exit;

  // Counted growth: answers reach thousands of items, and appending managed
  // records one by one re-copies the whole array (with string refcounting)
  // per element.
  SetLength(Result, LItems.Count);
  LCount := 0;
  for LValue in LItems do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LObj := TJSONObject(LValue);
    LItem.ItemLabel := LObj.GetValue<string>('label', '');
    if LItem.ItemLabel = '' then
      Continue;
    LItem.Kind := LObj.GetValue<Integer>('kind', 0);
    LItem.Detail := LObj.GetValue<string>('detail', '');
    LItem.Head := LObj.GetValue<string>('data.head', '');
    LItem.HasParams := LObj.GetValue<Boolean>('data.hasParams', False);
    // documentation is markdown-shaped per LSP, but OUR server sends the
    // already-rendered display text (no emphasis markers - see the server's
    // PasLsp.XmlDoc), so it is taken verbatim. The plain-string form of the
    // field is honored too; anything else means no documentation.
    if not LObj.TryGetValue<string>('documentation.value', LItem.Doc) then
      LItem.Doc := LObj.GetValue<string>('documentation', '');
    if not LObj.TryGetValue<TJSONObject>('textEdit.range', LRange) or
       not LRange.TryGetValue<TJSONObject>('start', LStart) or
       not LRange.TryGetValue<TJSONObject>('end', LEnd) then
      Continue;
    LLine := LStart.GetValue<Integer>('line', -1);
    LChar := LStart.GetValue<Integer>('character', -1);
    LEndLine := LEnd.GetValue<Integer>('line', -1);
    LEndChar := LEnd.GetValue<Integer>('character', -1);
    // A multi-line replace span never comes out of completion; treat one as
    // the malformed answer it would be rather than guessing.
    if (LLine < 0) or (LChar < 0) or (LEndLine <> LLine) or
       (LEndChar < LChar) then
      Continue;
    LspToIde(LLine, LChar, LItem.Row, LItem.ColFrom);
    LspToIde(LEndLine, LEndChar, LDummyRow, LItem.ColTo);
    Result[LCount] := LItem;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

procedure TLspSession.Completion(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspCompletionProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
  LIssuedId: Int64;   // captured by the closure - same rule as in Ask
begin
  if not EnsureSession then
  begin
    AOnDone(False, nil, 'no LSP server available');
    Exit;
  end;

  // Fresh text first, then supersede the previous question - the same order
  // and the same reasons as Ask. Completion is the request this matters most
  // for: it fires while the user is actively typing.
  FDocs.Sync;
  if FPendingCompletion <> 0 then
    FClient.Cancel(FPendingCompletion);

  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);

  LIssuedId := 0;
  LIssuedId := FClient.Request('textDocument/completion', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      // Clear the slot only if it still holds THIS request - the stale-answer
      // guard Ask documents at length.
      if FPendingCompletion = LIssuedId then
        FPendingCompletion := 0;
      if ASuccess then
        AOnDone(True, ParseCompletionItems(AResult), '')
      else
        AOnDone(False, nil, AError);
    end);
  FPendingCompletion := LIssuedId;
end;

/// <summary>
/// The server's hover markdown as tooltip plain text. The shape is OUR
/// server's (one code fence plus an italic note line); anything else is
/// passed through as-is rather than parsed - a hint is display-only.
/// </summary>
function HoverPlainText(AResult: TJSONValue): string;
var
  LValue: string;
  LLines: TArray<string>;
  LIdx: Integer;
  LOut: string;
begin
  Result := '';
  if (AResult = nil) or AResult.Null then
    Exit;
  if not AResult.TryGetValue<string>('contents.value', LValue) then
    Exit;
  LLines := LValue.Replace(#13#10, #10).Split([#10]);
  LOut := '';
  for LIdx := 0 to High(LLines) do
  begin
    if LLines[LIdx].StartsWith('```') then
      Continue;   // fence markers carry no content
    if (LLines[LIdx].Length >= 2) and LLines[LIdx].StartsWith('_') and
       LLines[LIdx].EndsWith('_') then
      LLines[LIdx] := Copy(LLines[LIdx], 2, LLines[LIdx].Length - 2);
    if LLines[LIdx] = '' then
      Continue;
    if LOut <> '' then
      LOut := LOut + sLineBreak;
    LOut := LOut + LLines[LIdx];
  end;
  Result := LOut;
end;

procedure TLspSession.Hover(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHoverProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
  LIssuedId: Int64;   // captured by the closure - same rule as in Ask
begin
  if not EnsureSession then
  begin
    AOnDone(False, '', 'no LSP server available');
    Exit;
  end;

  FDocs.Sync;
  if FPendingHover <> 0 then
    FClient.Cancel(FPendingHover);

  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);

  LIssuedId := 0;
  LIssuedId := FClient.Request('textDocument/hover', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if FPendingHover = LIssuedId then
        FPendingHover := 0;
      if ASuccess then
        AOnDone(True, HoverPlainText(AResult), '')
      else
        AOnDone(False, '', AError);
    end);
  FPendingHover := LIssuedId;
end;

function ParseSignatureHelp(AResult: TJSONValue): TLspSignatureHelp;
var
  LSigs, LParams: TJSONArray;
  LValue, LPrm: TJSONValue;
  LSig: TLspSignatureItem;
  LLine, LChar, LCount, LPCount: Integer;
begin
  Result := Default(TLspSignatureHelp);
  if (AResult = nil) or AResult.Null then
    Exit;
  if not AResult.TryGetValue<TJSONArray>('signatures', LSigs) then
    Exit;
  SetLength(Result.Signatures, LSigs.Count);
  LCount := 0;
  for LValue in LSigs do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LSig.SigLabel := LValue.GetValue<string>('label', '');
    LSig.Params := nil;
    if LValue.TryGetValue<TJSONArray>('parameters', LParams) then
    begin
      SetLength(LSig.Params, LParams.Count);
      LPCount := 0;
      for LPrm in LParams do
      begin
        LSig.Params[LPCount] := LPrm.GetValue<string>('label', '');
        Inc(LPCount);
      end;
      SetLength(LSig.Params, LPCount);
    end;
    Result.Signatures[LCount] := LSig;
    Inc(LCount);
  end;
  SetLength(Result.Signatures, LCount);
  if LCount = 0 then
    Exit;
  Result.ActiveSignature := AResult.GetValue<Integer>('activeSignature', 0);
  Result.ActiveParam := AResult.GetValue<Integer>('activeParameter', 0);
  LLine := AResult.GetValue<Integer>('pastreeCall.line', -1);
  LChar := AResult.GetValue<Integer>('pastreeCall.character', -1);
  if (LLine >= 0) and (LChar >= 0) then
    LspToIde(LLine, LChar, Result.CallRow, Result.CallCol);
  Result.Valid := True;
end;

procedure TLspSession.SignatureHelp(const AFileName: string;
  ARow, ACol: Integer; const AOnDone: TLspSignatureHelpProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
  LIssuedId: Int64;   // captured by the closure - same rule as in Ask
begin
  if not EnsureSession then
  begin
    AOnDone(False, Default(TLspSignatureHelp), 'no LSP server available');
    Exit;
  end;

  FDocs.Sync;
  if FPendingSignature <> 0 then
    FClient.Cancel(FPendingSignature);

  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);

  LIssuedId := 0;
  LIssuedId := FClient.Request('textDocument/signatureHelp', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if FPendingSignature = LIssuedId then
        FPendingSignature := 0;
      if ASuccess then
        AOnDone(True, ParseSignatureHelp(AResult), '')
      else
        AOnDone(False, Default(TLspSignatureHelp), AError);
    end);
  FPendingSignature := LIssuedId;
end;

// LSP SymbolKind -> the display vocabulary the whole plugin words kinds in.
function WorkspaceKindWord(AKind: Integer): string;
begin
  case AKind of
    5:  Result := 'class';
    6:  Result := 'function';   // Method - one word for all routines here
    7:  Result := 'property';
    8:  Result := 'field';
    10: Result := 'enum';
    11: Result := 'interface';
    12: Result := 'function';
    13: Result := 'var';
    14: Result := 'const';
    18: Result := 'array';
    22: Result := 'value';
    23: Result := 'record';
  else
    Result := '';
  end;
end;

function ParseWorkspaceSymbols(AResult: TJSONValue):
  TArray<TLspWorkspaceSymbol>;
var
  LArr: TJSONArray;
  LValue: TJSONValue;
  LSym: TLspWorkspaceSymbol;
  LUri: string;
  LLine, LChar, LCount: Integer;
begin
  Result := nil;
  if not (AResult is TJSONArray) then
    Exit;
  LArr := TJSONArray(AResult);
  SetLength(Result, LArr.Count);
  LCount := 0;
  for LValue in LArr do
  begin
    LSym.Name := LValue.GetValue<string>('name', '');
    if LSym.Name = '' then
      Continue;
    LSym.KindWord := WorkspaceKindWord(LValue.GetValue<Integer>('kind', 0));
    LSym.Container := LValue.GetValue<string>('containerName', '');
    if not LValue.TryGetValue<string>('location.uri', LUri) then
      Continue;
    LSym.FilePath := LspUriToPath(LUri);
    LLine := LValue.GetValue<Integer>('location.range.start.line', -1);
    LChar := LValue.GetValue<Integer>('location.range.start.character', -1);
    if (LSym.FilePath = '') or (LLine < 0) or (LChar < 0) then
      Continue;
    LspToIde(LLine, LChar, LSym.Row, LSym.Col);
    Result[LCount] := LSym;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

function ParseDocSymbols(AArr: TJSONArray): TArray<TLspDocSymbol>;
var
  LValue: TJSONValue;
  LSym: TLspDocSymbol;
  LChildren: TJSONArray;
  LLine, LChar, LCount: Integer;
begin
  Result := nil;
  if AArr = nil then
    Exit;
  SetLength(Result, AArr.Count);
  LCount := 0;
  for LValue in AArr do
  begin
    LSym := Default(TLspDocSymbol);
    LSym.Name := LValue.GetValue<string>('name', '');
    if LSym.Name = '' then
      Continue;
    LSym.KindWord := WorkspaceKindWord(LValue.GetValue<Integer>('kind', 0));
    LLine := LValue.GetValue<Integer>('selectionRange.start.line', -1);
    LChar := LValue.GetValue<Integer>('selectionRange.start.character', -1);
    if (LLine < 0) or (LChar < 0) then
      Continue;
    LspToIde(LLine, LChar, LSym.Row, LSym.Col);
    if LValue.TryGetValue<TJSONArray>('children', LChildren) then
      LSym.Children := ParseDocSymbols(LChildren);
    Result[LCount] := LSym;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

procedure TLspSession.DocumentSymbols(const AFileName: string;
  const AOnDone: TLspDocSymbolsProc);
var
  LParams, LDoc: TJSONObject;
  LIssuedId: Int64;   // captured by the closure - same rule as in Ask
begin
  if not EnsureSession then
  begin
    AOnDone(False, nil, 'no LSP server available');
    Exit;
  end;

  FDocs.Sync;
  if FPendingDocSymbols <> 0 then
    FClient.Cancel(FPendingDocSymbols);

  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);

  LIssuedId := 0;
  LIssuedId := FClient.Request('textDocument/documentSymbol', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if FPendingDocSymbols = LIssuedId then
        FPendingDocSymbols := 0;
      if ASuccess and (AResult is TJSONArray) then
        AOnDone(True, ParseDocSymbols(TJSONArray(AResult)), '')
      else if ASuccess then
        AOnDone(True, nil, '')
      else
        AOnDone(False, nil, AError);
    end);
  FPendingDocSymbols := LIssuedId;
end;

procedure TLspSession.WorkspaceSymbols(const AQuery: string;
  const AOnDone: TLspWorkspaceSymbolsProc);
var
  LParams: TJSONObject;
  LIssuedId: Int64;   // captured by the closure - same rule as in Ask
begin
  if not EnsureSession then
  begin
    AOnDone(False, nil, 'no LSP server available');
    Exit;
  end;

  FDocs.Sync;
  if FPendingWorkspace <> 0 then
    FClient.Cancel(FPendingWorkspace);

  LParams := TJSONObject.Create;
  LParams.AddPair('query', AQuery);

  LIssuedId := 0;
  LIssuedId := FClient.Request('workspace/symbol', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if FPendingWorkspace = LIssuedId then
        FPendingWorkspace := 0;
      if ASuccess then
        AOnDone(True, ParseWorkspaceSymbols(AResult), '')
      else
        AOnDone(False, nil, AError);
    end);
  FPendingWorkspace := LIssuedId;
end;

procedure TLspSession.Prewarm;
var
  LProject: IOTAProject;
begin
  // NO PROJECT IS NORMAL HERE, AND MUST STAY SILENT. This package loads before
  // the IDE restores its project group, so the prewarm fired from TIDEWizard's
  // constructor routinely finds nothing - and EnsureSession would put "no
  // active project." in the Build tab for it. That message is exactly right for
  // a Ctrl+Click that did nothing and pure noise for a warm-up nobody asked
  // for; a panel that reports non-events is a panel people stop reading. The
  // ofnEndProjectGroupOpen notification arrives moments later and does the
  // real work.
  LProject := GetActiveProject;
  if not Assigned(LProject) then
    Exit;
  // The rest is EnsureSession: it spawns the server and issues the handshake,
  // and the analysis then starts off the didOpen catch-up that OnReady
  // performs. Nothing to pump - the transport marshals with TThread.Queue and
  // the IDE's own idle processing dispatches that - so this returns at once and
  // the build runs on the server's background session. A missing exe IS still
  // reported: that one is worth hearing at project open rather than at the
  // first navigation.
  EnsureSession;
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

procedure TLspSession.Toggle(const AFileName: string; ARow, ACol: Integer;
  AToImpl: Boolean; const AOnDone: TLspHitsProc);
const
  // Two LSP methods, not one: the server answers "where is the other half of
  // the routine I am standing in" in a specific direction. See its own
  // HandleToggle - these are pure CST walks that never cross units, unlike
  // definition, which follows a resolved reference anywhere in the closure.
  cMethod: array[Boolean] of string =
    ('textDocument/declaration', 'textDocument/implementation');
begin
  Ask(cMethod[AToImpl], AFileName, ARow, ACol, False, FPendingToggle, AOnDone);
end;

procedure TLspSession.TypeDefinition(const AFileName: string;
  ARow, ACol: Integer; const AOnDone: TLspHitsProc);
begin
  Ask('textDocument/typeDefinition', AFileName, ARow, ACol, False,
    FPendingTypeDefinition, AOnDone);
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

procedure LspPrewarm;
begin
  // Silent when there is no session: this is fired by an IDE event, not by a
  // user action, so there is nobody to tell and nothing they could do.
  if Assigned(GSession) then
    GSession.Prewarm;
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

procedure LspToggle(const AFileName: string; ARow, ACol: Integer;
  AToImpl: Boolean; const AOnDone: TLspHitsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.Toggle(AFileName, ARow, ACol, AToImpl, AOnDone);
end;

procedure LspTypeDefinition(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHitsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.TypeDefinition(AFileName, ARow, ACol, AOnDone);
end;

procedure LspCompletion(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspCompletionProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.Completion(AFileName, ARow, ACol, AOnDone);
end;

procedure LspHover(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspHoverProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, '', 'LSP session not initialized');
    Exit;
  end;
  GSession.Hover(AFileName, ARow, ACol, AOnDone);
end;

procedure LspDocumentSymbols(const AFileName: string;
  const AOnDone: TLspDocSymbolsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.DocumentSymbols(AFileName, AOnDone);
end;

function LspTryGetDiagnostics(const APath: string;
  out ADiags: TArray<TLspDiagnostic>): Boolean;
begin
  ADiags := nil;
  Result := Assigned(GSession) and GSession.TryGetDiagnostics(APath, ADiags);
end;

procedure LspSetDiagnosticsChangedListener(
  const AListener: TLspDiagnosticsChangedProc);
begin
  GDiagnosticsListener := AListener;
end;

procedure TLspSession.IdleSync;
begin
  // PASSIVE by design: pushes the live buffers to a server that is already
  // up and past its handshake, and starts nothing - idle typing must not
  // spawn a server the user never asked a question of. Requests keep their
  // own EnsureSession+Sync pairing.
  if (FClient <> nil) and FClient.IsReady and (FDocs <> nil) and
     not FDestroying then
    FDocs.Sync;
end;

procedure LspIdleSync;
begin
  if Assigned(GSession) then
    GSession.IdleSync;
end;

procedure LspWorkspaceSymbols(const AQuery: string;
  const AOnDone: TLspWorkspaceSymbolsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.WorkspaceSymbols(AQuery, AOnDone);
end;

procedure LspSignatureHelp(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspSignatureHelpProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, Default(TLspSignatureHelp), 'LSP session not initialized');
    Exit;
  end;
  GSession.SignatureHelp(AFileName, ARow, ACol, AOnDone);
end;

function LspSourceTextOf(const AFileName: string): string;
begin
  Result := '';
  if Assigned(GSession) and GSession.TryGetSentText(AFileName, Result) then
    Exit;
  // Never opened in an editor, so disk IS what the server read. Unreadable
  // yields '' and callers degrade to no snippet - see TryReadTextNoBom.
  if not TryReadTextNoBom(AFileName, Result) then
    Result := '';
end;

end.
