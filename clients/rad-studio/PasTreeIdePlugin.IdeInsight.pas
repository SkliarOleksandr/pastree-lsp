unit PasTreeIdePlugin.IdeInsight;

{
  Project-wide symbol search in the IDE Insight dialog (Ctrl+. / the search
  box): a "PasTree symbols" category filled with every unit-level symbol and
  struct member of the analyzed closure. Activating a result jumps to its
  declaration through the plugin's history-aware navigation.

  HOW THE DIALOG WORKS, and why this unit caches: IOTAIDEInsightNotifier.
  RequestingItems fires when the dialog is INVOKED - once, with no filter
  text - and the dialog then searches/filters the provided items itself as
  the user types. There is no per-keystroke callback to answer lazily, so a
  round trip inside RequestingItems is impossible (it would block the main
  thread, the one thing this plugin never does). Instead the symbol INDEX
  is prefetched asynchronously (workspace/symbol with an empty query - the
  server caps at 20k and logs any drop) and RequestingItems adds items from
  whatever the cache holds. Consequence, documented rather than hidden: the
  FIRST dialog open after the IDE starts may show no PasTree symbols yet -
  opening it kicks the prefetch, and every later open has the index. The
  prefetch also refreshes on a throttle so the index follows the analysis.

  Items are non-Sticky: per the interface contract the dialog releases them
  when it closes, so nothing here outlives an open dialog except the plain
  record cache.
}

interface

procedure InitializeIdeInsight;

{ Unregister before the BPL unloads - same standing rule as every notifier
  in this plugin. }
procedure FinalizeIdeInsight;

implementation

uses
  System.SysUtils,
  System.Types,
  Winapi.Windows,
  Vcl.Graphics,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.GotoDeclaration;

var
  GCache: TArray<TLspWorkspaceSymbol>;
  GFetchRunning: Boolean = False;
  GLastFetchTick: UInt64 = 0;
  GNotifierIndex: Integer = -1;
  GAlive: Boolean = False;

const
  // How stale the index may get before a dialog open re-fetches it. The
  // fetch is one request answered from the finished analysis, so this is
  // about churn, not cost.
  cRefreshMs = 60000;

type
  TPasInsightItem = class(TInterfacedObject, INTAIDEInsightItem270,
    INTAIDEInsightItem280, INTAIDEInsightItem290, INTAIDEInsightItem)
  private
    FSymbol: TLspWorkspaceSymbol;
  public
    constructor Create(const ASymbol: TLspWorkspaceSymbol);
    { INTAIDEInsightItem270 }
    function DrawText(Canvas: TCanvas; Rect: TRect; var DrawDefault: Boolean;
      DoDraw: Boolean = True): Integer;
    procedure Execute;
    function GetDescription: string;
    function GetDescriptionSearchable: Boolean;
    function GetGlyph(Bitmap: TBitmap): Boolean;
    function GetSticky: Boolean;
    function GetTitle: string;
    function GetVisible: Boolean;
    procedure Update;
    { INTAIDEInsightItem280 }
    function SetGlyph(const AImageName: string;
      const AGlyph: TGraphicArray): Boolean;
    { INTAIDEInsightItem290 }
    function GetGlyphArray(var AImageName: string;
      var AGlyphArray: TGraphicArray): Boolean;
  end;

  TPasInsightNotifier = class(TInterfacedObject, IOTAIDEInsightNotifier,
    IOTAIDEInsightNotifier150)
  public
    { IOTAIDEInsightNotifier }
    procedure RequestingItems(IDEInsightService: IOTAIDEInsightService;
      Context: IInterface);
    { IOTAIDEInsightNotifier150 }
    procedure ReleaseItems(Context: IInterface);
  end;

{ TPasInsightItem }

constructor TPasInsightItem.Create(const ASymbol: TLspWorkspaceSymbol);
begin
  inherited Create;
  FSymbol := ASymbol;
end;

function TPasInsightItem.DrawText(Canvas: TCanvas; Rect: TRect;
  var DrawDefault: Boolean; DoDraw: Boolean): Integer;
