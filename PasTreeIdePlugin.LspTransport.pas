unit PasTreeIdePlugin.LspTransport;

{
  Win32 plumbing for talking to pastree-server.exe: spawn the child, own the
  pipes, frame and unframe LSP messages, tear it all down safely. Knows
  nothing about LSP semantics - it moves JSON strings in and out.

  THE HYBRID TRANSPORT. The server reads plain stdin/stdout (see the LSP
  server repo's PasLsp.Transport - GetStdHandle, one code path shared with
  the VS Code client). We do NOT use CreatePipe for those. Instead we create
  two uniquely-named pipes ourselves, keep the OVERLAPPED end, and hand the
  synchronous end to the child as its std handles. The server is unchanged
  and unaware; we get two things anonymous pipes cannot give us:

  1. CANCELLABLE READS. CreatePipe returns synchronous handles, and a thread
     blocked in ReadFile on one cannot be woken - the LSP server itself
     documents this in TLspReader.Destroy, where it only gets away with it
     because process exit follows immediately. We are a DESIGNTIME PACKAGE:
     the BPL can be unloaded (Uninstall, IDE shutdown) while our reader
     thread is parked in ReadFile, and unloading a DLL whose code a live
     thread is executing crashes the IDE. With FILE_FLAG_OVERLAPPED the read
     waits on an event pair and CancelIoEx ends it on demand - see
     TLspReaderThread.Execute and TLspConnection.Destroy's ordered teardown.
  2. EXPLICIT HANDLE INHERITANCE. CreateProcess with bInheritHandles=True
     inherits EVERY inheritable handle in the process, and our process is the
     whole RAD Studio IDE - files, sockets, whatever it happens to have open.
     A child holding one of those keeps it alive behind the IDE's back (a
     file staying locked after the IDE closed it, classically).
     PROC_THREAD_ATTRIBUTE_HANDLE_LIST via STARTUPINFOEX narrows inheritance
     to exactly the three handles we mean to pass.

  What we give up versus a real listening named pipe is reattaching to an
  already-warm server after a package reload. Deliberate: process lifetime
  stays automatic (the child sees EOF when our handles close and exits by
  itself - no orphan after an IDE crash, no watchdog), and we can add a
  listening mode later if losing warm caches actually turns out to hurt.

  STDERR goes to a FILE, not a pipe. The server logs diagnostics there, and
  an undrained pipe would wedge the server the moment its 64 KB buffer
  filled. A file needs no reader thread and survives a crash for reading
  afterwards. Routing it into the Messages panel means switching this one
  handle to a pipe plus a drain thread - a later step, not a redesign.

  THREADING. Send is for the main thread only. Frames arrive on the reader
  thread and are marshalled to the main thread via TThread.Queue, so the
  callbacks run where ToolsAPI can be touched. Teardown order is load
  bearing and spelled out in TLspConnection.Destroy.
}

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows;

