unit PasTreeIdePlugin.DcuNames;

{
  The naming contract between a compiled unit's path and the editor tab that
  shows the text PasTree generates for it - and the cache of that text.

  WHY THE TAB IS NOT NAMED Foo.dcu. A navigation answer into a third-party
  unit shipped compiled-only names the .dcu itself: the server analyzes such
  a unit from its .dcu (PasTree 0.37.0, TPasSourceManager's fallback), and
  every Location it answers with carries `file:///.../lib/win32/release/
  Foo.dcu` and a line of the interface text it generated. The IDE cannot
  open that path as source - it picks the editor and the highlighter by
  extension, and .dcu is a binary to it. So the module the plugin creates
  for it (PasTreeIdePlugin.DcuSource, through a registered IOTAFileSystem)
  is named `<full path>\Foo.dcu.pas`: the .pas suffix buys the Pascal
  highlighter, the retained .dcu says on the tab what the reader is looking
  at, and the mapping in both directions is a plain suffix rule with no
  table to keep in step. The PATH is kept whole so two libraries' Foo.dcu
  stay two tabs.

  WHY THE MAPPING IS APPLIED IN THE URI FUNCTIONS. Everything the plugin
  says about that tab to the server - didOpen, definition from inside it,
  hover, references, the outline - names the buffer's own FileName. The
  server knows the file only as Foo.dcu (that is the model's path, and what
  LoadFileTolerant regenerates to compare against the buffer), so
  PathToLspUri maps the virtual name to the .dcu before it leaves and the
  server never learns the .pas spelling. Answers come back naming Foo.dcu,
  and navigation (GotoDeclaration.NavigateToPosition) is where that turns
  into the tab. One rule, at the seam, rather than a check in every
  request.

  NO ToolsAPI HERE, ON PURPOSE. PasTreeIdePlugin.LspClient needs the
  mapping and PasTreeIdePlugin.DcuSource (which owns the file system and
  the modules) needs LspSession; a unit both can use has to sit below both.
  The text cache lives here for the same reason: the file system reads it,
  LspSession's snippet lookup (LspSourceTextOf) reads it, and neither may
  depend on the other.
}

interface

/// <summary>True when APath names a compiled unit (extension .dcu).</summary>
function IsDcuPath(const APath: string): Boolean;

/// <summary>
/// The virtual module name for a compiled unit: the .dcu path with .pas
/// appended (`C:\lib\Foo.dcu` -> `C:\lib\Foo.dcu.pas`).
/// </summary>
function DcuVirtualName(const ADcuPath: string): string;

/// <summary>
/// The .dcu behind a virtual module name, or '' when AName is not one
/// (`C:\lib\Foo.dcu.pas` -> `C:\lib\Foo.dcu`; `C:\src\Foo.pas` -> '').
/// </summary>
function DcuPathOfVirtual(const AName: string): string;

/// <summary>
/// The .dcu a file name stands for, whichever spelling it uses: the .dcu
/// itself, or its virtual module name. '' for an ordinary source file. What
/// navigation calls to decide whether a target is a generated tab.
/// </summary>
function DcuPathOfAny(const AName: string): string;

/// <summary>
/// The name the SERVER knows a path by: a virtual module name becomes its
/// .dcu, everything else is returned unchanged. Applied by PathToLspUri.
/// </summary>
function LspPathOf(const APath: string): string;

/// <summary>
/// Keeps the generated text of a .dcu for the file system to serve and for
/// snippet lookups. Keyed by the .dcu path, case-insensitively.
/// </summary>
procedure RememberDcuText(const ADcuPath, AText: string);

/// <summary>The remembered text of a .dcu, by either spelling of its name.</summary>
function TryGetDcuText(const AName: string; out AText: string): Boolean;

/// <summary>Drops every remembered text - the server that made them is gone.</summary>
procedure ForgetDcuTexts;

/// <summary>Every .dcu path a text is remembered for.</summary>
function RememberedDcuPaths: TArray<string>;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections;

const
  cVirtualSuffix = '.dcu.pas';

type
  TDcuEntry = record
    Path: string;   // the .dcu as first named, for closing its module by name
    Text: string;
  end;

var
  GTexts: TDictionary<string, TDcuEntry>;

function IsDcuPath(const APath: string): Boolean;
begin
  Result := SameText(TPath.GetExtension(APath), '.dcu');
end;

function DcuVirtualName(const ADcuPath: string): string;
begin
  Result := ADcuPath + '.pas';
end;

function DcuPathOfVirtual(const AName: string): string;
begin
  if AName.EndsWith(cVirtualSuffix, True) then
    Result := Copy(AName, 1, Length(AName) - Length('.pas'))
  else
    Result := '';
end;

function DcuPathOfAny(const AName: string): string;
begin
  if IsDcuPath(AName) then
    Result := AName
  else
    Result := DcuPathOfVirtual(AName);
end;

function LspPathOf(const APath: string): string;
begin
  Result := DcuPathOfVirtual(APath);
  if Result = '' then
    Result := APath;
end;

function Key(const ADcuPath: string): string;
begin
  Result := LowerCase(ADcuPath);
end;

procedure RememberDcuText(const ADcuPath, AText: string);
var
  LEntry: TDcuEntry;
begin
  LEntry.Path := ADcuPath;
  LEntry.Text := AText;
  GTexts.AddOrSetValue(Key(ADcuPath), LEntry);
end;

function TryGetDcuText(const AName: string; out AText: string): Boolean;
var
  LDcu: string;
  LEntry: TDcuEntry;
begin
  LDcu := DcuPathOfAny(AName);
  Result := (LDcu <> '') and GTexts.TryGetValue(Key(LDcu), LEntry);
  if Result then
    AText := LEntry.Text
  else
    AText := '';
end;

procedure ForgetDcuTexts;
begin
  GTexts.Clear;
end;

function RememberedDcuPaths: TArray<string>;
var
  LEntry: TDcuEntry;
begin
  Result := nil;
  for LEntry in GTexts.Values do
    Result := Result + [LEntry.Path];
end;

initialization
  GTexts := TDictionary<string, TDcuEntry>.Create;

finalization
  FreeAndNil(GTexts);

end.
