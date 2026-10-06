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
  then the return addresses up the FAULTING thread's stack, each resolved to
  MODULE + OFFSET. A frame in PasTreeIdePlugin.bpl is the answer; its offset
  maps to a unit and line through the .map file the build writes (build.bat
  passes DCC_MapFile=3) - add the image base and the code section's RVA to a
  `0001:xxxxxxxx` entry there. Frames are all this can give: a designtime BPL
  carries no symbols at runtime, so resolving names would mean shipping a
  symbol reader, and the offset is enough to find the site once.

  ONLY FAULTS WITH THIS PLUGIN ON THE STACK ARE WRITTEN (since 0.62.2). The
  IDE faults and swallows AVs of its own all day - vcl370 + 3E28C at every
  session, the GetIt welcome page, dcc32 during a background compile - and a
  log of those buried the few that matter. A block is written when the fault
  address or any frame of the walk is in this BPL; the rest are only counted,
  and the count goes into the next block that is written, so "the IDE had 40
  of its own" is still visible without 40 blocks. Settings > Diagnostics >
  "Log all IDE crashes" (SetCrashLogAll, off by default) writes them all, for
  the fault whose stack does not reach us although we caused it - a freed
  object of ours used later by the IDE is the classic one.

  THE WALK STARTS FROM THE FAULT'S CONTEXT, NOT FROM THIS HANDLER. Until
  0.62.2 it was RtlCaptureStackBackTrace here, which starts in the handler
  itself - so every block's first frame was PasTreeIdePlugin.bpl, ours or
  not, then three ntdll dispatcher frames - and on Win32 a frame-pointer walk
  mostly stops at KiUserExceptionDispatcher, so most blocks had nothing past
  those four lines: no caller at all, and nothing a filter could decide on.
  Now Win32 follows the EBP chain from the context's Eip/Ebp, and Win64
  unwinds a copy of the context with RtlVirtualUnwind, both bounded by the
  thread's stack limits and inside try/except - a fault inside an exception
  handler is the one place this unit must not have one. A frameless routine
  is skipped by the EBP walk (its caller is kept) - an IDE one costs a line
  of the stack, and none of ours is frameless: the package is compiled with
  the STACKFRAMES directive on (PasTreeIdePlugin.dpk), which this walk
  depends on - keep it.

  WHICH .map is the one beside the BPL the block's header names by full path:
  out\<version>\win32\ or out\<version>\win64\. The frames say only
  "PasTreeIdePlugin.bpl", which the 32-bit and the 64-bit IDE's packages both
  are, and an offset read against the other one's map names a plausible,
  wrong line.

  COST WHEN NOTHING IS WRONG: one comparison per exception raised in the
  process. The IDE raises (and handles) plenty, but only ACCESS VIOLATIONS get
  past the first check, and a foreign one costs a stack walk and no file I/O.

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
/// <summary>
/// True writes every access violation in the IDE, with or without a frame of
/// this plugin - the behaviour before 0.62.2, for chasing a fault the walk
/// cannot attribute. Settings > Diagnostics > "Log all IDE crashes", OFF by
/// default. Pushed by the wizard at load and by SaveSettings, never read
/// from the settings here: the handler must not touch the registry or
/// ToolsAPI.
/// </summary>
procedure SetCrashLogAll(AAll: Boolean);

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
// Windows 8 and later, which every supported RAD Studio requires. Declared
// here because older Winapi.Windows units do not import it.
procedure GetCurrentThreadStackLimits(out ALow, AHigh: ULONG_PTR); stdcall;
  external kernel32;
{$IFDEF CPUX64}
function RtlLookupFunctionEntry(AControlPc: DWORD64; out AImageBase: DWORD64;
  AHistoryTable: Pointer): Pointer; stdcall; external kernel32;
function RtlVirtualUnwind(AHandlerType: DWORD; AImageBase, AControlPc: DWORD64;
  AFunctionEntry: Pointer; AContext: PContext; out AHandlerData: Pointer;
  out AEstablisherFrame: DWORD64; AContextPointers: Pointer): Pointer; stdcall;
  external kernel32;
{$ENDIF}
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
  // "<version> at <full path of this BPL>", for each block's header - worked
  // out once at registration rather than inside the handler, which runs on
  // whatever thread faulted and should call as little as it can.
  GPackage: string = '';
  // This BPL's image, [GOwnLow, GOwnHigh) - the test for "a frame of ours".
  // From the PE header at registration, so the handler compares two numbers
  // per frame rather than asking the loader.
  GOwnLow: UIntPtr = 0;
  GOwnHigh: UIntPtr = 0;
  // Access violations with no frame of ours since the last block written.
  GSkipped: Integer = 0;
  // See SetCrashLogAll. One aligned Boolean, written on the main thread and
  // read by the handler on any - a torn read is impossible, a stale one
  // costs one block either way.
  GLogAll: Boolean = False;
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

