unit PasTreeIdePlugin.NativeErrorInsight;

{
  THE IDE's OWN ERROR INSIGHT, FED FROM PASTREE - the editor's Error Insight
  marks, the Structure View's Errors folder and the status bar's error count,
  while PasTree is the Insight Provider. What DelphiLSP does, through the same
  three private seams of coreide<ver>.bpl, read off the binaries on
  2026-10-23 (clients/rad-studio/SPEC.md, "Error Insight", has the readout and
  the comparison of 22.0, 23.0 and 37.0 - identical in all three, and in the
  64-bit IDE):

    1. The marker. coreide's IOTACodeInsightServices implements the private
       IInternalErrorInsight, one method: does the CURRENT manager for this
       file support IInternalSupportErrorInsight, an interface with NO
       methods. When it does not, the editor's parse hooks wipe the buffer's
       error marks after every parse and run the classic path - which is why
       nothing PasTree did could show there until now. The manager (Code
       Insight unit) now answers that marker; with no methods there is no
       vtable to get wrong.

    2. The push. Errorinsite.UpdateErrorMarks(Errors, Buffer, True) puts the
       errors on the buffer as Error Insight marks AND into the Structure
       View's Errors folder AND sends the status bar's count - DelphiLSP calls
       exactly this after each publishDiagnostics (TSourceInfo.SetErrors,
       then TEditBuffer.UpdateViews(False)). We call it from the
       diagnostics-changed listener, on the main thread, like ErrorPaint's
       repaint.

    3. The pull. Delphi modules answer IOTAModuleErrors in
       delphierrorinsite<ver>.bpl: IOverrideModuleErrors first, then the
       global hook Sourcemodule.LSPGetErrors (DelphiLSP assigns it in its
       unit initialization and never resets it), then the classic compiler.
       We chain the hook: for a file in our snapshot, while PasTree is the
       provider, we answer; anything else goes to the previous hook, so
       DelphiLSP keeps answering for itself. Without it, a pull would fall
       through to the classic compiler's errors and fight our push.

  REACHED BY NAME, NEVER LINKED. The package must not require coreide (one
  hard invariant: rtl, vcl, designide), so every entry point is GetProcAddress
  on the coreide module that sits beside the designide this package was
  loaded against. A Delphi export's name is its mangled signature, so a
  changed signature is a missing name: then this unit logs it once and does
  nothing, and the painted squiggles (ErrorPaint) are still there.

  COORDINATES as DelphiLSP fills them: Line 1-based, CharIndex 0-based, Stop
  exclusive and on the same line - our TLspDiagnostic (1-based columns,
  ColTo exclusive) minus one. The IDE draws a mark over Start.CharIndex ..
  Stop.CharIndex on Start.Line and ignores Stop.Line.

  THE HOOK MAY RUN OFF THE MAIN THREAD (the editor parses in a thread of its
  own), so it reads only this unit's snapshot under a lock - never the
  session, never the IDE.
}

interface

type
  /// <summary>
  /// coreide's CodCmplt.IInternalSupportErrorInsight - no methods. The Code
  /// Insight manager implements it to tell the IDE that Error Insight for its
  /// files comes from it (see this unit's header, the marker).
  /// </summary>
  IInternalSupportErrorInsight = interface(IInterface)
    ['{CF888043-8F6A-4172-8A16-6C155F378FEA}']
  end;

procedure InitializeNativeErrorInsight;
procedure FinalizeNativeErrorInsight;

/// <summary>
/// The IDE selected (True) or deselected (False) PasTree as the Insight
/// Provider: pushes every file's errors we hold, or takes ours off the
/// buffers again so the next provider starts clean.
/// </summary>
procedure NativeErrorInsightProviderChanged(AActive: Boolean);

/// <summary>
/// The settings were saved: pushes or takes off ours as NativeErrorInsight-
/// Enabled and the current provider now say.
/// </summary>
procedure NativeErrorInsightSettingChanged;

/// <summary>
/// An export of the coreide that pairs with the linked designide, by its
/// mangled name - nil when this IDE has no such name. The one place this
/// package reaches into coreide; the Structure pane's icons use it too
/// (PasTreeIdePlugin.Outline, Parsernodes.ImageIndexOffset).
/// </summary>
function CoreIdeExport(const AName: string): Pointer;

