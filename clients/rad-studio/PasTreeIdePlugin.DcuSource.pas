unit PasTreeIdePlugin.DcuSource;

{
  Editor tabs for compiled units: the interface text PasTree generates from
  a .dcu, shown read-only in the IDE's own code editor.

  WHAT THIS IS FOR. Since PasTree 0.37.0 a unit with no .pas on any path is
  analyzed from its .dcu - the reader decodes the file, a printer turns its
  declarations into interface source, and that text goes through the same
  lexer, parser and resolver as everything else. Every answer about such a
  unit therefore names the .dcu and a line of that text: Ctrl+Click on a
  TeeChart type lands in `lib\win32\release\VCLTee.Chart.dcu` line 412. The
  demo shows the tab read-only; here the IDE has to, and the IDE cannot
  open a .dcu as source.

  HOW: A REGISTERED FILE SYSTEM, NOT A TEMP FILE. The ToolsAPI lets a
  package register an IOTAFileSystem (IOTAModuleServices.AddFileSystem) and
  create a module whose I/O goes through it (IOTACreator.GetFileSystem).
  The module is named `<dcu path>.pas` (PasTreeIdePlugin.DcuNames has the
  rule and the reasons), exists nowhere on disk, reads its text from this
  unit's cache and reports itself read-only, which the IDE honours the way
  it honours a read-only file: the buffer refuses edits and the status bar
  says so. A file written to %TEMP% was the alternative and lost on three
  counts: it appears in Recent Files and Open Recent, the server would see
  an unknown .pas outside the closure (so nothing could be asked from inside
  the tab - no Ctrl+Click, no hover, no references), and somebody has to
  delete it. With the virtual name every request from the tab leaves as the
  .dcu URI (PathToLspUri), so the server answers about it exactly as about
  any unit of the closure, and didOpen carries the same text the server
  regenerates from the file - no rebuild.

  THE TEXT COMES FROM THE SERVER (pastree/dcuSource), never from a reader of
  our own: this package must not link PasTree (it is Win32, PasTree is
  Win64-only, and that split is the reason the analysis is a process), and
  the line the answer named is a line of the text the SERVER printed. One
  request per tab; a tab already open is only revealed again.

  A CONFIGURATION CHANGE CLOSES THE TABS. The text belongs to the server
  that generated it: Win32 and Win64 print different constants (Extended,
  pointer-sized values), and a platform switch may resolve the same unit to
  a different .dcu under a different lib directory, or to a .pas. So when a
  project's server is replaced (LspSetSessionRestartListener - platform,
  configuration, a re-saved .dproj) every generated tab is closed and its
  text forgotten; the next navigation regenerates from whatever the new
  server resolves. Closed rather than refreshed in place because the new
  .dcu may not be the same file and the old line numbers mean nothing in
  it. Deferred one main-thread turn (ForceQueue): the restart runs inside
  EnsureSession, i.e. inside somebody's request, and closing modules from
  there is closing them out from under the caller.

  A .dcu THE READER REFUSES goes to the Build tab with the reader's own
  words ("Foo.dcu could not be read: Delphi 10.4 is not supported (Delphi
  11 to 13 are)") - the same place the importer's F1027 already reports it,
  because that is where Alex asked for it (2026-09-18). No dialog: it is a
  navigation gesture, and the rule of this plugin is that a miss is logged.
}

interface

uses
  System.SysUtils;

/// <summary>
/// Registers the file system. Call once from TIDEWizard.Create, after
/// InitializeLspSession (this unit registers a restart listener with it).
/// </summary>
procedure InitializeDcuSource;

/// <summary>
/// Closes every generated tab, forgets their texts and unregisters the file
/// system. Call from TIDEWizard.Destroy BEFORE FinalizeLspSession: a module
/// whose file system lives in an unloaded BPL is an AV on the next read.
/// </summary>
procedure FinalizeDcuSource;

