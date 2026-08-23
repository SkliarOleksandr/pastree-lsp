unit PasLsp.XmlDoc;

{
  XMLDoc rendering: a declaration's `///` block as display text.

  PasTree hands out the block RAW - `///` markers stripped, lines joined with
  #10, no XML touched (TPasTree.DeclDocComment; the engine's contract says
  rendering is the host's concern, exactly as with ItemParamsText's whitespace
  collapse). This unit is that host side, once, for all three consumers:
  hover's markdown card, completionItem.documentation, and - through the RAD
  client, which only ever displays what arrives - the Help Insight window.

  WHAT IT PRODUCES. Blocks in a fixed reading order (summary, remarks,
  parameters, returns, exceptions), separated by BLANK LINES, each block one
  collapsed paragraph or one `- name - text` list line. That shape is chosen
  to survive both readers unchanged:

  - as markdown (VS Code's hover) the blank lines keep the sections apart and
    `- ` lines render as a list;
  - as tooltip plain text the RAD client's HoverPlainText drops empty lines
    and keeps the rest verbatim - so NO markdown emphasis markers are emitted
    anywhere, because `**Returns:**` would reach a Delphi hint window with the
    asterisks still in it.

  WHAT IT DOES NOT DO. No XML validity anything: a doc comment is prose a
  developer typed, half of them have no tags at all, and a parse error must
  never cost the user the text. Unknown tags are dropped and their content
  kept; text outside any tag joins the summary; an unterminated `<` is text.
  The only structure honored is the tag set Delphi's own Help Insight
  documents (summary, remarks, param, typeparam, returns, value, exception,
  plus the inline see/seealso/paramref/c/code and para/br).

  Length is NOT capped here. A hint window is the display, and clipping text
  the user wrote is a display decision - the same reason the engine does not
  cap ItemParamsText.
}

interface

{ The `///` block as display text, or '' for an empty/whitespace-only block.
  See the unit header for the shape and for why it carries no markdown
  emphasis. Never raises. }
function XmlDocDisplayText(const ARaw: string): string;

implementation

uses
  System.SysUtils,
  System.Classes;

type
  { Where the text currently being scanned belongs. dtLead is both "before any
    tag" and "after a section closed" - untagged prose is a summary, which is
    how an undocumented-but-commented declaration still reads well. }
  TDocTarget = (dtLead, dtSummary, dtRemarks, dtReturns, dtParam,
    dtException);

  TDocEntry = record
    Name: string;
    Text: string;
  end;

{ &lt; &gt; &amp; &quot; &apos; and numeric refs. An unknown or malformed
  entity is left exactly as written - it is likelier to be prose about a
  Pascal `&` than a mistyped entity. }
function Unescape(const AText: string): string;
var
  LIdx, LEnd, LCode: Integer;
  LName: string;
