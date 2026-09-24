unit DemoDiagnostics;

{ Fixture for LspClientSmoke's section 4d (diagnostics on open). It carries ONE
  genuine error ON DISK, on purpose: a member after a dot that the class does
  not have - the shape PasTree reports only with ReportUnresolvedMembers on.
  Do not fix it; the section checks the error arrives. }

interface

type
  TDiagBox = class
    Value: Integer;
  end;

procedure TouchBox(ABox: TDiagBox);

implementation

procedure TouchBox(ABox: TDiagBox);
begin
  ABox.Valeu := 1;
end;

end.
