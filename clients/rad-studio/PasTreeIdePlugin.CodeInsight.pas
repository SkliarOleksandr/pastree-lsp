unit PasTreeIdePlugin.CodeInsight;

{
  The Code Insight manager - since phase C (2026-08-22, COMPLETION.md) THE
  navigation and insight path of this plugin: the mouse-notifier Ctrl+Click
  override and the editor-menu takeover are deleted, and when the user
  selects "PasTree" as the Insight Provider the IDE routes completion,
  browse (Ctrl+Click), parameter insight and tooltips here.

  ALWAYS REGISTERED (2026-08-21, revising COMPLETION.md's original
  environment-variable gate at the user's call: an uninstall is recovery
  enough for a dev-stage plugin, and the gate was one more thing to explain).
  The real safety is the IDE's own: registration alone takes nothing over -
  the manager only ANSWERS once the user selects "PasTree" under
  Tools > Options > Editor > Source > Insight Provider, and switching back
  is the same combobox. The registration is logged to the Build tab with
  that instruction, since selecting the provider is the step people miss.

  WHAT IT ANSWERS TODAY, honestly and nothing more:
    - Code completion  -> textDocument/completion via LspCompletion (the
      server answers from PasTree itself since 2026-08-21; the interim
      keyword provider is gone, and this unit did not have to change for it).
    - Browse (Ctrl+Click when WE are the provider) -> AsyncGotoDefinitionEx
      over the same LspDefinition path the current override uses - but
      returning the target to the IDE, which then navigates and keeps history
      itself. That is the migration seam.
    - Hint text (Tooltip Insight) -> AsyncGetHintText over the server's
      hover, stripped to tooltip plain text by the session - only while
      Tooltip symbol insight is OFF; with it on, our own popup is the hint
      and this one is declined (OfferHintInsight).
    - Parameter insight (Ctrl+Shift+Space, '(' and ',') ->
      AsyncInvokeParameterCodeInsight over textDocument/signatureHelp; the
      answer feeds both IOTACodeInsightParameterList views, and the active
      argument is recounted server-side per request (ParamIndex answers -1 =
      reinvoke) so it can never drift from the text.

  The sync-interface methods (SetFilter/FindIdent on the symbol list, called
  per keystroke while the viewer is open) answer from the cached array the
  async answer filled - the constraint clients/rad-studio/SPEC.md documents:
  those calls may never round-trip.

  Registered via IOTACodeInsightServices.AddCodeInsightManager, which takes
  the SYNC interface (IOTACodeInsightManager); the async shape is offered as
  a companion the IDE queries with Supports. The sync Invoke methods
  therefore exist but decline - if a bring-up run shows the IDE using them
  instead of the async path, that finding goes here and the answer is a
  cached-list fallback, not blocking the main thread.

  COORDINATES: AsyncInvoke* hand over (ALine, ACharIndex) with no
  documentation of base, and the first live bring-up (2026-08-21) proved the
  guessed convention wrong - the parameters did not point at the text under
  the caret, so the server saw an empty prefix and answered all 64 keywords.
  Completion reads the CARET instead (EditPosition.Row/Column, IDE convention
  by definition); the second bring-up run confirmed that end to end - viewer,
  prefix filtering, accept-replaces-prefix all behave. Goto-definition still
  trusts the parameters, because a browse can be invoked at a click point
  rather than the caret; it is unexercised until the mouse-notifier override
  retires (phase C), and off-by-one there is the first thing to check.
}

interface

procedure InitializeCodeInsight;

{ Unregister before the BPL unloads - ordered BEFORE FinalizeLspSession in
  TIDEWizard.Destroy, because a viewer callback dispatched into this unit
  after the session died would ask questions nothing can answer. }
procedure FinalizeCodeInsight;

/// <summary>
/// Logs to the Build tab, once per session, if the Tools > Options > Editor >
/// Source "Insight Provider" combobox does not name PasTree - completion,
/// browse and parameter insight all silently come from whichever other
/// provider is selected otherwise, and nothing else says so. Called after
/// every project open (TProjectOpenNotifier), which is a real point in time
/// to ask, unlike registration (InitializeCodeInsight runs before the user
/// could have chosen anything).
/// </summary>
procedure CheckInsightProviderSelected;

/// <summary>
/// Whether the manager registered here is the one the IDE is currently
/// asking - i.e. whether the user has selected "PasTree" in the Tools >
/// Options > Editor > Source "Insight Provider" combobox.
///
/// The Ctrl+Click override in PasTreeIdePlugin.GotoDeclaration stands down
/// when this is True: with PasTree selected, the IDE's own click chain ends
/// in AsyncGotoDefinitionEx here, so it already resolves through PasTree,
/// draws the Ctrl+hover underline and keeps history itself. Intercepting the
/// mouse as well would resolve the same position twice and push the history
/// entry twice.
/// </summary>
function PasTreeIsActiveInsightProvider: Boolean;

/// <summary>
/// Makes the IDE's Insight Provider agree with the settings' Code Insight
/// Manager choice (PasTreeInsightManagerEnabled), so the user never has to
/// find the combobox in Tools > Options > Editor > Source.
///
/// THROUGH THE ENVIRONMENT OPTION `InsightManager` (IOTAEnvironmentOptions.
/// Values), the live switch DeclarationInformation and ErrorInsightLevel are
/// flipped with. Measured on 37.0 (2026-10-13, AVImark): a string option
/// (tkLString) holding the selected manager's IDString - "Borland.CodeInsight.
/// LSP.Pascal" for DelphiLSP. A write reads back at once and is written
/// through to the registry (`Insight Manager` under Editor\Source Options\
/// Borland.EditOptions.Pascal) at once; the IDE's CURRENT manager follows
/// lazily, at the editor's next Code Insight turn - 1 s after the write it
/// still answered DelphiLSP, at 5 s PasTree, both ways. So "the current
/// manager is not ours right after the switch" is not a failure.
///
/// PasTree: registers the manager (InitializeCodeInsight) if it is not yet,
/// remembers the IDE's value under our key (SavedInsightManager) BEFORE writing
/// ours. RAD Studio: puts the remembered value back over OUR value only - a
/// provider picked in Tools > Options since is the user's. The manager stays
/// registered until the IDE restarts: unregistering one the IDE may still hold
/// as current is a crash risk nothing here needs to take. Called after the
/// dialog saves and once at package load; a value that does not read yet is
/// asked again by SyncInsightManagerChoice. FinalizeCodeInsight puts the IDE's
/// value back before unregistering, the marker kept for the next start.
/// </summary>
procedure ApplyInsightManagerChoice;

/// <summary>
/// Retries an ApplyInsightManagerChoice whose option did not read, and hands
/// its log line to the LSP log once a session can take it. Cheap when there
/// is nothing to do; called on every editor mouse move, beside
/// SyncErrorInsightChoice.
/// </summary>
procedure SyncInsightManagerChoice;

implementation

uses
  System.SysUtils,
  System.Types,
  System.UITypes,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.StrUtils,
  System.Math,
  System.Variants,
  System.Win.Registry,
  Winapi.Windows,
  Winapi.Messages,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Themes,
  ToolsAPI,
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.DcuNames,
  PasTreeIdePlugin.DcuSource,
  PasTreeIdePlugin.ResultRows,   // PaintSyntaxTextTyped, EditorSyntaxColor
  PasTreeIdePlugin.Settings;   // AdvancedLoggingEnabled, the type colour

{ RE-ENTRANCY GUARD FOR THE IDE CALLBACKS. LspSession invokes a request's
  callback SYNCHRONOUSLY when the request cannot even be issued (no server
  exe, no active project, a send that fails outright). Passed straight
  through, the IDE would be called back with an operation id BEFORE the
  AsyncInvoke* call that created it has returned that id - re-entrant into
  the IDE's own bookkeeping, which has no reason to tolerate it. So every
  async entry point sets AInInvoke=True for the duration of the issuing call:
  a callback that fires inside that window is deferred one main-thread queue
  pump (ForceQueue), landing after the id has been returned; the normal
  asynchronous path is not delayed by anything. }
{ Whether this manager answers the IDE's hint (Tooltip Insight) at all. Not
  while Tooltip symbol insight is ours: that hint is our own popup, shown
  under every provider, and the IDE's hint is quenched through
  DeclarationInformation - but only DelphiLSP's. With THIS manager selected
  the IDE asked it as well, and its plain-text answer ("constant -
  Winapi.Windows.pas:25534") came up under our popup (Alex, 2026-10-13, the
  first run with the manager selected since 0.51). }
function OfferHintInsight: Boolean;
begin
  Result := not TooltipSymbolInsightEnabled;
end;

procedure DeliverToIde(AInInvoke: Boolean; const ADeliver: TProc);
begin
  if AInInvoke then
    TThread.ForceQueue(nil,
      procedure
      begin
        ADeliver();
      end)
  else
    ADeliver();
end;

const
  // GetIDString - and the value the environment option InsightManager is
  // given to select this manager (ApplyInsightManagerChoice).
  cOurManagerId = 'PasTreeIdePlugin.CodeInsight';

var
  // The teardown guard for async closures. A completion callback captures
  // the manager (Self) to fill FSymbols; if the LSP session dies during
  // package unload it FAILS every pending request synchronously, and by then
  // the manager may already be gone - the dangling-Self flavour of the AV
  // this project keeps a standing rule about. Checked FIRST in every closure
  // that touches manager state, before any Self dereference.
  GAlive: Boolean = False;
  // The IOTAHelpInsight readout runs once per session - see ProbeHelpInsight.
  GHelpInsightProbed: Boolean = False;
  // Edge-trigger for the "PasTree is not selected" line - see SetEnabled.
  GInsightWarned: Boolean = False;

{ ---------------------------------------------------------------------------
  The symbol list: one async answer, filtered synchronously ever after
  --------------------------------------------------------------------------- }

type
  { The IDE's own "Code completion filtering" choices (Options > Editor >
    Language > Insight Options), which the native list obeys and ours did not
    read (Alex, 2026-10-19). Environment options, named as coreide370 names
    them; a name the IDE does not answer keeps the IDE's default. }
  TInsightFilterOptions = record
    Contained: Boolean;     // CodeInsightContainedSymbols - "contain filter"
    StartsFirst: Boolean;   // CodeInsightFilterStartsWith - prefix matches first
    Shortest: Boolean;      // CodeInsightShorterSymbols - select the shortest
    Underline: Boolean;     // CodeInsightFilterUnderline
  end;

var
  // What the viewer asked a list, for the first calls of a session - the
  // record to read when a selection is wrong (Alex, 2026-10-19: a list opened
  // on `System.sys` had no row selected).
  GListTraces: Integer = 0;
  // The environment option names the IDE answers, read once; nil = not yet.
  GEnvOptionNames: TArray<string>;
  GEnvOptionNamesRead: Boolean = False;

procedure TraceList(const AText: string);
begin
  if GListTraces >= 40 then
    Exit;
  Inc(GListTraces);
  LspLogToServer('code insight list: ' + AText);
end;

function ReadInsightFilterOptions: TInsightFilterOptions;
var
  LServices: IOTAServices;
  LOptions: IOTAEnvironmentOptions;
  LNames: TOTAOptionNameArray;
  LIdx: Integer;
  LLog: string;

  function ReadBool(const AName: string; ADefault: Boolean): Boolean;
  var
    LValue: Variant;
  begin
    Result := ADefault;
    if not MatchText(AName, GEnvOptionNames) then
      Exit;
    try
      LValue := LOptions.Values[AName];
      if VarIsOrdinal(LValue) or (VarType(LValue) = varBoolean) then
        Result := LValue <> 0
      else if VarIsStr(LValue) then
        Result := SameText(VarToStr(LValue), 'True') or
          (VarToStr(LValue) = '1');
    except
      Result := ADefault;
    end;
  end;

begin
  // The IDE's defaults: contains on, starts-with first on, shortest off,
  // underline on.
  Result.Contained := True;
  Result.StartsFirst := True;
  Result.Shortest := False;
  Result.Underline := True;
  LOptions := nil;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    LOptions := LServices.GetEnvironmentOptions;
  if not Assigned(LOptions) then
    Exit;
  if not GEnvOptionNamesRead then
  begin
    GEnvOptionNamesRead := True;
    LLog := '';
    try
      LNames := LOptions.GetOptionNames;
      for LIdx := 0 to High(LNames) do
        if ContainsText(LNames[LIdx].Name, 'CodeInsight') then
        begin
          GEnvOptionNames := GEnvOptionNames + [LNames[LIdx].Name];
          LLog := LLog + ' ' + LNames[LIdx].Name;
        end;
    except
      on E: Exception do
        LLog := ' (unreadable: ' + E.Message + ')';
    end;
    LspLogToServer('code insight: environment options' + LLog);
  end;
  Result.Contained := ReadBool('CodeInsightContainedSymbols', Result.Contained);
  Result.StartsFirst := ReadBool('CodeInsightFilterStartsWith',
    Result.StartsFirst);
  Result.Shortest := ReadBool('CodeInsightShorterSymbols', Result.Shortest);
  Result.Underline := ReadBool('CodeInsightFilterUnderline', Result.Underline);
