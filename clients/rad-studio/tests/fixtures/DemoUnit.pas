unit DemoUnit;

{ Fixture for tests\LspClientSmoke.dpr - see DemoApp.dpr. }

interface

function Greet(const AName: string): string;

implementation

function Greet(const AName: string): string;
begin
  Result := 'Hello, ' + AName;
end;

end.
