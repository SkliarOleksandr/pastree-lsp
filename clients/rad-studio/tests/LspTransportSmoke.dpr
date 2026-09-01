program LspTransportSmoke;

{
  Exercises PasTreeIdePlugin.LspTransport against a real pastree-server.exe,
  outside the IDE. The transport unit deliberately depends on nothing but
  SysUtils/Classes/Windows, which is what makes this possible - and what makes
  the riskiest part of the plugin's LSP client (the Win32 pipe and process
  plumbing) testable without an IDE restart cycle.

  Deliberately built Win32, like the designtime package it is for, driving a
  Win64 server - the exact cross-bitness pairing the real plugin uses.

  Three scenarios, each asserting a property the plugin depends on:

  1. GRACEFUL   - initialize/shutdown/exit round trip, server leaves on its
                  own. The everyday path.
  2. ABRUPT     - free the connection with the server still live and a read
                  still pending. This is the BPL-unload path: teardown must
                  RETURN (a reader thread stuck in ReadFile inside a DLL being
                  unloaded is an IDE crash) and must leave NO ORPHAN process.
  3. SERVER DIES- kill the server behind the transport's back; the gone
                  callback must fire, which is what a restart policy will
                  eventually hang off.

  Usage: LspTransportSmoke.exe [path\to\pastree-server.exe]

  Console apps have no message loop, so CheckSynchronize is what runs the
  frame callbacks the reader thread marshals over with TThread.Queue; in the
  IDE the VCL does this for us.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  PasTreeIdePlugin.LspTransport;

const
  { The server this repo's own build.bat produces, as a path RELATIVE to the
    test exe's directory. Relative rather than absolute because since the
    package moved into the server's repository there is no sibling checkout to
    guess at - and an absolute C:\Repos\... default was only ever correct on
    one machine. Overridden by the first command-line argument. }
  cDefaultExeRel = '..\..\..\..\out\pastree-server.exe';
  cTimeoutMs = 20000;
  // Teardown is CancelIoEx plus at most a 1s wait on a server that already
  // saw stdin EOF. Anything near the transport's own 3s reader backstop means
  // the cancellable-read design is not working.
  cTeardownBudgetMs = 4000;

  cInitialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
    + '{"processId":null,"rootUri":null,"capabilities":{},'
    + '"initializationOptions":{}}}';

var
  GConn: TLspConnection;
  GInitialized: Boolean;
  GShutdownAcked: Boolean;
  GGone: string;
  GFrameCount: Integer;
  GFailures: Integer;
  // Set by OnFrame for the two protocol-robustness sections below.
  GPingAcked: Boolean;
  GLateRejected: Boolean;

procedure ResetState;
begin
  GInitialized := False;
  GShutdownAcked := False;
  GGone := '';
  GFrameCount := 0;
  GPingAcked := False;
  GLateRejected := False;
end;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    Writeln('  [ok]   ' + AWhat)
  else
  begin
    Writeln('  [FAIL] ' + AWhat);
    Inc(GFailures);
  end;
end;

function Abbrev(const AText: string; AMax: Integer): string;
begin
  if Length(AText) <= AMax then
    Exit(AText);
  Result := Copy(AText, 1, AMax) + Format('... (%d chars total)',
    [Length(AText)]);
end;

procedure OnFrame(const AJson: string);
begin
  Inc(GFrameCount);
  Writeln(Format('  <- frame %d: %s', [GFrameCount, Abbrev(AJson, 220)]));
  // Crude but sufficient: we only care that OUR two requests came back.
  if AJson.Contains('"capabilities"') then
    GInitialized := True;
  if AJson.Contains('"id":2') then
    GShutdownAcked := True;
  // id 77 is the "are you still listening" probe of section 4; id 78 the
  // post-shutdown request of section 5, which must come back as InvalidRequest.
  if AJson.Contains('"id":77') then
    GPingAcked := True;
  if AJson.Contains('"id":78') and AJson.Contains('-32600') then
    GLateRejected := True;
end;

procedure OnGone(const AReason: string);
begin
  GGone := AReason;
  Writeln('  ** gone: ' + AReason);
end;

/// <summary>
/// Pumps the RTL's synchronization queue (where the reader thread's frames
/// land) until ACondition holds or the deadline passes.
/// </summary>
function PumpUntil(const ACondition: TFunc<Boolean>;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := GetTickCount64 + ATimeoutMs;
  repeat
    CheckSynchronize(50);
    if ACondition then
      Exit(True);
  until GetTickCount64 >= LDeadline;
  Result := False;
end;

/// <summary>
/// True if APid is still a live process. Used to prove teardown leaves no
/// orphan - the property the whole stdio-lifetime argument rests on.
/// </summary>
function ProcessAlive(APid: DWORD): Boolean;
var
  LHandle: THandle;
  LCode: DWORD;
begin
  LHandle := OpenProcess(PROCESS_QUERY_INFORMATION, False, APid);
  if LHandle = 0 then
    Exit(False);   // gone (or at least unreachable, which is good enough)
  try
    Result := GetExitCodeProcess(LHandle, LCode) and (LCode = STILL_ACTIVE);
  finally
    CloseHandle(LHandle);
  end;
end;

procedure KillProcess(APid: DWORD);
var
  LHandle: THandle;
begin
  LHandle := OpenProcess(PROCESS_TERMINATE, False, APid);
  if LHandle = 0 then
    Exit;
  try
    TerminateProcess(LHandle, 99);
  finally
    CloseHandle(LHandle);
  end;
end;

{ The harness names its own stderr file, and that is the only reason one
  exists: the transport discards stderr when no path is given (no per-start
  temp file, see its header), but a harness that cannot show what a dying
  server said would be diagnosing blind. One fixed name, truncated per run. }
function StdErrFile: string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'pastree-lsp-smoke-stderr.log');
end;

