unit PasTreeIdePlugin.LspDocuments;

{
  Keeps the server's idea of the open documents in step with the editor's, and
  converts positions between the two coordinate systems. This is the first
  layer that touches ToolsAPI; everything below it (LspClient, LspTransport) is
  deliberately IDE-free so it can be tested from a console harness.

  SYNC ON REQUEST, NOT ON KEYSTROKE. Sync() is called just before a navigation
  request goes out, reads the live buffers, and sends only what actually
  changed. There is no editor-change notifier here at all, and that is the
  point:

  - The text is by definition current at the moment the question is asked,
    which is the only moment that matters for definition/references.
  - No keystroke-rate traffic at all, which is also why we do not need the
    server's incremental sync: at most one whole-document replacement per user
    action is cheaper than a stream of correctly-ranged patches, and a full
    replacement cannot silently desynchronise the way a mis-applied patch can
    (the server has no way to ask a client to resend).
  - One less notifier to tear down at package unload. This repo's README
    already names AddEditorEventsNotifier's incomplete teardown as the likely
    cause of its package hot-reload trouble; not adding a second notifier of
    the same kind is a deliberate risk reduction.

  The cost was that nothing reached the server between requests, which is
  invisible for navigation and unacceptable for diagnostics. Both halves of
  that sentence have since happened: publishDiagnostics is implemented, and the
  push side is PasTreeIdePlugin.IdleSync (2026-08-22), a debounced idle-timer
  notifier that runs BESIDE this pull path rather than instead of it -
  exactly as planned here. Since 2026-09-08 it reads only the buffers the
  editor reported modified (SyncOne), because the full pass below costs
  ~15 ms per open module in IOTAEditorContent.Content on a slow machine.

  Reading the live buffer goes through IOTAEditorContent, with the warnings
  that technique carries intact (see ReadBufferText).

  POSITIONS. The IDE gives 1-based Row/Column; LSP wants 0-based line and
  0-based UTF-16 code units; the server turns an LSP character back into a
  PasTree column by adding 1. So IDE -> LSP -> PasTree collapses to
  PasTreeColumn = IDEColumn, which is exactly the identity the in-process
  version already relies on when it hands EditPosition.Column straight to
  TPasNavigator. This step therefore adds no position risk of its own. The
  residual risk it inherits is unchanged: a character outside the BMP occupies
  two UTF-16 code units but may be counted once by the editor, so a line
  containing one could be off by one after it. Cyrillic and every other
  BMP text is exact.
}

interface

uses
  ToolsAPI,
  System.SysUtils,
  System.Generics.Collections,
  PasTreeIdePlugin.LspClient;

