unit PasTreeIdePlugin.NavSymbols;

{ The editor's navigation toolbar symbols: a file's outline (pastree/outline,
  module scope, with its uses items and the node extents) reshaped into the
  tree DelphiLSP answers textDocument/documentSymbol with - because that tree
  is what the toolbar reads (PasTreeIdePlugin.NavToolbar has the seam).

  THE SHAPE IS DELPHILSP'S, read off its answer to a probe unit on 2026-11-03
  (DelphiLSP.exe driven over stdio, RAD Studio 13), not designed here:

    - the sections at the top, Kind 2 (Module): `interface`,
      `implementation`, `initialization`, `finalization` with Detail
      'section'; a program's main `begin` with Detail 'block';
    - a `uses` clause under its section (at the top in a program), Kind 2,
      Name 'uses', Detail 'section'; its units under it, Kind 1 (File);
    - a type under its section, its members under it (a nested type under
      its type): Kind 5 a class, 11 an interface, 23 (Struct) any other type
      - a record, an enumeration, a procedural type alike;
    - a field Kind 8 and a module variable 13, Name `FValue: Integer`; a
      constant 14 by its name; a property 7;
    - a routine's declaration Kind 6, Name `Get<T>(const A: T): T`, Detail
      'declaration'; its body Kind 6 under the implementation section, Name
      `TFoo.Get<T>(const A: T): T`, Detail 'implementation'. Constructors
      and free routines are Kind 6 too. A body's nested routines and local
      types are not symbols.

  WHAT REACHES THE TOOLBAR IS TWO LEVELS. codequeryide's writer
  (TSQLiteSymbolWriter.InsertSymbols) wraps the tree in a module root,
  flattens a section (Kind 2) into its parent, and descends from the root
  only: the tables hold the sections' children - types, routine bodies,
  globals - and nothing below them, members included. So a method body must
  stay a section's child; under its type (tried 2026-11-03, to give the type
  box the class of a caret in a body, which it finds by the body's parent
  chain) it is not written at all and the method list keeps only the
  globals. The type box is empty inside a body with DelphiLSP too.

  RANGES (LSP, 0-based): a section, a uses clause and a routine body span
  their node from its first token; everything else starts at its name; all
  end where the node ends. SelectionRange is the name. The toolbar's queries
  are "the type / the method whose lines hold the caret", so it is the END
  that matters, and only the server knows it (the 14th row element). A row
  without an extent (an older server) gets its name as its range.

  TNavSymbol IS THE IDE's RECORD, LspInsightAPI.TOTALSPDocumentSymbol, field
  for field - Name and Detail UTF8String, Kind a byte holding the LSP
  SymbolKind number, the tag set and Deprecated one byte each, two ranges of
  four Integers, the children: 48 bytes on Win32, 64 on Win64, identical in
  designide290 and designide370 (read from its RTTI, 2026-11-03). The IDE
  copies and frees it with its own type info, so the layout is the contract.

  NO IDE, NO PasTree: a plain RTL unit, so tests/LspClientSmoke builds the
  tree from the server's real answer with the code the package runs. }

interface

uses
  PasTreeIdePlugin.OutlineRows;

const
  // LSP SymbolKind numbers - the byte the IDE stores in TNavSymbol.Kind.
  cNavFile = 1;
  cNavModule = 2;
  cNavClass = 5;
  cNavMethod = 6;
  cNavProperty = 7;
  cNavField = 8;
  cNavInterface = 11;
  cNavVariable = 13;
  cNavConstant = 14;
  cNavStruct = 23;

type
  TNavPosition = record
    Line: Integer;
    Character: Integer;
  end;

  TNavRange = record
    Start: TNavPosition;
    Stop: TNavPosition;   // the IDE's End
  end;

  TNavSymbol = record
    Name: UTF8String;
    Detail: UTF8String;
    Kind: Byte;
    Tags: Byte;
    Deprecated: Boolean;
    Range: TNavRange;
    SelectionRange: TNavRange;
    Children: TArray<TNavSymbol>;
  end;

  TNavSymbols = TArray<TNavSymbol>;

