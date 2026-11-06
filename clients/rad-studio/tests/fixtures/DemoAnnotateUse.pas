unit DemoAnnotateUse;

(*
  Fixture for LspClientSmoke section 5m: calls whose arguments come from
  DemoAnnotateLib. In the anonymous mode a NAME is its own annotation - an
  enum value and a const of the used unit as much as a variable - and only
  literals get names; a call of nothing but names says why nothing was
  written. A constructor and a method of the used unit's class, each one of
  two overloads of the same arity, take the names of the overload the
  project analysis chose - the one Go To Definition lands on.
*)

interface

procedure RunAnnotateDemo;

implementation

uses
  DemoAnnotateLib;

procedure RunAnnotateDemo;
var
  S: string;
  LSheet: TDemoSheet;
begin
  Paint(dcRed, cDemoLimit, S);
  Paint(dcBlue, 3, 'x');
  Echo(S);
  LSheet := TDemoSheet.CreateFor(S, 2);
  LSheet.Show(S, True);
  LSheet.Free;
end;

end.
