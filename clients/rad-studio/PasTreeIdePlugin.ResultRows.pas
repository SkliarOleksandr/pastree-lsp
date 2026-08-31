unit PasTreeIdePlugin.ResultRows;

{
  Owner-drawn rows for the plugin's result tabs in the Messages panel -
  Find References today; the "PasTree Rename" tab is deliberately the same
  shape and is the natural next adopter.

  Each row is one IOTACustomMessage100 (file/line/column plus navigation -
  double-click, Enter, F8/Shift+F8 all work, INCLUDING on the file header
  rows, which the previous AddToolMessage headers could never navigate
  from) combined with INTACustomDrawMessage (the panel hands us its TCanvas
  and we paint the whole line).

  THE STYLE IS A HYBRID, settled over three live runs with the user:
  the SKELETON is a replica of the IDE's own "Find in Files" results, the
  SNIPPET is painted in the user's live editor syntax colors.

    header:   <full path, bold>  [N]         - the count in IDE blue
    hit:      Name.pas (95):  <raw line>     - name and punctuation in IDE
                                               blue, the line number in IDE
                                               orange, the snippet with its
                                               INDENTATION PRESERVED and
                                               syntax-colored, the match
                                               bold + underlined in its own
                                               syntax color

  Two color sources, on purpose:

  - The accents (blue / orange / green) come from
    INTAIDEUIServices.ThemeAwareColors - the same theme-aware accents the
    IDE paints its panels with, so the dark theme gets its variants free.

  - The snippet colors come from INTACodeEditorServices.Options - FontColor
    and FontStyles per TOTASyntaxCode, the same live palette the code
    editor itself paints with, read at draw time so a Tools > Options >
    Editor color or theme change shows on the next repaint. Nothing cached.

  The match is bold + underline IN THE RUN'S OWN SYNTAX COLOR - the Find
  in Files marker, not a filled one. Two background variants lost to live
  runs first: the editor's "Search match" element is white-on-black by
  default (a black box punched into every row), and any filled rectangle
  repeated down a result list reads as noise.

  The tokenizer below is a DISPLAY tokenizer, one detached line at a time,
  best effort by design: reserved words, identifiers, strings, numbers
  ($ hex, % binary), comments of all three spellings, compiler directives
  (brace-dollar, painted as atPreproc), symbols. It cannot know that its
  line sits inside a multi-line block comment or an asm block - such a
  line degrades to normally-classified text, never to an error. The real
  tokenizer is Win64-only (PasTree, which this Win32 package must never
  link); the keyword list here is a cosmetic copy, not a second semantic
  authority - a missed or extra keyword paints a word in the wrong color
  and nothing else. Directives (private, virtual, name, index...) are
  deliberately NOT in the list: they are only keywords in context, and
  half of them are the most common identifier names in existence -
  coloring every `Name` as a keyword is worse than coloring no directive
  at all.

  Rows are inserted through IOTAMessageServices.AddCustomMessagePtr (a root
  row in a group, returns the Pointer used as Parent) and
  AddCustomMessage(msg, Parent) (a child row) - the custom-message parallel
  of the AddToolMessage Parent/LineRef tree that Find in Files uses.
}

interface

uses
  ToolsAPI;

/// <summary>
/// A file header row: painted as "&lt;full path&gt; [N]" with the path bold -
/// like Find in Files - and, unlike a tool-message header, navigable to the
/// top of the file.
/// </summary>
function NewFileHeaderRow(const AFilePath: string;
  ARefCount: Integer): IOTACustomMessage;

/// <summary>
/// A snippet row: ALine/ACol are the navigation target (1-based). ASnippet
/// is the RAW source line, indentation included - the row paints its own
/// "Name.pas (line): " prefix in front of it. AMatchStart (1-based index
/// into ASnippet) and AMatchLen mark the identifier painted bold+underlined;
/// both 0 means no highlight. ATag, if not empty, is painted in the green
/// accent after the snippet - the "declaration" label.
/// </summary>
function NewSnippetRow(const AFilePath: string; ALine, ACol: Integer;
  const ASnippet: string; AMatchStart, AMatchLen: Integer;
  const ATag: string): IOTACustomMessage;

