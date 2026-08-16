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
  end;

  TLspDocumentStore = class
  private
    FDocs: TDictionary<string, TLspDocument>;
    class function KeyOf(const APath: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open(const APath, AText: string; AVersion: Integer);
    { Full-sync change (phase 1: TextDocumentSyncKind.Full). }
    procedure Change(const APath, AText: string; AVersion: Integer);
    procedure Close(const APath: string);
    function TryGet(const APath: string; out ADoc: TLspDocument): Boolean;
    function All: TArray<TLspDocument>;
    function Count: Integer;
  end;

implementation

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
  AVersion: Integer);
var
  LDoc: TLspDocument;
begin
  LDoc.Path := TPath.GetFullPath(APath);
  LDoc.Text := AText;
  LDoc.Version := AVersion;
  FDocs.AddOrSetValue(KeyOf(APath), LDoc);
end;

procedure TLspDocumentStore.Change(const APath, AText: string;
  AVersion: Integer);
begin
  Open(APath, AText, AVersion);   // full sync: same shape as an open
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
