unit PasTreeIdePlugin.UnitPickerForm;

(*
  The View Unit (Ctrl+F12) and Use Unit (Alt+F11) dialog - PasTree's demo
  View Unit picker (PasTreeDemo.UnitPicker / PasTreeDemo.UnitList), brought
  into the IDE the way Go To was. One form, two modes: View opens the chosen
  unit, Use writes it into the current file's uses clause and so also asks
  WHICH clause. The keys, the requests and the landing are
  PasTreeIdePlugin.UnitPicker's; this unit is the form and the list rules.

  WHY IT EXISTS AT ALL. The IDE's own two dialogs list the units the .dproj
  names and nothing else (Find Unit adds .dcu files on the Library Path). A
  unit the project reaches implicitly - through the search path and a uses
  chain - is in neither, and in a project like AVImark that is most of the
  code. The server knows that set exactly: it is the closure it analyzed.
  The "Implicit Units" box is the demo's, and it switches between the two.

  WHAT THE DEMO'S RULES ARE, kept as they were (PasTreeDemo.UnitList):
  - two lines a row, the name over its directory - `System.Types` and
    `Vcl.Types` read the same in a name-only column;
  - one row per unit NAME, project rows first, so a project copy of a unit
    wins over a library one - the analyzer only ever reaches one of them;
  - sorted by name, the directory as the tie-break;
  - the filter is a case-insensitive SUBSTRING of the name, never of the
    path: the names are dotted, and a prefix filter makes the part people
    remember unreachable.
  View Unit also has the stock dialog's "All files in project group" box:
  it adds the OWN units of the group's other projects, read from the IDE
  (IOTAProject) - no server is asked or started for them, so their implicit
  units are not in it. Use Unit has its section choice in that place.
  Use Unit leaves out, in addition, what the file already uses (either
  section, the server's reading of the LIVE buffer), the file itself and a
  program or package file, which no uses clause can name.

  THE SERVER'S PARTS ARRIVE LATER. The dialog opens on the project's list,
  read from the IDE, so it never waits for the server. Use Unit then asks
  the server what the file already uses and shows no rows until that
  answer lands (warm: a few tens of milliseconds). Either mode asks for
  the closure when the box is ticked (or at show, when it was ticked last
  time). A cold server takes
  seconds to analyze; until the answer lands the box stays ticked, the list
  shows the project's units and the status line says what is awaited. The
  answer is kept even if the box was unticked meanwhile. A modal loop keeps
  pumping, so it lands while the dialog is up; one that lands after the
  dialog closed is dropped (GGeneration).

  THE LIST is PasTreeIdePlugin.ListBox, as in Go To, and for Go To's reason:
  a TListBox rebuilt per keystroke flickers, and nothing outside it can fix
  that.

  THEMED THE IDE'S OWN WAY - RegisterFormClass before construction,
  ApplyTheme after - as every form of this package. Every control is named,
  so the code finds it after any restyling in the designer.

  REMEMBERED (Settings' picker values, like Go To's): the window size, the
  Implicit Units box, and Use Unit's section choice.
*)

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.Generics.Collections,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Graphics,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.ListBox;

type
  TUnitPickerMode = (upmView, upmUse);

  /// <summary>
  /// Asks the server for pastree/units in AScope ('project' for the current
  /// file's uses marks, 'closure' for the implicit units); the answer
  /// arrives on the main thread, possibly while the dialog is still up.
  /// </summary>
  TUnitPickerFetch = reference to procedure(const AScope: string;
    const AOnDone: TLspUnitsProc);

  /// <summary>
  /// The own units of every project of the group, read from the IDE (no
  /// server is asked or started) - View Unit's "All files in project group".
  /// </summary>
  TUnitPickerGroupRows = reference to function: TArray<TLspUnitRow>;

  TUnitClosureState = (ucsNone, ucsAsked, ucsHave, ucsFailed);

  TPasTreeUnitPickerForm = class(TForm)
    edFilter: TEdit;
    pnlButtons: TPanel;
    chkImplicits: TCheckBox;
    chkGroup: TCheckBox;
    rbInterface: TRadioButton;
    rbImplementation: TRadioButton;
    btnOK: TButton;
    btnCancel: TButton;
    sbStatus: TStatusBar;
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure edFilterChange(Sender: TObject);
    procedure edFilterKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure chkImplicitsClick(Sender: TObject);
    procedure chkGroupClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    lbUnits: TPasTreeListBox;
    FMode: TUnitPickerMode;
    FProjectName: string;
    FProject: TArray<TLspUnitRow>;
    FClosure: TArray<TLspUnitRow>;
    FClosureState: TUnitClosureState;
    FClosureError: string;
    // Use Unit only: the file's own reading - what it is and what it uses -
    // asked of the server at show; the list waits for it.
    FDocState: TUnitClosureState;
    FDocKind: string;
    FDocError: string;
    FUsedKeys: TDictionary<string, Boolean>;
    FFetch: TUnitPickerFetch;
    FGroupSource: TUnitPickerGroupRows;
    FGroupRows: TArray<TLspUnitRow>;
    FGroupRead: Boolean;
    FAll: TArray<TLspUnitRow>;     // the current source list, unfiltered
    FShown: TArray<TLspUnitRow>;   // what the list shows
    FChosen: Boolean;
    FChosenRow: TLspUnitRow;
    FQuiet: TColor;
    FLoadingState: Boolean;
    procedure CreateList;
    procedure lbUnitsClick(Sender: TObject);
    procedure lbUnitsDblClick(Sender: TObject);
    procedure lbUnitsDrawItem(AList: TPasTreeListBox; ACanvas: TCanvas;
      AIndex: Integer; const ARect: TRect; ASelected: Boolean);
    procedure AskDoc;
    procedure DocArrived(ASuccess: Boolean; const AUnits: TLspUnits;
      const AError: string);
    procedure AskClosure;
    procedure ClosureArrived(ASuccess: Boolean; const AUnits: TLspUnits;
      const AError: string);
    procedure Rebuild;
    procedure Refilter;
    procedure UpdateStatus;
    procedure MoveSelection(ADelta: Integer);
    procedure LoadState;
    procedure SaveState;
  public
    constructor CreateWith(AOwner: TComponent; AMode: TUnitPickerMode;
      const AProjectRows: TArray<TLspUnitRow>; const AProjectName: string;
      const AFetch: TUnitPickerFetch; const AGroupSource: TUnitPickerGroupRows;
      AQuiet: TColor); reintroduce;
    destructor Destroy; override;
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeUnitPickerForm: TPasTreeUnitPickerForm = nil;

/// <summary>
/// Shows the dialog modally over AProjectRows (the project's own units, read
/// from the IDE) and
/// returns True with the chosen row - and for Use Unit, whether it goes
/// into the implementation clause - or False when cancelled. AFetch asks the
/// server: Use Unit's uses marks at show, the closure when first wanted.
/// </summary>
function ShowUnitPicker(AMode: TUnitPickerMode;
  const AProjectRows: TArray<TLspUnitRow>;
  const AProjectName: string; const AFetch: TUnitPickerFetch;
  const AGroupSource: TUnitPickerGroupRows;
  out ARow: TLspUnitRow; out AImplementation: Boolean): Boolean;

/// <summary>
/// The list rules (see the header): one row per unit name, project rows
/// winning a collision, sorted by name then directory; for Use Unit
/// without the file's own uses, the file itself and program/package files.
/// </summary>
function BuildUnitRows(const ARows: TArray<TLspUnitRow>;
  AProjectOnly: Boolean; AMode: TUnitPickerMode): TArray<TLspUnitRow>;

/// <summary>ARows filtered by a case-insensitive substring of the name.</summary>
function FilterUnitRows(const ARows: TArray<TLspUnitRow>;
  const AFilter: string): TArray<TLspUnitRow>;

implementation

{$R *.dfm}

uses
  System.Math,
  System.UITypes,
  System.StrUtils,
  System.IOUtils,
  System.Generics.Defaults,
  ToolsAPI,
  PasTreeIdePlugin.Settings;

const
  cStateWidth = 'UnitPicker.Width';
  cStateHeight = 'UnitPicker.Height';
  cStateImplicit = 'UnitPicker.Implicit';
  cStateGroup = 'UnitPicker.Group';
  cStateImplementation = 'UnitPicker.Implementation';

var
  // The dialog that is up, if any, and a count that tells an answer for it
  // from one for a dialog already closed.
  GOpenForm: TPasTreeUnitPickerForm = nil;
  GGeneration: Integer = 0;

function BuildUnitRows(const ARows: TArray<TLspUnitRow>;
  AProjectOnly: Boolean; AMode: TUnitPickerMode): TArray<TLspUnitRow>;
var
  LSeen: TDictionary<string, Boolean>;
  LItems: TList<TLspUnitRow>;
  LPass: Integer;
  LRow: TLspUnitRow;
  LExt: string;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  LItems := TList<TLspUnitRow>.Create;
  try
    // Two passes, project rows first: theirs is the copy that wins a name
    // collision, the precedence the analyzer itself applies.
    for LPass := 0 to 1 do
      for LRow in ARows do
      begin
        if LRow.IsProject <> (LPass = 0) then
          Continue;
        if AProjectOnly and not LRow.IsProject then
          Continue;
        if LRow.Name = '' then
          Continue;
        if AMode = upmUse then
        begin
          if LRow.Used or LRow.IsSelf then
            Continue;
          LExt := LowerCase(ExtractFileExt(LRow.FilePath));
          if (LExt = '.dpr') or (LExt = '.dpk') or (LExt = '.dproj') then
            Continue;
        end;
        if LSeen.ContainsKey(LowerCase(LRow.Name)) then
          Continue;
        LSeen.Add(LowerCase(LRow.Name), True);
        LItems.Add(LRow);
      end;
    LItems.Sort(TComparer<TLspUnitRow>.Construct(
      function(const A, B: TLspUnitRow): Integer
      begin
        Result := CompareText(A.Name, B.Name);
        if Result = 0 then
          Result := CompareText(A.FilePath, B.FilePath);
      end));
    Result := LItems.ToArray;
  finally
    LItems.Free;
    LSeen.Free;
  end;
end;

function FilterUnitRows(const ARows: TArray<TLspUnitRow>;
  const AFilter: string): TArray<TLspUnitRow>;
var
  LNeedle: string;
  LIdx, LCount: Integer;
begin
  LNeedle := Trim(AFilter);
  if LNeedle = '' then
    Exit(ARows);
  SetLength(Result, Length(ARows));
  LCount := 0;
  for LIdx := 0 to High(ARows) do
    if ContainsText(ARows[LIdx].Name, LNeedle) then
    begin
      Result[LCount] := ARows[LIdx];
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

function Themed(AColor: TColor): TColor;
var
  LTheming: IOTAIDEThemingServices;
begin
  Result := AColor;
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled and Assigned(LTheming.StyleServices) then
    Result := LTheming.StyleServices.GetSystemColor(AColor);
end;

function ShowUnitPicker(AMode: TUnitPickerMode;
  const AProjectRows: TArray<TLspUnitRow>;
  const AProjectName: string; const AFetch: TUnitPickerFetch;
  const AGroupSource: TUnitPickerGroupRows;
  out ARow: TLspUnitRow; out AImplementation: Boolean): Boolean;
var
  LForm: TPasTreeUnitPickerForm;
  LTheming: IOTAIDEThemingServices;
  LThemed: Boolean;
begin
  ARow := Default(TLspUnitRow);
  AImplementation := False;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeUnitPickerForm);
  LForm := TPasTreeUnitPickerForm.CreateWith(Application.MainForm, AMode,
    AProjectRows, AProjectName, AFetch, AGroupSource, Themed(clGrayText));
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);
    Inc(GGeneration);
    GOpenForm := LForm;
    try
      LForm.ShowModal;
    finally
      GOpenForm := nil;
      Inc(GGeneration);
    end;
    Result := LForm.FChosen;
    ARow := LForm.FChosenRow;
    AImplementation := LForm.rbImplementation.Checked;
  finally
    LForm.Free;
  end;
