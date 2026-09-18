unit DemoDcu;

{ Fixture for tests\LspClientSmoke.dpr, section 2d: the importer of a unit
  that exists only compiled (tests\dcusrc\DemoDcuLib.pas, built by build.bat
  into fixtures\dcu32). Definition from here must land in the .dcu, and
  pastree/dcuSource must hand back the text those lines belong to. }

interface

uses
  DemoDcuLib;

function UseTheDcu: string;

implementation

function UseTheDcu: string;
var
  LThing: TDcuThing;
begin
  LThing := TDcuThing.Create;
  try
    LThing.Bump;
    Result := DcuGreeting('x');
    if LThing.Count > DcuLimit then
      Result := '';
  finally
    LThing.Free;
  end;
end;

end.
