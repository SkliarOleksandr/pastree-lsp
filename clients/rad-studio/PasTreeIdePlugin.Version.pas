unit PasTreeIdePlugin.Version;

{
  This package's version, the oldest server it can work with, and the version
  comparison both need.

  Independent semver per repository (PasTree, the LSP server, this package),
  tied together by stated minimums rather than a shared number - see the header
  of PasTree.Version in the PasTree repo for the reasoning.

  THIS PACKAGE'S CHECK IS NECESSARILY A RUNTIME ONE. The server's own check on
  PasTree can be a build-time one, because PasTree is linked into the server's
  exe. Nothing is linked here: the plugin finds whatever pastree-server.exe
  happens to be next to its BPL (or wherever PASTREE_LSP_SERVER points), so the
  only moment the pair's compatibility can be established is the initialize
  handshake, and the only thing to do about a mismatch is say so clearly.

  A MISMATCH WARNS, IT DOES NOT REFUSE. An old server usually still answers the
  requests it does know, and a plugin that disabled itself over a version
  string would turn a partial degradation into a total one - with the same
  symptom every other misconfiguration here produces ("nothing happens on
  Ctrl+Click"), which is precisely the confusion this whole diagnostic effort
  exists to remove. So: navigate as well as possible, and put the reason in the
  Build tab where it can be read.

  CompareVersions IS DUPLICATED from PasTree.Version, deliberately. This
  package is a 32-bit designtime BPL and PasTree is Win64-only, so it CANNOT
  link that unit even if the sibling checkout were required - and it is not
  (the package builds from this repo alone, which is a property worth keeping).
  Twenty lines of numeric comparison is the cheaper half of that trade.
}

interface

const
  /// <summary>
  /// This package's version. Reported to the Build tab at session start next
  /// to the server's own, so a bug report says which pair was running.
  /// BUMP THE PATCH IN EVERY COMMIT, mechanically; bump the MINOR for a
  /// substantial change - see SPEC.md's Versioning section. The patch component
  /// is what lets this identify the BPL the IDE actually loaded (rebuilding
  /// inside a live IDE session does not reliably take effect here, so that is a
  /// real question); what this package REQUIRES is cMinServerVersion, below,
  /// which does not move with it.
  /// </summary>
  cPluginVersion = '0.2.1';

  /// <summary>
  /// The oldest pastree-server.exe this package can work with.
  ///
  /// It names the version that first supported everything the plugin ACTUALLY
  /// SENDS - textDocument/definition, textDocument/references, and the
  /// projectFile/platform/config/searchPaths/logFile initializationOptions -
  /// not simply the newest server that exists. Raising it to "whatever I just
  /// built" would reject working deployments and make the warning noise, and
  /// noise is how a real mismatch goes unread. Raise it in the commit that
  /// starts depending on something new.
  /// </summary>
  cMinServerVersion = '0.2.0';

/// <summary>
/// Compares two dotted version strings NUMERICALLY: negative if A is older
/// than B, 0 if equal, positive if newer. Missing components count as zero, so
/// '1' = '1.0' = '1.0.0'; a pre-release suffix ('0.2.0-rc1') is compared by its
/// numeric part only.
///
/// Numerically, not as text, because plain string comparison is wrong in the
/// case that matters most: '0.10.0' sorts BEFORE '0.9.0' as text, so a
/// minimum-version gate written that way would start rejecting newer servers
/// the moment the server reaches its tenth minor release - a bug that would
/// lie dormant for months and then look like a broken plugin.
/// </summary>
function CompareVersions(const A, B: string): Integer;

/// <summary>
/// The last-write time of a binary ('' if unreadable) - the build stamp. Taken
/// from the file rather than baked in at compile time: Delphi has no
/// compile-date macro, and the timestamp of the module that is actually loaded
/// cannot be stale in the way a generated constant can. Pass the BPL's own
/// filename (see PackageFileName in PasTreeIdePlugin.LspSession).
/// </summary>
function BinaryBuiltOn(const APath: string): string;

implementation

uses
  System.SysUtils,
  System.IOUtils;

function CompareVersions(const A, B: string): Integer;

  function PartOf(const AParts: TArray<string>; AIndex: Integer): Integer;
  var
    LText: string;
    LPos: Integer;
  begin
    Result := 0;
    if AIndex > High(AParts) then
      Exit;
    LText := AParts[AIndex];
    LPos := 1;
    while (LPos <= Length(LText)) and CharInSet(LText[LPos], ['0'..'9']) do
      Inc(LPos);
    LText := Copy(LText, 1, LPos - 1);
    if LText <> '' then
      Result := StrToIntDef(LText, 0);
  end;

var
  LA, LB: TArray<string>;
  LIdx, LMax, LLeft, LRight: Integer;
begin
  LA := A.Split(['.']);
  LB := B.Split(['.']);
  LMax := Length(LA);
  if Length(LB) > LMax then
    LMax := Length(LB);
  for LIdx := 0 to LMax - 1 do
  begin
    LLeft := PartOf(LA, LIdx);
    LRight := PartOf(LB, LIdx);
    if LLeft <> LRight then
      if LLeft < LRight then
        Exit(-1)
      else
        Exit(1);
  end;
  Result := 0;
end;

function BinaryBuiltOn(const APath: string): string;
begin
  Result := '';
  try
    if TFile.Exists(APath) then
      Result := FormatDateTime('yyyy-mm-dd hh:nn',
        TFile.GetLastWriteTime(APath));
  except
    Result := '';   // a build stamp is never worth an exception
  end;
end;

end.