end;

{ TPasTreeUnitPickerForm }

constructor TPasTreeUnitPickerForm.CreateWith(AOwner: TComponent;
  AMode: TUnitPickerMode; const AProjectRows: TArray<TLspUnitRow>;
  const AProjectName: string; const AFetch: TUnitPickerFetch;
  const AGroupSource: TUnitPickerGroupRows; AQuiet: TColor);
begin
  inherited Create(AOwner);   // loads the .dfm, and with it the design PPI
  FMode := AMode;
  FProject := AProjectRows;
  FUsedKeys := TDictionary<string, Boolean>.Create;
  FProjectName := AProjectName;
  FFetch := AFetch;
  FGroupSource := AGroupSource;
  FQuiet := AQuiet;
  CreateList;
  // Two text lines plus breathing room, from the font in effect after
  // scaling - the demo's measure.
  lbUnits.ItemHeight := Abs(Font.Height) * 2 + 14;
  if AMode = upmUse then
  begin
    Caption := 'Use Unit';
    // The section choice stays until the file's reading says it is a
    // program or library (DocArrived) - one uses clause, nothing to choose.
    chkGroup.Visible := False;
  end
  else
  begin
    Caption := 'View Unit';
    // The stock View Unit's own box, where Use Unit has its section choice.
    chkGroup.Visible := Assigned(AGroupSource);
    rbInterface.Visible := False;
    rbImplementation.Visible := False;
  end;
  LoadState;
  Rebuild;
