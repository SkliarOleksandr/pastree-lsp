unit PasTreeIdePlugin.GroupScopeForm;

(*
  The scope dialog - which projects of the group a Find References or Find
  All command asks, shown before the request goes out whenever the group has
  more than one project (Alex, 2026-09-22: starting every server of a big
  group ran the machine out of memory). Its caption is the COMMAND ("Find All
  References", "Find All Overrides"), and the edit above the list shows the
  identifier under the caret, so the dialog says what is about to be
  searched and where. The edit is disabled, not merely read-only - asked for
  by Alex on 2026-09-22. The rows, the greyed owner (selected on show, so it
  is in view whatever the group's size) and the registry memory are
  PasTreeIdePlugin.GroupScope's; this unit is the .dfm and the list's popup
  menu (Check All / Uncheck All - buttons for the same took a row of the
  form; Alex, 2026-09-22).

  THEMED THE IDE'S OWN WAY - RegisterFormClass before construction, ApplyTheme
  after - exactly as PasTreeIdePlugin.SettingsForm does and for the reasons
  written there. Every control is named so the code can find it after any
  restyling in the designer; rename or delete one and the build breaks, which
  is the intended tripwire.
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
  TPasTreeGroupScopeForm = class(TForm)
    lblSubject: TLabel;
    edtSubject: TEdit;
    lblPrompt: TLabel;
    clbProjects: TCheckListBox;
    btnOK: TButton;
    btnCancel: TButton;
  private
    procedure FormShow(ASender: TObject);
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeGroupScopeForm: TPasTreeGroupScopeForm = nil;

/// <summary>
/// Shows the dialog modally over AProjects (from GroupScopeProjects), with
/// ACaption as its title and ASubject in the disabled edit. On OK remembers
/// the ticks and returns True with the ticked .dproj paths, the owner
/// included; False on Cancel, ASelected nil.
/// </summary>
function ExecuteGroupScopeDialog(var AProjects: TGroupScopeProjects;
  const ACaption, ASubject: string; out ASelected: TArray<string>): Boolean;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.UITypes,
  ToolsAPI;

procedure TPasTreeGroupScopeForm.FormShow(ASender: TObject);
begin
  // Once the list has its window: selection scrolls, the bar can be nudged.
  SelectGroupScopeOwner(clbProjects);
end;

function ExecuteGroupScopeDialog(var AProjects: TGroupScopeProjects;
  const ACaption, ASubject: string; out ASelected: TArray<string>): Boolean;
var
  LForm: TPasTreeGroupScopeForm;
  LTheming: IOTAIDEThemingServices;
  LThemed: Boolean;
begin
  Result := False;
  ASelected := nil;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeGroupScopeForm);
  LForm := TPasTreeGroupScopeForm.Create(Application.MainForm);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);
    LForm.Caption := ACaption;
    LForm.edtSubject.Text := ASubject;
    FillGroupScopeList(LForm.clbProjects, AProjects);
    AttachGroupScopeMenu(LForm.clbProjects);
    LForm.ActiveControl := LForm.clbProjects;
    LForm.OnShow := LForm.FormShow;
    if LForm.ShowModal <> mrOk then
      Exit;
    ASelected := ReadGroupScopeList(LForm.clbProjects, AProjects);
    Result := True;
  finally
    LForm.Free;
  end;
end;

end.
