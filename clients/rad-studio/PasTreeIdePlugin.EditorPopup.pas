unit PasTreeIdePlugin.EditorPopup;

{
  The editor's context menu on Delphi 11, where ToolsAPI has no way in.

  Delphi 12 added INTAEditorLocalMenu (IOTAEditorServices.GetEditorLocalMenu):
  a plugin registers a TActionList under a category and the IDE builds the
  menu from it. That is how PasTreeIdePlugin.Wizard's TMenuManager puts
  "Find Type Declaration", the "Find All" submenu and "Rename..." into the
  editor's right-click menu - and how it takes over the native "Find
  Declaration" item. Delphi 11 has none of it: the interface, the constants
  and GetEditorLocalMenu are all missing, and the menu is a plain VCL
  TPopupMenu component named EditorLocalMenu on each TEditWindow form, built
  in the IDE's own OnPopup. This unit is the Delphi 11 stand-in, and compiles
  to nothing on 12 and later.

  HOW IT FINDS THE MENU. Not by walking Screen.Forms at startup: an edit
  window may not exist yet, and a second one can be opened at any time. The
  editor window hook (PasTreeIdePlugin.EditorWindowHook) already learns about
  every editor control the first time it paints, so this unit asks it to be
  told too, walks from the control up to the form, and looks for a TPopupMenu
  called EditorLocalMenu there. Found once per menu; a FreeNotification
  observer forgets the menu when the IDE frees the window.

  HOW IT ADDS THE ITEMS. In a chained OnPopup, AFTER the IDE's own: the IDE
  rebuilds part of the menu on every popup, so anything inserted beforehand
  may not survive. Ours are deleted and rebuilt on each popup as well - they
  are TMenuItems bound to the SAME TActions TMenuManager registers on 12, so
  captions, OnUpdate gating and OnExecute are shared, and the only thing this
  unit knows about the menu's shape is which category names the submenu (the
  same cFindAllCategory convention the 12 path uses: the parent's category is
  the prefix of its children's).

  THE TAKEOVER IS REVERSIBLE HERE, unlike on 12. The native "Find
  Declaration" is a TMenuItem in the same menu, so it is merely hidden while
  our replacement stands in its slot, and shown again the moment the setting
  is switched off or the package unloads - no one-way door, no restart.
}

interface

uses
  Vcl.ActnList;

/// <summary>
/// Puts AActions' items into every editor's context menu, ATakeover's
/// (a single "Find Declaration" action, or nil) in the native item's place.
/// The lists stay owned by the caller and must outlive FinalizeEditorPopup.
/// No-op on Delphi 12 and later.
/// </summary>
procedure RegisterEditorPopupActions(AActions: TActionList;
  const AFindAllCategory: string; ATakeover: TActionList);

/// <summary>
/// Removes our items from every menu, restores the native item, stops
/// listening. MUST run before the action lists are freed and before the
/// BPL unloads. Safe to call twice, or without a prior Register.
/// </summary>
procedure FinalizeEditorPopup;

implementation

{$IF CompilerVersion >= 36}

procedure RegisterEditorPopupActions(AActions: TActionList;
  const AFindAllCategory: string; ATakeover: TActionList);
begin
end;

procedure FinalizeEditorPopup;
begin
end;

{$ELSE}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Actions,
  System.Generics.Collections,
  Vcl.Controls, Vcl.Forms, Vcl.Menus,
  PasTreeIdePlugin.EditorWindowHook;

const
  cMenuComponentName = 'EditorLocalMenu';
  cNativeFindDeclaration = 'Find Declaration';

