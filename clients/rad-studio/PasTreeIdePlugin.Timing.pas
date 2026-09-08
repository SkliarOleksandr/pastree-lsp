unit PasTreeIdePlugin.Timing;

{
  MAIN-THREAD TIMING LINES, into the server log.

  Written for one report (2026-09-08): a six-core i5 where the IDE shows a
  busy cursor for about half a second on every typing pause while this
  package is loaded, and nothing at all with it disabled. Nobody with a fast
  machine can see it, so the machine that can has to say where the time goes.
  Every stage of the idle document sync - reading the editor buffers,
  comparing, building the JSON, writing the pipe - is timed by the code that
  performs it and reported through here as one line per stage.

  THE SERVER LOG, NOT A FILE OF ITS OWN. The lines land in the same
  <project>-pastree-lsp.log the server writes, so a reader sees "the client
  spent 400 ms writing didChange" next to "analysis started: full" without
  matching timestamps across two files. Appending is FILE_APPEND_DATA with
  shared access, the same arrangement the transport already relies on for the
  server's stderr (see CreatePipePair's caller): the OS puts every write at
  the current end, so lines interleave whole. The prefix "[ide ...]" is what
  tells them apart from the server's own.

  NO IDE, NO THREADS, NO STATE beyond the path. Dependency-free on purpose:
  LspTransport and LspClient are IDE-free so the harnesses can drive them,
  and they report through here too. The path is set by the session that
  builds the server options: the active project's log when ADVANCED logging
  is on, '' otherwise - and '' makes every call a no-op. Advanced rather than
  the plain switch because this is several lines per typing pause, exactly
  the volume the advanced switch keeps out of the ordinary log; a user who
  reports a slow editor is asked to turn it on for the measurement.

  ONE OPEN-WRITE-CLOSE PER LINE. Cheaper to reason about than a held handle
  (nothing to close at unload, nothing a crashed IDE leaves unflushed) and
  cheap enough: one line per typing pause, well under a millisecond each. If
  that ever shows up in its own numbers, the lines are lying about a cost
  they introduced - which is why the write is not timed.
}

interface

/// <summary>
/// Where TimingLog appends. '' disables it. Set from the options that start
/// a server, so it follows the logging switch and the active project.
/// </summary>
procedure SetTimingLogPath(const APath: string);
function TimingLogPath: string;

/// <summary>
/// Appends one line, prefixed "[ide HH:MM:SS.mmm] ". A no-op with no path.
/// Never raises: a diagnostic must not become the failure it documents.
/// </summary>
procedure TimingLog(const ALine: string);
procedure TimingLogFmt(const AFormat: string; const AArgs: array of const);

/// <summary>
/// A monotonic millisecond clock for elapsed times (QueryPerformanceCounter
/// under the hood, so sub-millisecond stages round honestly rather than to
/// the 15 ms of GetTickCount).
/// </summary>
function TimingNowMs: Double;

/// <summary>Elapsed since AStartMs, formatted for a log line: "12.3ms".</summary>
function TimingSince(AStartMs: Double): string;

/// <summary>A duration already measured, formatted the same way.</summary>
function Ms(AMs: Double): string;

implementation

uses
  Winapi.Windows,
  System.SysUtils;

var
  GPath: string;
  GFreq: Int64;

procedure SetTimingLogPath(const APath: string);
begin
  GPath := APath;
end;

function TimingLogPath: string;
begin
  Result := GPath;
end;

function TimingNowMs: Double;
var
  LCounter: Int64;
begin
  if GFreq = 0 then
    QueryPerformanceFrequency(GFreq);
  QueryPerformanceCounter(LCounter);
  Result := LCounter * 1000.0 / GFreq;
end;

function Ms(AMs: Double): string;
begin
  Result := FormatFloat('0.0', AMs, TFormatSettings.Invariant) + 'ms';
end;

function TimingSince(AStartMs: Double): string;
begin
  Result := Ms(TimingNowMs - AStartMs);
end;

procedure TimingLog(const ALine: string);
var
  LFile: THandle;
  LBytes: TBytes;
  LWritten: DWORD;
  LStamp: string;
begin
  if GPath = '' then
    Exit;
  try
    LStamp := FormatDateTime('hh:nn:ss.zzz', Now, TFormatSettings.Invariant);
    LFile := CreateFile(PChar(GPath), FILE_APPEND_DATA,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if LFile = INVALID_HANDLE_VALUE then
      Exit;
    try
      LBytes := TEncoding.UTF8.GetBytes('[ide ' + LStamp + '] ' + ALine +
        sLineBreak);
      WriteFile(LFile, LBytes[0], Length(LBytes), LWritten, nil);
    finally
      CloseHandle(LFile);
    end;
  except
    // Swallowed by design - see the unit header.
  end;
end;

procedure TimingLogFmt(const AFormat: string; const AArgs: array of const);
begin
  if GPath = '' then
    Exit;
  try
    TimingLog(Format(AFormat, AArgs, TFormatSettings.Invariant));
  except
  end;
end;

end.
