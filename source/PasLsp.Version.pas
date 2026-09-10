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
  ///
  /// Raised to 0.4.3 on 2026-08-21: PasLsp.Completion now runs PasTree's
  /// completion engine (PasTree.Sema.Complete, the bridged overlay pipeline),
  /// which stabilized at that version. An older sibling fails to compile
  /// anyway (the unit did not exist); the gate makes the requirement explicit.
  ///
  /// Raised to 0.5.0 on 2026-08-22: the seam adopted the CompleteAt overload
  /// that returns the caret info and ItemHeadWord - both new in 0.5.0.
  ///
  /// Raised to 0.6.0 later on 2026-08-22: signature help moved onto the
  /// engine's CallAt, and completion rows onto ItemParamsText/ItemHasParams
  /// (intrinsic signatures included) - all new in 0.6.0.
  ///
  /// Raised to 0.6.3 on 2026-08-23: Help Insight reads the doc-comment
  /// accessors added there - TPasCompletion.ItemDocComment for completion
  /// rows and TPasSemaProject.SymDocComment for hover. Without them the
  /// XMLDoc surfaces would compile against nothing.
  ///
  /// Raised to 0.9.0 on 2026-08-24: the analysis host now drives PasTree's
  /// incremental reanalysis - TPasAsyncSession.CreateForModule/ModuleAccepted
  /// for a one-unit edit and SetParseDonor for the rebuild that follows a
  /// refusal. Both are new in 0.9.0, and the guards that make the fast path
  /// sound (interface prefix, instance table) live in that version's
  /// AnalyzeModuleOnly - which is exactly why this is a version gate and not
  /// a compile-time one: an older sibling must fail loudly rather than have
  /// the server infer anything about what its guards checked.
  ///
  /// Raised to 0.11.0 on 2026-08-28: the incremental path grew the two things
  /// the server now depends on. 0.10.0 made an INTERFACE edit redo the units
  /// it can reach instead of refusing outright - which is what turns the fast
  /// path from a body-edit special case into the ordinary one - and 0.11.0
  /// turned the blast-radius ceiling into TPasSemaProject.ModuleRedoLimit,
  /// which the "moduleRedoLimit" initialization option writes. The property
  /// is the compile-time half; the behaviour is not, and that is the half
  /// this gate is for: against 0.9.0 every interface edit silently falls back
  /// to a closure rebuild and the only symptom is that editing feels slow.
  /// Raised to 0.12.0 on 2026-08-30: rename. TPasNavigator.PlanRename and
  /// IsValidRenameName are what textDocument/rename and pastree/renamePlan
  /// ARE - there is no fallback to degrade to, so an older sibling must
  /// fail at compile time rather than at the first F2.
  ///
  /// Raised again to 0.13.2 on 2026-08-31, for the UNIT half: PlanUnitRename
  /// and IsValidUnitRenameName. Same reasoning, and one extra: a unit rename
  /// carries a FILE obligation (ARequiredFileName), so a version without it
  /// would not merely lack a feature - the server would have to guess the
  /// file name, which is the one thing it must never do.
  /// Raised to 0.15.1 on 2026-09-02, and this one is not about a missing API
  /// at all - it is the second time the gate has been used the way the
  /// UTF-8 pin was. Before 0.15.1 PasTree's three FNV hashes inherited the
  /// compiling project's overflow check, so a server built from the IDE (whose
  /// stock Debug configuration sets $Q+) raised EIntOverflow inside
  /// TPasSemaProject.Create, and the half-built object's destructor faulted on
  /// top of it and hid the cause. The symptom is an EAccessViolation before
  /// the first analysis and every request failing afterwards - total, silent
  /// about its origin, and indistinguishable from a resolver defect. It cost
  /// two rounds of diagnosis, so an older sibling checkout has to fail here
  /// rather than at the user's first Ctrl+Click.
  ///
  /// 0.17.0 (2026-09-07): inline `var L := Expr` / `const C = Expr` /
  /// `for var I :=` typing, and with 0.17.1 a promoted `property Items;`
  /// taking its type from the ancestor. Not because this server's own code
  /// changed - it did not - but because LspClientSmoke 5l now ASKS for those
  /// types, and an older sibling answers nothing while every request still
  /// succeeds. That is the shape this floor exists for: a silent absence
  /// rather than a compile error.
  ///
  /// 0.20.1 (2026-09-08): MethodAt/FindOverrides and InterfaceMethodAt/
  /// FindImplementations, behind pastree/findOverrides and
  /// pastree/findImplementations. An older sibling fails to COMPILE here
  /// rather than silently, so the floor is documentation as much as a check -
  /// but a floor that names the real requirement is the one worth having.
  ///
  /// 0.21.0 (2026-09-09): pokRedeclared, the property half of an override
  /// chain - a bare `property Items;` republishing an inherited property is
  /// the same property, so Find Overrides answers its declarations. Half of
  /// this is loud: cKindWord in PasLsp.Server is typed over the enum, so the
  /// new value failed the element count and the build stopped. The other half
  /// is not, and is the reason the floor moves: against 0.20.3 MethodAt says
  /// False on a property, so the command is simply DISABLED on one, and Find
  /// References and Rename see each declaration in the chain as an unrelated
  /// property - a rename that touches one link and silently leaves the others.
  ///
  /// 0.23.0 (2026-09-10): the rest of the Find All family - TypeAt/
  /// FindDescendants, AssignableAt/FindAssignments, ClassAt/FindCreations/
  /// FindDestructions and InterfaceAt/FindInterfaceImplementors, behind
  /// pastree/findDescendants, findAssignments, findCreations,
  /// findDestructions, the interface-name half of findImplementations and
  /// the findAllAt gate. Loud again - a missing method does not compile -
  /// and the floor moves so the line beside the version says which sibling
  /// the six methods need.
  ///
  /// 0.25.0 (2026-09-10): FindImplementations/FindInterfaceImplementors stop
  /// at the classes that spell THIS interface's name - a class listing a
  /// descendant interface is no longer a row - and the AIncludeIndirect
  /// parameter 0.24.x put on them and on FindDescendants is gone. The
  /// second half is loud; the first is exactly the silent shape: against
  /// 0.24.x the two-argument call compiles (the parameter had a default) and
  /// answers rows SPEC.md now says are not rows, on a base interface by the
  /// hundred.
  cMinPasTreeVersion = '0.25.0';