type
  ELspTransport = class(Exception);

  /// <summary>
  /// Called on the MAIN thread, once per complete message received.
  /// </summary>
  TLspFrameProc = reference to procedure(const AJson: string);

  /// <summary>
  /// Called on the MAIN thread when the connection ends - the server exited,
  /// closed its end, or the stream broke. Fires at most once.
  /// </summary>
  TLspGoneProc = reference to procedure(const AReason: string);

  /// <summary>
  /// Byte-stream to LSP-message reassembly: `Content-Length: N\r\n\r\n` plus
  /// N bytes of UTF-8 JSON. A pipe read boundary lands anywhere - mid-header,
  /// mid-payload - so bytes accumulate here until a whole frame is present.
  /// Not thread safe; owned by the reader thread alone.
  /// </summary>
  TLspFrameParser = class
  private
    FBuf: TBytes;
    FLen: Integer;
  public
    procedure Append(ABytes: PByte; ACount: Integer);
    /// <summary>
    /// Pops one complete message, or False if the buffer does not hold one
    /// yet. Raises ELspTransport on a header with no Content-Length: a frame
    /// stream cannot be resynchronised, so the connection is finished.
    /// </summary>
    function NextFrame(out AJson: string): Boolean;
  end;

  TLspConnection = class;

  TLspReaderThread = class(TThread)
  private
    FOwner: TLspConnection;
    FPipe: THandle;
    FStopEvent: THandle;
    FReadEvent: THandle;
    FParser: TLspFrameParser;
    procedure QueueFrame(const AJson: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLspConnection; APipe, AStopEvent: THandle);
    destructor Destroy; override;
  end;

  /// <summary>
  /// One live pastree-server.exe and the pipes to it. Construct to spawn,
  /// free to tear down.
  /// </summary>
  TLspConnection = class
  private
    FWriteEnd: THandle;       // our end of the server's stdin
    FReadEnd: THandle;        // our end of the server's stdout
    FStdErrFile: THandle;     // handed to the child, never read by us
    FProcess: THandle;
    FProcessId: DWORD;
    FStopEvent: THandle;      // signals the reader thread to unwind
    FWriteEvent: THandle;     // OVERLAPPED.hEvent for Send
    FReader: TLspReaderThread;
    FStdErrPath: string;
    FOnFrame: TLspFrameProc;
    FOnGone: TLspGoneProc;
    FGoneReported: Boolean;
    procedure Spawn(const AExePath, AWorkDir: string; AChildIn, AChildOut: THandle);
    procedure CloseAll;
  protected
    /// <summary>
    /// Reader-thread entry points, both marshalling to the main thread.
    /// </summary>
    procedure DispatchFrame(const AJson: string);
    procedure DispatchGone(const AReason: string);
  public
    /// <summary>
    /// Spawns AExePath and starts reading. Raises ELspTransport if the exe is
    /// missing or the process cannot be started - nothing is left running.
    /// AOnFrame/AOnGone are invoked on the main thread.
    /// </summary>
    constructor Create(const AExePath, AWorkDir: string;
      const AOnFrame: TLspFrameProc; const AOnGone: TLspGoneProc);
    destructor Destroy; override;

    /// <summary>
    /// Frames AJson and writes it to the server's stdin. MAIN THREAD ONLY.
    /// Bounded wait (cWriteTimeoutMs): a wedged server must never park the
    /// IDE's main thread indefinitely. False = the write failed or timed out,
    /// i.e. this connection is dead - the caller should not keep using it.
    /// </summary>
    function Send(const AJson: string): Boolean;

    /// <summary>
    /// True while the child process is alive.
    /// </summary>
    function IsRunning: Boolean;

    /// <summary>
    /// Waits out a shutting-down server. Used by the graceful path (LSP
    /// shutdown+exit already sent) before the destructor's hard teardown.
    /// </summary>
    function WaitForExit(ATimeoutMs: Cardinal): Boolean;

    /// <summary>
    /// Where the child's stderr went, for diagnostics.
    /// </summary>
    property StdErrPath: string read FStdErrPath;
    property ProcessId: DWORD read FProcessId;
  end;

implementation

uses
  System.IOUtils;

const
  // 64 KB each way: a full-sync didChange carries the whole document, so the
  // buffer wants to be a document, not a line.
  cPipeBuffer = 64 * 1024;
  cReadChunk = 64 * 1024;
  // A request frame is a few hundred bytes and the pipe buffer is 64 KB, so
  // a healthy server never makes us wait at all. Reaching this means the
  // server stopped reading; failing beats hanging the IDE.
  cWriteTimeoutMs = 5000;
  // The reader unwinds on CancelIoEx, which is immediate. This is only the
  // backstop before we escalate to TerminateProcess.
  cReaderExitMs = 3000;

  // Not in Winapi.Windows: PROC_THREAD_ATTRIBUTE_HANDLE_LIST is
  // ProcThreadAttributeValue(2, thread=False, input=True, additive=False),
  // i.e. 2 or PROC_THREAD_ATTRIBUTE_INPUT ($20000).
  PROC_THREAD_ATTRIBUTE_HANDLE_LIST = $00020002;
  PIPE_REJECT_REMOTE_CLIENTS = $00000008;