end;

destructor TPasTreeUnitPickerForm.Destroy;
begin
  FUsedKeys.Free;
  inherited;
end;

{ The list, created here rather than in the .dfm - it is not a registered
  component. Colours through the IDE's style services, Go To's reason. }
procedure TPasTreeUnitPickerForm.CreateList;
begin
  lbUnits := TPasTreeListBox.Create(Self);
  lbUnits.Name := 'lbUnits';
  lbUnits.Parent := Self;
  lbUnits.AlignWithMargins := True;
  lbUnits.Margins.SetBounds(4, 2, 4, 2);
  lbUnits.Align := alClient;
  lbUnits.TabOrder := 1;
  lbUnits.ParentFont := True;
  lbUnits.Color := Themed(clWindow);
  lbUnits.SelectionColor := Themed(clHighlight);
  lbUnits.SelectionTextColor := Themed(clHighlightText);
  lbUnits.OnClick := lbUnitsClick;
  lbUnits.OnDblClick := lbUnitsDblClick;
  lbUnits.OnDrawItem := lbUnitsDrawItem;
end;

procedure TPasTreeUnitPickerForm.LoadState;
var
  LWidth, LHeight: Integer;
begin
  FLoadingState := True;
  try
    LWidth := ReadPickerValue(cStateWidth, 0);
    LHeight := ReadPickerValue(cStateHeight, 0);
    if LWidth >= Constraints.MinWidth then
      Width := LWidth;
    if LHeight >= Constraints.MinHeight then
      Height := LHeight;
    chkImplicits.Checked := ReadPickerValue(cStateImplicit, 0) <> 0;
    chkGroup.Checked := chkGroup.Visible and
      (ReadPickerValue(cStateGroup, 0) <> 0);
    if ReadPickerValue(cStateImplementation, 1) <> 0 then
      rbImplementation.Checked := True
    else
      rbInterface.Checked := True;
  finally
    FLoadingState := False;
  end;