type
  TEditorPopupBridge = class;

  { One hooked TPopupMenu: the chained OnPopup, our items in it, and the
    native item we may be hiding. A TComponent so FreeNotification can tell
    us when the IDE frees the window. }
  THookedMenu = class(TComponent)
  private
    FBridge: TEditorPopupBridge;
    FMenu: TPopupMenu;
    FOriginal: TNotifyEvent;
    FOurs: TObjectList<TMenuItem>;
    FNative: TMenuItem;
    procedure DoPopup(Sender: TObject);
    procedure RemoveOurs;
    function FindNative: TMenuItem;
    procedure Build;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    constructor Create(ABridge: TEditorPopupBridge; AMenu: TPopupMenu);
      reintroduce;
    destructor Destroy; override;
    property Menu: TPopupMenu read FMenu;
  end;

  TEditorPopupBridge = class
  private
    FActions: TActionList;
    FFindAllCategory: string;
    FTakeover: TActionList;
    FMenus: TObjectList<THookedMenu>;
    procedure EditorFound(const AEditor: TWinControl);
    procedure MenuGone(AMenu: THookedMenu);
  public
    constructor Create(AActions: TActionList; const AFindAllCategory: string;
      ATakeover: TActionList);
    destructor Destroy; override;
  end;

var
  GBridge: TEditorPopupBridge;

{ THookedMenu }

constructor THookedMenu.Create(ABridge: TEditorPopupBridge;
  AMenu: TPopupMenu);
begin
  inherited Create(nil);
  FBridge := ABridge;
  FMenu := AMenu;
  FOurs := TObjectList<TMenuItem>.Create(False);
  FOriginal := AMenu.OnPopup;
  AMenu.OnPopup := DoPopup;
  AMenu.FreeNotification(Self);
end;

destructor THookedMenu.Destroy;
begin
  if Assigned(FMenu) then
  begin
    RemoveOurs;
    if Assigned(FNative) then
      FNative.Visible := True;
    // Only if nobody hooked after us - otherwise we would cut them out.
    if TMethod(FMenu.OnPopup).Code = @THookedMenu.DoPopup then
      FMenu.OnPopup := FOriginal;
    FMenu.RemoveFreeNotification(Self);
  end;
  FOurs.Free;
  inherited;
end;

procedure THookedMenu.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited;
  if Operation <> opRemove then
    Exit;
  // An item freed by somebody else - the IDE's own OnPopup rebuilds the menu
  // and frees items it does not know, ours among them. Holding on to one
  // made the next RemoveOurs free it again: an invalid pointer operation in
  // TMenuItem.Destroy on the second right-click (Alex, 2026-11-02, in 11.3).
  if AComponent = FNative then
    FNative := nil;
  if AComponent is TMenuItem then
    FOurs.Remove(TMenuItem(AComponent));
  if AComponent = FMenu then
  begin
    FMenu := nil;
    FNative := nil;
    FOurs.Clear;
    FBridge.MenuGone(Self);   // frees us
  end;
end;

procedure THookedMenu.DoPopup(Sender: TObject);
begin
  if Assigned(FOriginal) then
    FOriginal(Sender);
  if Assigned(FMenu) then
    Build;
end;

{ Only the items still alive are in FOurs - see Notification. Last first, so
  a submenu's children go before their parent; freeing one removes it from
  its parent item, and from FOurs through the notification. }
procedure THookedMenu.RemoveOurs;
var
  LItem: TMenuItem;
begin
  while FOurs.Count > 0 do
  begin
    LItem := FOurs.Last;
    FOurs.Delete(FOurs.Count - 1);
    LItem.RemoveFreeNotification(Self);
    LItem.Free;
  end;
end;

{ The IDE's own item, by caption - there is no other handle to it, and the
  IDE is not localized in the editions this runs in. Hotkey marker stripped,
  so '&Find Declaration' matches too. }
function THookedMenu.FindNative: TMenuItem;
var
  LIdx: Integer;
begin
  for LIdx := 0 to FMenu.Items.Count - 1 do
    if SameText(StripHotkey(FMenu.Items[LIdx].Caption),
      cNativeFindDeclaration) then
      Exit(FMenu.Items[LIdx]);
  Result := nil;
end;

procedure THookedMenu.Build;
var
  LAt: Integer;
  LParent: TMenuItem;
  LPrefix: string;

  function NewItem(AAction: TContainedAction): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Action := AAction;
    Result.FreeNotification(Self);
    FOurs.Add(Result);
  end;

  procedure InsertTop(AItem: TMenuItem);
  begin
    FMenu.Items.Insert(LAt, AItem);
    Inc(LAt);
  end;

