unit Demo.Dotted;

{ Fixture for tests\LspClientSmoke.dpr - see DemoApp.dpr.

  A DOTTED unit name, and that is the whole point of it. `Demo.Dotted` is ONE
  name whose header is an nkMember chain, and the chain's own first token is
  the DOT - so anything that took the first-token slice of that node reported
  this unit as ".". It reached a user as the pre-filled text of the rename
  dialog (PasTree 0.13.2 fixed it in UnitAt), which is exactly the kind of
  bug a single-segment fixture cannot catch. Section 5d-ter renames it. }

interface

function DottedAnswer: Integer;

implementation

function DottedAnswer: Integer;
begin
  Result := 7;
end;

end.
