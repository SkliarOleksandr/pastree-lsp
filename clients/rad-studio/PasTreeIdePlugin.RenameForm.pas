unit PasTreeIdePlugin.RenameForm;

(*
  The "Rename" dialog - the new name, and beneath it the same project check
  list PasTreeIdePlugin.GroupScopeForm shows on its own, so that a rename
  inside a group is ONE dialog and not a name prompt followed by a scope
  prompt (Alex, 2026-09-22). Outside a group - one project open, or a group
  of one - the project list and its caption are hidden and the form shrinks
  to the prompt and the edit, which is what the IDE's own InputQuery used to
  show here.

  LAID OUT EXACTLY AS THE SCOPE DIALOG - a plain label above the list, the
  same bounds for every control - so the two read as one dialog in two uses.
  The list sat in a TGroupBox at first, and under the IDE's theme the box
  drew its caption larger than the labels (clipped at the right edge) and
  inset the list, so Rename looked narrower than Find All (Alex, 2026-09-22).
  Keep the two .dfm files in step.

  Until 0.50.x the prompt was INTAIDEUIServices.InputQuery, chosen over
  Vcl.Dialogs.InputQuery because the VCL one came up light inside the dark
  theme (user, 2026-08-31). This form is themed the way the other .dfm forms
  of the package are - RegisterFormClass before construction, ApplyTheme
  after (see PasTreeIdePlugin.SettingsForm) - so it stays dark where the IDE
  is dark. The rows, the greyed owner and the registry memory of the ticks
  are PasTreeIdePlugin.GroupScope's; this unit is the .dfm and the wiring.

  Every control is named so the code can find it after any restyling in the
  designer; rename or delete one and the build breaks, which is the intended
  tripwire.
*)

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.CheckLst,
  PasTreeIdePlugin.GroupScope;

type
  TPasTreeRenameForm = class(TForm)
    lblPrompt: TLabel;
    edtName: TEdit;
    lblProjects: TLabel;
    clbProjects: TCheckListBox;
    btnOK: TButton;
    btnCancel: TButton;
  private
    procedure FormShow(ASender: TObject);
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeRenameForm: TPasTreeRenameForm = nil;

/// <summary>
/// Asks for the new name of AOldName and, when the group has more than one
/// project, which other projects to plan the rename across (AProjects from
/// GroupScopeProjects; nil hides the project list). On OK returns True with
/// the trimmed new name in ANewName and the ticked .dproj paths, the owner
/// included, in ASelected - and remembers the ticks. False on Cancel.
/// </summary>
function ExecuteRenameDialog(const AOldName: string;
  var AProjects: TGroupScopeProjects; out ANewName: string;
  out ASelected: TArray<string>): Boolean;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.UITypes,
  ToolsAPI;

procedure TPasTreeRenameForm.FormShow(ASender: TObject);
begin
  if clbProjects.Visible then
    SelectGroupScopeOwner(clbProjects);
end;

function ExecuteRenameDialog(const AOldName: string;
  var AProjects: TGroupScopeProjects; out ANewName: string;
  out ASelected: TArray<string>): Boolean;
var
  LForm: TPasTreeRenameForm;
  LTheming: IOTAIDEThemingServices;
  LThemed: Boolean;
  LShift: Integer;
begin
  Result := False;
  ANewName := '';
  ASelected := nil;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeRenameForm);
  LForm := TPasTreeRenameForm.Create(Application.MainForm);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);
    LForm.lblPrompt.Caption := Format('Rename "%s" to:', [AOldName]);
    LForm.edtName.Text := AOldName;
    LForm.edtName.SelectAll;
    LForm.ActiveControl := LForm.edtName;

    if AProjects = nil then
    begin
      // No group to choose from: the list and its caption go, and the buttons
      // and the form close up over the gap they leave - the buttons ending
      // as far below the edit as they stood below the list. Measured from
      // the layout rather than hard-coded, so a change in the designer moves
      // with it.
      LShift := LForm.clbProjects.BoundsRect.Bottom - LForm.edtName.BoundsRect.Bottom;
      LForm.lblProjects.Visible := False;
      LForm.clbProjects.Visible := False;
      LForm.btnOK.Top := LForm.btnOK.Top - LShift;
      LForm.btnCancel.Top := LForm.btnCancel.Top - LShift;
      LForm.ClientHeight := LForm.ClientHeight - LShift;
    end
    else
    begin
      FillGroupScopeList(LForm.clbProjects, AProjects);
      // Check All / Uncheck All on the list's right-click, as in the scope
      // dialog - buttons for the same cost a row of the form.
      AttachGroupScopeMenu(LForm.clbProjects);
      LForm.OnShow := LForm.FormShow;
    end;

    if LForm.ShowModal <> mrOk then
      Exit;
    ANewName := Trim(LForm.edtName.Text);
    if AProjects <> nil then
      ASelected := ReadGroupScopeList(LForm.clbProjects, AProjects);
    Result := True;
  finally
    LForm.Free;
  end;
end;

end.
