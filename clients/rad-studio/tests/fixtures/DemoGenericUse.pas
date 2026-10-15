unit DemoGenericUse;

{ Fixture for LspClientSmoke 5b-bis: DemoGenericDetail's generic class through an
  instantiation, completed after `ABox.`. }

interface

uses
  DemoGenericDetail;

procedure UseGdBox(ABox: TGdBox<Integer>);

implementation

procedure UseGdBox(ABox: TGdBox<Integer>);
begin
  ABox.GdArr := nil;
end;

end.