// The IDE's record size (see the header): a field added or retyped here
// would hand the IDE records it reads at the wrong offsets.
{$IFDEF CPUX64}
  {$IF SizeOf(TNavSymbol) <> 64}
    {$MESSAGE ERROR 'TNavSymbol must match TOTALSPDocumentSymbol: 64 bytes on Win64'}
  {$IFEND}
{$ELSE}
  {$IF SizeOf(TNavSymbol) <> 48}
    {$MESSAGE ERROR 'TNavSymbol must match TOTALSPDocumentSymbol: 48 bytes on Win32'}
  {$IFEND}
{$ENDIF}

/// <summary>
/// The rows of AFilePath (pastree/outline, module scope, with uses items) as
/// DelphiLSP's documentSymbol tree. Rows of another file (an include) are
/// left out.
/// </summary>
function BuildNavSymbols(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>): TNavSymbols;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

type
  // A symbol without its children yet, and where it hangs: the tree is
  // built flat and nested at the end, since a record in a dynamic array
  // cannot be appended to through a reference.
  TFlat = record
    Sym: TNavSymbol;
    Parent: Integer;
  end;

function TypeKind(const ADetail: string): Byte;
var
  LDetail: string;
begin
  LDetail := LowerCase(Trim(ADetail));
  if (LDetail.StartsWith('= class') and not LDetail.StartsWith('= class of'))
    or LDetail.StartsWith('= packed class') or LDetail.StartsWith('= object')
  then
    Result := cNavClass
  else if LDetail.StartsWith('= interface')
    or LDetail.StartsWith('= dispinterface') then
    Result := cNavInterface
  else
    Result := cNavStruct;
end;

function Pos0(ALine, ACol: Integer): TNavPosition;
begin
  // 1-based (PasTree's) to LSP's 0-based; a missing position stays at 0.
  if ALine > 0 then
    Result.Line := ALine - 1
  else
    Result.Line := 0;
  if ACol > 0 then
    Result.Character := ACol - 1
  else
    Result.Character := 0;
end;

function BuildNavSymbols(const AFilePath: string;
  const ARows: TArray<TLspOutlineRow>): TNavSymbols;
var
  LFlat: TList<TFlat>;
  LTypes: TDictionary<string, Integer>;
  LRow: TLspOutlineRow;
  LSection, LUses, LParent, LIdx: Integer;
  // The routine body the rows are inside of, 1-based: rows within it are
  // its nested routines and local types, which DelphiLSP does not list.
  LBodySL, LBodySC, LBodyEL, LBodyEC: Integer;

  function InBody(ALine, ACol: Integer): Boolean;
  begin
    Result := (LBodyEL > 0) and
      ((ALine > LBodySL) or ((ALine = LBodySL) and (ACol >= LBodySC))) and
      ((ALine < LBodyEL) or ((ALine = LBodyEL) and (ACol < LBodyEC)));
  end;

  function Add(AKind: Byte; const AName, ADetail: string; AParent: Integer;
    AFromNode: Boolean): Integer;
  var
    LItem: TFlat;
  begin
    LItem := Default(TFlat);
    LItem.Parent := AParent;
    LItem.Sym.Name := UTF8String(AName);
    LItem.Sym.Detail := UTF8String(ADetail);
    LItem.Sym.Kind := AKind;
    LItem.Sym.SelectionRange.Start := Pos0(LRow.Line, LRow.Col);
    LItem.Sym.SelectionRange.Stop := LItem.Sym.SelectionRange.Start;
    if LRow.Name <> '' then
      Inc(LItem.Sym.SelectionRange.Stop.Character, Length(LRow.Name))
    else
      Inc(LItem.Sym.SelectionRange.Stop.Character, Length(LRow.Head));
    LItem.Sym.Range := LItem.Sym.SelectionRange;
    if LRow.ExtEndLine > 0 then
    begin
      if AFromNode then
        LItem.Sym.Range.Start := Pos0(LRow.ExtStartLine, LRow.ExtStartCol);
      LItem.Sym.Range.Stop := Pos0(LRow.ExtEndLine, LRow.ExtEndCol);
    end;
    Result := LFlat.Add(LItem);
  end;

  function OwnerOrSection: Integer;
  begin
    // A member under its type; one whose type is not here (an include holds
    // it, or it is spelled differently) stays in its section.
    if (LRow.Owner = '') or
       not LTypes.TryGetValue(LowerCase(LRow.Owner), Result) then
      Result := LSection;
  end;

