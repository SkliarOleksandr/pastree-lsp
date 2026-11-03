unit PasTreeIdePlugin.NavToolbar;

{
  THE EDITOR's NAVIGATION TOOLBAR, FED FROM PASTREE - the two comboboxes
  above the editor (RAD Studio 12 and 13, "Search for a type" / "Search for a
  method") that list the unit's types and routines and show the ones the
  caret is in. With PasTree as the Insight Provider they stayed empty
  (Alex, 2026-11-03); with DelphiLSP they work. Read off the binaries the
  same day (clients/rad-studio/SPEC.md, "The navigation toolbar"):

    1. The toolbar (coreide, EditorNavBar.TEditorNavigationToolbar) asks SQL
       of IOTACodeQueryServices on every editor idle - `SELECT ... FROM types
       WHERE start_line <= %d AND end_line >= %d`, the same of `methods`.
    2. The tables are filled per file by the first registered parser that
       takes the file (codequeryide, IDECodeQuery.GetParserForFilename).
       First is TLSPCodeQueryParser: it takes a file whose module answers
       ILSPDocumentSymbolModule, and copies that object's symbols - DelphiLSP's
       documentSymbol answer - into the tables. The IDE's own Castalia parser
       (codequerydelphi) comes after it, for a module without one.
    3. DelphiLSP (IDELSP, TLSPMgr.SendLSPDocumentSymbolRequest) attaches a
       TLSPDocumentSymbolModule to the module through IDocModule.
       AddModuleHandler, and its documentSymbol answers go into it. With
       PasTree selected no answer comes, the tables stay empty, and so does
       the toolbar.

  So we fill it. After each outline of the active file (the Structure pane's
  request, PasTreeIdePlugin.Outline) the rows become DelphiLSP's tree
  (PasTreeIdePlugin.NavSymbols) and go into the module's
  ILSPDocumentSymbolModule; a module without one gets one first - the IDE's
  OWN class, built by its exported constructor and attached exactly as
  DelphiLSP attaches it, so nothing of this package is left in a module when
  it unloads, and DelphiLSP finds and fills the same object once it is the
  provider again.

  REACHED BY NAME, NEVER LINKED, as NativeErrorInsight reaches coreide: the
  two interfaces are declared here by GUID and method order (identical in
  23.0 and 37.0, Win32 and Win64), the class and its constructor are
  GetProcAddress on the IDELSP beside the linked designide. RAD Studio 11.3
  has neither the interface nor the LSP parser - its toolbar reads the
  Castalia parser alone and needs nothing from us - so there the lookup
  finds nothing, says so once in the log, and this unit does nothing.
}

interface

uses
  PasTreeIdePlugin.OutlineRows;

/// <summary>
/// AFilePath's outline arrived (module scope, with uses items and extents):
/// its symbols into the module's ILSPDocumentSymbolModule, which the
/// navigation toolbar reads. Main thread; a file with no open module, or an
/// IDE without the seam, is left alone.
/// </summary>
procedure NavToolbarOutlineArrived(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  ToolsAPI,
  PasTreeIdePlugin.LspSession,   // LspLogDetail
  PasTreeIdePlugin.NavSymbols;

type
  /// <summary>
  /// IDELSP's LSPSrcInfo.ILSPDocumentSymbolModule. Only SetDocumentSymbols
  /// is called; the rest is declared so the slots line up.
  /// </summary>
  ILSPDocumentSymbolModule = interface(IInterface)
    ['{D8682E49-11EC-483F-93C7-53BF1E28CC8F}']
    procedure SetDocumentSymbols(const ASymbols: TNavSymbols);
    function GetDocumentSymbols: TNavSymbols;
    procedure SetEditBuffer(ABuffer: Pointer);
    function GetEditBuffer: Pointer;
    function RegisterChangeListener(const AFunc: IInterface): Integer;
    procedure UnregisterChangeListener(AId: Integer);
  end;

  /// <summary>
  /// coreide's DocModul.IDocModule, answered by every module
  /// (TCodeIDocModule). Only AddModuleHandler is called.
  /// </summary>
  IDocModule = interface(IInterface)
    ['{9E9C81A0-EDDC-11D1-9504-00608CCBF153}']
    function GetDocModule: TObject;
    procedure AddModuleHandler(const AHandler: IInterface);
    procedure ModuleHandlerAlsoOnNotifyList(const AHandler: IInterface);
    procedure ModuleHandlerNoLongerOnNotifyList(const AHandler: IInterface);
    procedure RemoveModuleHandler(const AHandler: IInterface);
  end;

  // A Delphi constructor called as a function: the class, and 1 = allocate.
  TSymbolModuleCtor = function(AClass: TClass; AAlloc: ShortInt): TObject;

const
{$IFDEF WIN64}
  cSymbolModuleClass = '_ZTVN10Lspsrcinfo24TLSPDocumentSymbolModuleE';
  cSymbolModuleCtor = '_ZN10Lspsrcinfo24TLSPDocumentSymbolModuleC3Ev';
{$ELSE}
  cSymbolModuleClass = '@Lspsrcinfo@TLSPDocumentSymbolModule@';
  cSymbolModuleCtor = '@Lspsrcinfo@TLSPDocumentSymbolModule@$bctr$qqrv';
{$ENDIF}

var
  GLooked: Boolean = False;
  GClass: TClass = nil;
  GCtor: TSymbolModuleCtor = nil;
  GFailLogged: Boolean = False;

{ IDELSP<ver>.bpl beside the designide this package was linked against. }
procedure LookUpSeam;
var
  LPath: string;
  LModule: HMODULE;
  LClass: Pointer;
begin
  if GLooked then
    Exit;
  GLooked := True;
  LPath := GetModuleName(FindHInstance(@BorlandIDEServices));
  LPath := ExtractFilePath(LPath) + StringReplace(ExtractFileName(LPath),
    'designide', 'IDELSP', [rfIgnoreCase]);
  LModule := GetModuleHandle(PChar(LPath));
  if LModule = 0 then
  begin
    LspLogDetail('navigation toolbar: ' + ExtractFileName(LPath)
      + ' is not loaded - the toolbar is left to the IDE');
    Exit;
  end;
  LClass := GetProcAddress(LModule, cSymbolModuleClass);
  @GCtor := GetProcAddress(LModule, cSymbolModuleCtor);
  if (LClass = nil) or not Assigned(GCtor) then
  begin
    GCtor := nil;
    LspLogDetail('navigation toolbar: ' + ExtractFileName(LPath)
      + ' has no TLSPDocumentSymbolModule - the toolbar is left to the IDE');
    Exit;
  end;
  GClass := TClass(LClass);
  // The export is the class itself: its VMT names it.
  if GClass.ClassName <> 'TLSPDocumentSymbolModule' then
  begin
    LspLogDetail('navigation toolbar: the exported class is '
      + GClass.ClassName + ', not TLSPDocumentSymbolModule - left alone');
    GClass := nil;
    GCtor := nil;
  end;
end;

{ The module's symbol object - DelphiLSP's, or one attached now. }
function SymbolModuleOf(const AModule: IOTAModule;
  out ASymbols: ILSPDocumentSymbolModule): Boolean;
var
  LDoc: IDocModule;
  LObj: TObject;
  LHandler: IInterface;
begin
  if Supports(AModule, ILSPDocumentSymbolModule, ASymbols) then
    Exit(True);
  Result := False;
  LookUpSeam;
  if (GClass = nil) or not Supports(AModule, IDocModule, LDoc) then
    Exit;
  // DelphiLSP's own steps (TLSPMgr.SendLSPDocumentSymbolRequest): construct,
  // hand the module the object's IInterface, find it through the module.
  LObj := GCtor(GClass, 1);
  if not LObj.GetInterface(IInterface, LHandler) then
  begin
    LObj.Free;
    Exit;
  end;
  LDoc.AddModuleHandler(LHandler);
  Result := Supports(AModule, ILSPDocumentSymbolModule, ASymbols);
end;

procedure NavToolbarOutlineArrived(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>);
var
  LServices: IOTAModuleServices;
  LModule: IOTAModule;
  LSymbols: ILSPDocumentSymbolModule;
  LTree: TNavSymbols;
begin
  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then
      Exit;
    LModule := LServices.FindModule(AFilePath);
    if LModule = nil then
      Exit;
    if not SymbolModuleOf(LModule, LSymbols) then
    begin
      if not GFailLogged and (GClass <> nil) then
      begin
        GFailLogged := True;
        LspLogDetail('navigation toolbar: no symbol object on the module of '
          + ExtractFileName(AFilePath) + ' - the toolbar stays as it is');
      end;
      Exit;
    end;
    LTree := BuildNavSymbols(AFilePath, ARows);
    LSymbols.SetDocumentSymbols(LTree);
  except
    on E: Exception do
      LspLogDetail('navigation toolbar: feeding ' + ExtractFileName(AFilePath)
        + ' failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

end.
