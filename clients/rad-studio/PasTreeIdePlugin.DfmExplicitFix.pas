unit PasTreeIdePlugin.DfmExplicitFix;

{
  IDE FIX: THE FORM DESIGNER NO LONGER WRITES ExplicitLeft / ExplicitTop /
  ExplicitWidth / ExplicitHeight INTO A FORM FILE.

  WHAT THEY ARE. A control's own bounds from before Align or Anchors stretched
  it, kept so that setting Align back to alNone restores them. The VCL writes
  them from TControl.DefineProperties whenever the control is aligned or
  anchored and the kept value differs from the current one - and, in an
  inherited form or a frame, whenever it differs from the ancestor's. The
  aligned bounds depend on the parent's size, which depends on the DPI, the
  monitor and the scaling the form was opened under, so the values move on
  every open-and-save and a form file's diff fills with them.

  HOW. TControl.DefineProperties inside the IDE's vcl*.bpl is replaced
  (PasTreeIdePlugin.CodePatch has the mechanism and its Win64 details) by
  DefinePropertiesNoExplicit below: the same method with every Explicit*
  HasData argument False, the ancestor case included (Alex, 2026-09-29 - an
  inherited form must not write them either). Its address is taken from
  TControl's virtual method table (TargetAddress).

  READING IS UNTOUCHED. The Explicit* properties are still DEFINED, with
  readers, because a form file that has them must still load - an undefined
  property is "Property ExplicitLeft does not exist". What a file already
  holds is read as before and simply not written back, so the lines disappear
  the first time each form is saved.

  WHOLE PROCESS, WHILE ENABLED. Every TControl the IDE streams goes through
  the patch - form files, frames, the designer's clipboard - and that is the
  point. The setting (PasTreeIdePlugin.Settings.DfmNoExplicitProperties)
  applies and removes it at once through SetDfmExplicitFix; the finalization
  section removes it before the BPL unloads, since a jump into unloaded code
  is a crash on the next form save.

  THE REPLACEMENT MIRRORS Vcl.Controls, identical in 22.0, 23.0 and 37.0:
  IsControl first, then the four Explicit* definitions, and NO inherited call
  (the original omits it on purpose - Left and Top are real properties). A new
  RAD Studio version that changes TControl.DefineProperties needs this body
  compared again.
}

interface

/// <summary>
/// Installs (True) or removes (False) the patch. Idempotent; called at
/// package load with the stored setting and again after the settings dialog
/// saves. A failure is one line in the Build tab and leaves the IDE as it was.
/// </summary>
procedure SetDfmExplicitFix(AEnabled: Boolean);

/// <summary>Whether the patch is in place right now.</summary>
function DfmExplicitFixActive: Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  ToolsAPI,
  PasTreeIdePlugin.CodePatch;

type
  // Protected access to TControl's fields and IsControl. Never instantiated:
  // DefinePropertiesNoExplicit runs with Self being whatever control the
  // filer is streaming, reached through the jump.
  TControlNoExplicit = class(TControl)
  private
    procedure ReadIsControl(Reader: TReader);
    procedure WriteIsControl(Writer: TWriter);
    procedure ReadExplicitLeft(Reader: TReader);
    procedure ReadExplicitTop(Reader: TReader);
    procedure ReadExplicitWidth(Reader: TReader);
    procedure ReadExplicitHeight(Reader: TReader);
  public
    procedure DefinePropertiesNoExplicit(Filer: TFiler);
  end;

var
  GPatch: TCodePatch;

{ TControlNoExplicit }

procedure TControlNoExplicit.ReadIsControl(Reader: TReader);
begin
  IsControl := Reader.ReadBoolean;
end;

procedure TControlNoExplicit.WriteIsControl(Writer: TWriter);
begin
  Writer.WriteBoolean(IsControl);
end;

procedure TControlNoExplicit.ReadExplicitLeft(Reader: TReader);
begin
  FExplicitLeft := Reader.ReadInteger;
end;

procedure TControlNoExplicit.ReadExplicitTop(Reader: TReader);
begin
  FExplicitTop := Reader.ReadInteger;
end;

procedure TControlNoExplicit.ReadExplicitWidth(Reader: TReader);
begin
  FExplicitWidth := Reader.ReadInteger;
end;

procedure TControlNoExplicit.ReadExplicitHeight(Reader: TReader);
begin
  FExplicitHeight := Reader.ReadInteger;
end;

procedure TControlNoExplicit.DefinePropertiesNoExplicit(Filer: TFiler);

  function DoWriteIsControl: Boolean;
  begin
    if Filer.Ancestor <> nil then
      Result := TControlNoExplicit(Filer.Ancestor).IsControl <> IsControl
    else
      Result := IsControl;
  end;

begin
  // No inherited - see the unit header. The Explicit* writers are nil: with
  // HasData False TWriter never calls them, and a reader is all a property
  // needs to load.
  Filer.DefineProperty('IsControl', ReadIsControl, WriteIsControl,
    DoWriteIsControl);
  Filer.DefineProperty('ExplicitLeft', ReadExplicitLeft, nil, False);
  Filer.DefineProperty('ExplicitTop', ReadExplicitTop, nil, False);
  Filer.DefineProperty('ExplicitWidth', ReadExplicitWidth, nil, False);
  Filer.DefineProperty('ExplicitHeight', ReadExplicitHeight, nil, False);
end;

{ The Build tab, tagged like every other line this package puts there. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ TControl.DefineProperties as TControl's own virtual method table holds it.
  A method pointer to a virtual method is formed by reading the instance's
  class pointer and then the slot, so a "fake instance" - one pointer-sized
  variable holding the class - yields the slot without constructing
  anything, and on either platform. }
function TargetAddress: Pointer;
type
  TDefineProperties = procedure(Filer: TFiler) of object;
var
  LFakeInstance: Pointer;
  LMethod: TDefineProperties;
begin
  LFakeInstance := Pointer(TControl);
  LMethod := TControlNoExplicit(Pointer(@LFakeInstance)).DefineProperties;
  Result := TMethod(LMethod).Code;
end;

procedure SetDfmExplicitFix(AEnabled: Boolean);
var
  LError: string;
begin
  if AEnabled = GPatch.Active then
    Exit;
  try
    if AEnabled then
    begin
      if not GPatch.Install(TargetAddress,
        @TControlNoExplicit.DefinePropertiesNoExplicit, TControl, LError) then
        LogDiagnostic('Explicit* fix not applied: TControl.DefineProperties - '
          + LError + '.');
    end
    else if not GPatch.Remove(LError) then
      LogDiagnostic('Explicit* fix could not be removed: ' + LError + '.');
  except
    on E: Exception do
      LogDiagnostic('Explicit* fix: ' + E.ClassName + ': ' + E.Message);
  end;
end;

function DfmExplicitFixActive: Boolean;
begin
  Result := GPatch.Active;
end;

var
  GIgnored: string;

initialization

finalization
  // Before the BPL unloads, whatever the wizard's teardown did or did not
  // reach: the jump points into this package.
  GPatch.Remove(GIgnored);

end.
