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

implementation

function FeatureName: string;
begin
  Result := 'feature';
end;

function PlatformName: string;
begin
  Result := 'windows';
end;

end.
