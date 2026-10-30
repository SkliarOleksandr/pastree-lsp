unit DemoClassCompleteFreeDeclFirst;

{
  Fixture for LspClientSmoke 5t: the interface section declares no routine
  yet, so the first one goes to its end, a blank line below the type.
}

interface

type
  TThing = class
  end;

implementation

procedure Lonely(A: Integer);
begin
end;

end.
