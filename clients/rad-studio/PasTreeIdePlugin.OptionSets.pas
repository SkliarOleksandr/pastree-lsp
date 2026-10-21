unit PasTreeIdePlugin.OptionSets;

{
  THE IDE'S EDITOR OPTION SETS, AND THE ONE DOOR TO THE ENVIRONMENT OPTIONS
  THAT LIVE IN THEM (0.73.8).

  Tools > Options > Editor > Language keeps one option set per language -
  Borland.EditOptions.Pascal ("Delphi"), .Default, .C, .C#, .HTML and so on,
  ToolsAPI's cDefEd* constants - and some environment options are fields of
  those sets rather than global values: InsightManager (the Insight
  Provider), ErrorInsightLevel and ErrorInsightMarks among them.
  IOTAEnvironmentOptions.Values reads and writes such a field in the set the
  IDE treats as CURRENT at that moment - the call cannot name a set - and the
  IDE moves that on its own, as a side effect of ordinary editor work:
  creating a view or a buffer, laying out a gutter, checking a highlighter,
  updating error marks all make the set of the file at hand current, Default
  for a file no set claims (coreide370, TEnvironmentOptions.
  MoveToOptionsForFileType and its callers, read 2026-10-21). At package load
  no set is current at all and the reads answer the fields' defaults. A write
  is saved at once - the setter calls TPropSet.SavePropValues - so a write
  into the wrong set outlives the session.

  WHY IT MATTERS: THE GATE. The IDE hands a unit to DelphiLSP only when
  IOTACodeInsightServices.HandlesFile(File, 'Borland.CodeInsight.LSP.Pascal')
  answers True, and that walks the sets in their own order (C, C#, Default,
  HTML, ... Pascal ...), takes the FIRST whose Insight Manager is that id and
  answers by THAT set's extensions. Default has none. So Default holding
  DelphiLSP's id gives DelphiLSP the project and never a unit: no
  completion, no Error Insight, an empty Structure view, and nothing in any
  log says why (2026-10-20: PasTree's put-back of DelphiLSP had landed in
  Default). Classic Pascal (Borland.CodeInsight.Pascal) is gated the same way
  by its own id.

  THE DOOR, WithPascalOptionSet: the caller's reads and writes run with the
  Pascal set current. Already current, they run as they are. Otherwise they
  run between BeginUpdate and EndUpdate of the Pascal set's IOTAEditOptions
  (IOTAEditorServices.GetEditOptions(cDefEdPascal)): the wrapper's
  BeginUpdate remembers the current set and makes its own current, EndUpdate
  puts the remembered one back - none, at package load (coreide370, read
  2026-10-21). Either way the probe - SourceOptionIDString, the sets' "Source
  Opt Internal ID" field, read through the same Values, so it names exactly
  the set an access reaches - must read Pascal before the caller runs, or
  nothing runs and the caller asks again later. Inside, touch nothing of the
  same IOTAEditOptions object: its other properties switch and put back the
  set through the same remembered slot.

  THE PRICE: the last EndUpdate does what any change through IOTAEditOptions
  does - TEnvironmentOptions.SendModified and SaveOptions, a save of every
  environment option. So the door is for the one-off moments (package load,
  the settings dialog's OK, a provider picked in Tools > Options, unload);
  what is asked often - the mark style per paint, the level follow, the gate
  recheck - peeks instead (PeekPascalSetOption): it reads only while Pascal is
  current by itself. So does a retry of a choice whose door did not open or
  whose value did not read (PascalOptionSetIsCurrent first): retried once a
  second, a bracket would save every option once a second.

  THE HEALTH CHECK, CheckInsightGate: while the Pascal set's provider is
  DelphiLSP (or Classic), HandlesFile on a .pas name must answer True for it.
  Asked when a Pascal editor becomes current, every ten seconds while one is,
  and after the provider choice is applied. False means a set ahead of Pascal
  carries the id; the check names it - read-only, through HandlesFile on a
  name of each set's type - and says so in the Build tab with the remedy. It
  REPAIRS NOTHING, by Alex's call (2026-10-21): PasTree writes no other set
  now, so what the check can still find is the IDE's own doing - the
  Language page of Tools > Options writes its provider combobox's item into
  whichever set it shows, Default included
  (TNewEditorSourceOptionsPg.CodeInsightManagerComboSelect) - and that is
  reported, not overwritten. Default's provider box is greyed on that page
  (its InsightChangable is False), so its remedy is the one in
  docs/diagnosing.md.

  NOT HERE: DeclarationInformation (Tooltip symbol insight) - a field of the
  Code Insight sets, which take no part in the gate. See
  PasTreeIdePlugin.TooltipSymbolInsight.
}

interface

uses
  System.SysUtils;   // TProc

/// <summary>
/// The editor option set IOTAEnvironmentOptions.Values reaches right now, by
/// its IDString ('Borland.EditOptions.Pascal', '...Default'), or '' while
/// none is current (package load) or the probe does not read.
/// </summary>
function CurrentOptionSet: string;

/// <summary>
/// ASet as a log line shows it: quoted, or what an empty one means.
/// </summary>
function OptionSetText(const ASet: string): string;

/// <summary>
/// Whether the Pascal set is current by itself - the door then opens without
/// a bracket, and so without the save of every option one costs. What
/// retries a choice once a second asks this first.
/// </summary>
function PascalOptionSetIsCurrent: Boolean;

/// <summary>
/// THE DOOR: runs AProc with the Pascal option set current - as it is when
/// it already is, between BeginUpdate and EndUpdate of the Pascal set
/// otherwise, which puts back the set that was current. False, and AProc not
/// run, when the probe does not read Pascal. Nested calls find Pascal
/// current and run as they are, so one bracket can hold several accesses -
/// and should: each bracket ends in a save of every option (see the header).
/// </summary>
function WithPascalOptionSet(const AProc: TProc): Boolean;

/// <summary>
/// One field of the Pascal set, through WithPascalOptionSet. False, AValue
/// Unassigned, when the door did not open.
/// </summary>
function ReadPascalSetOption(const AName: string; out AValue: Variant): Boolean;

/// <summary>
/// One field written into the Pascal set, through WithPascalOptionSet; the
/// IDE saves it at once. False, nothing written, when the door did not open.
/// </summary>
function WritePascalSetOption(const AName: string;
  const AValue: Variant): Boolean;

/// <summary>
/// One field of the Pascal set when that is current by itself, False
/// otherwise - for what is asked often, which must not pay for a bracket.
/// </summary>
function PeekPascalSetOption(const AName: string; out AValue: Variant): Boolean;

/// <summary>
/// The health check of the IDE's provider gate - see the header. A no-op
/// unless the Pascal set is current; AWhen names the moment for the log.
/// Logs changes of state only, so it may be asked often.
/// </summary>
procedure CheckInsightGate(const AWhen: string);

/// <summary>
/// For the editor's mouse-move path: at most once a second, notes whether
/// the Pascal set is current and runs CheckInsightGate when it has become so,
/// and every ten seconds while it stays so. Hands queued log lines to the
/// LSP log.
/// </summary>
procedure SyncOptionSets;

implementation

uses
  System.StrUtils,
  System.Variants,
  Winapi.Windows,
  ToolsAPI,
  PasTreeIdePlugin.LspSession;   // LspLogToServer

const
  // The probe: the sets' "Source Opt Internal ID" field, as
  // IOTAEnvironmentOptions names it (coreide370, EditorSourceOptions; the
  // same name in 22.0 and 23.0).
  cEnvOptionSetId = 'SourceOptionIDString';
  cEnvInsightManager = 'InsightManager';
  // The providers HandlesFile gates by their own id (delphicoreide370,
  // TLSPPascalManager.HandlesFile and TPascalKibitzManager.HandlesFile) -
  // what a third-party manager does with the gate is its own business.
  cGatedManagers: array[0..1] of string = ('Borland.CodeInsight.LSP.Pascal',
    'Borland.CodeInsight.Pascal');
  cGatedManagerNames: array[0..1] of string = ('DelphiLSP', 'Classic');
  // HandlesFile answers by a file's extension alone: a name of the Pascal
  // set's type, and the stem for the other sets' types.
  cProbePascalFile = 'PasTreeProbe.pas';
  cProbeStem = 'PasTreeProbe.';
  cSyncMs = 1000;
  cGateRecheckMs = 10000;

type
  TGateState = (gsUnknown, gsHealthy, gsNotGated, gsBroken);

var
  GSyncAt: UInt64 = 0;
  GGateCheckAt: UInt64 = 0;
  // The last SyncOptionSets found the Pascal set current.
  GPascalSeen: Boolean = False;
  GGateState: TGateState = gsUnknown;
  // Every line until a session can take it, as PasTreeIdePlugin.CodeInsight
  // keeps the provider's.
  GLogLines: TArray<string> = nil;

procedure FlushLog;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GLogLines) do
    if not LspLogToServer(GLogLines[LIdx]) then
    begin
      Delete(GLogLines, 0, LIdx);
      Exit;
    end;
  GLogLines := nil;
