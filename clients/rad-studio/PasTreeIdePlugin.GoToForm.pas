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
  list): the head word and the detail in the EDITOR'S syntax colours (the
  live palette the Find References rows paint with, through
  PasTreeIdePlugin.ResultRows - Alex, 2026-09-19: "the keyword colours the
  IDE editor uses, as in the Find All tabs"), the name in the editor's
  identifier colour with the matched letters in bold, and at the right edge
  three aligned quiet columns: the section (interface / implementation),
  the unit name on the project and group tabs, `:N` for a row that knows
  its line. The boxes at the bottom filter by KIND - All or a
  subset of Types, Vars/Fields, Consts, Routines, Properties, Includes;
  ticking a kind unticks All, ticking All clears the kinds, unticking the
  last kind falls back to All. Size and the boxes persist between openings.

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

  2. AN INCLUDES BOX: the `include 'Foo.inc'` landmark rows show under All
     or under the Includes box, one more box under the All-or-subset rule
     (Alex: "a filter - show or do not show the include entries"; then
     "Includes should work like all the others"). The other landmarks
     (unit, interface, uses, implementation) always show, as in the demo.

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
    FUnitWidth: Integer;      // the unit column (project/group tabs), same
    FSectionWidth: Integer;   // the section column, same
    FLineWidth: Integer;      // the `:N` column, by the longest line number
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
  ToolsAPI.Editor,
  PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.Timing;

{$R *.dfm}

const
  SET_WIDTH = 'GoToWidth';
  SET_HEIGHT = 'GoToHeight';
  SET_KINDS = 'GoToKinds';         // a bit per box; 32 = All (the default)
  SET_INCLUDES = 'GoToIncludes';   // 1 = the include rows show (default)

  ALL_KINDS: TGoToKinds = [gkType, gkVar, gkConst, gkProperty, gkRoutine];
  // Between the head column and the name. 8 had `class procedure` (bold,
  // in the editor's reserved-word style) touching the name.
  cHeadGap = 16;

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

// The section column: `interface` or `implementation` for a declaration
// that knows its section, `interface, declaration` for a routine header
// without a body (a project row - one per routine, never a body - reads the
// same). Nothing for a landmark. Until 0.46.1 this was a note in
// parentheses after the detail; Alex asked for a column of its own, the
// second from the right (2026-09-19).
function SectionColumn(const AEntry: TLspOutlineRow): string;
var
  LKind: TGoToKind;
begin
  Result := '';
  if not DeclKind(AEntry, LKind) or (AEntry.Section = '') then
    Exit;
  Result := AEntry.Section;
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
  LStart, LMeasured: Double;
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
        LStart := TimingNowMs;
        MeasureHeadColumn;
        LMeasured := TimingNowMs;
        Refilter(lbItems.ItemIndex < 0);
        TimingLogFmt('goto list landed %d: %d rows, measure %s, refilter %s',
          [Ord(LScope), Length(ARows), Ms(LMeasured - LStart),
           TimingSince(LMeasured)]);
        if not ASuccess and (AError <> '') and (APending = 0) then
          sbStatus.SimpleText := '  ' + AError;
      end;
    end);
end;

procedure TPasTreeGoToForm.MeasureHeadColumn;
var
  LEntries: TArray<TLspOutlineRow>;
  LSeen, LSeenUnit, LSeenSection: TDictionary<string, Boolean>;
  LIdx, LMaxLine: Integer;
  LText, LPrevUnit: string;
  LUnitColumn: Boolean;