/// <summary>
/// The Structure View's Errors folder again for AFileName: the outline calls
/// this right after it installs a context, because SetStructureContext drops
/// the folder - a field added to a class, so a new outline, made the folder
/// vanish while the same file's other errors kept it (2026-10-23).
/// </summary>
procedure NativeErrorInsightRestoreStructure(const AFileName: string);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.SyncObjs,
  System.Classes,
  System.Generics.Collections,
  DockForm,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments,   // IsPascalSourceFile
  PasTreeIdePlugin.CodeInsight,    // PasTreeIsActiveInsightProvider
  PasTreeIdePlugin.Settings;       // PasTreeErrorMaxSeverity

type
  TFindEditBuffer = function(const AFileName: string): Pointer;
  TUpdateErrorMarks = function(const AErrors: TOTAErrors; ABuffer: Pointer;
    AStructure: Boolean): Boolean;
  TUpdateViews = procedure(ABuffer: Pointer; AArg: Boolean);
  TLspGetErrors = function(const AName: string;
    var AErrors: TOTAErrors): Boolean;
  PLspGetErrors = ^TLspGetErrors;
  // A file's errors as last converted, under the path as the session gave it
  // (FindEditBuffer is handed that, not the lower-cased key).
  TSnapshot = record
    Path: string;
    Errors: TOTAErrors;
  end;

const
{$IFDEF WIN64}
  cFindEditBuffer = '_ZN12Editorbuffer14FindEditBufferEN6System13UnicodeStringE';
  cUpdateErrorMarks = '_ZN11Errorinsite16UpdateErrorMarksEN6System12'
    + 'DynamicArrayIN8Toolsapi9TOTAErrorEEEPN12Editorbuffer11TEditBufferEb';
  cUpdateViews = '_ZN12Editorbuffer11TEditBuffer11UpdateViewsEb';
  cLspGetErrors = '_ZN12Sourcemodule12LSPGetErrorsE';
{$ELSE}
  cFindEditBuffer = '@Editorbuffer@FindEditBuffer$qqrx20System@UnicodeString';
  cUpdateErrorMarks = '@Errorinsite@UpdateErrorMarks$qqrx42System@'
    + '%DynamicArray$18Toolsapi@TOTAError%p24Editorbuffer@TEditBuffero';
  cUpdateViews = '@Editorbuffer@TEditBuffer@UpdateViews$qqro';
  cLspGetErrors = '@Sourcemodule@LSPGetErrors';
{$ENDIF}

var
  GFindEditBuffer: TFindEditBuffer;
  GUpdateErrorMarks: TUpdateErrorMarks;
  GUpdateViews: TUpdateViews;
  GHookSlot: PLspGetErrors;
  GPrevHook: TLspGetErrors;
  GHooked: Boolean;
  GListener: Integer = 0;
  // Path (lower-cased) -> the errors last converted for it. Written on the
  // main thread, read by the hook from any thread - under GLock.
  GSnapshot: TDictionary<string, TSnapshot>;
  // Lower-cased path -> what we last put on that buffer: to skip a push that
  // changes nothing, and to take ours off again. Main thread only.
  GPushed: TDictionary<string, TSnapshot>;
  GNotifierIndex: Integer = -1;
  GLock: TCriticalSection;
  // Whether PasTree is the provider, as the main thread last saw it - the
  // hook may not ask the IDE.
  GActive: Boolean;
  GHookCalls: Integer;
  GHookCallsLogged: Boolean;
  // The readout of InitializeNativeErrorInsight, held until a server can
  // write it: the package loads before any project opens, and a line logged
  // then reaches nothing (first IDE run of 0.75.0, 2026-10-23).
  GReadout: string;

{ The coreide that pairs with the designide this package was linked against:
  same directory, same version suffix (designide370.bpl -> coreide370.bpl). }
function CoreIdeModule: HMODULE;
var
  LPath: string;
begin
  LPath := GetModuleName(FindHInstance(@BorlandIDEServices));
  LPath := ExtractFilePath(LPath) + StringReplace(ExtractFileName(LPath),
    'designide', 'coreide', [rfIgnoreCase]);
  Result := GetModuleHandle(PChar(LPath));
end;

function CoreIdeExport(const AName: string): Pointer;
var
  LCore: HMODULE;
