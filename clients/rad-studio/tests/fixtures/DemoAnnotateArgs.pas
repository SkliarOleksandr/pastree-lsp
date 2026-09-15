unit DemoAnnotateArgs;

(*
  Fixture for LspClientSmoke section 5l - pastree/annotateArgs. NOT part of
  DemoApp.dpr's closure, like DemoSyncPrototypes: the request resolves the
  LIVE buffer through the overlay, and a fixture that needs no project proves
  the standalone half. Positions are found by text in the test, so the shape
  matters and the line numbers do not; every call line below is unique as a
  substring, semicolon included.

  The calls in Demo, one per rule (spelled loosely here ON PURPOSE - the test
  finds its lines by substring, and a comment repeating a call verbatim would
  be found first):
    the first Open call      - const / var / out / defaulted: `{var}` and
                               `{out}` are written, `{const}` is not, and
                               the omitted default gets nothing.
    the second Open call     - half annotated: only what is missing is added.
    the two Twin calls       - overloads told apart by ARITY.
    the two Same calls       - overloads told apart by TYPE - the resolver's
                               choice, not a guess by count.
    Outer over Inner         - nested: the caret on `Inner` means Inner's
                               arguments, on the 4 means Outer's second.
    the W.Method call        - a member call, `AFirst, ASecond` declared as
                               one group and annotated as two.
    the Write call           - a variadic intrinsic: nothing to name, and the
                               answer says so.
    Inc with one and two     - an intrinsic with an OPTIONAL trailing
                               parameter: the call's count decides.
    Val                      - an intrinsic with var parameters, named from
                               the engine's signature table.
    Read with a string       - an intrinsic with an optional LEADING file:
                               one argument skips it.
*)

interface

type
  TWorker = class
    procedure Method(AFirst, ASecond: Integer; const AName: string);
  end;

procedure Open(const AFileName: string; var AMode: Integer;
  out AHandle: Integer; ACount: Integer = 1);
procedure Twin(A: Integer); overload;
procedure Twin(A: Integer; B: Integer); overload;
procedure Same(A: Integer); overload;
procedure Same(const S: string); overload;
function Inner(X: Integer): Integer;
procedure Outer(AValue: Integer; AExtra: Integer);

type
  TGateway = procedure(const ARequest: string; out AReply: string);
  TGatewayAlias = TGateway;

var
  Gateway: TGatewayAlias;
  Hook: procedure(ACount: Integer);

implementation

procedure TWorker.Method(AFirst, ASecond: Integer; const AName: string);
begin
end;

procedure Open(const AFileName: string; var AMode: Integer;
  out AHandle: Integer; ACount: Integer);
begin
end;

procedure Twin(A: Integer);
begin
end;

procedure Twin(A: Integer; B: Integer);
begin
end;

procedure Same(A: Integer);
begin
end;

procedure Same(const S: string);
begin
end;

function Inner(X: Integer): Integer;
begin
  Result := X;
end;

procedure Outer(AValue: Integer; AExtra: Integer);
begin
end;

procedure Demo;
var
  S: string;
  M, H: Integer;
  W: TWorker;
begin
  Open(S, M, H);
  Open({AFileName:} S, {var} {AMode:} M, H);
  Twin(1);
  Twin(1, 2);
  Same(5);
  Same('x');
  Outer(Inner(3), 4);
  W.Method(1, 2, S);
  Write(S);
  Inc(M);
  Inc(M, 2);
  Val(S, M, H);
  Read(S);
  Gateway(S, S);
  Hook(M);
  Open({AFileName:} S, M, {AHandle:} H);
  M := 0;
end;

end.
