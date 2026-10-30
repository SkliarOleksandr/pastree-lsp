unit DemoClassCompleteFreeDecl;

{
  Fixture for LspClientSmoke 5t: a FREE routine implemented and declared
  nowhere - class completion with the caret in its body writes the
  declaration into the interface section, after the last routine declared
  there. A forward-declared helper is declared already; a routine whose
  declaration has other parameters is a signature edit, and is refused.
}

interface

type
  TThing = class
  end;

procedure Declared(A: Integer);
procedure Changed(A: Integer);

implementation

procedure Helper; forward;

procedure Declared(A: Integer);
begin
end;

procedure Changed(A: string);
begin
end;

procedure Helper;
begin
end;

function Undeclared(const A: Integer; B: string): string; inline;
begin
  Result := B;
end;

end.
