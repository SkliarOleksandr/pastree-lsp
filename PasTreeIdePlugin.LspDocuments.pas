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

  The cost is that nothing reaches the server between requests, which is
  invisible for navigation and unacceptable for diagnostics. When
  publishDiagnostics arrives (server phase 3), THAT is when a push-based
  didChange becomes necessary - and it should be added as a debounced notifier
  next to this, not instead of it.

  Reading the live buffer is the same IOTAEditorContent technique
  PasTreeIdePlugin.Analysis uses, carried over here with its warnings intact
  (see ReadBufferText). It is duplicated for now rather than shared, so that
  Analysis - and all of PasTree with it - can be deleted from this package
  without touching this unit.

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
    end;
  private
    FClient: TLspClient;
    FSent: TObjectDictionary<string, TSentDocument>;   // key: lowercase path
    function CollectOpenDocuments: TArray<TSentDocument>;
    procedure SendDidOpen(const APath, AText: string; AVersion: Integer);
    procedure SendDidChange(const APath, AText: string; AVersion: Integer);
    procedure SendDidClose(const APath: string);
  public
    constructor Create(AClient: TLspClient);
    destructor Destroy; override;

    /// <summary>
    /// Brings the server in line with the editor: opens documents it has not
    /// seen, sends the new text of any whose buffer changed, and closes the
    /// ones no longer open. Cheap - a handful of open buffers, the same read
    /// the in-process version already does on every click.
    /// </summary>
    procedure Sync;

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

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  Winapi.ActiveX,
  IStreams;

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
function ReadBufferText(const AModule: IOTAModule): string;
var
  LBuffer: IOTAEditBuffer;
  LEditorContent: IOTAEditorContent;
  LIStream: IStream;
  LIMemStream: TIMemoryStream;
  LMemStream: TMemoryStream;
  LFileContent: UTF8String;
begin
  Result := '';
  if not Supports(AModule.GetModuleFileEditor(0), IOTAEditBuffer, LBuffer) then
    Exit;

  LEditorContent := LBuffer as IOTAEditorContent;
  LIStream := LEditorContent.Content;
  LIMemStream := LIStream as TIMemoryStream;
  LMemStream := LIMemStream.MemoryStream;
  SetLength(LFileContent, LMemStream.Size);
  LMemStream.Position := 0;
  if LMemStream.Size <> 0 then
    LMemStream.Read(LFileContent[1], Length(LFileContent));
  Result := UTF8ToString(LFileContent);
end;

{ TLspDocumentSync }

constructor TLspDocumentSync.Create(AClient: TLspClient);
begin
  inherited Create;
  FClient := AClient;
  FSent := TObjectDictionary<string, TSentDocument>.Create([doOwnsValues]);
end;

destructor TLspDocumentSync.Destroy;
begin
  FSent.Free;
  inherited;
end;

function TLspDocumentSync.CollectOpenDocuments: TArray<TSentDocument>;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LList: TObjectList<TSentDocument>;
  LDoc: TSentDocument;
  I: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;

  LList := TObjectList<TSentDocument>.Create(False);   // caller owns the items
  try
    for I := 0 to LModuleServices.ModuleCount - 1 do
    begin
      LModule := LModuleServices.Modules[I];
      if not Assigned(LModule) then
        Continue;
      if not IsPascalSourceFile(LModule.FileName) then
        Continue;
      try
        LDoc := TSentDocument.Create;
        try
          LDoc.Path := LModule.FileName;
          LDoc.Text := ReadBufferText(LModule);
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
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

procedure TLspDocumentSync.SendDidOpen(const APath, AText: string;
  AVersion: Integer);
var
  LParams, LDoc: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  LDoc.AddPair('uri', PathToLspUri(APath));
  LDoc.AddPair('languageId', 'pascal');
  LDoc.AddPair('version', TJSONNumber.Create(AVersion));
  LDoc.AddPair('text', AText);
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

procedure TLspDocumentSync.Sync;
var
  LOpen: TArray<TSentDocument>;
  LDoc, LKnown: TSentDocument;
  LKey: string;
  LSeen: TDictionary<string, Boolean>;
  LStale: TArray<string>;
begin
  LOpen := CollectOpenDocuments;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LDoc in LOpen do
    begin
      LKey := LowerCase(LDoc.Path);
      LSeen.AddOrSetValue(LKey, True);

      if not FSent.TryGetValue(LKey, LKnown) then
      begin
        LDoc.Version := 1;
        SendDidOpen(LDoc.Path, LDoc.Text, LDoc.Version);
        FSent.Add(LKey, LDoc);       // FSent owns it from here
        Continue;
      end;

      if LKnown.Text <> LDoc.Text then
      begin
        Inc(LKnown.Version);
        LKnown.Text := LDoc.Text;
        SendDidChange(LKnown.Path, LKnown.Text, LKnown.Version);
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
      SendDidClose(FSent[LKey].Path);
      FSent.Remove(LKey);
    end;
  finally
    LSeen.Free;
  end;
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
    SendDidOpen(LDoc.Path, LDoc.Text, LDoc.Version);
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

end.