var
  // Per symbol (index + 1; 0 is the top), its children in source order.
  LKids: TArray<TArray<Integer>>;

  function Nest(AParent: Integer): TNavSymbols;
  var
    I: Integer;
    LOwn: TArray<Integer>;
  begin
    LOwn := LKids[AParent + 1];
    SetLength(Result, Length(LOwn));
    for I := 0 to High(LOwn) do
    begin
      Result[I] := LFlat[LOwn[I]].Sym;
      Result[I].Children := Nest(LOwn[I]);
    end;
  end;

var
  LName, LKey: string;
  LNode: Integer;
begin
  LFlat := TList<TFlat>.Create;
  LTypes := TDictionary<string, Integer>.Create;
  try
    LSection := -1;
    LUses := -1;
    LBodyEL := 0;
    for LRow in ARows do
    begin
      if not SameText(LRow.FilePath, AFilePath) then
        Continue;
      if LRow.Kind = 'section' then
      begin
        LBodyEL := 0;
        if LRow.Head = 'begin' then
          LSection := Add(cNavModule, LRow.Head, 'block', -1, True)
        else
          LSection := Add(cNavModule, LRow.Head, 'section', -1, True);
        LUses := -1;
        Continue;
      end;
      if InBody(LRow.Line, LRow.Col) then
        Continue;
      LBodyEL := 0;
      if LRow.Kind = 'uses' then
      begin
        if LRow.Name = '' then
          LUses := Add(cNavModule, 'uses', 'section', LSection, True)
        else if LUses >= 0 then
          Add(cNavFile, LRow.Name, '', LUses, False);
      end
      else if LRow.Kind = 'type' then
      begin
        LParent := OwnerOrSection;
        LIdx := Add(TypeKind(LRow.Detail), LRow.Name, '', LParent, False);
        if LRow.Owner <> '' then
          LKey := LRow.Owner + '.' + LRow.Name
        else
          LKey := LRow.Name;
        LTypes.AddOrSetValue(LowerCase(LKey), LIdx);
      end
      else if LRow.Kind = 'var' then
      begin
        if LRow.Owner <> '' then
          Add(cNavField, LRow.Name + LRow.Detail, '', OwnerOrSection, False)
        else
          Add(cNavVariable, LRow.Name + LRow.Detail, '', LSection, False);
      end
      else if LRow.Kind = 'const' then
        Add(cNavConstant, LRow.Name, '', OwnerOrSection, False)
      else if LRow.Kind = 'property' then
        Add(cNavProperty, LRow.Name + LRow.Detail, '', OwnerOrSection, False)
      else if LRow.Kind = 'routine' then
      begin
        if LRow.IsImpl then
        begin
          LName := LRow.Name + LRow.Detail;
          if LRow.Owner <> '' then
            LName := LRow.Owner + '.' + LName;
          Add(cNavMethod, LName, 'implementation', LSection, True);
          if LRow.ExtEndLine > 0 then
          begin
            LBodySL := LRow.ExtStartLine;
            LBodySC := LRow.ExtStartCol;
            LBodyEL := LRow.ExtEndLine;
            LBodyEC := LRow.ExtEndCol;
          end;
        end
        else
          Add(cNavMethod, LRow.Name + LRow.Detail, 'declaration',
            OwnerOrSection, False);
      end;
      // module and include rows: DelphiLSP has no symbol for either.
    end;
    SetLength(LKids, LFlat.Count + 1);
    for LNode := 0 to LFlat.Count - 1 do
    begin
      LParent := LFlat[LNode].Parent + 1;
      LKids[LParent] := LKids[LParent] + [LNode];
    end;
    Result := Nest(-1);
  finally
    LTypes.Free;
    LFlat.Free;
  end;
end;

end.
