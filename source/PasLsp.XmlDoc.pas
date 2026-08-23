unit PasLsp.XmlDoc;

{
  XMLDoc rendering: a declaration's `///` block as display text, and as the
  HTML the RAD Studio IDE's Help Insight window actually wants.

  PasTree hands out the block RAW - `///` markers stripped, lines joined with
  #10, no XML touched (TPasTree.DeclDocComment; the engine's contract says
  rendering is the host's concern, exactly as with ItemParamsText's whitespace
  collapse). This unit is that host side, once, for every consumer: it parses
  the block ONE way (ParseXmlDoc) and emits it two ways.

  TWO EMITTERS, BECAUSE THERE ARE TWO KINDS OF WINDOW.

  1. `XmlDocDisplayText` - plain display text, blocks separated by blank
     lines, NO markdown emphasis markers anywhere. This is what goes over the
     wire as `completionItem.documentation` and inside hover's markdown card:
     VS Code renders it as markdown, and the RAD client's HoverPlainText
     hands the same string to a plain Delphi hint window, where a
     `**Returns:**` would arrive with the asterisks still in it.

  2. `XmlDocHtml` / `HelpInsightPage` - HTML, because the IDE's Help Insight
     surfaces are HTML surfaces and this is documented, if quietly:
     `IOTACodeInsightSymbolList80.GetSymbolDocumentation` says "Return
     documentation for the symbol, in HTML" (ToolsAPI.pas:8506) and
     `IOTACodeInsightManager90.GetHelpInsightHtml` returns a WideString of
     the same (8864). The shape to imitate is not guesswork either: the IDE
     builds its own Help Insight page by XSL-transforming a `<member>`
     document, and both the stylesheet and its CSS ship in the product -
     `ObjRepos\HelpInsight.xsl` and `ObjRepos\HelpInsight.css`. So
     HelpInsightPage emits what that transform emits: a `maincaption` div
     with the declaration and an `a.codelink` to its source, then the
     summary, then `h4` + `dl` sections for parameters, returns and
     exceptions. Same classes, same order, same `helpinsight:/filelink:`
     link scheme - which is why it can look like the native hint rather than
     merely carry the same words.

  WHAT THE PARSER DOES NOT DO. No XML validity anything: a doc comment is
  prose a developer typed, half of them have no tags at all, and a parse
  error must never cost the user the text. Unknown tags are dropped and their
  content kept; text outside any tag joins the summary; an unterminated `<`
  is text. The only structure honored is the tag set Delphi's own Help
  Insight documents (summary, remarks, param, typeparam, returns, value,
  exception, plus the inline see/seealso/paramref/c/code and para/br).

  Length is NOT capped here. A hint window is the display, and clipping text
  the user wrote is a display decision - the same reason the engine does not
  cap ItemParamsText.
}

interface

type
  { One named doc section: a parameter or an exception. }
  TXmlDocEntry = record
    Name: string;
    Text: string;
  end;

  { A parsed `///` block. Every text field is RAW section text (line breaks
    as the author wrote them) - collapsing to one paragraph is an emitter's
    job, because HTML wants no collapse and a hint window does. }
  TXmlDocParts = record
    Summary: string;
    Remarks: string;
    Returns: string;
    Params: TArray<TXmlDocEntry>;
    Exceptions: TArray<TXmlDocEntry>;
    function IsEmpty: Boolean;
  end;

{ The block, parsed. Never raises; an empty/whitespace-only block parses to
  an empty record (IsEmpty). }
function ParseXmlDoc(const ARaw: string): TXmlDocParts;

{ The `///` block as display text, or '' for an empty block. See the unit
  header for the shape and for why it carries no markdown emphasis. }
function XmlDocDisplayText(const ARaw: string): string;

{ The block as an HTML fragment - the sections only, no page around them.
  '' for an empty block. }
function XmlDocHtml(const ARaw: string): string;

{ A whole Help Insight page for one declaration, in the shape the IDE's own
  HelpInsight.xsl produces: the caption line (declaration text, then a
  codelink reading `<file> (<line>)`) followed by XmlDocHtml's sections. The
  link is only emitted when AFilePath is given; ALine/ACol are 1-based, as
  everywhere on the PasTree side. }
function HelpInsightPage(const ADeclaration, AFilePath, AFileShort: string;
  ALine, ACol: Integer; const ARawDoc: string): string;

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

function TXmlDocParts.IsEmpty: Boolean;
begin
  Result := (Summary = '') and (Remarks = '') and (Returns = '') and
    (Length(Params) = 0) and (Length(Exceptions) = 0);
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

