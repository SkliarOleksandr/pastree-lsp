program XmlDocDemo;

{
  The VS Code XMLDoc demo's root. A .dpr, not a .dproj: the server takes
  either as its analysis root (initializationOptions.projectFile), and a .dpr
  needs no MSBuild evaluation to be read - which keeps this demo openable with
  nothing but the checked-in files and the paths in .vscode\settings.json.
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  XmlDocDemo.Samples in 'XmlDocDemo.Samples.pas';

var
  GGreeter: TGreeter;
  GName2: TPersonName;

begin
  // Hover any of these, and complete after 'GGreeter.' - the documentation
  // rides with every completion row, not just with the hover.
  GName2.First := 'Ada';
  GName2.Last := 'Lovelace';
  GGreeter := TGreeter.Create(gsFormal);
  try
    Writeln(GGreeter.Greet(GName2, True));
    Writeln(CAnswer, ' ', EscapesAndOddities);
    UntaggedDoc;
    DocAboveAnAttribute;
    ThisIsNotDocumented;
  finally
    GGreeter.Free;
  end;
end.