end;

procedure OptionSetLog(const AText: string);
begin
  if Length(GLogLines) < 50 then
    GLogLines := GLogLines + ['option sets: ' + AText];
  FlushLog;
end;

{ A finding the user has to act on or know about: the Build tab as well. }
procedure OptionSetAlarm(const AText: string);
var
  LMessages: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessages) then
    LMessages.AddTitleMessage('[pastree] ' + AText);
  OptionSetLog(AText);
end;

function EnvOptions: IOTAEnvironmentOptions;
var
  LServices: IOTAServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    Result := LServices.GetEnvironmentOptions;
end;

function CurrentOptionSet: string;
var
  LOptions: IOTAEnvironmentOptions;
begin
  Result := '';
  try
    LOptions := EnvOptions;
    if Assigned(LOptions) then
      Result := Trim(VarToStrDef(LOptions.Values[cEnvOptionSetId], ''));
  except
    Result := '';
  end;
end;

function OptionSetText(const ASet: string): string;
begin
  if ASet = '' then
    Result := 'none (no editor has made one current yet)'
  else
    Result := '"' + ASet + '"';
end;

function PascalOptionSetIsCurrent: Boolean;
begin
  Result := SameText(CurrentOptionSet, cDefEdPascal);
end;

function WithPascalOptionSet(const AProc: TProc): Boolean;
var
  LEditor: IOTAEditorServices;
  LPascal: IOTAEditOptions;
