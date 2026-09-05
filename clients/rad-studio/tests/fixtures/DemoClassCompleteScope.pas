unit DemoClassCompleteScope;

{
  Fixture for LspClientSmoke 5k: what class completion must NOT invent, and
  where a new member's line begins. Both from one press of Ctrl+Shift+C on an
  empty line of uaviTypes.pas (2026-09-05).

  INHERITED MEMBERS. `property X: Integer read FX` on a class whose PARENT
  declares FX is complete as written. When the parent is in this unit the
  walk sees FX and declares nothing (TChildHere). When the parent is in
  another unit nothing can be seen, so a FIELD-shaped name is left alone -
  the eight `Code: string` fields written into TLabNameObject's descendants
  were the parent's field - while a Get/Set-shaped name still gets its method
  and a bare property is still completed (TChildAway). An interface with a
  foreign ancestor gets nothing at all (IChildAway); with an in-unit one, the
  walk decides (IChildHere).

  THE SEMICOLON. A field's node ends on its type; the `;` is the parser's.
  Anchoring after the node's last token wrote `FNewProvider: Boolean` + CRLF +
  `Code: string;` + `;`. The new member goes after the `;` (TChildHere.FA).
}

interface

type
  TParentHere = class
  private
    FX: Integer;
    function GetY: Integer;
  end;

  TChildHere = class(TParentHere)
  private
    FA: Integer;
  public
    property X: Integer read FX write FX;
    property Y: Integer read GetY;
    property Z: Integer read GetZ;
  end;

  TChildAway = class(TSomewhereElse)
    property Kode: string read Code write Code;
    property Thing: Integer read GetThing;
    property Bare: Integer;
  end;

  IBaseHere = interface
    function GetV: Integer;
  end;

  IChildHere = interface(IBaseHere)
    property V: Integer read GetV;
  end;

  IChildAway = interface(ISomewhereElse)
    property W: Integer read GetW;
  end;

implementation

function TParentHere.GetY: Integer;
begin
  Result := FX;
end;

end.
