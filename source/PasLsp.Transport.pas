unit PasLsp.Transport;

{
  LSP base-protocol framing over stdio: each message is
  `Content-Length: N\r\n\r\n<N bytes of UTF-8 JSON>`. Reads are buffered;
  writes go out as one header+payload block. Single-threaded by design —
  phase 1 handles one message at a time, so there is nothing to lock.

  stdout carries ONLY framed messages: a stray Write(ln) anywhere in the
  server corrupts the stream for every client. Diagnostics go to stderr
  (LSP clients capture and show it), never here.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.JSON,
  PasLsp.Protocol;

type
  TLspTransport = class
  private
    FIn: THandleStream;
    FOut: THandleStream;
    FBuf: TBytes;
    FPos, FLen: Integer;
    function ReadByte(out AByte: Byte): Boolean;
    function ReadHeaderLine(out ALine: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Blocks until a full message arrives. False = clean EOF (client closed
      our stdin — the LSP way of saying the session is over). Raises on a
      malformed header: there is no way to resync a broken frame stream. }
    function ReadMessage(out AJson: string): Boolean;
    procedure WriteMessage(const AJson: string);
  end;

  { Phase 2: stdin is read by THIS thread so a $/cancelRequest is SEEN while
    the dispatcher is busy (waiting out an analysis, typically). Every frame
    goes into Queue in arrival order; a $/cancelRequest is ADDITIONALLY noted
    in the cancel set right here, before the dispatcher gets anywhere near
    it. EOF (client gone) is signaled by an empty-string sentinel — a real
    message is never empty, ReadMessage yields at least two brace bytes.

    The full-parse cost for cancel detection is only paid for frames that
    textually contain "$/cancelRequest" (a cheap prefilter): parsing EVERY
    frame here would double-parse each didChange, whose full-sync payload is
    the entire document. A false hit on the prefilter (the literal inside a
    didChange text) costs one wasted parse and nothing else. }
  TLspReader = class(TThread)
  private
    FTransport: TLspTransport;
    FCancels: TLspCancelSet;
    FQueue: TThreadedQueue<string>;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TLspTransport; ACancels: TLspCancelSet);
    destructor Destroy; override;
    { Pops the next frame; wrTimeout after ~50ms (the dispatcher's idle
      tick, fixed at queue creation), wrSignaled with '' = EOF. }
    function Pop(out AJson: string): TWaitResult;
  end;

implementation

uses
  Winapi.Windows;

constructor TLspTransport.Create;
begin
  inherited Create;
  FIn := THandleStream.Create(GetStdHandle(STD_INPUT_HANDLE));
  FOut := THandleStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));
  SetLength(FBuf, 64 * 1024);
end;

destructor TLspTransport.Destroy;
begin
  FIn.Free;
  FOut.Free;
  inherited;
end;

function TLspTransport.ReadByte(out AByte: Byte): Boolean;
begin
  if FPos >= FLen then
  begin
    FLen := FIn.Read(FBuf[0], Length(FBuf));
    FPos := 0;
    if FLen <= 0 then
      Exit(False);
  end;
  AByte := FBuf[FPos];
  Inc(FPos);
  Result := True;
end;

// One header line, CRLF stripped. Headers are ASCII by spec.
function TLspTransport.ReadHeaderLine(out ALine: string): Boolean;
var
  LSB: TStringBuilder;
  LB: Byte;