begin
  if PascalOptionSetIsCurrent then
  begin
    AProc();
    Exit(True);
  end;
  Result := False;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditor) then
    Exit;
  LPascal := LEditor.GetEditOptions(cDefEdPascal);
  if not Assigned(LPascal) then
    Exit;
  LPascal.BeginUpdate;
  try
    // The probe, not the bracket's word for it: an IDE whose BeginUpdate
    // made no set current gets nothing written.
    if not PascalOptionSetIsCurrent then
      Exit;
    AProc();
    Result := True;
  finally
    LPascal.EndUpdate;
  end;
end;

function ReadPascalSetOption(const AName: string; out AValue: Variant): Boolean;
var
  LOptions: IOTAEnvironmentOptions;
  LValue: Variant;
begin
  LValue := Unassigned;
  LOptions := EnvOptions;
  Result := Assigned(LOptions) and WithPascalOptionSet(
    procedure
    begin
      LValue := LOptions.Values[AName];
    end);
  AValue := LValue;
end;

function WritePascalSetOption(const AName: string;
  const AValue: Variant): Boolean;
var
  LOptions: IOTAEnvironmentOptions;
  LValue: Variant;
begin
  LValue := AValue;
  LOptions := EnvOptions;
  Result := Assigned(LOptions) and WithPascalOptionSet(
    procedure
    begin
      LOptions.Values[AName] := LValue;
    end);
end;

function PeekPascalSetOption(const AName: string; out AValue: Variant): Boolean;
var
  LOptions: IOTAEnvironmentOptions;
begin
  AValue := Unassigned;
  LOptions := EnvOptions;
  Result := Assigned(LOptions) and PascalOptionSetIsCurrent;
  if Result then
    AValue := LOptions.Values[AName];
end;

{ The first plain extension of a set's list - an '&' entry names a mask
  file, not an extension; '' for a set without one (Default). }
function FirstExtension(const AExtensions: string): string;
var
  LExt: string;
