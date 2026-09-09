unit PasTreeIdePlugin.EditorWindowHook;

{
  THE PRE-37.0 EDITOR INPUT PATH: mouse and keyboard events for RAD Studio
  versions whose ToolsAPI does not offer them.

  WHY IT EXISTS. Two shipped features need editor input the old ToolsAPI
  cannot give:

    - Ctrl+Click navigation (PasTreeIdePlugin.GotoDeclaration) must SUPPRESS
      the native click. The `var Handled` that allows this arrived with the
      *Ex mouse events in ToolsAPI 37.0 (RAD Studio 13); before that
      INTACodeEditorEvents has EditorMouseDown/Up with no way to say
      "handled", so subscribing there would navigate IN ADDITION to the
      IDE's own Ctrl+Click - two resolvers, two history entries.
    - Block completion (PasTreeIdePlugin.BlockClose) needs Enter key-up.
      Before 37.0 the editor notifier has NO keyboard events at all -
      cevKeyboardEvents and OnEditorKeyUp simply do not exist - and an
      IOTAKeyboardBinding is not a substitute: it CLAIMS its keys, which is
      how the first build of that feature left Enter dead in the whole
      editor (see that unit's header).

  Nothing else in the old ToolsAPI substitutes: IOTAKeyBindingServices binds
  keys and menu commands but never mouse chords, and the Code Insight
  provider slot is all-or-nothing, so it cannot take one gesture and leave
  the rest of Code Insight to DelphiLSP. So the gesture is claimed one level
  down, in the VCL: the editor control is a TWinControl, its WindowProc is a
  plain chainable field, and messages are intercepted there. Same technique
  GExperts and DDevExtensions use, for the same missing API.

  THE WHOLE UNIT IS EMPTY ON 37.0 AND LATER, keyed on
  Declared(TEditorMouseExEvent) - the API's presence, not a version number.
  Callers register unconditionally and get a no-op where the real events
  exist; each caller keeps using the ToolsAPI events there.

  WHERE THE CONTROLS COME FROM. ToolsAPI has no "editor created" event, so
  hooking is lazy: every editor event that carries a TWinControl feeds
  EnsureHooked. Paint is the one that matters - a visible editor repaints
  before it can be typed in, including one reached by Ctrl+Tab with the
  mouse never moving, which mouse events alone would miss (that hole would
  have been silent: block completion dead for keyboard-only tab switching).
  GetKnownEditors would enumerate them directly but returns a TList whose
  ownership the API does not state; paint needs no such bet.

  THREE THINGS THAT ARE SILENT WHEN WRONG:

    - A hooked control can be destroyed while the package lives (closing an
      editor window). WM_NCDESTROY marks the hook dead; nothing may touch
      the control afterwards.
    - Every hook MUST be released before the BPL unloads (Finalize...) or
      the next mouse message in that editor calls into unloaded package
      code - the AV class this project has already hit through package
      hot-reload.
    - Restoring is only correct while the chain is still ours: if another
      plugin hooked the same control after us, its WindowProc is what sits
      in the property, and writing ours back would drop it. So the restore
      is conditional (see TEditorWindowHook.Destroy).

  ONE SUBSCRIBER PER GESTURE, deliberately: there is exactly one feature
  behind each, and a list would invite ordering questions about who claims a
  click first that the ToolsAPI path does not have either.
}

interface

uses
  Vcl.Controls, ToolsAPI.Editor;

type
  /// <summary>
  /// Asked on every plain Ctrl+left click, before anything is suppressed.
  /// True means the click is the subscriber's: down and up are both
  /// swallowed and OnClick fires on the up. Asked identically on down and
  /// up, so the two can never disagree about who owns the click.
  /// </summary>
  TEditorClickClaim = function: Boolean of object;

  /// <summary>Client coordinates within the editor control.</summary>
  TEditorClickEvent = procedure(const AEditor: TWinControl;
    AX, AY: Integer) of object;

  /// <summary>
  /// Observer only, and after the fact: the message is passed to the editor
  /// first, so by the time this runs the buffer already holds what the user
  /// sees. AKey is a virtual key code (VK_RETURN etc.).
  /// </summary>
  TEditorKeyUpEvent = procedure(const AEditor: TWinControl;
    AKey: Word) of object;

/// <summary>
/// Claims plain Ctrl+left clicks in every editor. No-op on ToolsAPI 37.0+,
/// where the caller uses OnEditorMouseDownEx/UpEx instead.
/// </summary>
procedure RegisterCtrlClickHandler(const AClaims: TEditorClickClaim;
  const AHandler: TEditorClickEvent);

/// <summary>
/// Observes key-up in every editor. No-op on ToolsAPI 37.0+, where the
/// caller uses OnEditorKeyUp instead.
/// </summary>
procedure RegisterKeyUpHandler(const AHandler: TEditorKeyUpEvent);

/// <summary>
/// Releases every hook and the editor notifier. MUST be called before the
/// BPL unloads - see this unit's header. Safe to call when nothing was ever
/// registered, and safe to call twice.
/// </summary>
procedure FinalizeEditorWindowHooks;

implementation

{$IF Declared(TEditorMouseExEvent)}

{ ToolsAPI 37.0 and later: the real events exist, so this unit does nothing
  at all. The registrations stay callable so callers need no conditional. }

procedure RegisterCtrlClickHandler(const AClaims: TEditorClickClaim;
  const AHandler: TEditorClickEvent);
begin
end;

procedure RegisterKeyUpHandler(const AHandler: TEditorKeyUpEvent);
begin
end;

procedure FinalizeEditorWindowHooks;
begin
end;

{$ELSE}

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.UITypes,
  System.Generics.Collections,
  ToolsAPI;

type
  TEditorHookRegistry = class;

  TEditorWindowHook = class
  private
    FRegistry: TEditorHookRegistry;
    FControl: TWinControl;
    FOriginal: TWndMethod;
    FDead: Boolean;
    procedure HookedWndProc(var AMessage: TMessage);
  public
    constructor Create(ARegistry: TEditorHookRegistry;
      const AControl: TWinControl);
    destructor Destroy; override;
    property Control: TWinControl read FControl;
    property Dead: Boolean read FDead;
  end;

  // AllowedEvents can only be customized by overriding it - there is no
  // event property for it on TNTACodeEditorNotifier, unlike the callbacks
  // (the official KeyboardMouse Events Demo subclasses for the same reason).
  // Mouse and paint events only: both merely tell us WHICH control to hook,
  // and paint is what makes a keyboard-only editor discoverable.
  TEditorDiscoveryNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  end;

  TEditorHookRegistry = class
  private
    FServices: INTACodeEditorServices;
    FNotifier: TEditorDiscoveryNotifier;
    FNotifierIndex: Integer;
    FHooks: TObjectList<TEditorWindowHook>;
    FLastHooked: TWinControl;
    FClaims: TEditorClickClaim;
    FOnClick: TEditorClickEvent;
    FOnKeyUp: TEditorKeyUpEvent;
    procedure DoBeginPaint(const AEditor: TWinControl;
      const AForceFullRepaint: Boolean);
    procedure DoMouseMove(const AEditor: TWinControl; AShift: TShiftState;
      AX, AY: Integer);
    procedure EnsureHooked(const AEditor: TWinControl);
    function ClaimsClick(AWParam: WPARAM): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  GRegistry: TEditorHookRegistry;

{ TEditorWindowHook }

constructor TEditorWindowHook.Create(ARegistry: TEditorHookRegistry;
  const AControl: TWinControl);
begin
  inherited Create;
  FRegistry := ARegistry;
  FControl := AControl;
  FOriginal := AControl.WindowProc;
  AControl.WindowProc := HookedWndProc;
end;

destructor TEditorWindowHook.Destroy;
var
  LMine: TWndMethod;
  LCurrent, LOurs: TMethod;
begin
  if not FDead and Assigned(FControl) then
  begin
    LMine := HookedWndProc;
    LCurrent := TMethod(FControl.WindowProc);
    LOurs := TMethod(LMine);
    if (LCurrent.Code = LOurs.Code) and (LCurrent.Data = LOurs.Data) then
      FControl.WindowProc := FOriginal;
  end;
  inherited;
end;

procedure TEditorWindowHook.HookedWndProc(var AMessage: TMessage);
begin
  case AMessage.Msg of
    WM_LBUTTONDOWN, WM_LBUTTONUP:
      if FRegistry.ClaimsClick(AMessage.WParam) then
      begin
        // Swallowed, not forwarded: this is the stand-in for the 37.0
        // `Handled := True`. The down goes nowhere (it would start a
        // selection drag), the up runs the handler. Suppression is
        // unconditional once the chord is claimed, even if the handler
        // resolves nothing - the point is to stop the native path, not to
        // fall back to it on a miss.
        if AMessage.Msg = WM_LBUTTONUP then
          FRegistry.FOnClick(FControl,
            SmallInt(AMessage.LParamLo), SmallInt(AMessage.LParamHi));
        AMessage.Result := 0;
        Exit;
      end;
    WM_KEYUP:
      // Observer: the editor sees the key first and this cannot swallow it,
      // matching what OnEditorKeyUp gives on 37.0.
      if Assigned(FRegistry.FOnKeyUp) then
      begin
        FOriginal(AMessage);
        if not FDead then
          FRegistry.FOnKeyUp(FControl, Word(AMessage.WParam));
        Exit;
      end;
    WM_NCDESTROY:
      begin
        // The control is going away under us. Let it finish, then mark the
        // hook dead so nothing here dereferences FControl again and the
        // registry can sweep it (see EnsureHooked).
        FOriginal(AMessage);
        FDead := True;
        FControl := nil;
        Exit;
      end;
  end;
  FOriginal(AMessage);
end;

{ TEditorDiscoveryNotifier }

function TEditorDiscoveryNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevMouseEvents, cevBeginEndPaintEvents];
end;

