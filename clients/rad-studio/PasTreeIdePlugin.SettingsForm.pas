unit PasTreeIdePlugin.SettingsForm;

{
  The settings dialog. Laid out in the FORM DESIGNER - this is the one unit in
  the package with a .dfm, and that is on purpose: it is the only part of the
  plugin whose appearance is a matter of taste rather than of behaviour, so it
  should be adjustable by dragging things around rather than by editing
  coordinates in code.

  NO SWITCH FOR THE STRUCTURE PANE OUTLINE (0.76.3): it is part of PasTree
  being the Insight Provider - with PasTree selected nothing else fills the
  pane, with RAD Studio selected DelphiLSP does - so the Code Insight Manager
  choice is its switch (PasTreeIdePlugin.Outline).

  THREE TABS SINCE 0.33.0 - Navigation (what a click or a key resolves to),
  Editing (what changes code), Diagnostics (the log) - because seven switches
  in two group boxes had become a column that no longer fit the screen at the
  IDE's default DPI. A switch goes on the tab that answers "what does this
  turn off": a feature that EDITS the user's code is Editing regardless of
  how it is triggered. Code Insight holds what replaces one of the IDE's own
  insight features - Tooltip symbol insight and, since 0.63.4, Errors Insight
  (moved there from Highlighting: it is a choice between the IDE's Error
  Insight and ours, not a colour) - and, since 0.68.0, the experimental Code
  Insight Manager choice (PasTreeIdePlugin.CodeInsight). Highlighting came later, and IDE Fixes (0.59.0) holds
  what corrects the IDE's own behaviour rather than adding a feature - first
  the form designer's Explicit* properties (PasTreeIdePlugin.DfmExplicitFix),
  then the unchanged StyleElements of inherited forms (0.60.0,
  PasTreeIdePlugin.DfmStyleElementsFix). Performance (0.67.0) holds the
  analysis thread count and the Benchmark box - the one place the dialog
  talks to a server (LspBenchmark), because comparing thread counts is only
  useful with the figures next to the choice.

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
  System.UITypes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls;

type
  TPasTreeSettingsForm = class(TForm)
    pnlHeader: TPanel;
    imgLogo: TImage;
    lblProduct: TLabel;
    lblVersion: TLabel;
    lbPasTreeVersion: TLabel;
    lblBuilt: TLabel;
    lnkHome: TLinkLabel;
    lnkHomePasTree: TLinkLabel;
    lnkHomeObjPasSpec: TLinkLabel;
    bvlHeader: TBevel;
    pgcSettings: TPageControl;
    tsNavigation: TTabSheet;
    tsEditing: TTabSheet;
    tsCodeInsight: TTabSheet;
    tsDiagnostics: TTabSheet;
    chkCtrlClick: TCheckBox;
    lblCtrlClickHint: TLabel;
    chkDeclImplToggle: TCheckBox;
    lblDeclImplToggleHint: TLabel;
    chkFindAll: TCheckBox;
    lblFindAllHint: TLabel;
    chkFindRefsImplHeaders: TCheckBox;
    chkGoTo: TCheckBox;
    lblGoToHint: TLabel;
    chkUnitDialogs: TCheckBox;
    lblUnitDialogsHint: TLabel;
    chkRename: TCheckBox;
    lblRenameHint: TLabel;
    chkBlockCompletion: TCheckBox;
    lblBlockCompletionHint: TLabel;
    chkTooltipSymbolInsight: TCheckBox;
    lblTooltipSymbolInsightHint: TLabel;
    lblErrorSquiggles: TLabel;
    cbxErrorSquiggles: TComboBox;
    lblErrorSquigglesHint: TLabel;
    chkNativeErrorInsight: TCheckBox;
    lblInsightManager: TLabel;
    cbxInsightManager: TComboBox;
    lblInsightManagerHint: TLabel;
    chkCompletionBoldNames: TCheckBox;
    chkClassComplete: TCheckBox;
    lblClassCompleteHint: TLabel;
    lblClassCompleteOrder: TLabel;
    cbxClassCompleteOrder: TComboBox;
    chkLogging: TCheckBox;
    lblLoggingHint: TLabel;
    chkAdvancedLogging: TCheckBox;
    lblAdvancedLoggingHint: TLabel;
    chkClearLogOnOpen: TCheckBox;
    lblClearLogOnOpenHint: TLabel;
    chkLogAllIdeCrashes: TCheckBox;
    lblLogAllIdeCrashesHint: TLabel;
    tsHighlighting: TTabSheet;
    chkHighlightTypes: TCheckBox;
    lblTypeColor: TLabel;
    cbxTypeColor: TColorBox;
    chkTypeBold: TCheckBox;
    chkTypeItalic: TCheckBox;
    chkTypeUnderline: TCheckBox;
    lblPreview: TLabel;
    pbxPreview: TPaintBox;
    chkHighlightInactive: TCheckBox;
    lblHighlightInactiveHint: TLabel;
    tsIdeFixes: TTabSheet;
    chkNoExplicitProps: TCheckBox;
    lblNoExplicitPropsHint: TLabel;
    chkNoDefaultStyleElements: TCheckBox;
    lblNoDefaultStyleElementsHint: TLabel;
    tsPerformance: TTabSheet;
    lblThreads: TLabel;
    cbxThreads: TComboBox;
    lblThreadsHint: TLabel;
    lblParseMode: TLabel;
    cbxParseMode: TComboBox;
    lblLightHint: TLabel;
    grpBenchmark: TGroupBox;
    lblBenchmarkHint: TLabel;
    btnAnalyze: TButton;
    lblBenchmarkStatus: TLabel;
    tmrBenchmark: TTimer;
    btnOK: TButton;
    btnCancel: TButton;
    procedure btnAnalyzeClick(Sender: TObject);
    procedure tmrBenchmarkTimer(Sender: TObject);
    procedure lnkHomeLinkClick(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure chkLoggingClick(Sender: TObject);
    procedure chkClassCompleteClick(Sender: TObject);
    procedure chkFindAllClick(Sender: TObject);
    procedure chkHighlightTypesClick(Sender: TObject);
    procedure TypeStyleChanged(Sender: TObject);
    procedure pbxPreviewPaint(Sender: TObject);
    procedure cbxInsightManagerChange(Sender: TObject);
  private
    // The Errors Insight choice the user made, kept while PasTree as the
    // Code Insight Manager forces it - see cbxInsightManagerChange.
    FErrorSquigglesOwn: Boolean;
    FErrorSquigglesHint: string;
    // cbxThreads' values, parallel to its items: 0 = Auto, else a count.
    FThreadChoices: TArray<Integer>;
    FBenchmarkStart: UInt64;
    function TypeStyles: TFontStyles;
    procedure FillThreads(ACurrent: Integer);
    function SelectedThreads: Integer;
    procedure BenchmarkFinished(AOk: Boolean; const AText: string);
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
  System.Math,
  Winapi.Windows,
  Winapi.ShellAPI,
  Vcl.Graphics,
  Vcl.Themes,
  ToolsAPI,
  PasLsp.ProductVersion,
  PasTreeIdePlugin.LspSession,
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
  chkClearLogOnOpen.Enabled := chkLogging.Checked;
  lblClearLogOnOpenHint.Enabled := chkLogging.Checked;
end;

{ The body order means nothing when Ctrl+Shift+C is the IDE's own - greyed
  for chkLoggingClick's reason, its value kept for the same one. }
procedure TPasTreeSettingsForm.chkClassCompleteClick(Sender: TObject);
begin
  lblClassCompleteOrder.Enabled := chkClassComplete.Checked;
  cbxClassCompleteOrder.Enabled := chkClassComplete.Checked;
end;

{ PASTREE AS THE CODE INSIGHT MANAGER FORCES PASTREE'S UNDERLINES: the IDE's
  Error Insight takes its errors from the selected provider alone (SPEC.md,
  the 2026-10-20 spike), so beside PasTree it underlines nothing. The Errors
  Insight choice then shows PasTree, greyed, with the reason in its hint
  line; the user's own choice is kept and comes back with RAD Studio. }
procedure TPasTreeSettingsForm.cbxInsightManagerChange(Sender: TObject);
var
  LForced: Boolean;
begin
  LForced := cbxInsightManager.ItemIndex = 1;
  if FErrorSquigglesHint = '' then
    FErrorSquigglesHint := lblErrorSquigglesHint.Caption;
  // Leaving the editable state: what it showed is the user's choice.
  if LForced and cbxErrorSquiggles.Enabled then
    FErrorSquigglesOwn := cbxErrorSquiggles.ItemIndex = 1;
  lblErrorSquiggles.Enabled := not LForced;
  cbxErrorSquiggles.Enabled := not LForced;
  if LForced then
  begin
    cbxErrorSquiggles.ItemIndex := 1;
    lblErrorSquigglesHint.Caption := 'PasTree draws them while it is the'
      + ' Code Insight Manager: the IDE''s Error Insight takes its errors'
      + ' from DelphiLSP alone, and beside PasTree it underlines nothing.';
  end
  else
  begin
    cbxErrorSquiggles.ItemIndex := Ord(FErrorSquigglesOwn);
    lblErrorSquigglesHint.Caption := FErrorSquigglesHint;
  end;
  // Our list's option, so greyed with RAD Studio's list - value kept.
  chkCompletionBoldNames.Enabled := LForced;
  // Fed only while PasTree is the provider - greyed otherwise, value kept.
  chkNativeErrorInsight.Enabled := LForced;
end;

{ Find References lives in the Find All submenu and nowhere else, so its
  option is greyed with it - for chkLoggingClick's reason, value kept. }
procedure TPasTreeSettingsForm.chkFindAllClick(Sender: TObject);
begin
  chkFindRefsImplHeaders.Enabled := chkFindAll.Checked;
end;

procedure TPasTreeSettingsForm.chkHighlightTypesClick(Sender: TObject);
begin
  lblTypeColor.Enabled := chkHighlightTypes.Checked;
  cbxTypeColor.Enabled := chkHighlightTypes.Checked;
  chkTypeBold.Enabled := chkHighlightTypes.Checked;
  chkTypeItalic.Enabled := chkHighlightTypes.Checked;
  chkTypeUnderline.Enabled := chkHighlightTypes.Checked;
  lblPreview.Enabled := chkHighlightTypes.Checked;
  pbxPreview.Invalidate;
end;

procedure TPasTreeSettingsForm.TypeStyleChanged(Sender: TObject);
begin
  pbxPreview.Invalidate;
end;

function TPasTreeSettingsForm.TypeStyles: TFontStyles;
begin
  Result := [];
  if chkTypeBold.Checked then
    Include(Result, fsBold);
  if chkTypeItalic.Checked then
    Include(Result, fsItalic);
  if chkTypeUnderline.Checked then
    Include(Result, fsUnderline);
end;

{ One declaration in the editor's font, the type names in the chosen colour
  and style, the rest in the window text colour - what the editor will show
  after OK. Themed through StyleServices, as the rest of the form is. }
procedure TPasTreeSettingsForm.pbxPreviewPaint(Sender: TObject);
var
  LCanvas: TCanvas;
  LX, LY: Integer;
  LPlain: TColor;

  procedure Put(const AText: string; AType: Boolean);
  begin
    if AType and chkHighlightTypes.Checked then
    begin
      LCanvas.Font.Color := cbxTypeColor.Selected;
      LCanvas.Font.Style := TypeStyles;
    end
    else
    begin
      LCanvas.Font.Color := LPlain;
      LCanvas.Font.Style := [];
    end;
    LCanvas.TextOut(LX, LY, AText);
    Inc(LX, LCanvas.TextWidth(AText));
  end;

begin
  LCanvas := pbxPreview.Canvas;
  LCanvas.Brush.Color := StyleServices.GetSystemColor(clWindow);
  LCanvas.FillRect(pbxPreview.ClientRect);
  LPlain := StyleServices.GetSystemColor(clWindowText);
  LCanvas.Font.Name := 'Consolas';
  LCanvas.Font.Size := 10;
  LCanvas.Brush.Style := bsClear;
  LX := 8;
  LY := (pbxPreview.Height - LCanvas.TextHeight('Tg')) div 2;
  Put('FItems: ', False);
  Put('TList', True);
  Put('<', False);
  Put('TItem', True);
  Put('>; Count: ', False);
  Put('Integer', True);
  Put(';', False);
  LCanvas.Brush.Style := bsSolid;
end;

{ Auto, then 1, 2, 4, 8 ... below the logical core count, then the count
  itself. 1 is not a pool width - PasTree's pool is never below 2 - but its
  SingleThreaded mode, every stage on one thread (the server's
  ApplyInitOptions). A stored value not in the list - set on a machine with
  more cores - is kept as its own item rather than lost. }
procedure TPasTreeSettingsForm.FillThreads(ACurrent: Integer);
var
  LCores, LCount, LIndex: Integer;

  procedure Add(AValue: Integer; const AText: string);
  begin
    cbxThreads.Items.Add(AText);
    FThreadChoices := FThreadChoices + [AValue];
  end;

begin
  LCores := CPUCount;
  cbxThreads.Items.Clear;
  FThreadChoices := nil;
  Add(0, Format('Auto (%d threads)', [Max(2, LCores)]));
  Add(1, '1 thread');
  LCount := 2;
  while LCount < LCores do
  begin
    Add(LCount, Format('%d threads', [LCount]));
    LCount := LCount * 2;
  end;
  if LCores >= 2 then
    Add(LCores, Format('%d threads (all cores)', [LCores]));
  cbxThreads.ItemIndex := -1;
  for LIndex := 0 to High(FThreadChoices) do
    if FThreadChoices[LIndex] = ACurrent then
      cbxThreads.ItemIndex := LIndex;
  if cbxThreads.ItemIndex < 0 then
  begin
    Add(ACurrent, Format('%d threads', [ACurrent]));
    cbxThreads.ItemIndex := High(FThreadChoices);
  end;
end;

function TPasTreeSettingsForm.SelectedThreads: Integer;
begin
  if (cbxThreads.ItemIndex >= 0) and
     (cbxThreads.ItemIndex <= High(FThreadChoices)) then
    Result := FThreadChoices[cbxThreads.ItemIndex]
  else
    Result := 0;
end;

{ The benchmark result's parsing mode: Fast with the number of library units
  it analyzed interface-only, or Full - which a Fast run with no library
  trees (no library paths) is as well. }
function ParseModeText(const AResult: TLspBenchmarkResult): string;
begin
  if AResult.LightUnits > 0 then
    Result := Format('Fast mode (%d library units interface-only)',
      [AResult.LightUnits])
  else
    Result := 'Full mode';
end;

{ A full analysis of the active project from nothing (pastree/benchmark), on
  the count and parsing mode selected NOW - saved or not, so they can be
  compared without closing the dialog; LspEndBenchmark, when the dialog
  closes, puts the settings back in charge. The timer shows the server's progress; the figures
  come from the server when the run finalizes. }
procedure TPasTreeSettingsForm.btnAnalyzeClick(Sender: TObject);
var
  LForm: TPasTreeSettingsForm;
begin
  LForm := Self;
  FBenchmarkStart := GetTickCount64;
  btnAnalyze.Enabled := False;
  cbxThreads.Enabled := False;
  cbxParseMode.Enabled := False;
  lblBenchmarkStatus.Caption := 'Starting...';
  if not LspBenchmark(SelectedThreads, cbxParseMode.ItemIndex <> 1,
    procedure(const AResult: TLspBenchmarkResult)
    begin
      if not AResult.Ok then
        LForm.BenchmarkFinished(False, 'Failed: ' + AResult.Error)
      else
        LForm.BenchmarkFinished(True, Format(
          '%d units in %s s on %s, %s.'#13#10
          + 'Memory: %d MB at peak, %d MB held after (server process;'
          + ' %d MB before the run).',
          [AResult.Units,
           FormatFloat('0.0', AResult.Ms / 1000),
           ThreadsText(AResult.Threads), ParseModeText(AResult),
           AResult.CommitPeakMB, AResult.CommitAfterMB,
           AResult.CommitBeforeMB]));
    end) then
  begin
    BenchmarkFinished(False,
      'No project to analyze - open one, or check the Messages window.');
    Exit;
  end;
  tmrBenchmark.Enabled := True;
end;

procedure TPasTreeSettingsForm.tmrBenchmarkTimer(Sender: TObject);
var
  LText: string;
  LRunningMs: UInt64;
  LElapsed: string;
begin
  LElapsed := FormatFloat('0.0', (GetTickCount64 - FBenchmarkStart) / 1000)
    + ' s';
  if not LspBenchmarkStatus(LText, LRunningMs) then
  begin
    // Starting is a phase; stopped or failed is the end - the server that
    // would have reported is gone.
    if LText = 'starting the server' then
      lblBenchmarkStatus.Caption := 'Starting the server... ' + LElapsed
    else
      BenchmarkFinished(False, 'Stopped: ' + LText);
    Exit;
  end;
  if LText = '' then
    LText := 'analyzing';
  lblBenchmarkStatus.Caption := Format('Analyzing: %s, %s', [LText, LElapsed]);
end;

procedure TPasTreeSettingsForm.BenchmarkFinished(AOk: Boolean;
  const AText: string);
begin
  tmrBenchmark.Enabled := False;
  btnAnalyze.Enabled := True;
  cbxThreads.Enabled := True;
  cbxParseMode.Enabled := True;
  lblBenchmarkStatus.Caption := AText;
end;

function ExecuteSettingsDialog: Boolean;
var
  LForm: TPasTreeSettingsForm;
  LTheming: IOTAIDEThemingServices;
  LSettings: TPasTreeSettings;
  LThemed: Boolean;
  LPasTreeVersion: string;
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

    // LOADED FROM THE RESOURCE RATHER THAN STORED IN THE .dfm, which is what
    // dropping a TImage in the Form Designer would have done: the same bitmap
    // is already linked for the splash screen, and a second copy inside the
    // .dfm is a copy that can be updated on its own and then disagree. This
    // way there is one image in the package and no way to change only half of
    // it. Transparent uses the bitmap's bottom-left pixel, the same convention
    // the splash screen reads - see PasTreeIdePlugin.Logo.rc.
    try
      LForm.imgLogo.Picture.Bitmap.LoadFromResourceName(HInstance, 'PASTREE_LOGO');
      LForm.imgLogo.Transparent := True;
    except
      // Decoration. A dialog that refuses to open because its logo is missing
      // would be a worse bug than the missing logo.
      LForm.imgLogo.Visible := False;
    end;

    LForm.lblVersion.Caption := 'Version ' + PasTreeLspVersion;
    // ThisBinaryPath inside a package is the BPL, which is the binary this
    // dialog can honestly report on - the server's own stamp belongs to the
    // server and is in its log.
    LForm.lblBuilt.Caption := 'Built ' + BinaryBuiltOn(ThisBinaryPath);
    // PasTree is linked into the server, not into this package, so the
    // server says which one - a running one, else the exe on disk.
    LPasTreeVersion := LspPasTreeVersion;
    if LPasTreeVersion <> '' then
      LForm.lbPasTreeVersion.Caption := 'PasTree ' + LPasTreeVersion
    else
      LForm.lbPasTreeVersion.Caption := 'PasTree - server not found';

    LSettings := LoadSettings;
    LForm.chkCtrlClick.Checked := LSettings.CtrlClickNavigation;
    LForm.chkDeclImplToggle.Checked := LSettings.OverrideDeclImplToggle;
    LForm.chkFindAll.Checked := LSettings.EnableFindAll;
    LForm.chkFindRefsImplHeaders.Checked := LSettings.FindRefsImplHeaders;
    LForm.chkRename.Checked := LSettings.EnableRename;
    LForm.chkBlockCompletion.Checked := LSettings.EnableBlockCompletion;
    LForm.chkTooltipSymbolInsight.Checked := LSettings.EnableTooltipSymbolInsight;
    LForm.chkClassComplete.Checked := LSettings.EnableClassComplete;
    LForm.cbxClassCompleteOrder.ItemIndex :=
      Ord(LSettings.ClassCompleteDeclOrder);
    LForm.chkGoTo.Checked := LSettings.EnableGoTo;
    LForm.chkUnitDialogs.Checked := LSettings.EnableUnitDialogs;
    LForm.chkLogging.Checked := LSettings.EnableLogging;
    LForm.chkAdvancedLogging.Checked := LSettings.AdvancedLogging;
    LForm.chkClearLogOnOpen.Checked := LSettings.ClearLogOnOpen;
    LForm.chkLogAllIdeCrashes.Checked := LSettings.LogAllIdeCrashes;
    LForm.chkHighlightTypes.Checked := LSettings.HighlightTypes;
    LForm.cbxTypeColor.Selected := LSettings.TypeColor;
    LForm.chkTypeBold.Checked := fsBold in LSettings.TypeFontStyle;
    LForm.chkTypeItalic.Checked := fsItalic in LSettings.TypeFontStyle;
    LForm.chkTypeUnderline.Checked := fsUnderline in LSettings.TypeFontStyle;
    LForm.chkHighlightInactive.Checked := LSettings.HighlightInactive;
    LForm.cbxErrorSquiggles.ItemIndex := Ord(LSettings.PasTreeErrorSquiggles);
    LForm.FErrorSquigglesOwn := LSettings.PasTreeErrorSquiggles;
    LForm.chkNativeErrorInsight.Checked := LSettings.NativeErrorInsight;
    LForm.cbxInsightManager.ItemIndex := Ord(LSettings.PasTreeInsightManager);
    LForm.chkCompletionBoldNames.Checked := LSettings.CompletionBoldNames;
    LForm.chkNoExplicitProps.Checked := LSettings.DfmNoExplicitProps;
    LForm.chkNoDefaultStyleElements.Checked := LSettings.DfmNoDefaultStyleElems;
    LForm.FillThreads(LSettings.AnalysisThreads);
    LForm.cbxParseMode.ItemIndex := Ord(not LSettings.LightLibraries);
    // Assigning Checked only fires OnClick when the value CHANGES, so the
    // dependent state is set here rather than relied upon above.
    LForm.chkLoggingClick(nil);
    LForm.cbxInsightManagerChange(nil);
    LForm.chkClassCompleteClick(nil);
    LForm.chkFindAllClick(nil);
    LForm.chkHighlightTypesClick(nil);

    if LForm.ShowModal <> mrOk then
      Exit;

    LSettings.CtrlClickNavigation := LForm.chkCtrlClick.Checked;
    LSettings.OverrideDeclImplToggle := LForm.chkDeclImplToggle.Checked;
    LSettings.EnableFindAll := LForm.chkFindAll.Checked;
    LSettings.FindRefsImplHeaders := LForm.chkFindRefsImplHeaders.Checked;
    LSettings.EnableRename := LForm.chkRename.Checked;
    LSettings.EnableBlockCompletion := LForm.chkBlockCompletion.Checked;
    LSettings.EnableTooltipSymbolInsight := LForm.chkTooltipSymbolInsight.Checked;
    LSettings.EnableClassComplete := LForm.chkClassComplete.Checked;
    LSettings.ClassCompleteDeclOrder :=
      LForm.cbxClassCompleteOrder.ItemIndex = 1;
    LSettings.EnableGoTo := LForm.chkGoTo.Checked;
    LSettings.EnableUnitDialogs := LForm.chkUnitDialogs.Checked;
    LSettings.EnableLogging := LForm.chkLogging.Checked;
    LSettings.AdvancedLogging := LForm.chkAdvancedLogging.Checked;
    LSettings.ClearLogOnOpen := LForm.chkClearLogOnOpen.Checked;
    LSettings.LogAllIdeCrashes := LForm.chkLogAllIdeCrashes.Checked;
    LSettings.HighlightTypes := LForm.chkHighlightTypes.Checked;
    LSettings.TypeColor := LForm.cbxTypeColor.Selected;
    LSettings.TypeFontStyle := LForm.TypeStyles;
    LSettings.HighlightInactive := LForm.chkHighlightInactive.Checked;
    // Forced, the combo shows PasTree; what is stored is the user's own.
    if LForm.cbxErrorSquiggles.Enabled then
      LSettings.PasTreeErrorSquiggles := LForm.cbxErrorSquiggles.ItemIndex = 1
    else
      LSettings.PasTreeErrorSquiggles := LForm.FErrorSquigglesOwn;
    LSettings.PasTreeInsightManager := LForm.cbxInsightManager.ItemIndex = 1;
    LSettings.NativeErrorInsight := LForm.chkNativeErrorInsight.Checked;
    LSettings.CompletionBoldNames := LForm.chkCompletionBoldNames.Checked;
    LSettings.DfmNoExplicitProps := LForm.chkNoExplicitProps.Checked;
    LSettings.DfmNoDefaultStyleElems := LForm.chkNoDefaultStyleElements.Checked;
    LSettings.AnalysisThreads := LForm.SelectedThreads;
    LSettings.LightLibraries := LForm.cbxParseMode.ItemIndex <> 1;
    SaveSettings(LSettings);
    Result := True;
  finally
    // Before the form goes: a benchmark still running must not call back
    // into a freed form, and its thread count stops overriding the setting.
    LspEndBenchmark;
    LForm.Free;
  end;
end;

end.
