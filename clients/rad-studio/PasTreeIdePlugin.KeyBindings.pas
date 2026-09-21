unit PasTreeIdePlugin.KeyBindings;

{
  THE ONE keyboard binding of this package - every key the plugin takes
  (Ctrl+G, Ctrl+Shift+C, Ctrl+Shift+E, Ctrl+Shift+A, Ctrl+Shift+Up/Down)
  goes through a single IOTAKeyboardBinding registered once at startup and
  removed once at unload. The features do not register with the IDE at all:
  they hand this unit a key and a procedure (RegisterKey) before the wizard
  calls InitializeKeyBindings, and the binding dispatches on the shortcut it
  was handed.

  WHY ONE, NOT ONE PER FEATURE (the shape until 0.46.7 - five bindings, five
  indices, five removals). Two reasons, found in the 2026-09-21 audit of how
  the package binds keys:

  1. RemoveKeyboardBinding takes the INDEX AddKeyboardBinding returned, and
     ToolsAPI does not say whether that index survives the removal of a
     lower one. If the IDE's list shifts, five removals in anything but the
     exact reverse order remove the wrong bindings - and the ones past our
     own belong to whatever plugin loaded after us. GExperts and CnPack each
     register exactly one binding; with one there is nothing to get out of
     order.

  2. Every AddKeyboardBinding and RemoveKeyboardBinding makes the IDE rebuild
     its keymap, and the rebuild rewrites TMenuItem.ShortCut across the main
     menu - so a plugin that put its shortcut straight on a menu item (the
     older experts do) loses it each time. CnPack saves and restores every
     such shortcut around each of its own calls for exactly this reason.
     Five bindings meant ten rebuilds per IDE session; one means two. The
     save/restore itself is not done here (yet) - see clients/rad-studio/
     README.md, "Keyboard bindings".

  btPartial, like every binding this package ever had: it layers over the
  user's keymap instead of replacing it and shows on Tools > Options >
  Editor > Key Mappings as one row, where it can be moved or switched off
  as a whole. The per-feature off switches (Settings) live in the features'
  own key procedures, which answer krUnhandled to hand a key back to the
  IDE - unchanged.

  THE CONTEXT POINTER passed to AddKeyBinding is the registration entry, not
  nil: the handler is found by it, the shortcut is the fallback.

  NOT OURS TO FIX, recorded so nobody chases it again (2026-09-21, RAD Studio
  13.2): unloading ANY designtime package - this one, or Embarcadero's own
  Sample Components - makes the IDE drop the built-in Navigator's and
  Bookmarks' binding modules (ParnassusIDE370.bpl registers them at
  ProductStartup, after every package has loaded), so Ctrl+G is dead until
  the IDE restarts. Three shapes of this unit were tried against it before
  the Sample Components test settled it - RestartKeyboardServices after the
  removal, a fixed delay before the registration, a registration deferred
  until Navigator had bound Ctrl+G - and none could have helped. The README
  has the reproduction.
}

interface

uses
  System.Classes,
  Vcl.Menus,
  ToolsAPI;

type
  /// <summary>
  /// A feature's key handler - the shape of TKeyBindingProc without the
  /// "of object", so a unit can hand over a plain procedure. AKeyCode is the
  /// shortcut that fired, for a handler registered under more than one key.
  /// </summary>
  TPasKeyProc = procedure(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
    var ABindingResult: TKeyBindingResult);

/// <summary>
/// Adds AShortCut -> AProc to the keys the single binding will claim. Called
/// by each feature's Initialize BEFORE InitializeKeyBindings; a call after
/// it is recorded but reaches the IDE only if the binding is registered
/// again. A shortcut registered twice keeps the first handler.
/// </summary>
procedure RegisterKey(AShortCut: TShortCut; AProc: TPasKeyProc);

/// <summary>
/// The one AddKeyboardBinding of this package, over everything RegisterKey
/// collected. Called once, from the wizard, after every feature has
/// registered.
/// </summary>
procedure InitializeKeyBindings;

/// <summary>
/// The one RemoveKeyboardBinding, and it forgets the registrations. First in
/// the wizard's teardown: a keystroke dispatched into unloaded package code
/// is an immediate crash, so the binding goes before anything it could call.
/// </summary>
procedure FinalizeKeyBindings;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.LspSession;

