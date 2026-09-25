unit DemoUseUnit;

{ Fixture for tests\LspClientSmoke.dpr, section 5n: Use Unit. The interface
  clause names one unit with its prefix and one without, so "already used"
  must see through a unit-scope prefix both ways. There is no
  implementation clause, so adding to that section writes a new one. }

interface

uses
  System.SysUtils, Classes;

type
  TUseUnitThing = Integer;

implementation

end.
