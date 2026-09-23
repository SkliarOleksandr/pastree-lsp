unit DemoClassCompleteFieldOnly;

{
  Fixture for LspClientSmoke 5q: a press whose ONLY edit is a field - no
  body, no orphan. The caret must go to the new field's name; "no caret" was
  read by the client as the unit's first line (Alex, 2026-09-23).
}

interface

type
  TFieldOnly = class
  private
    FA: Integer;
  public
    property Wanted: Integer read FWanted;
  end;

implementation

end.