implementation

uses
  System.SysUtils, System.Types, System.StrUtils, System.UITypes,
  Vcl.Graphics, ToolsAPI.UI, ToolsAPI.Editor;

{ ------------------------------------------------------------------------- }
{ The display tokenizer                                                      }
{ ------------------------------------------------------------------------- }

type
  TTokenRun = record
    Start: Integer; // 1-based index into the line
    Len: Integer;
    Code: TOTASyntaxCode;
  end;

const
  // Reserved words only - see the unit header for why directives are out.
  cReservedWords: array [0 .. 63] of string = ('and', 'array', 'as', 'asm',
    'begin', 'case', 'class', 'const', 'constructor', 'destructor',
    'dispinterface', 'div', 'do', 'downto', 'else', 'end', 'except',
    'exports', 'file', 'finalization', 'finally', 'for', 'function', 'goto',
    'if', 'implementation', 'in', 'inherited', 'initialization', 'inline',
    'interface', 'is', 'label', 'library', 'mod', 'nil', 'not', 'object',
    'of', 'or', 'packed', 'procedure', 'program', 'property', 'raise',
    'record', 'repeat', 'resourcestring', 'set', 'shl', 'shr', 'string',
    'then', 'threadvar', 'to', 'try', 'type', 'unit', 'until', 'uses', 'var',
    'while', 'with', 'xor');

function IsIdentStart(AChar: Char): Boolean; inline;
begin
  Result := CharInSet(AChar, ['A' .. 'Z', 'a' .. 'z', '_']);
end;