end;

procedure TPasTreeUnitPickerForm.SaveState;
begin
  WritePickerValue(cStateWidth, Width);
  WritePickerValue(cStateHeight, Height);
  WritePickerValue(cStateImplicit, Ord(chkImplicits.Checked));
  if FMode = upmView then
    WritePickerValue(cStateGroup, Ord(chkGroup.Checked));
  if FMode = upmUse then
    WritePickerValue(cStateImplementation, Ord(rbImplementation.Checked));
end;

procedure TPasTreeUnitPickerForm.FormShow(Sender: TObject);
begin
  // Never taller than the monitor's WORK area - a dialog whose OK button
  // sits under the taskbar cannot be finished with the mouse (the demo's
  // note).
  Height := Min(Height, Screen.MonitorFromWindow(Handle).WorkareaRect.Height);
  ActiveControl := edFilter;
  if FMode = upmUse then
    AskDoc;
  if chkImplicits.Checked then
    AskClosure;
end;

{ Use Unit's marks: what the file is and which units it already uses, read
  by the server from the LIVE buffer (a parse, no analysis - answered in
  tens of milliseconds on AVImark, unless the server is busy finishing an
  analysis, when it waits in the queue behind it). }
procedure TPasTreeUnitPickerForm.AskDoc;
var
  LGeneration: Integer;