function Connect(const AExe: string): TLspConnection;
begin
  ResetState;
  Result := TLspConnection.Create(AExe, ExtractFilePath(AExe), OnFrame, OnGone,
    StdErrFile);
  Writeln(Format('  spawned pid %d, stderr -> %s',
    [Result.ProcessId, Result.StdErrPath]));
end;

{ 1. The everyday path. }
procedure TestGraceful(const AExe: string);
var
  LPid: DWORD;
begin
  Writeln;
  Writeln('=== 1. graceful initialize / shutdown / exit ===');
  GConn := Connect(AExe);
  try
    LPid := GConn.ProcessId;

    Check(GConn.Send(cInitialize), 'Send(initialize) accepted');
    Check(PumpUntil(function: Boolean begin Result := GInitialized end,
      cTimeoutMs), 'initialize response received');

    Check(GConn.Send('{"jsonrpc":"2.0","method":"initialized","params":{}}'),
      'Send(initialized) accepted');
    Check(GConn.Send('{"jsonrpc":"2.0","id":2,"method":"shutdown"}'),
      'Send(shutdown) accepted');
    Check(PumpUntil(function: Boolean begin Result := GShutdownAcked end,
      cTimeoutMs), 'shutdown response received');

    GConn.Send('{"jsonrpc":"2.0","method":"exit"}');
    Check(GConn.WaitForExit(5000), 'server exited on its own after exit');
  finally
    FreeAndNil(GConn);
  end;
  Check(not ProcessAlive(LPid), 'no server process left behind');
end;

{ 2. The BPL-unload path: free while the server is live and a read is pending.
  This is what the overlapped/cancellable read exists for. }
procedure TestAbruptTeardown(const AExe: string);
var
  LPid: DWORD;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  Writeln;
  Writeln('=== 2. abrupt teardown with the server still live ===');
  GConn := Connect(AExe);
  LPid := GConn.ProcessId;

  Check(GConn.Send(cInitialize), 'Send(initialize) accepted');
  Check(PumpUntil(function: Boolean begin Result := GInitialized end,
    cTimeoutMs), 'initialize response received');
  Check(GConn.IsRunning, 'server is live going into teardown');

  // No shutdown, no exit - just drop it, exactly as an unexpected package
  // unload would.
  LStart := GetTickCount64;
  FreeAndNil(GConn);
  LElapsed := GetTickCount64 - LStart;
  Writeln(Format('  teardown returned in %d ms', [LElapsed]));
  Check(LElapsed < cTeardownBudgetMs,
    Format('teardown returned within %d ms', [cTeardownBudgetMs]));

  // Give a self-exiting server a moment; it should already be gone via EOF.
  Sleep(200);
  Check(not ProcessAlive(LPid), 'no orphan server after abrupt teardown');
end;

{ 3. Server dies underneath us: the gone callback is the signal a restart
  policy will hang off later. }
procedure TestServerDies(const AExe: string);
var
  LPid: DWORD;
begin
  Writeln;
  Writeln('=== 3. server killed behind the transport''s back ===');
  GConn := Connect(AExe);
  try
    LPid := GConn.ProcessId;
    Check(GConn.Send(cInitialize), 'Send(initialize) accepted');
    Check(PumpUntil(function: Boolean begin Result := GInitialized end,
      cTimeoutMs), 'initialize response received');

    KillProcess(LPid);
    Check(PumpUntil(function: Boolean begin Result := GGone <> '' end, 5000),
      'gone callback fired on the main thread');
    Check(not GConn.IsRunning, 'IsRunning reports the server is gone');
  finally
    FreeAndNil(GConn);
  end;
end;

{ 4. A MALFORMED $/cancelRequest MUST NOT DEAFEN THE SERVER.

  A cancel frame with a method and NO params member is well-formed JSON
  carrying the one method the server's READER THREAD inspects before queueing -
  so the reader used to dereference nil params and die. The cost was
  out of all proportion to the frame: the thread died without pushing its EOF
  sentinel, the dispatcher waited forever on a queue nothing would ever push
  to, and the server was deaf to every subsequent message for the rest of its
  life (only the client-pid watchdog could end it, and not even that if
  `initialize` carried no processId).

  So the check is not "no crash" but "still answering": a cancel for an id that
  never existed, then a real request, then an answer. }