type
  /// <summary>
  /// Tracks which text the server was last given for each document, so Sync
  /// can send didOpen/didChange/didClose only where something moved.
  /// </summary>
  TLspDocumentSync = class
  private type
    TSentDocument = class
      Path: string;
      Text: string;
      Version: Integer;
      // Has an editor view of its own - see ModuleIsShown. Meaningful only on
      // the way out of CollectOpenDocuments; what is REMEMBERED per document
      // is its text, and a module gaining or losing a tab changes nothing
      // about that.
      Shown: Boolean;
      // When Text was last READ from the editor: the buffer's modification
      // count then (see NoteBufferModified) and the file's disk stamp. Equal
      // now means the editor still holds this exact text, and the 15 ms
      // IOTAEditorContent.Content call can be skipped.
      ReadStamp: Int64;
      DiskStamp: TDateTime;
    end;
  private
    FClient: TLspClient;
    FSent: TObjectDictionary<string, TSentDocument>;   // key: lowercase path
    { WHICH OPEN BUFFERS ARE THIS SERVER'S, asked per module on every sync.

      A project group runs one server per project, and a buffer belongs to
      exactly one of them. Broadcasting all of them to all servers would not
      just waste memory: didOpen and didChange call ScheduleAnalysis on the
      server, so one tab switch would schedule a rebuild in every live server
      in the group. nil = take everything, which is what a single-project
      client wants and what the VS Code side does. }
    FOwnsPath: TFunc<string, Boolean>;
    function CollectOpenDocuments: TArray<TSentDocument>;
    procedure SendDidOpen(const APath, AText: string; AVersion: Integer;
      AShown: Boolean);
    procedure SendDidChange(const APath, AText: string; AVersion: Integer);
    procedure SendDidClose(const APath: string);
    procedure LogSent(const AVerb, APath: string; AVersion: Integer;
      AChars: Integer; ASendStart: Double);
  public
    constructor Create(AClient: TLspClient;
      const AOwnsPath: TFunc<string, Boolean> = nil);
    destructor Destroy; override;

    /// <summary>
    /// Brings the server in line with the editor: opens documents it has not
    /// seen, sends the new text of any whose buffer changed, and closes the
    /// ones no longer open. Cheap - a handful of open buffers, the same read
    /// the in-process version already does on every click.
    /// </summary>
    procedure Sync;

    /// <summary>
    /// The idle-typing counterpart of Sync: reads ONE buffer, the one the
    /// editor just reported modified, and sends didChange if its text moved.
    /// False when this path is not a document the server already has (never
    /// synced, or not open at all) - the caller then falls back to Sync,
    /// which is the only thing that can open and close documents.
    ///
    /// WHY NOT SYNC EVERY TIME. IOTAEditorContent.Content costs about 15 ms
    /// per module on a six-core i5 (measured 2026-09-08, 32 open modules,
    /// 480 ms per typing pause) regardless of the module's size, and the
    /// idle tick fires on every pause. One keystroke changes one buffer; the
    /// whole set is re-read where the answer has to be complete - before a
    /// request, in Sync.
    /// </summary>
    function SyncOne(const APath: string): Boolean;

    /// <summary>
    /// Re-opens every tracked document from scratch. Hook this to
    /// TLspClient.OnReady: a restarted server has no documents at all, and
    /// would otherwise answer from whatever is on disk.
    /// </summary>
    procedure ResendAll;

    /// <summary>
    /// Forgets everything, without telling the server (there is no server to
    /// tell - for use when the connection is already gone).
    /// </summary>
    procedure Forget;

    /// <summary>
    /// The exact text the server was last given for APath, if we sent it at
    /// all. Callers that want to display a line the server pointed at must ask
    /// here rather than read the file: for a buffer with unsaved edits, the
    /// text on disk no longer matches the line and column numbers the answer
    /// is expressed in.
    /// </summary>
    function TryGetSentText(const APath: string; out AText: string): Boolean;
  end;

/// <summary>
/// The editor reported this buffer modified. Called from the
/// EditorViewModified notifier (PasTreeIdePlugin.IdleSync) for every change
/// event; bumps the buffer's modification count, which is what lets Sync
/// skip reading a buffer nobody touched.
///
/// WHY A COUNT AND NOT A FLAG: several sessions (one per project in a group)
/// sync independently, and a flag cleared by one would hide the change from
/// the next. Each remembered document keeps the count it was read at, and
/// "count moved since" is a per-reader question with no clearing at all.
/// </summary>
procedure NoteBufferModified(const APath: string);

/// <summary>
/// Whether NoteBufferModified is actually being fed - True while the
/// EditorViewModified notifier is registered. False makes Sync read every
/// buffer, as it did before there was any tracking: a plugin whose notifier
/// failed to register must degrade to slow, not to stale.
/// </summary>
procedure SetBufferChangeTracking(AActive: Boolean);

/// <summary>
/// IDE (1-based row/column) to LSP (0-based line/character). See the unit
/// header on why this is the whole conversion.
/// </summary>
procedure IdeToLsp(ARow, ACol: Integer; out ALine, ACharacter: Integer);

/// <summary>LSP (0-based) back to IDE (1-based).</summary>
procedure LspToIde(ALine, ACharacter: Integer; out ARow, ACol: Integer);

/// <summary>
/// True for a file extension whose contents PasTree can be asked about. The
/// .dpr/.dpk matter as much as .pas here - Ctrl+Click inside the program's own
/// uses clause is exactly the three-identity case this project cares about -
/// which is why this is wider than the in-process version's .pas-only filter.
/// </summary>
function IsPascalSourceFile(const AFileName: string): Boolean;