begin
  LCore := CoreIdeModule;
  if LCore = 0 then
    Exit(nil);
  Result := GetProcAddress(LCore, PChar(AName));
end;

{ Our hook in Sourcemodule.LSPGetErrors. True = answered (AErrors is ours,
  possibly empty); anything not ours goes down the chain. }
function PasTreeGetErrors(const AName: string;
  var AErrors: TOTAErrors): Boolean;
var
  LSnap: TSnapshot;
  LOurs: Boolean;
begin
  AtomicIncrement(GHookCalls);
  LOurs := False;
  if Assigned(GLock) then
  begin
    GLock.Enter;
    try
      LOurs := GActive and Assigned(GSnapshot)
        and GSnapshot.TryGetValue(LowerCase(AName), LSnap);
    finally
      GLock.Leave;
    end;
  end;
  if LOurs then
  begin
    AErrors := Copy(LSnap.Errors);
    Exit(True);
  end;
  Result := Assigned(GPrevHook) and GPrevHook(AName, AErrors);
end;

function ToOtaErrors(const ADiags: TArray<TLspDiagnostic>): TOTAErrors;
var
  LDiag: TLspDiagnostic;
  LMax, LCount: Integer;
begin
  LMax := PasTreeErrorMaxSeverity;
  SetLength(Result, Length(ADiags));
  LCount := 0;
  for LDiag in ADiags do
  begin
    if LDiag.Severity > LMax then
      Continue;
    Result[LCount].Text := LDiag.Text;
    Result[LCount].Start.Line := LDiag.Row;
    Result[LCount].Start.CharIndex := LDiag.ColFrom - 1;
    Result[LCount].Stop.Line := LDiag.Row;
    Result[LCount].Stop.CharIndex := LDiag.ColTo - 1;
    Result[LCount].Severity := LDiag.Severity;
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

