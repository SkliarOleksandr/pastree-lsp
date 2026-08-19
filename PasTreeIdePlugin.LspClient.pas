unit PasTreeIdePlugin.LspClient;

{
  The JSON-RPC session on top of PasTreeIdePlugin.LspTransport: request ids,
  pending-response callbacks, the LSP lifecycle, and the restart policy. Knows
  LSP; knows nothing about ToolsAPI or the editor - that glue lives a layer up,
  which is also what lets this be driven from a console test harness.

  EVERYTHING HERE IS MAIN-THREAD ONLY, by design rather than by tolerance: the
  transport already marshals arriving frames onto the main thread, and every
  caller is an IDE event handler, so there is nothing to lock and no way for a
  callback to reach ToolsAPI from the wrong thread. Do not call any of this
  from a worker.

  NOTHING BLOCKS THE MAIN THREAD WAITING FOR A REPLY. Requests are fire-and-
  callback; the reply arrives on a later main-thread turn. This is the rule the
  whole out-of-process design rests on - running analysis synchronously on the
  UI thread is what made a deadlock possible in the in-process version (see
  the SingleThreaded comment in PasTreeIdePlugin.Analysis). A caller cannot
  have "the answer now"; it must accept the answer later, and must expect the
  editor to have moved on in between.

  REQUESTS BEFORE THE SERVER IS READY ARE QUEUED, NOT DROPPED. LSP forbids
  anything before the initialize handshake completes, and the user can very
  plausibly Ctrl+Click a second after the IDE finished loading. Such requests
  wait in FOutbox and flush the moment initialize is answered.

  RESTART IS LAZY, WITH NO TIMER. On a dead server we do not schedule a
  reconnect: the next request tries again, if the backoff has elapsed and the
  give-up count is not spent (EnsureStarted). Nothing needs a server until the
  user asks for something, and a timer owned by a designtime package is one
  more thing that can outlive an unload and crash the IDE.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  PasTreeIdePlugin.LspTransport;

type
  /// <summary>
  /// One request's answer, on the main thread. AResult is the `result` member,
  /// normalised to nil when the server answered null; on failure it is nil and
  /// AError explains. THE CLIENT OWNS AResult and frees it as soon as this
  /// returns - copy anything worth keeping.
  /// </summary>
  TLspResponseProc = reference to procedure(ASuccess: Boolean;
    AResult: TJSONValue; const AError: string);

  /// <summary>
  /// A server-initiated notification (window/logMessage,
  /// textDocument/publishDiagnostics, ...). AParams may be nil and is owned by
  /// the client.
  /// </summary>
  TLspNotifyProc = reference to procedure(const AMethod: string;
    AParams: TJSONValue);

  TLspLogProc = reference to procedure(const AText: string);

  TLspClientState = (
    lcsStopped,    // never started, or stopped on purpose
    lcsStarting,   // spawned, initialize sent, no answer yet
    lcsReady,      // handshake done, requests flow
    lcsFailed      // server died or would not start; see the restart policy
  );

  /// <summary>
  /// What the server needs to know about the project, mirroring
  /// initializationOptions in the server's own PasLsp.Server header. Nothing
  /// is mandatory: with no ProjectFile the server treats the open documents as
  /// the analysis roots.
  /// </summary>
  TLspInitOptions = record
    ProjectFile: string;      // the .dproj itself - the server evaluates it
    Platform: string;         // "Win64", "Win32", ... - a RAD Studio id
    Config: string;           // build configuration name, .dproj only
    SearchPaths: TArray<string>;
    Defines: TArray<string>;
    LogFile: string;
    /// <summary>Caller owns the returned object.</summary>
    function ToJson: TJSONObject;
  end;

  TLspClient = class
  private type
    TPendingRequest = class
      Id: Int64;
      Method: string;
      Callback: TLspResponseProc;
    end;
  private
    FExePath: string;
    FWorkDir: string;
    FOnLog: TLspLogProc;
    FOnNotification: TLspNotifyProc;
    FOnReady: TProc;
    FConn: TLspConnection;
    FState: TLspClientState;
    FOptions: TLspInitOptions;
    FStarted: Boolean;        // Start was called; restarts are allowed
    FNextId: Int64;
    FPending: TObjectDictionary<Int64, TPendingRequest>;
    FOutbox: TList<string>;   // frames held back until the handshake lands
    FServerInfo: string;
    // Connections replaced but not yet freed, and how deeply we are currently
    // nested inside a connection's own callback - see RetireConnection.
    FRetired: TObjectList<TLspConnection>;
    FDispatchDepth: Integer;
    FRestarting: Boolean;
    // Restart policy
    FAttempts: Integer;
    FLastAttemptTick: UInt64;
    FGaveUpLogged: Boolean;
    procedure Log(const AText: string);
    function Connect: Boolean;
    procedure Teardown;
    /// <summary>
    /// Detaches the current connection and disposes of it as soon as that is
    /// safe. NEVER frees it outright, because this can be reached from inside a
    /// callback that the connection's own reader thread queued: freeing it there
    /// would destroy the object whose method is on the stack, and the RTL still
    /// handles the queued entry after our closure returns.
    /// </summary>
    procedure RetireConnection;
    procedure DisposeRetired;
    /// <summary>
    /// Drops every queued frame AND fails the requests they belonged to.
    /// </summary>
    procedure DiscardOutbox(const AReason: string);
    function BackoffMs: UInt64;
    /// <summary>
    /// True if a request can be issued now: the server is up, or was
    /// restarted by this very call (leaving the request to be queued).
    /// </summary>
    function EnsureStarted: Boolean;
    procedure HandleFrame(const AJson: string);
    procedure HandleResponse(AId: Int64; AObj: TJSONObject);
    procedure HandleServerRequest(AIdJson: TJSONValue; const AMethod: string);
    procedure OnConnectionGone(const AReason: string);
    procedure SendInitialize;
    procedure OnInitializeAnswered(ASuccess: Boolean; AResult: TJSONValue;
      const AError: string);
    procedure FlushOutbox;
    procedure FailAllPending(const AReason: string);
    /// <summary>
    /// Writes AJson now if the server is ready, queues it while the handshake
    /// is in flight, otherwise fails. Lifecycle frames bypass the queue:
    /// initialize cannot wait for the readiness it is establishing.
    /// </summary>
    function SendOrQueue(const AJson: string; AIsLifecycle: Boolean): Boolean;
  public
    constructor Create(const AExePath, AWorkDir: string;
      const AOnLog: TLspLogProc);
    destructor Destroy; override;

    /// <summary>
    /// Spawns the server and begins the handshake. False if the process could
    /// not be started (the reason is logged). Calling it again reconfigures
    /// from scratch: the old server is stopped and the give-up count cleared.
    /// </summary>
    function Start(const AOptions: TLspInitOptions): Boolean;

    /// <summary>
    /// Graceful stop: shutdown + exit, then drop the connection. Does not wait
    /// for the shutdown response - the transport's teardown already makes
    /// stdin EOF the reliable signal, and waiting here would mean pumping the
    /// main thread.
    /// </summary>
    procedure Stop;

    /// <summary>
    /// Lets a dead server be retried on the next request even if the give-up
    /// count was spent. For an explicit, user-driven retry.
    /// </summary>
    procedure ResetRestartPolicy;

    /// <summary>
    /// Sends a request and returns its id, or 0 if it could be neither sent
    /// nor queued. TAKES OWNERSHIP of AParams. AOnResponse fires exactly
    /// once: with the answer, or with ASuccess=False if the server died or
    /// the send failed.
    /// </summary>
    function Request(const AMethod: string; AParams: TJSONObject;
      const AOnResponse: TLspResponseProc): Int64;

    /// <summary>
    /// Asks the server to abandon a request. The response still arrives (as
    /// an error), so the callback still fires exactly once.
    /// </summary>
    procedure Cancel(AId: Int64);

    /// <summary>TAKES OWNERSHIP of AParams.</summary>
    procedure Notify(const AMethod: string; AParams: TJSONObject);

    /// <summary>True when a request can actually reach the server now.</summary>
    function IsReady: Boolean;

    /// <summary>Where the server's stderr goes; '' if not running.</summary>
    function StdErrPath: string;

    /// <summary>The server's process id, or 0 if none. For diagnostics.</summary>
    function ProcessId: Cardinal;

    property State: TLspClientState read FState;
    property ServerInfo: string read FServerInfo;
    property OnNotification: TLspNotifyProc read FOnNotification
      write FOnNotification;

    /// <summary>
    /// Fires each time the handshake completes - on the first start AND after
    /// every restart - before any queued request is flushed. This is where the
    /// document layer re-sends its open documents: a fresh server has none of
    /// them, so without this it would answer from stale text on disk.
    /// </summary>
    property OnReady: TProc read FOnReady write FOnReady;
  end;

/// <summary>
/// Locates pastree-server.exe: PASTREE_LSP_SERVER wins (the development
/// override), otherwise it is looked for in ANearDir - normally the directory
/// the package's own BPL sits in. '' if neither exists; callers report that
/// rather than guessing further. A set-but-wrong override deliberately does
/// NOT fall back, so a typo shows up as an error instead of silently running
/// some other build.
/// </summary>
function FindServerExe(const ANearDir: string): string;

/// <summary>
/// C:\dir\file.pas -> file:///c%3A/dir/file.pas, and back. Deliberately
/// byte-for-byte the same canonical form as the server's own PasLsp.Protocol
/// (lower-cased drive letter, ':' percent-encoded): URIs are compared as
/// strings on both sides, so two spellings of the same file would silently
/// look like two different documents. Keep these in step with that unit.
/// </summary>
function PathToLspUri(const APath: string): string;
function LspUriToPath(const AUri: string): string;

const
  cLspServerExeName = 'pastree-server.exe';
  cLspMethodNotFound = -32601;
  cLspRequestCancelled = -32800;

implementation

uses
  System.IOUtils,
  Winapi.Windows;

const
  // Five tries, then stop pestering: a server that will not start is usually
  // misconfigured, and respawning on every Ctrl+Click turns one problem into
  // a stream of them.
  cMaxRestartAttempts = 5;
  cBackoffBaseMs = 1000;
  cBackoffCapMs = 30000;

function FindServerExe(const ANearDir: string): string;
var
  LEnv, LCandidate: string;
begin
  LEnv := GetEnvironmentVariable('PASTREE_LSP_SERVER');
  if LEnv <> '' then
  begin
    if TFile.Exists(LEnv) then
      Exit(LEnv);
    Exit('');
  end;
  if ANearDir <> '' then
  begin
    LCandidate := TPath.Combine(ANearDir, cLspServerExeName);
    if TFile.Exists(LCandidate) then
      Exit(LCandidate);
  end;
  Result := '';
end;

function PathToLspUri(const APath: string): string;
const
  cUnreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'];
var
  LNorm: string;
  LSB: TStringBuilder;
  LByte: Byte;
begin
  LNorm := APath.Replace('\', '/');
  if (Length(LNorm) >= 2) and (LNorm[2] = ':') then
    LNorm := '/' + LowerCase(LNorm[1]) + Copy(LNorm, 2, MaxInt);
  LSB := TStringBuilder.Create;
  try
    LSB.Append('file://');
    for LByte in TEncoding.UTF8.GetBytes(LNorm) do
      if (LByte < 128) and (AnsiChar(LByte) in cUnreserved) then
        LSB.Append(Char(LByte))
      else
        LSB.AppendFormat('%%%.2X', [LByte]);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

function LspUriToPath(const AUri: string): string;

  function HexVal(AChar: Char): Integer;
  begin
    case AChar of
      '0'..'9': Result := Ord(AChar) - Ord('0');
      'a'..'f': Result := Ord(AChar) - Ord('a') + 10;
      'A'..'F': Result := Ord(AChar) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

var
  LRest: string;
  LBytes: TBytes;
  LIdx, LH, LL: Integer;
begin
  Result := '';
  if not AUri.StartsWith('file://', True) then
    Exit;
  LRest := Copy(AUri, Length('file://') + 1, MaxInt);
  // Percent-decode into UTF-8 bytes and decode the bytes once at the end: a
  // single escape may be one byte of a multi-byte character.
  LBytes := nil;
  LIdx := 1;
  while LIdx <= Length(LRest) do
  begin
    if (LRest[LIdx] = '%') and (LIdx + 2 <= Length(LRest)) then
    begin
      LH := HexVal(LRest[LIdx + 1]);
      LL := HexVal(LRest[LIdx + 2]);
      if (LH >= 0) and (LL >= 0) then
      begin
        LBytes := LBytes + [Byte(LH * 16 + LL)];
        Inc(LIdx, 3);
        Continue;
      end;
    end;
    LBytes := LBytes + TEncoding.UTF8.GetBytes(LRest[LIdx]);
    Inc(LIdx);
  end;
  Result := TEncoding.UTF8.GetString(LBytes);
  // file:///c:/x -> c:\x ; file://server/share stays \\server\share.
  if (Length(Result) >= 3) and (Result[1] = '/') and (Result[3] = ':') then
    Delete(Result, 1, 1)
  else if (Result <> '') and (Result[1] <> '/') then
    Result := '\\' + Result;
  Result := Result.Replace('/', '\');
end;

{ TLspInitOptions }

function TLspInitOptions.ToJson: TJSONObject;
var
  LResult: TJSONObject;

  procedure AddStrings(const AName: string; const AValues: TArray<string>);
  var
    LArr: TJSONArray;
    LValue: string;
  begin
    if Length(AValues) = 0 then
      Exit;
    LArr := TJSONArray.Create;
    for LValue in AValues do
      LArr.Add(LValue);
    LResult.AddPair(AName, LArr);
  end;

begin
  LResult := TJSONObject.Create;
  if ProjectFile <> '' then
    LResult.AddPair('projectFile', ProjectFile);
  if Platform <> '' then
    LResult.AddPair('platform', Platform);
  if Config <> '' then
    LResult.AddPair('config', Config);
  if LogFile <> '' then
    LResult.AddPair('logFile', LogFile);
  // Real JSON arrays: the server logs a warning and ignores any other shape,
  // which already cost this project a debugging round once.
  AddStrings('searchPaths', SearchPaths);
  AddStrings('defines', Defines);
  Result := LResult;
end;

{ TLspClient }

constructor TLspClient.Create(const AExePath, AWorkDir: string;
  const AOnLog: TLspLogProc);
begin
  inherited Create;
  FExePath := AExePath;
  FWorkDir := AWorkDir;
  FOnLog := AOnLog;
  FPending := TObjectDictionary<Int64, TPendingRequest>.Create([doOwnsValues]);
  FOutbox := TList<string>.Create;
  FRetired := TObjectList<TLspConnection>.Create(True);
  FState := lcsStopped;
  FNextId := 1;
end;

destructor TLspClient.Destroy;
begin
  Teardown;
  DisposeRetired;
  FRetired.Free;
  FOutbox.Free;
  FPending.Free;
  inherited;
end;

procedure TLspClient.RetireConnection;
begin
  if not Assigned(FConn) then
    Exit;
  FRetired.Add(FConn);   // FRetired owns it now
  FConn := nil;
  DisposeRetired;        // a no-op while we are inside a dispatch
end;

procedure TLspClient.DisposeRetired;
begin
  // Freeing a connection joins its reader thread and drops that thread's queued
  // closures. Doing so while one of those closures is on the stack is a
  // use-after-free, so disposal waits for the dispatch to unwind - the next
  // Request, Teardown or destructor picks it up.
  if (FDispatchDepth > 0) or (FRetired.Count = 0) then
    Exit;
  FRetired.Clear;
end;

procedure TLspClient.Log(const AText: string);
begin
  if Assigned(FOnLog) then
    FOnLog(AText);
end;

function TLspClient.StdErrPath: string;
begin
  if Assigned(FConn) then
    Result := FConn.StdErrPath
  else
    Result := '';
end;

function TLspClient.ProcessId: Cardinal;
begin
  if Assigned(FConn) then
    Result := FConn.ProcessId
  else
    Result := 0;
end;

function TLspClient.IsReady: Boolean;
begin
  Result := (FState = lcsReady) and Assigned(FConn) and FConn.IsRunning;
end;

function TLspClient.Start(const AOptions: TLspInitOptions): Boolean;
begin
  Teardown;
  FOptions := AOptions;
  FStarted := True;
  FAttempts := 0;
  FGaveUpLogged := False;
  Result := Connect;
end;

procedure TLspClient.Stop;
begin
  FStarted := False;   // an explicit stop must not be undone by a restart
  Teardown;
end;

function TLspClient.Connect: Boolean;
begin
  // Never overwrite a live connection. Teardown and FailAllPending both invoke
  // callbacks, and a callback that issues a request can reach EnsureStarted and
  // connect underneath us; assigning over FConn here would leak that
  // connection, its handles and its reader thread, and orphan a live server.
  RetireConnection;

  Inc(FAttempts);
  FLastAttemptTick := GetTickCount64;
  try
    // Both callbacks bracket themselves with FDispatchDepth so that anything
    // they reach - a restart, a reconfigure - defers freeing this very
    // connection until the dispatch has unwound. See RetireConnection.
    FConn := TLspConnection.Create(FExePath, FWorkDir,
      procedure(const AJson: string)
      begin
        Inc(FDispatchDepth);
        try
          HandleFrame(AJson);
        finally
          Dec(FDispatchDepth);
        end;
      end,
      procedure(const AReason: string)
      begin
        Inc(FDispatchDepth);
        try
          OnConnectionGone(AReason);
        finally
          Dec(FDispatchDepth);
        end;
      end);
  except
    on E: ELspTransport do
    begin
      FConn := nil;
      FState := lcsFailed;
      Log('cannot start server: ' + E.Message);
      Exit(False);
    end;
  end;
  FState := lcsStarting;
  Log(Format('server started (pid %d), stderr: %s',
    [FConn.ProcessId, FConn.StdErrPath]));
  SendInitialize;
  Result := True;
end;

procedure TLspClient.Teardown;
begin
  if Assigned(FConn) then
  begin
    // Best-effort politeness. The transport's destructor is what actually
    // guarantees the server goes away (stdin EOF, then escalation), so there
    // is nothing to wait for here. Id 0 cannot collide: FNextId starts at 1.
    if FConn.IsRunning then
    begin
      FConn.Send('{"jsonrpc":"2.0","id":0,"method":"shutdown"}');
      FConn.Send('{"jsonrpc":"2.0","method":"exit"}');
    end;
    RetireConnection;
  end;
  FState := lcsStopped;
  FServerInfo := '';
  DiscardOutbox('server stopped');
  DisposeRetired;   // normally already done; picks up a deferred disposal
end;

procedure TLspClient.ResetRestartPolicy;
begin
  FAttempts := 0;
  FLastAttemptTick := 0;
  FGaveUpLogged := False;
end;

function TLspClient.BackoffMs: UInt64;
var
  LShift: Integer;
begin
  LShift := FAttempts - 1;
  if LShift < 0 then
    LShift := 0;
  if LShift > 5 then
    LShift := 5;
  Result := UInt64(cBackoffBaseMs) shl LShift;
  if Result > cBackoffCapMs then
    Result := cBackoffCapMs;
end;

function TLspClient.EnsureStarted: Boolean;
begin
  if Assigned(FConn) and FConn.IsRunning and
     (FState in [lcsStarting, lcsReady]) then
    Exit(True);

  // Reentered from a callback that this very restart is failing - see below.
  if FRestarting then
    Exit(False);

  if not FStarted then
    Exit(False);   // Start has never been called: no options to start with

  if FAttempts >= cMaxRestartAttempts then
  begin
    if not FGaveUpLogged then
    begin
      FGaveUpLogged := True;
      Log(Format('giving up on the server after %d attempts - fix the cause '
        + 'and reload the package (stderr: %s)', [FAttempts, StdErrPath]));
    end;
    Exit(False);
  end;

  if (FLastAttemptTick <> 0) and
     (GetTickCount64 - FLastAttemptTick < BackoffMs) then
    Exit(False);   // still inside the backoff window

  // Retire rather than free: this can be reached from inside a callback the
  // dying connection's own reader thread queued (see RetireConnection).
  RetireConnection;

  { Fail whatever the dead server will never answer, and do it BEFORE
    connecting: Connect issues the new handshake, which registers a pending
    request of its own, and sweeping that away would kill the very handshake we
    are starting - leaving the client permanently in lcsFailed.

    This sweep cannot be left to OnConnectionGone, which normally performs it:
    that runs from a closure the reader thread queued, and disposing of the
    connection calls TThread.RemoveQueuedEvents, which DELETES that closure if
    it has not been dispatched yet. A crash with a request outstanding, followed
    by a Ctrl+Click processed before the queued notification, would otherwise
    strand the earlier request's callback forever.

    FRestarting keeps a callback that responds by asking again from starting a
    second server underneath this one; it gets 'server unavailable' and the
    restart in progress continues. }
  FRestarting := True;
  try
    DiscardOutbox('server restarted; earlier request abandoned');
  finally
    FRestarting := False;
  end;

  Log(Format('restarting server (attempt %d)', [FAttempts + 1]));
  // Connect leaves us in lcsStarting, so the request that triggered this gets
  // queued rather than lost.
  Result := Connect;
end;

procedure TLspClient.SendInitialize;
var
  LParams: TJSONObject;
begin
  LParams := TJSONObject.Create;
  // processId lets the server notice an orphaning parent; rootUri stays null
  // because projectFile in initializationOptions is what scopes the analysis.
  LParams.AddPair('processId', TJSONNumber.Create(GetCurrentProcessId));
  LParams.AddPair('rootUri', TJSONNull.Create);
  LParams.AddPair('capabilities', TJSONObject.Create);
  LParams.AddPair('initializationOptions', FOptions.ToJson);
  Request('initialize', LParams, OnInitializeAnswered);
end;

procedure TLspClient.OnInitializeAnswered(ASuccess: Boolean;
  AResult: TJSONValue; const AError: string);
var
  LInfo: TJSONObject;
  LReady: string;
begin
  if not ASuccess then
  begin
    FState := lcsFailed;
    Log('initialize failed: ' + AError);
    // Every queued frame is now undeliverable. Clearing the outbox WITHOUT
    // failing the matching pending entries would silently break the
    // fire-exactly-once contract this class documents: a request queued behind
    // a handshake that then failed would never hear anything back, so the
    // feature that made it waits forever and the user's click vanishes.
    DiscardOutbox('initialize failed: ' + AError);
    Exit;
  end;

  if (AResult is TJSONObject) and
     TJSONObject(AResult).TryGetValue<TJSONObject>('serverInfo', LInfo) then
    FServerInfo := LInfo.GetValue<string>('name', '?') + ' ' +
      LInfo.GetValue<string>('version', '?');

  FState := lcsReady;
  // A completed handshake is what "working" means, so the whole failure
  // history goes - the attempt count AND the backoff clock. Measuring backoff
  // from the last attempt instead would punish a server that ran fine and then
  // died: the retry it deserves immediately would be blocked for a second
  // because it happened to crash soon after starting. Repeated crash loops
  // still back off, because a crash before the handshake never resets this.
  // There is no runaway risk even so: restart is lazy, so a server that
  // crashes every time costs one respawn per user action, not a spin.
  ResetRestartPolicy;
  Notify('initialized', TJSONObject.Create);

  LReady := 'server ready';
  if FServerInfo <> '' then
    LReady := LReady + ': ' + FServerInfo;
  Log(LReady);

  // Before the queued requests: a restarted server knows nothing about the
  // documents the editor has open, and answering a queued request against
  // stale-on-disk text would be worse than answering it a moment later. The
  // document layer re-sends its didOpen set from here.
  if Assigned(FOnReady) then
    FOnReady;

  FlushOutbox;
end;

{ Drops every queued frame and fails the requests they belonged to. The two go
  together: a pending entry whose frame was thrown away can never be answered,
  and leaving it in FPending turns "fires exactly once" into "never fires". }
procedure TLspClient.DiscardOutbox(const AReason: string);
begin
  FOutbox.Clear;
  FailAllPending(AReason);
end;

procedure TLspClient.FlushOutbox;
var
  LIdx: Integer;
begin
  if not Assigned(FConn) then
  begin
    DiscardOutbox('no connection to send queued requests on');
    Exit;
  end;
  // Indexed, not for-in: the failure path mutates FOutbox, which would
  // invalidate an active enumerator.
  for LIdx := 0 to FOutbox.Count - 1 do
    if not FConn.Send(FOutbox[LIdx]) then
    begin
      Log('send failed while flushing queued requests');
      // The connection is gone mid-flush; nothing after this frame went out
      // either, so fail the lot rather than leave callers waiting.
      DiscardOutbox('connection lost while sending queued requests');
      Exit;
    end;
  FOutbox.Clear;
end;

procedure TLspClient.FailAllPending(const AReason: string);
var
  LItems: TArray<TPendingRequest>;
  LCallbacks: TArray<TLspResponseProc>;
  I: Integer;
begin
  if FPending.Count = 0 then
    Exit;
  // Snapshot the callbacks and empty the map BEFORE invoking any of them: a
  // callback is free to issue a new request, and that must not be wiped out
  // by the clear, nor may it mutate a dictionary we are still walking.
  LItems := FPending.Values.ToArray;
  SetLength(LCallbacks, Length(LItems));
  for I := 0 to High(LItems) do
    LCallbacks[I] := LItems[I].Callback;
  FPending.Clear;
  for I := 0 to High(LCallbacks) do
    if Assigned(LCallbacks[I]) then
      LCallbacks[I](False, nil, AReason);
end;

function TLspClient.SendOrQueue(const AJson: string;
  AIsLifecycle: Boolean): Boolean;
begin
  if not Assigned(FConn) then
    Exit(False);
  if AIsLifecycle or (FState = lcsReady) then
    Exit(FConn.Send(AJson));
  if FState = lcsStarting then
  begin
    FOutbox.Add(AJson);
    Exit(True);
  end;
  Result := False;
end;

function TLspClient.Request(const AMethod: string; AParams: TJSONObject;
  const AOnResponse: TLspResponseProc): Int64;
var
  LId: Int64;
  LMsg: TJSONObject;
  LJson: string;
  LPending: TPendingRequest;
  LIsLifecycle: Boolean;
  LCallback: TLspResponseProc;
begin
  Result := 0;
  // A safe point to collect any connection whose disposal was deferred because
  // we were inside its own callback at the time.
  DisposeRetired;
  LIsLifecycle := SameText(AMethod, 'initialize');

  if not LIsLifecycle and not EnsureStarted then
  begin
    AParams.Free;
    if Assigned(AOnResponse) then
      AOnResponse(False, nil, 'server unavailable');
    Exit;
  end;

  LId := FNextId;
  Inc(FNextId);

  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('jsonrpc', '2.0');
    LMsg.AddPair('id', TJSONNumber.Create(LId));
    LMsg.AddPair('method', AMethod);
    if Assigned(AParams) then
      LMsg.AddPair('params', AParams);   // LMsg owns AParams from here
    LJson := LMsg.ToJSON;
  finally
    LMsg.Free;
  end;

  LPending := TPendingRequest.Create;
  LPending.Id := LId;
  LPending.Method := AMethod;
  LPending.Callback := AOnResponse;
  FPending.Add(LId, LPending);

  if SendOrQueue(LJson, LIsLifecycle) then
    Exit(LId);

  // Could not be sent: fail it here so no caller waits forever. Copy the
  // callback out first - Remove frees the entry.
  LCallback := LPending.Callback;
  FPending.Remove(LId);
  if Assigned(LCallback) then
    LCallback(False, nil, 'send failed');
end;

procedure TLspClient.Cancel(AId: Int64);
var
  LParams: TJSONObject;
begin
  if not FPending.ContainsKey(AId) then
    Exit;   // already answered; the server has nothing to cancel
  LParams := TJSONObject.Create;
  LParams.AddPair('id', TJSONNumber.Create(AId));
  Notify('$/cancelRequest', LParams);
end;

procedure TLspClient.Notify(const AMethod: string; AParams: TJSONObject);
var
  LMsg: TJSONObject;
  LJson: string;
begin
  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('jsonrpc', '2.0');
    LMsg.AddPair('method', AMethod);
    if Assigned(AParams) then
      LMsg.AddPair('params', AParams);
    LJson := LMsg.ToJSON;
  finally
    LMsg.Free;
  end;
  SendOrQueue(LJson, SameText(AMethod, 'initialized') or
    SameText(AMethod, 'exit'));
end;

procedure TLspClient.HandleFrame(const AJson: string);
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LIdVal: TJSONValue;
  LMethod: string;
  LId: Int64;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if LRoot = nil then
  begin
    Log('unparseable frame from server: ' + Copy(AJson, 1, 200));
    Exit;
  end;
  try
    if not (LRoot is TJSONObject) then
      Exit;   // LSP has no batches
    LObj := TJSONObject(LRoot);
    LMethod := LObj.GetValue<string>('method', '');
    LIdVal := LObj.FindValue('id');

    if LMethod = '' then
    begin
      if (LIdVal <> nil) and LIdVal.TryGetValue<Int64>(LId) then
        HandleResponse(LId, LObj)
      else
        Log('response with no usable id - ignored');
      Exit;
    end;

    if LIdVal <> nil then
      HandleServerRequest(LIdVal, LMethod)
    else if Assigned(FOnNotification) then
      FOnNotification(LMethod, LObj.FindValue('params'));
  finally
    LRoot.Free;
  end;
end;

procedure TLspClient.HandleResponse(AId: Int64; AObj: TJSONObject);
var
  LPending: TPendingRequest;
  LCallback: TLspResponseProc;
  LError, LResult: TJSONValue;
  LMessage: string;
begin
  if not FPending.TryGetValue(AId, LPending) then
  begin
    // A late answer to something we already gave up on (a cancelled request
    // whose connection was replaced, typically) - not an error.
    Log(Format('response for unknown id %d - ignored', [AId]));
    Exit;
  end;

  LCallback := LPending.Callback;
  FPending.Remove(AId);   // frees LPending; the callback was copied out first
  if not Assigned(LCallback) then
    Exit;

  LError := AObj.FindValue('error');
  if LError <> nil then
  begin
    LMessage := 'server error';
    if LError is TJSONObject then
      LMessage := TJSONObject(LError).GetValue<string>('message', LMessage);
    LCallback(False, nil, LMessage);
    Exit;
  end;

  // Normalise an explicit JSON null to nil so callers have one "no answer"
  // shape to test instead of two.
  LResult := AObj.FindValue('result');
  if LResult is TJSONNull then
    LResult := nil;
  LCallback(True, LResult, '');
end;

procedure TLspClient.HandleServerRequest(AIdJson: TJSONValue;
  const AMethod: string);
begin
  // We advertise no client capabilities, so this should not happen. Answering
  // anyway matters: an unanswered request leaves the server waiting forever.
  Log('unsupported server request: ' + AMethod);
  if Assigned(FConn) then
    FConn.Send(Format(
      '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":"not supported"}}',
      [AIdJson.ToJSON, cLspMethodNotFound]));
end;

procedure TLspClient.OnConnectionGone(const AReason: string);
begin
  if FState = lcsStopped then
    Exit;   // our own teardown closing the pipe

  FState := lcsFailed;
  Log(Format('server connection lost: %s (stderr: %s)',
    [AReason, StdErrPath]));
  FOutbox.Clear;
  FailAllPending('server connection lost: ' + AReason);
  // FConn is deliberately NOT freed here - see EnsureStarted for why.
end;

end.
