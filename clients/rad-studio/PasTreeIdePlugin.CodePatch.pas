unit PasTreeIdePlugin.CodePatch;

{
  REPLACING A METHOD OF THE IDE'S OWN RTL OR VCL, FOR THE IDE FIXES TAB.

  One patch overwrites the first bytes of a routine inside rtl*.bpl or
  vcl*.bpl with a jump to a replacement in this package, and puts them back on
  Remove. It is the mechanism of bero/DControlsFix (after Andreas Hausladen's
  VCLFixPack), with the two things that code gets wrong on Win64 done right:

  - THE JUMP. Win32 writes the 5-byte E9 rel32. Win64 cannot: rel32 reaches
    only 2 GB, nothing places this BPL within 2 GB of the IDE's rtl/vcl, and
    an offset that does not fit would be truncated silently - the next call
    would jump into garbage. So Win64 writes the 14-byte absolute form,
    FF 25 00000000 followed by the 8-byte target address.

  - THE ADDRESS. A virtual method's comes from its class's virtual method
    table (each fix unit does that itself - it needs the method by name). A
    static method's `@TFoo.Bar` in a package is an import thunk, an indirect
    jump through the import table, and ResolveImportThunk follows it: an
    absolute operand on Win32, a RIP-relative one on Win64 - DControlsFix
    reads the Win32 form on both, which on Win64 yields garbage.

  THE ORIGINAL IS NEVER CALLED WHILE PATCHED. Every replacement is a complete
  copy of the method, so there is no trampoline and no relocating of the
  instructions the jump overwrites - the part of any hooking library that is
  hard to get right. The cost is that a replacement must be compared with the
  VCL source again for every new RAD Studio version.

  NO CHECK FOR SOMEONE ELSE'S PATCH (Alex, 2026-09-29): DDevExtensions or
  DControlsFix loaded as well get overwritten, not detected. The check kept is
  that the address lies in the module of the class it belongs to - anything
  else means the lookup went wrong, and writing there would be a crash of our
  own making.

  Main thread only, like every caller.
}

interface

type
  TCodePatch = record
  private
    FTarget: Pointer;
    FSaved: array[0..13] of Byte;
    FActive: Boolean;
  public
    /// <summary>
    /// Overwrites ATarget with a jump to AReplacement. False, with AError
    /// saying why, leaves ATarget untouched. AOwnerClass is the class
    /// ATarget belongs to: the address must lie in that class's module.
    /// </summary>
    function Install(ATarget, AReplacement: Pointer; AOwnerClass: TClass;
      out AError: string): Boolean;
    /// <summary>
    /// Puts the saved bytes back. A no-op when not installed. Not installed
    /// afterwards even on failure: the jump then still points into this
    /// package, which is loaded, and a second try would fail alike.
    /// </summary>
    function Remove(out AError: string): Boolean;
    property Active: Boolean read FActive;
  end;

/// <summary>
/// The code an import thunk jumps to - `@TFoo.Bar` for a static method of
/// another package - or ACode itself when it is not a thunk.
/// </summary>
function ResolveImportThunk(ACode: Pointer): Pointer;

implementation

uses
  Winapi.Windows,
  System.SysUtils;

const
{$IFDEF CPUX64}
  cJumpSize = 14;   // FF 25 00000000 + 8-byte absolute address
{$ELSE}
  cJumpSize = 5;    // E9 + rel32
{$ENDIF}

function ResolveImportThunk(ACode: Pointer): Pointer;
var
  LCode: PByte;
  LHops: Integer;
begin
  Result := ACode;
  // A thunk may lead to another (a package re-exporting): a few hops at most.
  for LHops := 1 to 4 do
  begin
    LCode := Result;
    if LCode = nil then
      Exit;
{$IFDEF CPUX64}
    // jmp qword ptr [rip+rel32], with or without a REX.W prefix.
    if LCode^ = $48 then
      Inc(LCode);
    if PWord(LCode)^ <> $25FF then
      Exit;
    Result := PPointer(LCode + 6 + PInteger(LCode + 2)^)^;
{$ELSE}
    // jmp dword ptr [abs32]
    if PWord(LCode)^ <> $25FF then
      Exit;
    Result := PPointer(PPointer(LCode + 2)^)^;
{$ENDIF}
  end;
end;

function WriteCode(ATarget: Pointer; const ABytes; ASize: Integer): Boolean;
var
  LOld, LIgnored: DWORD;
begin
  Result := VirtualProtect(ATarget, ASize, PAGE_EXECUTE_READWRITE, LOld);
  if not Result then
    Exit;
  Move(ABytes, ATarget^, ASize);
  VirtualProtect(ATarget, ASize, LOld, LIgnored);
  FlushInstructionCache(GetCurrentProcess, ATarget, ASize);
end;

{ TCodePatch }

function TCodePatch.Install(ATarget, AReplacement: Pointer;
  AOwnerClass: TClass; out AError: string): Boolean;
var
  LJump: array[0..cJumpSize - 1] of Byte;
{$IFDEF CPUX64}
  LAddress: UInt64;
{$ENDIF}
begin
  AError := '';
  if FActive then
    Exit(True);
  if (ATarget = nil)
    or (FindHInstance(ATarget) <> FindHInstance(Pointer(AOwnerClass))) then
  begin
    AError := 'the method was not found in the module ' + AOwnerClass.ClassName
      + ' lives in';
    Exit(False);
  end;
{$IFDEF CPUX64}
  LJump[0] := $FF;
  LJump[1] := $25;
  PCardinal(@LJump[2])^ := 0;   // [rip+0]: the address right after
  LAddress := UInt64(AReplacement);
  Move(LAddress, LJump[6], SizeOf(LAddress));
{$ELSE}
  LJump[0] := $E9;
  PInteger(@LJump[1])^ := Integer(NativeInt(AReplacement) - NativeInt(ATarget)
    - cJumpSize);
{$ENDIF}
  Move(ATarget^, FSaved, cJumpSize);
  if not WriteCode(ATarget, LJump, cJumpSize) then
  begin
    AError := 'VirtualProtect failed (' + SysErrorMessage(GetLastError) + ')';
    Exit(False);
  end;
  FTarget := ATarget;
  FActive := True;
  Result := True;
end;

function TCodePatch.Remove(out AError: string): Boolean;
begin
  AError := '';
  if not FActive then
    Exit(True);
  Result := WriteCode(FTarget, FSaved, cJumpSize);
  if not Result then
    AError := 'VirtualProtect failed (' + SysErrorMessage(GetLastError) + ')';
  FActive := False;
  FTarget := nil;
end;

end.
