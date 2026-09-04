program DemoApp;

{ Fixture for tests\LspClientSmoke.dpr - small enough to analyze instantly and
  to reason about by eye. The `in 'DemoUnit.pas'` spelling is deliberate: a
  program's uses item is exactly the position where SymbolAt claims the name as
  an ordinary symbol and finds no references, which is why both this plugin and
  the LSP server test UnitAt first. }

{$APPTYPE CONSOLE}

uses
  DemoUnit in 'DemoUnit.pas',
  DemoUnicode in 'DemoUnicode.pas',
  Demo.Dotted in 'Demo.Dotted.pas',
  DemoInherited in 'DemoInherited.pas';

var
  LDerived: TDerived;

begin
  Writeln(Greet('world'));
  Writeln(Greet('again'));
  Writeln(Shout('quiet'));
  Writeln(DottedAnswer);
  LDerived := TDerived.Create;
  Writeln(LDerived.Greet('bare inherited'));
  LDerived.Free;
end.
