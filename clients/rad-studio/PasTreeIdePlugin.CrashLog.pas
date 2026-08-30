unit PasTreeIdePlugin.CrashLog;

{
  EVERY ACCESS VIOLATION IN THE IDE, WITH A STACK, IN THE PRODUCT'S OWN LOG.

  Why it exists. The only evidence an IDE AV leaves by itself is the dialog -
  "Access violation at address X in module 'rtl370.bpl', read of address Y" -
  and that names the function that FAULTED, never the code that called it with
  a bad argument. Two have now been chased that way: 2026-08-22 (at shutdown,
  offset 113F46, read of address 00000002) and 2026-08-24 (during Find
  References navigation, offset FD9D, read of address 00000020). Both inside
  rtl370, which is where every TThread/TList/TStringList method lives, so the
  dialog says almost nothing - the faulting instruction is in the RTL for the
  same reason a null pointer passed to WriteFile faults inside the kernel. A
  CALLER LIST is the whole difference between "somewhere in the plugin" and
  one line of one unit.

  pastree-lsp.log could not answer it either: it records what the plugin ASKS
  the server, so a crash on the IDE side looks exactly like a log that stops
  mid-session. That is precisely what the 2026-08-24 report showed - the last
  line is a documentSymbol answer and then nothing.

  ITS OWN FILE, NEXT TO THE OTHER ONE: pastree-ide-crash.log, in the folder
  pastree-lsp.log lives in - beside the .dproj being analyzed. Separate,
  because these are separate things: one records what the plugin asked the
  server, the other the host process falling over, and multi-line stack blocks
  wedged between request lines make both harder to read. Same folder, because
  that is where someone already looks, and the two get read together - the
  request lines are what the plugin was doing in the seconds before a fault.

  The DIRECTORY is pushed here (SetCrashLogPath) by the session that already
  computes it, rather than looked up: this code runs inside an exception
  handler, on whatever thread faulted, and must not call into ToolsAPI to find
  out where to write. Until a project is open it falls back to %TEMP%.

  HOW: a vectored exception handler (AddVectoredExceptionHandler) sees every
  access violation on every thread of the process BEFORE any handler decides
  what to do with it, which is what makes it usable here - by the time the
  dialog appears the stack is already unwound. It only OBSERVES: every path
  returns EXCEPTION_CONTINUE_SEARCH, so the IDE's own handling is unchanged,
  and an AV the IDE catches and swallows is recorded just the same (which is a
  feature - the swallowed ones are the ones nobody has ever seen).

  WHAT A BLOCK CONTAINS: the fault address and the address it tried to touch,
  then the return addresses up the stack, each resolved to MODULE + OFFSET. A
  frame in PasTreeIdePlugin.bpl is the answer; its offset maps to a unit and
  line through the .map file the build writes (build.bat passes DCC_MapFile=3)
  - add the image base and the code section's RVA to a `0001:xxxxxxxx` entry
  there. Frames are all this can give: a designtime BPL carries no symbols at
  runtime, so resolving names would mean shipping a symbol reader, and the
  offset is enough to find the site once. A block with no frame of ours is an
  answer too - it says the fault was not in this plugin.

  COST WHEN NOTHING IS WRONG: one comparison per exception raised in the
  process. The IDE raises (and handles) plenty, but only ACCESS VIOLATIONS get
  past the first check.

  THIS IS PERMANENT, not scaffolding for one bug. An intermittent AV in a
  designtime package is found by accumulating occurrences across weeks of
  ordinary use, which is exactly what an always-on recorder in a log people
  already read gives - and the next one of these will not be the last.
}

interface