type
  TKeyEntry = class
    ShortCut: TShortCut;
    Proc: TPasKeyProc;
  end;

  TPasTreeKeyBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure KeyProc(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
      var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

var
  GEntries: TObjectList<TKeyEntry> = nil;
  GKeyboardServices: IOTAKeyboardServices = nil;
  GBindingIndex: Integer = -1;
  // Set by Initialize, cleared by Finalize: a keystroke the IDE still
  // delivers while the package is unloading must do nothing.
  GAlive: Boolean = False;

function FindEntry(AShortCut: TShortCut): TKeyEntry;
var
  LEntry: TKeyEntry;
begin
  Result := nil;
  if not Assigned(GEntries) then
    Exit;
  for LEntry in GEntries do
    if LEntry.ShortCut = AShortCut then
      Exit(LEntry);
end;

procedure RegisterKey(AShortCut: TShortCut; AProc: TPasKeyProc);
var
  LEntry: TKeyEntry;
begin
  if (AShortCut = 0) or not Assigned(AProc) then
    Exit;
  if not Assigned(GEntries) then
    GEntries := TObjectList<TKeyEntry>.Create(True);
  if Assigned(FindEntry(AShortCut)) then
    Exit;
  LEntry := TKeyEntry.Create;
  LEntry.ShortCut := AShortCut;
  LEntry.Proc := AProc;
  GEntries.Add(LEntry);
end;

{ Advanced Logging only, and into the server's log only: a line read once,
  when a key did not behave after a load or an unload. At unload a server is
  up (FinalizeKeyBindings is the first teardown); at package load none is,
  and the line is simply lost - a first cut fell back to the Build tab
  there, which put "binding registered" in front of every build with the
  switch on (Alex, 2026-09-21: "drop the extra diagnostics from Build").
  Silent with the switch off. }
procedure LogAdvanced(const AMessage: string);
begin
  if AdvancedLoggingEnabled then
    LspLogToServer('keybindings: ' + AMessage);
end;

{ TPasTreeKeyBinding }

function TPasTreeKeyBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TPasTreeKeyBinding.GetDisplayName: string;
var
  LEntry: TKeyEntry;
  LKeys: string;
begin
  // The Key Mappings page is where someone goes to find out why a key
  // stopped behaving the way it used to, so the row lists every key it
  // takes - built from the registrations, so it cannot drift from them.
  LKeys := '';
  if Assigned(GEntries) then
    for LEntry in GEntries do
    begin
      if LKeys <> '' then
        LKeys := LKeys + ', ';
      LKeys := LKeys + ShortCutToText(LEntry.ShortCut);
    end;
  Result := 'PasTree (' + LKeys + ')';
end;

function TPasTreeKeyBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.KeyBinding';
end;

procedure TPasTreeKeyBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
var
  LEntry: TKeyEntry;
begin
  if not Assigned(GEntries) then
    Exit;
  // The IDE calls this again whenever it restarts its keyboard services
  // (10.3 did so on every Insert - GExperts' notes), so it must be a pure
  // function of the registrations: no state, nothing to undo.
  for LEntry in GEntries do
    ABindingServices.AddKeyBinding([LEntry.ShortCut], KeyProc, LEntry);
end;

procedure TPasTreeKeyBinding.KeyProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
var
  LEntry: TKeyEntry;
begin
  // krUnhandled for a key nobody registered - impossible by construction,
  // but the honest answer if it happens: the IDE keeps its own behaviour.
  ABindingResult := krUnhandled;
  if not GAlive then
    Exit;
  // The registration rides along as the binding context and is trusted only
  // if it IS one of ours (pointer identity, never a cast of whatever came
  // back); the shortcut is the fallback for an IDE that hands back
  // something else.
  LEntry := nil;
  if Assigned(AContext) and Assigned(GEntries) and
     (GEntries.IndexOf(TKeyEntry(AContext.Context)) >= 0) then
    LEntry := TKeyEntry(AContext.Context);
  if not Assigned(LEntry) then
    LEntry := FindEntry(AKeyCode);
  if Assigned(LEntry) then
    LEntry.Proc(AContext, AKeyCode, ABindingResult);
end;

procedure InitializeKeyBindings;
begin
  GAlive := True;
  if GBindingIndex >= 0 then
    Exit;
  if not Assigned(GEntries) or (GEntries.Count = 0) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices,
    GKeyboardServices) then
    Exit;
  GBindingIndex := GKeyboardServices.AddKeyboardBinding(
    TPasTreeKeyBinding.Create);
  // Not announced beyond the Advanced Logging line - a binding that worked
  // is not news; see the same reasoning in InitializeCodeInsight.
  LogAdvanced(Format('binding registered, %d keys, index %d',
    [GEntries.Count, GBindingIndex]));
end;

procedure FinalizeKeyBindings;
begin
  GAlive := False;
  if (GBindingIndex >= 0) and Assigned(GKeyboardServices) then
  begin
    GKeyboardServices.RemoveKeyboardBinding(GBindingIndex);
    LogAdvanced(Format('binding removed, index %d', [GBindingIndex]));
  end;
  GBindingIndex := -1;
  GKeyboardServices := nil;
  FreeAndNil(GEntries);
end;

end.