procedure SetCrashLogAll(AAll: Boolean);
begin
  GLogAll := AAll;
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

type
  TFrames = array[0..cMaxFrames - 1] of Pointer;

{ The faulting thread's stack as it was at the fault: AFrames[0] is the
  faulting instruction, then the return addresses outward. Every read is of
  this thread's own stack, checked against its limits first, and the whole
  walk is under try/except - a corrupted stack is a common reason to be here,
  and what was collected before it is kept. }
function WalkFaultStack(AContext: PContext; var AFrames: TFrames): Integer;
var
  LLow, LHigh: ULONG_PTR;
{$IFDEF CPUX86}
  LFp, LNext, LSp: UIntPtr;
  LModule: HMODULE;
{$ENDIF}
{$IFDEF CPUX64}
  // CONTEXT must be 16-byte aligned for RtlVirtualUnwind, which a local
  // record is not promised to be - so a buffer, aligned by hand.
  LBuf: array[0..SizeOf(TContext) + 15] of Byte;
  LCtx: PContext;
  LEntry, LHandlerData: Pointer;
  LImageBase, LEstablisher: DWORD64;
{$ENDIF}
begin
  Result := 0;
  GetCurrentThreadStackLimits(LLow, LHigh);
  try
{$IFDEF CPUX86}
    AFrames[0] := Pointer(AContext.Eip);
    Result := 1;
    // A call through a bad pointer (Eip in no module, or nil) faults before
    // the callee pushes anything, so [Esp] is still the return address - the
    // caller, which the EBP chain would skip.
    LSp := AContext.Esp;
    LModule := 0;
    if not GetModuleHandleEx($00000004 or $00000002, AFrames[0], LModule)
       and (LSp >= LLow) and (LSp + SizeOf(Pointer) <= LHigh) then
    begin
      AFrames[Result] := PPointer(LSp)^;
      Inc(Result);
    end;
    LFp := AContext.Ebp;
    while (Result < cMaxFrames) and (LFp >= LLow)
      and (LFp + 2 * SizeOf(Pointer) <= LHigh) and (LFp and 3 = 0) do
    begin
      AFrames[Result] := PPointer(LFp + SizeOf(Pointer))^;
      if AFrames[Result] = nil then
        Break;
      Inc(Result);
      LNext := UIntPtr(PPointer(LFp)^);
      // The stack grows down: a caller's frame is always higher.
      if LNext <= LFp then
        Break;
      LFp := LNext;
    end;
{$ENDIF}
{$IFDEF CPUX64}
    LCtx := PContext((UIntPtr(@LBuf[0]) + 15) and not UIntPtr(15));
    Move(AContext^, LCtx^, SizeOf(TContext));
    // Frame 0 is taken even when Rip is nil - a call through a nil pointer,
    // whose caller is the next frame and the one that matters.
    while Result < cMaxFrames do
    begin
      // Past frame 0 a nil Rip is the end of the stack.
      if (LCtx.Rip = 0) and (Result > 0) then
        Break;
      AFrames[Result] := Pointer(LCtx.Rip);
      Inc(Result);
      LEntry := RtlLookupFunctionEntry(LCtx.Rip, LImageBase, nil);
      if LEntry = nil then
      begin
        // A leaf (or a call through a bad pointer): the return address is
        // at Rsp and nothing else was pushed.
        if (LCtx.Rsp < LLow) or (LCtx.Rsp + SizeOf(Pointer) > LHigh) then
          Break;
        LCtx.Rip := PDWORD64(LCtx.Rsp)^;
        Inc(LCtx.Rsp, SizeOf(Pointer));
      end
      else
        RtlVirtualUnwind(0, LImageBase, LCtx.Rip, LEntry, LCtx, LHandlerData,
          LEstablisher, nil);
      if (LCtx.Rsp < LLow) or (LCtx.Rsp >= LHigh) then
        Break;
    end;
{$ENDIF}
  except
    // Keep the frames collected before the walk hit garbage.
  end;