end;

{ ---------------------------------------------------------------------------
  The row count under the Code Completion list
  --------------------------------------------------------------------------- }

type
  { A status strip at the bottom of the IDE's Code Completion window, in its
    NON-CLIENT area (Alex, 2026-10-19: "a status bar with the row count").
    The window is one control - TCodeCompleteListView "KibitzWindow", a popup
    whose VCL Parent is the main form, with no child controls (the 0.73.2
    probe) - so there is no panel to dock a TStatusBar into, and a child
    window over its client area would hide the last row from its scrolling.
    Taking the strip out of the client area in WM_NCCALCSIZE makes the list
    lay itself out above it; WM_NCPAINT paints it as the IDE style's status
    bar. Hooked through the control's WindowProc, which outlives a handle
    recreation; FreeNotification drops the hook's target if the IDE frees
    the window first. Active only while OUR list is shown - a hide turns it
    off, so the native manager's list, should it be selected, is untouched.
    The same hook shortens the pause before a long row's hint
    (CM_HINTSHOWPAUSE, see WndProc). }
  TCompletionStatusStrip = class(TComponent)
  private
    FTarget: TWinControl;
    FOldProc: TWndMethod;
    FActive: Boolean;   // the strip is wanted (our list is the one shown)
    FShrunk: Boolean;   // the last WM_NCCALCSIZE took the strip's room
    FText: string;
    procedure Hook(ATarget: TWinControl);
    procedure Unhook;
    procedure WndProc(var AMsg: TMessage);
    procedure SetActive(AValue: Boolean);
    procedure QueueFrame;
    function StripHeight: Integer;
    function StripRectInWindow(out ARect: TRect): Boolean;
    procedure PaintStrip;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
  public
    destructor Destroy; override;
    procedure ShowCounts(AVisible, ATotal: Integer; const AFilter: string);
  end;

const
  // The pause before the hint of a row too wide for the list (WndProc,
  // CM_HINTSHOWPAUSE): long enough not to flash a hint on every long row the
  // mouse crosses, a fifth of the IDE's default.
  cListHintPauseMs = 100;

var
  GStatusStrip: TCompletionStatusStrip = nil;
  // The posted frame recompute (TCompletionStatusStrip.SetActive).
  GStripFrameMsg: Cardinal = 0;

// The Code Completion window: a child of the main form's control list, by
// the name and class the probe saw. nil before the IDE created it.
function FindCompletionWindow: TWinControl;
var
  LMain: TForm;
  LIdx: Integer;
  LControl: TControl;
begin
  Result := nil;
  LMain := Application.MainForm;
  if LMain = nil then
    Exit;
  for LIdx := 0 to LMain.ControlCount - 1 do
  begin
    LControl := LMain.Controls[LIdx];
    if (LControl is TWinControl) and (SameText(LControl.Name, 'KibitzWindow')
       or SameText(LControl.ClassName, 'TCodeCompleteListView')) then
      Exit(TWinControl(LControl));
  end;
end;

destructor TCompletionStatusStrip.Destroy;
begin
  Unhook;
  inherited;
end;

procedure TCompletionStatusStrip.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited;
  // The window is going: its WindowProc goes with it, nothing to restore.
  if (Operation = opRemove) and (AComponent = FTarget) then
  begin
    FTarget := nil;
    FActive := False;
  end;
end;

procedure TCompletionStatusStrip.Hook(ATarget: TWinControl);
begin
  FTarget := ATarget;
  FOldProc := ATarget.WindowProc;
  ATarget.WindowProc := WndProc;
  ATarget.FreeNotification(Self);
  LspLogToServer('code insight: row count strip hooked to ' +
    ATarget.ClassName + ' "' + ATarget.Name + '"');
end;

procedure TCompletionStatusStrip.Unhook;
var
  LMine: TWndMethod;
