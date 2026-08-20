unit DemoUnicode;

{ Fixture for the position-encoding check in tests\LspClientSmoke.dpr.

  The point is the Cyrillic literal that sits BEFORE an identifier on the same
  line, in Shout below. LSP counts columns in UTF-16 code units; the IDE counts
  1-based columns; PasTree counts 1-based columns into a Delphi string. If any
  link in that chain counted UTF-8 BYTES instead, a position after this literal
  would be off by the number of extra bytes it takes - 13 characters of
  Cyrillic are 26 bytes - and the request would land inside the string literal
  rather than on Wrap.

  Deliberately no non-ASCII IDENTIFIERS: whether PasTree accepts those is its
  own question, and a failure there would be indistinguishable from the column
  bug this fixture exists to catch. }

interface

function Wrap(const AText: string): string;
function Shout(const AText: string): string;

implementation

function Wrap(const AText: string): string;
begin
  Result := '[' + AText + ']';
end;

function Shout(const AText: string): string;
begin
  Result := 'Привет, мир! ' + Wrap(AText);
end;

end.
