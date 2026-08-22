unit PasTreeIdePlugin.Outline;

{
  The Structure pane outline: unit-level declarations and type members of
  the ACTIVE source file, from the server's textDocument/documentSymbol,
  shown in the IDE's own Structure pane under a private StructureType
  ('PasTree.Outline' - deliberately NOT SourceCodeStructureType, so this
  never contends with whatever the IDE's own source provider registers).

  Trigger: INTAEditServicesNotifier.EditorViewActivated - the moment a
  source tab becomes active, its outline is requested (async, like every
  LSP question here) and the pane's context replaced when the answer lands.
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

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Vcl.Menus,
  DockForm,
  ToolsAPI,
  StructureViewAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.GotoDeclaration;

const
  cOutlineStructureType = 'PasTree.Outline';

var
  GNotifierIndex: Integer = -1;
  GAlive: Boolean = False;
  // The context currently installed in the pane - kept so a stale async
  // answer (tab switched again before the outline arrived) can be told from
  // the current one by file path.
  GCurrentFile: string;

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

function TPasOutlineNode.Get_ImageIndex: Integer;
begin
  Result := -1;   // no image list registered (v1)
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

function BuildNode(const AFilePath: string;
  const ASymbol: TLspDocSymbol): IOTAStructureNode;
var
  LCaption: string;
  LIdx: Integer;
begin
  LCaption := ASymbol.Name;
  if ASymbol.KindWord <> '' then
    LCaption := LCaption + ' (' + ASymbol.KindWord + ')';
  Result := TPasOutlineNode.Create(LCaption, AFilePath, ASymbol.Row,
    ASymbol.Col);
  for LIdx := 0 to High(ASymbol.Children) do
    Result.AddChildNode(BuildNode(AFilePath, ASymbol.Children[LIdx]), -1);
end;

var
  GViewMissingLogged: Boolean = False;

procedure InstallOutline(const AFilePath: string;
  const ASymbols: TArray<TLspDocSymbol>);
var
  LView: IOTAStructureView;
  LContext: TPasOutlineContext;
  LIdx: Integer;
  LMessages: IOTAMessageServices;
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
  LContext := TPasOutlineContext.Create(AFilePath);
  for LIdx := 0 to High(ASymbols) do
    LContext.AddRootNode(BuildNode(AFilePath, ASymbols[LIdx]), -1);
  LView.SetStructureContext(LContext);
end;

procedure RequestOutline(const AFilePath: string);
begin
  GCurrentFile := AFilePath;
  LspDocumentSymbols(AFilePath,
    procedure(ASuccess: Boolean; const ASymbols: TArray<TLspDocSymbol>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading
      // A stale answer for a tab the user has already left must not clobber
      // the outline of the one they are looking at.
      if not SameText(GCurrentFile, AFilePath) then
        Exit;
      if ASuccess then
        InstallOutline(AFilePath, ASymbols);
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
  if not IsPascalSourceFile(EditView.Buffer.FileName) then
    Exit;
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
end;

procedure FinalizeOutline;
var
  LServices: IOTAEditorServices80;
begin
  GAlive := False;
  if GNotifierIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTAEditorServices80, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := -1;
  end;
end;

end.
