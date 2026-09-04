unit DemoInherited;

{ Fixture for the bare `inherited` (no name following) check in
  tests\LspClientSmoke.dpr.

  A BARE `inherited` with no name following has no identifier token for
  IdentAt to land on - the parser gives it no nkIdent child at all - so it
  needs its own path (PasTree.Sema.Nav.GotoBareInherited) rather than the
  ordinary IdentAt + ResolveDecl one that already handles a NAMED
  `inherited Greet`. Both forms are covered here: TDerived.Greet calls the
  bare form, TOther.Greet the named one, both meaning the same override. }

interface

type
  TBase = class
    function Greet(const AName: string): string; virtual;
    // Two overloads, so a bare `inherited` in TDerived.Init(A, B) has to
    // pick by arity - the chain head is the one-argument one.
    procedure Init(A: Integer); overload; virtual;
    procedure Init(A, B: Integer); overload; virtual;
  end;

  TDerived = class(TBase)
    function Greet(const AName: string): string; override;
    procedure Init(A, B: Integer); overload; override;
  end;

  TOther = class(TBase)
    function Greet(const AName: string): string; override;
  end;

implementation

function TBase.Greet(const AName: string): string;
begin
  Result := 'Hello, ' + AName;
end;

procedure TBase.Init(A: Integer);
begin
  Init(A, 0);
end;

procedure TBase.Init(A, B: Integer);
begin
  Assert(A + B >= 0);
end;

function TDerived.Greet(const AName: string): string;
begin
  inherited;
  Result := 'Derived: ' + AName;
end;

procedure TDerived.Init(A, B: Integer);
begin
  inherited;   // the two-argument TBase.Init, not the chain head
end;

function TOther.Greet(const AName: string): string;
begin
  Result := inherited Greet(AName) + '!';
end;

end.
