unit PasLsp.Protocol;

{
  JSON-RPC 2.0 envelope handling and the LSP-specific value conversions the
  server needs everywhere: message parse, response/error builders, file URI
  <-> Windows path, and LSP <-> PasTree positions.

  Positions: LSP counts 0-based lines and 0-based UTF-16 code units;
  PasTree's lexer counts 1-based lines and 1-based Char (= UTF-16 code unit)
  columns. Delphi strings ARE UTF-16, so the unit matches and the whole
  conversion is the +/-1 in LspToPasTree/PasTreeToLsp — kept as named
  functions anyway so the one place encoding could ever go wrong is findable.
}

interface

uses
  System.SysUtils,
  System.JSON;

const
  // JSON-RPC / LSP error codes (the ones phase 1 actually emits).
  LSP_PARSE_ERROR = -32700;
  LSP_INVALID_REQUEST = -32600;
  LSP_METHOD_NOT_FOUND = -32601;
  LSP_INVALID_PARAMS = -32602;
  LSP_INTERNAL_ERROR = -32603;
  LSP_SERVER_NOT_INITIALIZED = -32002;

type
  // One incoming message. Root owns everything; callers free Root only.
  // IdJson is the id rendered back to JSON verbatim ('' = notification) —
  // embedding it verbatim in the response sidesteps ownership/clone games
  // and is correct for every id type the spec allows (number or string).
  TLspIncoming = record
    Root: TJSONObject;
    IdJson: string;
    Method: string;
    Params: TJSONValue;   // may be nil; owned by Root
    function IsRequest: Boolean;
  end;

function ParseIncoming(const AJson: string; out AMsg: TLspIncoming): Boolean;

{ AResultJson must be valid JSON (use 'null' for a void result). }
function BuildResponse(const AIdJson, AResultJson: string): string;
function BuildError(const AIdJson: string; ACode: Integer;
  const AMessage: string): string;

function JsonQuote(const S: string): string;

{ file:///c%3A/dir/file.pas <-> C:\dir\file.pas. UriToPath returns '' for a
  non-file URI. PathToUri lower-cases the drive letter (VS Code's own
  canonical form, so our URIs compare equal to the client's). }
function UriToPath(const AUri: string): string;
function PathToUri(const APath: string): string;

{ Position conversions — see the unit comment. }
procedure LspToPasTree(ALine, ACharacter: Integer; out APasLine,
  APasCol: Integer);
procedure PasTreeToLsp(APasLine, APasCol: Integer; out ALine,
  ACharacter: Integer);

{ An LSP Location JSON for a declaration: ALen UTF-16 units starting at the
  (1-based) PasTree position. }
function LocationJson(const AFilePath: string; APasLine, APasCol,
  ALen: Integer): string;

implementation

function TLspIncoming.IsRequest: Boolean;
begin
  Result := IdJson <> '';
end;

function ParseIncoming(const AJson: string; out AMsg: TLspIncoming): Boolean;
var
  LVal: TJSONValue;
  LId: TJSONValue;
begin
  AMsg := Default(TLspIncoming);
  LVal := TJSONObject.ParseJSONValue(AJson);
  if not (LVal is TJSONObject) then
  begin
    LVal.Free;
    Exit(False);
  end;
  AMsg.Root := TJSONObject(LVal);
  AMsg.Method := AMsg.Root.GetValue<string>('method', '');
  AMsg.Params := AMsg.Root.GetValue('params');
  LId := AMsg.Root.GetValue('id');
  if LId <> nil then
    AMsg.IdJson := LId.ToJSON;
  Result := True;
end;

function BuildResponse(const AIdJson, AResultJson: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + AIdJson + ',"result":' +
    AResultJson + '}';
end;

function BuildError(const AIdJson: string; ACode: Integer;
  const AMessage: string): string;
var
  LId: string;
begin
  LId := AIdJson;
  if LId = '' then
    LId := 'null';
  Result := Format('{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":%s}}',
    [LId, ACode, JsonQuote(AMessage)]);
end;

function JsonQuote(const S: string): string;
var
  LStr: TJSONString;
begin
  LStr := TJSONString.Create(S);
  try
    Result := LStr.ToJSON;
  finally
    LStr.Free;
  end;
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function UriToPath(const AUri: string): string;
var
  LRest: string;
  LBytes: TBytes;
  LIdx, LH, LL: Integer;
begin
  Result := '';
  if not AUri.StartsWith('file://', True) then
    Exit;
  LRest := Copy(AUri, Length('file://') + 1, MaxInt);
  // Percent-decode into UTF-8 bytes, then decode the bytes once — a %-escape
  // may be one byte of a multi-byte character.
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
  // file:///c:/x -> /c:/x ; file://server/share stays \\server\share.
  if (Length(Result) >= 3) and (Result[1] = '/') and (Result[3] = ':') then
    Delete(Result, 1, 1)
  else if (Result <> '') and (Result[1] <> '/') then
    Result := '\\' + Result;
  Result := Result.Replace('/', '\');
end;

function PathToUri(const APath: string): string;
const
  UNRESERVED = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'];
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
      if (LByte < 128) and (AnsiChar(LByte) in UNRESERVED) then
        LSB.Append(Char(LByte))
      else
        LSB.AppendFormat('%%%.2X', [LByte]);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure LspToPasTree(ALine, ACharacter: Integer; out APasLine,
  APasCol: Integer);
begin
  APasLine := ALine + 1;
  APasCol := ACharacter + 1;
end;

procedure PasTreeToLsp(APasLine, APasCol: Integer; out ALine,
  ACharacter: Integer);
begin
  ALine := APasLine - 1;
  ACharacter := APasCol - 1;
end;

function LocationJson(const AFilePath: string; APasLine, APasCol,
  ALen: Integer): string;
var
  LLine, LChar: Integer;
begin
  PasTreeToLsp(APasLine, APasCol, LLine, LChar);
  Result := Format(
    '{"uri":%s,"range":{"start":{"line":%d,"character":%d},' +
    '"end":{"line":%d,"character":%d}}}',
    [JsonQuote(PathToUri(AFilePath)), LLine, LChar, LLine, LChar + ALen]);
end;

end.
