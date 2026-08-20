program VersionSmoke;

{
  Pins PasTreeIdePlugin.Version.CompareVersions. No server, no IDE, no
  fixtures - it is pure arithmetic on strings, and it is worth a harness of its
  own for one reason: it is a COMPATIBILITY GATE, so a wrong answer here does
  not produce a wrong answer, it produces a plugin that refuses to work with a
  server that is perfectly fine (or accepts one that is not) - and it does so
  months later, on a version number nobody has reached yet.

  The case that motivates all of this is '0.10.0' vs '0.9.0'. As text, '0.10.0'
  sorts FIRST, so the naive comparison decides that server 0.10.0 is older than
  the required 0.9.0 and warns on every start. That bug cannot be found by
  testing today's numbers; it can only be pinned in advance.

  Usage: VersionSmoke.exe   (no arguments; exits non-zero on failure)
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PasTreeIdePlugin.Version;

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

begin
  GFailures := 0;
  Writeln('CompareVersions');

  // The whole point (see the header): double-digit components.
  CheckOlder('0.9.0', '0.10.0');
  CheckOlder('1.9.9', '1.10.0');
  CheckOlder('9.0.0', '10.0.0');

  // Ordinary ordering, one component at a time.
  CheckOlder('0.1.0', '0.2.0');
  CheckOlder('0.2.0', '0.2.1');
  CheckOlder('0.2.9', '0.3.0');
  CheckOlder('0.9.9', '1.0.0');

  // Missing components are zero, so a short string is not automatically older.
  CheckEqual('1', '1.0');
  CheckEqual('1', '1.0.0');
  CheckEqual('0.3.0', '0.3.0');
  CheckOlder('1.0', '1.0.1');

  // A pre-release suffix compares by its numeric part only. That makes an rc
  // EQUAL to its release rather than older - deliberately: this gate exists to
  // catch a server that is missing a feature, and an rc of the version that
  // has it does have it.
  CheckEqual('0.2.0-rc1', '0.2.0');
  CheckOlder('0.2.0-rc1', '0.3.0');

  // Junk must not raise: these strings come off the wire, from serverInfo.
  Check(CompareVersions('', '') = 0, 'empty = empty');
  Check(CompareVersions('', '0.1.0') < 0, 'empty is older than 0.1.0');
  Check(CompareVersions('x.y.z', '') = 0, 'unparseable counts as 0.0.0');

  // The gate the plugin actually runs, in both directions.
  Check(CompareVersions('0.2.0', cMinServerVersion) >= 0,
    Format('a %s server satisfies the plugin''s minimum (%s)',
      ['0.2.0', cMinServerVersion]));
  Check(CompareVersions('0.1.0', cMinServerVersion) < 0,
    Format('a 0.1.0 server does not satisfy the minimum (%s)',
      [cMinServerVersion]));

  Writeln;
  if GFailures = 0 then
    Writeln('RESULT: PASS')
  else
  begin
    Writeln(Format('RESULT: FAIL (%d checks failed)', [GFailures]));
    ExitCode := 1;
  end;
end.