{ Back to HTML text: the four characters that would otherwise be markup. The
  parser unescaped the source's entities so both emitters see real text; the
  HTML one has to put them back. }
function HtmlEscape(const AText: string): string;
begin
  Result := AText.Replace('&', '&amp;', [rfReplaceAll])
                 .Replace('<', '&lt;', [rfReplaceAll])
                 .Replace('>', '&gt;', [rfReplaceAll])
                 .Replace('"', '&quot;', [rfReplaceAll]);
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

function ParseXmlDoc(const ARaw: string): TXmlDocParts;
var
  LParts: TXmlDocParts;
  LTarget: TDocTarget;
  LIdx, LClose: Integer;
  LTagBody, LTagName, LName: string;
  LClosing: Boolean;
  LEntry: TXmlDocEntry;

  procedure AddText(const AText: string);
  begin
    if AText = '' then
      Exit;
    case LTarget of
      dtLead, dtSummary: LParts.Summary := LParts.Summary + AText;
      dtRemarks:         LParts.Remarks := LParts.Remarks + AText;
      dtReturns:         LParts.Returns := LParts.Returns + AText;
      dtParam:
        if Length(LParts.Params) > 0 then
          LParts.Params[High(LParts.Params)].Text :=
            LParts.Params[High(LParts.Params)].Text + AText;
      dtException:
        if Length(LParts.Exceptions) > 0 then
          LParts.Exceptions[High(LParts.Exceptions)].Text :=
            LParts.Exceptions[High(LParts.Exceptions)].Text + AText;
    end;
  end;

begin
  LParts := Default(TXmlDocParts);
  if Trim(ARaw) = '' then
    Exit(LParts);
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
      LParts.Params := LParts.Params + [LEntry];
      LTarget := dtParam;
    end
    else if LTagName = 'exception' then
    begin
      LEntry.Name := AttrValue(LTagBody, 'cref');
      LEntry.Text := '';
      LParts.Exceptions := LParts.Exceptions + [LEntry];
      LTarget := dtException;
    end;
    // Everything else - <c>, <code>, <list>, <item>, an unknown tag - keeps
    // its CONTENT in the current section and contributes no structure.
  end;
  Result := LParts;
end;

{ 'AName - the text', or just whichever of the two exists. Shared by both
  emitters so a nameless <param> cannot read as ' - text' in one and
  something else in the other. }
function EntryLine(const AEntry: TXmlDocEntry): string;
begin
  Result := CollapseWs(AEntry.Text);
  if AEntry.Name = '' then
    Exit;
  if Result <> '' then
    Result := AEntry.Name + ' - ' + Result
  else
    Result := AEntry.Name;
end;

