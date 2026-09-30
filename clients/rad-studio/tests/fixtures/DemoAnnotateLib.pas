unit DemoAnnotateLib;

(*
  Fixture for LspClientSmoke section 5m, with DemoAnnotateUse: the enum, the
  const and the routines a call in ANOTHER unit passes them to. In
  DemoApp.dpr's closure on purpose: the anonymous mode must leave a named
  constant alone even where the project could tell it is a constant.
*)

interface

type
  TDemoColor = (dcRed, dcBlue);

const
  cDemoLimit = 7;

procedure Paint(AColor: TDemoColor; ALimit: Integer; const AName: string);
procedure Echo(const AText: string);

implementation

procedure Paint(AColor: TDemoColor; ALimit: Integer; const AName: string);
begin
end;

procedure Echo(const AText: string);
begin
end;

end.
