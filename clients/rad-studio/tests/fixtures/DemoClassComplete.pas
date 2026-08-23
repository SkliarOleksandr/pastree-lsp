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
    { A DEFAULT VALUE, twice over. Implemented below WITHOUT the default (as
      Delphi requires - E2226 says defaults live in the interface only), so
      matching must ignore it: the first live run keyed the two differently
      and generated a duplicate body. }
    function Defaulted(A: Integer; const S: string = ''): Integer;
    { And one that IS missing, so the generated header can be checked for the
      default having been stripped out of it. }
    procedure NeedsBody(A: Integer = 7);
  end;

  TStack<T> = class
    procedure Push(const AItem: T);
  end;

  { Property accessors - the second half of class completion. Rule: a
    specifier name starting with Get/Set is a METHOD, anything else is a
    FIELD. }
  TProps = class
  private
    FKnown: Integer;
    function GetKnown: Integer;
  public
    { Both accessors exist: nothing to generate for this one. }
    property Known: Integer read GetKnown write FKnown;
    { Neither exists: a getter and a setter, declared and implemented. }
    property Missing: string read GetMissing write SetMissing;
    { Not Get/Set-shaped, so a FIELD - no body for this one. }
    property Backed: Integer read FBacked;
    { Indexed: the index parameters ride into both accessors, the setter's
      value last. }
    property Items[Index: Integer]: string read GetItem write SetItem;
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

function TBase.Defaulted(A: Integer; const S: string): Integer;
begin
  Result := A;
end;

function TProps.GetKnown: Integer;
begin
  Result := FKnown;
end;

end.
