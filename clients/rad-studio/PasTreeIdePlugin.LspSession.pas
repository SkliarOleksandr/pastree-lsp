unit PasTreeIdePlugin.LspSession;

{
  The package-lifetime LSP session: one server for the active project, the
  document sync that feeds it, and the two questions the features actually ask
  (declaration, references). This is what replaced the in-process
  BuildNavigator - same role, opposite shape. That unit
  (PasTreeIdePlugin.Analysis) no longer exists in this package: linking PasTree
  into a Win32 designtime BPL is the thing the whole out-of-process design was
  built to stop.

  THE SHAPE CHANGE IS THE WHOLE POINT, AND CALLERS FEEL IT. BuildNavigator
  returned an answer; these take a callback. Nothing here blocks the IDE's main
  thread waiting for the server, because that is the failure the out-of-process
  design exists to prevent - the in-process version had to promise a
  single-threaded analysis on the UI thread instead. A feature must therefore be written to accept its answer on a later
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
  pastree-lsp.log (LogPathFor), with the server's stderr appended INTO that
  same file (since 2026-08-24 - there is no sibling stderr file any more).
  The log is the only place the real cause of a failed navigation appears -
  the editor only ever says "nothing resolved" - so it is deliberately
  somewhere a person will actually look, not a timestamped file in %TEMP%.
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
    // The same documentation as an HTML fragment. This is what the viewer's
    // documentation surface wants: GetSymbolDocumentation is documented as
    // returning HTML (ToolsAPI.pas:8506), and so is the manager's
    // GetHelpInsightHtml (8864).
    DocHtml: string;
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
  /// One insertion of a class-completion answer, in IDE coordinates. Nothing
  /// is ever replaced - class completion only adds - so a row/col and the text
  /// to put there is the whole edit.
  /// </summary>
  TLspClassEditIde = record
    Row: Integer;
    Col: Integer;
    Text: string;
    Name: string;   // 'TFoo.Bar' - what the IDE reports as done
  end;

  /// <summary>
  /// The answer to pastree/classComplete. Edits arrive ASCENDING by position,
  /// which is the order an IOTAEditWriter can apply them in - it cannot move
  /// backward, and it is the tool to use here (see ApplyClassComplete). No
  /// edits with Success is the ordinary "everything is implemented already",
  /// and Provider says which it was.
  /// </summary>
  TLspClassComplete = record
    Edits: TArray<TLspClassEditIde>;
    CaretRow: Integer;
    CaretCol: Integer;
    Names: string;
    Provider: string;
  end;

  TLspClassCompleteProc = reference to procedure(ASuccess: Boolean;
    const AAnswer: TLspClassComplete; const AError: string);

  /// <summary>
  /// One edit from textDocument/onTypeFormatting, converted to IDE
  /// coordinates (1-based row/col): replace [Row,Col .. EndRow,EndCol) with
  /// Text. Equal ends mean a pure insertion.
  /// </summary>
  TLspTextEdit = record
    Row: Integer;
    Col: Integer;
    EndRow: Integer;
    EndCol: Integer;
    Text: string;
  end;

  TLspTextEditsProc = reference to procedure(ASuccess: Boolean;
    const AEdits: TArray<TLspTextEdit>; const AError: string);

  /// <summary>
  /// The answer to pastree/syncPrototypes: at most one REPLACEMENT (the other
  /// half of the routine under the caret) reusing TLspTextEdit, because a
  /// range with a real end is exactly what that record already is. No edits
  /// with Success is the ordinary outcome - already in step, an overload set,
  /// a declaration with no body yet - and Provider says which.
  /// </summary>
  TLspSyncPrototypes = record
    Edits: TArray<TLspTextEdit>;
    Name: string;      // 'TFoo.Bar' - the half that was rewritten
    Provider: string;
  end;

  TLspSyncPrototypesProc = reference to procedure(ASuccess: Boolean;
    const AAnswer: TLspSyncPrototypes; const AError: string);

  /// <summary>
  /// One replacement from a rename plan (pastree/renamePlan), already in IDE
  /// coordinates - and note that these arrive that way: unlike every other
  /// answer here, our own rename method reports PasTree's own 1-based
  /// line/column rather than LSP positions, precisely because a host that
  /// applies the edits itself works in editor coordinates.
  ///
  /// Row/Col/Len address the OLD identifier in the text the server was given.
  /// OldText is that exact text, for the "has the buffer moved since?" check
  /// every applier must make. NewText is what goes there - PER SITE, never
  /// the requested name: a UNIT rename legitimately writes the full dotted
  /// name at one site and the bare leaf at another. Snippet is the line as it
  /// reads AFTER every
  /// edit on that same line, with HiFrom/HiTo (0-based, into Snippet)
  /// spanning the NEW name - the preview that lets a results panel show the
  /// outcome rather than a promise.
  /// </summary>
  TLspRenameEdit = record
    FilePath: string;
    Row, Col: Integer;
    Len: Integer;
    OldText: string;
    NewText: string;
    IsDecl: Boolean;
    Snippet: string;
    HiFrom, HiTo: Integer;
  end;

  /// <summary>
  /// A whole rename, as planned by the analysis: what is being renamed, to
  /// what, and every site. Edits arrive sorted by (file, line, column), which
  /// is what lets an applier walk each file BACKWARDS - two edits on one line
  /// move each other whenever the name changes length.
  /// </summary>
  TLspRenamePlan = record
    OldName: string;
    NewName: string;
    { True when this renames a UNIT rather than a symbol, and then the four
      fields below are the part that has nothing to do with text: Object
      Pascal ties a unit's name to its FILE name, so RequiredFileName is
      what the file must be called afterwards, FilePath/NewFilePath are the
      rename to perform, and StaleInPaths lists the project files whose
      `uses ... in '...'` still spells the old file name. That last one has
      no edit in the plan at all - the literal has no position in the model
      - so a host must handle it or refuse; renaming the file through the
      IDE's own project API is what handles it here. }
    IsUnit: Boolean;
    RequiredFileName: string;
    FilePath: string;
    NewFilePath: string;
    StaleInPaths: TArray<string>;
    Edits: TArray<TLspRenameEdit>;
  end;

  /// <summary>Same delivery contract as TLspHitsProc.</summary>
  TLspRenamePlanProc = reference to procedure(ASuccess: Boolean;
    const APlan: TLspRenamePlan; const AError: string);

  /// <summary>
  /// The answer to prepareRename: the name to offer the user as the starting
  /// point, and nothing else. It is asked BEFORE the dialog rather than
  /// guessed from the text under the caret, because a UNIT's name may be
  /// dotted - `Namespace.Foo` is one name - and only the analysis knows the
  /// whole of it. AName is empty on failure, and AError then says why in a
  /// sentence written for the user.
  /// </summary>
  TLspRenameTargetProc = reference to procedure(ASuccess: Boolean;
    const AName: string; const AError: string);


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
  /// Hover delivery: AText is what the IDE's hint surface should show, and it
  /// is HTML whenever the server sent its own `pastreeHtml` page - which is
  /// the normal case, because the IDE's tooltip Help Insight is an HTML
  /// window (its stylesheet ships as ObjRepos\HelpInsight.css). Without that
  /// field - an older or foreign server - it falls back to the markdown card
  /// stripped to plain text, which renders as one collapsed paragraph there
  /// but still says the right words. '' with ASuccess=True means "nothing
  /// under the cursor", the common case for any hover machinery.
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
/// COMPLETION.md. The IDE surface that shows them is the Code Insight manager
/// (PasTreeIdePlugin.CodeInsight), registered and live. The server answers
/// from PasTree itself as of 2026-08-21 - the interim reserved-word provider
/// this used to describe is gone. A new request supersedes an unanswered one,
/// same as every other feature here.
/// </summary>
procedure LspCompletion(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspCompletionProc);

/// <summary>
/// Asks the server which declarations of a file have no implementation, and
/// for the text that would implement them (`pastree/classComplete` - our own
/// request, not an LSP method). Whole-file and position-free: the question has
/// one answer per buffer. The document is synced first, because the very
/// declaration the user wants a body for is the one they just typed.
/// </summary>
procedure LspClassComplete(const AFileName: string;
  const AOnDone: TLspClassCompleteProc);

/// <summary>
/// Prototype sync at a caret: the routine there, mirrored onto its other
/// half. One request, one answer, one edit at most - see PasLsp.SyncPrototypes
/// for what is mirrored and what is deliberately refused. The document is
/// synced first, for a sharper version of class completion's reason: the
/// signature it asks about was edited a keystroke ago.
/// </summary>
procedure LspSyncPrototypes(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspSyncPrototypesProc);

/// <summary>
/// textDocument/onTypeFormatting after Enter (the one trigger character the
/// server registers): the caret's NEW position goes in, zero or more
/// insertions come back - in practice zero or one, the missing block closer.
/// Zero edits with ASuccess=True is the ordinary "nothing to insert".
/// </summary>
procedure LspOnTypeFormatting(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspTextEditsProc);

/// <summary>
/// Plans a rename of the identifier at an IDE position: every site that
/// would change, plus a preview of each line as it would read afterwards.
/// Plans only - nothing is written; the caller applies the edits (see
/// PasTreeIdePlugin.Rename) and shows the result.
///
/// Failure here is normal and its message is for the USER: an invalid or
/// reserved new name, a unit name (a unit rename is a file rename plus
/// every uses clause - not this), or a compiler builtin with no declaration
/// to rename all come back as an error with a sentence saying so.
/// </summary>
procedure LspRenamePlan(const AFileName: string; ARow, ACol: Integer;
  const ANewName: string; const AOnDone: TLspRenamePlanProc);

/// <summary>
/// Asks whether the identifier at an IDE position can be renamed at all, and
/// under what name it is known - the question a rename dialog needs answered
/// before it can be shown. See TLspRenameTargetProc.
/// </summary>
procedure LspRenameTarget(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspRenameTargetProc);

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
/// A project (group) finished opening, or the active project changed. Prewarms
/// exactly as LspPrewarm does, and SAYS SO - in the Build tab and in the
/// server's own log.
///
/// Reopening the SAME project does not restart the server (its configuration
/// is unchanged, which is the whole point), so the "server ready" line that
/// otherwise marks a project coming up never appeared for it: the log ran
/// straight from the previous session's requests into the new one's with
/// nothing between them. That is where a reader needs a marker most, and it
/// was asked for on 2026-08-29 after exactly that confusion.
/// </summary>
procedure LspProjectOpened;

/// <summary>
/// The project group is closing. Logs which project went away, on both sides,
/// and leaves the server running: the same project reopening then costs
/// nothing, where stopping it would buy back memory at the price of the full
/// closure analysis on every open.
/// </summary>
procedure LspProjectClosed;

/// <summary>
/// Pushes the current editor buffers to the server now, instead of waiting for
/// the next request to do it on the way past.
///
/// Every feature here syncs before it asks a question, so this exists for the
/// one thing that CHANGES buffers rather than reading them: after a rename the
/// server's picture is stale and nothing would correct it until the user
/// happened to navigate. Harmless to call at any time - the sync sends only
/// what actually moved.
/// </summary>
procedure LspSyncDocuments;


/// <summary>
/// Writes one line into the SERVER's log (pastree-lsp.log), not the Build tab.
/// For findings worth keeping but not worth interrupting anybody with - a
/// capability readout, a probe result: the kind of thing that answers a
/// question weeks later and is pure noise in a panel the user watches while
/// working.
///
/// False = there was no ready server to write through, so nothing was
/// recorded. A caller that reports once per session should treat that as "not
/// yet" and ask again rather than marking itself done.
/// </summary>
function LspLogToServer(const AText: string): Boolean;

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
  PasTreeIdePlugin.CrashLog,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings;

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
    // WHICH PROJECT THE "server ready" LINE HAS ALREADY BEEN PRINTED FOR.
    //
    // Not the same question as FStartedProject, which is about the SERVER: one
    // project open is one line, but the IDE announces an open more than once.
    // ofnEndProjectGroupOpen and ofnActiveProjectChanged both mean "a project
    // came up" and both have to be acted on - the second is the only signal
    // for switching projects inside a group - so the notifier cannot tell them
    // apart, and the IDE sends several on one reopen. Three identical lines in
    // the Build tab is what that looked like (2026-09-02), and only on the
    // SECOND open of a session: the first found the server not yet ready, so
    // every duplicate suppressed itself through LWasReady by accident.
    FAnnouncedProject: string;
    // The two log switches the running server was started with. They are part
    // of that configuration for the same reason the platform is: the server
    // fixes both at initialize, so changing one in the dialog only means
    // anything if it restarts - which is what including them here does.
    FStartedLogFile: string;
    FStartedLogDetail: Boolean;
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
    procedure ProjectOpened;
    procedure ProjectClosed;
    procedure SyncDocuments;
    function LogToServer(const AText: string): Boolean;
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
    procedure ClassComplete(const AFileName: string;
      const AOnDone: TLspClassCompleteProc);
    procedure SyncPrototypes(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspSyncPrototypesProc);
    procedure OnTypeFormatting(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspTextEditsProc);
    procedure RenamePlan(const AFileName: string; ARow, ACol: Integer;
      const ANewName: string; const AOnDone: TLspRenamePlanProc);
    procedure RenameTarget(const AFileName: string; ARow, ACol: Integer;
      const AOnDone: TLspRenameTargetProc);
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

  /// <summary>
  /// TRegistry.ReadString RAISES for a value that is absent or is not a string
  /// - it is not a returns-empty API - and every caller here wants '' for
  /// "not configured". The surrounding code is already hardened against
  /// hand-edited settings (see AddPathList); this is the same hazard one level
  /// up. KeyExists/OpenKeyReadOnly answer for the KEY only, so a
  /// `Library\&lt;platform&gt;` that exists without a 'Search Path' - a pruned
  /// or half-written key - used to throw ERegistryException straight out of
  /// BuildOptions, through EnsureSession, into the ToolsAPI action handler:
  /// an IDE error dialog on every attempt to navigate, and no session.
  /// </summary>
  function ReadStringOrEmpty(AReg: TRegistry; const AName: string): string;
  begin
    try
      if AReg.ValueExists(AName) then
        Result := AReg.ReadString(AName)
      else
        Result := '';
    except
      Result := '';   // present but not a REG_SZ: unusable either way
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
            LMacros.Values[LSubDir] := ReadStringOrEmpty(LReg, LSubDir);
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
        AddPathList(ReadStringOrEmpty(LReg, 'Browsing Path'));
        AddPathList(ReadStringOrEmpty(LReg, 'Search Path'));
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

{ WHICH RAD STUDIO IS RUNNING THIS, to the update - "13.0" and "13.1" are one
  installation directory (Studio\37.0) and one $(BDS), so nothing already in
  the server log tells them apart. The file version of the host executable
  does, and the host executable is bds.exe: this code runs inside it, so
  ParamStr(0) names it without a registry lookup or a ToolsAPI call.

  It exists because of the 2026-09-02 report: an access violation on someone
  else's machine, same product version, and the first hour went to
  establishing what was different about the host. The answer belongs in the
  log the user already sends, not in a round of questions.

  Every failure here returns what it has rather than raising. This decorates
  a log line - a session must not fail to start because a version resource
  could not be read. }
function HostDescription: string;
var
  LExe: string;
  LSize, LHandle: DWORD;
  LBuf: TBytes;
  LInfo: PVSFixedFileInfo;
  LLen: UINT;
begin
  LExe := ParamStr(0);
  Result := ExtractFileName(LExe);
  LSize := GetFileVersionInfoSize(PChar(LExe), LHandle);
  if LSize = 0 then
    Exit;
  SetLength(LBuf, LSize);
  if not GetFileVersionInfo(PChar(LExe), LHandle, LSize, LBuf) then
    Exit;
  if not VerQueryValue(LBuf, '\', Pointer(LInfo), LLen) then
    Exit;
  if (LInfo = nil) or (LLen < SizeOf(TVSFixedFileInfo)) then
    Exit;
  Result := Format('%s %d.%d.%d.%d',
    [Result,
     HiWord(LInfo.dwFileVersionMS), LoWord(LInfo.dwFileVersionMS),
     HiWord(LInfo.dwFileVersionLS), LoWord(LInfo.dwFileVersionLS)]);
end;

function TLspSession.BuildOptions(const AProject: IOTAProject;
  out APlatform, AConfig: string): TLspInitOptions;
var
  LLogPath: string;
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
  Result.Host := HostDescription;
  // The IDE's own platform id, NOT the normalized one: the registry key and
  // the $(Platform) macro are named after what the IDE calls the platform
  // (Win64x has its own Library key), while APlatform has already been folded
  // onto the nearest name PasTree can parse.
  Result.SearchPaths := GetIDELibraryPaths(AProject.CurrentPlatform, APlatform);
  // THE SAME LIST, sent again under its other meaning, and that is not
  // redundancy. As searchPaths it says "look here to resolve a unit"; as
  // libraryPaths it says "these files are not the user's to rewrite". The
  // project's own directories reach the server from the .dproj instead and
  // are deliberately absent here - they are exactly the files a rename is
  // FOR. Keeping the two in step is the point of assigning them together.
  Result.LibraryPaths := Result.SearchPaths;
  // NEXT TO THE PROJECT, under a fixed name - not %TEMP%. The log only earns
  // its keep if it is where someone looks: the same folder as the .dproj being
  // analyzed, so "which project was this" needs no timestamp archaeology, and
  // a stable name so it can be left open in a tail/editor across restarts. The
  // server appends with a separator per run rather than truncating, so history
  // survives too. Falls back to %TEMP% only for a project with no directory,
  // which in practice means an unsaved one.
  LLogPath := LogPathFor(Result.ProjectFile);
  // "Enable logging" off means the server is told nothing about a log file,
  // which is how it already understands "no log" - no file is created, and
  // nothing is written and thrown away. The path is still computed, because
  // the crash log below needs the folder either way.
  if LoggingEnabled then
    Result.LogFile := LLogPath;
  Result.SuppressLogDetail := not AdvancedLoggingEnabled;
  // The IDE-side crash log goes to the same folder (its own file - see
  // PasTreeIdePlugin.CrashLog): the two are read together, and this is the
  // one place that already knows where "beside this project" is. NOT gated on
  // the logging switch - a fault in the IDE is not diagnostic chatter, and a
  // user who turned the log off did not ask to lose the record of a crash.
  SetCrashLogPath(LLogPath);
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
  // SILENTLY. EnsureSession is the gate in front of EVERY request, and most
  // requests are not user actions: the outline asks on each tab activation,
  // the idle sync on each pause. During IDE startup those fire while the
  // project group is still loading, so "no active project." landed in the
  // Build tab before the user had done anything - reported as noise on
  // 2026-08-29, and rightly. Nothing is lost: a click that resolved nothing
  // still says so where the user is looking (the editor), and the failures
  // worth a panel line - a missing server exe - are reported above.
  if not Assigned(LProject) then
    Exit;

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
     not SameText(FStartedConfig, LConfig) or
     not SameText(FStartedLogFile, LOptions.LogFile) or
     (FStartedLogDetail <> not LOptions.SuppressLogDetail) then
  begin
    if FClient.State <> lcsStopped then
      LogDiagnostic(Format('project configuration changed (%s %s %s) - '
        + 'restarting the server.',
        [ExtractFileName(LOptions.ProjectFile), LPlatform, LConfig]));
    FDocs.Forget;   // the old server's documents die with it
    { RECORDED BEFORE THE START, NOT AFTER IT, and the difference is a whole
      restart policy.

      Start resets the client's attempt counter and backoff on purpose - a new
      configuration deserves a fresh five tries. But when the spawn itself
      fails (the exe is there and locked, or corrupt, or the wrong
      architecture) Start returns False, and leaving these three unset meant
      SameText never matched again: every Ctrl+Click, every outline activation,
      every hover re-entered this branch, called Start, and zeroed the counter
      it had just incremented. Five-attempts-and-give-up and the exponential
      backoff never engaged for this whole class of failure, and the Build tab
      collected one false 'project configuration changed - restarting' per
      retry. Recording the target we ASKED for leaves the retry where it
      belongs: TLspClient.EnsureStarted, which paces it. }
    FStartedProject := LOptions.ProjectFile;
    FStartedPlatform := LPlatform;
    FStartedConfig := LConfig;
    FStartedLogFile := LOptions.LogFile;
    FStartedLogDetail := not LOptions.SuppressLogDetail;
    if not FClient.Start(LOptions) then
      Exit;
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
    LItem.DocHtml := LObj.GetValue<string>('data.docHtml', '');
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

/// <summary>
/// A pastree/classComplete answer into IDE coordinates. An edit without a
/// range is dropped for the same reason a completion item without a textEdit
/// is: our server always sends one, so its absence means a server this plugin
/// does not match.
/// </summary>
function ParseClassComplete(AResult: TJSONValue): TLspClassComplete;
var
  LEdits: TJSONArray;
  LValue: TJSONValue;
  LObj, LStart: TJSONObject;
  LEdit: TLspClassEditIde;
  LLine, LChar, LCount: Integer;
begin
  Result := Default(TLspClassComplete);
  if not (AResult is TJSONObject) then
    Exit;
  Result.Names := AResult.GetValue<string>('names', '');
  Result.Provider := AResult.GetValue<string>('provider', '');
  LLine := AResult.GetValue<Integer>('caret.line', -1);
  LChar := AResult.GetValue<Integer>('caret.character', -1);
  if (LLine >= 0) and (LChar >= 0) then
    LspToIde(LLine, LChar, Result.CaretRow, Result.CaretCol);
  if not AResult.TryGetValue<TJSONArray>('edits', LEdits) then
    Exit;
  SetLength(Result.Edits, LEdits.Count);
  LCount := 0;
  for LValue in LEdits do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LObj := TJSONObject(LValue);
    if not LObj.TryGetValue<TJSONObject>('range.start', LStart) then
      Continue;
    LLine := LStart.GetValue<Integer>('line', -1);
    LChar := LStart.GetValue<Integer>('character', -1);
    if (LLine < 0) or (LChar < 0) then
      Continue;
    LspToIde(LLine, LChar, LEdit.Row, LEdit.Col);
    LEdit.Text := LObj.GetValue<string>('newText', '');
    LEdit.Name := LObj.GetValue<string>('name', '');
    if LEdit.Text = '' then
      Continue;
    Result.Edits[LCount] := LEdit;
    Inc(LCount);
  end;
  SetLength(Result.Edits, LCount);
end;

procedure TLspSession.ClassComplete(const AFileName: string;
  const AOnDone: TLspClassCompleteProc);
var
  LParams, LDoc: TJSONObject;
begin
  if not EnsureSession then
  begin
    AOnDone(False, Default(TLspClassComplete), 'no LSP server available');
    Exit;
  end;
  // Sync FIRST and unconditionally: unlike every other request here, this one
  // exists BECAUSE the buffer just changed, and an answer computed from the
  // previous text would implement the wrong set.
  FDocs.Sync;
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  // No supersede slot: this is a deliberate keystroke, not a stream of
  // per-character questions, and two presses mean two answers.
  FClient.Request('pastree/classComplete', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if ASuccess then
        AOnDone(True, ParseClassComplete(AResult), '')
      else
        AOnDone(False, Default(TLspClassComplete), AError);
    end);
end;

{ The answer to pastree/syncPrototypes. One shape, parsed once - the edit's
  END matters here in a way class completion's never did: this request
  REPLACES a header, so an answer whose range end was dropped would delete
  nothing and insert a second copy of the signature. }
function ParseSyncPrototypes(AResult: TJSONValue): TLspSyncPrototypes;
var
  LEdits: TJSONArray;
  LValue: TJSONValue;
  LObj: TJSONObject;
  LEdit: TLspTextEdit;
  LLine, LChar: Integer;
begin
  Result := Default(TLspSyncPrototypes);
  if not (AResult is TJSONObject) then
    Exit;
  Result.Provider := AResult.GetValue<string>('provider', '');
  if not AResult.TryGetValue<TJSONArray>('edits', LEdits) then
    Exit;
  for LValue in LEdits do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LObj := TJSONObject(LValue);
    LLine := LObj.GetValue<Integer>('range.start.line', -1);
    LChar := LObj.GetValue<Integer>('range.start.character', -1);
    LEdit.Text := LObj.GetValue<string>('newText', '');
    if (LLine < 0) or (LChar < 0) or (LEdit.Text = '') then
      Continue;
    LspToIde(LLine, LChar, LEdit.Row, LEdit.Col);
    LLine := LObj.GetValue<Integer>('range.end.line', LLine);
    LChar := LObj.GetValue<Integer>('range.end.character', LChar);
    LspToIde(LLine, LChar, LEdit.EndRow, LEdit.EndCol);
    Result.Edits := Result.Edits + [LEdit];
    if Result.Name = '' then
      Result.Name := LObj.GetValue<string>('name', '');
  end;
end;

procedure TLspSession.SyncPrototypes(const AFileName: string;
  ARow, ACol: Integer; const AOnDone: TLspSyncPrototypesProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
begin
  if not EnsureSession then
  begin
    AOnDone(False, Default(TLspSyncPrototypes), 'no LSP server available');
    Exit;
  end;
  // Sync FIRST and unconditionally, for ClassComplete's reason and more
  // sharply: the signature this asks about was edited a keystroke ago, and an
  // answer computed from the previous text would mirror the OLD one back over
  // the user's change.
  FDocs.Sync;
  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);
  FClient.Request('pastree/syncPrototypes', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if ASuccess then
        AOnDone(True, ParseSyncPrototypes(AResult), '')
      else
        AOnDone(False, Default(TLspSyncPrototypes), AError);
    end);
end;

{ The IDE's own Block Indent and Use Tab Character, for a request that has to
  state them. Defaults 2 / spaces when the options cannot be read, which is
  what this used to send unconditionally. }
procedure ReadIndentOptions(out ATabSize: Integer; out AInsertSpaces: Boolean);
var
  LEditorServices: IOTAEditorServices;
  LView: IOTAEditView;
  LOptions: IOTAEditOptions;
begin
  ATabSize := 2;
  AInsertSpaces := True;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    Exit;
  LView := LEditorServices.TopView;
  if not Assigned(LView) or not Assigned(LView.Buffer) then
    Exit;
  LOptions := LView.Buffer.EditOptions;
  if not Assigned(LOptions) then
    Exit;
  if LOptions.BlockIndent > 0 then
    ATabSize := LOptions.BlockIndent;
  if Assigned(LOptions.BufferOptions) then
    AInsertSpaces := not LOptions.BufferOptions.UseTabCharacter;
end;

procedure TLspSession.OnTypeFormatting(const AFileName: string;
  ARow, ACol: Integer; const AOnDone: TLspTextEditsProc);
var
  LParams, LDoc, LPos, LOpts: TJSONObject;
  LLine, LChar, LTabSize: Integer;
  LInsertSpaces: Boolean;
begin
  if not EnsureSession then
  begin
    AOnDone(False, nil, 'no LSP server available');
    Exit;
  end;
  // Sync FIRST and unconditionally, for ClassComplete's reason: this request
  // exists BECAUSE the buffer just changed (the Enter is already in it).
  FDocs.Sync;
  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  { THE SERVER READS THESE - it does not, as this comment used to claim, copy
    the opener line's indentation and ignore them: PasLsp.BlockClose builds the
    body indent from options.tabSize and options.insertSpaces. So hardcoding
    2/spaces here was not a formality for spec compliance, it was every RAD
    Studio user getting "opener indent + 2 spaces" no matter what their Block
    Indent is set to. Asked of the IDE instead. }
  ReadIndentOptions({out} LTabSize, {out} LInsertSpaces);
  LOpts := TJSONObject.Create;
  LOpts.AddPair('tabSize', TJSONNumber.Create(LTabSize));
  LOpts.AddPair('insertSpaces', TJSONBool.Create(LInsertSpaces));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);
  LParams.AddPair('ch', #10);
  LParams.AddPair('options', LOpts);
  // No supersede slot: like ClassComplete, a deliberate keystroke - and the
  // answer is dropped by the caller if the caret has moved on.
  FClient.Request('textDocument/onTypeFormatting', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    var
      LEdits: TArray<TLspTextEdit>;
      LItem: TJSONValue;
      LEdit: TLspTextEdit;
      LEditLine, LEditChar: Integer;
    begin
      if not ASuccess then
      begin
        AOnDone(False, nil, AError);
        Exit;
      end;
      LEdits := nil;
      // null is the spec's "nothing to insert" - success with no edits.
      if AResult is TJSONArray then
        for LItem in TJSONArray(AResult) do
        begin
          LEditLine := LItem.GetValue<Integer>('range.start.line', -1);
          LEditChar := LItem.GetValue<Integer>('range.start.character', -1);
          LEdit.Text := LItem.GetValue<string>('newText', '');
          if (LEditLine < 0) or (LEditChar < 0) or (LEdit.Text = '') then
            Continue;
          LspToIde(LEditLine, LEditChar, LEdit.Row, LEdit.Col);
          LEditLine := LItem.GetValue<Integer>('range.end.line', LEditLine);
          LEditChar := LItem.GetValue<Integer>('range.end.character', LEditChar);
          LspToIde(LEditLine, LEditChar, LEdit.EndRow, LEdit.EndCol);
          LEdits := LEdits + [LEdit];
        end;
      AOnDone(True, LEdits, '');
    end);
end;

/// <summary>
/// A pastree/renamePlan answer. The positions are PasTree's own 1-based
/// line/column - IDE coordinates already - so unlike every other parser here
/// this one does NOT convert (see TLspRenameEdit). An edit missing its
/// position or its old text is dropped rather than applied blind.
/// </summary>
function ParseRenamePlan(AResult: TJSONValue): TLspRenamePlan;
var
  LEdits, LStale: TJSONArray;
  LValue: TJSONValue;
  LObj: TJSONObject;
  LEdit: TLspRenameEdit;
  LCount: Integer;
begin
  Result := Default(TLspRenamePlan);
  if not (AResult is TJSONObject) then
    Exit;
  Result.OldName := AResult.GetValue<string>('oldName', '');
  Result.NewName := AResult.GetValue<string>('newName', '');
  Result.IsUnit := SameText(AResult.GetValue<string>('kind', ''), 'unit');
  Result.RequiredFileName :=
    AResult.GetValue<string>('requiredFileName', '');
  Result.FilePath := AResult.GetValue<string>('filePath', '');
  Result.NewFilePath := AResult.GetValue<string>('newFilePath', '');
  if AResult.TryGetValue<TJSONArray>('staleInPaths', LStale) then
  begin
    SetLength(Result.StaleInPaths, LStale.Count);
    for LCount := 0 to LStale.Count - 1 do
      Result.StaleInPaths[LCount] := LStale.Items[LCount].Value;
  end;
  if not AResult.TryGetValue<TJSONArray>('edits', LEdits) then
    Exit;
  SetLength(Result.Edits, LEdits.Count);
  LCount := 0;
  for LValue in LEdits do
  begin
    if not (LValue is TJSONObject) then
      Continue;
    LObj := TJSONObject(LValue);
    LEdit.FilePath := LObj.GetValue<string>('filePath', '');
    LEdit.Row := LObj.GetValue<Integer>('line', 0);
    LEdit.Col := LObj.GetValue<Integer>('col', 0);
    LEdit.Len := LObj.GetValue<Integer>('len', 0);
    LEdit.OldText := LObj.GetValue<string>('oldText', '');
    LEdit.NewText := LObj.GetValue<string>('newText', '');
    LEdit.IsDecl := LObj.GetValue<Boolean>('isDecl', False);
    LEdit.Snippet := LObj.GetValue<string>('snippet', '');
    LEdit.HiFrom := LObj.GetValue<Integer>('hiFrom', 0);
    LEdit.HiTo := LObj.GetValue<Integer>('hiTo', 0);
    if (LEdit.FilePath = '') or (LEdit.Row < 1) or (LEdit.Col < 1) or
       (LEdit.Len < 1) or (LEdit.OldText = '') or (LEdit.NewText = '') then
      Continue;
    Result.Edits[LCount] := LEdit;
    Inc(LCount);
  end;
  SetLength(Result.Edits, LCount);
end;

procedure TLspSession.RenameTarget(const AFileName: string;
  ARow, ACol: Integer; const AOnDone: TLspRenameTargetProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
begin
  if not EnsureSession then
  begin
    AOnDone(False, '', 'no LSP server available');
    Exit;
  end;
  FDocs.Sync;
  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);
  FClient.Request('textDocument/prepareRename', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if not ASuccess then
      begin
        AOnDone(False, '', AError);
        Exit;
      end;
      // A null result means the server had no opinion (no project yet, or
      // the file is not in the closure). Not an error, and not a name.
      if not Assigned(AResult) then
        AOnDone(False, '', 'There is nothing renameable at that position.')
      else
        AOnDone(True, AResult.GetValue<string>('placeholder', ''), '');
    end);
end;

procedure TLspSession.RenamePlan(const AFileName: string; ARow, ACol: Integer;
  const ANewName: string; const AOnDone: TLspRenamePlanProc);
var
  LParams, LDoc, LPos: TJSONObject;
  LLine, LChar: Integer;
begin
  if not EnsureSession then
  begin
    AOnDone(False, Default(TLspRenamePlan), 'no LSP server available');
    Exit;
  end;
  // Sync FIRST and unconditionally, for classComplete's reason turned up one
  // notch: this plan becomes EDITS to those same buffers, and coordinates
  // computed from text the server no longer holds would be applied to the
  // wrong columns. (The applier re-checks every site against the buffer
  // anyway - this is what keeps that check from failing routinely.)
  FDocs.Sync;
  IdeToLsp(ARow, ACol, LLine, LChar);
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(AFileName));
  LPos := TJSONObject.Create;
  LPos.AddPair('line', TJSONNumber.Create(LLine));
  LPos.AddPair('character', TJSONNumber.Create(LChar));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('position', LPos);
  LParams.AddPair('newName', ANewName);
  // No supersede slot, as for classComplete: a rename is a deliberate act,
  // not a stream of per-keystroke questions.
  FClient.Request('pastree/renamePlan', LParams,
    procedure(ASuccess: Boolean; AResult: TJSONValue; const AError: string)
    begin
      if ASuccess then
        AOnDone(True, ParseRenamePlan(AResult), '')
      else
        AOnDone(False, Default(TLspRenamePlan), AError);
    end);
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
  LBlank: Boolean;
begin
  Result := '';
  if (AResult = nil) or AResult.Null then
    Exit;
  if not AResult.TryGetValue<string>('contents.value', LValue) then
    Exit;
  LLines := LValue.Replace(#13#10, #10).Split([#10]);
  LOut := '';
  LBlank := False;
  for LIdx := 0 to High(LLines) do
  begin
    if LLines[LIdx].StartsWith('```') then
      Continue;   // fence markers carry no content
    if (LLines[LIdx].Length >= 2) and LLines[LIdx].StartsWith('_') and
       LLines[LIdx].EndsWith('_') then
      LLines[LIdx] := Copy(LLines[LIdx], 2, LLines[LIdx].Length - 2);
    // Blank lines are the card's STRUCTURE, not filler: they separate the
    // declaration from the documentation and the documentation from its
    // sections. Dropping them (as this did until 2026-08-23) is what made a
    // documented declaration read as one run-on block in the hint. Kept at
    // most one in a row, so the markdown's fence-plus-blank does not open a
    // gap, and never leading.
    if LLines[LIdx] = '' then
    begin
      LBlank := LOut <> '';
      Continue;
    end;
    if LOut <> '' then
      LOut := LOut + sLineBreak;
    if LBlank then
      LOut := LOut + sLineBreak;
    LBlank := False;
    LOut := LOut + LLines[LIdx];
  end;
  Result := LOut;
end;

/// <summary>
/// What the hint surface gets: the server's own Help Insight page when it sent
/// one (`pastreeHtml` - our field, alongside the standard contents), else the
/// markdown card stripped to plain text.
///
/// HTML is preferred because the IDE's tooltip Help Insight IS an HTML window:
/// the IDE builds its own page by XSL-transforming a `member` document, and
/// both files ship in the product (ObjRepos\HelpInsight.xsl / .css). That also
/// explains the first live run's symptom - plain text with blank lines between
/// its blocks arrived as ONE paragraph, the declaration line running straight
/// into the documentation, because an HTML renderer collapses newlines.
/// </summary>
function HoverHintText(AResult: TJSONValue): string;
begin
  { MEASURED 2026-08-23, and the measurement decides this: the hint the IDE
    shows for AsyncGetHintText is a PLAIN window - fed HTML, it displayed the
    tags. So plain text it is, with the blocks kept apart by blank lines.

    The HTML page still arrives as `pastreeHtml` and is NOT used here. It is
    the payload for the rich Help Insight window, which is a different surface
    with a different feed (see ProbeHelpInsight in
    PasTreeIdePlugin.CodeInsight and the "Help Insight" option in the Code
    Insight option set) - and the moment that surface is reachable, this is
    the one line that changes. The viewer's documentation pane keeps using
    HTML, because ToolsAPI documents THAT one as HTML. }
  Result := HoverPlainText(AResult);
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
        AOnDone(True, HoverHintText(AResult), '')
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

procedure TLspSession.SyncDocuments;
begin
  FDocs.Sync;
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

{ Prewarm, plus the line that says a project came up.

  Where the line comes from matters: after EnsureSession, either the server was
  just started for this project - and its own handshake already logged
  "server ready" - or it was already running for it, which is the case that
  used to pass in silence. ReadyLine is empty until the handshake answers, so
  the first case prints nothing here and the second prints exactly what the
  first printed, which is the point: one line per project open, always the
  same one, whether or not a server had to be spawned for it. }
procedure TLspSession.ProjectOpened;
var
  LProject: IOTAProject;
  LWasReady: Boolean;
  LReadyLine: string;
begin
  LProject := GetActiveProject;
  if not Assigned(LProject) then
    Exit;   // see Prewarm: normal during startup, and not ours to report
  LWasReady := Assigned(FClient) and (FClient.State = lcsReady);
  if not EnsureSession then
    Exit;
  if not LWasReady then
  begin
    // The handshake logs the line itself when it answers, so this open is
    // already accounted for - claim it here, or the next notification for the
    // same open finds a ready server and prints a second copy.
    FAnnouncedProject := FStartedProject;
    Exit;
  end;
  // ONE LINE PER PROJECT OPEN, not one per notification - see
  // FAnnouncedProject. Reopening the same project after a close does print
  // again: ProjectClosed clears this, and it is the close that makes the
  // second line meaningful rather than repetitive.
  if SameText(FAnnouncedProject, FStartedProject) then
    Exit;
  FAnnouncedProject := FStartedProject;
  // LWasReady was sampled BEFORE EnsureSession: if it just restarted the
  // server for a changed project/configuration, the client is mid-handshake
  // again and ReadyLine is '' - that restart already announced itself, and
  // the new handshake will log its own "server ready" when it answers.
  // Logging an empty line here was exactly that race.
  LReadyLine := FClient.ReadyLine;
  if LReadyLine = '' then
    Exit;
  LogDiagnostic(LReadyLine);
  // Into the server's log too, where it separates one project's requests from
  // the next's. The server cannot see this event: from its side a reopened
  // project is just more requests arriving.
  FClient.LogToServer(Format('IDE opened %s',
    [ExtractFileName(FStartedProject)]));
end;

{ The server is deliberately LEFT RUNNING - see LspProjectClosed. This only
  records the boundary, on both sides, while there is still a project to
  name. }

procedure TLspSession.ProjectClosed;
begin
  // FIRST, and unconditionally: the next open of this project is entitled to
  // its own "server ready" line, and the early exits below are about whether
  // there is a SERVER to tell - a different question from whether the line has
  // been printed. Leaving it set behind one of those exits would silence the
  // reopen.
  FAnnouncedProject := '';
  if not Assigned(FClient) or (FClient.State <> lcsReady) or
     (FStartedProject = '') then
    Exit;
  LogDiagnostic(Format('project closed: %s - the server stays up for it',
    [ExtractFileName(FStartedProject)]));
  FClient.LogToServer(Format('IDE closed %s',
    [ExtractFileName(FStartedProject)]));
end;

{ Deliberately does NOT start a server: this carries readouts, and spawning a
  process to record one would be the tail wagging the dog. }
function TLspSession.LogToServer(const AText: string): Boolean;
begin
  Result := Assigned(FClient) and (FClient.State = lcsReady);
  if Result then
    FClient.LogToServer(AText);
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

procedure LspProjectOpened;
begin
  if Assigned(GSession) then
    GSession.ProjectOpened;
end;

procedure LspSyncDocuments;
begin
  // No session means nothing has been told anything yet, and the didOpen
  // catch-up on the next handshake will describe the buffers as they are by
  // then - so there is nothing to do and nothing to report.
  if Assigned(GSession) then
    GSession.SyncDocuments;
end;

procedure LspProjectClosed;
begin
  if Assigned(GSession) then
    GSession.ProjectClosed;
end;


function LspLogToServer(const AText: string): Boolean;
begin
  Result := Assigned(GSession) and GSession.LogToServer(AText);
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

procedure LspClassComplete(const AFileName: string;
  const AOnDone: TLspClassCompleteProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, Default(TLspClassComplete), 'LSP session not initialized');
    Exit;
  end;
  GSession.ClassComplete(AFileName, AOnDone);
end;

procedure LspSyncPrototypes(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspSyncPrototypesProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, Default(TLspSyncPrototypes),
      'LSP session not initialized');
    Exit;
  end;
  GSession.SyncPrototypes(AFileName, ARow, ACol, AOnDone);
end;

procedure LspOnTypeFormatting(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspTextEditsProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, nil, 'LSP session not initialized');
    Exit;
  end;
  GSession.OnTypeFormatting(AFileName, ARow, ACol, AOnDone);
end;

procedure LspRenamePlan(const AFileName: string; ARow, ACol: Integer;
  const ANewName: string; const AOnDone: TLspRenamePlanProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, Default(TLspRenamePlan), 'LSP session not initialized');
    Exit;
  end;
  GSession.RenamePlan(AFileName, ARow, ACol, ANewName, AOnDone);
end;

procedure LspRenameTarget(const AFileName: string; ARow, ACol: Integer;
  const AOnDone: TLspRenameTargetProc);
begin
  if not Assigned(GSession) then
  begin
    AOnDone(False, '', 'LSP session not initialized');
    Exit;
  end;
  GSession.RenameTarget(AFileName, ARow, ACol, AOnDone);
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
