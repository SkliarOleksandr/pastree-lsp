unit PasLsp.SourceText;

{
  Source text coming in from outside - from a client's buffer or from a file on
  disk - and, since 0.20.1, going back OUT to a file. Small answers, in one
  place, because every one of them has been gotten wrong somewhere in this
  product already.

  The write side exists for one caller: a rename reaching a unit nobody has
  open (PasTreeIdePlugin.Rename). It is the same knowledge as the read side -
  which preamble a .pas carries and what its bytes mean - used in the other
  direction, and putting it anywhere else would be a second place to get the
  same thing wrong. See TPasSourceEncoding.

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
  exception from a file that was deleted between two IDE events.

  DECODED THE WAY THE ANALYSIS DECODES IT — same detection as
  TryReadSourceForEdit, which is the point (see the body). One consequence
  worth naming: a UTF-16 source is "cannot be read", exactly as it is there,
  because no answer this unit gives can describe it. A .pas the Delphi IDE
  wrote is never UTF-16. }
function TryReadTextNoBom(const APath: string; out AText: string): Boolean;

{ Whether the file at APath holds exactly AText, encoded as UTF-8 — a leading
  UTF-8 BOM in the file being not-content, as above.

  This is a BYTE comparison rather than a text one, and that is the point. Any
  decode disagreement between what wrote the file and what read it — the
  historical one was the analysis reading a preamble-less source as ANSI while
  an editor read it as UTF-8 — reports every file containing an em-dash as
  "modified", which made the rebuild gate rebuild the whole closure twice for a
  peek that touched nothing. A decode disagreement is not an edit, and bytes
  are the one question no decoder gets to answer differently. False if the file
  cannot be read: unknown, so assume different. }
function FileHoldsText(const APath, AText: string): Boolean;