/// <summary>
/// One line naming the product version, the PasTree it was built against, and
/// when this exe was built - the log's first line, and what --version prints.
/// Both numbers, always: "the server is 0.5.0" does not tell you whether the
/// resolver fix you are looking for is in it, and that fix lives in PasTree.
/// </summary>
function PasLspVersionBanner: string;

/// <summary>
/// One line naming the CPU model, logical core count and total physical RAM -
/// the log's second line, next to the version banner. A report from someone
/// else's machine needs this before "is it slow because of the hardware or
/// because of a regression" is answerable at all.
/// </summary>
function PasLspHardwareBanner: string;

implementation

uses
  System.SysUtils,
  System.Win.Registry,
  Winapi.Windows;

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

// GlobalMemoryStatusEx reports what Windows can actually hand out, which is
// short of the DIMM total by whatever the BIOS/UEFI, integrated graphics and
// the like carve out first - a 32 GB kit reports as 31.9. That is correct,
// not a rounding bug, but it reads as one, so this snaps to the nearest
// stick of RAM a human would say they bought rather than printing the raw
// figure.
function NearestInstalledRamGb(ARawGb: Double): Integer;
const
  // Every capacity a DIMM actually ships in, so a real total lands within
  // rounding distance of exactly one of these - no arbitrary tolerance band
  // that could snap a genuinely odd total to the wrong neighbour.
  cRamSteps: array [0 .. 13] of Integer = (1, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    48, 64, 96, 128);
var
  I, LBest: Integer;
begin
  LBest := cRamSteps[0];
  for I := 0 to High(cRamSteps) do
    if Abs(cRamSteps[I] - ARawGb) < Abs(LBest - ARawGb) then
      LBest := cRamSteps[I];
  Result := LBest;
end;

function PasLspHardwareBanner: string;
var
  LSysInfo: TSystemInfo;
  LMemStatus: TMemoryStatusEx;
  LReg: TRegistry;
  LCpuName: string;
  LRamGb: Integer;
  LMhz: Integer;
  LSpeed: string;
begin
  GetSystemInfo(LSysInfo);

  FillChar(LMemStatus, SizeOf(LMemStatus), 0);
  LMemStatus.dwLength := SizeOf(LMemStatus);
  LRamGb := 0;
  if GlobalMemoryStatusEx(LMemStatus) then
    LRamGb := NearestInstalledRamGb(LMemStatus.ullTotalPhys /
      (1024 * 1024 * 1024));

  // The core count comes from GetSystemInfo, not the registry - the registry
  // key below is one entry per logical processor and only ever describes the
  // model name and rated speed, never the count.
  LCpuName := '';
  LMhz := 0;
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_LOCAL_MACHINE;
    if LReg.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0')
    then
    begin
      LCpuName := Trim(LReg.ReadString('ProcessorNameString'));
      // "~MHz" is the nominal (rated/base) clock Windows recorded at boot,
      // not the current, boost- and throttle-dependent speed - the number
      // that names the chip, which is what belongs next to its model.
      if LReg.ValueExists('~MHz') then
        LMhz := LReg.ReadInteger('~MHz');
    end;
  finally
    LReg.Free;
  end;
  if LCpuName = '' then
    LCpuName := 'unknown CPU';

  LSpeed := '';
  if LMhz > 0 then
    LSpeed := Format(' @ %.1f GHz', [LMhz / 1000]);

  Result := Format('hardware: %s%s, %d cores, %d GB RAM',
    [LCpuName, LSpeed, LSysInfo.dwNumberOfProcessors, LRamGb]);
end;

initialization
  CheckPasTreeVersion;

end.
