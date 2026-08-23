unit DemoClassCompleteBroken;

{
  Fixture for LspClientSmoke 5g: a file no semicolon can rescue - the class
  has no `end` and the unit no `end.`. Class completion must REFUSE and say
  so, because a generator working from a guessed tree is how 1339 lines of
  wrong code got written on 2026-08-23.
}

interface

type
  TBroken = class
    procedure Never;
