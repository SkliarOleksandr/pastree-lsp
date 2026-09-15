unit PasTreeIdePlugin.AnnotateArgsForm;

(*
  The "Annotate Arguments" dialog - what to write into the call under the
  caret, asked once per command (Alex, 2026-09-14: "a modal form with the
  annotation settings"). The SECOND form in this package with a .dfm, for the
  same reason as the first: the layout is the designer's business, and every
  control below is named so the code can find it after any restyling - rename
  or delete one and the build breaks, which is the intended tripwire.

  THREE CHOICES, matching PasLsp.AnnotateArgs' options one to one:

  - the scope radio: every argument / only the anonymous ones (a literal, an
    expression, a call - not an identifier that names itself) / only the
    argument at the caret. A fourth, "no names", keeps only the marks and
    the layout below - for a call that already has its names. The last is ENABLED only when the caret was in the
    argument list when the menu opened - on the routine's name there is no
    "current" argument - and the dialog opens with it selected in that case,
    with "all" selected otherwise: the caret's reading is the default, the
    dialog is where it is overridden;
  - `{var}` / `{out}` marks for by-reference parameters;
  - one argument per line - a layout choice about the whole call.

  THE LAST CHOICES ARE REMEMBERED for the session, so the second call is two
  clicks (open, OK). Not in the registry: these are per-call preferences, and
  what suits a five-argument constructor does not suit `Inc(X, 2)`. The scope
  radio is remembered too, except that "current" cannot be pre-selected when
  the caret is on the name.

  THEMED THE IDE'S OWN WAY - RegisterFormClass before construction, ApplyTheme
  after - exactly as PasTreeIdePlugin.SettingsForm does and for the reasons
  written there.
*)

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  PasTreeIdePlugin.LspSession;

type
  TPasTreeAnnotateArgsForm = class(TForm)
    grpScope: TGroupBox;
    rbAll: TRadioButton;
    rbAnonymous: TRadioButton;
    rbCurrent: TRadioButton;
    rbNone: TRadioButton;
    chkByRef: TCheckBox;
    chkOneArgPerLine: TCheckBox;
    btnOK: TButton;
    btnCancel: TButton;
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeAnnotateArgsForm: TPasTreeAnnotateArgsForm = nil;

/// <summary>
/// Shows the dialog modally. ACurrentAvailable says whether the caret was in
/// the argument list (the "current argument" choice is enabled and
/// preselected only then). On OK fills AOptions and returns True; False on
/// Cancel, AOptions untouched.
/// </summary>
function ExecuteAnnotateArgsDialog(ACurrentAvailable: Boolean;
  out AOptions: TLspAnnotateOptions): Boolean;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.UITypes,
  ToolsAPI;

var
  // The session memory - see the header. Starts as the server's own
  // defaults (auto scope, marks on, layout untouched).
  GLast: TLspAnnotateOptions = (Mode: ''; MarkByRef: True;
    OneArgPerLine: False);

function ExecuteAnnotateArgsDialog(ACurrentAvailable: Boolean;
  out AOptions: TLspAnnotateOptions): Boolean;
var
  LForm: TPasTreeAnnotateArgsForm;
  LTheming: IOTAIDEThemingServices;
  LThemed: Boolean;
begin
  Result := False;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeAnnotateArgsForm);
  LForm := TPasTreeAnnotateArgsForm.Create(Application.MainForm);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);

    LForm.rbCurrent.Enabled := ACurrentAvailable;
    // The caret's own reading first; the remembered scope only when it can
    // still apply (a remembered "current" with the caret on the name cannot).
    if ACurrentAvailable and ((GLast.Mode = '') or (GLast.Mode = 'current')) then
      LForm.rbCurrent.Checked := True
    else if GLast.Mode = 'anonymous' then
      LForm.rbAnonymous.Checked := True
    else if GLast.Mode = 'none' then
      LForm.rbNone.Checked := True
    else
      LForm.rbAll.Checked := True;
    LForm.chkByRef.Checked := GLast.MarkByRef;
    LForm.chkOneArgPerLine.Checked := GLast.OneArgPerLine;

    if LForm.ShowModal <> mrOk then
      Exit;

    if LForm.rbCurrent.Checked then
      AOptions.Mode := 'current'
    else if LForm.rbAnonymous.Checked then
      AOptions.Mode := 'anonymous'
    else if LForm.rbNone.Checked then
      AOptions.Mode := 'none'
    else
      AOptions.Mode := 'all';
    AOptions.MarkByRef := LForm.chkByRef.Checked;
    AOptions.OneArgPerLine := LForm.chkOneArgPerLine.Checked;
    GLast := AOptions;
    Result := True;
  finally
    LForm.Free;
  end;
end;

end.
