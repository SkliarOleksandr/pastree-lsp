unit PasLsp.Version;

{
  This server's version, and the oldest PasTree it can be built against.

  Independent semver per repository, tied together by stated minimums rather
  than by a shared number - see the header of PasTree.Version for the reasoning
  and CompareVersions for the comparison this relies on.

  THE PASTREE CHECK IS A COMPILE-TIME ONE, and it is the only one of the three
  that can be: PasTree is linked into this exe, so "which PasTree am I using"
  is decided when the exe is built, and a mismatch should stop the build rather
  than surface as a puzzling runtime failure. The plugin's check on THIS server
  is necessarily a runtime one - it talks to whatever exe it finds on disk.
}

interface

uses
  PasTree.Version;

const
  /// <summary>
  /// This server's version, reported to every client in the initialize
  /// response (serverInfo.version), on the log's first line and by --version.
  /// BUMP THE PATCH IN EVERY COMMIT, mechanically; bump the MINOR for a
  /// substantial change (a new request, a new initializationOption) - see
  /// SPEC.md's Versioning section. The patch component is what lets this
  /// identify a build; what a client can RELY on is expressed by its own
  /// cMinServerVersion instead.
  /// </summary>
  PasLspServerVersion = '0.4.1';

  /// <summary>
  /// The oldest PasTree this server's code actually works with. Raise it in
  /// the same commit that starts depending on something newer - that is the
  /// commit where a stale sibling checkout begins producing wrong answers
  /// instead of a compile error, which is the failure this constant exists to
  /// convert back into a compile error.
  /// </summary>
  cMinPasTreeVersion = '0.1.0';

/// <summary>
/// One line naming both versions and when this exe was built - the log's first
/// line, and what --version prints. Both numbers, always: "the server is
/// 0.3.0" does not tell you whether the resolver fix you are looking for is in
/// it, and that fix lives in PasTree.
/// </summary>
function PasLspVersionBanner: string;

implementation

uses
  System.SysUtils;

{ Compile-time gate on the sibling PasTree checkout. A string comparison is not
  possible in a $IF, so this is checked at unit initialization instead - the
  earliest moment a string comparison can run, and still before any request is
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
    [PasLspServerVersion, PasTreeVersion, LBuilt]);
end;

initialization
  CheckPasTreeVersion;

end.
