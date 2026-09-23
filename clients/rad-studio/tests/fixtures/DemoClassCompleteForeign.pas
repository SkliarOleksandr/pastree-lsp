unit DemoClassCompleteForeign;

{
  Fixture for LspClientSmoke 5p: a class whose ANCESTOR lives in another unit
  (DemoClassCompleteBase). The buffer alone cannot see that ancestor, so
  class completion asks the last analysis which accessor names are
  inherited - this unit is in DemoApp.dpr's closure for exactly that.

  Inherited and visible, so nothing is declared: the protected field and the
  protected getter. The base's PRIVATE field is not visible from here, so a
  property reading it gets its own. A name nobody declares gets a field and
  a setter that writes it.
}

interface

uses
  DemoClassCompleteBase;

type
  TCcChild = class(TCcBase)
  public
    property Shared: Integer read FShared;
    property ViaGetter: Integer read GetShared;
    property Hidden: Integer read FHidden;
    property Own: string read FOwn write SetOwn;
  end;

implementation

end.