begin
  DrawDefault := True;   // the dialog's own rendering is fine
  Result := 0;
end;

procedure TPasInsightItem.Execute;
begin
  // Called when the user picks this result and the dialog accepts - jump,
  // history-aware, so Alt+Left comes back here like from any other jump.
  NavigateHistoryAware(FSymbol.FilePath, FSymbol.Row, FSymbol.Col);
end;

function TPasInsightItem.GetDescription: string;
begin
  // 'function - PasLsp.Server.pas' - the kind plus where it lives. Not
  // searchable: matching should be on the NAME the user is typing, not on
  // every symbol of a unit whose name happens to match.
  if FSymbol.KindWord <> '' then
    Result := FSymbol.KindWord + ' - ' + FSymbol.Container
  else
    Result := FSymbol.Container;
end;

function TPasInsightItem.GetDescriptionSearchable: Boolean;
begin
  Result := False;
end;

function TPasInsightItem.GetGlyph(Bitmap: TBitmap): Boolean;
begin
  Result := False;
end;

function TPasInsightItem.GetSticky: Boolean;
begin
  Result := False;   // released by the dialog on close; re-added per open
end;

function TPasInsightItem.GetTitle: string;
begin
  Result := FSymbol.Name;
end;

function TPasInsightItem.GetVisible: Boolean;
begin
  Result := True;
end;

procedure TPasInsightItem.Update;
begin
end;

function TPasInsightItem.SetGlyph(const AImageName: string;
  const AGlyph: TGraphicArray): Boolean;
begin
  Result := False;
end;

function TPasInsightItem.GetGlyphArray(var AImageName: string;
  var AGlyphArray: TGraphicArray): Boolean;
begin
  Result := False;
end;

{ ---------------------------------------------------------------------------
  The prefetched index
  --------------------------------------------------------------------------- }

procedure KickPrefetch;
begin
  if GFetchRunning then
    Exit;
  if (GLastFetchTick <> 0) and
     (GetTickCount64 - GLastFetchTick < cRefreshMs) and
     (Length(GCache) > 0) then
    Exit;
  GFetchRunning := True;
  LspWorkspaceSymbols('',
    procedure(ASuccess: Boolean;
      const ASymbols: TArray<TLspWorkspaceSymbol>; const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - globals may be finalized
      GFetchRunning := False;
      GLastFetchTick := GetTickCount64;
      if ASuccess then
        GCache := ASymbols;
      // Failures stay quiet: the prefetch fires from a dialog open and at
      // package load, and "no server yet" is the normal state for both.
    end);
end;

{ TPasInsightNotifier }

procedure TPasInsightNotifier.RequestingItems(
  IDEInsightService: IOTAIDEInsightService; Context: IInterface);
var
  LIdx: Integer;
begin
  // Whatever the index holds NOW populates this open; the refresh runs for
  // the next one (see the unit header for why a round trip here is
  // impossible).
  for LIdx := 0 to High(GCache) do
    IDEInsightService.AddItem(TPasInsightItem.Create(GCache[LIdx]),
      'PasTree symbols');
  KickPrefetch;
end;

procedure TPasInsightNotifier.ReleaseItems(Context: IInterface);
begin
  // Non-sticky items are the dialog's to release; nothing retained here.
end;

procedure InitializeIdeInsight;
var
  LService: IOTAIDEInsightService;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, IOTAIDEInsightService, LService) then
    Exit;
  GNotifierIndex := LService.AddNotifier(TPasInsightNotifier.Create);
  GAlive := True;
  // Warm the index at load: by the first Ctrl+. the analysis has usually
  // finished and the fetch with it. Silent when no project is open yet -
  // the next dialog open retries.
  KickPrefetch;
end;

procedure FinalizeIdeInsight;
var
  LService: IOTAIDEInsightService;
begin
  GAlive := False;
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAIDEInsightService, LService) then
      LService.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
  GCache := nil;
end;

end.