/// <summary>
/// The view's buffer length in bytes, or -1 if it cannot be read.
///
/// THE STALENESS MEASURE FOR ANY FEATURE THAT WRITES A SERVER'S ANSWER BACK.
/// An answer's row/col describe the snapshot the server was given, and the
/// edits are applied at absolute offsets resolved from them, so they remain
/// valid exactly as long as the amount of text before each site is unchanged:
/// a same-length replacement shifts nothing, anything that grows or shrinks
/// the buffer shifts everything after it. So the length is very nearly the
/// exact condition rather than an approximation of it, and it costs one
/// integer at request time and one at answer time - the IDE hands the content
/// out as a memory stream and only its size is touched, never its text.
///
/// Here rather than in each feature because two of them need it (class
/// completion and block close) and a third eventually will.
/// </summary>
function BufferByteLength(const AView: IOTAEditView): Integer;

implementation

uses
  System.Classes,
  System.StrUtils,
  System.Math,
  System.Generics.Defaults,
  System.JSON,
  Winapi.ActiveX,
  IStreams,
  PasLsp.SourceText,
  PasTreeIdePlugin.Timing;

function BufferByteLength(const AView: IOTAEditView): Integer;
var
  LContent: IOTAEditorContent;
  LStream: IStream;
begin
  Result := -1;
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  if not Supports(AView.Buffer, IOTAEditorContent, LContent) then
    Exit;
  LStream := LContent.Content;
  if not Assigned(LStream) then
    Exit;
  Result := (LStream as TIMemoryStream).MemoryStream.Size;
end;

var
  // Lower-cased path -> modification count. Grows by one entry per file
  // ever edited in the session, which is bounded by what a person can type
  // in; never pruned, because a count for a closed file is harmless and a
  // reopen of the same file must not restart at zero while a remembered
  // document still carries the old count.
  GModCounts: TDictionary<string, Int64>;
  GTracking: Boolean = False;

procedure NoteBufferModified(const APath: string);
var
  LKey: string;
  LCount: Int64;
begin
  if GModCounts = nil then
    GModCounts := TDictionary<string, Int64>.Create;
  LKey := LowerCase(APath);
  if not GModCounts.TryGetValue(LKey, LCount) then
    LCount := 0;
  GModCounts.AddOrSetValue(LKey, LCount + 1);
end;

procedure SetBufferChangeTracking(AActive: Boolean);
begin
  GTracking := AActive;
end;

function ModCountOf(const AKey: string): Int64;
begin
  if (GModCounts = nil) or not GModCounts.TryGetValue(AKey, Result) then
    Result := 0;
end;

{ The file's last-write time, 0 for a file that is not on disk (a new unit
  never saved). The second half of "did this buffer change": the notifier
  sees every edit made IN the editor, and this sees the IDE reloading a file
  someone else wrote - a git checkout, a generator - which may or may not be
  announced as a modification. One stat call, tens of microseconds. }
function DiskStampOf(const APath: string): TDateTime;
begin
  if not FileAge(APath, Result) then
    Result := 0;
end;

procedure IdeToLsp(ARow, ACol: Integer; out ALine, ACharacter: Integer);
begin
  ALine := ARow - 1;
  ACharacter := ACol - 1;
end;

procedure LspToIde(ALine, ACharacter: Integer; out ARow, ACol: Integer);
begin
  ARow := ALine + 1;
  ACol := ACharacter + 1;
end;

function IsPascalSourceFile(const AFileName: string): Boolean;
var
  LExt: string;