/// <summary>
/// Makes sure the module showing ADcuPath's generated text exists, asking
/// the server for the text if it does not, and hands AOnReady the module's
/// name (`<dcu>.pas`) to navigate to - or '' when the .dcu could not be
/// read, in which case the reason has already gone to the Build tab.
/// Asynchronous when a request is needed, synchronous when the module is
/// already open; either way AOnReady runs on the main thread, once.
/// </summary>
procedure EnsureDcuModule(const ADcuPath: string;
  const AOnReady: TProc<string>);

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.Classes,
  System.IOUtils,
  ToolsAPI,
  PasTreeIdePlugin.DcuNames,
  PasTreeIdePlugin.LspSession;

const
  // The IDString the modules name; nothing else in the IDE may share it.
  cFileSystemId = 'PasTree.DcuSource';

type
  { The file system: every module created through TDcuModuleCreator reads
    and writes (never writes) through this. One instance for the package's
    lifetime; the texts it serves live in PasTreeIdePlugin.DcuNames. }
  TDcuFileSystem = class(TInterfacedObject, IOTAFileSystem)
  public
    { IOTAFileSystem }
    function GetFileStream(const FileName: string; Mode: Integer): IStream;
    function FileAge(const FileName: string): Longint;
    function RenameFile(const OldName, NewName: string): Boolean;
    function IsReadonly(const FileName: string): Boolean;
    function IsFileBased: Boolean;
    function DeleteFile(const FileName: string): Boolean;
    function FileExists(const FileName: string): Boolean;
    function GetTempFileName(const FileName: string): string;
    function GetBackupFileName(const FileName: string): string;
    function GetIDString: string;
  end;

  { The creator handed to IOTAModuleServices.CreateModule: an EXISTING unit
    (so the IDE reads it through the file system instead of asking for new
    source), in no project (Owner nil), named in full, source shown. }
  TDcuModuleCreator = class(TInterfacedObject, IOTACreator, IOTAModuleCreator)
  private
    FName: string;
  public
    constructor Create(const AVirtualName: string);
    { IOTACreator }
    function GetCreatorType: string;
    function GetExisting: Boolean;
    function GetFileSystem: string;
    function GetOwner: IOTAModule;
    function GetUnnamed: Boolean;
    { IOTAModuleCreator }
    function GetAncestorName: string;
    function GetImplFileName: string;
    function GetIntfFileName: string;
    function GetFormName: string;
    function GetMainForm: Boolean;
    function GetShowForm: Boolean;
    function GetShowSource: Boolean;
    function NewFormFile(const FormIdent, AncestorIdent: string): IOTAFile;
    function NewImplSource(const ModuleIdent, FormIdent,
      AncestorIdent: string): IOTAFile;
    function NewIntfSource(const ModuleIdent, FormIdent,
      AncestorIdent: string): IOTAFile;
    procedure FormCreated(const FormEditor: IOTAFormEditor);
  end;

type
  { The source handed back from NewImplSource. The IDE demands one even for
    an EXISTING module ("Creator must supply a source file", 37.0, found by
    Alex 2026-09-18) - so the text reaches the buffer this way, and the file
    system above answers the reads and the read-only question. Age -1 would
    mean "new file"; the registration moment is used instead so the buffer
    is not born modified. }
  TDcuSourceFile = class(TInterfacedObject, IOTAFile)
  private
    FText: string;
  public
    constructor Create(const AText: string);
    function GetSource: string;
    function GetAge: TDateTime;
  end;

var
  GFileSystemIndex: Integer = -1;
  GFileSystem: IOTAFileSystem;
  // The teardown guard for the asynchronous half of EnsureDcuModule: a
  // reply that lands after FinalizeDcuSource must create nothing.
  GAlive: Boolean = False;
  // The moment the file system was registered - what FileAge answers for
  // every module, so the IDE never sees a file "changed on disk".
  GAge: Longint = 0;

/// <summary>Build tab, tagged like the rest of the plugin's diagnostics.</summary>
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ TDcuFileSystem }

function TDcuFileSystem.GetFileStream(const FileName: string;
  Mode: Integer): IStream;
var
  LText: string;
  LStream: TMemoryStream;
  LBytes: TBytes;