{ How a source file on disk is encoded - only ever three answers in a Delphi
  project, and the ONE reason this type exists is that a host which EDITS a
  file has to put it back the way it found it.

  peUtf8Bom is what the IDE writes by default. peUtf8 is a preamble-less file
  whose bytes are valid UTF-8 - PasTree decodes those as UTF-8 (see the
  repository's CLAUDE.md on why that changed), so writing them back as
  anything else would move every non-ASCII column in the file.

  peBytes is everything else - a legacy ANSI source - and it is deliberately
  NOT "decode as ANSI". The active code page is not a round trip: a byte with
  no character in it, or a character with no byte, raises EEncodingError, and
  a rename is not the place to discover that (it did, on the first run of the
  harness that covers this). So those files go through a 1:1
  byte-to-codepoint mapping instead, which cannot fail in either direction
  and reproduces the file exactly. Nothing is lost by not knowing what the
  bytes MEAN: a rename only ever replaces ASCII with ASCII, and in a
  single-byte encoding a column is a byte either way. }
type
  TPasSourceEncoding = (peUtf8Bom, peUtf8, peBytes);

{ The file's text plus the encoding it was stored in, for a caller that is
  about to rewrite it. Same non-raising contract as TryReadTextNoBom, and the
  same BOM rule - AText never contains the preamble.

  UTF-16 is not a case: no answer here can describe it, so a UTF-16 source is
  reported as unreadable rather than silently transcoded to UTF-8. A .pas the
  Delphi IDE wrote is never UTF-16. }
function TryReadSourceForEdit(const APath: string; out AText: string;
  out AEncoding: TPasSourceEncoding): Boolean;

{ AText back to APath in AEncoding - the counterpart of the read above, and
  the only supported way for this product to rewrite a source file. False,
  with the file untouched, if the write fails.

  The write is atomic in the sense that matters here: the bytes are built
  first and handed to one call, so a failure cannot leave a half-written
  source. What it is NOT is undoable, which is why the only caller (a rename
  reaching a file nobody has open) tells the user which files it changed. }
function TryWriteSource(const APath, AText: string;
  AEncoding: TPasSourceEncoding): Boolean;

implementation

{ THE BYTE CONTAINER, and it is hand-rolled on purpose: not one line of it
  consults a code page, so not one line of it can raise EEncodingError. Every
  byte becomes the codepoint of the same value and back again - the identity
  mapping, which is the only property the caller needs (see
  TPasSourceEncoding). Reaching for TEncoding here instead is what the first
  version did, and the harness's ANSI case failed on exactly the mapping
  question this avoids having. }
function StringOfBytes(const ABytes: TBytes): string;
var
  LIdx: Integer;
begin
  SetLength(Result, Length(ABytes));
  for LIdx := 0 to High(ABytes) do
    Result[LIdx + 1] := Char(ABytes[LIdx]);
end;

{ The inverse. A codepoint above 255 cannot have come from StringOfBytes, so
  it can only be text the caller inserted - and a rename inserts an
  identifier, which is ASCII. Truncated rather than refused: the alternative
  is failing a write for a character the caller could not have put there. }
function BytesOfString(const AText: string): TBytes;
var
  LIdx: Integer;
begin
  SetLength(Result, Length(AText));
  for LIdx := 1 to Length(AText) do
    Result[LIdx - 1] := Byte(Ord(AText[LIdx]));
end;

function StripLeadingBom(const AText: string): string;
begin
  if (AText <> '') and (AText[1] = #$FEFF) then
    Result := Copy(AText, 2, MaxInt)
  else
    Result := AText;
end;

function TryReadTextNoBom(const APath: string; out AText: string): Boolean;
var
  LEncoding: TPasSourceEncoding;
begin
  { ONE DETECTION FOR THE WHOLE UNIT, and it is TryReadSourceForEdit's.
    TFile.ReadAllText - which this used to call - falls back to
    TEncoding.Default (the ANSI code page) for a file with no preamble, while
    PasTree since 0.2.3 decodes preamble-less valid UTF-8 AS UTF-8. That
    disagreement is the bug fixed at the root on 2026-08-20, and reading it
    back in here reintroduced it for every file the editor does NOT have open:
    a .pas with a Cyrillic comment or literal decoded into a DIFFERENT string
    than the analysis holds, so every column after the non-ASCII text was
    shifted and the text itself was mojibake. The encoding is of no interest
    to a reader; the agreement is. }
  AText := '';
  Result := TryReadSourceForEdit(APath, AText, LEncoding);
  if Result then
    // Belt and braces: the read above already drops a preamble, this covers
    // what it cannot see - a second BOM, or a decode that kept the first.
    AText := StripLeadingBom(AText)
  else
    AText := '';
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

// Byte-for-byte, and length first: the only comparison a round-trip test can
// be built on.
function BytesEqual(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) then
    Result := CompareMem(@A[0], @B[0], Length(A));
end;

function TryReadSourceForEdit(const APath: string; out AText: string;
  out AEncoding: TPasSourceEncoding): Boolean;
var
  LBytes: TBytes;
begin
  AText := '';
  AEncoding := peUtf8Bom;
  try
    if not TFile.Exists(APath) then
      Exit(False);
    LBytes := TFile.ReadAllBytes(APath);
  except
    Exit(False);
  end;
  if (Length(LBytes) >= 3) and (LBytes[0] = $EF) and (LBytes[1] = $BB) and
     (LBytes[2] = $BF) then
  begin
    AEncoding := peUtf8Bom;
    try
      AText := TEncoding.UTF8.GetString(LBytes, 3, Length(LBytes) - 3);
    except
      Exit(False);
    end;
    Exit(True);
  end;
  // A UTF-16 preamble: no encoding this unit can write back, so it is
  // reported as unreadable rather than transcoded behind the user.
  if (Length(LBytes) >= 2) and
     (((LBytes[0] = $FF) and (LBytes[1] = $FE)) or
      ((LBytes[0] = $FE) and (LBytes[1] = $FF))) then
    Exit(False);
  { UTF-8 FIRST, TESTED BY ROUND TRIP - AND UNDER A try, because the RTL is
    inconsistent about which half of the question it answers. Depending on
    the version, TEncoding.UTF8 either raises EEncodingError on an invalid
    sequence or substitutes U+FFFD and says nothing; this build raises (the
    harness's non-UTF-8 case found that the hard way). Neither behaviour can
    be relied on, so both are handled: an exception means "not UTF-8", and so
    does a decode whose re-encoding is not the original bytes.

    Round-tripping is the question that actually matters here anyway: these
    bytes ARE this text in UTF-8, so writing the text back reproduces the
    file exactly. }
  try
    AText := TEncoding.UTF8.GetString(LBytes);
    if BytesEqual(TEncoding.UTF8.GetBytes(AText), LBytes) then
    begin
      AEncoding := peUtf8;
      Exit(True);
    end;
  except
    // Not UTF-8, said by exception rather than by mismatch.
  end;
  // Not UTF-8: the byte-preserving path, for the reason the type documents.
  AText := StringOfBytes(LBytes);
  AEncoding := peBytes;
  Result := True;
end;

function TryWriteSource(const APath, AText: string;
  AEncoding: TPasSourceEncoding): Boolean;
var
  LBytes, LBody: TBytes;
begin
  try
    case AEncoding of
      peUtf8Bom:
        begin
          LBody := TEncoding.UTF8.GetBytes(AText);
          SetLength(LBytes, Length(LBody) + 3);
          LBytes[0] := $EF;
          LBytes[1] := $BB;
          LBytes[2] := $BF;
          if Length(LBody) > 0 then
            Move(LBody[0], LBytes[3], Length(LBody));
        end;
      peBytes:
        LBytes := BytesOfString(AText);
    else
      LBytes := TEncoding.UTF8.GetBytes(AText);
    end;
    TFile.WriteAllBytes(APath, LBytes);
    Result := True;
  except
    Result := False;
  end;
end;

end.
