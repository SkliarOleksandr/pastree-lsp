unit PasLsp.ProductVersion;

{
  ONE VERSION FOR THE WHOLE PRODUCT - the server and every client that ships
  with it - plus the two helpers that reading a version requires.

  WHY ONE NUMBER. The server and the RAD Studio package are two halves of one
  deliverable: neither is useful with a mismatched other half, and they are
  built from the same commit by the same script. So "which version is the
  plugin" and "which version is the server" are not two questions, and giving
  them two numbers only created a way for the answers to disagree. They did
  disagree, for real, on 2026-08-20: a rebuilt package ran against a server exe
  from the previous day, and the only symptom was a version string a human
  happened to read. With one number that condition is an equality check.

  ZERO DEPENDENCIES, AND THAT IS A HARD REQUIREMENT, NOT A STYLE PREFERENCE.
  This unit is linked into BOTH pastree-server.exe (Win64, links PasTree) and
  the RAD Studio designtime package (Win32, links rtl/vcl/designide and nothing
  else - PasTree is Win64-only and CANNOT go in there; that constraint is the
  entire reason the analysis moved out of process). Anything this unit `uses`
  must therefore be available in a plain Win32 designtime BPL.

    RTL AND Winapi ONLY - System.SysUtils, System.IOUtils, Winapi.Windows.
    NEVER A UNIT FROM THIS PRODUCT, AND ABOVE ALL NEVER PasTree.

  Winapi.Windows is here for one call, GetModuleFileName in ThisBinaryPath, and
  is as available in a designtime BPL as SysUtils is. The line that must not be
  crossed is a PROJECT dependency: adding PasTree.Version - which looks harmless,
  since the version is "just a string" - would break the package build outright.
  What belongs with PasTree lives in PasLsp.Version instead (cMinPasTreeVersion,
  the startup check, the banner), which only the server compiles.
  tests/VersionSmoke is the tripwire either way: it links this unit into a Win32
  program, so it stops compiling the moment that line is crossed.

  VERSIONING POLICY: patch in every commit, minor for a substantial change. See
  SPEC.md. PasTree keeps its own independent version - it is a general-purpose
  library with consumers of its own, and it is the one dependency this product
  states a minimum against.
}

interface

const
  /// <summary>
  /// The product version: this server AND the clients in clients\. Reported in
  /// the initialize response (serverInfo.version), by --version, on the log's
  /// first line, and by the RAD Studio package in the IDE's Build tab.
  ///
  /// BUMP THE PATCH IN EVERY COMMIT, mechanically - that is what makes this
  /// identify a build, which is the question actually asked from outside a
  /// deployed binary ("is the exe/BPL I am running the one I just built?").
  /// Bump the MINOR for a substantial change; that component keeps its ordinary
  /// semver meaning.
  /// </summary>
  PasTreeLspVersion = '0.13.0';

/// <summary>
/// Compares two dotted version strings NUMERICALLY: negative if A is older than
/// B, 0 if equal, positive if newer. Missing components count as zero, so
/// '1' = '1.0' = '1.0.0'; a pre-release suffix ('0.5.0-rc1') is compared by its
/// numeric part only.
///
/// Numerically, not as text, because plain string comparison is wrong in the
/// case that matters most: '0.10.0' sorts BEFORE '0.9.0' as text, so any
/// version gate written that way starts misjudging builds the moment a
/// component reaches its tenth release - a bug that lies dormant for months and
/// then looks like broken software. Pinned by clients\rad-studio\tests\
/// VersionSmoke.
/// </summary>
function CompareVersions(const A, B: string): Integer;

/// <summary>
/// The last-write time of a binary ('' if unreadable) - the build stamp.
///
/// Deliberately taken from the FILE rather than baked in at compile time:
/// Delphi has no compile-date macro (the {$I %DATE%} form is Free Pascal's, and
/// this was written with it once already), and a generated include file is a
/// build step that can be skipped, whereas the binary that is actually running
/// cannot misreport itself. It answers what a version cannot when a commit has
/// not happened: whether this exe/BPL was rebuilt at all. Pass ParamStr(0) for
/// the running exe, or a module's own filename for a DLL/BPL.
/// </summary>
function BinaryBuiltOn(const APath: string): string;

/// <summary>
/// The full path of the binary THIS CODE IS LINKED INTO - the .bpl inside the
/// designtime package, the .exe inside the server - which is what makes it the
/// right argument for BinaryBuiltOn above. HInstance in a package is the package
/// module rather than the host's exe, which is the whole reason this works from
/// inside a BPL loaded by RAD Studio.
///
/// Here rather than in the package because both halves ask the same question,
/// and it had already been written twice by the time anyone noticed. Empty
/// string if the OS declines to answer.
/// </summary>
function ThisBinaryPath: string;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Winapi.Windows;   // GetModuleFileName only - see ThisBinaryPath

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
    // Cut a pre-release/build suffix off the component ('0-rc1' -> '0').
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

function ThisBinaryPath: string;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LLen: DWORD;
begin
  LLen := GetModuleFileName(HInstance, @LBuffer[0], Length(LBuffer));
  if LLen = 0 then
    Exit('');
  Result := string(LBuffer);
end;

end.
