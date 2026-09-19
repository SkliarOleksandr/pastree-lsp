unit PasTreeIdePlugin.GoToForm;

(*
  The Go To picker (Ctrl+G) - PasTree's demo dialog (PasTreeDemo.GoToPicker),
  copied into the IDE with three changes and no others (Alex, 2026-09-18:
  "copy the Go To form from the demo whole, it suits us; then a couple of
  tweaks"). The THIRD form in this package with a .dfm, for the reason the
  first two give: the layout is the designer's business, and every control
  is named so the code finds it after any restyling.

  WHAT IT IS. A modal picker with a filter box above tabs and a list below.
  Type to filter, Enter or a double-click jumps, Up/Down/PgUp/PgDn move the
  list from the filter box, Ctrl+Tab flips the tab with the filter text
  intact. A filter that is nothing but digits adds a `line N` row on top of
  the module list, so the same box is the go-to-line command. The row
  nearest ABOVE the caret is selected when the module tab opens, so Ctrl+G
  with an empty box answers "where am I". Each row is drawn by hand
  (lbVirtualOwnerDraw - a project's fifty thousand rows cost nothing to
  list): the head word and the detail in a quieter colour, the name in the
  window text colour with the matched letters in bold, then the unit name
  and the section note quiet again, and `:N` at the right edge for a row
  that knows its line. The boxes at the bottom filter by KIND - All or a
  subset of Types, Vars/Fields, Consts, Routines, Properties; ticking a kind
  unticks All, ticking All clears the kinds, unticking the last kind falls
  back to All. Size and the boxes persist between openings.

  THE THREE CHANGES FROM THE DEMO:

  1. THREE TABS, not two: the MODULE (the active file's outline, with
     positions), the PROJECT (every declaration of every unit of the project
     that owns the file) and the GROUP (the same over every project of the
     group whose server is running - the demo has no groups). A project or
     group row has no position of its own; choosing it asks the server that
     listed it where it lands (LspOutlineTarget), which rehydrates that one
     unit. The tab is named after what it lists - the file, the .dproj, the
     .groupproj - so the dialog says where a chosen row can land. No group
     tab when the group has one project.

  2. AN INCLUDES BOX: the `include 'Foo.inc'` landmark rows can be hidden
     (Alex: "a filter - show or do not show the include entries"). The
     other landmarks (unit, interface, uses, implementation) always show, as
     in the demo. Independent of All: a landmark is not a kind.

  3. THE LISTS ARRIVE ASYNCHRONOUSLY. The demo reads them off an in-process
     model; here every list is an LSP answer delivered on a later
     main-thread turn (PasTreeIdePlugin.LspSession). The module list is
     fetched BEFORE the dialog opens (under the IDE's wait dialog, by
     PasTreeIdePlugin.GoToPicker); the project and group lists on the first switch
     to their tab, with the status bar saying "loading" until the answer
     lands - the modal loop pumps messages, so it does. A row's landing is
     asked the same way, with the Go button disabled while it is in flight.
     Every callback checks that THIS form is still the open one (GOpenForm)
     before touching it: a late answer for a closed dialog is dropped.

  TYPES: the rows are TLspOutlineRow (PasTreeIdePlugin.LspSession), PasTree's
  TPasOutlineEntry spelled without PasTree - this package must not link it
  (see the .dpk). Kinds are the server's words, matched by string here.

  THEMED THE IDE'S OWN WAY - RegisterFormClass before construction,
  ApplyTheme after, exactly as PasTreeIdePlugin.SettingsForm does; the
  owner-drawn rows take their two colours from the IDE's style services so
  a dark theme gets its variants (see RowColors).
*)

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Graphics,
  PasTreeIdePlugin.LspSession;

type
  TGoToRowKind = (grEntry, grLine);

  { One visible row: an outline entry, or the synthetic `line N`. MatchFrom/
    MatchLen (0-based, into the row's NAME COLUMN text - see NameColumn)
    mark the filter hit to embolden; MatchLen = 0 when nothing to mark. }
  TGoToRow = record
    Kind: TGoToRowKind;
    Entry: Integer;          // index into the list (grEntry)
    LineNo: Integer;         // the requested line (grLine)
    MatchFrom, MatchLen: Integer;
  end;

  { The declaration kinds the bottom boxes filter by. The server's words:
    'type', 'var', 'const', 'property', 'routine'. }
  TGoToKind = (gkType, gkVar, gkConst, gkProperty, gkRoutine);
  TGoToKinds = set of TGoToKind;

  TGoToScope = (gsModule, gsProject, gsGroup);

  { The project or group list, asked for once, on the first switch to that
    tab; the answer comes later, on the main thread. AAnswered/AInGroup are
    the group's "N of M projects" (1 of 1 for a project). }
  TGoToListSource = reference to procedure(AScope: TGoToScope;
    const AOnDone: TLspOutlineGroupProc);

  { The landing of a row that carries no position (a project/group row),
    answered later with zero or one hit. Zero keeps the dialog open. }
  TGoToResolve = reference to procedure(const ARow: TLspOutlineRow;
    const AOnDone: TLspHitsProc);

  TPasTreeGoToForm = class(TForm)
    tcScope: TTabControl;
    edFilter: TEdit;
    lbItems: TListBox;
    pnlButtons: TPanel;
    sbStatus: TStatusBar;
    chkAll: TCheckBox;
    chkTypes: TCheckBox;
    chkVars: TCheckBox;
    chkConsts: TCheckBox;
    chkRoutines: TCheckBox;
    chkProps: TCheckBox;
    chkIncludes: TCheckBox;
    btnGo: TButton;
    btnCancel: TButton;
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure edFilterChange(Sender: TObject);
    procedure edFilterKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure lbItemsClick(Sender: TObject);
    procedure lbItemsDblClick(Sender: TObject);
    procedure lbItemsDrawItem(AControl: TWinControl; AIndex: Integer;
      ARect: TRect; AState: TOwnerDrawState);
    procedure FilterChanged(Sender: TObject);
    procedure AllChanged(Sender: TObject);
    procedure IncludesChanged(Sender: TObject);
    procedure btnGoClick(Sender: TObject);
    procedure tcScopeChange(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FEntries: array[TGoToScope] of TArray<TLspOutlineRow>;
    FLoaded: array[TGoToScope] of Boolean;
    FLoading: array[TGoToScope] of Boolean;
    FAnswered, FInGroup, FPending: array[TGoToScope] of Integer;
    FHasGroup: Boolean;
    FSource: TGoToListSource;
    FResolve: TGoToResolve;
    FRows: TArray<TGoToRow>;
    FModuleFile: string;      // the module's main file (for the caret row)
    FCaretLine: Integer;
    FLineCount: Integer;      // the module's line count (line N is clamped)
    FChosen: Boolean;
    FChosenFile: string;
    FChosenLine, FChosenCol: Integer;
    FResolving: Boolean;      // a landing request is in flight
    FHeadWidth: Integer;      // the head-word column, measured per tab
    FLoadingState: Boolean;   // boxes being set in bulk: rules and refilter off
    FQuiet, FStrong: TColor;  // the two row colours, from the IDE's theme
    function Scope: TGoToScope;
    function Entries: TArray<TLspOutlineRow>;
    function Kinds: TGoToKinds;
    procedure EnsureLoaded;
    procedure UpdateCursor;
    procedure MeasureHeadColumn;
    procedure Refilter(ASelectNearCaret: Boolean);
    procedure MoveSelection(ADelta: Integer);
    procedure LoadState;
    procedure SaveState;
  public
    constructor CreateWith(AOwner: TComponent;
      const AEntries: TArray<TLspOutlineRow>; const AModuleFile: string;
      ACaretLine, ALineCount: Integer;
      const AProjectName, AGroupName: string; AHasGroup: Boolean;
      ASource: TGoToListSource; AResolve: TGoToResolve;
      AQuiet, AStrong: TColor); reintroduce;
  end;

var
  // For the Form Designer only, never assigned - see SettingsForm's note on
  // the same variable.
  PasTreeGoToForm: TPasTreeGoToForm = nil;

{ The visible rows for a filter text and a kind set, in list order. A
  digits-only filter puts a `line N` row first (N clamped to 1..ALineCount)
  and still lists the entries whose text contains the digits; ALineCount <= 0
  means "no line row" (a project tab has no line to go to). The match is a
  case-insensitive substring over the row's name column (Owner.Name, or the
  head word for a landmark). Landmarks pass the kind filter unconditionally;
  an include row passes only with AIncludes. Exposed for a test. }
function FilterRows(const AEntries: TArray<TLspOutlineRow>;
  const AFilter: string; AKinds: TGoToKinds; AIncludes: Boolean;
  ALineCount: Integer): TArray<TGoToRow>;

{ The name column of an entry: `Owner.Name`, or the head word alone for a
  landmark with no name (`interface`, `uses`). }
function NameColumn(const AEntry: TLspOutlineRow): string;

{ Shows the dialog modally, themed the IDE's way. True and the target when
  the user chose a row that could be placed. }
function ShowGoTo(const AEntries: TArray<TLspOutlineRow>;
  const AModuleFile: string; ACaretLine, ALineCount: Integer;
  const AProjectName, AGroupName: string; AHasGroup: Boolean;
  ASource: TGoToListSource; AResolve: TGoToResolve;
  out AFile: string; out ALine, ACol: Integer): Boolean;

implementation

uses
  System.Math,
  System.UITypes,
  System.IOUtils,
  System.Generics.Collections,
  Vcl.Themes,
  ToolsAPI,
  PasTreeIdePlugin.Settings;

{$R *.dfm}

const
  SET_WIDTH = 'GoToWidth';
  SET_HEIGHT = 'GoToHeight';
  SET_KINDS = 'GoToKinds';         // a bit per box; 32 = All (the default)
  SET_INCLUDES = 'GoToIncludes';   // 1 = the include rows show (default)

  ALL_KINDS: TGoToKinds = [gkType, gkVar, gkConst, gkProperty, gkRoutine];

var
  // The one open picker, or nil. Every asynchronous answer checks that the
  // form it was issued for is still this one before touching it - the user
  // may have cancelled while a server was thinking.
  GOpenForm: TPasTreeGoToForm = nil;

{ The declaration kind of a row, or False for a landmark. }
function DeclKind(const AEntry: TLspOutlineRow; out AKind: TGoToKind): Boolean;
begin
  Result := True;
  if AEntry.Kind = 'type' then
    AKind := gkType
  else if AEntry.Kind = 'var' then
    AKind := gkVar
  else if AEntry.Kind = 'const' then
    AKind := gkConst
  else if AEntry.Kind = 'property' then
    AKind := gkProperty
  else if AEntry.Kind = 'routine' then
    AKind := gkRoutine
  else
    Result := False;
end;

function NameColumn(const AEntry: TLspOutlineRow): string;
begin
  if AEntry.Name = '' then
    Exit(AEntry.Head);
  if AEntry.Owner <> '' then
    Result := AEntry.Owner + '.' + AEntry.Name
  else
    Result := AEntry.Name;
end;

function IsDigits(const AText: string): Boolean;
var
  LIdx: Integer;
begin
  Result := AText <> '';
  for LIdx := 1 to Length(AText) do
    if not CharInSet(AText[LIdx], ['0'..'9']) then
      Exit(False);
end;

function FilterRows(const AEntries: TArray<TLspOutlineRow>;
  const AFilter: string; AKinds: TGoToKinds; AIncludes: Boolean;
  ALineCount: Integer): TArray<TGoToRow>;
var
  LFilter: string;
  LIdx, LCount, LPos, LLine: Integer;
  LRow: TGoToRow;
  LKind: TGoToKind;
begin
  LFilter := Trim(AFilter);
  SetLength(Result, Length(AEntries) + 1);
  LCount := 0;
  if (ALineCount > 0) and IsDigits(LFilter) then
  begin
    LLine := StrToIntDef(LFilter, 0);
    if LLine < 1 then
      LLine := 1;
    if LLine > ALineCount then
      LLine := ALineCount;
    LRow := Default(TGoToRow);
    LRow.Kind := grLine;
    LRow.LineNo := LLine;
    Result[LCount] := LRow;
    Inc(LCount);
  end;
  LFilter := LowerCase(LFilter);
  for LIdx := 0 to High(AEntries) do
  begin
    if DeclKind(AEntries[LIdx], LKind) then
    begin
      if not (LKind in AKinds) then
        Continue;
    end
    else if not AIncludes and (AEntries[LIdx].Kind = 'include') then
      Continue;
    LRow := Default(TGoToRow);
    LRow.Kind := grEntry;
    LRow.Entry := LIdx;
    if LFilter <> '' then
    begin
      // Key is the name column lower-cased once when the list arrived
      // (PasTreeIdePlugin.OutlineRows) - per keystroke this is one Pos per
      // row and no allocation, which matters at 100k rows.
      LPos := Pos(LFilter, AEntries[LIdx].Key);
      if LPos = 0 then
        Continue;
      LRow.MatchFrom := LPos - 1;
      LRow.MatchLen := Length(LFilter);
    end;
    Result[LCount] := LRow;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

{ The two row colours. Through the IDE's style services when a theme is on,
  so the quiet grey and the text colour are the theme's rather than the
  system's - a system clWindowText on a dark editor is invisible. }
procedure RowColors(out AQuiet, AStrong: TColor);
var
  LTheming: IOTAIDEThemingServices;
begin
  AQuiet := clGrayText;
  AStrong := clWindowText;
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled and Assigned(LTheming.StyleServices) then
  begin
    AQuiet := LTheming.StyleServices.GetSystemColor(clGrayText);
    AStrong := LTheming.StyleServices.GetSystemColor(clWindowText);
  end;
end;

function ShowGoTo(const AEntries: TArray<TLspOutlineRow>;
  const AModuleFile: string; ACaretLine, ALineCount: Integer;
  const AProjectName, AGroupName: string; AHasGroup: Boolean;
  ASource: TGoToListSource; AResolve: TGoToResolve;
  out AFile: string; out ALine, ACol: Integer): Boolean;
var
  LForm: TPasTreeGoToForm;
  LTheming: IOTAIDEThemingServices;
  LThemed: Boolean;
  LQuiet, LStrong: TColor;
begin
  Result := False;
  AFile := '';
  ALine := 0;
  ACol := 0;
  LThemed := Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming)
    and LTheming.IDEThemingEnabled;
  // BEFORE construction, as for every form here: the style hook is
  // installed on the class and a form made earlier does not pick it up.
  if LThemed then
    LTheming.RegisterFormClass(TPasTreeGoToForm);
  RowColors(LQuiet, LStrong);
  LForm := TPasTreeGoToForm.CreateWith(Application.MainForm, AEntries,
    AModuleFile, ACaretLine, ALineCount, AProjectName, AGroupName, AHasGroup,
    ASource, AResolve, LQuiet, LStrong);
  try
    if LThemed then
      LTheming.ApplyTheme(LForm);
    GOpenForm := LForm;
    try
      LForm.ShowModal;
    finally
      GOpenForm := nil;
    end;
    Result := LForm.FChosen;
    AFile := LForm.FChosenFile;
    ALine := LForm.FChosenLine;
    ACol := LForm.FChosenCol;
  finally
    LForm.Free;
  end;
end;

{ TPasTreeGoToForm }

constructor TPasTreeGoToForm.CreateWith(AOwner: TComponent;
  const AEntries: TArray<TLspOutlineRow>; const AModuleFile: string;
  ACaretLine, ALineCount: Integer; const AProjectName, AGroupName: string;
  AHasGroup: Boolean; ASource: TGoToListSource; AResolve: TGoToResolve;
  AQuiet, AStrong: TColor);
begin
  inherited Create(AOwner);   // loads the .dfm, and with it the design PPI
  FEntries[gsModule] := AEntries;
  FLoaded[gsModule] := True;
  FAnswered[gsModule] := 1;
  FInGroup[gsModule] := 1;
  FModuleFile := AModuleFile;
  FCaretLine := ACaretLine;
  FLineCount := ALineCount;
  FHasGroup := AHasGroup;
  FSource := ASource;
  FResolve := AResolve;
  FQuiet := AQuiet;
  FStrong := AStrong;
  // The tabs are named after what they list - the file, the project, the
  // group - so the dialog says where a chosen row can land.
  tcScope.Tabs[0] := TPath.GetFileName(AModuleFile);
  if AProjectName <> '' then
    tcScope.Tabs[1] := AProjectName
  else
    tcScope.Tabs[1] := 'Project';
  if FHasGroup then
  begin
    if AGroupName <> '' then
      tcScope.Tabs[2] := AGroupName
    else
      tcScope.Tabs[2] := 'Project Group';
  end
  else
    tcScope.Tabs.Delete(2);
  tcScope.TabIndex := 0;
  // One text line plus breathing room, from the font in effect after
  // scaling - the designer cannot state a row height in font terms.
  lbItems.ItemHeight := Abs(Font.Height) + 9;
  LoadState;
end;

function TPasTreeGoToForm.Scope: TGoToScope;
begin
  case tcScope.TabIndex of
    1: Result := gsProject;
    2: Result := gsGroup;
  else
    Result := gsModule;
  end;
end;

function TPasTreeGoToForm.Entries: TArray<TLspOutlineRow>;
begin
  Result := FEntries[Scope];
end;

{ The project and group lists are asked for on the first switch to their
  tab and arrive later; until then the tab shows an empty list and a status
  line that says so. The answer refilters the CURRENT tab only if it is
  still the one the answer is for - the user may have flipped back. }
procedure TPasTreeGoToForm.EnsureLoaded;
var
  LScope: TGoToScope;
  LSelf: TPasTreeGoToForm;
begin
  LScope := Scope;
  if FLoaded[LScope] or FLoading[LScope] or not Assigned(FSource) then
    Exit;
  FLoading[LScope] := True;
  sbStatus.SimpleText := '  loading...';
  UpdateCursor;
  LSelf := Self;
  FSource(LScope,
    // Called once per answering project for the group (APending counts
    // down to 0), once for the project: the list grows as cold servers
    // finish their analysis, and the selection is kept across the growth.
    procedure(ASuccess: Boolean; const ARows: TArray<TLspOutlineRow>;
      AAnswered, AInGroup, APending: Integer; const AError: string)
    begin
      if GOpenForm <> LSelf then
        Exit;   // the dialog this was asked for is gone
      FLoading[LScope] := APending > 0;
      UpdateCursor;
      FLoaded[LScope] := True;
      FAnswered[LScope] := AAnswered;
      FInGroup[LScope] := AInGroup;
      FPending[LScope] := APending;
      if ASuccess then
        FEntries[LScope] := ARows
      else
        FEntries[LScope] := nil;
      if Scope = LScope then
      begin
        MeasureHeadColumn;
        Refilter(lbItems.ItemIndex < 0);
        if not ASuccess and (AError <> '') and (APending = 0) then
          sbStatus.SimpleText := '  ' + AError;
      end;
    end);
end;

procedure TPasTreeGoToForm.MeasureHeadColumn;
var
  LEntries: TArray<TLspOutlineRow>;
  LSeen: TDictionary<string, Boolean>;
  LIdx: Integer;
begin
  // The head column: wide enough for the longest head word actually present,
  // so names line up whatever mix of `class function` and `var` the list
  // has. Measured here, where the canvas has the scaled font - and once per
  // DISTINCT word: there are a dozen of them in 100k rows, and a GDI text
  // measurement per row was a third of a second on the project list.
  lbItems.Canvas.Font.Assign(lbItems.Font);
  FHeadWidth := lbItems.Canvas.TextWidth('line');
  LEntries := Entries;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LIdx := 0 to High(LEntries) do
      if LSeen.TryAdd(LEntries[LIdx].Head, True) then
        FHeadWidth := Max(FHeadWidth,
          lbItems.Canvas.TextWidth(LEntries[LIdx].Head));
  finally
    LSeen.Free;
  end;
end;

procedure TPasTreeGoToForm.FormShow(Sender: TObject);
begin
  Height := Min(Height, Screen.MonitorFromWindow(Handle).WorkareaRect.Height);
  Width := Min(Width, Screen.MonitorFromWindow(Handle).WorkareaRect.Width);
  MeasureHeadColumn;
  Refilter(True);
  ActiveControl := edFilter;
end;

{ The working cursor (arrow with a small hourglass - typing goes on) while
  the CURRENT tab's list is still arriving (Alex, 2026-09-18: "progress on
  the mouse cursor while it loads"). Screen-wide because the form's own
  Cursor does not cover its child controls; restored on every answer, tab
  switch and at close, so a cancelled dialog never leaves it behind. }
procedure TPasTreeGoToForm.UpdateCursor;
begin
  if FLoading[Scope] and (GOpenForm = Self) then
    Screen.Cursor := crAppStart
  else
    Screen.Cursor := crDefault;
end;

procedure TPasTreeGoToForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Screen.Cursor := crDefault;
  SaveState;
end;

procedure TPasTreeGoToForm.LoadState;
var
  LBits: Integer;
begin
  Width := Max(400, ReadPickerValue(SET_WIDTH, Width));
  Height := Max(300, ReadPickerValue(SET_HEIGHT, Height));
  // Bit 32 = All. Five set boxes read as All, anything else as a real subset.
  LBits := ReadPickerValue(SET_KINDS, 32);
  if LBits and 31 = 31 then
    LBits := 32;
  FLoadingState := True;
  try
    chkAll.Checked := LBits and 32 <> 0;
    chkTypes.Checked := LBits and 1 <> 0;
    chkVars.Checked := LBits and 2 <> 0;
    chkConsts.Checked := LBits and 4 <> 0;
    chkRoutines.Checked := LBits and 8 <> 0;
    chkProps.Checked := LBits and 16 <> 0;
    if LBits and 63 = 0 then
      chkAll.Checked := True;
    chkIncludes.Checked := ReadPickerValue(SET_INCLUDES, 1) <> 0;
  finally
    FLoadingState := False;
  end;
end;

procedure TPasTreeGoToForm.SaveState;
var
  LBits: Integer;
begin
  if WindowState = wsNormal then
  begin
    WritePickerValue(SET_WIDTH, Width);
    WritePickerValue(SET_HEIGHT, Height);
  end;
  LBits := 0;
  if chkAll.Checked then LBits := LBits or 32;
  if chkTypes.Checked then LBits := LBits or 1;
  if chkVars.Checked then LBits := LBits or 2;
  if chkConsts.Checked then LBits := LBits or 4;
  if chkRoutines.Checked then LBits := LBits or 8;
  if chkProps.Checked then LBits := LBits or 16;
  WritePickerValue(SET_KINDS, LBits);
  WritePickerValue(SET_INCLUDES, Ord(chkIncludes.Checked));
end;

function TPasTreeGoToForm.Kinds: TGoToKinds;
begin
  if chkAll.Checked then
    Exit(ALL_KINDS);
  Result := [];
  if chkTypes.Checked then Include(Result, gkType);
  if chkVars.Checked then Include(Result, gkVar);
  if chkConsts.Checked then Include(Result, gkConst);
  if chkRoutines.Checked then Include(Result, gkRoutine);
  if chkProps.Checked then Include(Result, gkProperty);
end;

procedure TPasTreeGoToForm.Refilter(ASelectNearCaret: Boolean);
var
  LEntries: TArray<TLspOutlineRow>;
  LIdx, LKeep, LKeepEntry, LLineCount: Integer;
  LScope: TGoToScope;
  LStatus: string;
begin
  // Keep the selected entry across a filter change when it survives it -
  // losing the selection mid-typing is what makes a picker feel like it is
  // fighting back. On first show the caret decides instead.
  LKeepEntry := -1;
  if (lbItems.ItemIndex >= 0) and (lbItems.ItemIndex <= High(FRows)) and
     (FRows[lbItems.ItemIndex].Kind = grEntry) then
    LKeepEntry := FRows[lbItems.ItemIndex].Entry;
  LScope := Scope;
  LEntries := Entries;
  if LScope <> gsModule then
    LLineCount := 0    // no `line N` row: there is no one file to go to
  else
    LLineCount := FLineCount;
  FRows := FilterRows(LEntries, edFilter.Text, Kinds, chkIncludes.Checked,
    LLineCount);
  // Virtual list: the count is the whole update, every row is painted from
  // FRows on demand.
  lbItems.Count := Length(FRows);
  LKeep := -1;
  if ASelectNearCaret and (LScope = gsModule) then
  begin
    // The last row at or above the caret, in the module's own file - an
    // include's rows carry other line numbers and must not compete.
    for LIdx := 0 to High(FRows) do
      if FRows[LIdx].Kind = grEntry then
        with LEntries[FRows[LIdx].Entry] do
          if SameText(FilePath, FModuleFile) and (Line <= FCaretLine) then
            LKeep := LIdx;
  end
  else if LKeepEntry >= 0 then
    for LIdx := 0 to High(FRows) do
      if (FRows[LIdx].Kind = grEntry) and (FRows[LIdx].Entry = LKeepEntry) then
      begin
        LKeep := LIdx;
        Break;
      end;
  if (LKeep < 0) and (Length(FRows) > 0) then
    LKeep := 0;
  lbItems.ItemIndex := LKeep;
  btnGo.Enabled := (LKeep >= 0) and not FResolving;
  // Shown of listed - the `line N` row is not an entry and is not counted.
  LIdx := Length(FRows);
  if (LIdx > 0) and (FRows[0].Kind = grLine) then
    Dec(LIdx);
  if FLoading[LScope] and not FLoaded[LScope] then
    LStatus := '  loading...'
  else
    LStatus := Format('  %d of %d', [LIdx, Length(LEntries)]);
  // The group tab says how many projects are in the list so far, and how
  // many servers are still analyzing - a cold project takes its time, and
  // the rows already in are shown meanwhile.
  if (LScope = gsGroup) and FLoaded[LScope] then
  begin
    LStatus := LStatus + Format('  -  %d of %d projects',
      [FAnswered[LScope], FInGroup[LScope]]);
    if FPending[LScope] > 0 then
      LStatus := LStatus + Format(', %d still loading', [FPending[LScope]]);
  end;
  sbStatus.SimpleText := LStatus;
end;

procedure TPasTreeGoToForm.tcScopeChange(Sender: TObject);
begin
  // A tab switch is a new list: the old selection means nothing in it, the
  // module tab reselects by caret, the others start at the top.
  lbItems.ItemIndex := -1;
  FRows := nil;
  EnsureLoaded;
  UpdateCursor;
  MeasureHeadColumn;
  Refilter(True);
  ActiveControl := edFilter;
end;

// A list box repaints only the pixels a resize exposes; the `:N` column is
// anchored to the RIGHT edge, so every row must be painted again or the old
// numbers stay where the edge used to be.
procedure TPasTreeGoToForm.FormResize(Sender: TObject);
begin
  lbItems.Invalidate;
end;

procedure TPasTreeGoToForm.edFilterChange(Sender: TObject);
begin
  Refilter(False);
end;

// The kind boxes are All OR a subset, never both: ticking a kind unticks
// All, ticking All clears the kinds, and unticking the last kind falls back
// to All (an empty list is never what a click meant). While the saved state
// loads, the boxes are set in bulk and the rules stay out of it.
procedure TPasTreeGoToForm.FilterChanged(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  FLoadingState := True;   // a programmatic Checked change fires OnClick too
  try
    if TCheckBox(Sender).Checked then
      chkAll.Checked := False
    else if not (chkTypes.Checked or chkVars.Checked or chkConsts.Checked or
                 chkRoutines.Checked or chkProps.Checked) then
      chkAll.Checked := True;
  finally
    FLoadingState := False;
  end;
  Refilter(False);
end;

procedure TPasTreeGoToForm.AllChanged(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  FLoadingState := True;
  try
    if chkAll.Checked then
    begin
      chkTypes.Checked := False;
      chkVars.Checked := False;
      chkConsts.Checked := False;
      chkRoutines.Checked := False;
      chkProps.Checked := False;
    end
    else if not (chkTypes.Checked or chkVars.Checked or chkConsts.Checked or
                 chkRoutines.Checked or chkProps.Checked) then
      chkAll.Checked := True;   // nothing else is on: All cannot go off
  finally
    FLoadingState := False;
  end;
  Refilter(False);
end;

// Includes is a landmark switch, not a kind: it takes no part in the
// All-or-subset rule above.
procedure TPasTreeGoToForm.IncludesChanged(Sender: TObject);
begin
  if FLoadingState then
    Exit;
  Refilter(False);
end;

procedure TPasTreeGoToForm.MoveSelection(ADelta: Integer);
var
  LNew: Integer;
begin
  if lbItems.Count = 0 then
    Exit;
  LNew := EnsureRange(lbItems.ItemIndex + ADelta, 0, lbItems.Count - 1);
  lbItems.ItemIndex := LNew;
  btnGo.Enabled := not FResolving;
end;

procedure TPasTreeGoToForm.edFilterKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  LPage: Integer;
begin
  // Up/Down/PgUp/PgDn move the LIST while the caret stays in the filter box:
  // typing and choosing are one gesture, and Enter keeps working from here.
  // Ctrl+Tab cycles the tabs the same way (Ctrl+Shift+Tab backwards), filter
  // text intact.
  LPage := Max(1, lbItems.ClientHeight div Max(1, lbItems.ItemHeight) - 1);
  case Key of
    VK_DOWN: begin MoveSelection(1); Key := 0; end;
    VK_UP: begin MoveSelection(-1); Key := 0; end;
    VK_NEXT: begin MoveSelection(LPage); Key := 0; end;
    VK_PRIOR: begin MoveSelection(-LPage); Key := 0; end;
    VK_TAB:
      if (ssCtrl in Shift) and (tcScope.Tabs.Count > 1) then
      begin
        if ssShift in Shift then
          tcScope.TabIndex := (tcScope.TabIndex + tcScope.Tabs.Count - 1)
            mod tcScope.Tabs.Count
        else
          tcScope.TabIndex := (tcScope.TabIndex + 1) mod tcScope.Tabs.Count;
        tcScopeChange(tcScope);
        Key := 0;
      end;
  end;
end;

procedure TPasTreeGoToForm.lbItemsClick(Sender: TObject);
begin
  btnGo.Enabled := (lbItems.ItemIndex >= 0) and not FResolving;
end;

procedure TPasTreeGoToForm.lbItemsDblClick(Sender: TObject);
begin
  btnGoClick(Sender);
end;

procedure TPasTreeGoToForm.btnGoClick(Sender: TObject);
var
  LRow: TGoToRow;
  LEntries: TArray<TLspOutlineRow>;
  LSelf: TPasTreeGoToForm;
begin
  if FResolving or (lbItems.ItemIndex < 0) or
     (lbItems.ItemIndex > High(FRows)) then
    Exit;
  LRow := FRows[lbItems.ItemIndex];
  LEntries := Entries;
  case LRow.Kind of
    grLine:
      begin
        FChosenFile := FModuleFile;
        FChosenLine := LRow.LineNo;
        FChosenCol := 1;
      end;
    grEntry:
      if LEntries[LRow.Entry].UnitId >= 0 then
      begin
        // A project row: no position of its own, the server that listed it
        // places it (and rehydrates the unit if it has to). The answer comes
        // later; the dialog waits with Go disabled, and a row that cannot
        // be placed keeps it open rather than landing somewhere else.
        if not Assigned(FResolve) then
          Exit;
        FResolving := True;
        btnGo.Enabled := False;
        sbStatus.SimpleText := '  locating ' +
          NameColumn(LEntries[LRow.Entry]) + '...';
        LSelf := Self;
        FResolve(LEntries[LRow.Entry],
          procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
            const AError: string)
          begin
            if GOpenForm <> LSelf then
              Exit;
            FResolving := False;
            btnGo.Enabled := lbItems.ItemIndex >= 0;
            if ASuccess and (Length(AHits) > 0) then
            begin
              FChosenFile := AHits[0].FilePath;
              FChosenLine := AHits[0].Row;
              FChosenCol := AHits[0].Col;
              FChosen := True;
              ModalResult := mrOk;
            end
            else if AError <> '' then
              sbStatus.SimpleText := '  ' + AError
            else
              sbStatus.SimpleText := '  the declaration could not be placed';
          end);
        Exit;
      end
      else
      begin
        FChosenFile := LEntries[LRow.Entry].FilePath;
        FChosenLine := LEntries[LRow.Entry].Line;
        FChosenCol := LEntries[LRow.Entry].Col;
      end;
  end;
  FChosen := True;
  ModalResult := mrOk;
end;

// The section note after the detail: `(declaration; interface section)` for
// a routine header without a body, `(interface section)` for any other
// declaration, nothing for an implementation row (its section is implied)
// or a landmark. A project row (one row per routine, never a body) reads
// `(interface section)` for a routine too.
function SectionNote(const AEntry: TLspOutlineRow): string;
var
  LKind: TGoToKind;
begin
  Result := '';
  if not DeclKind(AEntry, LKind) or AEntry.IsImpl or (AEntry.Section = '') then
    Exit;
  Result := AEntry.Section + ' section';
  if (LKind = gkRoutine) and (AEntry.Sym < 0) then
    Result := 'declaration; ' + Result;
  Result := '(' + Result + ')';
end;

procedure TPasTreeGoToForm.lbItemsDrawItem(AControl: TWinControl;
  AIndex: Integer; ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LRow: TGoToRow;
  LEntries: TArray<TLspOutlineRow>;
  LQuiet, LStrong: TColor;
  LX, LY, LLineRight, LSaved: Integer;
  LName, LNote: string;

  procedure Put(const AText: string; AColor: TColor; ABold: Boolean);
  begin
    if AText = '' then
      Exit;
    LCanvas.Font.Color := AColor;
    if ABold then
      LCanvas.Font.Style := [fsBold]
    else
      LCanvas.Font.Style := [];
    LCanvas.TextOut(LX, LY, AText);
    Inc(LX, LCanvas.TextWidth(AText));
  end;

begin
  LCanvas := lbItems.Canvas;
  LCanvas.FillRect(ARect);
  if (AIndex < 0) or (AIndex > High(FRows)) then
    Exit;
  LRow := FRows[AIndex];
  // A selected row keeps the highlight text colour for everything: it is
  // the only colour guaranteed readable on the highlight background.
  if odSelected in AState then
  begin
    LQuiet := LCanvas.Font.Color;
    LStrong := LCanvas.Font.Color;
  end
  else
  begin
    LQuiet := FQuiet;
    LStrong := FStrong;
  end;
  LX := ARect.Left + 6;
  LY := ARect.Top + (ARect.Height - LCanvas.TextHeight('Xg')) div 2;
  if LRow.Kind = grLine then
  begin
    Put('line', LQuiet, False);
    LX := ARect.Left + 6 + FHeadWidth + 8;
    Put(IntToStr(LRow.LineNo), LStrong, True);
    Exit;
  end;
  LEntries := Entries;
  if LRow.Entry > High(LEntries) then
    Exit;
  with LEntries[LRow.Entry] do
  begin
    // The line column, right-aligned as `:N`, for a row that knows its line
    // (the module tab; a project row has no position until it is chosen).
    // Drawn FIRST, and the row text is then clipped short of it, so a long
    // detail runs out under the column instead of over it.
    LLineRight := ARect.Right;
    if Line > 0 then
    begin
      LNote := ':' + IntToStr(Line);
      LCanvas.Font.Style := [];
      LLineRight := ARect.Right - 6 - LCanvas.TextWidth(LNote);
      LX := LLineRight;
      Put(LNote, LQuiet, False);
      LX := ARect.Left + 6;
      LLineRight := LLineRight - 8;
    end;
    LSaved := SaveDC(LCanvas.Handle);
    IntersectClipRect(LCanvas.Handle, ARect.Left, ARect.Top, LLineRight,
      ARect.Bottom);
    // The name column is `Owner.Name` - or, for a landmark, the head word
    // itself, which then takes the head column and the match highlight.
    LName := NameColumn(LEntries[LRow.Entry]);
    if Name <> '' then
    begin
      Put(Head, LQuiet, False);
      LX := ARect.Left + 6 + FHeadWidth + 8;
    end;
    if LRow.MatchLen > 0 then
    begin
      Put(Copy(LName, 1, LRow.MatchFrom), LStrong, False);
      Put(Copy(LName, LRow.MatchFrom + 1, LRow.MatchLen), LStrong, True);
      Put(Copy(LName, LRow.MatchFrom + LRow.MatchLen + 1, MaxInt), LStrong,
        False);
    end
    else
      Put(LName, LStrong, False);
    if Detail <> '' then
      Put('  ' + Detail, LQuiet, False);
    // A project row says which unit it is from; the module tab's rows are
    // all from the one module the tab is named after. The unit's own header
    // row already IS that name - printing it twice read as a stutter.
    if (UnitName <> '') and (Kind <> 'module') then
      Put('  ' + UnitName, LQuiet, False);
    LNote := SectionNote(LEntries[LRow.Entry]);
    if LNote <> '' then
      Put('  ' + LNote, LQuiet, False);
    RestoreDC(LCanvas.Handle, LSaved);
  end;
end;

end.