type
  // Winapi.Windows declares the attribute-list APIs and
  // EXTENDED_STARTUPINFO_PRESENT but not this record.
  TStartupInfoEx = record
    StartupInfo: TStartupInfo;
    lpAttributeList: PProcThreadAttributeList;
  end;

// Our own import of UpdateProcThreadAttribute, because the RTL's declares
// lpPreviousValue and lpReturnSize as `var` while the API documents both as
// reserved and REQUIRED to be NULL - passing real variables through the RTL
// overload fails with ERROR_INVALID_PARAMETER (87). Pointer parameters let us
// pass the nil the API insists on.
function UpdateProcThreadAttributeNil(lpAttributeList: PProcThreadAttributeList;
  dwFlags: DWORD; Attribute: NativeUInt; lpValue: Pointer; cbSize: NativeUInt;
  lpPreviousValue: Pointer; lpReturnSize: Pointer): ByteBool; stdcall;
  external kernel32 name 'UpdateProcThreadAttribute';

{ ---------------------------------------------------------------------------
  Pipe creation

  CreateNamedPipe gives us an overlapped end; CreateFile on that same name
  gives the child a plain synchronous end and, by connecting, puts the pipe
  in the connected state - so no ConnectNamedPipe is needed anywhere. This is
  the long-standing "CreatePipeEx" pattern.

  nMaxInstances = 1 and an unguessable GUID name are the access control: the
  one connection is made by us, before the child ever runs, and no second
  client can attach. PIPE_REJECT_REMOTE_CLIENTS keeps it off the network.
  --------------------------------------------------------------------------- }

procedure CreatePipePair(out AOurEnd, AChildEnd: THandle; AOurEndReads: Boolean);
var
  LName: string;
  LSA: TSecurityAttributes;
  LOpenMode, LChildAccess: DWORD;
begin
  LName := Format('\\.\pipe\pastree-lsp-%d-%s', [GetCurrentProcessId,
    TGUID.NewGuid.ToString]);

  if AOurEndReads then
  begin
    LOpenMode := PIPE_ACCESS_INBOUND;
    LChildAccess := GENERIC_WRITE;
  end
  else
  begin
    LOpenMode := PIPE_ACCESS_OUTBOUND;
    LChildAccess := GENERIC_READ;
  end;

  AOurEnd := CreateNamedPipe(PChar(LName), LOpenMode or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
    PIPE_REJECT_REMOTE_CLIENTS, 1, cPipeBuffer, cPipeBuffer, 0, nil);
  if AOurEnd = INVALID_HANDLE_VALUE then
    raise ELspTransport.CreateFmt('CreateNamedPipe failed (%d)',
      [GetLastError]);

  LSA.nLength := SizeOf(LSA);
  LSA.lpSecurityDescriptor := nil;
  LSA.bInheritHandle := True;   // the only handles the child may inherit
  AChildEnd := CreateFile(PChar(LName), LChildAccess, 0, @LSA, OPEN_EXISTING,
    0, 0);
  if AChildEnd = INVALID_HANDLE_VALUE then
  begin
    var LErr := GetLastError;
    CloseHandle(AOurEnd);
    AOurEnd := INVALID_HANDLE_VALUE;
    raise ELspTransport.CreateFmt('CreateFile on own pipe failed (%d)',
      [LErr]);
  end;
end;

{ TLspFrameParser }

procedure TLspFrameParser.Append(ABytes: PByte; ACount: Integer);
begin
  if ACount <= 0 then
    Exit;
  if FLen + ACount > Length(FBuf) then
    SetLength(FBuf, (FLen + ACount) * 2);
  Move(ABytes^, FBuf[FLen], ACount);
  Inc(FLen, ACount);