begin
  if Pos('&', AText) = 0 then
    Exit(AText);
  Result := '';
  LIdx := 1;
  while LIdx <= Length(AText) do
  begin
    if AText[LIdx] <> '&' then
    begin
      Result := Result + AText[LIdx];
      Inc(LIdx);
      Continue;
    end;
    LEnd := LIdx + 1;
    while (LEnd <= Length(AText)) and (AText[LEnd] <> ';') and
          (LEnd - LIdx <= 10) do
      Inc(LEnd);
    if (LEnd > Length(AText)) or (AText[LEnd] <> ';') then
    begin
      Result := Result + AText[LIdx];
      Inc(LIdx);
      Continue;
    end;
    LName := Copy(AText, LIdx + 1, LEnd - LIdx - 1);
    if SameText(LName, 'lt') then
      Result := Result + '<'
    else if SameText(LName, 'gt') then
      Result := Result + '>'
    else if SameText(LName, 'amp') then
      Result := Result + '&'
    else if SameText(LName, 'quot') then
      Result := Result + '"'
    else if SameText(LName, 'apos') then
      Result := Result + ''''
    else if LName.StartsWith('#') and
            TryStrToInt(Copy(LName, 2, MaxInt), LCode) and
            (LCode > 0) and (LCode <= $FFFF) then
      Result := Result + Char(LCode)
    else
      Result := Result + '&' + LName + ';';
    LIdx := LEnd + 1;
  end;
end;

{ One paragraph out of a section's accumulated text: every whitespace run
  (the #10s DeclDocComment joined the lines with included) becomes one space.
  A doc section is prose written across several `///` lines and must read as
  a sentence, not as the line breaks the author's margin happened to force. }
function CollapseWs(const AText: string): string;
var
  LIdx: Integer;
  LSpace: Boolean;
begin
  Result := '';
  LSpace := False;
  for LIdx := 1 to Length(AText) do
    if CharInSet(AText[LIdx], [#9, #10, #13, ' ']) then
      LSpace := Result <> ''
    else
    begin
      if LSpace then
        Result := Result + ' ';
      LSpace := False;
      Result := Result + AText[LIdx];
    end;
end;

{ An attribute's value inside a tag's raw inner text ('param name="AName"'),
  by attribute name, quoted with either quote character. '' when absent.
  A cref's documentation-comment prefix ('T:', 'M:') is stripped: it is
  compiler-facing, and no reader wants to see it in a hint. }
function AttrValue(const ATagBody, AAttr: string): string;
var
  LPos, LIdx: Integer;
  LQuote: Char;
begin
  Result := '';
  LPos := Pos(LowerCase(AAttr) + '=', LowerCase(ATagBody));
  if LPos = 0 then
    Exit;
  LIdx := LPos + Length(AAttr) + 1;
  while (LIdx <= Length(ATagBody)) and (ATagBody[LIdx] = ' ') do
    Inc(LIdx);
  if (LIdx > Length(ATagBody)) or
     not CharInSet(ATagBody[LIdx], ['"', '''']) then
    Exit;
  LQuote := ATagBody[LIdx];
  Inc(LIdx);
  while (LIdx <= Length(ATagBody)) and (ATagBody[LIdx] <> LQuote) do
  begin
    Result := Result + ATagBody[LIdx];
    Inc(LIdx);
  end;
  Result := Unescape(Result);
  if (Length(Result) > 2) and (Result[2] = ':') and
     CharInSet(Result[1], ['T', 'M', 'P', 'F', 'E', 'N']) then
    Result := Copy(Result, 3, MaxInt);
end;