begin
  for LExt in AExtensions.Split([';']) do
    if (Trim(LExt) <> '') and
       (Trim(LExt).IndexOfAny(['&', '*', '?', '.', '\', '/', ' ']) < 0) then
      Exit(Trim(LExt));
  Result := '';
end;

{ The set the gate answers AManager by, among those it asks before Pascal,
  as Tools > Options names it - found without making any set current:
  HandlesFile answers by the extensions of the first set holding the id, so
  the set whose own extension it answers True for is that set. When none of
  them does, the first is one without extensions: named when there is one
  such set ahead of Pascal (Default), '' otherwise. }
function NameSetAheadOfPascal(const AServices: IOTACodeInsightServices;
  const AManager: string): string;
var
  LEditor: IOTAEditorServices;
  LSet: IOTAEditOptions;
  LIdx, LBare: Integer;
  LExt, LBareName: string;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditor) then
    Exit;
  LBare := 0;
  LBareName := '';
  // EditorOptions[] is the list HandlesFile walks, in its order.
  for LIdx := 0 to LEditor.EditOptionsCount - 1 do
  begin
    LSet := LEditor.EditorOptions[LIdx];
    if not Assigned(LSet) then
      Continue;
    if SameText(LSet.IDString, cDefEdPascal) then
      Break;
    LExt := FirstExtension(LSet.Extensions);
    if LExt = '' then
    begin
      Inc(LBare);
      LBareName := LSet.OptionsName;
    end
    else if AServices.HandlesFile(cProbeStem + LExt, AManager) then
      Exit(LSet.OptionsName);
  end;
  if LBare = 1 then
    Result := LBareName;
end;

function GatedName(const AManager: string): string;
begin
  Result := AManager;
  if SameText(AManager, cGatedManagers[0]) then
    Result := cGatedManagerNames[0]
  else if SameText(AManager, cGatedManagers[1]) then
    Result := cGatedManagerNames[1];
end;

procedure CheckInsightGate(const AWhen: string);
var
  LServices: IOTACodeInsightServices;
  LValue: Variant;
  LManager, LName, LSet, LWhen: string;
begin
  try
    if not Supports(BorlandIDEServices, IOTACodeInsightServices, LServices) or
       not PeekPascalSetOption(cEnvInsightManager, LValue) then
      Exit;
    LWhen := AWhen;
    if GGateState = gsUnknown then
      LWhen := 'first check of the session (' + AWhen + ')';
    LManager := Trim(VarToStrDef(LValue, ''));
    if not MatchText(LManager, cGatedManagers) then
    begin
      if GGateState <> gsNotGated then
        OptionSetLog(LWhen + ': the Pascal set''s provider is "' + LManager
          + '", not one the IDE gates by HandlesFile - nothing to check');
      GGateState := gsNotGated;
      Exit;
    end;
    LName := GatedName(LManager);
    if LServices.HandlesFile(cProbePascalFile, LManager) then
    begin
      if GGateState = gsBroken then
        OptionSetAlarm(LName + ' serves Pascal units again (' + AWhen + ').')
      else if GGateState <> gsHealthy then
        OptionSetLog(LWhen + ': HandlesFile(' + cProbePascalFile + ', "'
          + LManager + '") is True - the IDE hands ' + LName
          + ' the Pascal units');
      GGateState := gsHealthy;
      Exit;
    end;
    if GGateState = gsBroken then
      Exit;   // said already
    GGateState := gsBroken;
    LSet := NameSetAheadOfPascal(LServices, LManager);
    if LSet = '' then
      OptionSetAlarm(LName + ' is refused every Pascal unit (no completion,'
        + ' no Error Insight, an empty Structure view): an editor option set'
        + ' the IDE asks before Delphi''s names it ("' + LManager + '") as'
        + ' its Code insight manager, and PasTree could not tell which. See'
        + ' docs/diagnosing.md, "DelphiLSP gets no unit".')
    else
      OptionSetAlarm(LName + ' is refused every Pascal unit (no completion,'
        + ' no Error Insight, an empty Structure view): the editor option set'
        + ' "' + LSet + '" names it ("' + LManager + '") as its Code insight'
        + ' manager, and the IDE asks that set before Delphi''s. Remedy:'
        + ' Tools > Options > Editor > Language, choose "' + LSet + '", set'
        + ' its Code insight manager to that language''s own, OK - where'
        + ' that box is greyed (Default), see docs/diagnosing.md, "DelphiLSP'
        + ' gets no unit".');
  except
    on E: Exception do
      OptionSetLog('the provider gate check failed: ' + E.ClassName + ': '
        + E.Message);
  end;
end;

procedure SyncOptionSets;
var
  LNow: UInt64;
  LPascal: Boolean;
begin
  if GLogLines <> nil then
    FlushLog;
  LNow := GetTickCount64;
  if LNow < GSyncAt then
    Exit;
  GSyncAt := LNow + cSyncMs;
  LPascal := PascalOptionSetIsCurrent;
  if LPascal and (not GPascalSeen or (LNow >= GGateCheckAt)) then
  begin
    GGateCheckAt := LNow + cGateRecheckMs;
    if not GPascalSeen then
      CheckInsightGate('a Pascal editor is current')
    else
      CheckInsightGate('recheck');
  end;
  GPascalSeen := LPascal;
end;

end.
