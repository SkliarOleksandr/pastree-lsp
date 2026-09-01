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
/// Byte-for-byte equality of a FILE and the bytes it should hold - the only
/// comparison an encoding round-trip test can be built on. A text comparison
/// would pass on exactly the bug this is looking for.
function SameBytes(const APath: string; const ABytes: TBytes): Boolean;
var
  LFile: TBytes;
begin
  try
    LFile := TFile.ReadAllBytes(APath);
  except
    Exit(False);
  end;
  Result := Length(LFile) = Length(ABytes);
  if Result and (Length(LFile) > 0) then
    Result := CompareMem(@LFile[0], @ABytes[0], Length(LFile));
end;

procedure TestSourceText;
var
  LDir, LPlain, LBom, LMissing, LAnsi, LUtf16: string;
  LText, LText2Read: string;
  LEnc: TPasSourceEncoding;
const
  cText = 'unit A;'#13#10'// em dash — here'#13#10'end.'#13#10;
  LText2 = 'unit B;'#13#10'end.'#13#10;
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
    LAnsi := TPath.Combine(LDir, 'ansi.pas');
    LUtf16 := TPath.Combine(LDir, 'utf16.pas');
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

    { The edit pair, and what it is for: the IDE plugin rewrites a source file
      that nobody has open (a rename reaching a closed unit), and it has to put
      the file back in the encoding it found it in. Getting that wrong is
      invisible in the diff and moves every non-ASCII column in the file -
      which is why the em-dash in cText is doing double duty here. }
    Check(TryReadSourceForEdit(LBom, LText, LEnc) and (LText = cText) and
      (LEnc = peUtf8Bom),
      'a BOM''d file reads as UTF-8-with-BOM, text without the BOM');
    Check(TryReadSourceForEdit(LPlain, LText, LEnc) and (LText = cText) and
      (LEnc = peUtf8),
      'a preamble-less file whose bytes are valid UTF-8 reads as UTF-8');

    // ANSI: a high byte that is NOT valid UTF-8, so the round-trip test has
    // to fall through to it. dcc's own rule for a preamble-less file.
    TFile.WriteAllBytes(LAnsi, TBytes.Create(Ord('a'), $E4, Ord('b')));
    Check(TryReadSourceForEdit(LAnsi, LText, LEnc) and (LEnc = peBytes) and
      (Length(LText) = 3),
      'bytes that are not UTF-8 read byte-for-byte, not as U+FFFD');

    Check(TryWriteSource(LBom, LText2, peUtf8Bom) and
      SameBytes(LBom, TBytes.Create($EF, $BB, $BF) +
        TEncoding.UTF8.GetBytes(LText2)),
      'writing UTF-8-with-BOM puts the preamble back');
    Check(TryWriteSource(LPlain, LText2, peUtf8) and
      SameBytes(LPlain, TEncoding.UTF8.GetBytes(LText2)),
      'writing bare UTF-8 adds no preamble');
    Check(TryReadSourceForEdit(LAnsi, LText, LEnc) and
      TryWriteSource(LAnsi, LText, LEnc) and
      SameBytes(LAnsi, TBytes.Create(Ord('a'), $E4, Ord('b'))),
      'a non-UTF-8 file round-trips byte for byte through read then write');

    // UTF-16 is the one encoding this pair refuses rather than transcodes.
    TFile.WriteAllBytes(LUtf16, TBytes.Create($FF, $FE, Ord('a'), 0));
    Check(not TryReadSourceForEdit(LUtf16, LText, LEnc),
      'a UTF-16 source is declined, not silently rewritten as UTF-8');

    { THE TWO READERS MUST AGREE, and until 0.23.0 they did not:
      TryReadTextNoBom went through TFile.ReadAllText, which falls back to the
      ANSI code page for a preamble-less file, while TryReadSourceForEdit
      detects UTF-8 first - the rule PasTree itself follows since 0.2.3. The
      server reads a file the editor does NOT have open through the former and
      then computes positions in it, so a disagreement here shifts every column
      after any non-ASCII character in a closed file. Same file, same string,
      or this is broken. }
    TFile.WriteAllBytes(LPlain, TEncoding.UTF8.GetBytes(cText));
    TFile.WriteAllBytes(LAnsi, TBytes.Create(Ord('a'), $E4, Ord('b')));
    Check(TryReadTextNoBom(LPlain, LText) and (LText = cText),
      'the em-dash file reads as UTF-8, not as the ANSI code page');
    Check(TryReadTextNoBom(LPlain, LText) and
      TryReadSourceForEdit(LPlain, LText2Read, LEnc) and (LText = LText2Read),
      'both readers return the same string for a preamble-less UTF-8 file');
    Check(TryReadTextNoBom(LAnsi, LText) and (Length(LText) = 3),
      'and the same one for bytes that are not UTF-8 (byte-for-byte, 3 chars)');
    Check(TryReadTextNoBom(LBom, LText) and (LText = LText2),
      'a BOM''d file still reads without its preamble');
    Check(not TryReadTextNoBom(LUtf16, LText),
      'and UTF-16 is declined here too, exactly as by the edit reader');
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
