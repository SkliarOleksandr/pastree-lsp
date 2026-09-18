unit DemoDcuLib;

{ Fixture for tests\LspClientSmoke.dpr, section 2d - a unit the server sees
  ONLY as a .dcu. build.bat compiles this file with the IDE's dcc32 into
  tests\fixtures\dcu32\ (ignored, *.dcu), and that directory is a search
  path of the harness's session while THIS directory is not, so every
  answer about the names below comes from the interface text PasTree
  generates out of the compiled unit. Keep the declarations plain: the
  checks look for their names in the generated text, not for their shape. }

interface

type
  TDcuThing = class
  private
    FCount: Integer;
  public
    procedure Bump;
    property Count: Integer read FCount;
  end;

const
  DcuLimit = 42;

function DcuGreeting(const AName: string): string;

implementation

procedure TDcuThing.Bump;
begin
  Inc(FCount);
end;

function DcuGreeting(const AName: string): string;
begin
  Result := 'dcu ' + AName;
end;

end.