begin
  Result := nil;
  if not TryGetDcuText(FileName, LText) then
    Exit;
  // UTF-8 with a BOM, the encoding the IDE itself writes by default, so the
  // buffer decodes without guessing. The stream owns its memory; the IDE
  // holds the interface for as long as it reads.
  LStream := TMemoryStream.Create;
  LBytes := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(LText);
  if Length(LBytes) > 0 then
    LStream.WriteBuffer(LBytes[0], Length(LBytes));
  LStream.Position := 0;
  Result := TStreamAdapter.Create(LStream, soOwned);
end;

function TDcuFileSystem.FileAge(const FileName: string): Longint;
begin
  Result := GAge;
end;

function TDcuFileSystem.RenameFile(const OldName, NewName: string): Boolean;
begin
  Result := False;
end;

function TDcuFileSystem.IsReadonly(const FileName: string): Boolean;
begin
  // The whole point: generated text, not a file anyone can save.
  Result := True;
end;

function TDcuFileSystem.IsFileBased: Boolean;
begin
  Result := False;
end;

function TDcuFileSystem.DeleteFile(const FileName: string): Boolean;
begin
  Result := False;
end;

function TDcuFileSystem.FileExists(const FileName: string): Boolean;
var
  LText: string;
begin
  Result := TryGetDcuText(FileName, LText);
end;

function TDcuFileSystem.GetTempFileName(const FileName: string): string;
begin
  Result := '';
end;

function TDcuFileSystem.GetBackupFileName(const FileName: string): string;
begin
  Result := '';
end;

function TDcuFileSystem.GetIDString: string;
begin
  Result := cFileSystemId;
end;

{ TDcuModuleCreator }

constructor TDcuModuleCreator.Create(const AVirtualName: string);
begin
  inherited Create;
  FName := AVirtualName;
end;

function TDcuModuleCreator.GetCreatorType: string;
begin
  Result := sUnit;
end;

function TDcuModuleCreator.GetExisting: Boolean;
begin
  // Existing: the IDE loads the text through the file system rather than
  // asking NewImplSource for a skeleton.
  Result := True;
end;

function TDcuModuleCreator.GetFileSystem: string;
begin
  Result := cFileSystemId;
end;

function TDcuModuleCreator.GetOwner: IOTAModule;
begin
  // No project: the tab must not become a unit of whatever is active.
  Result := nil;
end;

function TDcuModuleCreator.GetUnnamed: Boolean;
begin
  Result := False;
end;

function TDcuModuleCreator.GetAncestorName: string;
begin
  Result := '';
end;

function TDcuModuleCreator.GetImplFileName: string;
begin
  Result := FName;
end;

function TDcuModuleCreator.GetIntfFileName: string;
begin
  Result := '';
end;

function TDcuModuleCreator.GetFormName: string;
begin
  Result := '';
end;

function TDcuModuleCreator.GetMainForm: Boolean;
begin
  Result := False;
end;

function TDcuModuleCreator.GetShowForm: Boolean;
begin
  Result := False;
end;

function TDcuModuleCreator.GetShowSource: Boolean;
begin
  Result := True;
end;

function TDcuModuleCreator.NewFormFile(const FormIdent,
  AncestorIdent: string): IOTAFile;
begin
  Result := nil;
end;

function TDcuModuleCreator.NewImplSource(const ModuleIdent, FormIdent,
  AncestorIdent: string): IOTAFile;
var
  LText: string;
begin
  if TryGetDcuText(FName, LText) then
    Result := TDcuSourceFile.Create(LText)
  else
    Result := nil;
end;

{ TDcuSourceFile }

constructor TDcuSourceFile.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
end;

function TDcuSourceFile.GetSource: string;
begin
  Result := FText;
end;

function TDcuSourceFile.GetAge: TDateTime;
begin
  Result := FileDateToDateTime(GAge);
end;

function TDcuModuleCreator.NewIntfSource(const ModuleIdent, FormIdent,
  AncestorIdent: string): IOTAFile;
begin
  Result := nil;
end;

procedure TDcuModuleCreator.FormCreated(const FormEditor: IOTAFormEditor);
begin
end;

{ The modules }

function FindDcuModule(const AVirtualName: string): IOTAModule;
var
  LModuleServices: IOTAModuleServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Result := LModuleServices.FindModule(AVirtualName);
end;

{ Belt and braces over IsReadonly: the buffer's own flag, set after the
  module exists, so an IDE that consulted the file system only at load time
  still refuses the first keystroke. }
