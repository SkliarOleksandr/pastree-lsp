unit DemoHoverInfer;

{ Fixture for LspClientSmoke 5c: every place a declaration takes its type
  from somewhere else instead of writing one - an inline var's initializer, a
  for counter's bound, a for-in collection's element, an inline const - so the
  hover's `var Name: Type` line is checked for each shape (Alex, 2026-10-07: a
  for-in element over `[LDir] + FLastSearchPaths` showed no type at all). }

interface

uses
  System.Generics.Collections,
  DemoAnnotateLib;

type
  TInferItem = class
    Name: string;
  end;

  // Compiler-intrinsic types, hovered for their range.
  TInferWhole = Integer;
  TInferCount = Cardinal;
  TInferReal = Double;

  // Generic parameters, hovered for themselves rather than their owner.
  TInferBox<TBoxed> = class
    Boxed: TBoxed;
    function Pick<TPicked>(const AValue: TPicked): TPicked;
    function Make<TMade: class, constructor; TKept: TInferItem>(
      const AKept: TKept): TMade;
  end;

  // Words before or after a type's head that are flags in the tree.
  TInferFunc<TArg> = reference to function(const AArg: TArg): Boolean;
  TInferBase = class abstract
  end;

  // A nested generic ancestor: every argument in it is painted as a type.
  TInferNest<TNested> = class(TInferBox<TInferBox<TNested>>)
  end;

const
  // A constant whose value names its own type in a qualified spelling.
  CInferBlue = DemoAnnotateLib.TDemoColor.dcBlue;
  CInferLevel = 3;

// Names inside a $IF expression, hovered and Ctrl+Clicked like names in code.
{$IF CompilerVersion > 20}
const CInferModern = 1;
{$IFEND}
{$IF CInferLevel > 2}
const CInferHigh = 1;
{$IFEND}

type
  // A unit-qualified intrinsic type.
  TInferQual = System.Byte;

function MakeInferItem: TInferItem;

procedure InferAll(const ADir: string; const APaths: TArray<string>;
  AList: TList<TInferItem>);

implementation

function TInferBox<TBoxed>.Pick<TPicked>(const AValue: TPicked): TPicked;
begin
  Result := AValue;
end;

function TInferBox<TBoxed>.Make<TMade, TKept>(const AKept: TKept): TMade;
begin
  Result := TMade.Create;
end;

function MakeInferItem: TInferItem;
begin
  Result := TInferItem.Create;
end;

procedure InferAll(const ADir: string; const APaths: TArray<string>;
  AList: TList<TInferItem>);
begin
  var IStr := 'text';
  var IInt := 42;
  var IFloat := 1.5;
  var IBool := True;
  var ICall := MakeInferItem;
  var ICtor := TInferItem.Create;
  var IExpr := ADir + '\';
  var IMember := ICall.Name;
  const IConst = 7;
  for var ICount := 0 to 10 do
    IInt := IInt + ICount;
  for var IPath in APaths do
    IStr := IPath;
  for var IJoined in [ADir] + APaths do
    IStr := IJoined;
  for var ILiteral in ['.pas', '.inc'] do
    IStr := ILiteral;
  for var IChar in ADir do
    IStr := IChar;
  for var IItem in AList do
    IStr := IItem.Name;
  if IBool and (IFloat > IConst) then
    ICtor.Free;
  // Intrinsic routines and constants, hovered for their signature.
  IInt := Length(ADir);
  Inc(IInt);
  IInt := High(APaths);
  IBool := False;
end;

end.
