unit DemoClassCompleteFields;

{
  Fixture for LspClientSmoke 5n: where class completion puts FIELDS, and the
  body placement next to existing bodies. Not in DemoApp.dpr's closure - a
  parse of one buffer.

  A field after a method in one section is E2169, so new fields go after the
  section's LEADING run of fields, not at its end. A class var block in that
  run makes everything after it class-side, so a new INSTANCE field goes
  ahead of the block and a new class var after it (TFields). An EMPTY private
  section is used as it is rather than a second one being written
  (TEmptyPrivate).

  A bare property is completed the way the native command completes it:
  read through a new field, write through a setter that assigns it. A class
  property's field is a class var and its setter a class static method; an
  indexed property takes methods both ways, since no field has an index.
  A class var that already exists is not declared again.

  Bodies, alphabetically: the indexed getter sorts ahead of the one existing
  body, and must land ABOVE the comment that documents that body.
}

interface

type
  TFields = class
  private
    FFirst: Integer;
    class var FCounter: Integer;
    procedure Helper;
  public
    property Name: string;
    class property Total: Integer;
    property Items[Index: Integer]: string;
    property Counter: Integer read FCounter;
  end;

  TEmptyPrivate = class
  private
  public
    property Size: Integer;
  end;

implementation

// Documents the one existing body - it stays attached to it.
procedure TFields.Helper;
begin
end;

end.
