unit DemoClassCompleteBase;

{
  Fixture for LspClientSmoke 5p: the ANCESTOR, in a unit of its own, of the
  class DemoClassCompleteForeign completes. One member of each visibility
  that matters from there: a protected field and getter the descendant can
  point at, and a private field it cannot see (private is visible to this
  unit only).
}

interface

type
  TCcBase = class
  private
    FHidden: Integer;
  protected
    FShared: Integer;
    function GetShared: Integer;
  end;

implementation

function TCcBase.GetShared: Integer;
begin
  Result := FShared + FHidden;
end;

end.
