unit PasTreeIdePlugin.Outline;

{
  The Structure pane outline: unit-level declarations and type members of
  the ACTIVE source file, from the server's textDocument/documentSymbol,
  shown in the IDE's own Structure pane under a private StructureType
  ('PasTree.Outline' - deliberately NOT SourceCodeStructureType, so this
  never contends with whatever the IDE's own source provider registers).

  THE IDE's OWN ICONS (0.76.0). The pane's image list already holds the
  Pascal structure icons; coreide exports where they start,
  Parsernodes.ImageIndexOffset, and both the classic structure (TNode.
  get_ImageIndex) and DelphiLSP's outline (TDocumentSymbolNode.
  get_ImageIndex) answer that plus a fixed offset - DelphiLSP's by the LSP
  SymbolKind, through the table copied into NativeIconOffset below (read off
  IDELSP370.bpl, 2026-10-23; identical export in 22.0, 23.0, 37.0 and Win64).
  So a node here is drawn exactly like DelphiLSP's, in the IDE's theme. The
  badges this unit drew itself before (a TImageList through AddImageList)
  never showed in the themed IDE - the reason the outline was withdrawn on
  2026-09-01. Not exported, or not set (-1): no icon, as before.

  Trigger: INTAEditServicesNotifier.EditorViewActivated - the moment a
  source tab becomes active, its outline is requested (async, like every
  LSP question here) and the pane's context replaced when the answer lands.
  And after every analysis of the shown file (the diagnostics-changed
  listener, 0.76.1): until then a type added to the file - a new unsaved
  unit, measured 2026-10-23 - never reached the pane until the tab was
  activated again. A rebuild whose symbols are the same as the pane's is
  skipped (OutlineSignature), and a node the user collapsed stays collapsed
  across rebuilds (GCollapsed).
  Double-clicking a node navigates history-aware.

  LIVE-RUN CAVEAT, recorded up front: whether the IDE's own providers
  re-take the pane on some later event (focus bounces, its own parser
  finishing) is exactly the kind of behavior only a live session shows. If
  the pane flickers between ours and the IDE's, the fix direction is
  event-choice, not architecture.

  The IDispatch plumbing looks odd but is required: every StructureViewAPI
  interface is IDispatch-based with safecall methods (the SPEC's own
  cross-cutting hazard note) - the stubs answer E_NOTIMPL and the real
  members are ordinary safecall implementations.
}

interface

procedure InitializeOutline;
procedure FinalizeOutline;

/// <summary>
/// The IDE selected (True) or deselected (False) PasTree as the Insight
/// Provider: the top editor's outline into the pane, or ours out of it so
/// DelphiLSP's takes its place.
/// </summary>
procedure OutlineProviderChanged(AActive: Boolean);

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  System.Generics.Collections,
  Winapi.Windows,
  Vcl.Forms,
  Vcl.Menus,
  DockForm,
  ToolsAPI,
  StructureViewAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.OutlineRows,   // TLspOutlineRow
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings,
  // CoreIdeExport, and the Errors folder a new context drops
  PasTreeIdePlugin.NativeErrorInsight,
  PasTreeIdePlugin.CodeInsight,   // PasTreeProviderSelected
  PasTreeIdePlugin.GotoDeclaration;

const
  cOutlineStructureType = 'PasTree.Outline';

var
  GNotifierIndex: Integer = -1;
  GAlive: Boolean = False;
  // coreide's Parsernodes.ImageIndexOffset - where the Pascal structure icons
  // start in the pane's image list. Looked up once; nil = not exported.
  GIconBase: PInteger = nil;
  GIconBaseLooked: Boolean = False;
  // The context currently installed in the pane - kept so a stale async
  // answer (tab switched again before the outline arrived) can be told from
  // the current one by file path.
  GCurrentFile: string;
  // Whether the pane is holding a context of OURS right now. Not cosmetic
  // bookkeeping: it is what FinalizeOutline needs in order to take it back.
  GContextInstalled: Boolean = False;
  // What the installed context shows, as OutlineSignature - an analysis
  // that changed nothing the outline shows must not rebuild the pane.
  GInstalledSignature: string;
  // Node key (file and captions down to the node) -> the expanded state the
  // user left it in. A rebuild would otherwise put every node back to its
  // default.
  GExpanded: TDictionary<string, Boolean> = nil;
  GListener: Integer = 0;