begin
  LExt := LowerCase(ExtractFileExt(AFileName));
  Result := (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') or
    (LExt = '.inc');
end;

/// <summary>
/// Live text of an already-open module's edit buffer.
///
/// Deliberately the same technique as RAD Studio's own official "Editor Raw
/// Read Demo" (StreamReadGetFileData): IOTAEditorContent.Content gives direct
/// access to the buffer's own memory stream. An earlier version of this code
/// used the legacy IOTAEditReader.GetText loop instead, which triggered
/// heap/stack corruption - an access violation surfacing much later, in
/// unrelated IDE code, on the NEXT menu click. Do not reintroduce
/// IOTAEditReader here without re-verifying against the official samples
/// first.
///
/// AModule must already be open (it comes from IOTAModuleServices' list of
/// open modules) - there is deliberately no OpenModule call. Forcing a module
/// open makes the IDE instantiate a form or data module's design surface,
/// which flickers every such designer open and shut.
/// </summary>
{ Is this module ON SCREEN, or merely loaded?

  The IDE's module list is not the list of tabs, and the difference surprises
  everyone who reads the log once: opening one form pulls in its visual-
  inheritance ancestors and every datamodule its .dfm references, and each of
  those arrives as a didOpen the user did not ask for. They belong in the sync
  - an unsaved edit in a form with no tab is still the truth about that unit -
  but a log that cannot tell them apart from the file the user is looking at
  reads like a bug.

  A view, not a tab: EditViewCount is what the IDE actually gives us, and a
  module loaded behind the scenes has none. A module with no file editor at
  all (a .dfm-only or a form the IDE has not materialised) is likewise not
  shown. }
function ModuleIsShown(const AModule: IOTAModule): Boolean;
var
  LEditor: IOTASourceEditor;
begin
  Result := False;
  try
    if Supports(AModule.GetModuleFileEditor(0), IOTASourceEditor, LEditor) then
      Result := LEditor.EditViewCount > 0;
  except
    // Same degradation as ReadBufferText's: a module we cannot ask about is
    // reported as not shown rather than taking the sync down with it.
  end;
end;

{ The three costs of one buffer read, for the per-module timing line in
  CollectOpenDocuments: finding the editor (GetModuleFileEditor), asking the
  IDE for the content stream (IOTAEditorContent.Content - where the IDE may
  have to flatten an edited buffer), and our own copy plus UTF-8 decode. }
type
  TReadCost = record
    EditorMs, ContentMs, DecodeMs: Double;
  end;

function ReadBufferText(const AModule: IOTAModule;
  out ACost: TReadCost): string;
var
  LBuffer: IOTAEditBuffer;
  LEditorContent: IOTAEditorContent;
  LIStream: IStream;
  LIMemStream: TIMemoryStream;
  LMemStream: TMemoryStream;
  LFileContent: UTF8String;
  LT: Double;
begin
  Result := '';
  ACost := Default(TReadCost);
  LT := TimingNowMs;
  if not Supports(AModule.GetModuleFileEditor(0), IOTAEditBuffer, LBuffer) then
  begin
    ACost.EditorMs := TimingNowMs - LT;
    Exit;
  end;
  ACost.EditorMs := TimingNowMs - LT;

  LT := TimingNowMs;
  LEditorContent := LBuffer as IOTAEditorContent;
  LIStream := LEditorContent.Content;
  LIMemStream := LIStream as TIMemoryStream;
  LMemStream := LIMemStream.MemoryStream;
  ACost.ContentMs := TimingNowMs - LT;
  LT := TimingNowMs;
  SetLength(LFileContent, LMemStream.Size);
  LMemStream.Position := 0;
  if LMemStream.Size <> 0 then
    LMemStream.Read(LFileContent[1], Length(LFileContent));
  Result := UTF8ToString(LFileContent);

  // A leading BOM must never reach the server - see PasLsp.SourceText for what
  // it costs. The server strips one too as of 0.5.3, so this is now a belt on
  // top of braces rather than the only defence; it stays because it is free
  // and because it keeps what this client SENDS honest, whatever it talks to.
  Result := StripLeadingBom(Result);
  ACost.DecodeMs := TimingNowMs - LT;
end;

{ TLspDocumentSync }

constructor TLspDocumentSync.Create(AClient: TLspClient;
  const AOwnsPath: TFunc<string, Boolean>);
begin
  inherited Create;
  FClient := AClient;
  FOwnsPath := AOwnsPath;
  FSent := TObjectDictionary<string, TSentDocument>.Create([doOwnsValues]);
end;

destructor TLspDocumentSync.Destroy;
begin
  FSent.Free;
  inherited;
end;

{ WHERE A SLOW READ GOES, module by module. The first measured log from the
  six-core machine (2026-09-08) put 470 ms of a 480 ms typing pause in
  CollectOpenDocuments for 31 documents - and the same 31 documents read in
  9.5 ms when a request, not an idle tick, asked. So the cost is not the byte
  copy, it is something the IDE does when asked about a buffer shortly after
  an edit, and the only way to see which buffer and which call is to time
  each one. The three slowest modules of a sync are logged when the sync as a
  whole cost more than cSlowCollectMs; a cheap sync logs nothing extra. }
type
  TModuleCost = record
    Name: string;
    OwnsMs, ShownMs: Double;
    Read: TReadCost;
    Chars: Integer;
    function Total: Double;
  end;

function TModuleCost.Total: Double;
begin
  Result := OwnsMs + ShownMs + Read.EditorMs + Read.ContentMs + Read.DecodeMs;
end;

const
  cSlowCollectMs = 20.0;
  cSlowestToLog = 3;

function TLspDocumentSync.CollectOpenDocuments: TArray<TSentDocument>;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LList: TObjectList<TSentDocument>;
  LDoc: TSentDocument;
  LActive, LKey: string;
  I, J, LSkipped, LReused: Integer;
  LStart, LT: Double;
  LCost: TModuleCost;
  LCosts: TList<TModuleCost>;
  LOwns: Boolean;
  LKnown: TSentDocument;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;

  LStart := TimingNowMs;
  LSkipped := 0;
  LReused := 0;
  LCosts := nil;
  if TimingLogPath <> '' then
    LCosts := TList<TModuleCost>.Create;
  LList := TObjectList<TSentDocument>.Create(False);   // caller owns the items
  try
    for I := 0 to LModuleServices.ModuleCount - 1 do
    begin
      LModule := LModuleServices.Modules[I];
      if not Assigned(LModule) then
        Continue;
      if not IsPascalSourceFile(LModule.FileName) then
        Continue;
      LCost := Default(TModuleCost);
      LCost.Name := ExtractFileName(LModule.FileName);
      LT := TimingNowMs;
      LOwns := not Assigned(FOwnsPath) or FOwnsPath(LModule.FileName);
      LCost.OwnsMs := TimingNowMs - LT;
      if not LOwns then
      begin
        // Another project's buffer, and another server's business. Still
        // accounted: the route lookup is per module per sync.
        Inc(LSkipped);
        if LCosts <> nil then
          LCosts.Add(LCost);
        Continue;
      end;
      try
        LDoc := TSentDocument.Create;
        try
          LDoc.Path := LModule.FileName;
          LKey := LowerCase(LDoc.Path);
          LDoc.ReadStamp := ModCountOf(LKey);
          LDoc.DiskStamp := DiskStampOf(LDoc.Path);
          // REUSE THE TEXT WE HOLD when nothing says it moved: the editor has
          // not reported a modification since it was read, and the file on
          // disk is what it was. Both stamps equal is the whole test; the
          // 15 ms IOTAEditorContent.Content call (see the header) is paid only
          // for a buffer that is new to us or has actually changed. With no
          // tracking every buffer is read, as before tracking existed.
          if GTracking and FSent.TryGetValue(LKey, LKnown) and
             (LKnown.ReadStamp = LDoc.ReadStamp) and
             (LKnown.DiskStamp = LDoc.DiskStamp) then
          begin
            LDoc.Text := LKnown.Text;
            Inc(LReused);
          end
          else
          begin
            LDoc.Text := ReadBufferText(LModule, LCost.Read);
            LCost.Chars := Length(LDoc.Text);
          end;
          LT := TimingNowMs;
          LDoc.Shown := ModuleIsShown(LModule);
          LCost.ShownMs := TimingNowMs - LT;
          LList.Add(LDoc);
        except
          LDoc.Free;
          raise;
        end;
      except
        // Swallow per-module read failures: a document we cannot read simply
        // does not get overlaid, and the server falls back to the copy on
        // disk. That is a safe degradation, and there is no single right place
        // to report it from shared plumbing.
      end;
      if LCosts <> nil then
        LCosts.Add(LCost);
    end;
    if (LCosts <> nil) and (TimingNowMs - LStart >= cSlowCollectMs) then
    begin
      LCosts.Sort(TComparer<TModuleCost>.Construct(
        function(const A, B: TModuleCost): Integer
        begin
          if A.Total > B.Total then
            Result := -1
          else if A.Total < B.Total then
            Result := 1
          else
            Result := 0;
        end));
      TimingLogFmt('  collect: %d modules, %d read, %d reused, %d not this ' +
        'project''s, %s; slowest:', [LList.Count, LList.Count - LReused,
        LReused, LSkipped, TimingSince(LStart)]);
      for J := 0 to Min(cSlowestToLog, LCosts.Count) - 1 do
        TimingLogFmt('    %s: %s total (owns %s, editor %s, content %s, ' +
          'decode %s, shown %s), %d chars',
          [LCosts[J].Name, Ms(LCosts[J].Total), Ms(LCosts[J].OwnsMs),
           Ms(LCosts[J].Read.EditorMs), Ms(LCosts[J].Read.ContentMs),
           Ms(LCosts[J].Read.DecodeMs), Ms(LCosts[J].ShownMs),
           LCosts[J].Chars]);
    end;
    // The file the user is LOOKING AT goes last, and that ordering is load-
    // bearing rather than cosmetic. Every didOpen the server receives before
    // it has anything analyzed schedules the build again and OVERWRITES the
    // pending priority file, so the last one sent is the one AnalyzeStaged
    // front-loads. Sending the active editor last therefore means the first
    // Ctrl+Click has the best chance of being answerable early - which is the
    // whole point of starting the analysis at project open.
    if Assigned(LModuleServices.CurrentModule) then
    begin
      LActive := LModuleServices.CurrentModule.FileName;
      for I := 0 to LList.Count - 2 do
        if SameText(LList[I].Path, LActive) then
        begin
          LList.Move(I, LList.Count - 1);
          Break;
        end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
    LCosts.Free;
  end;
end;

procedure TLspDocumentSync.SendDidOpen(const APath, AText: string;
  AVersion: Integer; AShown: Boolean);
var
  LParams, LDoc: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(APath));
  LDoc.AddPair('languageId', 'pascal');
  LDoc.AddPair('version', TJSONNumber.Create(AVersion));
  LDoc.AddPair('text', AText);
  // OURS, on a standard TextDocumentItem: the spec says unknown members are
  // ignored, so this costs a client that does not know it nothing, and it is
  // only ever read to write one word in the server's log. Sent ALWAYS rather
  // than only when False - absent has to keep meaning "a client that does not
  // report this" (VS Code), which is not the same as "not shown".
  LDoc.AddPair('pastreeShown', TJSONBool.Create(AShown));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  FClient.Notify('textDocument/didOpen', LParams);