/// <summary>
/// Registers the handler. Call FIRST in the wizard's constructor, before
/// anything that could fault.
/// </summary>
procedure InitializeCrashLog;
/// <summary>
/// Unregisters it. Call LAST in the wizard's destructor: the handler is a
/// pointer into this BPL, and one left registered across an unload is called
/// by the next AV anywhere in the IDE - the very crash class this unit exists
/// to find.
/// </summary>
procedure FinalizeCrashLog;
/// <summary>
/// Puts the crash log beside ALspLogPath - same folder, fixed name
/// pastree-ide-crash.log. Called by PasTreeIdePlugin.LspSession as it starts a
/// server for a project, so a project switch moves the crash log with the
/// server log. Safe to call repeatedly; an empty path is ignored, and until
/// the first call the fallback is %TEMP%.
/// </summary>
procedure SetCrashLogPath(const ALspLogPath: string);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.IOUtils,
  System.SyncObjs,
  PasLsp.ProductVersion;

const
  // Persistent and fixed, like the server log next to it, so it can be left
  // open in a tail across IDE restarts.
  cCrashLogName = 'pastree-ide-crash.log';
  // Enough to cross the IDE's own dispatch frames and still show ours.
  cMaxFrames = 40;
  // A cap, not a policy: a fault inside a paint loop repeats thousands of
  // times a second and would otherwise fill a disk. Per IDE session, and high
  // enough that no real investigation has ever reached it.
  cMaxEntries = 1000;
  // Nothing else writes this file, but a tail, an editor or a backup agent can
  // hold it for an instant. These bound the wait at ~100 ms and then drop the
  // block rather than stall the faulting thread.
  cRetries = 20;
  cRetryMs = 5;
  EXCEPTION_CONTINUE_SEARCH = 0;

function AddVectoredExceptionHandler(AFirst: ULONG;
  AHandler: Pointer): Pointer; stdcall; external kernel32;
function RemoveVectoredExceptionHandler(AHandle: Pointer): ULONG; stdcall;
  external kernel32;
function RtlCaptureStackBackTrace(AFramesToSkip, AFramesToCapture: DWORD;
  ABackTrace: Pointer; ABackTraceHash: PDWORD): Word; stdcall;
  external kernel32;
// Declared here rather than taken from Winapi.Windows, which does not import
// it in this RTL. The FROM_ADDRESS flag makes the second parameter an ADDRESS
// inside the module rather than a name - hence the Pointer, not a PChar.
function GetModuleHandleEx(AFlags: DWORD; AModuleNameOrAddr: Pointer;
  var AModule: HMODULE): BOOL; stdcall; external kernel32
  name 'GetModuleHandleExW';

var
  GHandler: Pointer = nil;
  GLock: TCriticalSection = nil;
  GEntries: Integer = 0;
  GPath: string = '';
  // Re-entrancy: an AV raised by this handler's own code (or by the file
  // write) must not recurse into it.
  GInside: Boolean = False;

procedure SetCrashLogPath(const ALspLogPath: string);
var
  LDir: string;
begin
  if (ALspLogPath = '') or (GLock = nil) then
    Exit;
  LDir := ExtractFilePath(ALspLogPath);
  if LDir = '' then
    Exit;
  GLock.Enter;
  try
    GPath := TPath.Combine(LDir, cCrashLogName);
  finally
    GLock.Leave;
  end;
end;

{ MODULE+OFFSET for one address - the only resolution available without
  symbols, and the one the AV dialog itself uses. An address in no module at
  all (a thunk, or a corrupted return address) says so rather than being
  dropped: a garbage return address IS the finding in a stack smash. }
function DescribeAddress(AAddr: Pointer): string;
const
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = $00000004;
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = $00000002;
var
  LModule: HMODULE;
  LName: array[0..MAX_PATH] of Char;
begin
  LModule := 0;
  if not GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or
       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, AAddr,
       LModule) or (LModule = 0) then
    Exit(Format('%p  (no module)', [AAddr]));
  if GetModuleFileName(LModule, LName, Length(LName)) = 0 then
    LName[0] := #0;
  Result := Format('%p  %s + %x', [AAddr, ExtractFileName(string(LName)),
    UIntPtr(AAddr) - UIntPtr(LModule)]);
end;

