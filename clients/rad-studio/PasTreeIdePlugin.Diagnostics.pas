unit PasTreeIdePlugin.Diagnostics;

{
  THE FILE-TRAIT SPIKE (clients/rad-studio/SPEC.md, "the open experiment"):
  can a plugin feed the editor's NATIVE error squiggles by registering an
  IOTAModuleErrors implementation as a personality trait?

  What the declarations promise: IOTAModuleErrors' own comment says the
  editor queries a module for it "to show error hints and red underlines".
  What they do NOT say is whether the IDE, failing a QueryInterface on the
  module itself, falls back to IOTAPersonalityServices.GetFileTrait - the
  registration path this unit uses (AddPersonalityTrait on the Delphi
  personality; there is no public way to implement the module's own QI).
  That is the one unknown the whole diagnostics plan hangs on, and no amount
  of reading settles it - hence a spike.

  READOUT: the Build tab logs one line the FIRST time GetErrors is ever
  called. If that line appears (and squiggles follow), native diagnostics
  are nearly free and the painted-squiggle path in SPEC.md is dead code
  never to be written. If it never appears across a session with a
  diagnostic-bearing file open, the answer is "the IDE does not consult
  traits for this interface" - record it in SPEC.md and take the paint path.

  2026-08-22: a full live session produced NO readout, and the silence was
  ambiguous - registration itself logged nothing. Now the Build tab says
  ARMED/NOT ARMED at registration, and a one-shot probe on the first
  didOpen splits the remaining causes: whether FindFileTrait actually
  reaches our registration, and whether the module already answers
  IOTAModuleErrors natively (the interface's own doc says the editor
  queries the MODULE - a native answer there means the trait route is dead
  no matter how correct the registration).

  The data is real either way: the server's publishDiagnostics, cached per
  file by the session (LspTryGetDiagnostics), so a positive spike is
  instantly a working feature, not a mock.
}

interface

procedure InitializeDiagnosticsTrait;
procedure FinalizeDiagnosticsTrait;

{ One-shot probe, called on the first didOpen of a Pascal file (the earliest
  moment a real module exists): logs to the Build tab whether the trait
  lookup the IDE would use actually reaches our registration, and whether
  the MODULE itself already answers IOTAModuleErrors natively - the two
  facts that split "registered wrong" from "the editor never consults
  traits" from "the native module wins the QI". Added 2026-08-22 after a
  full live session produced no GetErrors readout. }
procedure ProbeDiagnosticsTrait(const AFileName: string);

implementation

uses
  System.SysUtils,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.LspDocuments;

var
  GTrait: IInterface;
  GQueried: Boolean = False;   // the spike's readout: first pull logged once
  GProbed: Boolean = False;    // the registration probe: runs once per session

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

type
  TPasModuleErrorsTrait = class(TInterfacedObject, IOTAModuleErrors)
  public
    function GetErrors(const AFileName: string): TOTAErrors;
  end;

function TPasModuleErrorsTrait.GetErrors(const AFileName: string): TOTAErrors;
var
  LDiags: TArray<TLspDiagnostic>;
  LIdx: Integer;
begin
  if not GQueried then
  begin
    GQueried := True;
    LogDiagnostic('file-trait spike POSITIVE: the IDE queried GetErrors('
      + AFileName + ') - native squiggles are reachable.');
  end;
  Result := nil;
  if (AFileName = '') or not IsPascalSourceFile(AFileName) then
    Exit;
  if not LspTryGetDiagnostics(AFileName, LDiags) then
    Exit;
  SetLength(Result, Length(LDiags));
  for LIdx := 0 to High(LDiags) do
  begin
    Result[LIdx].Text := LDiags[LIdx].Text;
    Result[LIdx].Start.Line := LDiags[LIdx].Row;
    Result[LIdx].Start.CharIndex := LDiags[LIdx].ColFrom - 1;
    Result[LIdx].Stop.Line := LDiags[LIdx].Row;
    // Stop = Start means "one character" per the record's own doc, so an
    // empty span degrades to that rather than to a negative width.
    if LDiags[LIdx].ColTo > LDiags[LIdx].ColFrom then
      Result[LIdx].Stop.CharIndex := LDiags[LIdx].ColTo - 1
    else
      Result[LIdx].Stop.CharIndex := LDiags[LIdx].ColFrom - 1;
    // The LSP severities were normalized to 1..3 by the session - the same
    // three values TOTAError declares (error/warning/hint).
    Result[LIdx].Severity := LDiags[LIdx].Severity;
  end;
end;

procedure InitializeDiagnosticsTrait;
var
  LServices: IOTAPersonalityServices100;
begin
  if GTrait <> nil then
    Exit;
  if not Supports(BorlandIDEServices, IOTAPersonalityServices100,
       LServices) then
  begin
    // A silent early-exit here cost a whole live session (2026-08-22): the
    // spike read as "the IDE never asked" when nothing proved it was armed.
    LogDiagnostic('file-trait spike NOT ARMED: no IOTAPersonalityServices100');
    Exit;
  end;
  GTrait := TPasModuleErrorsTrait.Create;
  // Personality-wide rather than per-file-type: the file-type NAME constants
  // live in PersonalityConst, which ships as DCU only, and GetFileTrait's
  // SearchDefault fallback reaches personality traits anyway - the widest
  // net the spike can cast.
  LServices.AddPersonalityTrait(sDelphiPersonality, IOTAModuleErrors, GTrait);
  LogDiagnostic('file-trait spike ARMED: IOTAModuleErrors trait registered');
end;

procedure ProbeDiagnosticsTrait(const AFileName: string);
var
  LServices: IOTAPersonalityServices;
  LModuleServices: IOTAModuleServices;
  LFound: IInterface;
  LModule: IOTAModule;
  LModuleErrors: IOTAModuleErrors;
begin
  if GProbed or (GTrait = nil) or (AFileName = '') then
    Exit;
  GProbed := True;

  // 1. Does the trait LOOKUP the IDE would run reach our registration?
  if Supports(BorlandIDEServices, IOTAPersonalityServices, LServices) then
  begin
    LFound := LServices.FindFileTrait(AFileName, IOTAModuleErrors);
    if LFound = nil then
      LogDiagnostic('probe: FindFileTrait(IOTAModuleErrors) answers NIL - '
        + 'the personality-wide registration is invisible to the lookup')
    else if LFound = GTrait then
      LogDiagnostic('probe: FindFileTrait answers OUR trait - registration '
        + 'is correct; if GetErrors stays silent, the editor simply never '
        + 'consults traits for this interface')
    else
      LogDiagnostic('probe: FindFileTrait answers a DIFFERENT trait - '
        + 'something else already owns IOTAModuleErrors for this file');
  end
  else
    LogDiagnostic('probe: no IOTAPersonalityServices - FindFileTrait '
      + 'unavailable');

  // 2. Does the MODULE answer IOTAModuleErrors natively? The interface's
  // own doc says the editor queries the module; a native answer there
  // means the trait can never win.
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
  begin
    LModule := LModuleServices.FindModule(AFileName);
    if LModule = nil then
      LogDiagnostic('probe: FindModule answered nil for ' + AFileName)
    else if Supports(LModule, IOTAModuleErrors, LModuleErrors) then
      LogDiagnostic(Format('probe: the module itself implements '
        + 'IOTAModuleErrors natively (GetErrors answers %d entries) - the '
        + 'editor gets errors there and the trait route is DEAD',
        [Length(LModuleErrors.GetErrors(AFileName))]))
    else
      LogDiagnostic('probe: the module does NOT implement IOTAModuleErrors '
        + '- if the editor QIs only the module, nobody answers and the '
        + 'trait fallback is the open question');
  end;
end;

procedure FinalizeDiagnosticsTrait;
var
  LServices: IOTAPersonalityServices100;
begin
  if GTrait = nil then
    Exit;
  if Supports(BorlandIDEServices, IOTAPersonalityServices100, LServices) then
    LServices.RemovePersonalityTrait(sDelphiPersonality, IOTAModuleErrors);
  GTrait := nil;
end;

end.