begin
  if (FDocState <> ucsNone) or not Assigned(FFetch) then
    Exit;
  FDocState := ucsAsked;
  UpdateStatus;
  LGeneration := GGeneration;
  FFetch('project',
    procedure(ASuccess: Boolean; const AUnits: TLspUnits; const AError: string)
    begin
      if (GOpenForm = nil) or (GGeneration <> LGeneration) then
        Exit;
      GOpenForm.DocArrived(ASuccess, AUnits, AError);
    end);
end;

procedure TPasTreeUnitPickerForm.DocArrived(ASuccess: Boolean;
  const AUnits: TLspUnits; const AError: string);
var
  LRow: TLspUnitRow;
  LSectioned: Boolean;
begin
  if not ASuccess then
  begin
    FDocState := ucsFailed;
    FDocError := AError;
    Rebuild;
    Exit;
  end;
  FDocState := ucsHave;
  FDocKind := AUnits.DocKind;
  // The server's own project rows carry the marks; the IDE's rows are
  // matched to them by unit name.
  for LRow in AUnits.Rows do
    if LRow.Used or LRow.IsSelf then
      FUsedKeys.AddOrSetValue(LowerCase(LRow.Name), True);
  if FDocKind = '' then
  begin
    FDocState := ucsFailed;
    FDocError := 'this file is not a unit, program or library';
  end
  else if FDocKind = 'package' then
  begin
    FDocState := ucsFailed;
    FDocError := 'a package has requires/contains, not a uses clause';
  end;
  LSectioned := FDocKind = 'unit';
  rbInterface.Visible := LSectioned;
  rbImplementation.Visible := LSectioned;
  Rebuild;
end;

procedure TPasTreeUnitPickerForm.FormClose(Sender: TObject;
  var Action: TCloseAction);
begin
  SaveState;
end;

procedure TPasTreeUnitPickerForm.AskClosure;
var
  LGeneration: Integer;
begin
  if (FClosureState <> ucsNone) or not Assigned(FFetch) then
    Exit;
  FClosureState := ucsAsked;
  UpdateStatus;
  LGeneration := GGeneration;
  FFetch('closure',
    procedure(ASuccess: Boolean; const AUnits: TLspUnits; const AError: string)
    begin
      // The dialog that asked may be gone - closed, or replaced by another.
      if (GOpenForm = nil) or (GGeneration <> LGeneration) then
        Exit;
      GOpenForm.ClosureArrived(ASuccess, AUnits, AError);
    end);
end;

procedure TPasTreeUnitPickerForm.ClosureArrived(ASuccess: Boolean;
  const AUnits: TLspUnits; const AError: string);