end;

function TLspFrameParser.NextFrame(out AJson: string): Boolean;
var
  I, LBodyStart, LContentLen, LTotal: Integer;
  LHeaders, LLine: string;
begin
  Result := False;

  // Header block terminator. The header sits at the front of what is left,
  // so this scan gives up (or succeeds) within a few dozen bytes.
  LBodyStart := -1;
  for I := 0 to FLen - 4 do
    if (FBuf[I] = 13) and (FBuf[I + 1] = 10) and (FBuf[I + 2] = 13) and
       (FBuf[I + 3] = 10) then
    begin
      LBodyStart := I + 4;
      Break;
    end;
  if LBodyStart < 0 then
    Exit;

  LContentLen := -1;
  LHeaders := TEncoding.ASCII.GetString(FBuf, 0, LBodyStart - 4);
  for LLine in LHeaders.Split([#13#10]) do
    if LLine.StartsWith('Content-Length:', True) then
      LContentLen := StrToIntDef(Trim(LLine.Substring(Length('Content-Length:'))), -1);
  if LContentLen < 0 then
    raise ELspTransport.Create('LSP frame without Content-Length');

  LTotal := LBodyStart + LContentLen;
  if FLen < LTotal then
    Exit;   // payload still arriving

  AJson := TEncoding.UTF8.GetString(FBuf, LBodyStart, LContentLen);
  if FLen > LTotal then
    Move(FBuf[LTotal], FBuf[0], FLen - LTotal);
  Dec(FLen, LTotal);
  Result := True;
end;

{ TLspReaderThread }

constructor TLspReaderThread.Create(AOwner: TLspConnection;
  APipe, AStopEvent: THandle);
begin
  FOwner := AOwner;
  FPipe := APipe;
  FStopEvent := AStopEvent;
  // Manual reset: WaitForMultipleObjects must see a completion that was
  // signalled before we got to the wait.
  FReadEvent := CreateEvent(nil, True, False, nil);
  FParser := TLspFrameParser.Create;
  inherited Create(False);
end;

destructor TLspReaderThread.Destroy;
begin
  inherited;   // joins; the thread is already unwinding via FStopEvent
  FParser.Free;
  if FReadEvent <> 0 then
    CloseHandle(FReadEvent);
end;

// A parameter, not a captured local: each call gets its own closure frame.
// Capturing a loop variable would hand every queued closure the same
// (last-written) string - the classic Delphi anonymous-method capture trap.
procedure TLspReaderThread.QueueFrame(const AJson: string);
begin
  TThread.Queue(Self,
    procedure
    begin
      FOwner.DispatchFrame(AJson);
    end);
end;

procedure TLspReaderThread.Execute;
var
  LOv: TOverlapped;
  LBuf: TBytes;
  LRead: DWORD;
  LWaits: array[0..1] of THandle;
  LJson, LReason: string;
  LErr: DWORD;
begin
  NameThreadForDebugging('PasTree LSP reader');
  SetLength(LBuf, cReadChunk);
  LReason := 'server closed the connection';

  while not Terminated do
  begin
    FillChar(LOv, SizeOf(LOv), 0);
    LOv.hEvent := FReadEvent;
    ResetEvent(FReadEvent);
    LRead := 0;

    if not ReadFile(FPipe, LBuf[0], cReadChunk, LRead, @LOv) then
    begin
      LErr := GetLastError;
      if LErr <> ERROR_IO_PENDING then
      begin
        // ERROR_BROKEN_PIPE is the normal end: the child exited and its
        // write end went with it.
        if LErr <> ERROR_BROKEN_PIPE then
          LReason := Format('read failed (%d)', [LErr]);
        Break;
      end;

      LWaits[0] := FReadEvent;
      LWaits[1] := FStopEvent;
      case WaitForMultipleObjects(2, @LWaits[0], False, INFINITE) of
        WAIT_OBJECT_0:
          if not GetOverlappedResult(FPipe, LOv, LRead, False) then
          begin
            LErr := GetLastError;
            if LErr <> ERROR_BROKEN_PIPE then
              LReason := Format('read failed (%d)', [LErr]);
            Break;
          end;
        WAIT_OBJECT_0 + 1:
          begin
            // Teardown. Cancel the pending read and wait for the kernel to
            // release the buffer before this thread's stack goes away.
            // Break leaves the while loop - case has no fallthrough here.
            CancelIoEx(FPipe, @LOv);
            GetOverlappedResult(FPipe, LOv, LRead, True);
            LReason := 'shutting down';
            Break;
          end;
      else
        LReason := Format('wait failed (%d)', [GetLastError]);
        Break;
      end;
    end;

    if LRead = 0 then
      Break;   // EOF

    try
      FParser.Append(@LBuf[0], LRead);
      while FParser.NextFrame(LJson) do
        QueueFrame(LJson);
    except
      on E: Exception do
      begin
        LReason := E.Message;   // unrecoverable framing error
        Break;
      end;
    end;
  end;

  if not Terminated then
    TThread.Queue(Self,
      procedure
      begin
        FOwner.DispatchGone(LReason);
      end);
end;

{ TLspConnection }

constructor TLspConnection.Create(const AExePath, AWorkDir: string;
  const AOnFrame: TLspFrameProc; const AOnGone: TLspGoneProc);
var
  LChildIn, LChildOut: THandle;
  LSA: TSecurityAttributes;
begin
  inherited Create;
  FOnFrame := AOnFrame;
  FOnGone := AOnGone;
  FWriteEnd := INVALID_HANDLE_VALUE;
  FReadEnd := INVALID_HANDLE_VALUE;
  FStdErrFile := INVALID_HANDLE_VALUE;

  if not TFile.Exists(AExePath) then
    raise ELspTransport.CreateFmt('server executable not found: %s',
      [AExePath]);

  FStopEvent := CreateEvent(nil, True, False, nil);
  FWriteEvent := CreateEvent(nil, True, False, nil);

  LChildIn := INVALID_HANDLE_VALUE;
  LChildOut := INVALID_HANDLE_VALUE;
  try
    CreatePipePair(FWriteEnd, LChildIn, False);   // child reads its stdin
    CreatePipePair(FReadEnd, LChildOut, True);    // child writes its stdout

    // Child stderr: an append-mode file, shared for reading so it can be
    // tailed live. FILE_APPEND_DATA rather than GENERIC_WRITE so concurrent
    // servers cannot overwrite each other's lines.
    FStdErrPath := TPath.Combine(TPath.GetTempPath,
      Format('pastree-lsp-stderr-%d.log', [GetCurrentProcessId]));
    LSA.nLength := SizeOf(LSA);
    LSA.lpSecurityDescriptor := nil;
    LSA.bInheritHandle := True;
    FStdErrFile := CreateFile(PChar(FStdErrPath), FILE_APPEND_DATA,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @LSA, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if FStdErrFile = INVALID_HANDLE_VALUE then
      raise ELspTransport.CreateFmt('cannot open stderr log %s (%d)',
        [FStdErrPath, GetLastError]);

    Spawn(AExePath, AWorkDir, LChildIn, LChildOut);
  finally
    // The child owns these now. We MUST drop them: holding the write end of
    // the child's stdout pipe means our reader never sees EOF when the child
    // dies, and we would wait for a message from a corpse forever.
    if LChildIn <> INVALID_HANDLE_VALUE then
      CloseHandle(LChildIn);
    if LChildOut <> INVALID_HANDLE_VALUE then
      CloseHandle(LChildOut);
    if FStdErrFile <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FStdErrFile);
      FStdErrFile := INVALID_HANDLE_VALUE;
    end;
  end;

  FReader := TLspReaderThread.Create(Self, FReadEnd, FStopEvent);
end;

procedure TLspConnection.Spawn(const AExePath, AWorkDir: string;
  AChildIn, AChildOut: THandle);
var
  LSIEx: TStartupInfoEx;
  LPI: TProcessInformation;
  LSize: NativeUInt;
  LHandles: array[0..2] of THandle;
  LDir: PChar;
begin
  FillChar(LSIEx, SizeOf(LSIEx), 0);
  LSIEx.StartupInfo.cb := SizeOf(LSIEx);
  LSIEx.StartupInfo.dwFlags := STARTF_USESTDHANDLES;
  LSIEx.StartupInfo.hStdInput := AChildIn;
  LSIEx.StartupInfo.hStdOutput := AChildOut;
  LSIEx.StartupInfo.hStdError := FStdErrFile;

  LHandles[0] := AChildIn;
  LHandles[1] := AChildOut;
  LHandles[2] := FStdErrFile;

  // Sizing call: documented to fail with ERROR_INSUFFICIENT_BUFFER while
  // filling in LSize.
  LSize := 0;
  InitializeProcThreadAttributeList(PProcThreadAttributeList(nil), 1, 0, LSize);
  if LSize = 0 then
    raise ELspTransport.CreateFmt(
      'InitializeProcThreadAttributeList sizing failed (%d)', [GetLastError]);
  LSIEx.lpAttributeList := PProcThreadAttributeList(GetMemory(LSize));
  try
    if not InitializeProcThreadAttributeList(LSIEx.lpAttributeList, 1, 0,
      LSize) then
      raise ELspTransport.CreateFmt(
        'InitializeProcThreadAttributeList failed (%d)', [GetLastError]);
    try
      // Exactly these three handles are inherited - see the unit header.
      if not UpdateProcThreadAttributeNil(LSIEx.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @LHandles[0], SizeOf(LHandles),
        nil, nil) then
        raise ELspTransport.CreateFmt('UpdateProcThreadAttribute failed (%d)',
          [GetLastError]);

      if AWorkDir <> '' then
        LDir := PChar(AWorkDir)
      else
        LDir := nil;

      // CREATE_NO_WINDOW: the server is a console app and we are a GUI
      // process - without this a console window flashes on every start.
      // bInheritHandles must still be True for the handle list to apply.
      if not CreateProcess(nil, PChar('"' + AExePath + '"'), nil, nil, True,
        EXTENDED_STARTUPINFO_PRESENT or CREATE_NO_WINDOW, nil, LDir,
        LSIEx.StartupInfo, LPI) then
        raise ELspTransport.CreateFmt('cannot start %s (%d)',
          [AExePath, GetLastError]);

      FProcess := LPI.hProcess;
      FProcessId := LPI.dwProcessId;
      CloseHandle(LPI.hThread);
    finally
      DeleteProcThreadAttributeList(LSIEx.lpAttributeList);
    end;
  finally
    FreeMemory(LSIEx.lpAttributeList);
  end;
end;

procedure TLspConnection.CloseAll;
begin
  if FWriteEnd <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FWriteEnd);
    FWriteEnd := INVALID_HANDLE_VALUE;
  end;
  if FReadEnd <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FReadEnd);
    FReadEnd := INVALID_HANDLE_VALUE;
  end;
  if FProcess <> 0 then
  begin
    CloseHandle(FProcess);
    FProcess := 0;
  end;
  if FStopEvent <> 0 then
  begin
    CloseHandle(FStopEvent);
    FStopEvent := 0;
  end;
  if FWriteEvent <> 0 then
  begin
    CloseHandle(FWriteEvent);
    FWriteEvent := 0;
  end;
