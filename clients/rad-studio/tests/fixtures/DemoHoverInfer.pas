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

const
  // A constant whose value names its own type in a qualified spelling.
  CInferBlue = DemoAnnotateLib.TDemoColor.dcBlue;

function MakeInferItem: TInferItem;

procedure InferAll(const ADir: string; const APaths: TArray<string>;
  AList: TList<TInferItem>);

implementation

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
end;

end.
