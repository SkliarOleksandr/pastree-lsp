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

  HOW. The first bytes of TControl.DefineProperties inside the IDE's vcl*.bpl
  are overwritten with a jump to DefinePropertiesNoExplicit below: the same
  method with every Explicit* HasData argument False, the ancestor case
  included (Alex, 2026-09-29 - an inherited form must not write them either).
  The same approach as bero/DControlsFix, with two things that code does not
  do on Win64 done here:

  - THE JUMP. Win32 uses the 5-byte E9 rel32. Win64 cannot: rel32 reaches
    only 2 GB, and nothing places this BPL within 2 GB of vcl*.bpl - an
    offset that does not fit would be truncated silently and the next form
    save would jump into garbage. So Win64 writes the 14-byte absolute form,
    FF 25 00000000 followed by the 8-byte target address.

  - THE ADDRESS. Taken from TControl's virtual method table (TargetAddress),
    which holds the real code address inside vcl*.bpl. `@TControl.
    DefineProperties` in a package is an import thunk instead, and
    DControlsFix's thunk decoder reads the Win32 form (FF 25 abs32) - on
    Win64 the operand is RIP-relative and that decoder yields garbage.

  NOTHING OF THE ORIGINAL IS EVER CALLED WHILE PATCHED, which is what keeps
  this simple: no trampoline, no relocating the instructions the jump
  overwrites. The bytes are saved and put back by RemovePatch.

  NO CHECK FOR SOMEONE ELSE'S PATCH (Alex, 2026-09-29): with DDevExtensions or
  DControlsFix loaded as well, ours simply overwrites theirs - they do the same
  thing. The one check kept is that the address lies in the module TControl
  lives in; anything else means the lookup went wrong, and writing there would
  be a crash of our own making.

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
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  ToolsAPI;

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

const
{$IFDEF CPUX64}
  cPatchSize = 14;   // FF 25 00000000 + 8-byte absolute address
{$ELSE}
  cPatchSize = 5;    // E9 + rel32
{$ENDIF}

type
  TPatchBytes = array[0..cPatchSize - 1] of Byte;

var
  GTarget: Pointer = nil;
  GSaved: TPatchBytes;
  GActive: Boolean = False;

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

function ReplacementAddress: Pointer;
begin
  Result := @TControlNoExplicit.DefinePropertiesNoExplicit;
end;

function WriteCode(ATarget: Pointer; const ABytes: TPatchBytes): Boolean;
var
  LOld, LIgnored: DWORD;
begin
  Result := VirtualProtect(ATarget, cPatchSize, PAGE_EXECUTE_READWRITE, LOld);
  if not Result then
    Exit;
  Move(ABytes, ATarget^, cPatchSize);
  VirtualProtect(ATarget, cPatchSize, LOld, LIgnored);
  FlushInstructionCache(GetCurrentProcess, ATarget, cPatchSize);
end;

function JumpBytes(AFrom, ATo: Pointer): TPatchBytes;
{$IFDEF CPUX64}
var
  LAddress: UInt64;
begin
  Result[0] := $FF;
  Result[1] := $25;
  PCardinal(@Result[2])^ := 0;   // [rip+0]: the address right after
  LAddress := UInt64(ATo);
  Move(LAddress, Result[6], SizeOf(LAddress));
end;
{$ELSE}
begin
  Result[0] := $E9;
  PInteger(@Result[1])^ := Integer(NativeInt(ATo) - NativeInt(AFrom)
    - cPatchSize);
end;
{$ENDIF}

procedure InstallPatch;
var
  LTarget: Pointer;
begin
  LTarget := TargetAddress;
  // The one sanity check - see the unit header.
  if (LTarget = nil)
    or (FindHInstance(LTarget) <> FindHInstance(Pointer(TControl))) then
  begin
    LogDiagnostic('Explicit* fix not applied: TControl.DefineProperties was '
      + 'not found in the module TControl lives in.');
    Exit;
  end;
  Move(LTarget^, GSaved, cPatchSize);
  if not WriteCode(LTarget, JumpBytes(LTarget, ReplacementAddress)) then
  begin
    LogDiagnostic('Explicit* fix not applied: VirtualProtect failed ('
      + SysErrorMessage(GetLastError) + ').');
    Exit;
  end;
  GTarget := LTarget;
  GActive := True;
end;

procedure RemovePatch;
begin
  if not GActive then
    Exit;
  if not WriteCode(GTarget, GSaved) then
    LogDiagnostic('Explicit* fix could not be removed: VirtualProtect failed ('
      + SysErrorMessage(GetLastError) + ').');
  // Considered gone either way: a failed restore leaves the jump pointing at
  // this package, which is still loaded, and a second try would fail alike.
  GActive := False;
  GTarget := nil;
end;

procedure SetDfmExplicitFix(AEnabled: Boolean);
begin
  if AEnabled = GActive then
    Exit;
  try
    if AEnabled then
      InstallPatch
    else
      RemovePatch;
  except
    on E: Exception do
      LogDiagnostic('Explicit* fix: ' + E.ClassName + ': ' + E.Message);
  end;
end;

function DfmExplicitFixActive: Boolean;
begin
  Result := GActive;
end;

initialization

finalization
  // Before the BPL unloads, whatever the wizard's teardown did or did not
  // reach: the jump points into this package.
  RemovePatch;

end.
