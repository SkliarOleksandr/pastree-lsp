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
  System.Classes;

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

end.
