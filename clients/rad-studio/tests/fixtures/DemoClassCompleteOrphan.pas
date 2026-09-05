unit DemoClassCompleteOrphan;

{
  Fixture for LspClientSmoke 5i: an ORPHAN implementation IN ISOLATION - no
  missing body anywhere in the unit, so the only edit is the declaration
  written back into TLone. This is what proves the CARET rule on its own:
  when class completion has nothing to generate a body for, it must still
  land the caret on the declaration it just wrote, not leave it at 0 (which
  a client reads as "wherever the user already was" - the start of the
  buffer if that happened to be a fresh open, 2026-09-05).
}

interface

type
  TLone = class
  public
    procedure Known;
  end;

implementation

procedure TLone.Known;
begin
end;

procedure TLone.Extra(const A: Integer);
begin
end;

end.
