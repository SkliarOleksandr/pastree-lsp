unit DemoForm;

{ Fixture for the form-file checks of tests\LspClientSmoke.dpr: a form class
  whose component and handler its form file names. The project has no VCL on
  its path and needs none - a form file binds to the form class's own
  published members. }

interface

type
  TDemoForm = class
    GoButton: TObject;
    procedure GoButtonClick(Sender: TObject);
  end;

implementation

{$R *.dfm}

procedure TDemoForm.GoButtonClick(Sender: TObject);
begin
  if GoButton = nil then
    GoButtonClick(Sender);
end;

end.
