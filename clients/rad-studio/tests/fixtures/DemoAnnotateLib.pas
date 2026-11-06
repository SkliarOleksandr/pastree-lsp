unit DemoAnnotateLib;

(*
  Fixture for LspClientSmoke section 5m, with DemoAnnotateUse: the enum, the
  const and the routines a call in ANOTHER unit passes them to. In
  DemoApp.dpr's closure on purpose: the anonymous mode must leave a named
  constant alone even where the project could tell it is a constant.
  The class's two pairs of overloads take as many arguments as each other,
  so only the argument TYPES pick one: a call from the other unit is bound by
  the project analysis alone, never by the overlay of the calling unit.
*)

interface

type
  TDemoColor = (dcRed, dcBlue);

  TDemoSheet = class
  public
    constructor CreateFor(const ADoctor: string; ASite: Byte = 0); overload;
    constructor CreateFor(AOwner: TObject; ASite: Byte = 0); overload;
    procedure Show(const ATitle: string; AWide: Boolean); overload;
    procedure Show(AOwner: TObject; AWide: Boolean); overload;
  end;

const
  cDemoLimit = 7;

procedure Paint(AColor: TDemoColor; ALimit: Integer; const AName: string);
procedure Echo(const AText: string);

implementation

constructor TDemoSheet.CreateFor(const ADoctor: string; ASite: Byte);
begin
end;

constructor TDemoSheet.CreateFor(AOwner: TObject; ASite: Byte);
begin
end;

procedure TDemoSheet.Show(const ATitle: string; AWide: Boolean);
begin
end;

procedure TDemoSheet.Show(AOwner: TObject; AWide: Boolean);
begin
end;

procedure Paint(AColor: TDemoColor; ALimit: Integer; const AName: string);
begin
end;

procedure Echo(const AText: string);
begin
end;

end.
