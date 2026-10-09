unit DemoClassCompleteGeneric;

{
  Fixture for LspClientSmoke 5s: generic METHODS and default values with
  brackets of their own (AVImark's TStripeService, 2026-10-09).

  Implemented already (must NOT be generated, nor declared a second time):
  the two generic methods of TGenHost. Their declarations carry constraints,
  their bodies do not - the press used to add a second declaration of each
  AND a second body.

  Missing (must be generated): Added; Sets, whose defaults are an open array
  with a comma in it and a plain number - the header must lose both whole,
  not resume at the bracket or the comma; and the method of TBox, whose
  class constraint must not ride into the qualifier.
}

interface

type
  TGenHost = class
  private
    function Fetch<T: class>(const AId: string;
      const AKeys: TArray<string> = []; AStrict: Boolean = True): T;
    function ListOf<T: class, constructor; U>(const AParam: U): T;
  protected
    procedure Added;
    procedure Sets(const A: TArray<Integer> = [1, 2]; B: Integer = 0);
  end;

  TBox<T: class> = class
    procedure Put(const AItem: T);
  end;

implementation

function TGenHost.Fetch<T>(const AId: string; const AKeys: TArray<string>;
  AStrict: Boolean): T;
begin
  Result := nil;
end;

function TGenHost.ListOf<T, U>(const AParam: U): T;
begin
  Result := nil;
end;

end.