begin
  // The head column: wide enough for the longest head word actually present,
  // so names line up whatever mix of `class function` and `var` the list
  // has. Measured here, where the canvas has the scaled font - and once per
  // DISTINCT word: there are a dozen of them in 100k rows, and a GDI text
  // measurement per row was a third of a second on the project list.
  //
  // Measured in the reserved-word style of the editor's palette (bold by
  // default) - head words are painted in it, and measuring them plain left
  // `class procedure` running into the name (Alex's first screenshot,
  // 2026-09-19).
  //
  // The unit and section columns the same way. The loop body is what a
  // project list of a million rows (AVImark with the library) runs once per
  // row, so NOTHING in it allocates: a first cut that built a `'unit:' +
  // Name` key and a SectionColumn string per row made the project tab take
  // seconds to open (Alex, 2026-09-19: "wild lag"). A row's UnitName is
  // the files table's string shared by every row of that file, and rows
  // arrive grouped by file, so a plain inequality against the previous
  // row's skips the dictionary for all but one row per file; the section
  // words are keyed by the raw Section and both spellings the column can
  // have are measured for each new one - a column a few pixels wider than
  // strictly needed beats a string per row. And no Scope in the loop: it
  // reads tcScope.TabIndex, a SendMessage to the tab control, 47 us a row
  // - 5.7 s over the AVImark list, traced 2026-09-19 with the same cost
  // per row on the module tab. The unit width is zero on the module tab,
  // whose rows draw no unit (lbItemsDrawItem).
  lbItems.Canvas.Font.Assign(lbItems.Font);
  lbItems.Canvas.Font.Style := EditorSyntaxStyle(atReservedWord);
  FHeadWidth := lbItems.Canvas.TextWidth('line');
  LEntries := Entries;
  LSeen := TDictionary<string, Boolean>.Create;
  LSeenUnit := TDictionary<string, Boolean>.Create;
  LSeenSection := TDictionary<string, Boolean>.Create;
  try
    for LIdx := 0 to High(LEntries) do
      if LSeen.TryAdd(LEntries[LIdx].Head, True) then
        FHeadWidth := Max(FHeadWidth,
          lbItems.Canvas.TextWidth(LEntries[LIdx].Head));
    lbItems.Canvas.Font.Style := [];
    FUnitWidth := 0;
    FSectionWidth := 0;
    LMaxLine := 0;
    LPrevUnit := '';
    LUnitColumn := Scope <> gsModule;
    for LIdx := 0 to High(LEntries) do
    begin
      LMaxLine := Max(LMaxLine, LEntries[LIdx].Line);
      if LUnitColumn and (LEntries[LIdx].UnitName <> '') and
         (LEntries[LIdx].UnitName <> LPrevUnit) then
      begin
        LPrevUnit := LEntries[LIdx].UnitName;
        if LSeenUnit.TryAdd(LPrevUnit, True) then
          FUnitWidth := Max(FUnitWidth, lbItems.Canvas.TextWidth(LPrevUnit));
      end;
      if (LEntries[LIdx].Section <> '') and
         LSeenSection.TryAdd(LEntries[LIdx].Section, True) then
      begin
        LText := LEntries[LIdx].Section;
        FSectionWidth := Max(FSectionWidth, lbItems.Canvas.TextWidth(LText));
        FSectionWidth := Max(FSectionWidth, lbItems.Canvas.TextWidth(LText));
      end;
    end;
    // One width for the whole `:N` column: the columns left of it are
    // placed from its edge, and a per-row width moved them by a digit
    // between `:99` and `:100` (Alex, 2026-09-19).
    FLineWidth := 0;
    if LMaxLine > 0 then
      FLineWidth := lbItems.Canvas.TextWidth(':' + IntToStr(LMaxLine));
  finally
    LSeenSection.Free;
    LSeenUnit.Free;
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
    // Includes is under the All rule: it cannot be on beside All.
    chkIncludes.Checked := not chkAll.Checked and
      (ReadPickerValue(SET_INCLUDES, 0) <> 0);
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
  FRows := FilterRows(LEntries, edFilter.Text, Kinds,
    chkAll.Checked or chkIncludes.Checked, LLineCount);
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
var
  LStart, LMeasured: Double;
begin
  // A tab switch is a new list: the old selection means nothing in it, the
  // module tab reselects by caret, the others start at the top.
  lbItems.ItemIndex := -1;
  FRows := nil;
  EnsureLoaded;
  UpdateCursor;
  // Timing lines under Advanced Logging: they found the 5.7 s Scope-per-row
  // loop on 2026-09-19 and stay for the next such report.
  LStart := TimingNowMs;
  MeasureHeadColumn;
  LMeasured := TimingNowMs;
  Refilter(True);
  TimingLogFmt('goto tab %d: %d rows, measure %s, refilter %s',
    [Ord(Scope), Length(Entries), Ms(LMeasured - LStart), TimingSince(LMeasured)]);
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
                 chkRoutines.Checked or chkProps.Checked or
                 chkIncludes.Checked) then
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
      chkIncludes.Checked := False;
    end
    else if not (chkTypes.Checked or chkVars.Checked or chkConsts.Checked or
                 chkRoutines.Checked or chkProps.Checked or
                 chkIncludes.Checked) then
      chkAll.Checked := True;   // nothing else is on: All cannot go off
  finally
    FLoadingState := False;
  end;
  Refilter(False);