function XmlDocDisplayText(const ARaw: string): string;
var
  LSummary, LRemarks, LReturns: string;
  LParams, LExceptions: TArray<TDocEntry>;
  LTarget: TDocTarget;
  LIdx, LClose: Integer;
  LTagBody, LTagName, LName, LLine: string;
  LClosing: Boolean;
  LEntry: TDocEntry;
  LOut: TStringBuilder;

  procedure AddText(const AText: string);
  begin
    if AText = '' then
      Exit;
    case LTarget of
      dtLead, dtSummary: LSummary := LSummary + AText;
      dtRemarks:         LRemarks := LRemarks + AText;
      dtReturns:         LReturns := LReturns + AText;
      dtParam:
        if Length(LParams) > 0 then
          LParams[High(LParams)].Text := LParams[High(LParams)].Text + AText;
      dtException:
        if Length(LExceptions) > 0 then
          LExceptions[High(LExceptions)].Text :=
            LExceptions[High(LExceptions)].Text + AText;
    end;
  end;

  procedure AddBlock(const AText: string);
  begin
    if AText = '' then
      Exit;
    if LOut.Length > 0 then
      LOut.Append(#10#10);
    LOut.Append(AText);
  end;

begin
  Result := '';
  if Trim(ARaw) = '' then
    Exit;
  LSummary := '';
  LRemarks := '';
  LReturns := '';
  LParams := nil;
  LExceptions := nil;
  LTarget := dtLead;
  LIdx := 1;
  while LIdx <= Length(ARaw) do
  begin
    if ARaw[LIdx] <> '<' then
    begin
      AddText(ARaw[LIdx]);
      Inc(LIdx);
      Continue;
    end;
    LClose := LIdx + 1;
    while (LClose <= Length(ARaw)) and (ARaw[LClose] <> '>') do
      Inc(LClose);
    // An unterminated '<' is prose (a comparison, a generic in running text).
    if LClose > Length(ARaw) then
    begin
      AddText(Copy(ARaw, LIdx, MaxInt));
      Break;
    end;
    LTagBody := Trim(Copy(ARaw, LIdx + 1, LClose - LIdx - 1));
    LIdx := LClose + 1;
    if LTagBody.EndsWith('/') then
      LTagBody := Trim(Copy(LTagBody, 1, Length(LTagBody) - 1));
    LClosing := LTagBody.StartsWith('/');
    if LClosing then
      LTagBody := Trim(Copy(LTagBody, 2, MaxInt));
    LTagName := LTagBody;
    if Pos(' ', LTagName) > 0 then
      LTagName := Copy(LTagName, 1, Pos(' ', LTagName) - 1);
    LTagName := LowerCase(LTagName);

    // Inline tags: no section of their own, their VALUE is the text.
    if (LTagName = 'see') or (LTagName = 'seealso') then
    begin
      if not LClosing then
      begin
        LName := AttrValue(LTagBody, 'cref');
        if LName = '' then
          LName := AttrValue(LTagBody, 'langword');
        AddText(LName);
      end;
      Continue;
    end;
    if LTagName = 'paramref' then
    begin
      if not LClosing then
        AddText(AttrValue(LTagBody, 'name'));
      Continue;
    end;
    // Structural whitespace: a paragraph or line break inside a section that
    // is rendered as one collapsed paragraph is exactly one space.
    if (LTagName = 'para') or (LTagName = 'br') then
    begin
      AddText(' ');
      Continue;
    end;

    if LClosing then
    begin
      // Any section's end returns to the lead: prose after </summary> with no
      // tag of its own still belongs to the summary paragraph.
      if (LTagName = 'summary') or (LTagName = 'remarks') or
         (LTagName = 'returns') or (LTagName = 'value') or
         (LTagName = 'param') or (LTagName = 'typeparam') or
         (LTagName = 'exception') then
        LTarget := dtLead;
      Continue;
    end;

    if LTagName = 'summary' then
      LTarget := dtSummary
    else if LTagName = 'remarks' then
      LTarget := dtRemarks
    else if (LTagName = 'returns') or (LTagName = 'value') then
      LTarget := dtReturns
    else if (LTagName = 'param') or (LTagName = 'typeparam') then
    begin
      LEntry.Name := AttrValue(LTagBody, 'name');
      LEntry.Text := '';
      LParams := LParams + [LEntry];
      LTarget := dtParam;
    end
    else if LTagName = 'exception' then
    begin
      LEntry.Name := AttrValue(LTagBody, 'cref');
      LEntry.Text := '';
      LExceptions := LExceptions + [LEntry];
      LTarget := dtException;
    end;
    // Everything else - <c>, <code>, <list>, <item>, an unknown tag - keeps
    // its CONTENT in the current section and contributes no structure.
  end;

  LOut := TStringBuilder.Create;
  try
    AddBlock(CollapseWs(LSummary));
    AddBlock(CollapseWs(LRemarks));
    if Length(LParams) > 0 then
    begin
      if LOut.Length > 0 then
        LOut.Append(#10#10);
      LOut.Append('Parameters:');
      for LIdx := 0 to High(LParams) do
      begin
        LLine := CollapseWs(LParams[LIdx].Text);
        if LParams[LIdx].Name <> '' then
        begin
          if LLine <> '' then
            LLine := LParams[LIdx].Name + ' - ' + LLine
          else
            LLine := LParams[LIdx].Name;
        end;
        if LLine <> '' then
          LOut.Append(#10'- ').Append(LLine);
      end;
    end;
    LLine := CollapseWs(LReturns);
    if LLine <> '' then
      AddBlock('Returns: ' + LLine);
    for LIdx := 0 to High(LExceptions) do
    begin
      LLine := CollapseWs(LExceptions[LIdx].Text);
      if LExceptions[LIdx].Name <> '' then
      begin
        if LLine <> '' then
          LLine := LExceptions[LIdx].Name + ' - ' + LLine
        else
          LLine := LExceptions[LIdx].Name;
      end;
      if LLine <> '' then
        AddBlock('Raises: ' + LLine);
    end;
    Result := LOut.ToString;
  finally
    LOut.Free;
  end;
end;

end.