{ Appended with the plain API rather than a TStreamWriter: this runs inside an
  exception handler, so the fewer layers between the text and the file the
  better - and an unflushed buffer is exactly what would be lost if the IDE
  went down on the next fault. FILE_APPEND_DATA rather than seek-then-write so
  a reader holding the file open cannot make us overwrite anything. }
procedure AppendBlock(const AText: string);
var
  LFile: THandle;
  LBytes: TBytes;
  LWritten: DWORD;
  LTry: Integer;
begin
  // No pre-initialisation: the loop assigns on its first iteration and every
  // exit below is either a Break with a real handle or an Exit.
  for LTry := 1 to cRetries do
  begin
    LFile := CreateFile(PChar(GPath), FILE_APPEND_DATA,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, 0);
    if LFile <> INVALID_HANDLE_VALUE then
      Break;
    // Only a sharing collision is worth waiting out; a bad path or a denied
    // directory will not become writable in 100 ms.
    if GetLastError <> ERROR_SHARING_VIOLATION then
      Exit;
    Sleep(cRetryMs);
  end;
  if LFile = INVALID_HANDLE_VALUE then
    Exit;
  try
    LBytes := TEncoding.UTF8.GetBytes(AText + sLineBreak);
    WriteFile(LFile, LBytes[0], Length(LBytes), LWritten, nil);
  finally
    CloseHandle(LFile);
  end;
end;

function VectoredHandler(AInfo: PExceptionPointers): LongInt; stdcall;
var
  LFrames: array[0..cMaxFrames - 1] of Pointer;
  LCount, LIdx: Integer;
  LText: string;
  LRec: PExceptionRecord;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;   // observe only, never handle
  LRec := AInfo.ExceptionRecord;
  if (LRec = nil) or (LRec.ExceptionCode <> EXCEPTION_ACCESS_VIOLATION) then
    Exit;
  GLock.Enter;
  try
    if GInside or (GEntries >= cMaxEntries) then
      Exit;
    GInside := True;
    try
      Inc(GEntries);
      LCount := RtlCaptureStackBackTrace(0, cMaxFrames, @LFrames[0], nil);
      // ExceptionInformation[0] is 0 for a read, 1 for a write, 8 for a DEP
      // fault; [1] is the address that was touched - the "read of address
      // 00000020" half of the dialog, and the half that separates a nil
      // object (a small offset) from a freed one (garbage).
      LText := Format('%s IDE ACCESS VIOLATION at %s'#13#10
        + '  %s of address %p, thread %d, package %s',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
         DescribeAddress(LRec.ExceptionAddress),
         IfThen(LRec.ExceptionInformation[0] = 0, 'read', 'write'),
         Pointer(LRec.ExceptionInformation[1]), GetCurrentThreadId,
         PasTreeLspVersion]);
      for LIdx := 0 to LCount - 1 do
        LText := LText + #13#10 + '    ' + DescribeAddress(LFrames[LIdx]);
      AppendBlock(LText);
    finally
      GInside := False;
    end;
  finally
    GLock.Leave;
  end;
end;

procedure InitializeCrashLog;
begin
  if GHandler <> nil then
    Exit;
  GLock := TCriticalSection.Create;
  // Until a project is open there is no per-project log yet, and an AV during
  // package load is exactly the kind this must not miss.
  GPath := TPath.Combine(TPath.GetTempPath, cCrashLogName);
  // FIRST in the chain (1): a handler registered last would still see the
  // exception, but only after any earlier one had a chance to change the
  // record - and being first costs nothing when the answer is always
  // CONTINUE_SEARCH.
  GHandler := AddVectoredExceptionHandler(1, @VectoredHandler);
  if GHandler = nil then
    FreeAndNil(GLock);
end;

procedure FinalizeCrashLog;
begin
  if GHandler <> nil then
  begin
    RemoveVectoredExceptionHandler(GHandler);
    GHandler := nil;
  end;
  FreeAndNil(GLock);
end;

end.