procedure TestMalformedCancel(const AExe: string);
begin
  Writeln;
  Writeln('=== 4. a $/cancelRequest with no params leaves the server alive ===');
  GConn := Connect(AExe);
  try
    Check(GConn.Send(cInitialize), 'Send(initialize) accepted');
    Check(PumpUntil(function: Boolean begin Result := GInitialized end,
      cTimeoutMs), 'initialize response received');

    Check(GConn.Send('{"jsonrpc":"2.0","method":"$/cancelRequest"}'),
      'a params-less $/cancelRequest was sent');
    // And the other shapes the same code path has to survive.
    Check(GConn.Send('{"jsonrpc":"2.0","method":"$/cancelRequest",'
      + '"params":{}}'), 'and one whose params carry no id');
    Check(GConn.Send('{"jsonrpc":"2.0","method":"$/cancelRequest",'
      + '"params":{"id":999999}}'), 'and one for an id that never existed');

    Check(GConn.Send('{"jsonrpc":"2.0","id":77,'
      + '"method":"textDocument/documentSymbol","params":'
      + '{"textDocument":{"uri":"file:///c%3A/nosuch.pas"}}}'),
      'a real request was sent afterwards');
    Check(PumpUntil(function: Boolean begin Result := GPingAcked end,
      cTimeoutMs),
      'the server answered it - the reader thread is still running');
  finally
    FreeAndNil(GConn);
  end;
end;

{ 5. AFTER shutdown, EVERYTHING BUT exit IS InvalidRequest.

  The spec asks for it, and this server needs it for itself: `shutdown` frees
  the project and the navigator on purpose, so a straggler request - editors do
  send them while tearing a session down - would walk into the analysis wait
  with nothing analyzed and start a FULL rebuild of the project just
  invalidated, blocking the dispatcher and delaying `exit` by however long that
  takes. Everything it rebuilt is guaranteed garbage. }
procedure TestRequestAfterShutdown(const AExe: string);
var
  LPid: DWORD;
begin
  Writeln;
  Writeln('=== 5. a request between shutdown and exit is refused ===');
  GConn := Connect(AExe);
  try
    LPid := GConn.ProcessId;
    Check(GConn.Send(cInitialize), 'Send(initialize) accepted');
    Check(PumpUntil(function: Boolean begin Result := GInitialized end,
      cTimeoutMs), 'initialize response received');

    Check(GConn.Send('{"jsonrpc":"2.0","id":2,"method":"shutdown"}'),
      'Send(shutdown) accepted');
    Check(PumpUntil(function: Boolean begin Result := GShutdownAcked end,
      cTimeoutMs), 'shutdown response received');

    Check(GConn.Send('{"jsonrpc":"2.0","id":78,'
      + '"method":"textDocument/documentSymbol","params":'
      + '{"textDocument":{"uri":"file:///c%3A/nosuch.pas"}}}'),
      'a straggler request was sent after shutdown');
    Check(PumpUntil(function: Boolean begin Result := GLateRejected end,
      cTimeoutMs),
      'it came back as InvalidRequest (-32600) rather than being served');

    GConn.Send('{"jsonrpc":"2.0","method":"exit"}');
    Check(GConn.WaitForExit(5000),
      'and exit still works, promptly - nothing was rebuilt in between');
  finally
    FreeAndNil(GConn);
  end;
  Check(not ProcessAlive(LPid), 'no server process left behind');
end;

procedure DumpStdErr;
var
  LPath, LLine: string;
begin
  LPath := StdErrFile;
  if not TFile.Exists(LPath) then
    Exit;
  Writeln;
  Writeln('--- server stderr (' + LPath + ') ---');
  for LLine in TFile.ReadAllLines(LPath) do
    Writeln('  ' + LLine);
end;

var
  GExe: string;
begin
  try
    GExe := ParamStr(1);
    if GExe = '' then
      GExe := TPath.GetFullPath(TPath.Combine(
        ExtractFilePath(ParamStr(0)), cDefaultExeRel));
    Writeln('server: ' + GExe);

    // Truncated per run, not appended: the transport opens it in append mode,
    // so without this the dump would show every previous run's output too.
    if TFile.Exists(StdErrFile) then
      TFile.Delete(StdErrFile);

    GFailures := 0;
    TestGraceful(GExe);
    TestAbruptTeardown(GExe);
    TestServerDies(GExe);
    TestMalformedCancel(GExe);
    TestRequestAfterShutdown(GExe);
    DumpStdErr;

    Writeln;
    if GFailures = 0 then
      Writeln('RESULT: PASS')
    else
      Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := Ord(GFailures <> 0);
  except
    on E: Exception do
    begin
      Writeln(Format('RESULT: FAIL - %s: %s', [E.ClassName, E.Message]));
      ExitCode := 2;
    end;
  end;
end.
