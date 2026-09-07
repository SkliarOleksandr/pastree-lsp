unit DemoInference;

{
  Fixture for LspClientSmoke 5l - member typing through this server's seam,
  in shapes that get progressively harder, so a failure says WHICH one broke
  rather than "types do not work". Each is reached INDEPENDENTLY of the ones
  after it, which is the whole design: the first version reached the promoted
  property through an inline var, so one missing type failed both checks and
  neither said which.

    1. a typed local          `LPlain: TInner`      -> LPlain.Value
    2. a written property     TBaseHolder.Items     -> LBase.Items.Value
    3. a promoted property    `property Items;`     -> LTyped.Items.Value
                              (PasTree 0.17.1; reached from a TYPED local, so
                              it does not depend on 3 below)
    4. an inline var          `var L := MakeHolder` (PasTree 0.17.0)
    5. an inline var from a CONSTRUCTOR call - `var L := THolder.Create`,
       which PasTree 0.17.1 does NOT type (measured 2026-09-07): a
       constructor is not a function with a declared result type, and the
       inference does not special-case it. Kept here, unasserted, because the
       idiom is everywhere and this is where the coverage goes if the library
       grows it.

  All of these are silent when they break: the identifier still exists, hover
  still answers (it shows the declaration LINE, initializer included, so it
  cannot tell you whether anything was inferred), and only the TYPE behind
  the name goes missing - with it every member reached through it. So the
  checks ask what has no answer at all without the type: what type is this,
  and where does the member BEHIND it live.

  In DemoApp.dpr's closure on purpose: these are resolver answers, and the
  resolver needs the project.
}

interface

type
  TInner = class
  public
    Value: string;
    function Describe: string;
  end;

  TBaseHolder = class
  strict protected
    // Declared here, promoted in THolder - the shape 0.17.1 is about.
    property Items: TInner read FItems write FItems;
  private
    FItems: TInner;
  end;

  THolder = class(TBaseHolder)
  public
    // No type written: it is TInner, and only the ancestor says so.
    property Items;
  end;

function MakeHolder: THolder;
procedure UseHolder;

implementation

function TInner.Describe: string;
begin
  Result := Value;
end;

function MakeHolder: THolder;
begin
  Result := THolder.Create;
  Result.Items := TInner.Create;
end;

procedure UseHolder;
var
  LPlain: TInner;
  LBase: TBaseHolder;
  LTyped: THolder;
begin
  // 1. The baseline: a local with a written type, and its member.
  LPlain := TInner.Create;
  LPlain.Value := 'plain';
  // 2. A property with a written type, and the member behind it.
  LBase := TBaseHolder.Create;
  LBase.Items := LPlain;
  // 3. Through the PROMOTED property, from a TYPED local: Value is TInner's,
  // reached from a redeclaration that names no type at all.
  LTyped := MakeHolder;
  LTyped.Items.Value := 'promoted';
  LTyped.Items.Value := LTyped.Items.Describe;
  // 4. An inline var typed from a parameterless call, and a member behind it.
  var LFromCall := MakeHolder;
  LFromCall.Items := LPlain;
  // 5. An inline var typed from a constructor call.
  var LFromCtor := THolder.Create;
  LFromCtor.Items := LPlain;
end;

end.