type
  // Common IDispatch stub base: StructureViewAPI interfaces descend from
  // IDispatch, but nothing here is automation-scripted - E_NOTIMPL is the
  // honest answer for all four.
  TPasDispatchObject = class(TInterfacedObject, IDispatch)
  public
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer;
      out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo,
      ArgErr: Pointer): HResult; stdcall;
  end;

  TPasOutlineNode = class(TPasDispatchObject, IOTAStructureNode,
    IOTANavigableStructureNode)
  private
    FCaption: string;
    FFilePath: string;
    FRow, FCol: Integer;
    // File + the captions down to this node - its identity across rebuilds,
    // for GCollapsed.
    FKey: string;
    // The icon's offset from Parsernodes.ImageIndexOffset (NativeIconOffset),
    // -1 for none. A folder (cIconFolder) shows open while expanded.
    FIcon: Integer;
    FChildren: TList<IOTAStructureNode>;
    // Raw, not counted: parent holds child interfaces, so a counted
    // back-reference would be a cycle no refcount ever collects.
    FParent: Pointer;
  public
    constructor Create(const ACaption, AFilePath: string; ARow, ACol: Integer);
    destructor Destroy; override;
    { IOTAStructureNode }
    function AddChildNode(const ANode: IOTAStructureNode;
      Index: Integer = -1): Integer; safecall;
    function Get_Caption: WideString; safecall;
    function Get_ChildCount: Integer; safecall;
    function Get_Child(Index: Integer): IOTAStructureNode; safecall;
    function Get_Expanded: WordBool; safecall;
    procedure Set_Expanded(Value: WordBool); safecall;
    function Get_Focused: WordBool; safecall;
    procedure Set_Focused(Value: WordBool); safecall;
    function Get_Hint: WideString; safecall;
    function Get_ImageIndex: Integer; safecall;
    function Get_Name: WideString; safecall;
    function Get_Parent: IOTAStructureNode; safecall;
    function Get_Selected: WordBool; safecall;
    procedure Set_Selected(Value: WordBool); safecall;
    function Get_StateIndex: Integer; safecall;
    function Get_Data: IntPtr; safecall;
    procedure Set_Data(Value: IntPtr); safecall;
    procedure RemoveChildNode(Index: Integer); safecall;
    { IOTANavigableStructureNode }
    function Navigate: Boolean; safecall;
  private
    FExpanded: WordBool;
    FFocused: WordBool;
    FSelected: WordBool;
    FData: IntPtr;
  end;

  TPasOutlineContext = class(TPasDispatchObject, IOTAStructureContext,
    IOTAStructureContext110)
  private
    FFilePath: string;
    FRoots: TList<IOTAStructureNode>;
  public
    constructor Create(const AFilePath: string);
    destructor Destroy; override;
    { IOTAStructureContext }
    function Get_ContextIdent: WideString; safecall;
    function Get_StructureType: WideString; safecall;
    function Get_ViewOptions: Integer; safecall;
    function Get_RootNodeCount: Integer; safecall;
    function GetRootStructureNode(Index: Integer): IOTAStructureNode; safecall;
    procedure NodeEdited(const Node: IOTAStructureNode); safecall;
    procedure NodeFocused(const Node: IOTAStructureNode); safecall;
    procedure NodeSelected(const Node: IOTAStructureNode); safecall;
    procedure DefaultNodeAction(const Node: IOTAStructureNode); safecall;
    function SameContext(const AContext: IOTAStructureContext): WordBool;
      safecall;
    procedure InitPopupMenu(const Node: IOTAStructureNode;
      const PopupMenu: IOTAStructureNodeMenuItem); safecall;
    procedure AddRootNode(const ANode: IOTAStructureNode;
      Index: Integer); safecall;
    procedure RemoveRootNode(const ANode: IOTAStructureNode); safecall;
    { IOTAStructureContext110 }
    procedure ContextActivated; safecall;
  end;

  TOutlineEditNotifier = class(TNotifierObject, INTAEditServicesNotifier)
  public
    procedure WindowShow(const EditWindow: INTAEditWindow;
      Show, LoadedFromDesktop: Boolean);
    procedure WindowNotification(const EditWindow: INTAEditWindow;
      Operation: TOperation);
    procedure WindowActivated(const EditWindow: INTAEditWindow);
    procedure WindowCommand(const EditWindow: INTAEditWindow;
      Command, Param: Integer; var Handled: Boolean);
    procedure EditorViewActivated(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure EditorViewModified(const EditWindow: INTAEditWindow;
      const EditView: IOTAEditView);
    procedure DockFormVisibleChanged(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormUpdated(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
    procedure DockFormRefresh(const EditWindow: INTAEditWindow;
      DockForm: TDockableForm);
  end;

{ TPasDispatchObject }

function TPasDispatchObject.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := E_NOTIMPL;
end;

function TPasDispatchObject.GetTypeInfo(Index, LocaleID: Integer;
  out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TPasDispatchObject.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TPasDispatchObject.Invoke(DispID: Integer; const IID: TGUID;
  LocaleID: Integer; Flags: Word; var Params; VarResult, ExcepInfo,
  ArgErr: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

{ TPasOutlineNode }

constructor TPasOutlineNode.Create(const ACaption, AFilePath: string;
  ARow, ACol: Integer);
begin
  inherited Create;
  FCaption := ACaption;
  FFilePath := AFilePath;
  FRow := ARow;
  FCol := ACol;
  FIcon := -1;
  FChildren := TList<IOTAStructureNode>.Create;
  FExpanded := True;
end;

destructor TPasOutlineNode.Destroy;
begin
  FChildren.Free;
  inherited;
end;

function TPasOutlineNode.AddChildNode(const ANode: IOTAStructureNode;
  Index: Integer): Integer;
var
  LObj: TObject;
begin
  if (Index < 0) or (Index >= FChildren.Count) then
    Result := FChildren.Add(ANode)
  else
  begin
    FChildren.Insert(Index, ANode);
    Result := Index;
  end;
  LObj := ANode as TObject;
  if LObj is TPasOutlineNode then   // back-link our own nodes only
    TPasOutlineNode(LObj).FParent := Pointer(Self);
end;

function TPasOutlineNode.Get_Caption: WideString;
begin
  Result := FCaption;
end;

function TPasOutlineNode.Get_ChildCount: Integer;
begin
  Result := FChildren.Count;
end;

function TPasOutlineNode.Get_Child(Index: Integer): IOTAStructureNode;
begin
  if (Index >= 0) and (Index < FChildren.Count) then
    Result := FChildren[Index]
  else
    Result := nil;
end;

function TPasOutlineNode.Get_Expanded: WordBool;
begin
  Result := FExpanded;
end;

procedure TPasOutlineNode.Set_Expanded(Value: WordBool);
begin
  FExpanded := Value;
  if (FKey <> '') and (GExpanded <> nil) then
    GExpanded.AddOrSetValue(FKey, Value);
end;

{ Sets the node's identity and its expanded state: the user's, else the
  default. }
procedure SetNodeKey(ANode: TPasOutlineNode; const AKey: string;
  ADefaultExpanded: Boolean);
var
  LExpanded: Boolean;
begin
  ANode.FKey := LowerCase(AKey);
  if (GExpanded <> nil) and GExpanded.TryGetValue(ANode.FKey, LExpanded) then
    ANode.FExpanded := LExpanded
  else
    ANode.FExpanded := ADefaultExpanded;
end;

function TPasOutlineNode.Get_Focused: WordBool;
begin
  Result := FFocused;
end;

procedure TPasOutlineNode.Set_Focused(Value: WordBool);
begin
  FFocused := Value;
end;

function TPasOutlineNode.Get_Hint: WideString;
begin
  Result := FCaption;
end;

const
  // Offsets from Parsernodes.ImageIndexOffset, as DelphiLSP uses them.
  cIconFolder = 8;       // 9 is the same folder open
  cIconFolderOpen = 9;

function IconBase: Integer;
{$IFDEF WIN64}
const
  cName = '_ZN11Parsernodes16ImageIndexOffsetE';
{$ELSE}
const
  cName = '@Parsernodes@ImageIndexOffset';
{$ENDIF}
begin
  if not GIconBaseLooked then
  begin
    GIconBaseLooked := True;
    GIconBase := CoreIdeExport(cName);
  end;
  if GIconBase = nil then
    Result := -1
  else
    Result := GIconBase^;
end;

function TPasOutlineNode.Get_ImageIndex: Integer;
var
  LBase: Integer;
begin
  LBase := IconBase;
  if (FIcon < 0) or (LBase < 0) then
    Exit(-1);
  if (FIcon = cIconFolder) and FExpanded then
    Result := LBase + cIconFolderOpen
  else
    Result := LBase + FIcon;
end;

function TPasOutlineNode.Get_Name: WideString;
begin
  Result := FCaption;
end;

function TPasOutlineNode.Get_Parent: IOTAStructureNode;
begin
  if FParent <> nil then
    Result := TPasOutlineNode(FParent)
  else
    Result := nil;
end;

function TPasOutlineNode.Get_Selected: WordBool;
begin
  Result := FSelected;
end;

procedure TPasOutlineNode.Set_Selected(Value: WordBool);
begin
  FSelected := Value;
end;

function TPasOutlineNode.Get_StateIndex: Integer;
begin
  Result := -1;
end;

function TPasOutlineNode.Get_Data: IntPtr;
begin
  Result := FData;
end;

procedure TPasOutlineNode.Set_Data(Value: IntPtr);
begin
  // Reserved by the structure view services (the interface's own warning) -
  // stored opaquely, never read by this unit.
  FData := Value;
end;

procedure TPasOutlineNode.RemoveChildNode(Index: Integer);
begin
  if (Index >= 0) and (Index < FChildren.Count) then
    FChildren.Delete(Index);
end;

function TPasOutlineNode.Navigate: Boolean;
begin
  // Group headers (Types, Routines, ...) carry no position - Row 0 - and
  // navigating them would jump to nowhere useful.
  if FRow >= 1 then
    NavigateHistoryAware(FFilePath, FRow, FCol);
  Result := True;
end;

{ TPasOutlineContext }

constructor TPasOutlineContext.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath := AFilePath;
  FRoots := TList<IOTAStructureNode>.Create;
end;

destructor TPasOutlineContext.Destroy;
begin
  FRoots.Free;
  inherited;
end;

function TPasOutlineContext.Get_ContextIdent: WideString;
begin
  Result := FFilePath;
end;

function TPasOutlineContext.Get_StructureType: WideString;
begin
  Result := cOutlineStructureType;
end;

function TPasOutlineContext.Get_ViewOptions: Integer;
begin
  Result := 0;
end;

function TPasOutlineContext.Get_RootNodeCount: Integer;
begin
  Result := FRoots.Count;
end;

function TPasOutlineContext.GetRootStructureNode(
  Index: Integer): IOTAStructureNode;
begin
  if (Index >= 0) and (Index < FRoots.Count) then
    Result := FRoots[Index]
  else
    Result := nil;
end;

procedure TPasOutlineContext.NodeEdited(const Node: IOTAStructureNode);
begin
end;

procedure TPasOutlineContext.NodeFocused(const Node: IOTAStructureNode);
begin
end;

procedure TPasOutlineContext.NodeSelected(const Node: IOTAStructureNode);
begin
end;

procedure TPasOutlineContext.DefaultNodeAction(const Node: IOTAStructureNode);
var
  LNavigable: IOTANavigableStructureNode;
begin
  // Double-click / Enter on a node - jump to its declaration.
  if Supports(Node, IOTANavigableStructureNode, LNavigable) then
    LNavigable.Navigate;
end;

function TPasOutlineContext.SameContext(
  const AContext: IOTAStructureContext): WordBool;
begin
  Result := (AContext <> nil) and
    (AContext.StructureType = cOutlineStructureType) and
    SameText(AContext.ContextIdent, FFilePath);
end;

procedure TPasOutlineContext.InitPopupMenu(const Node: IOTAStructureNode;
  const PopupMenu: IOTAStructureNodeMenuItem);
begin
end;

procedure TPasOutlineContext.AddRootNode(const ANode: IOTAStructureNode;
  Index: Integer);
begin
  if (Index < 0) or (Index >= FRoots.Count) then
    FRoots.Add(ANode)
  else
    FRoots.Insert(Index, ANode);
end;

procedure TPasOutlineContext.RemoveRootNode(const ANode: IOTAStructureNode);
begin
  FRoots.Remove(ANode);
end;

procedure TPasOutlineContext.ContextActivated;
begin
end;

{ ---------------------------------------------------------------------------
  Building and installing the outline
  --------------------------------------------------------------------------- }

{ THE TREE, AS DelphiLSP's PANE LAYS IT OUT (0.76.4, Alex's screenshots of
  both, 2026-10-23): one 'Structure' root; under it the sections in source
  order - interface, implementation, initialization, finalization, a
  program's main begin - and in a program, which has none, the uses clause
  and the begin straight under the root; under a section its uses folder
  (each unit a row) and its declarations; a type's members under the type.
  Built from pastree/outline (scope module, with the units of every uses
  clause) rather than documentSymbol, which has no sections, no uses and no
  signatures. Only the root and the interface start expanded - DelphiLSP's
  defaults; what the user opens or closes is kept (GExpanded).

  Icons are DelphiLSP's offsets (IDELSP370.bpl, TDocumentSymbolNode.
  get_ImageIndex, by LSP SymbolKind): 0 file, 1 field/variable/constant,
  2 class, 3 interface, 4 property, 6 method, 7 function, 8 folder (9 open),
  10 other type, 11 constructor. A plain procedure is a Function there too. }
const
  cIconFile = 0;
  cIconVar = 1;
  cIconClass = 2;
  cIconInterface = 3;
  cIconProperty = 4;
  cIconMethod = 6;
  cIconFunction = 7;
  cIconType = 10;
  cIconConstructor = 11;

function RowIcon(const ARow: TLspOutlineRow): Integer;
var
  LDetail: string;
begin
  if ARow.Kind = 'type' then
  begin
    LDetail := LowerCase(Trim(ARow.Detail));
    if (LDetail.StartsWith('= class') and not LDetail.StartsWith('= class of'))
      or LDetail.StartsWith('= packed class') then
      Result := cIconClass
    else if LDetail.StartsWith('= interface')
      or LDetail.StartsWith('= dispinterface') then
      Result := cIconInterface
    else
      Result := cIconType;
  end
  else if ARow.Kind = 'routine' then
  begin
    if Pos('constructor', ARow.Head) > 0 then
      Result := cIconConstructor
    else if ARow.Owner <> '' then
      Result := cIconMethod
    else
      Result := cIconFunction;
  end
  else if ARow.Kind = 'property' then
    Result := cIconProperty
  else if (ARow.Kind = 'var') or (ARow.Kind = 'const') then
    Result := cIconVar
  else
    Result := -1;
end;

{ What a row reads as in the pane: a type by its name, everything else by
  its name and detail - `Refill(const A: Integer)`, `Dlg: TMedHistoryDlg` -
  and a method body by its owner too (`TFoo.Bar(...)`), since in the
  implementation it stands apart from its class. }
function RowCaption(const ARow: TLspOutlineRow): string;
begin
  Result := ARow.Name;
  if ARow.IsImpl and (ARow.Owner <> '') then
    Result := ARow.Owner + '.' + Result;
  if ARow.Kind <> 'type' then
    Result := Result + ARow.Detail;
end;

var
  GViewMissingLogged: Boolean = False;

function NewNode(const AFilePath, ACaption: string; ARow, ACol,
  AIcon: Integer; const AParentKey: string;
  ADefaultExpanded: Boolean): TPasOutlineNode;
begin
  Result := TPasOutlineNode.Create(ACaption, AFilePath, ARow, ACol);
  Result.FIcon := AIcon;
  SetNodeKey(Result, AParentKey + '/' + ACaption, ADefaultExpanded);
end;

procedure BuildTree(const AContext: TPasOutlineContext;
  const AFilePath: string; const ARows: TArray<TLspOutlineRow>);
var
  LTop, LRoot, LSection, LUses, LNode, LParent: TPasOutlineNode;
  LTypes: TDictionary<string, TPasOutlineNode>;
  LRow: TLspOutlineRow;
  LKey: string;
begin
  // The pane does not draw a context's root nodes, only what is under them
  // (0.76.4 showed no 'Structure', and the Types/Routines groups before it
  // never showed either) - so 'Structure' sits under one root of its own.
  LTop := NewNode(AFilePath, '', 0, 0, -1, LowerCase(AFilePath), True);
  AContext.AddRootNode(LTop, -1);
  LRoot := NewNode(AFilePath, 'Structure', 0, 0, cIconFile, LTop.FKey, True);
  LTop.AddChildNode(LRoot, -1);
  LSection := LRoot;
  LUses := nil;
  LTypes := TDictionary<string, TPasOutlineNode>.Create;
  try
    for LRow in ARows do
    begin
      // An include's rows are its file's, not this pane's.
      if not SameText(LRow.FilePath, AFilePath) then
        Continue;
      if LRow.Kind = 'section' then
      begin
        LSection := NewNode(AFilePath, LRow.Head, LRow.Line, LRow.Col,
          cIconFolder, LRoot.FKey, LRow.Head = 'interface');
        LRoot.AddChildNode(LSection, -1);
        LUses := nil;
      end
      else if LRow.Kind = 'uses' then
      begin
        if LRow.Name = '' then
        begin
          LUses := NewNode(AFilePath, LRow.Head, LRow.Line, LRow.Col,
            cIconFolder, LSection.FKey, False);
          LSection.AddChildNode(LUses, -1);
        end
        else if LUses <> nil then
          LUses.AddChildNode(NewNode(AFilePath, LRow.Name, LRow.Line,
            LRow.Col, cIconFile, LUses.FKey, False), -1);
      end
      else if RowIcon(LRow) >= 0 then
      begin
        // A member goes under its type, a method body stays in its section -
        // and so does a member whose type is not in the pane (its type sits
        // in an include, or is named differently). TryGetValue sets its out
        // parameter to nil on a miss, so never hand it LParent itself: that
        // was an access violation on AVImark (2026-10-24).
        LParent := LSection;
        if (LRow.Owner <> '') and not LRow.IsImpl
          and LTypes.TryGetValue(LowerCase(LRow.Owner), LNode) then
          LParent := LNode;
        LNode := NewNode(AFilePath, RowCaption(LRow), LRow.Line, LRow.Col,
          RowIcon(LRow), LParent.FKey, False);
        LParent.AddChildNode(LNode, -1);
        if LRow.Kind = 'type' then
        begin
          if LRow.Owner <> '' then
            LKey := LRow.Owner + '.' + LRow.Name
          else
            LKey := LRow.Name;
          LTypes.AddOrSetValue(LowerCase(LKey), LNode);
        end;
      end;
      // module and include rows: the root stands for the module, and an
      // include is not a declaration.
    end;
  finally
    LTypes.Free;
  end;
end;

{ Everything the pane shows of ARows, as one string. }
function OutlineSignature(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>): string;
var
  LSB: TStringBuilder;
  LRow: TLspOutlineRow;
begin
  LSB := TStringBuilder.Create;
  try
    LSB.Append(LowerCase(AFilePath)).Append(#0);
    for LRow in ARows do
      LSB.Append(LRow.Kind).Append(#1).Append(LRow.Head).Append(#1)
        .Append(LRow.Owner).Append(#1).Append(LRow.Name).Append(#1)
        .Append(LRow.Detail).Append(#1).Append(Ord(LRow.IsImpl)).Append(#1)
        .Append(LRow.Line).Append(#1).Append(LRow.Col).Append(#2);
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure InstallOutline(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>);
var
  LView: IOTAStructureView;
  LContext: TPasOutlineContext;
  LMessages: IOTAMessageServices;
  LSignature: string;
begin
  if not Supports(BorlandIDEServices, IOTAStructureView, LView) then
  begin
    // Part of what this feature's first live run establishes: whether the
    // structure view is reachable as a service at all. Logged once.
    if not GViewMissingLogged then
    begin
      GViewMissingLogged := True;
      if Supports(BorlandIDEServices, IOTAMessageServices, LMessages) then
        LMessages.AddTitleMessage('[pastree] Structure outline: '
          + 'IOTAStructureView is not a BorlandIDEServices service here - '
          + 'the outline stays off.');
    end;
    Exit;
  end;
  LSignature := OutlineSignature(AFilePath, ARows);
  if GContextInstalled and (LSignature = GInstalledSignature) then
    Exit;
  LContext := TPasOutlineContext.Create(AFilePath);
  BuildTree(LContext, AFilePath, ARows);
  LView.SetStructureContext(LContext);
  GContextInstalled := True;
  GInstalledSignature := LSignature;
  // The new context took the Errors folder with the old one.
  NativeErrorInsightRestoreStructure(AFilePath);
end;

procedure RequestOutline(const AFilePath: string);
begin
  GCurrentFile := AFilePath;
  LspOutlineStructure(AFilePath,
    procedure(ASuccess: Boolean; const ARows: TArray<TLspOutlineRow>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading
      // A stale answer for a tab the user has already left must not clobber
      // the outline of the one they are looking at.
      if not SameText(GCurrentFile, AFilePath) then
        Exit;
      if ASuccess then
        InstallOutline(AFilePath, ARows);
      // Failures stay quiet: "no server yet" is the normal state right
      // after the IDE starts, and the pane simply keeps what it shows.
    end);
end;

{ TOutlineEditNotifier }

procedure TOutlineEditNotifier.EditorViewActivated(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  if not Assigned(EditView) then
    Exit;
  // THE PANE IS THE PROVIDER'S (0.76.3, Alex): with PasTree selected
  // nothing else fills it - DelphiLSP is handed no unit - and with RAD Studio
  // selected DelphiLSP does. So the Insight Provider choice is this
  // feature's switch, and not pushing IS leaving the pane to DelphiLSP.
  if not PasTreeProviderSelected then
    Exit;
  if not IsPascalSourceFile(EditView.Buffer.FileName) then
    Exit;
  // Always rebuilt here: another tab, or the IDE's own provider, may have
  // had the pane since, so "the same symbols" proves nothing about it.
  GInstalledSignature := '';
  RequestOutline(EditView.Buffer.FileName);
end;

procedure TOutlineEditNotifier.WindowShow(const EditWindow: INTAEditWindow;
  Show, LoadedFromDesktop: Boolean);
begin
end;

procedure TOutlineEditNotifier.WindowNotification(
  const EditWindow: INTAEditWindow; Operation: TOperation);
begin
end;

procedure TOutlineEditNotifier.WindowActivated(
  const EditWindow: INTAEditWindow);
begin
end;

procedure TOutlineEditNotifier.WindowCommand(const EditWindow: INTAEditWindow;
  Command, Param: Integer; var Handled: Boolean);
begin
end;

procedure TOutlineEditNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
end;

procedure TOutlineEditNotifier.DockFormVisibleChanged(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TOutlineEditNotifier.DockFormUpdated(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TOutlineEditNotifier.DockFormRefresh(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure OutlineProviderChanged(AActive: Boolean);
var
  LEditor: IOTAEditorServices;
  LView: IOTAStructureView;
  LTop: IOTAEditBuffer;
begin
  if not GAlive then
    Exit;
  GInstalledSignature := '';
  if AActive then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices, LEditor) then
      LTop := LEditor.TopBuffer;
    if Assigned(LTop) and IsPascalSourceFile(LTop.FileName) then
      RequestOutline(LTop.FileName);
  end
  else if GContextInstalled then
  begin
    GContextInstalled := False;
    GCurrentFile := '';
    if Supports(BorlandIDEServices, IOTAStructureView, LView) then
      LView.SetStructureContext(nil);
  end;
end;

{ An analysis landed: the shown file's outline again, if it changed. }
procedure OnDiagnosticsChanged(const APath: string);
begin
  if GAlive and PasTreeProviderSelected and (GCurrentFile <> '')
    and SameText(APath, GCurrentFile) then
    RequestOutline(GCurrentFile);
end;

procedure InitializeOutline;
var
  LServices: IOTAEditorServices80;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
    Exit;
  GNotifierIndex := LServices.AddNotifier(TOutlineEditNotifier.Create);
  GAlive := True;
  GExpanded := TDictionary<string, Boolean>.Create;
  GListener := LspAddDiagnosticsChangedListener(OnDiagnosticsChanged);
end;

procedure FinalizeOutline;
var
  LServices: IOTAEditorServices80;
  LView: IOTAStructureView;
begin
  GAlive := False;
  LspRemoveDiagnosticsChangedListener(GListener);
  GListener := 0;
  { TAKE THE CONTEXT BACK BEFORE THE CODE BEHIND IT GOES AWAY. This was
    missing, and it is the same dangling-code hazard the rest of the plugin
    deregisters everything to avoid: TPasOutlineContext and every
    TPasOutlineNode under it implement IOTAStructureContext /
    IOTAStructureNode in THIS BPL. With a .pas tab active - so our outline
    shown - and the package uninstalled from a running IDE, the Structure pane
    goes on holding those interfaces; the next repaint, the next click on a
    node, or merely the final _Release of them executes unloaded code.
 }
  if GContextInstalled then
  begin
    GContextInstalled := False;
    if not Application.Terminated and
       Supports(BorlandIDEServices, IOTAStructureView, LView) then
      try
        LView.SetStructureContext(nil);
      except
        // Silent by the same rule as FinalizeFindReferencesMessageGroup: this
        // runs during unload, there is nowhere left to report to, and an
        // exception escaping here would take the IDE down over a cleanup.
      end;
  end;
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
  GInstalledSignature := '';
  FreeAndNil(GExpanded);
end;

end.