end;

{ Teardown order, all of it load bearing:

  1. Close our write end. The server's stdin hits EOF, which is how LSP says
     "we are done" - it exits on its own, no signal needed.
  2. Signal FStopEvent so the reader cancels its pending read and unwinds. It
     is executing OUR code, inside a DLL that is about to be unloaded, so it
     must be gone before we return.
  3. If it will not leave in time, kill the child: that breaks the pipe and
     forces the read to complete even if CancelIoEx somehow did not.
  4. RemoveQueuedEvents AFTER the thread is joined - nothing can queue any
     more by then, and any closure still pending would call into a freed
     TLspConnection.
  5. Only now close the handles the thread was using. }
destructor TLspConnection.Destroy;
begin
  if FWriteEnd <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FWriteEnd);
    FWriteEnd := INVALID_HANDLE_VALUE;
  end;

  if Assigned(FReader) then
  begin
    FReader.Terminate;
    if FStopEvent <> 0 then
      SetEvent(FStopEvent);
    if WaitForSingleObject(FReader.Handle, cReaderExitMs) <> WAIT_OBJECT_0 then
      if (FProcess <> 0) and IsRunning then
        TerminateProcess(FProcess, 1);
    TThread.RemoveQueuedEvents(FReader);
    FReader.Free;   // joins
    FReader := nil;
  end;

  // The server exits on stdin EOF; only insist if it did not.
  if (FProcess <> 0) and IsRunning then
  begin
    if WaitForSingleObject(FProcess, 1000) <> WAIT_OBJECT_0 then
      TerminateProcess(FProcess, 1);
  end;

  CloseAll;
  inherited;