function XmlDocDisplayText(const ARaw: string): string;
var
  LParts: TXmlDocParts;
  LOut: TStringBuilder;
  LIdx: Integer;
  LLine: string;

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
  LParts := ParseXmlDoc(ARaw);
  if LParts.IsEmpty then
    Exit;
  LOut := TStringBuilder.Create;
  try
    AddBlock(CollapseWs(LParts.Summary));
    AddBlock(CollapseWs(LParts.Remarks));
    if Length(LParts.Params) > 0 then
    begin
      if LOut.Length > 0 then
        LOut.Append(#10#10);
      LOut.Append('Parameters:');
      for LIdx := 0 to High(LParts.Params) do
      begin
        LLine := EntryLine(LParts.Params[LIdx]);
        if LLine <> '' then
          LOut.Append(#10'- ').Append(LLine);
      end;
    end;
    LLine := CollapseWs(LParts.Returns);
    if LLine <> '' then
      AddBlock('Returns: ' + LLine);
    for LIdx := 0 to High(LParts.Exceptions) do
    begin
      LLine := EntryLine(LParts.Exceptions[LIdx]);
      if LLine <> '' then
        AddBlock('Raises: ' + LLine);
    end;
    Result := LOut.ToString;
  finally
    LOut.Free;
  end;
end;

const
  { The documentation pane of the RAD Studio completion viewer sizes itself to
    the MIN-CONTENT width of the HTML it is given - measured live on
    2026-08-23: the pane came out exactly as wide as the longest word in the
    text ('coordinates'), one or two words per line, and resizing the popup
    changed nothing. So the width has to come from the document, and this is
    it: a wrapper with an explicit width, which the layout cannot collapse.

    420 CSS pixels is about 60 characters at the pane's 9pt font - the width
    prose is comfortable to read at, and close to what the native Help
    Insight window uses. A fixed number is right here rather than a
    percentage: there is no containing box to be a percentage OF. }
  cDocPaneWidthPx = 420;

{ The sections as HelpInsight.xsl emits them: a paragraph per prose section,
  and `h4` + `dl` for the named ones, with the name in the `dt` and its text
  in the `dd`, inside the fixed-width wrapper the pane needs. }
function XmlDocHtml(const ARaw: string): string;
var
  LParts: TXmlDocParts;
  LOut: TStringBuilder;

  procedure AppendDefList(const ACaption: string;
    const AEntries: TArray<TXmlDocEntry>);
  var
    LEntry: Integer;
    LText: string;
  begin
    if Length(AEntries) = 0 then
      Exit;
    LOut.Append('<h4>').Append(ACaption).Append('</h4><p><dl>');
    for LEntry := 0 to High(AEntries) do
    begin
      if AEntries[LEntry].Name <> '' then
        LOut.Append('<dt><b>')
            .Append(HtmlEscape(AEntries[LEntry].Name))
            .Append('</b></dt>');
      LText := CollapseWs(AEntries[LEntry].Text);
      if LText <> '' then
        LOut.Append('<dd>').Append(HtmlEscape(LText)).Append('</dd>');
    end;
    LOut.Append('</dl></p>');
  end;

begin
  Result := '';
  LParts := ParseXmlDoc(ARaw);
  if LParts.IsEmpty then
    Exit;
  LOut := TStringBuilder.Create;
  try
    // Both a table width and a CSS width, deliberately: the pane's renderer
    // is the IDE's own and unidentified, and these are the two ways an HTML
    // layout has ever been told "this wide" - a table attribute for the
    // mshtml-era engine, a style for anything modern. Neither harms the
    // other, and one of them is the one that lands.
    LOut.Append(Format('<table width="%0:d" style="width:%0:dpx">' +
      '<tr><td>', [cDocPaneWidthPx]));
    if CollapseWs(LParts.Summary) <> '' then
      LOut.Append('<p>').Append(HtmlEscape(CollapseWs(LParts.Summary)))
          .Append('</p>');
    if CollapseWs(LParts.Remarks) <> '' then
      LOut.Append('<p>').Append(HtmlEscape(CollapseWs(LParts.Remarks)))
          .Append('</p>');
    AppendDefList('Parameters', LParts.Params);
    if CollapseWs(LParts.Returns) <> '' then
      LOut.Append('<h4>Returns</h4><p>')
          .Append(HtmlEscape(CollapseWs(LParts.Returns))).Append('</p>');
    AppendDefList('Exceptions', LParts.Exceptions);
    LOut.Append('</td></tr></table>');
    Result := LOut.ToString;
  finally
    LOut.Free;
  end;
end;

function HelpInsightPage(const ADeclaration, AFilePath, AFileShort: string;
  ALine, ACol: Integer; const ARawDoc: string): string;
var
  LOut: TStringBuilder;
  LBody: string;
begin
  LOut := TStringBuilder.Create;
  try
    // The head is the IDE's own: a relative stylesheet link to
    // ObjRepos\HelpInsight.css, exactly as HelpInsight.xsl writes it, so the
    // page picks up the IDE's fonts, colours and link styling instead of a
    // second theme of our invention.
    LOut.Append('<html><head>')
        .Append('<link type=''text/css'' rel=''Stylesheet'' ')
        .Append('href=''HelpInsight.css'' />')
        .Append('</head><body><div name="main">');
    LOut.Append('<div class="maincaption">')
        .Append(HtmlEscape(ADeclaration));
    if AFilePath <> '' then
      // The IDE's own link scheme: helpinsight:/filelink:<path>?<line>,<col>.
      // Clicking it navigates the way the native hint's link does.
      LOut.Append(' - <a class="codelink" href="helpinsight:/filelink:')
          .Append(HtmlEscape(AFilePath))
          .Append('?').Append(ALine).Append(',').Append(ACol)
          .Append('">')
          .Append(HtmlEscape(AFileShort))
          .Append(' (').Append(ALine).Append(')</a>');
    LOut.Append('</div>');
    LBody := XmlDocHtml(ARawDoc);
    if LBody <> '' then
      LOut.Append(LBody);
    LOut.Append('</div></body></html>');
    Result := LOut.ToString;
  finally
    LOut.Free;
  end;
end;

end.