end;

procedure TLspDocumentSync.SendDidChange(const APath, AText: string;
  AVersion: Integer);
var
  LParams, LDoc, LChange: TJSONObject;
  LChanges: TJSONArray;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(APath));
  LDoc.AddPair('version', TJSONNumber.Create(AVersion));
  // One change with NO range: the spec defines that as replacing the whole
  // document, and the server honors it explicitly even though it advertises
  // incremental sync (see HandleDidChange there). Deliberate - see the unit
  // header on why sync-on-request has no use for ranged patches.
  LChange := TJSONObject.Create;
  LChange.AddPair('text', AText);
  LChanges := TJSONArray.Create;
  LChanges.Add(LChange);
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  LParams.AddPair('contentChanges', LChanges);
  FClient.Notify('textDocument/didChange', LParams);
end;

procedure TLspDocumentSync.SendDidClose(const APath: string);
var
  LParams, LDoc: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(APath));
  LParams := TJSONObject.Create;
  LParams.AddPair('textDocument', LDoc);
  FClient.Notify('textDocument/didClose', LParams);
end;

{ While the handshake is still in flight we update our own picture but send
  NOTHING, and let ResendAll establish the whole document set once the server
  is ready. Sending here instead would double-open every document: the
  notifications would queue behind the handshake in the client's outbox, and
  then ResendAll - which runs on the handshake, BEFORE that outbox is flushed -
  would send them all again. The server treats each didOpen as a fresh open and
  schedules an analysis for any document that differs from disk, so the
  duplicate is not merely redundant traffic, it is a wasted full project
  rebuild.

  There is no race between "not ready" here and the handshake completing: the
  reply can only be dispatched on a later main-thread turn, and the caller runs
  EnsureSession and Sync back to back on this one. }
{ One timing line per notification actually written - see
  PasTreeIdePlugin.Timing for why. The whole chain on the main thread for a
  didChange is: read the buffer (in CollectOpenDocuments, reported by Sync),
  build the JSON (LastNotifyJsonMs, the document escaped character by
  character), then WriteFile on a 64 KB pipe (LastSendWaitMs, and Pending
  says whether the frame even fit the buffer). }