end;

procedure TLspConnection.DispatchFrame(const AJson: string);
begin
  if Assigned(FOnFrame) then
    FOnFrame(AJson);
end;

procedure TLspConnection.DispatchGone(const AReason: string);
begin
  if FGoneReported then
    Exit;
  FGoneReported := True;
  if Assigned(FOnGone) then
    FOnGone(AReason);
end;

function TLspConnection.Send(const AJson: string): Boolean;
var
  LPayload, LFrame: TBytes;
  LHeader: string;
  LOv: TOverlapped;
  LWritten: DWORD;
begin
  Result := False;
  if FWriteEnd = INVALID_HANDLE_VALUE then
    Exit;

  LPayload := TEncoding.UTF8.GetBytes(AJson);
  LHeader := Format('Content-Length: %d'#13#10#13#10, [Length(LPayload)]);
  // One write, not two: a header and payload written separately are still one
  // stream to the server, but a single call cannot interleave with anything
  // and keeps the timeout accounting simple.
  LFrame := TEncoding.ASCII.GetBytes(LHeader) + LPayload;

  FillChar(LOv, SizeOf(LOv), 0);
  LOv.hEvent := FWriteEvent;
  ResetEvent(FWriteEvent);
  LWritten := 0;

  if WriteFile(FWriteEnd, LFrame[0], Length(LFrame), LWritten, @LOv) then
    Exit(LWritten = DWORD(Length(LFrame)));

  if GetLastError <> ERROR_IO_PENDING then
    Exit;

  case WaitForSingleObject(FWriteEvent, cWriteTimeoutMs) of
    WAIT_OBJECT_0:
      Result := GetOverlappedResult(FWriteEnd, LOv, LWritten, False) and
        (LWritten = DWORD(Length(LFrame)));
  else
    // Timed out (or the wait itself failed): abandon the write so the kernel
    // stops referencing LFrame and LOv, both of which are about to go out of
    // scope with this stack frame.
    CancelIoEx(FWriteEnd, @LOv);
    GetOverlappedResult(FWriteEnd, LOv, LWritten, True);
  end;
end;

function TLspConnection.IsRunning: Boolean;
var
  LCode: DWORD;
begin
  Result := (FProcess <> 0) and GetExitCodeProcess(FProcess, LCode) and
    (LCode = STILL_ACTIVE);
end;

function TLspConnection.WaitForExit(ATimeoutMs: Cardinal): Boolean;
begin
  Result := (FProcess = 0) or
    (WaitForSingleObject(FProcess, ATimeoutMs) = WAIT_OBJECT_0);
end;

end.