begin
  LSB := TStringBuilder.Create;
  try
    while ReadByte(LB) do
    begin
      if LB = 10 then
      begin
        ALine := LSB.ToString;
        if (ALine <> '') and (ALine[Length(ALine)] = #13) then
          SetLength(ALine, Length(ALine) - 1);
        Exit(True);
      end;
      LSB.Append(Char(LB));
    end;
    Result := False;   // EOF mid-line: treat as stream end
  finally
    LSB.Free;
  end;
end;

function TLspTransport.ReadMessage(out AJson: string): Boolean;
var
  LLine: string;
  LLen, LGot, LTake: Integer;
  LPayload: TBytes;
begin
  LLen := -1;
  // Header block: Content-Length is the one we need; Content-Type (the only
  // other defined header) is read and ignored.
  while True do
  begin
    if not ReadHeaderLine(LLine) then
      Exit(False);
    if LLine = '' then
      Break;
    if LLine.StartsWith('Content-Length:', True) then
      LLen := StrToIntDef(Trim(Copy(LLine, Length('Content-Length:') + 1,
        MaxInt)), -1);
  end;
  if LLen < 0 then
    raise Exception.Create('LSP frame without Content-Length');
  SetLength(LPayload, LLen);
  LGot := 0;
  while LGot < LLen do
  begin
    if FPos >= FLen then
    begin
      FLen := FIn.Read(FBuf[0], Length(FBuf));
      FPos := 0;
      if FLen <= 0 then
        Exit(False);   // EOF mid-payload
    end;
    LTake := FLen - FPos;
    if LTake > LLen - LGot then
      LTake := LLen - LGot;
    Move(FBuf[FPos], LPayload[LGot], LTake);
    Inc(FPos, LTake);
    Inc(LGot, LTake);
  end;
  AJson := TEncoding.UTF8.GetString(LPayload);
  Result := True;
end;

procedure TLspTransport.WriteMessage(const AJson: string);
var
  LPayload, LHeader: TBytes;
begin
  LPayload := TEncoding.UTF8.GetBytes(AJson);
  LHeader := TEncoding.ASCII.GetBytes(
    Format('Content-Length: %d'#13#10#13#10, [Length(LPayload)]));
  FOut.WriteBuffer(LHeader[0], Length(LHeader));
  if Length(LPayload) > 0 then
    FOut.WriteBuffer(LPayload[0], Length(LPayload));
end;

{ TLspReader }

constructor TLspReader.Create(ATransport: TLspTransport;
  ACancels: TLspCancelSet);
begin
  // Queue depth 1024: ~a keystroke burst; PushItem blocks (never drops) if
  // the dispatcher falls further behind than that. Pop timeout 50ms is the
  // dispatcher's idle tick (finished analyses get finalized on it).
  FQueue := TThreadedQueue<string>.Create(1024, INFINITE, 50);
  FTransport := ATransport;
  FCancels := ACancels;
  inherited Create(False);
end;

destructor TLspReader.Destroy;
begin
  // The thread is normally already gone (EOF or exit) — Terminate covers the
  // abnormal teardown path. A blocking FIn.Read cannot be interrupted, but
  // process exit is what follows this destructor anyway.
  Terminate;
  FQueue.DoShutDown;
  inherited;   // WaitFor would hang on a live blocking read; thread is
               // FreeOnTerminate=False and reaped by process exit
  FQueue.Free;
end;

procedure TLspReader.Execute;
var
  LJson: string;
  LMsg: TLspIncoming;
begin
  while not Terminated do
  begin
    try
      if not FTransport.ReadMessage(LJson) then
        Break;
    except
      Break;   // framing is unrecoverable — treat like EOF
    end;
    if (Pos('"$/cancelRequest"', LJson) > 0) and
       ParseIncoming(LJson, LMsg) then
    begin
      try
        if LMsg.Method = '$/cancelRequest' then
        begin
          var LId := LMsg.Params.FindValue('id');
          if LId <> nil then
            FCancels.NoteCancel(LId.ToJSON);
        end;
      finally
        LMsg.Root.Free;
      end;
    end;
    if FQueue.PushItem(LJson) <> wrSignaled then
      Break;
  end;
  FQueue.PushItem('');   // EOF sentinel
end;

function TLspReader.Pop(out AJson: string): TWaitResult;
var
  LSize: Integer;
begin
  Result := FQueue.PopItem(LSize, AJson);
end;

end.