end;

// Includes is one more box under the All-or-subset rule since 0.46.3 (Alex,
// 2026-09-19: "Includes should work like all the others - ticking it
// unticks All"). Until then it was a landmark switch outside the rule, and
// the one box that behaved differently. All shows the include rows too.
procedure TPasTreeGoToForm.IncludesChanged(Sender: TObject);
begin
  FilterChanged(Sender);
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

procedure TPasTreeGoToForm.lbItemsDrawItem(AControl: TWinControl;
  AIndex: Integer; ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LRow: TGoToRow;
  LEntries: TArray<TLspOutlineRow>;
  LQuiet, LStrong, LIdent, LKeyword, LPreproc, LForce: TColor;
  LNameStyle: TFontStyles;
  LX, LY, LLineRight, LSaved: Integer;
  LName, LNote: string;

  procedure Put(const AText: string; AColor: TColor; AStyle: TFontStyles);
  begin
    if AText = '' then
      Exit;
    LCanvas.Font.Color := AColor;
    LCanvas.Font.Style := AStyle;
    LCanvas.TextOut(LX, LY, AText);
    Inc(LX, LCanvas.TextWidth(AText));
  end;

  // One right-aligned column of width AWidth ending at LLineRight - 6,
  // clipped to itself; LLineRight moves left past it and a gap. The text
  // ends at the column's right edge, like the `:N` numbers do (Alex,
  // 2026-09-19: "the unit against the right edge, the section against the
  // unit") - a text wider than the cap loses its start, not its end.
  procedure PutColumn(const AText: string; AWidth: Integer);
  begin
    if (AText = '') or (AWidth <= 0) then
      Exit;
    AWidth := Min(AWidth, lbItems.ClientWidth div 3);
    LCanvas.Font.Style := [];
    LX := LLineRight - 6 - LCanvas.TextWidth(AText);
    LSaved := SaveDC(LCanvas.Handle);
    IntersectClipRect(LCanvas.Handle, LLineRight - 6 - AWidth, ARect.Top,
      LLineRight - 6, ARect.Bottom);
    Put(AText, LQuiet, []);
    RestoreDC(LCanvas.Handle, LSaved);
    // RestoreDC puts back the DC's text colour from before SaveDC, but the
    // canvas still believes its Font is selected - so the next Put with the
    // SAME Font.Color changes nothing and paints in whatever the DC holds.
    // On the project tab no `:N` precedes the columns, and the section came
    // out in the list's default black while the unit was grey (2026-09-19).
    LCanvas.Refresh;
    LLineRight := LLineRight - 6 - AWidth - 8;
  end;

  // A run in the editor's syntax colours (PasTreeIdePlugin.ResultRows, the
  // same palette the Find References rows paint with). Font.Style is the
  // last run's afterwards; every Put sets its own.
  procedure PutSyntax(const AText: string);
  begin
    PaintSyntaxText(LCanvas, LX, LY, AText, LQuiet, LForce);
  end;

begin
  LCanvas := lbItems.Canvas;
  LCanvas.FillRect(ARect);
  if (AIndex < 0) or (AIndex > High(FRows)) then
    Exit;
  LRow := FRows[AIndex];
  // A selected row keeps the highlight text colour for everything: it is
  // the only colour guaranteed readable on the highlight background (the
  // list's, a saturated blue - not the editor's own selection colour that
  // the Messages panel rows keep their palette on).
  if odSelected in AState then
  begin
    LQuiet := LCanvas.Font.Color;
    LStrong := LCanvas.Font.Color;
    LIdent := LStrong;
    LKeyword := LStrong;
    LPreproc := LStrong;
    LForce := LStrong;
  end
  else
  begin
    LQuiet := FQuiet;
    LStrong := FStrong;
    // The name column is an identifier and a landmark is a reserved word,
    // in the editor's live colours for those classes; the head word and
    // the detail go through the tokenizer (PutSyntax). `include` is neither -
    // there is no such keyword and the path is not a string literal - it is
    // the directive colour, the one the editor paints the whole
    // `{$INCLUDE ...}` line with.
    LIdent := EditorSyntaxColor(atIdentifier, LStrong);
    LKeyword := EditorSyntaxColor(atReservedWord, LStrong);
    LPreproc := EditorSyntaxColor(atPreproc, LStrong);
    LForce := clNone;
  end;
  LX := ARect.Left + 6;
  LY := ARect.Top + (ARect.Height - LCanvas.TextHeight('Xg')) div 2;
  if LRow.Kind = grLine then
  begin
    Put('line', LQuiet, []);
    LX := ARect.Left + 6 + FHeadWidth + cHeadGap;
    Put(IntToStr(LRow.LineNo), LStrong, [fsBold]);
    Exit;
  end;
  LEntries := Entries;
  if LRow.Entry > High(LEntries) then
    Exit;
  with LEntries[LRow.Entry] do
  begin
    // The right-hand columns, drawn FIRST, and the row text is then clipped
    // short of them, so a long detail runs out under a column instead of
    // over it. From the edge inwards:
    //  - the LINE, `:N`, for a row that knows its line (the module tab; a
    //    project row has no position until it is chosen);
    //  - the UNIT, on the project and group tabs (Alex, 2026-09-19: "the
    //    module name in a separate column, as the line number is for the
    //    module tab"). The module tab's rows are all from the one module
    //    the tab is named after, and the unit's own header row already IS
    //    that name - so neither gets the column;
    //  - the SECTION - interface / implementation, `, declaration` for a
    //    bodiless routine header (Alex, the same day: "one more column for
    //    the extra information, second from the right").
    // Each as wide as its longest text on the tab (MeasureHeadColumn),
    // capped at a third of the list so one absurd name does not eat the
    // row (PutColumn).
    LLineRight := ARect.Right;
    if Line > 0 then
    begin
      LNote := ':' + IntToStr(Line);
      LCanvas.Font.Style := [];
      LX := ARect.Right - 6 - LCanvas.TextWidth(LNote);
      Put(LNote, LQuiet, []);
      LLineRight := ARect.Right - 6 - FLineWidth - 8;
    end;
    if (Kind <> 'module') and (Scope <> gsModule) then
      PutColumn(UnitName, FUnitWidth);
    PutColumn(SectionColumn(LEntries[LRow.Entry]), FSectionWidth);
    LX := ARect.Left + 6;
    LSaved := SaveDC(LCanvas.Handle);
    IntersectClipRect(LCanvas.Handle, ARect.Left, ARect.Top, LLineRight,
      ARect.Bottom);
    // The name column is `Owner.Name` - or, for a landmark, the head word
    // itself, which then takes the head column and the match highlight, in
    // the reserved-word colour AND style (bold by default - `interface`
    // and `uses` came out plain when only the colour was taken).
    LName := NameColumn(LEntries[LRow.Entry]);
    LNameStyle := [];
    if Kind = 'include' then
    begin
      Put(Head, LPreproc, []);
      LX := ARect.Left + 6 + FHeadWidth + cHeadGap;
      LIdent := LPreproc;
    end
    else if Name <> '' then
    begin
      PutSyntax(Head);
      LX := ARect.Left + 6 + FHeadWidth + cHeadGap;
    end
    else
    begin
      LIdent := LKeyword;
      LNameStyle := EditorSyntaxStyle(atReservedWord);
    end;
    if LRow.MatchLen > 0 then
    begin
      Put(Copy(LName, 1, LRow.MatchFrom), LIdent, LNameStyle);
      Put(Copy(LName, LRow.MatchFrom + 1, LRow.MatchLen), LIdent,
        LNameStyle + [fsBold]);
      Put(Copy(LName, LRow.MatchFrom + LRow.MatchLen + 1, MaxInt), LIdent,
        LNameStyle);
    end
    else
      Put(LName, LIdent, LNameStyle);
    if Detail <> '' then
      PutSyntax('  ' + Detail);
    RestoreDC(LCanvas.Handle, LSaved);
  end;
end;

end.
