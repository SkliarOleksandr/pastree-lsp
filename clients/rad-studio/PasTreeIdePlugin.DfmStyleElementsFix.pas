unit PasTreeIdePlugin.DfmStyleElementsFix;

{
  IDE FIX: AN INHERITED FORM OR A FRAME NO LONGER GETS
  `StyleElements = [seFont, seClient, seBorder]` WRITTEN INTO ITS FORM FILE
  WHEN NOBODY CHANGED IT.

  THE BUG (23.0 and 37.0; 22.0 read the field directly and does not have it).
  TControl.GetStyleElements, in the designer and with a VCL style active,
  answers FStyleElements MINUS what the designer excludes from styling
  (IDesignerHook.GetExcludedStyleElements) - except for a control being
  written, which has csWriting and gets the real value. For a plain form that
  is enough: the value is compared with the property's default and equals it.
  An inherited form or a frame is compared with its ANCESTOR instead
  (System.Classes, IsDefaultPropertyValue: GetOrdProp(Ancestor, ...)), and the
  ancestor is not being written - its getter answers the reduced set, the
  default differs from it, and the default is written.

  HOW. Two methods are replaced (PasTreeIdePlugin.CodePatch has the
  mechanism), both or neither:

  - TWriter.WriteProperties (rtl*.bpl), which TWriter calls for every object it
    writes. The copy is the original's body - unchanged in 23.0 and 37.0, and
    nothing in it private - counting the depth of writes in progress on this
    thread (GWriteDepth).

  - TControl.GetStyleElements (vcl*.bpl). While a write is in progress on the
    calling thread it answers the real value for every control, the ancestor
    included, so the comparison is value against value. Otherwise it is the
    original, so what the designer paints does not change. Its address comes
    from TControl's virtual method table, WriteProperties' (a static method)
    from following the import thunk.

  A threadvar rather than a global, so that a write on another thread - if the
  IDE ever does one - leaves the main thread's painting alone.

  A value somebody really set is still written: only the comparison is fixed.

  The setting (PasTreeIdePlugin.Settings.DfmNoDefaultStyleElements) applies
  and removes both at once through SetDfmStyleElementsFix; the finalization
  section removes them before the BPL unloads. A new RAD Studio version that
  changes either method needs its copy here compared again.
}

interface

/// <summary>
/// Installs (True) or removes (False) both patches. Idempotent; called at
/// package load with the stored setting and again after the settings dialog
/// saves. A failure is one line in the Build tab and leaves the IDE as it was.
/// </summary>
procedure SetDfmStyleElementsFix(AEnabled: Boolean);

/// <summary>Whether the patches are in place right now.</summary>
function DfmStyleElementsFixActive: Boolean;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.TypInfo,
  Vcl.Controls,
  Vcl.Forms,
  ToolsAPI,
  PasTreeIdePlugin.CodePatch;

type
  // Protected access; never instantiated - the replacements run with Self
  // being the real writer and the real control, reached through the jumps.
  TWriterCounted = class(TWriter)
  public
    procedure WritePropertiesCounted(const Instance: TPersistent);
  end;

  TPersistentAccess = class(TPersistent);

  TControlStyleFix = class(TControl)
  public
    function GetStyleElementsFixed: TStyleElements;
  end;

threadvar
  GWriteDepth: Integer;

var
  GWritePatch: TCodePatch;
  GStylePatch: TCodePatch;

{ TWriterCounted }

procedure TWriterCounted.WritePropertiesCounted(const Instance: TPersistent);
var
  I, Count: Integer;
  PropInfo: PPropInfo;
  PropList: PPropList;
