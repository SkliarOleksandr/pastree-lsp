unit PasTreeIdePlugin.ConfigSwitch;

{
  WHEN A CONFIGURATION SWITCH IS A SWITCH - the debounce in front of the
  restart TLspSession.CheckConfigSwitch asks for on its timer.

  The server fixes its configuration and platform at initialize, so a switch
  in the IDE means a new server process. Until 0.77.0 only EnsureSession, the
  gate in front of a REQUEST, compared them, and everything painted without a
  request - the inactive-code grey, the squiggles, the type colouring, the
  status panel - showed the other configuration's view until the next
  Ctrl+Click (AVImark, 2026-10-15: Debug -> Release -> Debug in the IDE, the
  server on Debug throughout and nothing saying so).

  ToolsAPI has no event for an active configuration or platform change, so a
  timer reads both. A value is acted on only once it has HELD for
  cConfigSwitchHoldMs: a pass over several configurations quicker than that
  restarts once, for the last one, and a switch straight back restarts
  nothing.
  Each restart is a full analysis on a process with no parse donor (5.8 s on
  AVImark), so the rule is worth its harness.

  Pure string and number work - no ToolsAPI - so LspTextSmoke holds it to
  cases.
}

interface

const
  // The typing pause of PasTreeIdePlugin.IdleSync (cIdleMs). 1000 in 0.77.0,
  // to let a click-through of the combo pass, was a second's stale view on
  // every real switch - and nobody clicks through configurations (Alex,
  // 2026-11-02).
  cConfigSwitchHoldMs = 250;

type
  TConfigSwitchVerdict = (
    csSame,      // the server runs what the IDE has selected
    csWaiting,   // something else is selected, not for long enough yet
    csRestart);  // it has held: restart the server now

  TConfigSwitchWatch = record
  private
    FPending: string;
    FSince: UInt64;
  public
    /// <summary>
    /// One look at the selection. AStarted is what the running server was
    /// started for, ASelected what the IDE has selected now - each a
    /// configuration and a platform joined by ConfigSwitchKey. ANowMs is a
    /// millisecond clock (GetTickCount64). csRestart is answered once per
    /// held value; the watch is empty after it.
    /// </summary>
    function Observe(const AStarted, ASelected: string;
      ANowMs: UInt64): TConfigSwitchVerdict;
    /// <summary>Forgets the pending value - a restart happened anyway.</summary>
    procedure Reset;
  end;

/// <summary>A configuration and a platform as one comparable value.</summary>
function ConfigSwitchKey(const AConfig, APlatform: string): string;

/// <summary>
/// The log line's account of a switch: 'active configuration changed
/// (Debug -> Release)', 'active platform changed (Win32 -> Win64)', or both
/// when both moved.
/// </summary>
function ConfigSwitchWhat(const AOldConfig, AOldPlatform, ANewConfig,
  ANewPlatform: string): string;

implementation

uses
  System.SysUtils;

function ConfigSwitchKey(const AConfig, APlatform: string): string;
begin
  // #0 cannot occur in either name, so no two pairs share a key.
  Result := AConfig + #0 + APlatform;
end;

function ConfigSwitchWhat(const AOldConfig, AOldPlatform, ANewConfig,
  ANewPlatform: string): string;
var
  LConfigMoved, LPlatformMoved: Boolean;
begin
  LConfigMoved := not SameText(AOldConfig, ANewConfig);
  LPlatformMoved := not SameText(AOldPlatform, ANewPlatform);
  if LConfigMoved and LPlatformMoved then
    Result := Format('active configuration and platform changed '
      + '(%s %s -> %s %s)', [AOldConfig, AOldPlatform, ANewConfig, ANewPlatform])
  else if LPlatformMoved then
    Result := Format('active platform changed (%s -> %s)',
      [AOldPlatform, ANewPlatform])
  else
    Result := Format('active configuration changed (%s -> %s)',
      [AOldConfig, ANewConfig]);
end;

{ TConfigSwitchWatch }

function TConfigSwitchWatch.Observe(const AStarted, ASelected: string;
  ANowMs: UInt64): TConfigSwitchVerdict;
begin
  // SameText, as EnsureSession compares: the two must never disagree about
  // what "changed" means, or the timer restarts what a request would keep.
  if SameText(ASelected, AStarted) then
  begin
    Reset;
    Exit(csSame);
  end;
  if (FPending = '') or not SameText(FPending, ASelected) then
  begin
    // A new value: its hold starts now. A switch on to a third value
    // starts it again, so a pass over several restarts once, for the last.
    FPending := ASelected;
    FSince := ANowMs;
    Exit(csWaiting);
  end;
  if ANowMs - FSince < cConfigSwitchHoldMs then
    Exit(csWaiting);
  Reset;
  Result := csRestart;
end;

procedure TConfigSwitchWatch.Reset;
begin
  FPending := '';
  FSince := 0;
end;

end.
