unit DemoFindAll;

{ Fixture for the Find All family in tests\LspClientSmoke.dpr -
  pastree/findDescendants, findAssignments, findCreations, findDestructions,
  the interface-name half of findImplementations, and the findAllAt gate.

  A three-level class hierarchy with an unrelated class beside it; an
  interface, an interface extending it, and two classes implementing one
  each; a global, a field, a writable property and a read-only one, a for
  counter; two creations of one class and one of its descendant, freed three
  different ways. Positions are found by text in the test, so the shape
  matters and the line numbers do not. FreeAndNil, Create, Destroy and Free
  are the unit's own: the harness closure has no RTL, not even System. }

interface

uses
  DemoHierarchy;

type
  // Its own Create, Destroy and Free: the fixture closure has no System.pas,
  // so TObject's never resolve here - the same shape PasTree's own NavCD
  // fixture uses. Find Creations wants a RESOLVED constructor, Find
  // Destructions a resolved routine named Free or Destroy.
  TAnimal = class
    FName: string;
    FLegs: Integer;
    constructor Create;
    destructor Destroy;
    procedure Free;
    procedure SetName(const AValue: string);
    property Name: string read FName write SetName;
    // Read-only: nothing assigns it, so Find Assignments must decline it.
    property Legs: Integer read FLegs;
  end;

  TDog = class(TAnimal)
  end;

  TCat = class(TAnimal)
  end;

  TPuppy = class(TDog)
  end;

  // An abstract class, a class over an ancestor from ANOTHER unit, and a
  // class over a type ALIAS of its ancestor (VirtualTrees: `TVTBaseAncestor
  // = TVTBaseAncestorVcl;` then `class abstract(TVTBaseAncestor)`): the
  // shapes the findAllAt gate is checked on beside the plain one.
  TAbstractPet = class abstract(TAnimal)
  end;

  TFarShape = class(TShape)
  end;

  TAnimalAlias = TAnimal;

  TAliasedDog = class abstract(TAnimalAlias)
  end;

  // No common ancestor with TAnimal: never a descendant row.
  TStone = class
  end;

  IShape = interface
    ['{7A0C2D1E-4B5F-4E6A-9C8D-1F2E3D4C5B6A}']
    procedure Draw;
  end;

  // Extends IShape: a DESCENDANT of the interface (Find Descendants' row),
  // not an implementor.
  IRoundShape = interface(IShape)
    ['{7A0C2D1E-4B5F-4E6A-9C8D-1F2E3D4C5B6B}']
  end;

  // Lists IRoundShape only: an implementor row of IRoundShape, NOT of IShape
  // (PasTree 0.25.0 - the interfaces below IShape are Find Descendants').
  TCircle = class(TInterfacedObject, IRoundShape)
    procedure Draw;
  end;

  TBox = class(TInterfacedObject, IShape)
    procedure Draw;
  end;

const
  cLimit = 3;

var
  GCounter: Integer;

procedure Run;
procedure FreeAndNil(var AObj);

implementation

procedure FreeAndNil(var AObj);
var
  LTemp: TObject;
begin
  LTemp := TObject(AObj);
  Pointer(AObj) := nil;
  LTemp.Free;
end;

constructor TAnimal.Create;
begin
end;

destructor TAnimal.Destroy;
begin
end;

procedure TAnimal.Free;
begin
end;

procedure TAnimal.SetName(const AValue: string);
begin
  FName := AValue;
end;

procedure TCircle.Draw;
begin
end;

procedure TBox.Draw;
begin
end;

procedure Run;
var
  LDog: TDog;
  LPuppy: TPuppy;
  LAnimal: TAnimal;
  I: Integer;
begin
  GCounter := 0;
  for I := 1 to cLimit do
    GCounter := GCounter + I;
  LDog := TDog.Create;
  LDog.Name := 'Rex';
  LDog.FLegs := 4;
  LDog.Free;
  LPuppy := TPuppy.Create;
  FreeAndNil(LPuppy);
  LDog := TDog.Create;
  LDog.Destroy;
  // A creation through the type ALIAS: a TAnimal, found from TAnimal.
  LAnimal := TAnimalAlias.Create;
  LAnimal.Free;
end;

end.
