unit DemoMissingUnit;

{ Fixture for LspClientSmoke's section 4e (the range of a missing dotted
  unit). It uses ONE unit that exists nowhere, on purpose, and a dotted one:
  the diagnostic anchors on the dotted name's node, whose first token is the
  dot. Do not fix it, and keep it out of the other fixtures - a missing unit
  switches off the undeclared-identifier checks of the unit that uses it. }

interface

uses
  System.NoSuchUnit2;

implementation

end.
