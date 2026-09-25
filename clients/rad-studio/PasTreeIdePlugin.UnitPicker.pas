unit PasTreeIdePlugin.UnitPicker;

{
  View Unit (Ctrl+F12) and Use Unit (Alt+F11), OURS - the IDE side of
  PasTreeIdePlugin.UnitPickerForm: the two keys, the lists, and what a
  chosen row does.

  REPLACEMENTS, NOT ADDITIONS (Alex, 2026-09-25: "our job is to replace the
  IDE's windows"). The stock dialogs list the units the .dproj names; these
  list, behind "Implicit Units", every unit the analysis reached - the
  search path's, the IDE Library Path's, `.dcu`-only ones. Neither stock
  dialog has a ToolsAPI surface to add rows to (checked against 22.0, 23.0
  and 37.0 - clients/rad-studio/SPEC.md, "Use Unit over the real closure"),
  so the keys are taken instead. The stock dialogs stay on their menus.

  THE KEYS go through the package's one keyboard binding (KeyBindings).
  Settings.UnitDialogsEnabled is the ONE place that answers krUnhandled: off
  hands both keys back to the IDE's own dialogs. Once on, a key is
  krHandled whether or not a list could be shown - Go To's rule.

  THE LISTS. The PROJECT list is the IDE's own (IOTAProject modules plus the
  main source), so the dialog opens with no request in front of it - a
  request would wait in the server's queue behind any analysis in flight,
  which after opening AVImark is seconds (Alex, 2026-09-25). What needs the
  server is asked by the dialog and lands while it is up: Use Unit's marks
  (pastree/units, scope project, which also says what the file is) and the
  implicit units (scope closure), both of the server owning the file.

  WHAT A ROW DOES.
  - View: opens the unit where it starts - NavigateHistoryAware, so a
    `.dcu`-only unit becomes the generated `Foo.dcu.pas` tab
    (PasTreeIdePlugin.DcuSource) and Alt+Left walks back.
  - Use: pastree/useUnit computes the one insertion over the live buffer
    (the server has the parser; PasLsp.UseUnit has the layout and every
    refusal), and it is written through one undoable writer, so Ctrl+Z
    takes it back. The buffer must still be the one the server answered
    about - Annotate's length gate - or nothing is written. A refusal (the
    unit is already used, the clause does not parse) goes to the Build tab
    with its reason: a keystroke that did nothing must say why.
}

interface

uses
  ToolsAPI;

procedure InitializeUnitPicker;
procedure FinalizeUnitPicker;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Winapi.Windows,
  Vcl.Menus,
  System.Actions,
  Vcl.ActnList,
  Vcl.ExtCtrls,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.KeyBindings,
  PasTreeIdePlugin.Timing,
  PasTreeIdePlugin.GotoDeclaration,
  PasTreeIdePlugin.UnitPickerForm;

var
  // Set by Initialize, cleared by Finalize - a callback landing during the
  // unload must do nothing.
  GAlive: Boolean = False;
  // A list request is in flight, or the dialog is up: one at a time, Go To's
  // guard and for its reason (a second modal picker inside the first).
  GBusy: Boolean = False;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function ModeName(AMode: TUnitPickerMode): string;
begin
  if AMode = upmUse then
    Result := 'Use Unit'
  else
    Result := 'View Unit';
end;

{ The one insertion, applied - ApplyAnnotateEdits' shape: offsets first,
  against the snapshot the server answered about, then the writer. }
procedure ApplyUseUnitEdit(const AView: IOTAEditView; const AEdit: TLspTextEdit);
var
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LPos: Integer;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  LCharPos.Line := AEdit.Row;
  LCharPos.CharIndex := AEdit.Col - 1;
  LPos := AView.CharPosToPos(LCharPos);
  if LPos < 0 then
    Exit;
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    LWriter.CopyTo(LPos);
    LWriter.Insert(UTF8String(AEdit.Text));
  finally
    LWriter := nil;   // the writer commits on release
  end;
  AView.Paint;
end;

procedure UseChosenUnit(const AView: IOTAEditView; const AFileName: string;
  const ARow: TLspUnitRow; AImplementation: Boolean);
var
  LLenAtRequest: Integer;
