unit PasLsp.Documents;

{
  Open-document store: the server-side half of the LSP "document truth" rule
  (SPEC.md) — once a file is open here, its text and version come from the
  client and PasTree must never read that path from disk until didClose.
  Enforced by handing every entry to TPasSemaProject.SetBuffer (with the
  version) before each analysis.

  Keyed by full lower-cased path, matching TPasSourceManager's own keying.
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  System.IOUtils;

type
  TLspDocument = record
    Path: string;      // full path, original casing
    Text: string;
    Version: Integer;  // client's didOpen/didChange version
    DiskText: string;  // the file's on-disk text at didOpen (tolerant decode)
    // Whether Text differs from DiskText — the REBUILD gate: an editor sends
    // didOpen/didClose for every tab switch and every peek popup, and a
    // document whose text equals the disk file cannot change any analysis
    // result, so those events must not cost a full project rebuild.
    Differs: Boolean;
  end;

  TLspDocumentStore = class
  private
    FDocs: TDictionary<string, TLspDocument>;
    class function KeyOf(const APath: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open(const APath, AText: string; AVersion: Integer;
      const ADiskText: string; ADiffers: Boolean);
    { Replaces the stored text (the caller has already applied whatever
      incremental edits arrived). DiskText is carried over from the open —
      the caller compares against it without re-reading. }
    procedure Change(const APath, AText: string; AVersion: Integer;
      const ADiskText: string; ADiffers: Boolean);
    procedure Close(const APath: string);
    function TryGet(const APath: string; out ADoc: TLspDocument): Boolean;
    function All: TArray<TLspDocument>;
    function Count: Integer;
  end;

{ An LSP position (0-based line, 0-based UTF-16 code unit) as a 1-based index
  into AText. Delphi strings ARE UTF-16, so a character offset is an index
  offset and no encoding conversion happens here — see PasLsp.Protocol's own
  note on position encoding.

  Lines are split on CRLF, LF or a lone CR, all three, because that is the
  spec's definition of a line and a real document carries whichever its author
  used. A position past the end of its line (or past the end of the document)
  CLAMPS to that end: editors legitimately send end-of-line positions, and a
  clamp keeps a malformed or racing patch from raising. }
function PositionToIndex(const AText: string; ALine, ACharacter: Integer):
  Integer;

{ AText with the given LSP range replaced by ANewText — one incremental
  contentChange. A reversed range is treated as empty (an insertion at its
  start) rather than as an error. }
function ApplyRangeChange(const AText: string; AStartLine, AStartChar,
  AEndLine, AEndChar: Integer; const ANewText: string): string;

implementation

function PositionToIndex(const AText: string; ALine, ACharacter: Integer):
  Integer;
var
  LIdx, LLen, LSeen: Integer;
begin
  LLen := Length(AText);
  LIdx := 1;
  LSeen := 0;
  while (LSeen < ALine) and (LIdx <= LLen) do
  begin
    case AText[LIdx] of
      #13:
        begin
          Inc(LIdx);
          if (LIdx <= LLen) and (AText[LIdx] = #10) then
            Inc(LIdx);          // CRLF counts once
          Inc(LSeen);
        end;
      #10:
        begin
          Inc(LIdx);
          Inc(LSeen);
        end;
    else
      Inc(LIdx);
    end;
  end;
  // Walk the requested column, stopping at the line break: a character offset
  // beyond the line's length clamps to its end.
  while (ACharacter > 0) and (LIdx <= LLen) and
        not CharInSet(AText[LIdx], [#13, #10]) do
  begin
    Dec(ACharacter);
    Inc(LIdx);
  end;
  Result := LIdx;
end;

function ApplyRangeChange(const AText: string; AStartLine, AStartChar,
  AEndLine, AEndChar: Integer; const ANewText: string): string;
var
  LFrom, LTo: Integer;
begin
  LFrom := PositionToIndex(AText, AStartLine, AStartChar);
  LTo := PositionToIndex(AText, AEndLine, AEndChar);
  if LTo < LFrom then
    LTo := LFrom;
  Result := Copy(AText, 1, LFrom - 1) + ANewText + Copy(AText, LTo, MaxInt);
end;

constructor TLspDocumentStore.Create;
begin
  inherited Create;
  FDocs := TDictionary<string, TLspDocument>.Create;
end;

destructor TLspDocumentStore.Destroy;
begin
  FDocs.Free;
  inherited;
end;

class function TLspDocumentStore.KeyOf(const APath: string): string;
begin
  Result := LowerCase(TPath.GetFullPath(APath));
end;

procedure TLspDocumentStore.Open(const APath, AText: string;
  AVersion: Integer; const ADiskText: string; ADiffers: Boolean);
var
  LDoc: TLspDocument;
begin
  LDoc.Path := TPath.GetFullPath(APath);
  LDoc.Text := AText;
  LDoc.Version := AVersion;
  LDoc.DiskText := ADiskText;
  LDoc.Differs := ADiffers;
  FDocs.AddOrSetValue(KeyOf(APath), LDoc);
end;

procedure TLspDocumentStore.Change(const APath, AText: string;
  AVersion: Integer; const ADiskText: string; ADiffers: Boolean);
begin
  Open(APath, AText, AVersion, ADiskText, ADiffers);   // same shape
end;

procedure TLspDocumentStore.Close(const APath: string);
begin
  FDocs.Remove(KeyOf(APath));
end;

function TLspDocumentStore.TryGet(const APath: string;
  out ADoc: TLspDocument): Boolean;
begin
  Result := FDocs.TryGetValue(KeyOf(APath), ADoc);
end;

function TLspDocumentStore.All: TArray<TLspDocument>;
begin
  Result := FDocs.Values.ToArray;
end;

function TLspDocumentStore.Count: Integer;
begin
  Result := FDocs.Count;
end;

end.