function IsIdentChar(AChar: Char): Boolean; inline;
begin
  Result := CharInSet(AChar, ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_']);
end;

function TokenizeLine(const AText: string): TArray<TTokenRun>;
var
  LRuns: TArray<TTokenRun>;
  LCount: Integer;
  LPos, LLen: Integer;

  procedure Add(AStart, ALen: Integer; ACode: TOTASyntaxCode);
  begin
    if ALen <= 0 then
      Exit;
    // Merge with the previous run when contiguous and same-colored - the
    // symbol branch below emits one char at a time and this keeps the run
    // list (and the TextOut count) small.
    if (LCount > 0) and (LRuns[LCount - 1].Code = ACode) and
       (LRuns[LCount - 1].Start + LRuns[LCount - 1].Len = AStart) then
      Inc(LRuns[LCount - 1].Len, ALen)
    else
    begin
      if LCount = Length(LRuns) then
        SetLength(LRuns, LCount * 2 + 8);
      LRuns[LCount].Start := AStart;
      LRuns[LCount].Len := ALen;
      LRuns[LCount].Code := ACode;
      Inc(LCount);
    end;
  end;

  procedure TakeString;
  var
    LStart: Integer;
  begin
    LStart := LPos;
    Inc(LPos); // opening quote
    while LPos <= LLen do
    begin
      if AText[LPos] = '''' then
      begin
        Inc(LPos);
        // A doubled quote is an escaped quote, still inside the literal.
        if (LPos > LLen) or (AText[LPos] <> '''') then
          Break;
      end;
      Inc(LPos);
    end;
    Add(LStart, LPos - LStart, atString);
  end;

  procedure TakeBraceComment;
  var
    LStart: Integer;
    LCode: TOTASyntaxCode;
  begin
    LStart := LPos;
    LCode := atComment;
    if (LPos < LLen) and (AText[LPos + 1] = '$') then
      LCode := atPreproc;
    while (LPos <= LLen) and (AText[LPos] <> '}') do
      Inc(LPos);
    if LPos <= LLen then
      Inc(LPos); // the closing brace
    Add(LStart, LPos - LStart, LCode);
  end;

  procedure TakeParenStarComment;
  var
    LStart: Integer;
    LCode: TOTASyntaxCode;
  begin
    LStart := LPos;
    LCode := atComment;
    if (LPos + 2 <= LLen) and (AText[LPos + 2] = '$') then
      LCode := atPreproc;
    Inc(LPos, 2); // the '(*'
    while (LPos < LLen) and
          not ((AText[LPos] = '*') and (AText[LPos + 1] = ')')) do
      Inc(LPos);
    if LPos < LLen then
      Inc(LPos, 2) // the '*)'
    else
      LPos := LLen + 1;
    Add(LStart, LPos - LStart, LCode);
  end;

  procedure TakeNumber;
  var
    LStart: Integer;
    LCode: TOTASyntaxCode;
  begin
    LStart := LPos;
    LCode := atNumber;
    while (LPos <= LLen) and CharInSet(AText[LPos], ['0' .. '9', '_']) do
      Inc(LPos);
    // A '.' continues the number only when a digit follows: `1..2` is a
    // range, and `1.` at end of expression is a member access on a literal.
    if (LPos < LLen) and (AText[LPos] = '.') and
       CharInSet(AText[LPos + 1], ['0' .. '9']) then
    begin
      LCode := atFloat;
      Inc(LPos);
      while (LPos <= LLen) and CharInSet(AText[LPos], ['0' .. '9', '_']) do
        Inc(LPos);
    end;
    if (LPos <= LLen) and CharInSet(AText[LPos], ['e', 'E']) then
    begin
      LCode := atFloat;
      Inc(LPos);
      if (LPos <= LLen) and CharInSet(AText[LPos], ['+', '-']) then
        Inc(LPos);
      while (LPos <= LLen) and CharInSet(AText[LPos], ['0' .. '9']) do
        Inc(LPos);
    end;
    Add(LStart, LPos - LStart, LCode);
  end;

  procedure TakeIdent;
  var
    LStart: Integer;
  begin
    LStart := LPos;
    while (LPos <= LLen) and IsIdentChar(AText[LPos]) do
      Inc(LPos);
    if MatchText(Copy(AText, LStart, LPos - LStart), cReservedWords) then
      Add(LStart, LPos - LStart, atReservedWord)
    else
      Add(LStart, LPos - LStart, atIdentifier);
  end;

var
  LStart: Integer;
  LChar: Char;
begin
  LRuns := nil;
  LCount := 0;
  LLen := Length(AText);
  LPos := 1;
  while LPos <= LLen do
  begin
    LChar := AText[LPos];
    if CharInSet(LChar, [' ', #9]) then
    begin
      LStart := LPos;
      while (LPos <= LLen) and CharInSet(AText[LPos], [' ', #9]) do
        Inc(LPos);
      Add(LStart, LPos - LStart, atWhiteSpace);
    end
    else if (LChar = '/') and (LPos < LLen) and (AText[LPos + 1] = '/') then
    begin
      Add(LPos, LLen - LPos + 1, atComment);
      Break;
    end
    else if LChar = '{' then
      TakeBraceComment
    else if (LChar = '(') and (LPos < LLen) and (AText[LPos + 1] = '*') then
      TakeParenStarComment
    else if LChar = '''' then
      TakeString
    else if LChar = '#' then
    begin
      // A character literal: #13, #$1B. Painted as a string, which is what
      // the editor does with the whole '...'#13#10 chain anyway.
      LStart := LPos;
      Inc(LPos);
      if (LPos <= LLen) and (AText[LPos] = '$') then
        Inc(LPos);
      while (LPos <= LLen) and
            CharInSet(AText[LPos], ['0' .. '9', 'A' .. 'F', 'a' .. 'f']) do
        Inc(LPos);
      Add(LStart, LPos - LStart, atString);
    end
    else if LChar = '$' then
    begin
      LStart := LPos;
      Inc(LPos);
      while (LPos <= LLen) and
            CharInSet(AText[LPos], ['0' .. '9', 'A' .. 'F', 'a' .. 'f', '_']) do
        Inc(LPos);
      Add(LStart, LPos - LStart, atHex);
    end
    else if LChar = '%' then
    begin
      LStart := LPos;
      Inc(LPos);
      while (LPos <= LLen) and CharInSet(AText[LPos], ['0', '1', '_']) do
        Inc(LPos);
      Add(LStart, LPos - LStart, atBinary);
    end
    else if CharInSet(LChar, ['0' .. '9']) then
      TakeNumber
    else if IsIdentStart(LChar) then
      TakeIdent
    else
    begin
      Add(LPos, 1, atSymbol);
      Inc(LPos);
    end;
  end;
  SetLength(LRuns, LCount);
  Result := LRuns;
end;

{ ------------------------------------------------------------------------- }
{ The palette                                                                }
{ ------------------------------------------------------------------------- }

function TryEditorOptions(out AOptions: INTACodeEditorOptions): Boolean;
var
  LServices: INTACodeEditorServices;
begin
  AOptions := nil;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    AOptions := LServices.Options;
  Result := Assigned(AOptions);
end;

{ ------------------------------------------------------------------------- }
{ The row                                                                    }
{ ------------------------------------------------------------------------- }

type
  TResultRow = class(TInterfacedObject, IOTACustomMessage,
    IOTACustomMessage50, IOTACustomMessage100, INTACustomDrawMessage)
  private
    FFilePath: string;
    FLine: Integer;
    FCol: Integer;
    FText: string;   // header: unused; snippet: the raw line text
    FSuffix: string; // header: ' [N]'; snippet: the tag or ''
    FMatchStart: Integer; // 1-based into FText, 0 = no highlight
    FMatchLen: Integer;
    FIsHeader: Boolean;
    procedure Paint(ACanvas: TCanvas; const ARect: TRect; ADoDraw: Boolean;
      out AWidth: Integer);
  public
    // IOTACustomMessage
    function GetColumnNumber: Integer;
    function GetFileName: string;
    function GetLineNumber: Integer;
    function GetLineText: string;
    procedure ShowHelp;
    // IOTACustomMessage50 - the tree is built through AddCustomMessage's
    // Parent pointers, not through message-owned children.
    function GetChildCount: Integer;
    function GetChild(Index: Integer): IOTACustomMessage50;
    // IOTACustomMessage100
    function CanGotoSource(var DefaultHandling: Boolean): Boolean;
    procedure TrackSource(var DefaultHandling: Boolean);
    procedure GotoSource(var DefaultHandling: Boolean);
    // INTACustomDrawMessage
    procedure Draw(Canvas: TCanvas; const Rect: TRect; Wrap: Boolean);
    function CalcRect(Canvas: TCanvas; MaxWidth: Integer;
      Wrap: Boolean): TRect;
  end;

function TResultRow.GetColumnNumber: Integer;
begin
  Result := FCol;
end;

function TResultRow.GetFileName: string;
begin
  Result := FFilePath;
end;

function TResultRow.GetLineNumber: Integer;
begin
  Result := FLine;
end;

function TResultRow.GetLineText: string;
begin
  // What the panel hands to the clipboard and to F1.
  if FIsHeader then
    Result := FFilePath + FSuffix
  else
    Result := Format('%s (%d): %s%s',
      [ExtractFileName(FFilePath), FLine, FText, FSuffix]);
end;

procedure TResultRow.ShowHelp;
begin
end;

function TResultRow.GetChildCount: Integer;
begin
  Result := 0;
end;

function TResultRow.GetChild(Index: Integer): IOTACustomMessage50;
begin
  Result := nil;
end;

function TResultRow.CanGotoSource(var DefaultHandling: Boolean): Boolean;
begin
  // DefaultHandling = True hands the actual navigation to the IDE, which
  // uses GetFileName/GetLineNumber/GetColumnNumber - the same jump a tool
  // message gets, now also available on header rows.
  DefaultHandling := True;
  Result := FFilePath <> '';
end;

procedure TResultRow.TrackSource(var DefaultHandling: Boolean);
begin
  DefaultHandling := True;
end;

procedure TResultRow.GotoSource(var DefaultHandling: Boolean);
begin
  DefaultHandling := True;
end;

{ One routine for both Draw and CalcRect, because the width IS the layout:
  bold and per-code styles change TextWidth, so measuring with any other
  code path drifts from what gets painted. ADoDraw=False only accumulates
  AWidth.

  The panel prepares the canvas for the row - highlight brush and font on
  the selected row - so the row is filled with THAT brush first and the
  prepared font color is the fallback wherever the accents and the palette
  have no say. Colors stay on the selected row, exactly like the editor's
  own selection and the native Find in Files rows (see also
  PasTreeIdePlugin.CodeInsight's draw comment - the first pass that
  flattened colors on selection read as the coloring "disappearing"). }
procedure TResultRow.Paint(ACanvas: TCanvas; const ARect: TRect;
  ADoDraw: Boolean; out AWidth: Integer);
const
  cPad = 2;
var
  LOptions: INTACodeEditorOptions;
  LHavePalette: Boolean;
  LBaseColor: TColor;
  LBaseStyle: TFontStyles;
  LBlue, LOrange, LGreen: TColor;
  LTop, LX: Integer;

  procedure Put(const ARun: string; AColor: TColor; AStyle: TFontStyles);
  begin
    if ARun = '' then
      Exit;
    ACanvas.Font.Style := AStyle;
    if ADoDraw then
    begin
      ACanvas.Font.Color := AColor;
      ACanvas.TextOut(LX, LTop, ARun);
    end;
    Inc(LX, ACanvas.TextWidth(ARun));
  end;

  procedure PutSnippet;
  var
    LRuns: TArray<TTokenRun>;
    LRun: TTokenRun;
    LColor: TColor;
    LStyle: TFontStyles;
    LFrom, LTake, LCut: Integer;
    LInMatch: Boolean;
  begin
    LRuns := TokenizeLine(FText);
    for LRun in LRuns do
    begin
      LColor := LBaseColor;
      LStyle := LBaseStyle;
      if LHavePalette then
      begin
        LColor := LOptions.FontColor[LRun.Code];
        LStyle := LOptions.FontStyles[LRun.Code];
      end;
      // Split the run where it crosses the match boundary, so the marker
      // lands on exactly the identifier and nothing else.
      LFrom := LRun.Start;
      while LFrom < LRun.Start + LRun.Len do
      begin
        LTake := LRun.Start + LRun.Len - LFrom;
        LInMatch := (FMatchLen > 0) and (LFrom >= FMatchStart) and
          (LFrom < FMatchStart + FMatchLen);
        if LInMatch then
          LCut := FMatchStart + FMatchLen - LFrom
        else if (FMatchLen > 0) and (LFrom < FMatchStart) then
          LCut := FMatchStart - LFrom
        else
          LCut := LTake;
        if LCut < LTake then
          LTake := LCut;
        if LInMatch then
          // The Find in Files marker - bold + underline - in the run's own
          // syntax color. See the unit header for the two rejected
          // background variants.
          Put(Copy(FText, LFrom, LTake), LColor,
            LStyle + [TFontStyle.fsBold, TFontStyle.fsUnderline])
        else
          Put(Copy(FText, LFrom, LTake), LColor, LStyle);
        Inc(LFrom, LTake);
      end;
    end;
  end;

var
  LUI: INTAIDEUIServices;
begin
  LHavePalette := TryEditorOptions(LOptions);
  LBaseColor := ACanvas.Font.Color;
  LBaseStyle := ACanvas.Font.Style;
  LBlue := LBaseColor;
  LOrange := LBaseColor;
  LGreen := LBaseColor;
  if Supports(BorlandIDEServices, INTAIDEUIServices, LUI) then
  begin
    LBlue := LUI.ThemeAwareColors[itcBlue];
    LOrange := LUI.ThemeAwareColors[itcOrange];
    LGreen := LUI.ThemeAwareColors[itcGreen];
  end;
  LTop := ARect.Top + (ARect.Height - ACanvas.TextHeight('Ag')) div 2;
  LX := ARect.Left + cPad;

  if ADoDraw then
  begin
    // The brush arrives prepared (selection highlight included). TextOut
    // paints with it too, which is what keeps the selection bar visible
    // behind the text - no bsClear here.
    ACanvas.FillRect(ARect);
  end;

  if FIsHeader then
  begin
    // Find in Files: the full path bold in the panel's text color, the
    // count in the blue accent - "C:\...\Unit.pas [13]".
    Put(FFilePath, LBaseColor, LBaseStyle + [TFontStyle.fsBold]);
    Put(FSuffix, LBlue, LBaseStyle + [TFontStyle.fsBold]);
  end
  else
  begin
    // Find in Files: "Name.pas (95): " with the name and punctuation in
    // the blue accent and the number in the orange one - then the raw
    // line, syntax-colored, which is where the hybrid departs.
    Put(ExtractFileName(FFilePath) + ' (', LBlue, LBaseStyle);
    Put(IntToStr(FLine), LOrange, LBaseStyle);
    Put('): ', LBlue, LBaseStyle);
    PutSnippet;
    Put(FSuffix, LGreen, LBaseStyle);
  end;

  // Leave the canvas the way the panel prepared it.
  ACanvas.Font.Color := LBaseColor;
  ACanvas.Font.Style := LBaseStyle;
  AWidth := LX + cPad - ARect.Left;
end;

procedure TResultRow.Draw(Canvas: TCanvas; const Rect: TRect; Wrap: Boolean);
var
  LWidth: Integer;
begin
  Paint(Canvas, Rect, True, LWidth);
end;

function TResultRow.CalcRect(Canvas: TCanvas; MaxWidth: Integer;
  Wrap: Boolean): TRect;
var
  LWidth: Integer;
begin
  Result := TRect.Create(0, 0, 0, Canvas.TextHeight('Ag') + 2);
  Paint(Canvas, Result, False, LWidth);
  Result.Right := LWidth;
end;

{ ------------------------------------------------------------------------- }
{ Construction                                                               }
{ ------------------------------------------------------------------------- }

function NewFileHeaderRow(const AFilePath: string;
  ARefCount: Integer): IOTACustomMessage;
var
  LRow: TResultRow;
begin
  LRow := TResultRow.Create;
  LRow.FFilePath := AFilePath;
  LRow.FLine := 1;
  LRow.FCol := 1;
  LRow.FSuffix := Format(' [%d]', [ARefCount]);
  LRow.FIsHeader := True;
  Result := LRow;
end;

function NewSnippetRow(const AFilePath: string; ALine, ACol: Integer;
  const ASnippet: string; AMatchStart, AMatchLen: Integer;
  const ATag: string): IOTACustomMessage;
var
  LRow: TResultRow;
begin
  LRow := TResultRow.Create;
  LRow.FFilePath := AFilePath;
  LRow.FLine := ALine;
  LRow.FCol := ACol;
  // TextOut does not expand tabs - it paints them as boxes. Tabs become
  // single spaces, 1:1, so the match offsets keep meaning what they meant;
  // a tab-indented line ends up narrower than in the editor, which is what
  // the native Find in Files rows show too.
  LRow.FText := ASnippet.Replace(#9, ' ');
  LRow.FMatchStart := AMatchStart;
  LRow.FMatchLen := AMatchLen;
  if ATag <> '' then
    LRow.FSuffix := '  (' + ATag + ')';
  LRow.FIsHeader := False;
  Result := LRow;
end;

end.
