unit PasLsp.SourceText;

{
  Source text coming in from outside: from a client's buffer, or from a file on
  disk. Three small answers, in one place, because every one of them has been
  gotten wrong somewhere in this product already.

  SHARED WITH THE RAD STUDIO PACKAGE, and therefore under the same rule as
  PasLsp.ProductVersion: this unit uses the RTL and NOTHING from this project,
  and it must never gain a dependency — above all not on PasTree, which is
  Win64-only while the package is a Win32 designtime BPL. That is the entire
  reason the analysis runs out of process. tests/VersionSmoke links this unit
  into a Win32 program for exactly that reason: if a `uses` line creeps in
  here, that harness stops compiling, which is the alarm.

  Why it exists at all: the BOM problem showed up three separate times, in
  three separate layers, and each was fixed locally.

  - A leading U+FEFF in document text made PasTree's position index treat it as
    content, and `IdentAt` then found nothing at ANY position in that file, not
    merely on line 1 — navigation in the file stopped working entirely while
    the log said only "no identifier at ...", which reads exactly like a
    resolver bug. Measured 2026-08-20; it cost a debugging session.
  - The IDE client had its own strip (ReadBufferText), so the IDE was covered
    and the server's own flaw stayed invisible to every test.
  - The rebuild gate had to skip a BOM at the BYTE level to decide whether an
    editor's text is what the file holds, or peeking a declaration cost two
    full closure rebuilds.

  Same character, three encodings of the same rule. Hence one unit.
}

interface

uses
  System.SysUtils,
  System.IOUtils;

{ AText with a leading U+FEFF removed.

  A BOM is an encoding marker, not content — but a client is free to hand its
  buffer over with the character still in it, and a UTF-8-with-BOM .pas is
  completely ordinary in a Delphi project. Call this at the boundary where
  text arrives, not at every place that later reads it.

  The residual cost is that a client which counts the BOM as a character is
  then off by one on line 1 alone — strictly smaller than a file in which
  nothing resolves at all. }
function StripLeadingBom(const AText: string): string;

{ The file's text, decoded, with no BOM; False (and AText = '') if it cannot be
  read. Non-raising on purpose: every caller so far degrades gracefully — no
  snippet, or "treat the buffer as the truth" — and none of them wants an
  exception from a file that was deleted between two IDE events. }
function TryReadTextNoBom(const APath: string; out AText: string): Boolean;

{ Whether the file at APath holds exactly AText, encoded as UTF-8 — a leading
  UTF-8 BOM in the file being not-content, as above.

  This is a BYTE comparison rather than a text one, and that is the point. The
  analysis decodes a source with no BOM as ANSI (dcc's rule) while an editor
  decodes it as UTF-8, so comparing the two decoded strings reports every file
  containing an em-dash as "modified" — which made the rebuild gate rebuild the
  whole closure twice for a peek that touched nothing. A decode disagreement is
  not an edit. False if the file cannot be read: unknown, so assume different. }
function FileHoldsText(const APath, AText: string): Boolean;

implementation

function StripLeadingBom(const AText: string): string;
begin
  if (AText <> '') and (AText[1] = #$FEFF) then
    Result := Copy(AText, 2, MaxInt)
  else
    Result := AText;
end;

function TryReadTextNoBom(const APath: string; out AText: string): Boolean;
begin
  AText := '';
  try
    if not TFile.Exists(APath) then
      Exit(False);
    // ReadAllText detects and drops a preamble itself; the strip below covers
    // the case it cannot see - a second BOM, or a decode that kept the first.
    AText := StripLeadingBom(TFile.ReadAllText(APath));
    Result := True;
  except
    AText := '';
    Result := False;
  end;
end;

function FileHoldsText(const APath, AText: string): Boolean;
var
  LFile, LEnc: TBytes;
  LOffset: Integer;
begin
  try
    LFile := TFile.ReadAllBytes(APath);
  except
    Exit(False);
  end;
  LEnc := TEncoding.UTF8.GetBytes(AText);
  LOffset := 0;
  if (Length(LFile) >= 3) and (LFile[0] = $EF) and (LFile[1] = $BB) and
     (LFile[2] = $BF) then
    LOffset := 3;
  if Length(LFile) - LOffset <> Length(LEnc) then
    Exit(False);
  Result := (Length(LEnc) = 0) or
    CompareMem(@LFile[LOffset], @LEnc[0], Length(LEnc));
end;

end.