end;

function IsOwnAddress(AAddr: Pointer): Boolean; inline;
begin
  Result := (UIntPtr(AAddr) >= GOwnLow) and (UIntPtr(AAddr) < GOwnHigh);
end;

function VectoredHandler(AInfo: PExceptionPointers): LongInt; stdcall;
var
  LFrames: TFrames;
  LCount, LIdx: Integer;
  LOurs: Boolean;
  LText: string;
  LRec: PExceptionRecord;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;   // observe only, never handle
  LRec := AInfo.ExceptionRecord;
  if (LRec = nil) or (LRec.ExceptionCode <> EXCEPTION_ACCESS_VIOLATION) then
    Exit;
  // NIL-CHECKED like SetCrashLogPath, and for a harder reason: this runs on
  // whatever thread faulted, and the fault can arrive while the package is
  // being unloaded. See FinalizeCrashLog for why the lock outlives us.
  if GLock = nil then
    Exit;
  GLock.Enter;
  try
    if GInside or (GEntries >= cMaxEntries) then
      Exit;
    GInside := True;
    try
      LCount := 0;
      if AInfo.ContextRecord <> nil then
        LCount := WalkFaultStack(AInfo.ContextRecord, LFrames);
      LOurs := IsOwnAddress(LRec.ExceptionAddress);
      for LIdx := 0 to LCount - 1 do
        LOurs := LOurs or IsOwnAddress(LFrames[LIdx]);
      if not (LOurs or GLogAll) then
      begin
        Inc(GSkipped);
        Exit;
      end;
      Inc(GEntries);
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
         GPackage]);
      if GSkipped > 0 then
        LText := LText + Format(#13#10'  (%d access violation(s) without '
          + 'this plugin on the stack since the previous block, not written)',
          [GSkipped]);
      GSkipped := 0;
      // Frame 0 is the fault address the header already names.
      for LIdx := 1 to LCount - 1 do
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
  // Reused across a package reload rather than recreated: FinalizeCrashLog
  // deliberately does not free it (see there), so a second load must not
  // abandon the first one's.
  if GLock = nil then
    GLock := TCriticalSection.Create;
  GPackage := PasTreeLspVersion + ' at ' + ThisBinaryPath;
  // HInstance is this package's module; SizeOfImage covers every section.
  GOwnLow := UIntPtr(HInstance);
  GOwnHigh := GOwnLow + PImageNtHeaders(GOwnLow
    + UIntPtr(PImageDosHeader(GOwnLow)._lfanew)).OptionalHeader.SizeOfImage;
  // Until a project is open there is no per-project log yet, and an AV during
  // package load is exactly the kind this must not miss.
  GPath := TPath.Combine(TPath.GetTempPath, cCrashLogName);
  // FIRST in the chain (1): a handler registered last would still see the
  // exception, but only after any earlier one had a chance to change the
  // record - and being first costs nothing when the answer is always
  // CONTINUE_SEARCH.
  GHandler := AddVectoredExceptionHandler(1, @VectoredHandler);
end;

{ THE LOCK IS DELIBERATELY NEVER FREED - one critical section, once per
  process, and the alternative is a use-after-free inside a crash handler.

  RemoveVectoredExceptionHandler unregisters the handler; it does NOT wait for
  executions already under way on other threads, and this handler runs on
  whichever thread faulted - the transport's reader, an IDE worker, anything.
  An AV on such a thread at the moment the package unloads can be past its
  dispatch and about to call GLock.Enter while this line frees it. A secondary
  fault INSIDE the vectored handler is the worst place to have one: at best a
  second AV during unload, at worst recursion into the handler until the stack
  is gone. Leaking a few dozen bytes of a design that only ever runs once is
  the cheap side of that trade, and InitializeCrashLog reuses it on a reload.

  It does not make the window zero and cannot: once the BPL itself is out of
  memory, so is this code. What it removes is the part this unit controls -
  a freed lock reached by a handler that had already passed the gate. }
procedure FinalizeCrashLog;
begin
  if GHandler <> nil then
  begin
    RemoveVectoredExceptionHandler(GHandler);
    GHandler := nil;
  end;
end;

end.