begin
  LLenAtRequest := BufferByteLength(AView);
  LspUseUnit(AFileName, ARow.Name, AImplementation,
    procedure(ASuccess: Boolean; const AAnswer: TLspUseUnit;
      const AError: string)
    begin
      if not GAlive then
        Exit;
      if not ASuccess then
      begin
        LogDiagnostic('Use Unit: ' + AError);
        Exit;
      end;
      if Length(AAnswer.Edits) = 0 then
      begin
        LogDiagnostic('Use Unit: ' + AAnswer.Provider);
        Exit;
      end;
      if (LLenAtRequest < 0) or (BufferByteLength(AView) <> LLenAtRequest) then
      begin
        LogDiagnostic('Use Unit: the buffer changed while the server was '
          + 'answering - nothing was written. Try again.');
        Exit;
      end;
      ApplyUseUnitEdit(AView, AAnswer.Edits[0]);
      LspLogToServer(Format('useUnit: %s written into the %s uses of %s',
        [ARow.Name, AAnswer.Section, ExtractFileName(AFileName)]));
    end);
end;

{ One project's OWN units - its .pas modules and its main source - as the
  stock dialogs list them, read from the IDE. Synchronous and cheap, and it
  needs no server: this is what lets the dialog open at once even while the
  server is still finishing an analysis, when any request would wait in the
  queue behind it (Alex, 2026-09-25: the first View Unit after opening
  AVImark took as long as the rest of the initial analysis). }
procedure AddProjectRows(const AProject: IOTAProject;
  var ARows: TArray<TLspUnitRow>);
var
  LIdx: Integer;
  LPath: string;

  procedure Add(const AFilePath: string);
  var
    LRow: TLspUnitRow;
  begin
    LRow := Default(TLspUnitRow);
    LRow.Name := TPath.GetFileNameWithoutExtension(AFilePath);
    LRow.FilePath := AFilePath;
    LRow.IsProject := True;
    ARows := ARows + [LRow];
  end;

begin
  if not Assigned(AProject) then
    Exit;
  // The main source is not in the module list; it sits beside the .dproj.
  LPath := ChangeFileExt(AProject.FileName, '.dpr');
  if not FileExists(LPath) then
    LPath := ChangeFileExt(AProject.FileName, '.dpk');
  if FileExists(LPath) then
    Add(LPath);
  for LIdx := 0 to AProject.GetModuleCount - 1 do
  begin
    LPath := AProject.GetModule(LIdx).FileName;
    if SameText(ExtractFileExt(LPath), '.pas') then
      Add(LPath);
  end;
end;

function CurrentGroup: IOTAProjectGroup;
var
  LModuleServices: IOTAModuleServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Result := LModuleServices.MainProjectGroup;
end;

{ The units of the project whose .dproj is AProjectFile. }
function ProjectUnitRows(const AProjectFile: string): TArray<TLspUnitRow>;
var
  LGroup: IOTAProjectGroup;
  LProj: Integer;
begin
  Result := nil;
  LGroup := CurrentGroup;
  if not Assigned(LGroup) then
    Exit;
  for LProj := 0 to LGroup.ProjectCount - 1 do
    if SameText(LGroup.Projects[LProj].FileName, AProjectFile) then
    begin
      AddProjectRows(LGroup.Projects[LProj], Result);
      Exit;
    end;
end;

{ Every project's own units across the open group, as the stock View Unit's
  group box lists them. No server is involved, so a cold project of the
  group stays cold. }
function GroupUnitRows: TArray<TLspUnitRow>;
var
  LGroup: IOTAProjectGroup;
  LProj: Integer;
begin
  Result := nil;
  LGroup := CurrentGroup;
  if not Assigned(LGroup) then
    Exit;
  for LProj := 0 to LGroup.ProjectCount - 1 do
    AddProjectRows(LGroup.Projects[LProj], Result);
end;

{ Below, with the menu hooks it reports on. }
procedure ReportHooksOnce; forward;

