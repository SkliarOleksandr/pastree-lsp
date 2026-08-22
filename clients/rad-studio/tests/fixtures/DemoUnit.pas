unit DemoUnit;

{ Fixture for tests\LspClientSmoke.dpr - see DemoApp.dpr. }

interface

type
  TBox = record
    Value: string;
  end;

const
  CAnswer = 42;

function Greet(const AName: string): string;

implementation

function Greet(const AName: string): string;
begin
  Result := 'Hello, ' + AName;
end;

end.
