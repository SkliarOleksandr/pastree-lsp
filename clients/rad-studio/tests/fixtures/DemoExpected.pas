unit DemoExpected;

{ Fixture for LspClientSmoke 5b-ter: on the right side of a comparison the
  values of the left side's type rank first, and no procedure is listed. }

interface

type
  TExpColor = (ecRed, ecGreen);
  TExpShape = (esRound, esSquare);

procedure ExpReset;
procedure ExpRun;

implementation

procedure ExpReset;
begin
end;

procedure ExpRun;
var
  LColor: TExpColor;
  LShape: TExpShape;
begin
  LShape := esRound;
  if LColor = ecRed then
    ExpReset;
end;

end.