{ The open buffer's file name exactly as the IDE spells it, '' when APath is
  not open. FindEditBuffer compares names CASE-SENSITIVELY, and the session's
  paths come back from file URIs with the drive in lower case
  ("c:\Repos\...\Medhist.PAS" against the IDE's "C:\Repos\..."): handed
  the session's path, it found nothing, and every push after the first
  analysis was lost (AVImark, 2026-10-23 - the errors showed only through the
  pull, at the next start). }
function IdeBufferName(const APath: string): string;
var
  LServices: IOTAEditorServices;
  LIterator: IOTAEditBufferIterator;
  LName: string;
  I: Integer;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  if not LServices.GetEditBufferIterator(LIterator) then
    Exit;
  for I := 0 to LIterator.Count - 1 do
  begin
    LName := LIterator.EditBuffers[I].FileName;
    if SameText(LName, APath) then
      Exit(LName);
  end;
end;

function SameErrors(const A, B: TOTAErrors): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to High(A) do
      if (A[I].Text <> B[I].Text) or (A[I].Severity <> B[I].Severity)
        or (A[I].Start.Line <> B[I].Start.Line)
        or (A[I].Start.CharIndex <> B[I].Start.CharIndex)
        or (A[I].Stop.CharIndex <> B[I].Stop.CharIndex) then
        Exit(False);
end;

function IsTopBuffer(const AName: string): Boolean;
var
  LServices: IOTAEditorServices;
  LTop: IOTAEditBuffer;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LTop := LServices.TopBuffer;
  Result := Assigned(LTop) and SameText(LTop.FileName, AName);
end;

{ Puts AErrors on APath's buffer when it is open; nil takes them off.

  THE STRUCTURE VIEW'S ERRORS FOLDER IS ONE FOR THE WHOLE IDE, not one per
  buffer: UpdateErrorMarks(..., True) first empties it, then fills it with
  this buffer's errors and sends the status bar its count. 0.75.1 pushed
  every file the server published for with True, so the clean
  dmAVIDatabase.pas published after Medhist.PAS emptied the folder the
  moment Medhist had filled it (AVImark, 2026-10-23). DelphiLSP passes True
  for the active module alone; so do we - the editor's top buffer - and the
  others get their marks only. A tab switch re-pushes the new top buffer
  (EditorViewActivated), so the folder follows the editor.
  AForce: push even when the buffer already has exactly these errors. }
procedure Push(const APath: string; const AErrors: TOTAErrors;
  AForce: Boolean = False);
var
  LKey, LName: string;
  LBuffer: Pointer;
  LPrev, LSnap: TSnapshot;
  LHad, LTop, LChanged: Boolean;
begin
  if not (Assigned(GFindEditBuffer) and Assigned(GUpdateErrorMarks)) then
    Exit;
  LKey := LowerCase(APath);
  LHad := GPushed.TryGetValue(LKey, LPrev);
  if not AForce and ((LHad and SameErrors(LPrev.Errors, AErrors))
    or (not LHad and (AErrors = nil))) then
    Exit;
  LName := IdeBufferName(APath);
  if LName = '' then
  begin
    GPushed.Remove(LKey);   // closed: its marks went with the buffer
    Exit;
  end;
  LBuffer := GFindEditBuffer(LName);
  if LBuffer = nil then
  begin
    LspLogDetail('native error insight: no edit buffer for ' + LName);
    Exit;
  end;
  LTop := IsTopBuffer(LName);
  LChanged := GUpdateErrorMarks(AErrors, LBuffer, LTop);
  if LChanged and Assigned(GUpdateViews) then
    GUpdateViews(LBuffer, False);
  LspLogDetail(Format('native error insight: %d error(s) put on %s%s, %s',
    [Length(AErrors), ExtractFileName(LName),
     IfThen(LTop, ' and the Structure View', ''),
     IfThen(LChanged, 'views updated', 'nothing changed')]));
  if AErrors <> nil then
  begin
    LSnap.Path := APath;
    LSnap.Errors := AErrors;
    GPushed.AddOrSetValue(LKey, LSnap);
  end
  else
    GPushed.Remove(LKey);
end;

{ The editor brought another view to the front: its errors, or none, into
  the Structure View, which still holds the previous tab's. }
procedure ViewActivated(const AFileName: string);
var
  LSnap: TSnapshot;
  LFound: Boolean;
begin
  if (GLock = nil) or not GActive or not IsPascalSourceFile(AFileName) then
    Exit;
  GLock.Enter;
  try
    LFound := GSnapshot.TryGetValue(LowerCase(AFileName), LSnap);
  finally
    GLock.Leave;
  end;
  if LFound then
    Push(LSnap.Path, LSnap.Errors, True)
  else
    Push(AFileName, nil, True);
end;

procedure NativeErrorInsightRestoreStructure(const AFileName: string);
begin
  ViewActivated(AFileName);
end;

type
  TNativeErrorInsightNotifier = class(TNotifierObject,
    INTAEditServicesNotifier)
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

procedure TNativeErrorInsightNotifier.EditorViewActivated(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  if Assigned(EditView) and Assigned(EditView.Buffer) then
    ViewActivated(EditView.Buffer.FileName);
end;

procedure TNativeErrorInsightNotifier.WindowShow(
  const EditWindow: INTAEditWindow; Show, LoadedFromDesktop: Boolean);
begin
end;

procedure TNativeErrorInsightNotifier.WindowNotification(
  const EditWindow: INTAEditWindow; Operation: TOperation);
begin
end;

procedure TNativeErrorInsightNotifier.WindowActivated(
  const EditWindow: INTAEditWindow);
begin
end;

procedure TNativeErrorInsightNotifier.WindowCommand(
  const EditWindow: INTAEditWindow; Command, Param: Integer;
  var Handled: Boolean);
begin
end;

procedure TNativeErrorInsightNotifier.EditorViewModified(
  const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
end;

procedure TNativeErrorInsightNotifier.DockFormVisibleChanged(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TNativeErrorInsightNotifier.DockFormUpdated(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure TNativeErrorInsightNotifier.DockFormRefresh(
  const EditWindow: INTAEditWindow; DockForm: TDockableForm);
begin
end;

procedure LogPending;
begin
  if (GReadout <> '') and LspLogToServer(GReadout) then
    GReadout := '';
  if GHookCallsLogged or (GHookCalls = 0) then
    Exit;
  GHookCallsLogged := LspLogToServer('native error insight: the IDE pulls '
    + 'errors through LSPGetErrors too');
end;

procedure OnDiagnosticsChanged(const APath: string);
var
  LDiags: TArray<TLspDiagnostic>;
  LSnap: TSnapshot;
begin
  if not IsPascalSourceFile(APath) then
    Exit;
  if not LspTryGetDiagnostics(APath, LDiags) then
    LDiags := nil;
  LSnap.Path := APath;
  LSnap.Errors := ToOtaErrors(LDiags);
  GLock.Enter;
  try
    GActive := NativeErrorInsightEnabled and PasTreeIsActiveInsightProvider;
    GSnapshot.AddOrSetValue(LowerCase(APath), LSnap);
  finally
    GLock.Leave;
  end;
  LogPending;
  if GActive then
    Push(APath, LSnap.Errors)
  else
    LspLogDetail('native error insight: off or PasTree is not the '
      + 'provider, ' + ExtractFileName(APath) + ' left to the IDE');
end;

procedure NativeErrorInsightProviderChanged(AActive: Boolean);
var
  LSnaps: TArray<TSnapshot>;
  LSnap: TSnapshot;
begin
  if GLock = nil then
    Exit;
  AActive := AActive and NativeErrorInsightEnabled;
  GLock.Enter;
  try
    GActive := AActive;
    LSnaps := GSnapshot.Values.ToArray;
  finally
    GLock.Leave;
  end;
  if AActive then
    for LSnap in LSnaps do
      Push(LSnap.Path, LSnap.Errors)
  else
    for LSnap in GPushed.Values.ToArray do
      Push(LSnap.Path, nil);
end;

procedure NativeErrorInsightSettingChanged;
begin
  NativeErrorInsightProviderChanged(PasTreeIsActiveInsightProvider);
end;

procedure InitializeNativeErrorInsight;
var
  LCore: HMODULE;
  LMissing: string;
  LEditor: IOTAEditorServices;

  function Find(const AName, AShort: string): Pointer;
  begin
    Result := GetProcAddress(LCore, PChar(AName));
    if Result = nil then
      LMissing := LMissing + ' ' + AShort;
  end;

begin
  if GLock <> nil then
    Exit;
  GLock := TCriticalSection.Create;
  GSnapshot := TDictionary<string, TSnapshot>.Create;
  GPushed := TDictionary<string, TSnapshot>.Create;
  LCore := CoreIdeModule;
  if LCore = 0 then
  begin
    GReadout := 'native error insight: coreide is not loaded - off';
    Exit;
  end;
  @GFindEditBuffer := Find(cFindEditBuffer, 'FindEditBuffer');
  @GUpdateErrorMarks := Find(cUpdateErrorMarks, 'UpdateErrorMarks');
  @GUpdateViews := Find(cUpdateViews, 'UpdateViews');
  GHookSlot := Find(cLspGetErrors, 'LSPGetErrors');
  if GHookSlot <> nil then
  begin
    GPrevHook := GHookSlot^;
    GHookSlot^ := PasTreeGetErrors;
    GHooked := True;
  end;
  if LMissing <> '' then
    GReadout := 'native error insight: not exported by this IDE:' + LMissing
  else
    GReadout := Format('native error insight: ready (LSPGetErrors was %s)',
      [IfThen(Assigned(GPrevHook), 'set - chained', 'nil')]);
  GListener := LspAddDiagnosticsChangedListener(OnDiagnosticsChanged);
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditor) then
    GNotifierIndex := LEditor.AddNotifier(TNativeErrorInsightNotifier.Create);
end;

procedure FinalizeNativeErrorInsight;
var
  LEditor: IOTAEditorServices;
begin
  LspRemoveDiagnosticsChangedListener(GListener);
  GListener := 0;
  if (GNotifierIndex >= 0)
    and Supports(BorlandIDEServices, IOTAEditorServices, LEditor) then
    LEditor.RemoveNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  if GLock = nil then
    Exit;
  // Ours off the buffers while the IDE is still whole enough to draw.
  NativeErrorInsightProviderChanged(False);
  // Only our own value goes back: whoever assigned after us keeps theirs.
  if GHooked and (@GHookSlot^ = @PasTreeGetErrors) then
    GHookSlot^ := GPrevHook;
  GHooked := False;
  GHookSlot := nil;
  GPrevHook := nil;
  GFindEditBuffer := nil;
  GUpdateErrorMarks := nil;
  GUpdateViews := nil;
  FreeAndNil(GSnapshot);
  FreeAndNil(GPushed);
  FreeAndNil(GLock);
end;

end.