begin
  if ASuccess then
  begin
    FClosure := AUnits.Rows;
    FClosureState := ucsHave;
  end
  else
  begin
    FClosureState := ucsFailed;
    FClosureError := AError;
  end;
  if chkImplicits.Checked then
    Rebuild
  else
    UpdateStatus;
end;

procedure TPasTreeUnitPickerForm.Rebuild;
var
  LSource: TArray<TLspUnitRow>;
  LProjectOnly: Boolean;
  LIdx: Integer;
begin
  // Use Unit shows nothing until it knows what the file already uses: a list
  // that loses rows a moment after it appears reads as the dialog changing
  // its mind.
  if (FMode = upmUse) and (FDocState <> ucsHave) then
  begin
    FAll := nil;
    Refilter;
    Exit;
  end;
  LProjectOnly := not (chkImplicits.Checked and (FClosureState = ucsHave));
  if LProjectOnly then
  begin
    LSource := Copy(FProject);
    if FMode = upmUse then
      for LIdx := 0 to High(LSource) do
        LSource[LIdx].Used := FUsedKeys.ContainsKey(
          LowerCase(LSource[LIdx].Name));
  end
  else
    LSource := FClosure;
  // The group's other projects contribute their OWN units, read once from
  // the IDE. Their implicit units would need their servers, and a group
  // command starts no server nobody asked for (the scope dialog's rule).
  if chkGroup.Visible and chkGroup.Checked and Assigned(FGroupSource) then
  begin
    if not FGroupRead then
    begin
      FGroupRows := FGroupSource();
      FGroupRead := True;
    end;
    LSource := LSource + FGroupRows;
  end;
  FAll := BuildUnitRows(LSource, LProjectOnly, FMode);
  Refilter;
end;