procedure TLspDocumentSync.LogSent(const AVerb, APath: string;
  AVersion: Integer; AChars: Integer; ASendStart: Double);
var
  LPending: string;
begin
  if TimingLogPath = '' then
    Exit;
  if FClient.LastSendPending then
    LPending := Format(', waited %sms for the pipe',
      [FormatFloat('0.0', FClient.LastSendWaitMs, TFormatSettings.Invariant)])
  else
    LPending := ', fit the pipe buffer';
  TimingLogFmt('  %s %s v%d: %d chars, json %sms, frame %d bytes, send %s%s',
    [AVerb, ExtractFileName(APath), AVersion, AChars,
     FormatFloat('0.0', FClient.LastNotifyJsonMs, TFormatSettings.Invariant),
     FClient.LastSendBytes, TimingSince(ASendStart), LPending]);
end;

procedure TLspDocumentSync.Sync;
var
  LOpen: TArray<TSentDocument>;
  LDoc, LKnown: TSentDocument;
  LKey: string;
  LSeen: TDictionary<string, Boolean>;
  LStale: TArray<string>;
  LReady: Boolean;
  LIdx, LChars, LOpened, LChanged, LClosed: Integer;
  LStart, LCollected, LSendStart: Double;
begin
  LStart := TimingNowMs;
  LReady := FClient.IsReady;
  LOpen := CollectOpenDocuments;
  LCollected := TimingNowMs;
  LChars := 0;
  LOpened := 0;
  LChanged := 0;
  LClosed := 0;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LIdx := 0 to High(LOpen) do
    begin
      LDoc := LOpen[LIdx];
      // Clear the slot as we take responsibility for it, so the cleanup below
      // frees exactly what this loop did not get to. CollectOpenDocuments hands
      // over ownership of every element, and each one carries a whole document's
      // text - megabytes per leak, once per navigation, if an exception between
      // here and the end of the loop went unhandled.
      LOpen[LIdx] := nil;
      LKey := LowerCase(LDoc.Path);
      LSeen.AddOrSetValue(LKey, True);
      Inc(LChars, Length(LDoc.Text));

      if not FSent.TryGetValue(LKey, LKnown) then
      begin
        LDoc.Version := 1;
        if LReady then
        begin
          LSendStart := TimingNowMs;
          SendDidOpen(LDoc.Path, LDoc.Text, LDoc.Version, LDoc.Shown);
          LogSent('didOpen', LDoc.Path, LDoc.Version, Length(LDoc.Text),
            LSendStart);
          Inc(LOpened);
        end;
        FSent.Add(LKey, LDoc);       // FSent owns it from here
        Continue;
      end;

      // Kept current even though nothing is sent for it: a module that has
      // since been given a tab must not be described as background by the
      // ResendAll after the next server restart.
      LKnown.Shown := LDoc.Shown;
      // The stamps describe the editor state this text was taken from, moved
      // or not: a modification that left the text identical (typed and
      // undone) still advances the count, and must not force a re-read on
      // every sync after it.
      LKnown.ReadStamp := LDoc.ReadStamp;
      LKnown.DiskStamp := LDoc.DiskStamp;
      if LKnown.Text <> LDoc.Text then
      begin
        Inc(LKnown.Version);
        LKnown.Text := LDoc.Text;
        if LReady then
        begin
          LSendStart := TimingNowMs;
          SendDidChange(LKnown.Path, LKnown.Text, LKnown.Version);
          LogSent('didChange', LKnown.Path, LKnown.Version,
            Length(LKnown.Text), LSendStart);
          Inc(LChanged);
        end;
      end;
      LDoc.Free;                     // duplicate of a document we already hold
    end;

    // Closed since last time. Collect first: removing inside the enumeration
    // would invalidate it.
    LStale := nil;
    for LKey in FSent.Keys do
      if not LSeen.ContainsKey(LKey) then
        LStale := LStale + [LKey];
    for LKey in LStale do
    begin
      // Not ready: the server either never heard of this document or is about
      // to be told the whole set by ResendAll, which omits it anyway.
      if LReady then
      begin
        SendDidClose(FSent[LKey].Path);
        Inc(LClosed);
      end;
      FSent.Remove(LKey);
    end;
  finally
    // Anything the loop above did not claim (it nils each slot as it does).
    for LIdx := 0 to High(LOpen) do
      LOpen[LIdx].Free;
    LSeen.Free;
  end;
  // The summary AFTER the per-send lines, so the reader sees what the total
  // is made of. "read" is CollectOpenDocuments - every open module of this
  // server's project pulled out of the editor and UTF-8 decoded - and is paid
  // whether or not anything changed; the rest is the comparison plus
  // whatever was sent.
  TimingLogFmt('sync %s: %d docs, %d chars, read %sms, rest %s, ' +
    'sent %d didOpen %d didChange %d didClose%s',
    [ExtractFileName(FClient.ProjectFile), FSent.Count, LChars,
     FormatFloat('0.0', LCollected - LStart, TFormatSettings.Invariant),
     TimingSince(LCollected), LOpened, LChanged, LClosed,
     IfThen(LReady, '', ' (server not ready: nothing sent)')]);
