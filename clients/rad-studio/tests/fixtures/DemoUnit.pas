unit DemoUnit;

{ Fixture for tests\LspClientSmoke.dpr - see DemoApp.dpr. Fixed lines. }

interface

type
  TBox = record
    Value: string; const CSlots = 4;
  end;

const
  CAnswer = 42; CCastMask = Cardinal(Ord('A')); CBoxSlots = TBox.CSlots;

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
