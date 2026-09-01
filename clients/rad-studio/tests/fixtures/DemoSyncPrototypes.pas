unit DemoSyncPrototypes;

{
  Fixture for LspClientSmoke section 5h - one pair per rule prototype sync has
  to follow. NOT part of DemoApp.dpr's closure, for the same reason
  DemoClassComplete is not: pastree/syncPrototypes is a parse of one buffer,
  and a fixture that needs no project proves it.

  DELIBERATELY DOES NOT COMPILE as Delphi, and could not: every pair below is
  a declaration and an implementation whose signatures DISAGREE, which is
  exactly the state the feature exists to end. The parser has no opinion about
  that - it builds the tree either way - and the analysis never sees this file.

  The pairs:
    Grew      - the DECLARATION gained a parameter; the body must follow.
    Shrank    - the BODY lost one; the declaration must follow.
    Became    - a procedure that became a function, declared side first.
    Defaults  - a default value in the declaration, which the body must NOT
                repeat (E2226) - on a parameter the body does not have yet,
                so the stripping is visible in the edit rather than making
                the two sides equal.
    Steady    - the pair that differs ONLY by a default: equal once stripped,
                so the answer must be "already in step" and no edit at all.
    ClassGone - a `class procedure` whose body forgot the word: mirroring
                puts it back, which the replacement range has to reach over.
    Twin      - two overloads, one of them out of step: ambiguous, refused.
    Lonely    - declared and never implemented: not this feature's business.
    FreeOne   - a free routine of the interface section, same as a method.
}

interface

type
  TBase = class
  public
    procedure Grew(A: Integer; const B: string);
    procedure Shrank(A: Integer; B: Integer);
    function Became(A: Integer): string;
    procedure Defaults(A: Integer = 7; const B: string = '');
    procedure Steady(A: Integer = 3);
    class procedure ClassGone(A: Integer);
    function Twin(A: Integer): Integer; overload;
    function Twin(const A: string): Integer; overload;
    procedure Lonely(A: Integer);
  end;

procedure FreeOne(A: Integer);

implementation

procedure TBase.Grew(A: Integer);
begin
end;

procedure TBase.Shrank(A: Integer);
begin
end;

procedure TBase.Became(A: Integer);
begin
end;

procedure TBase.Defaults(A: Integer);
begin
end;

procedure TBase.Steady(A: Integer);
begin
end;

procedure TBase.ClassGone(A: Integer);
begin
end;

function TBase.Twin(A: Integer; B: Integer): Integer;
begin
  Result := A;
end;

function TBase.Twin(const A: string): Integer;
begin
  Result := 0;
end;

procedure FreeOne(A: Integer; const B: string);
begin
end;

end.