end;

function TLspDocumentSync.SyncOne(const APath: string): Boolean;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LKnown: TSentDocument;
  LText: string;
  LCost: TReadCost;
  LStart, LRead, LSendStart: Double;
  LReadStamp: Int64;
  LDiskStamp: TDateTime;
begin
  Result := False;
  if not FSent.TryGetValue(LowerCase(APath), LKnown) then
    Exit;   // not a document the server holds: Sync's job
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LStart := TimingNowMs;
  LModule := LModuleServices.FindModule(APath);
  if not Assigned(LModule) then
    Exit;   // closed since: Sync sends the didClose
  // Stamps BEFORE the read, like CollectOpenDocuments: an edit landing
  // between the two is then seen as newer than this read and re-read next
  // time, rather than lost.
  LReadStamp := ModCountOf(LowerCase(APath));
  LDiskStamp := DiskStampOf(APath);
  try
    LText := ReadBufferText(LModule, LCost);
  except
    // Same degradation as CollectOpenDocuments: unreadable means unsent, and
    // the server keeps the text it has. The stamps stay old too, so the next
    // sync reads it again instead of trusting a text it never got.
    Exit(True);
  end;
  LKnown.ReadStamp := LReadStamp;
  LKnown.DiskStamp := LDiskStamp;
  LRead := TimingNowMs;
  Result := True;
  if LKnown.Text = LText then
  begin
    TimingLogFmt('sync-one %s: unchanged, read %s',
      [ExtractFileName(APath), Ms(LRead - LStart)]);
    Exit;
  end;
  Inc(LKnown.Version);
  LKnown.Text := LText;
  if FClient.IsReady then
  begin
    LSendStart := TimingNowMs;
    SendDidChange(LKnown.Path, LKnown.Text, LKnown.Version);
    LogSent('didChange', LKnown.Path, LKnown.Version, Length(LKnown.Text),
      LSendStart);
  end;
  TimingLogFmt('sync-one %s: read %s (content %s), compare+send %s',
    [ExtractFileName(APath), Ms(LRead - LStart), Ms(LCost.ContentMs),
     TimingSince(LRead)]);
end;

procedure TLspDocumentSync.ResendAll;
var
  LDoc: TSentDocument;
begin
  // A fresh server: version numbering starts over, and didOpen is the only
  // correct verb - didChange against a document it never opened would be
  // rejected or, worse, ignored.
  for LDoc in FSent.Values do
  begin
    LDoc.Version := 1;
    SendDidOpen(LDoc.Path, LDoc.Text, LDoc.Version, LDoc.Shown);
  end;
end;

procedure TLspDocumentSync.Forget;
begin
  FSent.Clear;
end;

function TLspDocumentSync.TryGetSentText(const APath: string;
  out AText: string): Boolean;
var
  LDoc: TSentDocument;
begin
  Result := FSent.TryGetValue(LowerCase(APath), LDoc);
  if Result then
    AText := LDoc.Text;
end;

initialization

finalization
  FreeAndNil(GModCounts);

end.
