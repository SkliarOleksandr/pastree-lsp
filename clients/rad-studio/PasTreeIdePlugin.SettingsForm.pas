unit PasTreeIdePlugin.SettingsForm;

{
  The settings dialog. Laid out in the FORM DESIGNER - this is the one unit in
  the package with a .dfm, and that is on purpose: it is the only part of the
  plugin whose appearance is a matter of taste rather than of behaviour, so it
  should be adjustable by dragging things around rather than by editing
  coordinates in code.

  IF YOU ARE EDITING THE .dfm: the only names the code depends on are the ones
  bound below (the checkboxes, their hint labels, the readout labels and the
  link). Move them, resize them, restyle them freely; renaming or deleting one breaks the
  build, which is the intended tripwire.

  THEMED THE IDE'S OWN WAY, not styled by hand. IOTAIDEThemingServices does two
  things here that hand-picked colors cannot: RegisterFormClass makes the form
  participate in the IDE's style hooks at all, and ApplyTheme fixes up the
  controls that have no hook of their own (TLabel, TPanel, TBevel - the
  interface documents exactly that list). Without both, this dialog is a bright
  form in a dark IDE. Both calls are optional-by-Supports, so an IDE without
  the service - or with theming switched off - simply gets the unthemed form
  rather than no dialog.

  The version readout is the same pair PasLsp.ProductVersion exists to answer:
  the compiled-in version, and the BINARY's own timestamp, which is the thing
  that says whether the BPL currently loaded is the one just built. See that
  unit's header for why the stamp comes from the file rather than the compiler.
}

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls;

type
  TPasTreeSettingsForm = class(TForm)
    pnlHeader: TPanel;
    lblProduct: TLabel;
    lblVersion: TLabel;
    lblBuilt: TLabel;
    lnkHome: TLinkLabel;
    bvlHeader: TBevel;
    gbOverrides: TGroupBox;
    chkStructureView: TCheckBox;
    lblStructureViewHint: TLabel;
    chkDeclImplToggle: TCheckBox;
    lblDeclImplToggleHint: TLabel;
    chkRename: TCheckBox;
    lblRenameHint: TLabel;
    chkBlockCompletion: TCheckBox;
    lblBlockCompletionHint: TLabel;
    chkClassComplete: TCheckBox;
    lblClassCompleteHint: TLabel;
    gbLogging: TGroupBox;
    chkLogging: TCheckBox;
    lblLoggingHint: TLabel;
    chkAdvancedLogging: TCheckBox;
    lblAdvancedLoggingHint: TLabel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure lnkHomeLinkClick(Sender: TObject; const Link: string;
      LinkType: TSysLinkType);
    procedure chkLoggingClick(Sender: TObject);
  end;

var
  // FOR THE FORM DESIGNER ONLY, and DELIBERATELY NEVER ASSIGNED. The designer
  // expects the variable the New Form wizard would have written, and opening
  // the .dfm is the whole reason this unit has one. Nothing creates into it:
  // ExecuteSettingsDialog owns its instance and frees it, which is what a
  // modal dialog in a designtime package must do - a global form left alive
  // is the flavour of dangling this package unregisters everything else to
  // avoid.
  PasTreeSettingsForm: TPasTreeSettingsForm = nil;

/// <summary>
/// Shows the dialog modally and, on OK, writes the settings back. Returns
/// True if anything was saved - the caller uses that to decide whether to act
/// on a change, so "the user pressed Cancel" and "the user pressed OK" are
/// distinguishable without inspecting the values.
/// </summary>
function ExecuteSettingsDialog: Boolean;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.UITypes,
  Winapi.Windows,
  Winapi.ShellAPI,
  ToolsAPI,
  PasLsp.ProductVersion,
  PasTreeIdePlugin.Settings;

const
  cHomeUrl = 'https://github.com/SkliarOleksandr/pastree-lsp';

procedure TPasTreeSettingsForm.lnkHomeLinkClick(Sender: TObject;
  const Link: string; LinkType: TSysLinkType);
begin
  // The URL comes from the .dfm's own markup, so restyling the link cannot
  // silently change where it goes - and a link with no href does nothing
  // rather than opening a blank browser.
  if Link <> '' then
    ShellExecute(0, 'open', PChar(Link), nil, nil, SW_SHOWNORMAL);
end;

{ "Advanced logging" is meaningless with nothing to write it to, and a tickable
  box that does nothing is worse than a greyed one - it reads as a setting that
  was ignored. Its VALUE is deliberately left alone while it is greyed: turning
  the log off and on again gets the detail choice back rather than silently
  resetting it. }
procedure TPasTreeSettingsForm.chkLoggingClick(Sender: TObject);
begin
  chkAdvancedLogging.Enabled := chkLogging.Checked;
  lblAdvancedLoggingHint.Enabled := chkLogging.Checked;
end;

function ExecuteSettingsDialog: Boolean;
var
  LForm: TPasTreeSettingsForm;
  LTheming: IOTAIDEThemingServices;
  LSettings: TPasTreeSettings;
  LThemed: Boolean;
begin
  Result := False;

  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  // BEFORE the form is constructed: RegisterFormClass installs the style hook
  // on the CLASS, and a form created before its class was registered does not
  // pick one up retroactively. Idempotent, so calling it per invocation is
  // fine and saves a "have we registered yet" flag.
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeSettingsForm);

  // Owned by the IDE's own main form rather than by Application: this is a
  // designtime package, and a top-level VCL form owned by nothing is exactly
  // the thing left dangling at unload.
  LForm := TPasTreeSettingsForm.Create(Application.MainForm);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);

    LForm.lblVersion.Caption := 'Version ' + PasTreeLspVersion;
    // ThisBinaryPath inside a package is the BPL, which is the binary this
    // dialog can honestly report on - the server's own stamp belongs to the
    // server and is in its log.
    LForm.lblBuilt.Caption := 'Built ' + BinaryBuiltOn(ThisBinaryPath);

    LSettings := LoadSettings;
    LForm.chkStructureView.Checked := LSettings.OverrideStructureView;
    LForm.chkDeclImplToggle.Checked := LSettings.OverrideDeclImplToggle;
    LForm.chkRename.Checked := LSettings.EnableRename;
    LForm.chkBlockCompletion.Checked := LSettings.EnableBlockCompletion;
    LForm.chkClassComplete.Checked := LSettings.EnableClassComplete;
    LForm.chkLogging.Checked := LSettings.EnableLogging;
    LForm.chkAdvancedLogging.Checked := LSettings.AdvancedLogging;
    // Assigning Checked only fires OnClick when the value CHANGES, so the
    // dependent state is set here rather than relied upon above.
    LForm.chkLoggingClick(nil);

    if LForm.ShowModal <> mrOk then
      Exit;

    LSettings.OverrideStructureView := LForm.chkStructureView.Checked;
    LSettings.OverrideDeclImplToggle := LForm.chkDeclImplToggle.Checked;
    LSettings.EnableRename := LForm.chkRename.Checked;
    LSettings.EnableBlockCompletion := LForm.chkBlockCompletion.Checked;
    LSettings.EnableClassComplete := LForm.chkClassComplete.Checked;
    LSettings.EnableLogging := LForm.chkLogging.Checked;
    LSettings.AdvancedLogging := LForm.chkAdvancedLogging.Checked;
    SaveSettings(LSettings);
    Result := True;
  finally
    LForm.Free;
  end;
end;

end.