procedure TPasTreeUnitPickerForm.chkGroupClick(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  Rebuild;
end;

procedure TPasTreeUnitPickerForm.Refilter;
var
  LIdx, LKeep: Integer;
  LWanted: string;
begin
  // Keep the selected unit across a filter change when it survives it - the
  // list is rebuilt on every keystroke, and losing the selection mid-typing
  // is what makes such a dialog feel like it is fighting back.
  LWanted := '';
  if (lbUnits.ItemIndex >= 0) and (lbUnits.ItemIndex <= High(FShown)) then
    LWanted := FShown[lbUnits.ItemIndex].FilePath;
  FShown := FilterUnitRows(FAll, edFilter.Text);
  LKeep := -1;
  if LWanted <> '' then
    for LIdx := 0 to High(FShown) do
      if SameText(FShown[LIdx].FilePath, LWanted) then
      begin
        LKeep := LIdx;
        Break;
      end;
  if (LKeep < 0) and (Length(FShown) > 0) then
    LKeep := 0;
  lbUnits.BeginUpdate;
  try
    lbUnits.Count := Length(FShown);
    lbUnits.ItemIndex := LKeep;
    lbUnits.Invalidate;
  finally
    lbUnits.EndUpdate;
  end;
  UpdateStatus;
end;

procedure TPasTreeUnitPickerForm.UpdateStatus;
var
  LText: string;
begin
  if (FMode = upmUse) and (FDocState in [ucsNone, ucsAsked]) then
    LText := 'Reading this file''s uses...'
  else if (FMode = upmUse) and (FDocState = ucsFailed) then
    LText := 'Use Unit: ' + FDocError
  else if (Length(FAll) = 0) and (FMode = upmUse) and not chkImplicits.Checked then
    // A .dpr names every unit of its project in its uses, so without the
    // implicit units there is nothing left to add - say that, rather than a
    // bare "0 units" over an empty list that reads as broken (Alex,
    // 2026-09-25, Alt+F11 in AVImark.dpr).
    LText := 'Every project unit is already used here - tick Implicit Units'
  else if Length(FShown) = Length(FAll) then
    LText := Format('%d units', [Length(FAll)])
  else
    LText := Format('%d of %d units', [Length(FShown), Length(FAll)]);
  if chkImplicits.Checked then
    case FClosureState of
      ucsAsked:
        LText := LText + ' - reading every unit the analysis reached...';
      ucsFailed:
        LText := LText + ' - implicit units unavailable: ' + FClosureError;
    end;
  sbStatus.Panels[0].Text := LText;
  sbStatus.Panels[1].Text := FProjectName;
  btnOK.Enabled := lbUnits.ItemIndex >= 0;
end;

procedure TPasTreeUnitPickerForm.MoveSelection(ADelta: Integer);
var
  LIndex: Integer;
begin
  if lbUnits.Count = 0 then
    Exit;
  LIndex := EnsureRange(lbUnits.ItemIndex + ADelta, 0, lbUnits.Count - 1);
  if LIndex <> lbUnits.ItemIndex then
  begin
    lbUnits.ItemIndex := LIndex;
    UpdateStatus;
  end;
end;

procedure TPasTreeUnitPickerForm.edFilterChange(Sender: TObject);
begin
  Refilter;
end;

procedure TPasTreeUnitPickerForm.edFilterKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  // The list moves while the caret stays in the filter box: typing and
  // choosing are one gesture, and Enter keeps working from the edit.
  case Key of
    VK_DOWN: MoveSelection(1);
    VK_UP: MoveSelection(-1);
    VK_NEXT: MoveSelection(Max(1, lbUnits.PageRows));
    VK_PRIOR: MoveSelection(-Max(1, lbUnits.PageRows));
  else
    Exit;
  end;
  Key := 0;
end;

procedure TPasTreeUnitPickerForm.lbUnitsClick(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TPasTreeUnitPickerForm.lbUnitsDblClick(Sender: TObject);
begin
  if lbUnits.ItemIndex >= 0 then
    btnOKClick(Sender);
end;

procedure TPasTreeUnitPickerForm.lbUnitsDrawItem(AList: TPasTreeListBox;
  ACanvas: TCanvas; AIndex: Integer; const ARect: TRect; ASelected: Boolean);
var
  LTop, LLineHeight: Integer;
  LTag: string;
  LTextColor: TColor;
begin
  if (AIndex < 0) or (AIndex > High(FShown)) then
    Exit;
  ACanvas.FillRect(ARect);
  ACanvas.Brush.Style := bsClear;
  LTextColor := ACanvas.Font.Color;
  LLineHeight := Abs(Font.Height) + 4;
  LTop := ARect.Top + 3;
  ACanvas.TextOut(ARect.Left + 6, LTop, FShown[AIndex].Name);
  // A unit the server has only as a .dcu opens as a generated tab, not a
  // source file - worth saying before the click.
  if FShown[AIndex].IsDcu then
  begin
    LTag := 'compiled only';
    if not ASelected then
      ACanvas.Font.Color := FQuiet;
    ACanvas.TextOut(ARect.Right - 8 - ACanvas.TextWidth(LTag), LTop, LTag);
    ACanvas.Font.Color := LTextColor;
  end;
  Inc(LTop, LLineHeight);
  // The directory in a quieter colour - but NOT on the selected row, where
  // the highlight's own text colour is the only one guaranteed readable.
  if not ASelected then
    ACanvas.Font.Color := FQuiet;
  ACanvas.TextOut(ARect.Left + 6, LTop,
    ExcludeTrailingPathDelimiter(ExtractFilePath(FShown[AIndex].FilePath)));
  ACanvas.Font.Color := LTextColor;
  ACanvas.Brush.Style := bsSolid;
end;

procedure TPasTreeUnitPickerForm.chkImplicitsClick(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  if chkImplicits.Checked then
    AskClosure;
  Rebuild;
end;

procedure TPasTreeUnitPickerForm.btnOKClick(Sender: TObject);
begin
  if (lbUnits.ItemIndex < 0) or (lbUnits.ItemIndex > High(FShown)) then
    Exit;
  FChosenRow := FShown[lbUnits.ItemIndex];
  FChosen := True;
  ModalResult := mrOk;
end;

end.