begin
  if FTarget = nil then
    Exit;
  FActive := False;
  LMine := WndProc;
  // Restored only while the chain still ends in us. Someone who hooked
  // after us holds our method as THEIR old one; putting ours back over
  // theirs would cut them off, and that is logged instead.
  if (TMethod(FTarget.WindowProc).Code = TMethod(LMine).Code) and
     (TMethod(FTarget.WindowProc).Data = TMethod(LMine).Data) then
    FTarget.WindowProc := FOldProc
  else
    LspLogToServer('code insight: the completion window''s WindowProc was ' +
      'hooked after ours - left as it is');
  // Unloading: a list on screen gets its whole client area back now (the
  // queue would deliver to a WindowProc that is no longer ours); a hidden
  // one is left alone, as everywhere here.
  if FShrunk and FTarget.HandleAllocated and
     IsWindowVisible(FTarget.Handle) then
    SetWindowPos(FTarget.Handle, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  FTarget.RemoveFreeNotification(Self);
  FTarget := nil;
end;

{ THE FRAME IS RECOMPUTED ONLY FROM THE QUEUE, AND ONLY ON A VISIBLE WINDOW.
  Twice on 2026-10-19 a synchronous SetWindowPos(SWP_FRAMECHANGED) did harm:
  inside SetFilter or a hide it made the list repaint rows while the viewer
  was mid-update (AVs in the Code Templates manager's DrawLine, scrolling
  and resizing), and on the HIDDEN window it made the IDE style's scroll bar
  - a separate window TScrollingStyleHook keeps beside the list - show
  itself and stay on screen after the list closed. So SetActive only records
  the wish and posts; the posted message applies it when the window is
  shown, and a hidden window is left alone until its next show. }
procedure TCompletionStatusStrip.SetActive(AValue: Boolean);
begin
  if FActive = AValue then
    Exit;
  FActive := AValue;
  if FActive <> FShrunk then
    QueueFrame;
end;

procedure TCompletionStatusStrip.QueueFrame;
begin
  if (FTarget = nil) or not FTarget.HandleAllocated then
    Exit;
  if GStripFrameMsg = 0 then
    GStripFrameMsg := RegisterWindowMessage('PasTreeCompletionStripFrame');
  PostMessage(FTarget.Handle, GStripFrameMsg, 0, 0);
end;

// One line of the main form's font plus a status bar's padding, at the
// window's own DPI.
function TCompletionStatusStrip.StripHeight: Integer;
var
  LPPI, LFontHeight: Integer;
begin
  LPPI := FTarget.CurrentPPI;
  if (Application.MainForm <> nil) and (Application.MainForm.Font <> nil) then
    LFontHeight := MulDiv(Abs(Application.MainForm.Font.Height), LPPI,
      Application.MainForm.Font.PixelsPerInch)
  else
    LFontHeight := MulDiv(12, LPPI, 72);
  Result := LFontHeight + MulDiv(8, LPPI, 96);
end;

{ The strip in window coordinates: from the bottom of the client area down
  over the frame's bottom band to the window's 1-pixel outline, and across
  the whole inner width - under the scroll bar column too. Directly under
  the client area alone it floated above a band of empty frame (Alex,
  2026-10-19: "drawn a little higher than it should be"). }
function TCompletionStatusStrip.StripRectInWindow(out ARect: TRect): Boolean;
var
  LWindow, LClient: TRect;
  LOrigin: TPoint;
begin
  Result := (FTarget <> nil) and FTarget.HandleAllocated and
    Winapi.Windows.GetWindowRect(FTarget.Handle, LWindow) and
    Winapi.Windows.GetClientRect(FTarget.Handle, LClient);
  if not Result then
    Exit;
  LOrigin := Point(0, 0);
  Winapi.Windows.ClientToScreen(FTarget.Handle, LOrigin);
  ARect.Left := 1;
  ARect.Right := LWindow.Width - 1;
  ARect.Top := LOrigin.Y - LWindow.Top + LClient.Bottom;
  ARect.Bottom := LWindow.Height - 1;
  Result := ARect.Bottom > ARect.Top;
end;

procedure TCompletionStatusStrip.PaintStrip;
var
  LDC: HDC;
  LRect, LText, LWindow: TRect;
  LOrigin: TPoint;
  LCanvas: TCanvas;
  LStyle: TCustomStyleServices;
begin
  if not StripRectInWindow(LRect) then
    Exit;
  LDC := GetWindowDC(FTarget.Handle);
  if LDC = 0 then
    Exit;
  LCanvas := TCanvas.Create;
  try
    LCanvas.Handle := LDC;
    if Application.MainForm <> nil then
    begin
      LCanvas.Font.Assign(Application.MainForm.Font);
      LCanvas.Font.Height := -MulDiv(Abs(Application.MainForm.Font.Height),
        FTarget.CurrentPPI, Application.MainForm.Font.PixelsPerInch);
    end;
    // The IDE style's own status bar: its background element and its panel
    // text colour, so a dark theme gets the dark strip without a table here.
    LStyle := StyleServices(FTarget);
    if LStyle.Enabled and not LStyle.IsSystemStyle then
    begin
      LStyle.DrawElement(LDC, LStyle.GetElementDetails(tsStatusRoot), LRect);
      LCanvas.Font.Color := LStyle.GetStyleFontColor(sfStatusPanelTextNormal);
    end
    else
    begin
      LCanvas.Brush.Color := clBtnFace;
      LCanvas.FillRect(LRect);
      LCanvas.Font.Color := clBtnText;
    end;
    LCanvas.Brush.Style := bsClear;
    // The text starts where the rows do: past the frame's left band.
    LText := LRect;
    LOrigin := Point(0, 0);
    Winapi.Windows.ClientToScreen(FTarget.Handle, LOrigin);
    Winapi.Windows.GetWindowRect(FTarget.Handle, LWindow);
    LText.Left := LOrigin.X - LWindow.Left + MulDiv(4, FTarget.CurrentPPI, 96);
    LText.Right := LText.Right - MulDiv(4, FTarget.CurrentPPI, 96);
    // Through the canvas, which selects its font into the DC first.
    LCanvas.TextRect(LText, FText, [tfSingleLine, tfVerticalCenter, tfLeft,
      tfNoPrefix, tfEndEllipsis]);
  finally
    LCanvas.Handle := 0;
    LCanvas.Free;
    ReleaseDC(FTarget.Handle, LDC);
  end;
end;

procedure TCompletionStatusStrip.WndProc(var AMsg: TMessage);
var
  LStrip, LWindow: TRect;
  LPoint: TPoint;
  LRect: PRect;
  LWindowBottom: Integer;
begin
  case AMsg.Msg of
    WM_NCCALCSIZE:
      begin
        // Both shapes of the message: with wParam the rect is rgrc[0],
        // without it lParam is the rect itself - the window rect in, the
        // client rect out.
        if AMsg.WParam <> 0 then
          LRect := @PNCCalcSizeParams(AMsg.LParam).rgrc[0]
        else
          LRect := PRect(AMsg.LParam);
        LWindowBottom := LRect.Bottom;
        FOldProc(AMsg);
        // One line in all: the frame's bottom band already is part of the
        // strip (StripRectInWindow), so the client area gives up only what
        // the band lacks of a line - all of it, it was three lines tall
        // (Alex, 2026-10-19: "one line high, not three").
        FShrunk := FActive;
        if FActive then
          Dec(LRect.Bottom, Max(0, StripHeight -
            (LWindowBottom - LRect.Bottom)));
      end;
    WM_NCPAINT:
      begin
        FOldProc(AMsg);
        if FActive and FShrunk then
          PaintStrip;
      end;
    WM_NCHITTEST:
      begin
        FOldProc(AMsg);
        // A click on the strip is nobody's - not a row, it is below the
        // client area - except where the frame under it is a resize edge,
        // which keeps resizing the window.
        if FActive and StripRectInWindow(LStrip) and
           Winapi.Windows.GetWindowRect(FTarget.Handle, LWindow) and
           (AMsg.Result <> HTLEFT) and (AMsg.Result <> HTRIGHT) and
           (AMsg.Result <> HTBOTTOM) and (AMsg.Result <> HTBOTTOMLEFT) and
           (AMsg.Result <> HTBOTTOMRIGHT) then
        begin
          LPoint := Point(SmallInt(AMsg.LParamLo) - LWindow.Left,
            SmallInt(AMsg.LParamHi) - LWindow.Top);
          if PtInRect(LStrip, LPoint) then
            AMsg.Result := HTBORDER;
        end;
      end;
    // The hint of a row too wide for the list is the VCL's own Application
    // hint (the list answers CM_HINTSHOW with TPopupHintWindow), so it waited
    // Application.HintPause - 500 ms by default - like every hint in the IDE
    // (Alex, 2026-10-20: "can it come sooner?"). TApplication asks the hint
    // control itself first, through CM_HINTSHOWPAUSE with the pause by
    // reference: answered here, the list's hint comes sooner and no other
    // hint of the IDE changes. Only the first hint's pause - moving on from a
    // shown one already takes HintShortPause.
    CM_HINTSHOWPAUSE:
      begin
        FOldProc(AMsg);
        if FActive and (AMsg.WParam = 0) and (AMsg.LParam <> 0) then
          PInteger(AMsg.LParam)^ := Min(PInteger(AMsg.LParam)^,
            cListHintPauseMs);
      end;
    // A hide only marks the strip unwanted - the frame of a hidden window is
    // never touched (see SetActive). A show settles whatever is pending:
    // the strip wanted and missing, or a list not ours on a shrunk client.
    WM_SHOWWINDOW:
      begin
        FOldProc(AMsg);
        if AMsg.WParam = 0 then
          FActive := False
        else if FActive <> FShrunk then
          QueueFrame;
      end;
    WM_WINDOWPOSCHANGED:
      begin
        FOldProc(AMsg);
        if PWindowPos(AMsg.LParam).flags and SWP_HIDEWINDOW <> 0 then
          FActive := False
        else if (PWindowPos(AMsg.LParam).flags and SWP_SHOWWINDOW <> 0) and
                (FActive <> FShrunk) then
          QueueFrame;
      end;
  else
    if (GStripFrameMsg <> 0) and (AMsg.Msg = GStripFrameMsg) then
    begin
      // From the queue, visible, and still out of step: recompute now.
      if (FActive <> FShrunk) and FTarget.HandleAllocated and
         IsWindowVisible(FTarget.Handle) then
        SetWindowPos(FTarget.Handle, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or
          SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
    end
    else
      FOldProc(AMsg);
  end;
end;

{ Called by our list on every SetFilter - the viewer refilters on each
  keystroke, so this is the count as the user sees it. }
procedure TCompletionStatusStrip.ShowCounts(AVisible, ATotal: Integer;
  const AFilter: string);
var
  LWindow: TWinControl;
begin
  if FTarget = nil then
  begin
    LWindow := FindCompletionWindow;
    if LWindow = nil then
      Exit;
    Hook(LWindow);
  end;
  if AFilter = '' then
    FText := Format('%d items', [ATotal])
  else
    FText := Format('%d of %d items', [AVisible, ATotal]);
  SetActive(True);
  // Only the strip, and only on screen: an invalidation, painted when the
  // queue gets to it.
  if FTarget.HandleAllocated and IsWindowVisible(FTarget.Handle) then
    RedrawWindow(FTarget.Handle, nil, 0, RDW_FRAME or RDW_INVALIDATE);
end;

procedure ShowCompletionCounts(AVisible, ATotal: Integer;
  const AFilter: string);
begin
  if not GAlive then
    Exit;
  try
    if GStatusStrip = nil then
      GStatusStrip := TCompletionStatusStrip.Create(nil);
    GStatusStrip.ShowCounts(AVisible, ATotal, AFilter);
  except
    // A strip that cannot be drawn must never cost the list itself.
    on E: Exception do
      LspLogToServer('code insight: row count strip failed: ' + E.Message);
  end;
end;

type
  TPasSymbolList = class(TInterfacedObject, IOTACodeInsightSymbolList,
    IOTACodeInsightSymbolList80)
  private
    FOptions: TInsightFilterOptions;
    FAll: TArray<TLspCompletionItem>;
    // FAll's labels upper-cased once, parallel to it - the filter's haystack.
    FUpper: TArray<string>;
    FVisible: TArray<Integer>;   // indices into FAll, after SetFilter
    FFilter: string;             // the last SetFilter's text
    FSortOrder: TOTASortOrder;
    procedure Rebuild(const AFilter: string);
  public
    { The text the viewer filters by - DrawLine underlines it in each name. }
    property Filter: string read FFilter;
    property Options: TInsightFilterOptions read FOptions;
    { The type names in the visible row I's detail - DrawLine paints them. }
    function TypeSpansOf(I: Integer): TArray<Integer>;
    constructor Create(const AItems: TArray<TLspCompletionItem>;
      const AOptions: TInsightFilterOptions);
    { IOTACodeInsightSymbolList }
    procedure Clear;
    function GetCount: Integer;
    function GetSymbolIsReadWrite(I: Integer): Boolean;
    function GetSymbolIsAbstract(I: Integer): Boolean;
    function GetViewerSymbolFlags(I: Integer): TOTAViewerSymbolFlags;
    function GetViewerVisibilityFlags(I: Integer): TOTAViewerVisibilityFlags;
    function GetProcDispatchFlags(I: Integer): TOTAProcDispatchFlags;
    procedure SetSortOrder(const Value: TOTASortOrder);
    function GetSortOrder: TOTASortOrder;
    function FindIdent(const AnIdent: string): Integer;
    function FindSymIndex(const Ident: string; var Index: Integer): Boolean;
    procedure SetFilter(const FilterText: string);
    { The full item behind a viewer row - what Done reads to decide
      auto-parenthesis. Searches ALL items, not the filtered view: the
      viewer's selected string exists regardless of the current filter. }
    function TryGetByName(const AName: string;
      out AItem: TLspCompletionItem): Boolean;
    function GetSymbolText(Index: Integer): string;
    function GetSymbolTypeText(Index: Integer): string;
    function GetSymbolClassText(I: Integer): string;
    { IOTACodeInsightSymbolList80 }
    function GetSymbolDocumentation(I: Integer): string;
  end;

constructor TPasSymbolList.Create(const AItems: TArray<TLspCompletionItem>;
  const AOptions: TInsightFilterOptions);
var
  LIdx: Integer;
begin
  inherited Create;
  FAll := AItems;
  FSortOrder := soAlpha;
  FOptions := AOptions;
  // Sorted ONCE, here: SetFilter runs per keystroke on the UI thread with
  // whole-RTL-sized lists, and both of Rebuild's passes preserve order - so
  // Rebuild never needs to sort, only scan. (soScope grouping, when it comes,
  // means a second precomputed permutation, not a per-keystroke sort.)
  TArray.Sort<TLspCompletionItem>(FAll,
    TComparer<TLspCompletionItem>.Construct(
      function(const A, B: TLspCompletionItem): Integer
      begin
        Result := CompareText(A.ItemLabel, B.ItemLabel);
      end));
  SetLength(FUpper, Length(FAll));
  for LIdx := 0 to High(FAll) do
    FUpper[LIdx] := UpperCase(FAll[LIdx].ItemLabel);
  Rebuild('');
end;

{ BY CONTAINMENT, NOT PREFIX - the native viewer's rule (Alex, 2026-10-13,
  AVImark): "fas" lists faSysFile, but also iefFast, TIEFastDrawing and
  CC_FPFASTCALL. Until 0.68.0 this kept only the labels STARTING with the
  filter, so the list was a fraction of DelphiLSP's for the same text - the
  server sends every name in scope and never filtered; this did. Prefix
  matches first, then the rest, each alphabetical, as the native list does. }
procedure TPasSymbolList.Rebuild(const AFilter: string);
var
  LIdx, LCount, LPos: Integer;
  LNeedle: string;
  LInner: TArray<Integer>;
  LInnerCount: Integer;
begin
  // Counted growth, not per-element appends: this runs per keystroke and
  // FAll can hold thousands of rows.
  SetLength(FVisible, Length(FAll));
  LCount := 0;
  if AFilter = '' then
  begin
    for LIdx := 0 to High(FAll) do
      FVisible[LIdx] := LIdx;
    Exit;
  end;
  LNeedle := UpperCase(AFilter);
  SetLength(LInner, Length(FAll));
  LInnerCount := 0;
  for LIdx := 0 to High(FAll) do
  begin
    LPos := Pos(LNeedle, FUpper[LIdx]);
    // The IDE's Insight Options: without "contain filter" only prefix
    // matches stay; without "starts with first" every match is one
    // alphabetical run.
    if (LPos > 1) and not FOptions.Contained then
      Continue;
    if (LPos = 1) or ((LPos > 1) and not FOptions.StartsFirst) then
    begin
      FVisible[LCount] := LIdx;
      Inc(LCount);
    end
    else if LPos > 1 then
    begin
      LInner[LInnerCount] := LIdx;
      Inc(LInnerCount);
    end;
  end;
  for LIdx := 0 to LInnerCount - 1 do
    FVisible[LCount + LIdx] := LInner[LIdx];
  SetLength(FVisible, LCount + LInnerCount);
end;

procedure TPasSymbolList.Clear;
begin
  FAll := nil;
  FUpper := nil;
  FVisible := nil;
end;

function TPasSymbolList.GetCount: Integer;
begin
  Result := Length(FVisible);
end;

function TPasSymbolList.GetSymbolIsReadWrite(I: Integer): Boolean;
begin
  Result := False;
end;

function TPasSymbolList.GetSymbolIsAbstract(I: Integer): Boolean;
begin
  Result := False;
end;

function TPasSymbolList.GetViewerSymbolFlags(I: Integer): TOTAViewerSymbolFlags;
begin
  // LSP CompletionItemKind -> viewer color class. Only the kinds the server
  // can send today and the obvious next ones; everything else draws neutral.
  if (I < 0) or (I > High(FVisible)) then
    Exit(vsfUnknown);
  case FAll[FVisible[I]].Kind of
    3:  Result := vsfFunction;    // Function
    5:  Result := vsfVariable;    // Field
    6:  Result := vsfLocalVar;    // Variable
    7:  Result := vsfType;        // Class
    8:  Result := vsfInterface;   // Interface
    9:  Result := vsfUnit;        // Module
    10: Result := vsfProperty;    // Property
    14: Result := vsfReservedWord;
    21: Result := vsfConstant;    // Constant
  else
    Result := vsfUnknown;
  end;
end;

function TPasSymbolList.GetViewerVisibilityFlags(
  I: Integer): TOTAViewerVisibilityFlags;
begin
  Result := 0;
end;

function TPasSymbolList.GetProcDispatchFlags(I: Integer): TOTAProcDispatchFlags;
begin
  Result := pdfNone;
end;

procedure TPasSymbolList.SetSortOrder(const Value: TOTASortOrder);
begin
  FSortOrder := Value;
end;

function TPasSymbolList.GetSortOrder: TOTASortOrder;
begin
  Result := FSortOrder;
end;

function TPasSymbolList.FindIdent(const AnIdent: string): Integer;
var
  LIdx: Integer;
  LNeedle: string;
  LPrefixOnly: Boolean;
begin
  Result := 0;
  if FFilter <> '' then
  begin
    // Filtered, the first row is the one selected, whatever the viewer asks
    // with (Alex, 2026-10-16) - Rebuild already put the best match there -
    // or, under "Select shortest matching symbol", the shortest of the
    // prefix matches (of all matches when none starts with the filter).
    if FOptions.Shortest and (Length(FVisible) > 1) then
    begin
      LNeedle := UpperCase(FFilter);
      LPrefixOnly := False;
      for LIdx := 0 to High(FVisible) do
        if FUpper[FVisible[LIdx]].StartsWith(LNeedle) then
        begin
          LPrefixOnly := True;
          Break;
        end;
      Result := -1;
      for LIdx := 0 to High(FVisible) do
        if (not LPrefixOnly or FUpper[FVisible[LIdx]].StartsWith(LNeedle)) and
           ((Result < 0) or (Length(FUpper[FVisible[LIdx]]) <
              Length(FUpper[FVisible[Result]]))) then
          Result := LIdx;
    end;
  end
  else
    // "Closest partial match": the first visible label the ident is a prefix
    // of; failing that, the top of the list keeps the viewer somewhere sane.
    for LIdx := 0 to High(FVisible) do
      if FAll[FVisible[LIdx]].ItemLabel.StartsWith(AnIdent, True) then
      begin
        Result := LIdx;
        Break;
      end;
  TraceList(Format('FindIdent("%s") under filter "%s" -> %d of %d',
    [AnIdent, FFilter, Result, Length(FVisible)]));
end;

function TPasSymbolList.FindSymIndex(const Ident: string;
  var Index: Integer): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  for LIdx := 0 to High(FVisible) do
    if SameText(FAll[FVisible[LIdx]].ItemLabel, Ident) then
    begin
      Index := LIdx;
      Result := True;
      Break;
    end;
  // The viewer (37.0) selects through THIS call alone: after every SetFilter
  // it asks FindSymIndex(<filter>) and never FindIdent, so a filter that is
  // no whole label selected nothing (Alex, 2026-10-19, the trace below). A
  // filtered list answers its best row instead - FindIdent's choice.
  if not Result and (FFilter <> '') and (Length(FVisible) > 0) then
  begin
    Index := FindIdent(Ident);
    Result := True;
  end;
  TraceList(Format('FindSymIndex("%s") under filter "%s" -> %s',
    [Ident, FFilter, BoolToStr(Result, True)]));
end;

function TPasSymbolList.TypeSpansOf(I: Integer): TArray<Integer>;
begin
  if (I < 0) or (I > High(FVisible)) then
    Exit(nil);
  Result := FAll[FVisible[I]].TypeSpans;
end;

procedure TPasSymbolList.SetFilter(const FilterText: string);
begin
  FFilter := FilterText;
  Rebuild(FilterText);
  TraceList(Format('SetFilter("%s") -> %d of %d', [FilterText,
    Length(FVisible), Length(FAll)]));
  ShowCompletionCounts(Length(FVisible), Length(FAll), FilterText);
end;

function TPasSymbolList.GetSymbolText(Index: Integer): string;
begin
  if (Index >= 0) and (Index <= High(FVisible)) then
    Result := FAll[FVisible[Index]].ItemLabel
  else
    Result := '';
end;

function TPasSymbolList.GetSymbolTypeText(Index: Integer): string;
begin
  // Drawn GLUED right after the symbol text - exactly where the native
  // viewer shows a symbol's type/signature, and exactly why the server
  // sends Detail display-verbatim (': TStringList (+2)').
  if (Index >= 0) and (Index <= High(FVisible)) then
    Result := FAll[FVisible[Index]].Detail
  else
    Result := '';
end;

function TPasSymbolList.GetSymbolClassText(I: Integer): string;
begin
  // The viewer's left-hand class column, in the exact vocabulary the native
  // DelphiLSP list uses ('keyword', 'function', 'const', ...) - matching it
  // is what makes our rows read like the IDE's own. A routine's REAL head
  // word (constructor/destructor/operator/...) arrives from the server in
  // the item's data field and wins over the generic kind mapping.
  if (I < 0) or (I > High(FVisible)) then
    Exit('');
  if FAll[FVisible[I]].Head <> '' then
    Exit(FAll[FVisible[I]].Head);
  case FAll[FVisible[I]].Kind of
    2, 3:   Result := 'function';    // Method, Function
    4:      Result := 'constructor';
    5, 6:   Result := 'var';         // Field, Variable
    7, 8:   Result := 'type';        // Class, Interface
    9:      Result := 'unit';        // Module
    10:     Result := 'property';
    14:     Result := 'keyword';
    // EnumMember: the native list calls an enum value a 'const' (it is one,
    // typed by its enum); 'value' was ours, and no Delphi word.
    20, 21: Result := 'const';
    24:     Result := 'operator';
    25:     Result := 'type';        // TypeParameter
  else
    Result := '';
  end;
end;

function TPasSymbolList.TryGetByName(const AName: string;
  out AItem: TLspCompletionItem): Boolean;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(FAll) do
    if SameText(FAll[LIdx].ItemLabel, AName) then
    begin
      AItem := FAll[LIdx];
      Exit(True);
    end;
  Result := False;
end;

function TPasSymbolList.GetSymbolDocumentation(I: Integer): string;
begin
  // Help Insight for the selected row. HTML, not plain text: ToolsAPI's own
  // comment on this method is "Return documentation for the symbol, in HTML"
  // (ToolsAPI.pas:8506), and the IDE's Help Insight surfaces are HTML windows
  // styled by ObjRepos\HelpInsight.css - the plain rendering arrives there as
  // one collapsed paragraph. The plain text stays the fallback for a server
  // that sent no HTML fragment.
  //
  // This call arrives on the UI thread while the viewer is open, so it may
  // never round-trip (the sync-interface rule in clients/rad-studio/SPEC.md) -
  // which is exactly why the server sends documentation with EVERY item
  // instead of deferring it to a completionItem/resolve the IDE gives us no
  // moment to make.
  if (I < 0) or (I > High(FVisible)) then
    Exit('');
  Result := FAll[FVisible[I]].DocHtml;
  if Result = '' then
    Result := FAll[FVisible[I]].Doc;
end;

{ ---------------------------------------------------------------------------
  Parameter insight: one signatureHelp answer behind the IDE's two views
  --------------------------------------------------------------------------- }

{ 'const AName: string = Default' -> modifier/name/type/has-default. The
  labels were built by the server from the declaration's own source span, so
  the shape is real Pascal. }
procedure ParseParamLabel(const ALabel: string; out AModifier, AName,
  AType: string; out AHasDefault: Boolean);
var
  LText: string;
  LIdx: Integer;
begin
  AModifier := '';
  AType := '';
  LText := Trim(ALabel);
  LIdx := Pos(' ', LText);
  if LIdx > 0 then
  begin
    AModifier := Copy(LText, 1, LIdx - 1);
    if SameText(AModifier, 'const') or SameText(AModifier, 'var') or
       SameText(AModifier, 'out') then
      LText := Trim(Copy(LText, LIdx + 1, MaxInt))
    else
      AModifier := '';
  end;
  LIdx := Pos(':', LText);
  if LIdx > 0 then
  begin
    AName := Trim(Copy(LText, 1, LIdx - 1));
    AType := Trim(Copy(LText, LIdx + 1, MaxInt));
  end
  else
    AName := LText;
  AHasDefault := Pos('=', AType) > 0;
  if AHasDefault then
    AType := Trim(Copy(AType, 1, Pos('=', AType) - 1));
end;

type
  TPasParamQuery = class(TInterfacedObject, IOTACodeInsightParamQuery)
  private
    FSig: TLspSignatureItem;
    FRetVal: string;
  public
    constructor Create(const ASig: TLspSignatureItem);
    { IOTACodeInsightParamQuery }
    function GetQueryParamCount: Integer;
    function GetQueryRetVal: string;
    function GetQueryParamSymText(Index: Integer): string;
    function GetQueryParamTypeText(Index: Integer): string;
    function GetQueryParamHasDefaultVal(Index: Integer): Boolean;
    function GetQueryParamInvokeTypeText(Index: Integer): string;
  end;

  TPasParameterList = class(TInterfacedObject, IOTACodeInsightParameterList,
    IOTACodeInsightParameterList100)
  private
    FHelp: TLspSignatureHelp;
    function ActiveParams: TArray<string>;
  public
    constructor Create(const AHelp: TLspSignatureHelp);
    property Help: TLspSignatureHelp read FHelp;
    { IOTACodeInsightParameterList }
    procedure GetParameterQuery(ProcIndex: Integer;
      out ParamQuery: IOTACodeInsightParamQuery);
    function GetParamDelimiter: Char;
    function GetProcedureCount: Integer;
    function GetProcedureParamsText(I: Integer): string;
    { IOTACodeInsightParameterList100 }
    function GetParmPos(Index: Integer): TOTACharPos;
    function GetParmCount: Integer;
    function GetParmName(Index: Integer): string;
    function GetParmHint(Index: Integer): string;
    function GetCallStartPos: TOTACharPos;
    function GetCallEndPos: TOTACharPos;
  end;

constructor TPasParamQuery.Create(const ASig: TLspSignatureItem);
var
  LIdx: Integer;
begin
  inherited Create;
  FSig := ASig;
  // The result type is the label's tail after the params' closing '): ' (or
  // after 'Name: ' for a parameterless function).
  //
  // THE FALLBACK ONLY APPLIES WITH NO PARAMETER LIST AT ALL, which is the case
  // the sentence above describes and the condition the first version left out.
  // A PROCEDURE with typed parameters has no '): ' either -
  // `Foo(const S: string; Index: Integer)` - so the fallback found the first
  // PARAMETER's ': ' inside the brackets and handed the IDE's parameter
  // insight `string; Index: Integer)` as the routine's result type.
  LIdx := FSig.SigLabel.LastIndexOf('): ');
  if LIdx >= 0 then
    FRetVal := FSig.SigLabel.Substring(LIdx + 3)
  else if FSig.SigLabel.IndexOf('(') < 0 then
  begin
    LIdx := FSig.SigLabel.IndexOf(': ');
    if LIdx >= 0 then
      FRetVal := FSig.SigLabel.Substring(LIdx + 2);
  end;
end;

function TPasParamQuery.GetQueryParamCount: Integer;
begin
  Result := Length(FSig.Params);
end;

function TPasParamQuery.GetQueryRetVal: string;
begin
  Result := FRetVal;
end;

function TPasParamQuery.GetQueryParamSymText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LName;
  end;
end;

function TPasParamQuery.GetQueryParamTypeText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LType;
  end;
end;

function TPasParamQuery.GetQueryParamHasDefaultVal(Index: Integer): Boolean;
var
  LModifier, LName, LType: string;
begin
  Result := False;
  if (Index >= 0) and (Index <= High(FSig.Params)) then
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, Result);
end;

function TPasParamQuery.GetQueryParamInvokeTypeText(Index: Integer): string;
var
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(FSig.Params)) then
  begin
    ParseParamLabel(FSig.Params[Index], LModifier, LName, LType, LHasDefault);
    Result := LModifier;
  end;
end;

constructor TPasParameterList.Create(const AHelp: TLspSignatureHelp);
begin
  inherited Create;
  FHelp := AHelp;
end;

function TPasParameterList.ActiveParams: TArray<string>;
begin
  Result := nil;
  if (FHelp.ActiveSignature >= 0) and
     (FHelp.ActiveSignature <= High(FHelp.Signatures)) then
    Result := FHelp.Signatures[FHelp.ActiveSignature].Params;
end;

procedure TPasParameterList.GetParameterQuery(ProcIndex: Integer;
  out ParamQuery: IOTACodeInsightParamQuery);
begin
  ParamQuery := nil;
  if (ProcIndex >= 0) and (ProcIndex <= High(FHelp.Signatures)) then
    ParamQuery := TPasParamQuery.Create(FHelp.Signatures[ProcIndex]);
end;

function TPasParameterList.GetParamDelimiter: Char;
begin
  Result := ';';
end;

function TPasParameterList.GetProcedureCount: Integer;
begin
  Result := Length(FHelp.Signatures);
end;

function TPasParameterList.GetProcedureParamsText(I: Integer): string;
begin
  // Per the interface doc: the parameters of procedure I, "delimited by a
  // line ending".
  Result := '';
  if (I >= 0) and (I <= High(FHelp.Signatures)) then
    Result := string.Join(sLineBreak, FHelp.Signatures[I].Params);
end;

function TPasParameterList.GetParmPos(Index: Integer): TOTACharPos;
begin
  // Per-parameter source positions are undocumented; the call's own open
  // paren is the one position the interim provider knows. Bring-up decides
  // whether the viewer needs more.
  Result := GetCallStartPos;
end;

function TPasParameterList.GetParmCount: Integer;
begin
  Result := Length(ActiveParams);
end;

function TPasParameterList.GetParmName(Index: Integer): string;
var
  LParams: TArray<string>;
  LModifier, LName, LType: string;
  LHasDefault: Boolean;
begin
  Result := '';
  LParams := ActiveParams;
  if (Index >= 0) and (Index <= High(LParams)) then
  begin
    ParseParamLabel(LParams[Index], LModifier, LName, LType, LHasDefault);
    Result := LName;
  end;
end;

function TPasParameterList.GetParmHint(Index: Integer): string;
var
  LParams: TArray<string>;
begin
  Result := '';
  LParams := ActiveParams;
  if (Index >= 0) and (Index <= High(LParams)) then
    Result := LParams[Index];
end;

function TPasParameterList.GetCallStartPos: TOTACharPos;
begin
  Result.Line := FHelp.CallRow;
  Result.CharIndex := FHelp.CallCol - 1;   // TOTACharPos is zero-based
end;

function TPasParameterList.GetCallEndPos: TOTACharPos;
begin
  // The call is still being typed - there is no closing paren to report;
  // the open paren is the only honest fixed point.
  Result := GetCallStartPos;
end;

{ ---------------------------------------------------------------------------
  The manager
  --------------------------------------------------------------------------- }

type
  TPasCodeInsightManager = class(TInterfacedObject, IOTACodeInsightManager100,
    IOTACodeInsightManager, IOTACodeInsightSelection,
    IOTAAsyncCodeInsightManager, IOTAAsyncCodeInsightManager290,
    IOTACodeInsightManager90, INTACustomDrawCodeInsightViewer,
    IOTAPrimaryCodeInsightManager)
  private
    FEnabled: Boolean;
    // GetContext's first call this session went to the log - see there.
    FContextAsked: Boolean;
    FSymbols: IOTACodeInsightSymbolList;
    // The same object as FSymbols, typed - the callers that need item fields
    // the interface does not expose. The interface reference owns the
    // lifetime; this one is only ever read alongside it. (Those callers all
    // read the SHOWN pair below, not this one - see there.)
    FSymbolsObj: TPasSymbolList;
    // The list the VIEWER actually pulled (GetSymbolList) - a late async
    // answer may replace FSymbols while a popup built from the previous
    // list is still open, and Done's auto-parenthesis must consult what the
    // user was LOOKING AT, not the newest answer. The interface reference
    // keeps the shown object alive.
    FShownSymbols: IOTACodeInsightSymbolList;
    FShownObj: TPasSymbolList;
    // The last signatureHelp answer, behind the two views the IDE pulls
    // (GetParameterList / the 100 interface). Same pairing rule as
    // FSymbols/FSymbolsObj.
    FParamList: IOTACodeInsightParameterList;
    FParamListObj: TPasParameterList;
    FActiveParamId: Integer;
    // The newest active-argument recount (AsyncParameterCodeInsightParamIndex)
    // - the callback has no id for the IDE to tell them apart, so a
    // superseded recount must not answer at all.
    FParamIndexSeq: Integer;
    // The one in-flight async completion; a later invocation supersedes it
    // (LspSession cancels the LSP request, this id gate drops the callback).
    FNextId: Integer;
    FActiveId: Integer;
    FActiveHintId: Integer;
    function CurrentView: IOTAEditView;
  public
    constructor Create;
    { IOTACodeInsightManager100 }
    function GetName: string;
    function GetIDString: string;
    function GetEnabled: Boolean;
    procedure SetEnabled(Value: Boolean);
    function EditorTokenValidChars(PreValidating: Boolean): TSysCharSet;
    procedure AllowCodeInsight(var Allow: Boolean; const Key: Char);
    function PreValidateCodeInsight(const Str: string): Boolean;
    function IsViewerBrowsable(Index: Integer): Boolean;
    function GetMultiSelect: Boolean;
    procedure GetSymbolList(out SymbolList: IOTACodeInsightSymbolList);
    procedure OnEditorKey(Key: Char; var CloseViewer: Boolean;
      var Accept: Boolean);
    function HandlesFile(const AFileName: string): Boolean;
    function GetLongestItem: string;
    procedure GetParameterList(out ParameterList: IOTACodeInsightParameterList);
    procedure GetCodeInsightType(AChar: Char; AElement: Integer;
      out CodeInsightType: TOTACodeInsightType; out InvokeType: TOTAInvokeType);
    function InvokeCodeCompletion(HowInvoked: TOTAInvokeType;
      var Str: string): Boolean;
    function InvokeParameterCodeInsight(HowInvoked: TOTAInvokeType;
      var SelectedIndex: Integer): Boolean;
    procedure ParameterCodeInsightAnchorPos(var EdPos: TOTAEditPos);
    function ParameterCodeInsightParamIndex(EdPos: TOTAEditPos): Integer;
    function GetHintText(HintLine, HintCol: Integer): string;
    function GotoDefinition(out AFileName: string; out ALineNum: Integer;
      Index: Integer = -1): Boolean;
    procedure Done(Accepted: Boolean; out DisplayParams: Boolean);
    { IOTACodeInsightManager }
    function GetOptionSetName: string;
    { IOTACodeInsightSelection - GetIDString is shared with the manager }
    function GetDisplayName: string;
    { IOTAAsyncCodeInsightManager }
    procedure AsyncAllowCodeInsight(var AAllow: Boolean; const AKey: Char);
    function AsyncCanInvoke(AInsightType: TOTACodeInsightType): Boolean;
    function AsyncEnabled: Boolean;
    function AsyncInvokeCodeCompletion(AHowInvoked: TOTAInvokeType;
      var AStr: string; ALine, ACharIndex: Integer;
      ACallback: TOTACodeCompleteCallBack): Integer;
    function AsyncInvokeParameterCodeInsight(HowInvoked: TOTAInvokeType;
      const AFileName: string; ALine, ACharIndex: Integer;
      ACallback: TOTAParametersCallBack): Integer;
    function AsyncGetHintText(HintLine, HintCol: Integer;
      ACallBack: TOTAHintTextCallBack): Integer;
    function AsyncGotoDefinition(const AFileName: string;
      ALine, ACharIndex: Integer;
      ACallBack: TOTAGotoDefinitionCallBack): Integer;
    procedure AsyncParameterCodeInsightParamIndex(const AFileName: string;
      ALine, ACharIndex: Integer; ACallBack: TOTAParamIndexCallBack);
    procedure AsyncOperationCanceled(AId: Integer);
    function ShowCalculating: Boolean;
    { IOTAAsyncCodeInsightManager290 }
    function AsyncGotoDefinitionEx(const AFileName: string;
      ALine, ACharIndex: Integer;
      ACallBack: TOTAGotoDefinitionCallBackEx): Integer;
    { IOTACodeInsightManager90 - the viewer's Help Insight pane, in HTML }
    function GetHelpInsightHtml: WideString;
    { INTACustomDrawCodeInsightViewer }
    procedure DrawLine(Index: Integer; Canvas: TCanvas; var Rect: TRect;
      DrawingHintText: Boolean; DoDraw: Boolean; var DefaultDraw: Boolean);
    { IOTAPrimaryCodeInsightManager - see GetContext }
    function GetContext: TOTACodeCompletionContext;
    { IDispatch, which IOTAPrimaryCodeInsightManager derives from: nothing
      here is scriptable, every call answers E_NOTIMPL. }
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
      stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
      stdcall;
  end;

constructor TPasCodeInsightManager.Create;
begin
  inherited Create;
  FEnabled := True;
end;

function TPasCodeInsightManager.CurrentView: IOTAEditView;
var
  LServices: IOTACodeInsightServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    LServices.GetEditView(Result);
end;

function TPasCodeInsightManager.GetName: string;
begin
  Result := 'PasTree code insight';
end;

function TPasCodeInsightManager.GetIDString: string;
begin
  Result := cOurManagerId;
end;

function TPasCodeInsightManager.GetDisplayName: string;
begin
  Result := 'PasTree';   // the Tools > Options "Insight Provider" combobox
end;

function TPasCodeInsightManager.GetEnabled: Boolean;
begin
  Result := FEnabled;
end;

{ NOT where "is PasTree selected" is answered - tried that first, and the IDE
  does not call this with False for a manager the user never selected at all
  (only ever observed True, on selection). CheckInsightProviderSelected below
  asks IOTACodeInsightServices60 directly instead. }
procedure TPasCodeInsightManager.SetEnabled(Value: Boolean);
begin
  FEnabled := Value;
end;

function TPasCodeInsightManager.EditorTokenValidChars(
  PreValidating: Boolean): TSysCharSet;
begin
  Result := ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

procedure TPasCodeInsightManager.AllowCodeInsight(var Allow: Boolean;
  const Key: Char);
begin
  // #0 completion, #1 parameters (signatureHelp), #2 browse, #3 hints
  // (Tooltip Insight, over the server's hover), plus the trigger characters
  // '.' (completion) and '('/',' (parameter insight re-anchoring).
  Allow := (Key = #0) or (Key = #1) or (Key = #2) or
    ((Key = #3) and OfferHintInsight) or
    (Key = '.') or (Key = '(') or (Key = ',');
end;

function TPasCodeInsightManager.PreValidateCodeInsight(
  const Str: string): Boolean;
begin
  Result := True;
end;

function TPasCodeInsightManager.IsViewerBrowsable(Index: Integer): Boolean;
begin
  // Deliberately not yet: real symbols DO have declarations now, but the
  // sync GotoDefinition below declines (async is the only resolve path), so
  // advertising browseability would offer a gesture that goes nowhere.
  // Not a phase-C question any more (phase C shipped 2026-08-22): it stays
  // False until the sync GotoDefinition can answer, which is a decision about
  // this interface, not about the migration.
  Result := False;
end;

function TPasCodeInsightManager.GetMultiSelect: Boolean;
begin
  Result := False;
end;

procedure TPasCodeInsightManager.GetSymbolList(
  out SymbolList: IOTACodeInsightSymbolList);
begin
  SymbolList := FSymbols;
  // Whatever the viewer takes now is what Done must judge later - see
  // FShownSymbols.
  FShownSymbols := FSymbols;
  FShownObj := FSymbolsObj;
end;

procedure TPasCodeInsightManager.OnEditorKey(Key: Char;
  var CloseViewer: Boolean; var Accept: Boolean);
begin
  // Identifier characters refine the filter; Enter/Tab accept; anything else
  // closes without accepting (Escape never reaches here).
  if CharInSet(Key, ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
  begin
    CloseViewer := False;
    Accept := False;
  end
  else
  begin
    CloseViewer := True;
    Accept := CharInSet(Key, [#13, #9]);
  end;
end;

function TPasCodeInsightManager.HandlesFile(const AFileName: string): Boolean;
begin
  Result := IsPascalSourceFile(AFileName);
end;

function TPasCodeInsightManager.GetLongestItem: string;
begin
  // Per the interface doc this is the longest CLASS text ('constructor' vs
  // 'var'), not the longest item - and 'constructor' is the widest word our
  // class column ever shows.
  Result := 'constructor';
end;

procedure TPasCodeInsightManager.GetParameterList(
  out ParameterList: IOTACodeInsightParameterList);
begin
  ParameterList := FParamList;   // the last signatureHelp answer, or nil
end;

procedure TPasCodeInsightManager.GetCodeInsightType(AChar: Char;
  AElement: Integer; out CodeInsightType: TOTACodeInsightType;
  out InvokeType: TOTAInvokeType);
begin
  InvokeType := itManual;
  // NOT IN A COMMENT OR A STRING, for what opens by itself or asks for a
  // list: '.' typed in `// e.g.` or in a string literal started a timed
  // completion request, '(' and ',' in a string a parameter request, and a
  // float's '.' (`1.5`) another - the ToolsAPI's own example of this method
  // vetoes exactly these. Parameter insight (#1), browse (#2) and the hint
  // (#3) are explicit gestures and keep working where they did.
  if ((AElement = atComment) or (AElement = atString)) and
     CharInSet(AChar, [#0, '.', '(', ',']) then
  begin
    CodeInsightType := citNone;
    Exit;
  end;
  if (AElement = atNumber) and (AChar = '.') then
  begin
    CodeInsightType := citNone;
    Exit;
  end;
  case AChar of
    #0: CodeInsightType := citCodeInsight;
    #2: CodeInsightType := citBrowseCodeInsight;
    // Without this arm the IDE never reaches AsyncGetHintText at all: it
    // asks GetCodeInsightType(#3) BEFORE invoking a hint, and citNone here
    // vetoes the whole gesture - the first tooltip bring-up showed exactly
    // that (no popup, no request in the log).
    #1: CodeInsightType := citParameterCodeInsight;
    #3: CodeInsightType := citHintCodeInsight;
    '.':
      begin
        // The same trigger character the server advertises to LSP clients.
        CodeInsightType := citCodeInsight;
        InvokeType := itTimer;
      end;
    '(', ',':
      begin
        // Typing into an argument list re-anchors the parameter hint - the
        // same trigger characters the server advertises for signatureHelp.
        CodeInsightType := citParameterCodeInsight;
        InvokeType := itTimer;
      end;
  else
    CodeInsightType := citNone;
  end;
end;

function TPasCodeInsightManager.InvokeCodeCompletion(
  HowInvoked: TOTAInvokeType; var Str: string): Boolean;
begin
  // The SYNC invocation. Answering it truthfully would mean blocking the
  // main thread on the server, which nothing here ever does - the async
  // companion is the real path. Declining is safe: an IDE that ignored the
  // async interface would show no completion, not wrong completion, and the
  // gated bring-up exists to catch exactly that before anyone relies on it.
  Result := False;
end;

function TPasCodeInsightManager.InvokeParameterCodeInsight(
  HowInvoked: TOTAInvokeType; var SelectedIndex: Integer): Boolean;
begin
  Result := False;
end;

procedure TPasCodeInsightManager.ParameterCodeInsightAnchorPos(
  var EdPos: TOTAEditPos);
begin
  // Anchor the hint at the call's own open paren when we know it.
  if Assigned(FParamListObj) and FParamListObj.Help.Valid then
  begin
    EdPos.Line := FParamListObj.Help.CallRow;
    EdPos.Col := FParamListObj.Help.CallCol;
  end;
end;

function TPasCodeInsightManager.ParameterCodeInsightParamIndex(
  EdPos: TOTAEditPos): Integer;
begin
  // -1 = "reinvoke me" (the interface's own protocol): the server recounts
  // the active argument from the live text, which is always right, where a
  // cached index would drift the moment the user edits mid-call.
  Result := -1;
end;

function TPasCodeInsightManager.GetHintText(HintLine, HintCol: Integer): string;
begin
  Result := '';
end;

function TPasCodeInsightManager.GotoDefinition(out AFileName: string;
  out ALineNum: Integer; Index: Integer): Boolean;
begin
  // Sync browse: same reasoning as InvokeCodeCompletion - the async Ex
  // overload is the real path.
  AFileName := '';
  ALineNum := 0;
  Result := False;
end;

procedure TPasCodeInsightManager.Done(Accepted: Boolean;
  out DisplayParams: Boolean);
var
  LServices: IOTACodeInsightServices;
  LViewer: IOTACodeInsightViewer;
  LSelected: string;
  LItem: TLspCompletionItem;
  LView: IOTAEditView;
begin
  DisplayParams := False;
  if not Accepted then
    Exit;
  // Insertion is the manager's job (the interface comment says so): take the
  // viewer's selection and let the IDE replace the token under the caret -
  // the same replace-the-typed-prefix contract the LSP textEdit span carries
  // for VS Code, expressed through the IDE's own InsertText.
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LViewer := nil;
  LServices.GetViewer(LViewer);
  if not Assigned(LViewer) then
    Exit;
  LSelected := LViewer.GetSelectedString;
  if LSelected = '' then
    Exit;
  LServices.InsertText(LSelected, True);
  // AUTO-PARENTHESIS: a routine WITH parameters gets `()` and the caret
  // lands between them, mirroring the native behavior. hasParams came from
  // the server (the declaration's real nkParams), so a parameterless
  // procedure stays bare - `LoadSettings;` never becomes `LoadSettings();`.
  // Applied only on the keyboard accept (Enter/Tab, per OnEditorKey): a
  // future '(' close-key accept must not double the paren. Judged against
  // the list the VIEWER displayed (FShownObj), not the newest answer - a
  // late re-invoke may have replaced FSymbolsObj under the open popup.
  if Assigned(FShownObj) and FShownObj.TryGetByName(LSelected, LItem) and
     LItem.HasParams then
  begin
    LView := CurrentView;
    // The completed name may sit in an EXISTING call - caret inside the
    // identifier of `LoadSettings(True);` - where appending `()` would
    // produce `LoadSettings()(True)`. If a paren already follows the
    // caret, the native behavior is to add nothing.
    if Assigned(LView) and (LView.Buffer.EditPosition.Character <> '(') then
    begin
      LView.Buffer.EditPosition.InsertText('()');
      LView.Buffer.EditPosition.MoveRelative(0, -1);
      // Repaint now rather than on the next natural refresh: the insertion
      // came from a popup, and a stale caret is visibly wrong.
      LView.Paint;
      // And the parameter hint opens between the parens, as after the native
      // list's accept - DisplayParams is the interface's "requery me for
      // parameter insight". Not when a paren already followed: the caret
      // then sits before it, outside the call.
      DisplayParams := True;
    end;
  end;
end;

function TPasCodeInsightManager.GetHelpInsightHtml: WideString;
var
  LServices: IOTACodeInsightServices;
  LViewer: IOTACodeInsightViewer;
  LSelected: string;
  LItem: TLspCompletionItem;
begin
  // The viewer's own Help Insight pane for the SELECTED row - HTML by
  // contract ("Retrieves help insight information for the current Viewer's
  // selected item", ToolsAPI.pas:8864), and the same fragment
  // GetSymbolDocumentation hands over, so the two surfaces cannot disagree.
  //
  // Read from the list the viewer is DISPLAYING (FShownObj), for the same
  // reason Done does: a late async answer may have replaced FSymbolsObj under
  // the open popup, and the pane must describe the row the user is looking at.
  Result := '';
  if not GAlive or not Assigned(FShownObj) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LViewer := nil;
  LServices.GetViewer(LViewer);
  if not Assigned(LViewer) then
    Exit;
  LSelected := LViewer.GetSelectedString;
  if (LSelected = '') or not FShownObj.TryGetByName(LSelected, LItem) then
    Exit;
  if LItem.DocHtml <> '' then
    Result := LItem.DocHtml
  else
    Result := LItem.Doc;
end;

function TPasCodeInsightManager.GetOptionSetName: string;
begin
  { The Code Insight options are stored PER OPTION SET, and the set name is
    the registry subkey: under <BaseRegistryKey>\Code Insight the IDE keeps
    `Borland.EditOptions.Pascal` (the classic Pascal provider) and
    `Borland.EditOptions.Borland.CodeInsight.LSP.Pascal` (DelphiLSP), each
    holding `Help Insight`, `Auto Invoke`, `CodeCompleteAutoParens`,
    `Declaration Information` and the rest. Returning '' - which this did
    until 2026-08-23 - means our provider has NO set, so every one of those
    settings reads as its bare default for us, whatever the user ticked.
    That is the first suspect for a feature that "should work because the
    method exists": the method is called, the option behind it is off.

    We name the CLASSIC Pascal set deliberately, rather than inventing one:
    the whole point of this provider is to behave like the native one
    (user, 2026-08-21: "один в один"), and a set of our own would start with
    every box unticked and would have to be configured twice. The cost is
    that changes made on our page land in the shared set - acceptable while
    the two providers mean the same thing by each option, and the line to
    revisit if they ever do not. }
  Result := 'Borland.EditOptions.Pascal';
end;

{ ------------------------------ async half ------------------------------ }

procedure TPasCodeInsightManager.AsyncAllowCodeInsight(var AAllow: Boolean;
  const AKey: Char);
begin
  AllowCodeInsight(AAllow, AKey);
end;

function TPasCodeInsightManager.AsyncCanInvoke(
  AInsightType: TOTACodeInsightType): Boolean;
begin
  Result := (AInsightType in [citCodeInsight, citParameterCodeInsight,
    citBrowseCodeInsight]) or
    ((AInsightType = citHintCodeInsight) and OfferHintInsight);
end;

function TPasCodeInsightManager.AsyncEnabled: Boolean;
begin
  Result := FEnabled;
end;

function TPasCodeInsightManager.AsyncInvokeCodeCompletion(
  AHowInvoked: TOTAInvokeType; var AStr: string; ALine, ACharIndex: Integer;
  ACallback: TOTACodeCompleteCallBack): Integer;
var
  LId, LRow, LCol: Integer;
  LView: IOTAEditView;
  LFileName: string;
  LInInvoke: Boolean;
  LOptions: TInsightFilterOptions;
begin
  LView := CurrentView;
  if not Assigned(LView) then
    Exit(-1);
  LFileName := LView.Buffer.FileName;
  // Read here, on the UI thread, per invocation - the list itself is built
  // in the answer's callback, and an options-page change holds from the
  // next list on.
  LOptions := ReadInsightFilterOptions;
  TraceList(Format('invoked (how %d) at %d:%d with "%s"', [Ord(AHowInvoked),
    LView.Buffer.EditPosition.Row, LView.Buffer.EditPosition.Column, AStr]));
  // THE POSITION COMES FROM THE CARET, NOT FROM THE PARAMETERS. The first
  // live bring-up (2026-08-21) showed why: with the caret after `beg` the
  // parameters carried a position whose text was NOT `beg` - the server saw
  // an empty prefix and answered all 64 keywords - and the parameters' base
  // (0- or 1-based line, char index vs column) is documented nowhere.
  // Completion is only ever invoked at the caret, and the caret's own
  // coordinates are already in IDE convention, so use those and log the raw
  // parameters alongside until the convention is understood.
  LRow := LView.Buffer.EditPosition.Row;
  LCol := LView.Buffer.EditPosition.Column;
  Inc(FNextId);
  LId := FNextId;
  FActiveId := LId;
  LInInvoke := True;
  LspCompletion(LFileName, LRow, LCol,
    procedure(ASuccess: Boolean; const AItems: TArray<TLspCompletionItem>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      // A superseded or cancelled invocation must not call back: the IDE has
      // already moved on, and LspSession has already cancelled the request.
      if FActiveId <> LId then
        Exit;
      FActiveId := 0;
      if ASuccess then
      begin
        FSymbolsObj := TPasSymbolList.Create(AItems, LOptions);
        FSymbols := FSymbolsObj;
      end
      else
      begin
        FSymbols := nil;
        FSymbolsObj := nil;
      end;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallback) then
            ACallback(Self, LId, not ASuccess, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncInvokeParameterCodeInsight(
  HowInvoked: TOTAInvokeType; const AFileName: string;
  ALine, ACharIndex: Integer; ACallback: TOTAParametersCallBack): Integer;
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  FActiveParamId := LId;
  LInInvoke := True;
  // Position parameters trusted per the browse-confirmed convention
  // (1-based line, 0-based char index).
  LspSignatureHelp(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHelp: TLspSignatureHelp;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      if FActiveParamId <> LId then
        Exit;   // superseded by a newer invocation
      FActiveParamId := 0;
      if ASuccess and AHelp.Valid then
      begin
        FParamListObj := TPasParameterList.Create(AHelp);
        FParamList := FParamListObj;
      end
      else
      begin
        FParamList := nil;
        FParamListObj := nil;
      end;
      DeliverToIde(LInInvoke,
        procedure
        begin
          // ASelectIndex is the ARGUMENT to highlight, not the overload: the
          // sync twin of this call documents its SelectedIndex as "the
          // index of the current parameter for the method/proc". Until
          // 0.73.3 this passed ActiveSignature - 0 for any call without
          // overloads, so the first parameter lit up whatever the caret's
          // argument until the first recount.
          if GAlive and Assigned(ACallback) then
            ACallback(Self, LId, AHelp.ActiveParam,
              not (ASuccess and AHelp.Valid), AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

{ ONE-TIME READOUT, first hover of a session: does the active module offer
  IOTAHelpInsight? That interface ("Allows Help Insight to show documentation
  information from the current symbol in the code editor. Query for it from the
  IOTAModule. If it isn't present, then this feature is not present",
  ToolsAPI.pas:6787) is the OTHER way into the editor's Help Insight window -
  the one that takes a `member` document rather than a hint string. It is
  queried FROM the module, so if the IDE's own module already implements it the
  path is occupied and not ours to take, exactly as the 2026-08-22 file-trait
  spike found for IOTAModuleErrors. Answering that question costs one Supports
  call, and guessing it has already cost this project one spike. }
procedure ProbeHelpInsight;
var
  LModuleServices: IOTAModuleServices;
  LModule: IOTAModule;
  LHelpInsight: IOTAHelpInsight;

  // INTO THE SERVER LOG, not the Build tab. This is a readout: it answers a
  // question about the IDE that mattered while the feature was being designed
  // and may matter again in a year, and it says nothing the user can act on
  // today. The panel is for things worth interrupting somebody with (user,
  // 2026-08-29 - and the same call retired two other lines that day).
  procedure Readout(const AText: string);
  begin
    if not LspLogToServer('IOTAHelpInsight probe: ' + AText) then
      // No server yet, so this went nowhere: unmark, and the next hover asks
      // again. A readout that reports into the void is not a readout.
      GHelpInsightProbed := False;
  end;

begin
  if GHelpInsightProbed then
    Exit;
  GHelpInsightProbed := True;
  // Wrapped whole: the first version of this probe produced NO line at all on
  // a live run (user, 2026-08-23). Everything here talks to IDE objects we do
  // not own - Supports on the module, and IsEnabled is `safecall` on an
  // IDispatch, so a raise on the other side arrives as an exception here -
  // and an exception thrown out of a hover would be swallowed by the IDE with
  // the probe silently never reporting. A readout that can fail silently is
  // not a readout.
  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices)
    then
    begin
      Readout('no IOTAModuleServices');
      Exit;
    end;
    LModule := LModuleServices.CurrentModule;
    if not Assigned(LModule) then
    begin
      GHelpInsightProbed := False;   // no module yet - ask again next hover
      Exit;
    end;
    if not Supports(LModule, IOTAHelpInsight, LHelpInsight) then
    begin
      Readout('absent on module ' + LModule.FileName
        + ' - the hint string is the only editor Help Insight feed for us');
      Exit;
    end;
    // Two lines, not one: presence is the finding, and IsEnabled is a second
    // call that may fail on its own. Reported separately so a failure in the
    // second cannot hide the first.
    Readout('PRESENT on module ' + LModule.FileName
      + ' - the editor Help Insight window has a native feed');
    try
      Readout('IsEnabled = ' + BoolToStr(LHelpInsight.IsEnabled, True));
    except
      on E: Exception do
        Readout('IsEnabled raised ' + E.ClassName + ': ' + E.Message);
    end;
  except
    on E: Exception do
      Readout('raised ' + E.ClassName + ': ' + E.Message);
  end;
end;

function TPasCodeInsightManager.AsyncGetHintText(HintLine, HintCol: Integer;
  ACallBack: TOTAHintTextCallBack): Integer;
var
  LId: Integer;
  LView: IOTAEditView;
  LFileName: string;
  LInInvoke: Boolean;
begin
  ProbeHelpInsight;
  // Declined above already while our own hint is on; this is the backstop for
  // an IDE that asks anyway.
  if not OfferHintInsight then
    Exit(-1);
  // Tooltip Insight: the server's hover, as plain text. The position is the
  // HOVERED token's, not the caret's, so the parameters must be trusted -
  // assumed to follow the browse convention confirmed live (1-based line,
  // 0-based char index); if a tooltip ever describes the neighbor token,
  // this conversion is the first suspect.
  LView := CurrentView;
  if not Assigned(LView) then
    Exit(-1);
  LFileName := LView.Buffer.FileName;
  Inc(FNextId);
  LId := FNextId;
  FActiveHintId := LId;
  LInInvoke := True;
  LspHover(LFileName, HintLine, HintCol + 1,
    procedure(ASuccess: Boolean; const AText: string; const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      if FActiveHintId <> LId then
        Exit;   // superseded by a newer hover
      FActiveHintId := 0;
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallBack) then
            ACallBack(Self, LId, AText, not ASuccess, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncGotoDefinition(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBack): Integer;
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  LInInvoke := True;
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      DeliverToIde(LInInvoke,
        procedure
        begin
          if not (GAlive and Assigned(ACallBack)) then
            Exit;
          if ASuccess and (Length(AHits) > 0) then
            ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row, False, '')
          else
            ACallBack(Self, LId, '', 0, True, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

function TPasCodeInsightManager.AsyncGotoDefinitionEx(const AFileName: string;
  ALine, ACharIndex: Integer; ACallBack: TOTAGotoDefinitionCallBackEx): Integer;
var
  LId: Integer;
  LInInvoke: Boolean;
begin
  Inc(FNextId);
  LId := FNextId;
  LInInvoke := True;
  // Browse parameters CONFIRMED live (2026-08-21): 1-based line, 0-based
  // char index - the +1 below landed the jump exactly. (Completion's
  // parameters remain untrusted; it reads the caret instead - see above.)
  LspDefinition(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHits: TArray<TLspHit>;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading - Self may be gone (see GAlive)
      DeliverToIde(LInInvoke,
        procedure
        begin
          if not (GAlive and Assigned(ACallBack)) then
            Exit;
          if ASuccess and (Length(AHits) > 0) then
          begin
            // A COMPILED UNIT: the IDE will open whatever file name it is
            // handed, and it cannot open a .dcu. The generated tab is made
            // first (one more asynchronous hop, only the first time) and
            // the IDE is handed its module name instead - it finds the open
            // module by that name and lands on the line like any other.
            if IsDcuPath(AHits[0].FilePath) then
            begin
              EnsureDcuModule(AHits[0].FilePath,
                procedure(AModuleName: string)
                begin
                  if not (GAlive and Assigned(ACallBack)) then
                    Exit;
                  if AModuleName <> '' then
                    ACallBack(Self, LId, AModuleName, AHits[0].Row,
                      AHits[0].Col - 1, False, '')
                  else
                    ACallBack(Self, LId, '', 0, 0, True,
                      'the .dcu could not be read - see the Build tab');
                end);
              Exit;
            end;
            // Col back to the 0-based char index the callback expects.
            ACallBack(Self, LId, AHits[0].FilePath, AHits[0].Row,
              AHits[0].Col - 1, False, '');
          end
          else
            ACallBack(Self, LId, '', 0, 0, True, AError);
        end);
    end);
  LInInvoke := False;
  Result := LId;
end;

{ A detail's overload tail ` (+N)` cut off into ATail - it is ours, not code,
  and is drawn dim. Matched from the END: a parameter list could contain a
  literal ' (+' of its own. }
procedure SplitOverloadTail(var ADetail: string; out ATail: string);
var
  LCut: Integer;
begin
  ATail := '';
  LCut := ADetail.LastIndexOf(' (+');
  if (LCut >= 0) and ADetail.EndsWith(')') and
     (LCut >= ADetail.Length - 8) then
  begin
    ATail := ADetail.Substring(LCut);
    ADetail := ADetail.Substring(0, LCut);
  end;
end;

var
  GSelectionProbes: Integer = 0;

{ The first rows of a session say what the viewer prepared them with and
  whether DrawLine took that for the selection - the record to read if the
  selected row is painted wrong again. }
procedure LogSelectionProbe(AIndex: Integer; ABrush: TColor;
  ASelected: Boolean);
begin
  if GSelectionProbes >= 12 then
    Exit;
  Inc(GSelectionProbes);
  LspLogToServer(Format('code insight: row %d brush $%.6x (style highlight '
    + '$%.6x) selected=%s', [AIndex, ColorToRGB(ABrush),
    ColorToRGB(StyleServices.GetSystemColor(clHighlight)),
    BoolToStr(ASelected, True)]));
end;

{ The row as the hover hint paints a declaration (Alex, 2026-10-13: "paint
  everything the way the tooltips do"): the stock LAYOUT - fixed class
  column, bold name, the detail glued after it - with the hint's COLOURS. The
  class word in the editor's reserved-word colour; the detail through
  PaintSyntaxTextTyped, the editor's own palette for keywords, numbers,
  strings and symbols, with the type names the server marked (data.typeSpans)
  in the Highlighting tab's colour and style. Until 0.68.0 a hand-rolled
  tokenizer coloured `:`-to-`;` in a violet and values in blue, which matched
  neither the editor nor the hint. The selected row is one colour on the
  editor's Marked block bar, as the native window paints it. }
procedure TPasCodeInsightManager.DrawLine(Index: Integer; Canvas: TCanvas;
  var Rect: TRect; DrawingHintText: Boolean; DoDraw: Boolean;
  var DefaultDraw: Boolean);
const
  cPad = 4;
var
  LClass, LName, LDetail, LTail: string;
  LColWidth, LX, LTop, LMatch: Integer;
  LRun: string;
  LBase, LDim, LTypeColor, LForce, LBar, LOldBrush: TColor;
  LOldBrushStyle: TBrushStyle;
  LTypeStyle: TFontStyles;
  LSpans: TArray<Integer>;
  LSelected: Boolean;
begin
  // FShownSymbols, NOT FSymbols - the list the viewer is actually painting,
  // for the same reason Done and GetHelpInsightHtml read it: a late async
  // answer replaces FSymbols under a popup built from the previous list, and a
  // failed re-invoke nils it outright. Indexing the newest list to draw rows
  // of the displayed one paints the wrong text where the two happen to be the
  // same length.
  //
  // A row past the list's end is drawn BLANK, never handed back with
  // DefaultDraw: the IDE's DefaultViewerDrawLine resolves the same index
  // through its own SymbolListAndSymbolFromIndex, which walks off the end of
  // its symbol-list TInterfaceList and raises "List index out of bounds"
  // (Alex, 2026-10-15, AVImarkServer, arrowing through a 51-item member list
  // - one request, no late answer). The viewer's row count can run ahead of
  // the list's for a paint, after a SetFilter shrank it; the next recount
  // removes the row.
  if not Assigned(FShownSymbols) or (Index < 0) or
     (Index >= FShownSymbols.Count) then
  begin
    DefaultDraw := False;
    Exit;
  end;
  DefaultDraw := False;
  LClass := FShownSymbols.SymbolClassText[Index];
  LName := FShownSymbols.SymbolText[Index];
  LDetail := FShownSymbols.SymbolTypeText[Index];
  LSpans := nil;
  if Assigned(FShownObj) then
    LSpans := FShownObj.TypeSpansOf(Index);

  // The class column is fixed-width - rows must align down the list, and
  // 'constructor' is the widest word the column ever holds.
  Canvas.Font.Style := [];
  LColWidth := Canvas.TextWidth('constructor') + 2 * cPad;

  if not DoDraw then
  begin
    // Measured with the runs' own styles - a bold `const` in a parameter
    // list is wider than a plain TextWidth of the detail.
    Canvas.Font.Style := [TFontStyle.fsBold];
    LX := Canvas.TextWidth(LName);
    SplitOverloadTail(LDetail, LTail);
    PaintSyntaxTextTyped(Canvas, LX, 0, LDetail, Canvas.Font.Color,
      LSpans, TypeHighlightColor, TypeHighlightStyle, False);
    Canvas.Font.Style := [];
    Inc(LX, Canvas.TextWidth(LTail));
    Rect.Right := Rect.Left + LColWidth + LX + 3 * cPad;
    // "The rectangle should be returned by the 'Rect' out parameter" - the
    // whole rectangle (ToolsAPI, INTACustomDrawCodeInsightViewer). The hint
    // of a row too wide for the list is sized by this pass, which arrives
    // with DrawingHintText FALSE and a zero-height rect, (0,0)-(1,0) (logged
    // 2026-10-20): given the width alone, the hint came up a few pixels tall.
    // One row's height, as the list draws it.
    Rect.Bottom := Rect.Top + Max(Rect.Height,
      Canvas.TextHeight('Ag') + 2 * cPad);
    Exit;
  end;

  // The selected row as the native list paints it (Alex, 2026-10-16): a bar
  // across the whole row in the editor's Marked block background, every run
  // in its foreground - white on $A56D53 by default. The viewer's own
  // preparation was the system highlight brush, which TextOut painted under
  // each run alone: pale boxes behind the class word and the text. Runs go
  // out transparent on the bar, so no run paints a box of its own.
  //
  // WHICH row is selected is read off that preparation - the brush in the
  // style's highlight colour - not asked of the viewer. Asked, it lagged:
  // Selected[Index] and GetManagerSelectedIndex both still named the row the
  // selection was LEAVING while the viewer repainted it, so every row arrowed
  // past kept its bar (Alex, 2026-10-17, twice: a record's four fields, then
  // seventeen rows).
  LOldBrush := Canvas.Brush.Color;
  LSelected := (ColorToRGB(LOldBrush) =
      ColorToRGB(StyleServices.GetSystemColor(clHighlight))) or
    (ColorToRGB(LOldBrush) = ColorToRGB(clHighlight));
  LogSelectionProbe(Index, LOldBrush, LSelected);
  LForce := clNone;
  LOldBrushStyle := Canvas.Brush.Style;
  // Every row is filled whole before its runs, the bar or the background the
  // viewer prepared: the viewer does not clear a row, so a row the selection
  // left kept its bar (Alex, 2026-10-17: "the background is not cleared").
  if LSelected then
    EditorMarkedBlockColors(LForce, LBar)
  else
    LBar := LOldBrush;
  Canvas.Brush.Color := LBar;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(Rect);
  Canvas.Brush.Style := bsClear;

  // LBase is the text colour the viewer chose for the row.
  LBase := Canvas.Font.Color;
  LDim := clNavy;
  // Type names as the hint paints them: the Highlighting tab's colour and
  // style, or the editor's identifier colour when type colouring is off.
  if TypeHighlightEnabled then
    LTypeColor := TypeHighlightColor
  else
    LTypeColor := clNone;
  LTypeStyle := TypeHighlightStyle;

  LTop := Rect.Top + (Rect.Height - Canvas.TextHeight('Ag')) div 2;
  LX := Rect.Left + cPad;

  // The class word in the editor's reserved-word colour, as the hint draws
  // its lead - regular weight, so the fixed column measured above holds.
  Canvas.Font.Color := EditorSyntaxColor(atReservedWord, LDim);
  if LForce <> clNone then
    Canvas.Font.Color := LForce;
  Canvas.TextOut(LX, LTop, LClass);
  LX := Rect.Left + LColWidth;

  // The name, bold, with the part the filter matched UNDERLINED - the native
  // window's mark, and the only way to see why a row whose name does not start
  // with the typed text is listed (the filter matches anywhere, see
  // TPasSymbolList.Rebuild). Drawn in three runs so the underline covers the
  // match alone; a name without one (no filter yet) is a single run.
  Canvas.Font.Color := LBase;
  if LForce <> clNone then
    Canvas.Font.Color := LForce;
  Canvas.Font.Style := [TFontStyle.fsBold];
  LMatch := 0;
  if Assigned(FShownObj) and (FShownObj.Filter <> '') and
     FShownObj.Options.Underline then
    LMatch := Pos(UpperCase(FShownObj.Filter), UpperCase(LName));
  if LMatch > 0 then
  begin
    LRun := Copy(LName, 1, LMatch - 1);
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
    LRun := Copy(LName, LMatch, Length(FShownObj.Filter));
    Canvas.Font.Style := [TFontStyle.fsBold, TFontStyle.fsUnderline];
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
    Canvas.Font.Style := [TFontStyle.fsBold];
    LRun := Copy(LName, LMatch + Length(FShownObj.Filter), MaxInt);
    Canvas.TextOut(LX, LTop, LRun);
    Inc(LX, Canvas.TextWidth(LRun));
  end
  else
  begin
    Canvas.TextOut(LX, LTop, LName);
    Inc(LX, Canvas.TextWidth(LName));
  end;
  Canvas.Font.Style := [];

  if LDetail <> '' then
  begin
    SplitOverloadTail(LDetail, LTail);
    PaintSyntaxTextTyped(Canvas, LX, LTop, LDetail, LBase, LSpans,
      LTypeColor, LTypeStyle, True, LForce);
    if LTail <> '' then
    begin
      Canvas.Font.Color := LDim;   // '(+N)' is ours, not code - stays dim
      if LForce <> clNone then
        Canvas.Font.Color := LForce;
      Canvas.Font.Style := [];
      Canvas.TextOut(LX, LTop, LTail);
    end;
  end;
  // Leave the canvas the way the viewer set it.
  Canvas.Font.Color := LBase;
  Canvas.Font.Style := [];
  Canvas.Brush.Color := LOldBrush;
  Canvas.Brush.Style := LOldBrushStyle;
end;

procedure TPasCodeInsightManager.AsyncParameterCodeInsightParamIndex(
  const AFileName: string; ALine, ACharIndex: Integer;
  ACallBack: TOTAParamIndexCallBack);
var
  LInInvoke: Boolean;
  LSeq: Integer;
begin
  // The IDE asks this while the hint is up and the user types: recount the
  // active argument from the live text - a fresh signatureHelp round trip,
  // which the overlay pipeline answers in milliseconds.
  //
  // In its own supersede slot (AIndexOnly), and gated by sequence: until
  // 0.73.3 a recount shared the invocation's slot, so it cancelled the
  // invocation that opens the hint, and a recount cancelled by the next
  // keystroke answered -1 - "reinvoke" - whose invocation cancelled the next
  // recount in turn. A superseded recount now says nothing; only the newest
  // one answers, -1 included when it really failed.
  Inc(FParamIndexSeq);
  LSeq := FParamIndexSeq;
  LInInvoke := True;
  LspSignatureHelp(AFileName, ALine, ACharIndex + 1,
    procedure(ASuccess: Boolean; const AHelp: TLspSignatureHelp;
      const AError: string)
    begin
      if not GAlive then
        Exit;
      if FParamIndexSeq <> LSeq then
        Exit;   // superseded by a newer recount
      DeliverToIde(LInInvoke,
        procedure
        begin
          if GAlive and Assigned(ACallBack) then
            if ASuccess and AHelp.Valid then
              ACallBack(Self, AHelp.ActiveParam)
            else
              ACallBack(Self, -1);
        end);
    end, True);
  LInInvoke := False;
end;

procedure TPasCodeInsightManager.AsyncOperationCanceled(AId: Integer);
begin
  // Drop the callback gate; LspSession's supersede-cancel already told the
  // server the moment a newer request went out.
  if FActiveId = AId then
    FActiveId := 0;
  if FActiveHintId = AId then
    FActiveHintId := 0;
  if FActiveParamId = AId then
    FActiveParamId := 0;
end;

{ THE PRIMARY-MANAGER CONTRACT. ToolsAPI documents that alternate managers -
  Code Templates is one, registered beside every provider - "may query the
  current manager from the services to get invocation context information"
  through IOTAPrimaryCodeInsightManager. Until 0.68.0 this manager did not
  implement it, and with PasTree selected the IDE crashed twice in the Code
  Templates manager's own GetHelpInsightHtml, from the completion list's
  Help Insight timer (Alex, 2026-10-13; our BPL was not on the stack, and no
  AV was seen while DelphiLSP, a primary manager, was selected). ccAny - the
  invocation filters nothing - is the honest answer for a list that offers
  every name in scope. The first question of a session is logged, so whether
  the templates manager really asks is on record. }
function TPasCodeInsightManager.GetContext: TOTACodeCompletionContext;
begin
  Result := ccAny;
  if not FContextAsked then
  begin
    FContextAsked := True;
    LspLogToServer('code insight: an alternate manager asked the invocation'
      + ' context (IOTAPrimaryCodeInsightManager), answered ccAny');
  end;
end;

function TPasCodeInsightManager.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.GetTypeInfo(Index, LocaleID: Integer;
  out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.GetIDsOfNames(const IID: TGUID;
  Names: Pointer; NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.Invoke(DispID: Integer; const IID: TGUID;
  LocaleID: Integer; Flags: Word; var Params; VarResult, ExcepInfo,
  ArgErr: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TPasCodeInsightManager.ShowCalculating: Boolean;
begin
  Result := False;   // keyword answers are instant; no flicker for them
end;

{ ---------------------------------------------------------------------------
  Registration
  --------------------------------------------------------------------------- }

var
  GManager: IOTACodeInsightManager;
  GManagerIndex: Integer = -1;

procedure InitializeCodeInsight;
var
  LServices: IOTACodeInsightServices;
begin
  if Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  GManager := TPasCodeInsightManager.Create;
  GManagerIndex := LServices.AddCodeInsightManager(GManager);
  GAlive := True;
  // NOT ANNOUNCED. This used to say "registered - now select PasTree under
  // Tools > Options ...", loud on purpose because picking the provider is the
  // step people miss. It is the wrong trade at every IDE start after the
  // first: the provider is already selected, so the line is a step report
  // nobody needs, and this panel earns its keep only if what appears in it is
  // worth reading. Log failures, not steps.
end;

function PasTreeIsActiveInsightProvider: Boolean;
var
  LServices: IOTACodeInsightServices;
  LCurrent: IOTACodeInsightManager;
begin
  Result := False;
  if not Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
    Exit;
  LCurrent := nil;
  LServices.GetCurrentCodeInsightManager(LCurrent);
  // By IDString, not interface identity: the services may hand back a
  // different interface reference onto the same registered manager.
  Result := Assigned(LCurrent)
    and SameText(LCurrent.GetIDString, GManager.GetIDString);
end;

{ ---------------------------------------------------------------------------
  Selecting the Insight Provider - see ApplyInsightManagerChoice
  --------------------------------------------------------------------------- }

const
  cEnvInsightManager = 'InsightManager';
  // What RAD Studio selects for Delphi, put back when nothing was remembered.
  cDelphiLspManagerId = 'Borland.CodeInsight.LSP.Pascal';
  // Under <BaseRegistryKey>\PasTree, the settings' own key.
  cSettingsKey = 'PasTree';
  cValueSavedInsightManager = 'SavedInsightManager';
  cApplyRetryMs = 1000;

var
  // ApplyInsightManagerChoice's option did not read: retried no sooner than
  // GProviderRetryAt by SyncInsightManagerChoice. Reported once.
  GProviderPending: Boolean = False;
  GProviderRetryAt: UInt64 = 0;
  GProviderUnreadableNoted: Boolean = False;
  // The last line for the LSP log, until a session takes it - the call at
  // package load runs before any project is open.
  GProviderLogLine: string = '';

procedure ProviderLog(const AText: string);
begin
  GProviderLogLine := 'insight provider: ' + AText;
  if LspLogToServer(GProviderLogLine) then
    GProviderLogLine := '';
end;

{ A failure: the provider the IDE uses now disagrees with the settings, so
  it is worth the Build tab as well as the log. }
procedure ProviderFailure(const AText: string);
var
  LMessages: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessages) then
    LMessages.AddTitleMessage('[pastree] could not set the Insight Provider: '
      + AText);
  ProviderLog('FAILED: ' + AText);
end;

function EnvOptions: IOTAEnvironmentOptions;
var
  LServices: IOTAServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    Result := LServices.GetEnvironmentOptions;
end;

function OpenOurKey(AReg: TRegistry): Boolean;
var
  LServices: IOTAServices;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  AReg.RootKey := HKEY_CURRENT_USER;
  Result := AReg.OpenKey(IncludeTrailingPathDelimiter(
    LServices.GetBaseRegistryKey) + cSettingsKey, True);
end;

function ReadSavedManager: string;
var
  LReg: TRegistry;
begin
  Result := '';
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    if OpenOurKey(LReg) and LReg.ValueExists(cValueSavedInsightManager) then
      Result := LReg.ReadString(cValueSavedInsightManager);
  finally
    LReg.Free;
  end;
end;

{ '' deletes the marker. }
procedure WriteSavedManager(const AValue: string);
var
  LReg: TRegistry;
begin
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    if OpenOurKey(LReg) then
      if AValue = '' then
        LReg.DeleteValue(cValueSavedInsightManager)
      else
        LReg.WriteString(cValueSavedInsightManager, AValue);
  finally
    LReg.Free;
  end;
end;

{ The provider PasTree replaced: the marker, or DelphiLSP without one. }
function ManagerToRestore: string;
begin
  Result := ReadSavedManager;
  if (Result = '') or SameText(Result, cOurManagerId) then
    Result := cDelphiLspManagerId;
end;

procedure ApplyInsightManagerChoice;
var
  LWant: Boolean;
  LOptions: IOTAEnvironmentOptions;
  LBefore, LAfter, LRestore: string;
begin
  GProviderPending := False;
  try
    LWant := PasTreeInsightManagerEnabled;
    // Nothing of ours anywhere: nothing to do or say.
    if not LWant and not Assigned(GManager) and (ReadSavedManager = '') then
      Exit;
    if LWant and not Assigned(GManager) then
      InitializeCodeInsight;
    LOptions := EnvOptions;
    LBefore := '';
    if Assigned(LOptions) then
      LBefore := Trim(VarToStrDef(LOptions.Values[cEnvInsightManager], ''));
    if LBefore = '' then
    begin
      // A value we cannot read is one we cannot put back: leave the IDE's
      // provider alone for now and ask again - it may not be loaded yet.
      GProviderPending := True;
      GProviderRetryAt := GetTickCount64 + cApplyRetryMs;
      if not GProviderUnreadableNoted then
      begin
        GProviderUnreadableNoted := True;
        ProviderLog('the IDE''s ' + cEnvInsightManager
          + ' does not read yet - asked again');
      end;
      Exit;
    end;
    if LWant then
    begin
      if SameText(LBefore, cOurManagerId) then
      begin
        ProviderLog('PasTree, already selected');
        Exit;
      end;
      // Remembered BEFORE the switch: the other order, interrupted, loses
      // the user's provider.
      WriteSavedManager(LBefore);
      LOptions.Values[cEnvInsightManager] := cOurManagerId;
      LAfter := Trim(VarToStrDef(LOptions.Values[cEnvInsightManager], ''));
      if SameText(LAfter, cOurManagerId) then
        ProviderLog('PasTree selected in place of "' + LBefore + '"')
      else
        ProviderFailure('"' + cOurManagerId + '" was written over "' + LBefore
          + '" and the option reads "' + LAfter + '"');
    end
    else
    begin
      // Only over OUR value: a provider the user has picked since in
      // Tools > Options is theirs, and wins.
      if SameText(LBefore, cOurManagerId) then
      begin
        LRestore := ManagerToRestore;
        LOptions.Values[cEnvInsightManager] := LRestore;
        ProviderLog('RAD Studio - put back "' + LRestore + '"; PasTree stays'
          + ' registered until the IDE restarts');
      end
      else
        ProviderLog('RAD Studio - "' + LBefore + '" is the user''s, kept');
      WriteSavedManager('');
    end;
  except
    on E: Exception do
      ProviderFailure(E.ClassName + ': ' + E.Message);
  end;
end;

procedure SyncInsightManagerChoice;
begin
  if (GProviderLogLine <> '') and LspLogToServer(GProviderLogLine) then
    GProviderLogLine := '';
  if GProviderPending and (GetTickCount64 >= GProviderRetryAt) then
    ApplyInsightManagerChoice;
end;

{ At unload: the IDE's own provider back over ours, the marker kept. The
  option writes through to the registry at once (measured 2026-10-13), so
  without this an IDE started without the package would find a provider that
  does not exist; with it, the next start selects PasTree again. }
procedure RestoreProviderAtUnload;
var
  LOptions: IOTAEnvironmentOptions;
  LRestore: string;
begin
  try
    LOptions := EnvOptions;
    if not Assigned(LOptions) or not SameText(Trim(VarToStrDef(
      LOptions.Values[cEnvInsightManager], '')), cOurManagerId) then
      Exit;
    LRestore := ManagerToRestore;
    LOptions.Values[cEnvInsightManager] := LRestore;
    LspLogToServer('insight provider: unload - put back "' + LRestore + '"');
  except
    // Unload: nobody to tell, and nothing worth an exception into the IDE.
  end;
end;

procedure FinalizeCodeInsight;
var
  LServices: IOTACodeInsightServices;
begin
  GProviderPending := False;
  // Before the unregister: the IDE must not be left selecting a manager that
  // is about to be gone.
  if Assigned(GManager) then
    RestoreProviderAtUnload;
  GAlive := False;
  // The completion window outlives this package: its WindowProc must stop
  // pointing into our code before the code goes.
  FreeAndNil(GStatusStrip);
  if GManagerIndex >= 0 then
  begin
    if Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) then
      LServices.RemoveCodeInsightManager(GManagerIndex);
    GManagerIndex := -1;
  end;
  GManager := nil;
end;

procedure CheckInsightProviderSelected;
var
  LServices: IOTACodeInsightServices60;
  LCurrent: IOTACodeInsightManager;
  LSelection: IOTACodeInsightSelection;
  LCurrentName: string;
begin
  if not GAlive or not Assigned(GManager) then
    Exit;
  if not Supports(BorlandIDEServices, IOTACodeInsightServices60, LServices) then
    Exit;
  LServices.GetCurrentCodeInsightManager(LCurrent);
  if LCurrent = GManager then
  begin
    // Selected again after a warning earlier this session - the next time it
    // is switched away should say so again, not stay silent because of an
    // old flag.
    GInsightWarned := False;
    Exit;
  end;
  if GInsightWarned then
    Exit;
  LCurrentName := 'no provider';
  if Assigned(LCurrent) and Supports(LCurrent, IOTACodeInsightSelection,
    LSelection) then
    LCurrentName := '"' + LSelection.GetDisplayName + '"';
  // Into the server's log, under Advanced Logging only - never the Build
  // tab. Until completion is complete, not being the provider is the normal
  // state, and a Build-tab line about it was noise on every load (Alex,
  // 2026-09-21). GInsightWarned is set either way so the check stays cheap.
  if AdvancedLoggingEnabled then
    LspLogToServer(Format('PasTree is not selected as the Insight Provider - '
      + 'completion, browse and parameter insight come from %s instead '
      + 'until it is selected under Tools > Options > Editor > Source.',
      [LCurrentName]));
  GInsightWarned := True;
end;

end.