procedure ExecuteUnitPicker(const AView: IOTAEditView; AMode: TUnitPickerMode);
var
  LFile, LProjectFile, LProjectName: string;
  LRows: TArray<TLspUnitRow>;
  LRow: TLspUnitRow;
  LImplementation: Boolean;
  LStart: Double;
  LGroupSource: TUnitPickerGroupRows;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) or GBusy then
    Exit;
  ReportHooksOnce;
  // View Unit only - Use Unit writes into THIS project's file, and a unit
  // of another project is not one it compiles.
  LGroupSource := nil;
  if AMode = upmView then
    LGroupSource :=
      function: TArray<TLspUnitRow>
      begin
        Result := GroupUnitRows;
      end;
  LFile := AView.Buffer.FileName;
  LProjectFile := LspOwningProjectFile(LFile);
  LProjectName := TPath.GetFileName(LProjectFile);
  LStart := TimingNowMs;
  LRows := ProjectUnitRows(LProjectFile);
  TimingLogFmt('unitpicker %s: %d project rows from the IDE in %s',
    [ModeName(AMode), Length(LRows), TimingSince(LStart)]);
  GBusy := True;
  try
    // No request in front of the dialog: the project's list is the IDE's
    // (ProjectUnitRows), and what needs the server - Use Unit's marks, the
    // implicit units - is asked by the dialog and lands while it is up.
    if not ShowUnitPicker(AMode, LRows, LProjectName,
         procedure(const AScope: string; const AOnDone: TLspUnitsProc)
         begin
           LspUnits(AScope, LFile, AOnDone);
         end,
         LGroupSource,
         {out} LRow, {out} LImplementation) then
      Exit;
    if not GAlive then
      Exit;
    if AMode = upmView then
      NavigateHistoryAware(LRow.FilePath, 1, 1)
    else
      UseChosenUnit(AView, LFile, LRow, LImplementation);
  finally
    GBusy := False;
  end;
end;

procedure UnitKeyProc(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
begin
  // THE OFF SWITCH - the one krUnhandled here; see the unit header.
  if not UnitDialogsEnabled then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) then
    Exit;
  if AKeyCode = ShortCut(VK_F11, [ssAlt]) then
    ExecuteUnitPicker(LView, upmUse)
  else
    ExecuteUnitPicker(LView, upmView);
end;

{ THE MENU AND TOOLBAR (Alex, 2026-09-25: View > Units... and its toolbar
  button still opened the stock dialog). The keys are ours through the
  binding; a menu item or a toolbar button never reaches a key binding. What
  they run is a TAction of the IDE's main action list -
  INTAServices.ActionList - named ViewUnitCommand (coreide) and
  FileUseUnitCommand (delphicoreide), the same names in 22.0, 23.0 and 37.0
  (read out of the packages). Menu item and button share the action, so one
  OnExecute repointed takes both.

  NOT the editor local menu's trap. The failed Sync Prototypes takeover
  (clients/rad-studio/SPEC.md) held a TMenuItem of the EDITOR's local menu,
  which the IDE rebuilds on every open - a use-after-free. These actions are
  the IDE's own, created once with its main form and alive for the session;
  nothing is held but the action and the handler it had.

  REVERSIBLE, unlike the Find Declaration takeover: the IDE's handler is kept
  and put back at unload - but only if the action still carries ours. If
  something loaded after us repointed it in turn and kept ours as ITS
  "previous", putting the IDE's back would cut that chain; the line then
  says so, and our handler, gated by GAlive, falls through to nothing.

  THE SWITCH is the keys' switch: off, the hook hands every execution to the
  IDE's handler. So is "no editor open": our dialog is about the file under
  the caret, and without one the stock dialog is the only sensible answer.

  FOUND LATE IF NEED BE. FileUseUnitCommand belongs to the Delphi
  personality, which may register after a designtime package loads; an
  action not there at startup is looked for again on a timer, a few times. }
type
  TActionHook = class
  public
    Action: TContainedAction;
    Original: TNotifyEvent;
    Mode: TUnitPickerMode;
    procedure Execute(ASender: TObject);
  end;

  THookRetry = class
    procedure Tick(ASender: TObject);
  end;

const
  cHookedActions: array[TUnitPickerMode] of string =
    ('ViewUnitCommand', 'FileUseUnitCommand');
  cHookRetryMs = 2000;
  cHookRetries = 5;

var
  GHooks: array[TUnitPickerMode] of TActionHook;
  GHookTimer: TTimer = nil;
  GHookRetry: THookRetry = nil;
  GHookTries: Integer = 0;
  // What the hooks did, for the log - written once a server is up to take
  // it (Advanced Logging), since at package load there is none.
  GHookReport: string = '';
  GHookReported: Boolean = False;

procedure NoteHook(const ALine: string);
begin
  if GHookReport <> '' then
    GHookReport := GHookReport + '; ';
  GHookReport := GHookReport + ALine;
  GHookReported := False;
end;

procedure ReportHooksOnce;
begin
  if GHookReported or (GHookReport = '') or not AdvancedLoggingEnabled then
    Exit;
  if LspLogToServer('unitpicker menu hooks: ' + GHookReport) then
    GHookReported := True;
end;

procedure TActionHook.Execute(ASender: TObject);
var
  LEditorServices: IOTAEditorServices;
  LView: IOTAEditView;