{ TEditorHookRegistry }

constructor TEditorHookRegistry.Create;
begin
  inherited;
  FNotifierIndex := -1;
  FHooks := TObjectList<TEditorWindowHook>.Create(True);
  if not Supports(BorlandIDEServices, INTACodeEditorServices, FServices) then
    Exit;
  FNotifier := TEditorDiscoveryNotifier.Create;
  FNotifier.OnEditorBeginPaint := DoBeginPaint;
  FNotifier.OnEditorMouseMove := DoMouseMove;
  FNotifierIndex := FServices.AddEditorEventsNotifier(FNotifier);
end;

destructor TEditorHookRegistry.Destroy;
begin
  // Order matters: stop discovering first, so nothing can hook a fresh
  // control between the sweep and the unload.
  if Assigned(FServices) and (FNotifierIndex >= 0) then
    FServices.RemoveEditorEventsNotifier(FNotifierIndex);
  FreeAndNil(FHooks);
  inherited;
end;

procedure TEditorHookRegistry.DoBeginPaint(const AEditor: TWinControl;
  const AForceFullRepaint: Boolean);
begin
  EnsureHooked(AEditor);
end;

procedure TEditorHookRegistry.DoMouseMove(const AEditor: TWinControl;
  AShift: TShiftState; AX, AY: Integer);
