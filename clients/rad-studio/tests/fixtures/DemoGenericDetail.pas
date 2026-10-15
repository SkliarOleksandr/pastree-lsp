unit DemoGenericDetail;

{ Fixture for LspClientSmoke 5b-bis: what a completion row says after the name of
  a generic class's member, inside the class and through an instantiation
  (DemoGenericUse). The closure has no System.Generics.Collections, so the
  generics are the fixture's own: a list and a comparer interface the class
  takes arguments of, and a type nested in it (2026-10-15: inside the class
  these rows were bare or lost their arguments; through `TGdBox<Integer>` the
  nested type read `TGdArr<Integer>` and the parameters kept `TVal`). }

interface

type
  TGdList<TElem> = class
    Elems: array of TElem;
  end;

  TGdComparer<TCmp> = interface
    function Compare(const ALeft, ARight: TCmp): Integer;
  end;

  TGdBox<TVal> = class
  public type
    TGdArr = array of TVal;
  public
    GdCmp: TGdComparer<TVal>;
    GdList: TGdList<TVal>;
    GdArr: TGdArr;
    function GdPut(const AValue: TVal; AList: TGdList<TVal>): TGdList<TVal>;
    procedure GdProbe;
  end;

implementation

function TGdBox<TVal>.GdPut(const AValue: TVal;
  AList: TGdList<TVal>): TGdList<TVal>;
begin
  Result := AList;
end;

procedure TGdBox<TVal>.GdProbe;
begin
  Self.GdArr := nil;
end;

end.
