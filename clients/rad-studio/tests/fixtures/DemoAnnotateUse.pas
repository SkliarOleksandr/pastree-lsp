unit DemoAnnotateUse;

(*
  Fixture for LspClientSmoke section 5m: calls whose arguments come from
  DemoAnnotateLib. In the anonymous mode a NAME is its own annotation - an
  enum value and a const of the used unit as much as a variable - and only
  literals get names; a call of nothing but names says why nothing was
  written.
*)

interface

procedure RunAnnotateDemo;

implementation

uses
  DemoAnnotateLib;

procedure RunAnnotateDemo;
var
  S: string;
begin
  Paint(dcRed, cDemoLimit, S);
  Paint(dcBlue, 3, 'x');
  Echo(S);
end;

end.