begin
  EnsureHooked(AEditor);
end;

procedure TEditorHookRegistry.EnsureHooked(const AEditor: TWinControl);
var
  LIndex: Integer;
begin
  // Called from paint, so the common case must cost nothing: the same
  // control paints many times in a row.
  if not Assigned(AEditor) or (AEditor = FLastHooked) then
    Exit;
  for LIndex := FHooks.Count - 1 downto 0 do
    if FHooks[LIndex].Dead then
      FHooks.Delete(LIndex)
    else if FHooks[LIndex].Control = AEditor then
    begin
      FLastHooked := AEditor;
      Exit;
    end;
  FHooks.Add(TEditorWindowHook.Create(Self, AEditor));
  FLastHooked := AEditor;
end;

/// <summary>
/// The chord test. WM_LBUTTON* carries MK_CONTROL and MK_SHIFT in wParam
/// but has no Alt bit at all, so Alt comes from GetKeyState - without it,
/// Ctrl+Alt+Click would look like plain Ctrl+Click and be claimed, silently
/// taking that chord from the IDE or another plugin. Exactly Ctrl, nothing
/// else.
/// </summary>
function TEditorHookRegistry.ClaimsClick(AWParam: WPARAM): Boolean;
begin
  Result := Assigned(FOnClick) and Assigned(FClaims)
    and ((AWParam and MK_CONTROL) <> 0)
    and ((AWParam and MK_SHIFT) = 0)
    and (GetKeyState(VK_MENU) >= 0)
    and FClaims;
end;

{ registration }

function Registry: TEditorHookRegistry;
begin
  if not Assigned(GRegistry) then
    GRegistry := TEditorHookRegistry.Create;
  Result := GRegistry;
end;

procedure RegisterCtrlClickHandler(const AClaims: TEditorClickClaim;
  const AHandler: TEditorClickEvent);
begin
  // Passing nil is how a feature withdraws before its object is freed (the
  // registry holds method pointers into it). Withdrawing must never be what
  // brings the registry into existence.
  if not Assigned(AHandler) and not Assigned(GRegistry) then
    Exit;
  Registry.FClaims := AClaims;
  Registry.FOnClick := AHandler;
end;

procedure RegisterKeyUpHandler(const AHandler: TEditorKeyUpEvent);
begin
  if not Assigned(AHandler) and not Assigned(GRegistry) then
    Exit;
  Registry.FOnKeyUp := AHandler;
end;

procedure FinalizeEditorWindowHooks;
begin
  FreeAndNil(GRegistry);
end;

{$ENDIF}

end.
