unit DemoClassCompleteSemi;

{
  Fixture for LspClientSmoke 5g: the ONE repair class completion makes to a
  buffer it cannot parse. `property XX: Integer` has no terminating `;` yet -
  the shape the key is pressed on - and an unterminated property swallows the
  rest of the class, so generating from that tree produces nonsense. The `;`
  is written as an edit, the file is parsed again, and only the clean tree is
  used.
}

interface

type
  TSemi = class
  private
    FA: Integer;
  public
    procedure Done;
    property XX: Integer
  end;

implementation

procedure TSemi.Done;
begin
end;

end.
