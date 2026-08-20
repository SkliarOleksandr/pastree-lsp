program VersionSmoke;

{
  Pins the units SHARED by the server and the RAD Studio package:
  PasLsp.ProductVersion (the version string and the comparison that reads it)
  and PasLsp.SourceText (BOM and file-vs-buffer rules). No server, no IDE, no
  fixtures.

  Two things are worth a harness of their own here.

  FIRST, CompareVersions decides whether a deployment is reported as broken, so
  a wrong answer does not produce a wrong answer - it produces a warning about a
  perfectly good pair, or silence about a mismatched one, months later, on a
  version number nobody has reached yet. The motivating case is '0.10.0' vs
  '0.9.0': as text '0.10.0' sorts FIRST, so the naive comparison decides the
  newer build is the older one. That cannot be found by testing today's
  numbers; it can only be pinned in advance.

  SECOND, and the reason this harness is built as part of the package's test
  set: it proves BOTH SHARED UNITS COMPILE INTO A WIN32 PROGRAM THAT LINKS NO
  PASTREE. They are shared with the Win64 server, and the one change that would
  silently break the RAD Studio package is someone adding `uses PasTree.Version`
  to the version unit - the version is "just a string", so it looks harmless -
  or reaching for a PasTree source loader from PasLsp.SourceText, which is
  exactly the temptation a unit about reading source files invites. It is not
  harmless: PasTree is Win64-only, which is why the analysis moved out of
  process at all. This program failing to build IS that alarm.

  Usage: VersionSmoke.exe   (no arguments; exits non-zero on failure)
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  PasLsp.ProductVersion,
  PasLsp.SourceText;

var
  GFailures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln('  [ok]   ', AName)
  else
  begin
    Writeln('  [FAIL] ', AName);
    Inc(GFailures);
  end;
end;

/// <summary>
/// Asserts the SIGN of the comparison, and that swapping the arguments flips
/// it - an implementation that returned a constant would pass half of these.
/// </summary>
procedure CheckOlder(const AOlder, ANewer: string);
begin
  Check(CompareVersions(AOlder, ANewer) < 0,
    Format('%s is older than %s', [AOlder, ANewer]));
  Check(CompareVersions(ANewer, AOlder) > 0,
    Format('%s is newer than %s', [ANewer, AOlder]));
end;

procedure CheckEqual(const A, B: string);
begin
  Check(CompareVersions(A, B) = 0, Format('%s = %s', [A, B]));
  Check(CompareVersions(B, A) = 0, Format('%s = %s', [B, A]));
end;

/// <summary>
/// PasLsp.SourceText, over temporary files written here so the harness still
/// needs no fixtures. Two of these pin behaviour that cost real debugging: a
/// BOM must not survive into document text at all, and a file whose bytes ARE
/// the buffer's text must compare equal even though a tolerant ANSI decode of
/// those same bytes would not (the rebuild gate).
/// </summary>
procedure TestSourceText;
var
  LDir, LPlain, LBom, LMissing: string;
  LText: string;
const
  cText = 'unit A;'#13#10'// em dash — here'#13#10'end.'#13#10;
begin
  Check(StripLeadingBom('') = '', 'empty text survives the BOM strip');
  Check(StripLeadingBom('abc') = 'abc', 'text with no BOM is untouched');
  Check(StripLeadingBom(#$FEFF + 'abc') = 'abc', 'a leading BOM is removed');
  // Only LEADING: a U+FEFF later in the text is a zero-width no-break space,
  // which is content, and removing it would shift every column after it.
  Check(StripLeadingBom('a' + #$FEFF + 'bc') = 'a' + #$FEFF + 'bc',
    'a BOM that is not leading is content and stays');
  Check(StripLeadingBom(#$FEFF#$FEFF + 'a') = #$FEFF + 'a',
    'exactly one BOM is removed, not a run of them');

  LDir := TPath.Combine(TPath.GetTempPath, 'PasLspSourceTextSmoke');
  TDirectory.CreateDirectory(LDir);
  try
    LPlain := TPath.Combine(LDir, 'plain.pas');
    LBom := TPath.Combine(LDir, 'bom.pas');
    LMissing := TPath.Combine(LDir, 'nosuchfile.pas');

    TFile.WriteAllBytes(LPlain, TEncoding.UTF8.GetBytes(cText));
    TFile.WriteAllBytes(LBom,
      TBytes.Create($EF, $BB, $BF) + TEncoding.UTF8.GetBytes(cText));

    // The rebuild gate. cText holds an em-dash on purpose: this is precisely
    // the case where the two sides' decodes disagree and a string comparison
    // would call an untouched file "modified".
    Check(FileHoldsText(LPlain, cText),
      'a file holds the text its own UTF-8 bytes encode');
    Check(FileHoldsText(LBom, cText),
      'and still holds it when the file carries a UTF-8 BOM');
    Check(not FileHoldsText(LPlain, cText + 'x'),
      'a real edit is not mistaken for a decode difference');
    Check(not FileHoldsText(LMissing, cText),
      'an unreadable file holds nothing, rather than raising');

    Check(TryReadTextNoBom(LPlain, LText) and (LText = cText),
      'reading a plain file gives its text');
    Check(TryReadTextNoBom(LBom, LText) and (LText = cText),
      'reading a BOM''d file gives the same text, with no BOM');
    Check((not TryReadTextNoBom(LMissing, LText)) and (LText = ''),
      'a missing file reports failure and yields no text');
  finally
    try
      TDirectory.Delete(LDir, True);
    except
      // A leftover temp directory is not a test failure.
    end;
  end;
end;

begin
  GFailures := 0;
  Writeln('CompareVersions');

  // The whole point (see the header): double-digit components.
  CheckOlder('0.9.0', '0.10.0');
  CheckOlder('1.9.9', '1.10.0');
  CheckOlder('9.0.0', '10.0.0');

  // Ordinary ordering, one component at a time.
  CheckOlder('0.4.1', '0.5.0');
  CheckOlder('0.5.0', '0.5.1');
  CheckOlder('0.5.9', '0.6.0');
  CheckOlder('0.9.9', '1.0.0');

  // Missing components are zero, so a short string is not automatically older.
  CheckEqual('1', '1.0');
  CheckEqual('1', '1.0.0');
  CheckEqual('0.5.0', '0.5.0');
  CheckOlder('1.0', '1.0.1');

  // A pre-release suffix compares by its numeric part only, which makes an rc
  // EQUAL to its release rather than older. Deliberate: the comparison is used
  // to spot a stale binary, and an rc of a version is the same build lineage.
  CheckEqual('0.5.0-rc1', '0.5.0');
  CheckOlder('0.5.0-rc1', '0.6.0');

  // Junk must not raise: these strings come off the wire, from serverInfo.
  Check(CompareVersions('', '') = 0, 'empty = empty');
  Check(CompareVersions('', '0.1.0') < 0, 'empty is older than 0.1.0');
  Check(CompareVersions('x.y.z', '') = 0, 'unparseable counts as 0.0.0');

  Writeln;
  Writeln('the product version');

  // The shared constant must be readable here at all - see the header: this is
  // the check that the package's half of the product can see it without
  // linking PasTree.
  Check(PasTreeLspVersion <> '', 'PasTreeLspVersion is set: ' + PasTreeLspVersion);
  Check(CompareVersions(PasTreeLspVersion, PasTreeLspVersion) = 0,
    'the product version equals itself, so a matched pair never warns');

  // The stale-deployment check the LSP client performs, in both directions. It
  // is equality now, not a minimum: both halves come from one commit, so any
  // difference means one binary was not rebuilt.
  Check(CompareVersions(PasTreeLspVersion, '0.0.1') > 0,
    'an ancient server version differs from ours, so it warns');
  Check(PasTreeLspVersion <> '', 'an empty serverInfo version differs too');

  Writeln;
  Writeln('source text (BOM, and buffer vs file)');
  TestSourceText;

  Writeln;
  if GFailures = 0 then
    Writeln('RESULT: PASS')
  else
  begin
    Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := 1;
  end;
end.
