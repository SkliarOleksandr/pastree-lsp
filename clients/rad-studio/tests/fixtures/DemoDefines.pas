unit DemoDefines;

{ Fixture for tests\LspClientSmoke.dpr: conditional symbols, the FOURTH
  identity (PasTree 0.27.0). DEMO_FEATURE is defined and tested here; the
  second DEFINE after the test is what Go to Definition must NOT pick (the
  nearest PRECEDING one wins). MSWINDOWS comes from the platform, so it has
  mentions but no source site. }

interface

{$DEFINE DEMO_FEATURE}

{$IFDEF DEMO_FEATURE}
function FeatureName: string;
{$ENDIF}

{$IF Defined(MSWINDOWS) and Defined(DEMO_FEATURE)}
function PlatformName: string;
{$ENDIF}

{$DEFINE DEMO_FEATURE}

{$IFDEF DEMO_NEVER} // a directive in a dead branch is inactive code too
  {$DEFINE DEMO_DEAD}
{$ENDIF}

implementation

function FeatureName: string;
begin
  Result := 'feature';
end;

function PlatformName: string;
begin
  Result := 'windows';
{$IFDEF DEMO_NEVER}
  Result := FeatureName + ' (never compiled)';
{$ENDIF}
end;

// Options at cursor (pastree/optionsAt): range and overflow checks on,
// a pushed state where one of them is switched off again, the pop, and a
// long-form-only option. Below the last pinned position on purpose.
{$R+,Q+}
{$PUSHOPT}
{$RANGECHECKS OFF}
{$POPOPT}
{$SCOPEDENUMS ON}

end.
