unit PasLsp.Version;

{
  The PasTree-dependent half of versioning: the minimum PasTree this server can
  be built against, the check that enforces it, and the banner that names both
  numbers.

  SPLIT FROM PasLsp.ProductVersion FOR A HARD REASON, not tidiness. The product
  version has to be readable by the RAD Studio package, which is a Win32
  designtime BPL and cannot link PasTree (Win64-only). So the version string
  itself lives in a unit with no dependencies, and everything that needs
  PasTree.Version stays here - compiled only into pastree-server.exe. See the
  header of PasLsp.ProductVersion.

  THE PASTREE CHECK IS THE ONLY BUILD-TIME ONE IN THE PRODUCT. PasTree is
  linked into this exe, so which PasTree is in use is decided when the exe is
  built, and a mismatch should fail loudly at startup rather than surface later
  as puzzling wrong answers. The other direction - is the deployed package the
  same build as the deployed exe - can only be checked at runtime, over the
  protocol, and lives in the package's LSP client.
}

interface

uses
  PasLsp.ProductVersion,
  PasTree.Version;

const
  /// <summary>
  /// The oldest PasTree this server's code actually works with. Raise it in the
  /// same commit that starts depending on something newer - that is the commit
  /// where a stale sibling checkout begins producing wrong answers instead of a
  /// compile error, which is the failure this constant exists to convert back
  /// into a loud one.
  ///
  /// It may legitimately name a PATCH version of PasTree: a resolver fix is a
  /// patch in PasTree's own terms and can still be a hard requirement here.
  /// </summary>
  /// Raised to 0.2.3 on 2026-08-20: that is where PasTree started decoding a
  /// preamble-less source as UTF-8 when its bytes are valid UTF-8, instead of
  /// always as ANSI. This server's columns are only correct against that rule -
  /// an older PasTree reads a different string out of the same file and every
  /// position after a non-ASCII character on the line is off, silently. Exactly
  /// the "wrong answers instead of a compile error" case above.
  cMinPasTreeVersion = '0.2.3';

/// <summary>
/// One line naming the product version, the PasTree it was built against, and
/// when this exe was built - the log's first line, and what --version prints.
/// Both numbers, always: "the server is 0.5.0" does not tell you whether the
/// resolver fix you are looking for is in it, and that fix lives in PasTree.
/// </summary>
function PasLspVersionBanner: string;

implementation

uses
  System.SysUtils;

{ Compile-time gate on the sibling PasTree checkout, in spirit. A string
  comparison cannot run in a $IF, so this is checked at unit initialization
  instead - the earliest moment it can be, and still before any request is
  served. }
procedure CheckPasTreeVersion;
begin
  if CompareVersions(PasTreeVersion, cMinPasTreeVersion) < 0 then
    raise Exception.CreateFmt(
      'built against PasTree %s, but this server needs %s or newer - update '
      + 'the ..\object-pascal-tree checkout and rebuild',
      [PasTreeVersion, cMinPasTreeVersion]);
end;

function PasLspVersionBanner: string;
var
  LBuilt: string;
begin
  // ParamStr(0) is this exe - see BinaryBuiltOn for why the stamp comes from
  // the file rather than from a compile-time constant.
  LBuilt := BinaryBuiltOn(ParamStr(0));
  if LBuilt <> '' then
    LBuilt := ', built ' + LBuilt;
  Result := Format('pastree-lsp-server %s (PasTree %s%s)',
    [PasTreeLspVersion, PasTreeVersion, LBuilt]);
end;

initialization
  CheckPasTreeVersion;

end.
