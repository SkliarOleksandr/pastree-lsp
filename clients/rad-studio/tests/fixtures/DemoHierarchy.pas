unit DemoHierarchy;

{ Fixture for the two hierarchy requests in tests\LspClientSmoke.dpr -
  pastree/findOverrides and pastree/findImplementations.

  A three-level chain with every row kind the override search reports (root,
  override, reintroduce, message) plus a hiding declaration that must NOT be a
  row; an interface with a direct implementor, an implementor through a
  descendant interface, and a class that satisfies the method through its
  ancestor (the `inherited` row, named via the class that listed the
  interface). Positions are found by text in the test, so the shape matters
  and the line numbers do not. }

interface

const
  WM_DEMO = 1024 + 1;

type
  TDemoMessage = record
    Msg: Cardinal;
  end;

  TShape = class
    procedure Paint; virtual;
    procedure Describe; virtual;
    procedure OnDemo(var AMsg: TDemoMessage); message WM_DEMO;
  end;

  TCircle = class(TShape)
    procedure Paint; override;
  end;

  TSquare = class(TShape)
    procedure Paint; override;
    // Deliberately NOT an override - reported as `reintroduce` so a reader
    // does not mistake it for one.
    procedure Describe; reintroduce;
  end;

  TRoundedSquare = class(TSquare)
    procedure Paint; override;
    // A message handler is implicitly virtual and dcc rejects `override` on
    // one: it is in the chain of the ancestor's `message` handler by name.
    procedure OnDemo(var AMsg: TDemoMessage); message WM_DEMO;
  end;

  TUnrelated = class
    // Same name, no directive, no common ancestor: never a row.
    procedure Paint;
  end;

  IGreeter = interface
    ['{5E1F0A8C-9C4B-4B9F-8E3A-2D6B7C1F0A11}']
    procedure Greet;
  end;

  ILoudGreeter = interface(IGreeter)
    ['{5E1F0A8C-9C4B-4B9F-8E3A-2D6B7C1F0A12}']
    procedure Shout;
  end;

  TPoliteGreeter = class(IGreeter)
    procedure Greet;
  end;

  TLoudGreeter = class(ILoudGreeter)
    procedure Greet;
    procedure Shout;
  end;

  // Declares Greet itself but lists no interface...
  TGreeterBase = class
    procedure Greet; virtual;
  end;

  // ...and this descendant takes IGreeter on while inheriting the method:
  // the `inherited` row, positioned on TGreeterBase.Greet, via TInheritedGreeter.
  TInheritedGreeter = class(TGreeterBase, IGreeter)
  end;

implementation

procedure TShape.Paint;
begin
end;

procedure TShape.Describe;
begin
end;

procedure TShape.OnDemo(var AMsg: TDemoMessage);
begin
end;

procedure TCircle.Paint;
begin
  inherited;
end;

procedure TSquare.Paint;
begin
  inherited;
end;

procedure TSquare.Describe;
begin
end;

procedure TRoundedSquare.Paint;
begin
  inherited;
end;

procedure TRoundedSquare.OnDemo(var AMsg: TDemoMessage);
begin
end;

procedure TUnrelated.Paint;
begin
end;

procedure TPoliteGreeter.Greet;
begin
end;

procedure TLoudGreeter.Greet;
begin
end;

procedure TLoudGreeter.Shout;
begin
end;

procedure TGreeterBase.Greet;
begin
end;

end.
