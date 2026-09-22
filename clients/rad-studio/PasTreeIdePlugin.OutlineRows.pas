unit PasTreeIdePlugin.OutlineRows;

{ The Go To picker's rows (pastree/outline) and the reader of the TABLE the
  server sends them as.

  WHY A TABLE AND A HAND-WRITTEN READER, NOT System.JSON OBJECTS. The project
  list of a real project is big: AVImark (1553 units) is 113,613 rows. As one
  JSON object per row with every field spelled out - the shape up to 0.45.3 -
  that was 33.3 MB on the wire, and the client spent 0.5 s in
  TJSONObject.ParseJSONValue and another 1.5 s pulling fourteen GetValue<T>
  per row out of the DOM, all of it on the main thread, before the picker
  could show a single row (measured 2026-09-19, Ryzen 5800X; a laptop is
  slower). The row's fields are mostly REPEATED VALUES: a dozen kind and head
  words, a few hundred owners, one file per unit. So the server interns them
  once and each row is a short positional array of indices, names and
  numbers - one JSON object with these members (spelled without its braces
  here, because a brace would end this comment):

    "scope": "project"
    "kinds": ["module","include","type",...]      kind words, in the server's order
    "heads": ["unit","type","procedure",...]      head words actually present
    "sections": ["","interface","implementation",...]
    "owners": ["","TFoo","TOuter.TInner",...]     the enclosing structs
    "files": [["file:///c%3A/x/Foo.pas","Foo",12], ...]   uri, unit name, unit id
    "rows": [[kind,head,owner,"Name","detail",section,isImpl,file,sym,node,line,col], ...]

  kind/head/owner/section/file are indices into the tables above, which the
  server writes BEFORE the rows; isImpl is 0/1; line/col are 1-based
  (PasTree's own) and 0 on a project row. The words still travel as words:
  the client never depends on a PasTree enum's order, only on this
  response's own tables. The same list is ~8 MB, and this reader turns it
  into records in one pass over the characters, no DOM. It is handed the
  result text by TLspClient.RequestRaw, which skips the DOM parse for
  responses issued this way.

  NO IDE, NO PasTree: a plain RTL unit, so tests/LspClientSmoke reads the
  server's real answer with the same code the package does. }

interface

uses
  System.SysUtils;

type
  /// <summary>
  /// One row of a Go To list - PasTree's TPasOutlineEntry field for field,
  /// spelled here because this package must not link PasTree (see the .dpk).
  /// Kind and Section are the server's WORDS ('type', 'routine', 'include'...;
  /// 'interface', 'implementation'...), never ordinals. A MODULE row carries
  /// its position (Line/Col 1-based, IDE coordinates as they are - PasTree
  /// and the editor agree here) and UnitId = -1; a PROJECT row carries
  /// UnitId/Sym/Node and NO position (Line = 0): LspOutlineTarget places it
  /// when it is chosen. ProjectFile is the .dproj whose server answered -
  /// what routes the target request back to that server. Key is
  /// the lower-cased name column (see OutlineNameColumn), computed once here
  /// so the picker's filter does not lower-case 100k strings per keystroke.
  /// </summary>
  TLspOutlineRow = record
    Kind: string;
    Head: string;
    Owner: string;
    Name: string;
    Detail: string;
    Section: string;
    IsImpl: Boolean;
    FilePath: string;
    Line: Integer;
    Col: Integer;
    UnitId: Integer;
    Sym: Integer;
    Node: Integer;
    UnitName: string;
    ProjectFile: string;
    Key: string;
    /// The type names inside Detail as (start, length) pairs, 1-based into
    /// Detail, flattened - [s1, l1, s2, l2, ...]. nil when the server sent
    /// no 13th element (a PasTree before outline type spans).
    TypeSpans: TArray<Integer>;
  end;

  EOutlineTable = class(Exception);

/// <summary>
/// The text the picker's name column shows and its filter matches:
/// `Owner.Name`, `Name`, or the head word for a landmark with no name
/// (a section, a uses clause).
/// </summary>
function OutlineNameColumn(const ARow: TLspOutlineRow): string;

/// <summary>
/// Reads the server's table (the unit header) into rows, every row stamped
/// with AProjectFile. AJson is the RESULT text of pastree/outline - 'null'
/// (nothing analyzed, a file outside the closure) reads as an empty list. A
/// malformed table raises EOutlineTable naming the offset; the overload
/// without AError returns an empty list and the message instead.
/// </summary>
function ParseOutlineTable(const AJson, AProjectFile: string):
  TArray<TLspOutlineRow>; overload;
function ParseOutlineTable(const AJson, AProjectFile: string;
  out AError: string): TArray<TLspOutlineRow>; overload;

implementation

uses
  PasTreeIdePlugin.LspClient;   // LspUriToPath

function OutlineNameColumn(const ARow: TLspOutlineRow): string;
begin
  if ARow.Name = '' then
    Exit(ARow.Head);
  if ARow.Owner <> '' then
    Result := ARow.Owner + '.' + ARow.Name
  else
    Result := ARow.Name;
end;

type
  TFileEntry = record
    Path: string;
    UnitName: string;
    UnitId: Integer;
  end;

  { A cursor over the response text. Strings are read by scanning for the
    closing quote and copying the span when no escape intervenes - the
    common case for identifiers and signatures - and unescaped char by char
    otherwise. }
  TTableScanner = record
    P, PBegin, PEnd: PChar;
    procedure Init(const AText: string);
    function Offset: Integer; inline;
    procedure Fail(const AWhat: string);
    procedure SkipWs; inline;
    function TryConsume(C: Char): Boolean; inline;
    procedure Expect(C: Char);
    function ReadString: string;
    function ReadInt: Integer;
    function ReadIntOrBool: Integer;
    function ReadStrings: TArray<string>;
    procedure SkipValue;
  end;

procedure TTableScanner.Init(const AText: string);
begin
  PBegin := PChar(AText);
  P := PBegin;
  PEnd := PBegin + Length(AText);
end;

function TTableScanner.Offset: Integer;
begin
  Result := P - PBegin;
end;

procedure TTableScanner.Fail(const AWhat: string);
begin
  raise EOutlineTable.CreateFmt('outline table: %s at offset %d',
    [AWhat, Offset]);
end;

procedure TTableScanner.SkipWs;
begin
  while (P < PEnd) and (P^ <= ' ') do
    Inc(P);
end;

function TTableScanner.TryConsume(C: Char): Boolean;
begin
  Result := (P < PEnd) and (P^ = C);
  if Result then
    Inc(P);
end;

procedure TTableScanner.Expect(C: Char);
begin
  SkipWs;
  if not TryConsume(C) then
    Fail('expected "' + C + '"');
end;

function TTableScanner.ReadString: string;
var
  LStart, LScan: PChar;
  LBuf: string;
  LLen, LCode, LDigit: Integer;
  C: Char;
begin
  SkipWs;
  if not TryConsume('"') then
    Fail('expected a string');
  LStart := P;
  LScan := P;
  while (LScan < PEnd) and (LScan^ <> '"') and (LScan^ <> '\') do
    Inc(LScan);
  if LScan >= PEnd then
    Fail('unterminated string');
  if LScan^ = '"' then
  begin
    SetString(Result, LStart, LScan - LStart);
    P := LScan + 1;
    Exit;
  end;
  // An escape somewhere: find the closing quote past the escapes, then
  // unescape into a buffer no longer than that span (never the rest of the
  // document - a path in a `detail` is a common escaped string).
  while (LScan < PEnd) and (LScan^ <> '"') do
  begin
    if LScan^ = '\' then
      Inc(LScan);
    Inc(LScan);
  end;
  if LScan >= PEnd then
    Fail('unterminated string');
  SetLength(LBuf, LScan - LStart);
  LLen := 0;
  while P < PEnd do
  begin
    C := P^;
    Inc(P);
    if C = '"' then
    begin
      SetLength(LBuf, LLen);
      Exit(LBuf);
    end;
    if C = '\' then
    begin
      if P >= PEnd then
        Fail('unterminated escape');
      C := P^;
      Inc(P);
      case C of
        '"', '\', '/': ;
        'b': C := #8;
        'f': C := #12;
        'n': C := #10;
        'r': C := #13;
        't': C := #9;
        'u':
          begin
            if PEnd - P < 4 then
              Fail('short \u escape');
            LCode := 0;
            for LDigit := 1 to 4 do
            begin
              case P^ of
                '0'..'9': LCode := LCode * 16 + Ord(P^) - Ord('0');
                'a'..'f': LCode := LCode * 16 + Ord(P^) - Ord('a') + 10;
                'A'..'F': LCode := LCode * 16 + Ord(P^) - Ord('A') + 10;
              else
                Fail('bad \u escape');
              end;
              Inc(P);
            end;
            C := Char(LCode);
          end;
      else
        Fail('unknown escape');
      end;
    end;
    Inc(LLen);
    LBuf[LLen] := C;
  end;
  Result := '';
  Fail('unterminated string');
end;

function TTableScanner.ReadInt: Integer;
var
  LNeg: Boolean;
  LAny: Boolean;
begin
  SkipWs;
  LNeg := TryConsume('-');
  Result := 0;
  LAny := False;
  while (P < PEnd) and (P^ >= '0') and (P^ <= '9') do
  begin
    Result := Result * 10 + (Ord(P^) - Ord('0'));
    Inc(P);
    LAny := True;
  end;
  if not LAny then
    Fail('expected a number');
  if LNeg then
    Result := -Result;
end;

function TTableScanner.ReadIntOrBool: Integer;
begin
  SkipWs;
  if (PEnd - P >= 4) and (StrLComp(P, 'true', 4) = 0) then
  begin
    Inc(P, 4);
    Exit(1);
  end;
  if (PEnd - P >= 5) and (StrLComp(P, 'false', 5) = 0) then
  begin
    Inc(P, 5);
    Exit(0);
  end;
  Result := ReadInt;
end;

function TTableScanner.ReadStrings: TArray<string>;
var
  LCount: Integer;
begin
  Result := nil;
  LCount := 0;
  Expect('[');
  SkipWs;
  if TryConsume(']') then
    Exit;
  repeat
    if LCount = Length(Result) then
      SetLength(Result, LCount * 2 + 8);
    Result[LCount] := ReadString;
    Inc(LCount);
    SkipWs;
    if TryConsume(']') then
      Break;
    Expect(',');
  until False;
  SetLength(Result, LCount);
end;

{ Skips one value of any shape - a key this reader does not know. }
procedure TTableScanner.SkipValue;
var
  LDepth: Integer;
begin
  SkipWs;
  if P >= PEnd then
    Fail('unexpected end');
  case P^ of
    '"': ReadString;
    '[', '{':
      begin
        LDepth := 0;
        repeat
          if P >= PEnd then
            Fail('unterminated value');
          case P^ of
            '"': begin ReadString; Continue; end;
            '[', '{': Inc(LDepth);
            ']', '}': Dec(LDepth);
          end;
          Inc(P);
        until LDepth = 0;
      end;
  else
    while (P < PEnd) and (P^ <> ',') and (P^ <> ']') and (P^ <> '}') do
      Inc(P);
  end;
end;

function ParseOutlineTable(const AJson, AProjectFile: string;
  out AError: string): TArray<TLspOutlineRow>;
var
  S: TTableScanner;
  LKey: string;
  LKinds, LHeads, LSections, LOwners: TArray<string>;
  LFiles: TArray<TFileEntry>;
  LCount, LFileCount: Integer;
  LRow: TLspOutlineRow;

  function Pick(const ATable: TArray<string>; AIdx: Integer;
    const AWhat: string): string;
  begin
    if (AIdx < 0) or (AIdx > High(ATable)) then
      S.Fail(AWhat + ' index out of range');
    Result := ATable[AIdx];
  end;

  procedure ReadFiles;
  begin
    S.Expect('[');
    S.SkipWs;
    if S.TryConsume(']') then
      Exit;
    repeat
      if LFileCount = Length(LFiles) then
        SetLength(LFiles, LFileCount * 2 + 16);
      S.Expect('[');
      LFiles[LFileCount].Path := LspUriToPath(S.ReadString);
      S.Expect(',');
      LFiles[LFileCount].UnitName := S.ReadString;
      S.Expect(',');
      LFiles[LFileCount].UnitId := S.ReadInt;
      S.Expect(']');
      Inc(LFileCount);
      S.SkipWs;
      if S.TryConsume(']') then
        Break;
      S.Expect(',');
    until False;
    SetLength(LFiles, LFileCount);
  end;

  procedure ReadRows;
  var
    LFile: Integer;
  begin
    S.Expect('[');
    S.SkipWs;
    if S.TryConsume(']') then
      Exit;
    repeat
      if LCount = Length(Result) then
        SetLength(Result, LCount * 2 + 256);
      S.Expect('[');
      LRow.Kind := Pick(LKinds, S.ReadInt, 'kind');
      S.Expect(',');
      LRow.Head := Pick(LHeads, S.ReadInt, 'head');
      S.Expect(',');
      LRow.Owner := Pick(LOwners, S.ReadInt, 'owner');
      S.Expect(',');
      LRow.Name := S.ReadString;
      S.Expect(',');
      LRow.Detail := S.ReadString;
      S.Expect(',');
      LRow.Section := Pick(LSections, S.ReadInt, 'section');
      S.Expect(',');
      LRow.IsImpl := S.ReadIntOrBool <> 0;
      S.Expect(',');
      LFile := S.ReadInt;
      if (LFile < 0) or (LFile >= LFileCount) then
        S.Fail('file index out of range');
      LRow.FilePath := LFiles[LFile].Path;
      LRow.UnitName := LFiles[LFile].UnitName;
      LRow.UnitId := LFiles[LFile].UnitId;
      S.Expect(',');
      LRow.Sym := S.ReadInt;
      S.Expect(',');
      LRow.Node := S.ReadInt;
      S.Expect(',');
      LRow.Line := S.ReadInt;
      S.Expect(',');
      LRow.Col := S.ReadInt;
      // Optional 13th element: the detail's type spans, [s, l, s, l...].
      LRow.TypeSpans := nil;
      S.SkipWs;
      if S.TryConsume(',') then
      begin
        S.Expect('[');
        S.SkipWs;
        if not S.TryConsume(']') then
        begin
          repeat
            LRow.TypeSpans := LRow.TypeSpans + [S.ReadInt];
            S.SkipWs;
          until not S.TryConsume(',');
          S.Expect(']');
        end;
      end;
      S.Expect(']');
      LRow.Key := LowerCase(OutlineNameColumn(LRow));
      Result[LCount] := LRow;
      Inc(LCount);
      S.SkipWs;
      if S.TryConsume(']') then
        Break;
      S.Expect(',');
    until False;
  end;

begin
  Result := nil;
  AError := '';
  LCount := 0;
  LFileCount := 0;
  LRow := Default(TLspOutlineRow);
  LRow.ProjectFile := AProjectFile;   // every row's, set once
  S.Init(AJson);
  try
    S.SkipWs;
    if (S.PEnd - S.P >= 4) and (StrLComp(S.P, 'null', 4) = 0) then
      Exit;
    S.Expect('{');
    S.SkipWs;
    if not S.TryConsume('}') then
      repeat
        LKey := S.ReadString;
        S.Expect(':');
        if LKey = 'kinds' then
          LKinds := S.ReadStrings
        else if LKey = 'heads' then
          LHeads := S.ReadStrings
        else if LKey = 'sections' then
          LSections := S.ReadStrings
        else if LKey = 'owners' then
          LOwners := S.ReadStrings
        else if LKey = 'files' then
          ReadFiles
        else if LKey = 'rows' then
          ReadRows
        else
          S.SkipValue;
        S.SkipWs;
        if S.TryConsume('}') then
          Break;
        S.Expect(',');
      until False;
    SetLength(Result, LCount);
  except
    on E: EOutlineTable do
    begin
      Result := nil;
      AError := E.Message;
    end;
  end;
end;

function ParseOutlineTable(const AJson, AProjectFile: string):
  TArray<TLspOutlineRow>;
var
  LError: string;
begin
  Result := ParseOutlineTable(AJson, AProjectFile, LError);
end;

end.