begin
  LView := nil;
  if GAlive and UnitDialogsEnabled and
     Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    LView := LEditorServices.TopView;
  if not Assigned(LView) or not Assigned(LView.Buffer) then
  begin
    if Assigned(Original) then
      Original(ASender);
    Exit;
  end;
  ExecuteUnitPicker(LView, Mode);
end;

function FindIdeAction(const AName: string): TContainedAction;
var
  LServices: INTAServices;
  LList: TCustomActionList;
  LIdx: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LList := LServices.ActionList;
  if not Assigned(LList) then
    Exit;
  for LIdx := 0 to LList.ActionCount - 1 do
    if SameText(LList.Actions[LIdx].Name, AName) then
      Exit(LList.Actions[LIdx]);
end;

{ Hooks whatever is not hooked yet; True when both are. }
function HookIdeActions: Boolean;
var
  LMode: TUnitPickerMode;
  LAction: TContainedAction;
  LHook: TActionHook;
begin
  Result := True;
  for LMode := Low(TUnitPickerMode) to High(TUnitPickerMode) do
  begin
    if Assigned(GHooks[LMode]) then
      Continue;
    LAction := FindIdeAction(cHookedActions[LMode]);
    if not Assigned(LAction) then
    begin
      Result := False;
      Continue;
    end;
    LHook := TActionHook.Create;
    LHook.Action := LAction;
    LHook.Original := LAction.OnExecute;
    LHook.Mode := LMode;
    LAction.OnExecute := LHook.Execute;
    GHooks[LMode] := LHook;
    if Assigned(LHook.Original) then
      NoteHook(cHookedActions[LMode] + ' hooked')
    else
      NoteHook(cHookedActions[LMode] + ' hooked (it had no OnExecute - the '
        + 'IDE may run it another way)');
  end;
end;

procedure StopHookTimer;
begin
  FreeAndNil(GHookTimer);
  FreeAndNil(GHookRetry);
end;

procedure THookRetry.Tick(ASender: TObject);
var
  LMode: TUnitPickerMode;
begin
  Inc(GHookTries);
  if HookIdeActions or (GHookTries >= cHookRetries) then
  begin
    for LMode := Low(TUnitPickerMode) to High(TUnitPickerMode) do
      if not Assigned(GHooks[LMode]) then
        NoteHook(cHookedActions[LMode] + ' not found - the menu keeps the '
          + 'stock dialog');
    // Freed on the next turn, not inside its own event.
    GHookTimer.Enabled := False;
    TThread.ForceQueue(nil, StopHookTimer);
  end;
end;

procedure UnhookIdeActions;
var
  LMode: TUnitPickerMode;
  LHook: TActionHook;
  LOurs: TNotifyEvent;
begin
  StopHookTimer;
  for LMode := Low(TUnitPickerMode) to High(TUnitPickerMode) do
  begin
    LHook := GHooks[LMode];
    if not Assigned(LHook) then
      Continue;
    GHooks[LMode] := nil;
    LOurs := LHook.Execute;
    if (TMethod(LHook.Action.OnExecute).Code = TMethod(LOurs).Code) and
       (TMethod(LHook.Action.OnExecute).Data = TMethod(LOurs).Data) then
    begin
      LHook.Action.OnExecute := LHook.Original;
      LHook.Free;
    end
    else
    begin
      // Someone repointed it after us and may call ours as their previous:
      // leave the chain alone. The object stays allocated (it is tiny) so a
      // late call finds valid memory while the package is still mapped.
      LspLogToServer('unitpicker: ' + cHookedActions[LMode] + ' was '
        + 'repointed after us - left as it is');
    end;
  end;
end;

procedure InitializeUnitPicker;
begin
  GAlive := True;
  // Registered, not bound: the wizard binds everything at once.
  RegisterKey(ShortCut(VK_F12, [ssCtrl]), UnitKeyProc);
  RegisterKey(ShortCut(VK_F11, [ssAlt]), UnitKeyProc);
  GHookReport := '';
  GHookTries := 0;
  if not HookIdeActions then
  begin
    GHookRetry := THookRetry.Create;
    GHookTimer := TTimer.Create(nil);
    GHookTimer.Interval := cHookRetryMs;
    GHookTimer.OnTimer := GHookRetry.Tick;
    GHookTimer.Enabled := True;
  end;
end;

procedure FinalizeUnitPicker;
begin
  GAlive := False;
  GBusy := False;
  UnhookIdeActions;
end;

end.