begin
  Inc(GWriteDepth);
  try
    // TWriter.WriteProperties, verbatim.
    Count := GetTypeData(Instance.ClassInfo)^.PropCount;
    if Count > 0 then
    begin
      GetMem(PropList, Count * SizeOf(Pointer));
      try
        GetPropInfos(Instance.ClassInfo, PropList);
        for I := 0 to Count - 1 do
        begin
          PropInfo := PropList^[I];
          if PropInfo = nil then
            Break;
          if IsStoredProp(Instance, PropInfo) then
            WriteProperty(Instance, PropInfo);
        end;
      finally
        FreeMem(PropList, Count * SizeOf(Pointer));
      end;
    end;
    TPersistentAccess(Instance).DefineProperties(Self);
  finally
    Dec(GWriteDepth);
  end;
end;

{ TControlStyleFix }

function TControlStyleFix.GetStyleElementsFixed: TStyleElements;
var
  LForm: TCustomForm;
  LDesigner: IDesignerHook;
begin
  // The fix: during a write, the real value - see the unit header.
  if GWriteDepth > 0 then
    Exit(GetInternalStyleElements);
  // TControl.GetStyleElements, with its GetDesignerForControl (implementation
  // section of Vcl.Controls) inlined.
  if not (csReadingProps in ControlState) and (csDesigning in ComponentState)
    and not (csWriting in ComponentState) and IsCustomStyleActive then
  begin
    LForm := GetParentForm(Self);
    if Assigned(LForm) then
    begin
      LDesigner := LForm.Designer;
      if Assigned(LDesigner) then
        Exit(GetInternalStyleElements
          - LDesigner.GetExcludedStyleElements(Self));
    end;
  end;
  Result := GetInternalStyleElements;
end;

{ The Build tab, tagged like every other line this package puts there. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ TControl.GetStyleElements from TControl's virtual method table - the
  "fake instance" of PasTreeIdePlugin.DfmExplicitFix.TargetAddress. }
function GetStyleElementsAddress: Pointer;
type
  TGetStyleElements = function: TStyleElements of object;
var
  LFakeInstance: Pointer;
  LMethod: TGetStyleElements;
begin
  LFakeInstance := Pointer(TControl);
  LMethod := TControlStyleFix(Pointer(@LFakeInstance)).GetStyleElements;
  Result := TMethod(LMethod).Code;
end;

procedure Remove;
var
  LError: string;
begin
  // The getter first: it is the one that reads the counter.
  if not GStylePatch.Remove(LError) then
    LogDiagnostic('StyleElements fix could not be removed: '
      + 'TControl.GetStyleElements - ' + LError + '.');
  if not GWritePatch.Remove(LError) then
    LogDiagnostic('StyleElements fix could not be removed: '
      + 'TWriter.WriteProperties - ' + LError + '.');
end;

procedure Install;
var
  LError: string;
begin
  // The counter first, so the getter never runs without it.
  if not GWritePatch.Install(ResolveImportThunk(@TWriter.WriteProperties),
    @TWriterCounted.WritePropertiesCounted, TWriter, LError) then
  begin
    LogDiagnostic('StyleElements fix not applied: TWriter.WriteProperties - '
      + LError + '.');
    Exit;
  end;
  if not GStylePatch.Install(GetStyleElementsAddress,
    @TControlStyleFix.GetStyleElementsFixed, TControl, LError) then
  begin
    LogDiagnostic('StyleElements fix not applied: TControl.GetStyleElements - '
      + LError + '.');
    Remove;
  end;
end;

procedure SetDfmStyleElementsFix(AEnabled: Boolean);
begin
  if AEnabled = DfmStyleElementsFixActive then
    Exit;
  try
    if AEnabled then
      Install
    else
      Remove;
  except
    on E: Exception do
      LogDiagnostic('StyleElements fix: ' + E.ClassName + ': ' + E.Message);
  end;
end;

function DfmStyleElementsFixActive: Boolean;
begin
  Result := GWritePatch.Active and GStylePatch.Active;
end;

var
  GIgnored: string;

initialization

finalization
  // Before the BPL unloads: both jumps point into this package. Not Remove -
  // the Build tab may already be gone.
  GStylePatch.Remove(GIgnored);
  GWritePatch.Remove(GIgnored);

end.
