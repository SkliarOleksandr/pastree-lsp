unit DemoClassComplete;

{
  Fixture for LspClientSmoke section 5f - one declaration per rule class
  completion has to follow. NOT part of DemoApp.dpr's closure on purpose:
  pastree/classComplete is a parse of one buffer, and a fixture that needs no
  project proves it.

  Implemented already (must NOT be generated again): TBase.Done, the
  parameterless TBase.Overloaded.
  Never implementable here (must NOT be generated): IWorker.Work (an
  interface's methods belong to its implementors), TBase.Abstracted.
  Missing (must ALL be generated): TBase.Missing, TBase.Make with its
  `static` repeated, the one-argument TBase.Overloaded, TStack<T>.Push with
  its generic qualification, and FreeRoutine - a free routine of the
  interface section, which the native class completion ignores and this one
  does not.
}

interface

type
  IWorker = interface
    procedure Work;
  end;

  TBase = class
  public
    procedure Done;
    procedure Missing(const A: string; B: Integer);
    procedure Abstracted; virtual; abstract;
    class function Make: TBase; static;
    function Overloaded: Integer; overload;
    function Overloaded(A: Integer): Integer; overload;
  end;

  TStack<T> = class
    procedure Push(const AItem: T);
  end;

procedure FreeRoutine(AValue: Integer);

implementation

procedure TBase.Done;
begin
end;

function TBase.Overloaded: Integer;
begin
  Result := 0;
end;

end.