var
  LIdx: Integer;
  LAction: TContainedAction;
  LTakeover: TMenuItem;
begin
  RemoveOurs;
  FNative := FindNative;
  if Assigned(FNative) then
  begin
    FNative.FreeNotification(Self);
    LAt := FNative.MenuIndex + 1;
  end
  else
    LAt := 0;

  // The takeover: our "Find Declaration" where the native one stands, the
  // native one hidden - but only while the action itself is visible, which
  // is the setting (TMenuManager.OnFindDeclarationUpdate). Update() runs
  // that OnUpdate now; the menu's own InitiateActions comes later, after
  // the handle is built.
  LTakeover := nil;
  if Assigned(FBridge.FTakeover) and (FBridge.FTakeover.ActionCount > 0) then
  begin
    LAction := FBridge.FTakeover.Actions[0];
    LAction.Update;
    if LAction.Visible then
    begin
      LTakeover := NewItem(LAction);
      if Assigned(FNative) then
      begin
        FNative.Visible := False;
        FMenu.Items.Insert(FNative.MenuIndex, LTakeover);
        LAt := LTakeover.MenuIndex + 1;
      end
      else
        InsertTop(LTakeover);
    end;
  end;
  if Assigned(FNative) and not Assigned(LTakeover) then
    FNative.Visible := True;

  // Our own items, in action-list order; the submenu by the category
  // convention (see the header).
  LParent := nil;
  LPrefix := FBridge.FFindAllCategory + '.';
  for LIdx := 0 to FBridge.FActions.ActionCount - 1 do
  begin
    LAction := FBridge.FActions.Actions[LIdx];
    if SameText(LAction.Category, FBridge.FFindAllCategory) then
    begin
      LParent := NewItem(LAction);
      InsertTop(LParent);
    end
    else if Assigned(LParent) and StartsText(LPrefix, LAction.Category) then
      LParent.Add(NewItem(LAction))
    else
      InsertTop(NewItem(LAction));
  end;
end;

{ TEditorPopupBridge }

constructor TEditorPopupBridge.Create(AActions: TActionList;
  const AFindAllCategory: string; ATakeover: TActionList);
begin
  inherited Create;
  FActions := AActions;
  FFindAllCategory := AFindAllCategory;
  FTakeover := ATakeover;
  FMenus := TObjectList<THookedMenu>.Create(True);
  RegisterEditorFoundHandler(EditorFound);
end;

destructor TEditorPopupBridge.Destroy;
begin
  RegisterEditorFoundHandler(nil);
  FreeAndNil(FMenus);   // each unhooks and restores its menu
  inherited;
end;

procedure TEditorPopupBridge.EditorFound(const AEditor: TWinControl);
var
  LParent: TWinControl;
  LComponent: TComponent;
  LIdx: Integer;
begin
  // Up to the nearest form that owns an EditorLocalMenu. Not GetParentForm:
  // a docked edit window's outermost form is the dock host, and the menu is
  // on the TEditWindow in between.
  LParent := AEditor;
  while Assigned(LParent) do
  begin
    if LParent is TCustomForm then
    begin
      LComponent := LParent.FindComponent(cMenuComponentName);
      if LComponent is TPopupMenu then
      begin
        for LIdx := 0 to FMenus.Count - 1 do
          if FMenus[LIdx].Menu = LComponent then
            Exit;
        FMenus.Add(THookedMenu.Create(Self, TPopupMenu(LComponent)));
        Exit;
      end;
    end;
    LParent := LParent.Parent;
  end;
end;

procedure TEditorPopupBridge.MenuGone(AMenu: THookedMenu);
begin
  FMenus.Remove(AMenu);   // owns: frees it
end;

{ entry points }

procedure RegisterEditorPopupActions(AActions: TActionList;
  const AFindAllCategory: string; ATakeover: TActionList);
begin
  FinalizeEditorPopup;
  GBridge := TEditorPopupBridge.Create(AActions, AFindAllCategory, ATakeover);
end;

procedure FinalizeEditorPopup;
begin
  FreeAndNil(GBridge);
end;

{$IFEND}

end.
