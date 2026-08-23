unit DemoUnit;

{ Fixture for tests\LspClientSmoke.dpr - see DemoApp.dpr. }

interface

type
  TBox = record
    Value: string;
  end;

const
  CAnswer = 42;

/// <summary>
/// Greets a person
/// by name.
/// </summary>
/// <param name="AName">the name to greet</param>
/// <returns>the greeting line</returns>
function Greet(const AName: string): string;

implementation

function Greet(const AName: string): string;
begin
  Result := 'Hello, ' + AName;
end;

end.