procedure MarkBufferReadOnly(const AModule: IOTAModule);
var
  LIdx: Integer;
  LBuffer: IOTAEditBuffer;
begin
  if not Assigned(AModule) then
    Exit;
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTAEditBuffer, LBuffer) then
      LBuffer.IsReadOnly := True;
end;

function CreateDcuModule(const ADcuPath: string): IOTAModule;
var
  LModuleServices: IOTAModuleServices;
  LName: string;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  LName := DcuVirtualName(ADcuPath);
  try
    Result := LModuleServices.CreateModule(TDcuModuleCreator.Create(LName));
  except
    on E: Exception do
    begin
      LogDiagnostic(Format('%s: the IDE could not open the generated text: %s',
        [TPath.GetFileName(ADcuPath), E.Message]));
      Result := nil;
    end;
  end;
  if Result = nil then
    Result := FindDcuModule(LName);   // CreateModule may have returned nil
  MarkBufferReadOnly(Result);
end;

procedure EnsureDcuModule(const ADcuPath: string;
  const AOnReady: TProc<string>);
var
  LName: string;
begin
  LName := DcuVirtualName(ADcuPath);
  if Assigned(FindDcuModule(LName)) then
  begin
    AOnReady(LName);
    Exit;
  end;
  if not GAlive then
  begin
    AOnReady('');
    Exit;
  end;
  LspDcuSource(ADcuPath,
    procedure(ASuccess: Boolean; const AText, AError: string)
    begin
      if not GAlive then
        Exit;   // package unloading: create nothing, call nobody
      if not ASuccess then
      begin
        LogDiagnostic(Format('%s: no source to show - %s',
          [TPath.GetFileName(ADcuPath), AError]));
        AOnReady('');
        Exit;
      end;
      RememberDcuText(ADcuPath, AText);
      if Assigned(CreateDcuModule(ADcuPath)) then
        AOnReady(LName)
      else
        AOnReady('');
    end);
end;

{ Every generated tab, closed; every text, forgotten. ForceClosed: the
  buffers are read-only and cannot be dirty, and a "save changes?" prompt
  over a file that cannot be saved would be absurd anyway. }
procedure CloseDcuModules(const AWhy: string);
var
  LPath: string;
  LModule: IOTAModule;
  LClosed: Integer;
begin
  LClosed := 0;
  for LPath in RememberedDcuPaths do
  begin
    LModule := FindDcuModule(DcuVirtualName(LPath));
    if Assigned(LModule) then
    begin
      try
        if LModule.CloseModule(True) then
          Inc(LClosed);
      except
        // A module the IDE is already tearing down: nothing to do about it.
      end;
    end;
  end;
  ForgetDcuTexts;
  if (LClosed > 0) and (AWhy <> '') then
    LogDiagnostic(Format('%d generated .dcu tab(s) closed - %s',
      [LClosed, AWhy]));
end;

procedure OnSessionRestart;
begin
  // Deferred: this runs inside EnsureSession, inside a request somebody is
  // in the middle of issuing. Close the modules once that call has returned.
  TThread.ForceQueue(nil,
    procedure
    begin
      if GAlive then
        CloseDcuModules('the project configuration changed, navigate again'
          + ' to regenerate from the new platform''s units');
    end);
end;

procedure InitializeDcuSource;
var
  LModuleServices: IOTAModuleServices;
begin
  if GAlive then
    Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    Exit;
  GFileSystem := TDcuFileSystem.Create;
  GFileSystemIndex := LModuleServices.AddFileSystem(GFileSystem);
  GAge := DateTimeToFileDate(Now);
  GAlive := True;
  LspSetSessionRestartListener(OnSessionRestart);
end;

procedure FinalizeDcuSource;
var
  LModuleServices: IOTAModuleServices;
begin
  if not GAlive then
    Exit;
  GAlive := False;
  LspSetSessionRestartListener(nil);
  CloseDcuModules('');
  if (GFileSystemIndex >= 0) and
     Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then
    LModuleServices.RemoveFileSystem(GFileSystemIndex);
  GFileSystemIndex := -1;
  GFileSystem := nil;
end;

end.
