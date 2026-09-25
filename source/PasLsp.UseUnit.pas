unit PasLsp.UseUnit;

(*
  Use Unit: one unit name written into a `uses` clause of the live buffer -
  the server half of the RAD Studio client's Alt+F11 (and of any client that
  wants the same). Also the reading that goes with it: which units the file
  already uses, so a picker can leave them out.

  WHY THE SERVER WRITES THE TEXT, not the client. The client is a 32-bit
  package without a parser; it would have to find the clause, its `;`, a
  conditional block around the last item and the section keyword by
  scanning characters, and every one of those has a case a scanner gets
  wrong. The tree knows all of them. The client applies the one edit through
  an undoable writer, as it does for class completion and Annotate.

  WHERE THE NAME GOES: right in front of the clause's closing `;`. Not after
  the last item - the last item can sit inside `{$IFDEF X}, C{$ENDIF}`, and a
  name appended to it would be compiled only when X is defined. In front of
  the `;` it is outside every such block, whatever the list looks like.

  THE LAYOUT, kept deliberately small:
  - `, Name` on the `;` line when the line stays within the right margin;
  - otherwise `,` + a line break + the new name on a line of its own, indented
    like the line the last item starts on (or one indent step past `uses`
    when the whole clause is one line);
  - a section with no clause gets one, after its keyword: a blank line,
    `uses`, the name on the next line one indent step in.
  The line break is the file's own - CRLF unless the text has only LF.

  REFUSALS, each naming itself (the client shows the reason): a package
  (`requires`/`contains` is not a uses clause), a name already used in either
  section (with or without a unit-scope prefix - `Classes` and
  `System.Classes` are the same unit to this check), the file's own name, a
  clause the parser had to repair (the user is typing in it - a position
  computed from a guessed tree lands in the wrong place), a clause with no
  closing `;`, and a clause or section keyword inside an $I include (not the
  buffer the edit is for).

  Everything here is a pure function of the TREE and the text - no project,
  no analysis, no I/O - so the answer is about the buffer as it is now, the
  same rule class completion and Annotate follow.
*)

interface

uses
  PasTree.Ast;

type
  { One item of one clause. Section is 'interface', 'implementation' or
    'program' (a program's or library's single clause). InPath is the
    `in '...'` string without its quotes, '' when absent. }
  TLspUsesItem = record
    Name: string;
    InPath: string;
    Section: string;
  end;

  { What the file is and what it uses. Kind is 'unit', 'program', 'library',
    'package' or '' (nothing parsed). }
  TLspUsesInfo = record
    Kind: string;
    SelfName: string;
    Items: TArray<TLspUsesItem>;
  end;

  { The one edit, in 1-based PasTree coordinates; an insertion, so the end is
    the start. Text = '' means refused, and Provider says why. Section is
    where the name went. }
  TLspUseUnitAnswer = record
    Line: Integer;
    Col: Integer;
    Text: string;
    Section: string;
    Provider: string;
  end;

function ReadUsesInfo(const ATree: TPasTree): TLspUsesInfo;

{ True when AName and an item name denote the same unit for the purpose of
  "already used": equal, or one is the other behind a unit-scope prefix
  (`Classes` / `System.Classes`). }
function SameUnitName(const AName, AOther: string): Boolean;

{ The edit that adds AUnitName to the file's uses. AImplementation picks the
  unit's implementation clause (ignored for a program/library). AIndent is
  one indent step (the IDE's block indent); ARightMargin the column past
  which a line should not grow. }
function UseUnitEdit(const ATree: TPasTree; const AText, AUnitName: string;
  AImplementation: Boolean; const AIndent: string;
  ARightMargin: Integer): TLspUseUnitAnswer;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  PasTree.Types,
  PasTree.Preprocessor,
  PasLsp.ClassComplete;

const
  cProvider = 'pastree/useUnit';

{ The dotted name under a qualified-name node, as written, whitespace and
  comments dropped. }
function NameTextOf(const ATree: TPasTree; ANode: Integer): string;
var
  LFirst, LLast, LIdx: Integer;
  LPart: string;
begin
  Result := '';
  if not ATree.NodeVisRange(ANode, LFirst, LLast) then
    Exit;
  for LIdx := LFirst to LLast do
  begin
    LPart := Trim(RawSpan(ATree, LIdx, LIdx));
    if StartsText('{', LPart) or StartsText('(*', LPart) or
       StartsText('//', LPart) then
      Continue;
    Result := Result + LPart;
  end;
end;

function StrLitText(const ATree: TPasTree; ANode: Integer): string;
begin
  Result := RawSpan(ATree, ATree.Nodes[ANode].FirstToken,
    ATree.Nodes[ANode].FirstToken);
  if (Length(Result) >= 2) and (Result[1] = '''') and
     (Result[Length(Result)] = '''') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

procedure AddClause(const ATree: TPasTree; AClause: Integer;
  const ASection: string; var AInfo: TLspUsesInfo);
var
  LItem, LChild: Integer;
  LEntry: TLspUsesItem;
begin
  if AClause = NIL_NODE then
    Exit;
  LItem := ATree.Nodes[AClause].FirstChild;
  while LItem <> NIL_NODE do
  begin
    if ATree.Nodes[LItem].Kind = nkUsesItem then
    begin
      LEntry := Default(TLspUsesItem);
      LEntry.Section := ASection;
      LChild := ATree.Nodes[LItem].FirstChild;
      if LChild <> NIL_NODE then
      begin
        LEntry.Name := NameTextOf(ATree, LChild);
        LChild := ATree.Nodes[LChild].NextSibling;
        if (LChild <> NIL_NODE) and (ATree.Nodes[LChild].Kind = nkStrLit) then
          LEntry.InPath := StrLitText(ATree, LChild);
      end;
      if LEntry.Name <> '' then
        AInfo.Items := AInfo.Items + [LEntry];
    end;
    LItem := ATree.Nodes[LItem].NextSibling;
  end;
end;

function ReadUsesInfo(const ATree: TPasTree): TLspUsesInfo;
var
  LRoot, LName, LSec: Integer;
begin
  Result := Default(TLspUsesInfo);
  if Length(ATree.Nodes) = 0 then
    Exit;
  LRoot := 0;
  case ATree.Nodes[LRoot].Kind of
    nkUnit: Result.Kind := 'unit';
    nkProgram: Result.Kind := 'program';
    nkLibrary: Result.Kind := 'library';
    nkPackage: Result.Kind := 'package';
  else
    Exit;
  end;
  LName := ATree.Nodes[LRoot].FirstChild;
  if LName <> NIL_NODE then
    Result.SelfName := NameTextOf(ATree, LName);
  if Result.Kind = 'unit' then
  begin
    LSec := ChildOfKind(ATree, LRoot, nkInterfaceSec);
    if LSec <> NIL_NODE then
      AddClause(ATree, ChildOfKind(ATree, LSec, nkUsesClause), 'interface',
        Result);
    LSec := ChildOfKind(ATree, LRoot, nkImplementationSec);
    if LSec <> NIL_NODE then
      AddClause(ATree, ChildOfKind(ATree, LSec, nkUsesClause),
        'implementation', Result);
  end
  else if Result.Kind <> 'package' then
    AddClause(ATree, ChildOfKind(ATree, LRoot, nkUsesClause), 'program',
      Result);
end;

function SameUnitName(const AName, AOther: string): Boolean;
begin
  Result := SameText(AName, AOther) or
    EndsText('.' + AName, AOther) or EndsText('.' + AOther, AName);
end;

{ The file's line break: CRLF unless the text has LF and no CRLF. }
function LineBreakOf(const AText: string): string;
begin
  if (Pos(#13#10, AText) = 0) and (Pos(#10, AText) > 0) then
    Result := #10
  else
    Result := #13#10;
end;

{ Start (or end) of a visible token in the MAIN file; False for a token in an
  $I include or out of range. }
function MainTokenPos(const ATree: TPasTree; AVisIdx: Integer; AEnd: Boolean;
  out ALine, ACol: Integer): Boolean;
var
  LVis: TPasVisibleToken;
begin
  Result := False;
  ALine := 0;
  ACol := 0;
  if (AVisIdx < 0) or (AVisIdx > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVisIdx];
  if LVis.FileId <> 0 then
    Exit;
  with ATree.Source.Files[0] do
    if AEnd then
      OffsetToLineCol(Tokens[LVis.TokenIndex].EndPos, ALine, ACol)
    else
      OffsetToLineCol(Tokens[LVis.TokenIndex].Start, ALine, ACol);
  Result := True;
end;

function MainLineText(const ATree: TPasTree; ALine: Integer): string;
begin
  Result := ATree.Source.Files[0].LineText(ALine);
end;

function LeadingBlanks(const ALine: string): string;
var
  LIdx: Integer;
begin
  Result := '';
  for LIdx := 1 to Length(ALine) do
    if CharInSet(ALine[LIdx], [' ', #9]) then
      Result := Result + ALine[LIdx]
    else
      Break;
end;

function Refused(const AReason: string): TLspUseUnitAnswer;
begin
  Result := Default(TLspUseUnitAnswer);
  Result.Provider := cProvider + ': ' + AReason;
end;

{ `, Name` in front of the clause's `;`, or the name on a line of its own. }
function AppendToClause(const ATree: TPasTree; AClause: Integer;
  const AUnitName, AIndent, ABreak: string;
  ARightMargin: Integer): TLspUseUnitAnswer;
var
  LSemi, LLine, LCol, LItem, LLastItem, LItemLine, LItemCol: Integer;
  LUsesLine, LUsesCol: Integer;
  LLineText, LIndent: string;
begin
  Result := Default(TLspUseUnitAnswer);
  if nfError in ATree.Nodes[AClause].Flags then
    Exit(Refused('the uses clause does not parse - finish the edit in it '
      + 'first'));
  LSemi := ATree.Nodes[AClause].LastToken;
  if RawSpan(ATree, LSemi, LSemi) <> ';' then
    Exit(Refused('the uses clause has no closing ";"'));
  if not MainTokenPos(ATree, LSemi, False, LLine, LCol) or
     not MainTokenPos(ATree, ATree.Nodes[AClause].FirstToken, False,
       LUsesLine, LUsesCol) then
    Exit(Refused('the uses clause is in an include file'));
  LLineText := MainLineText(ATree, LLine);
  Result.Line := LLine;
  Result.Col := LCol;
  if (ARightMargin <= 0) or
     (Length(LLineText) + Length(', ' + AUnitName) <= ARightMargin) then
  begin
    Result.Text := ', ' + AUnitName;
    Exit;
  end;
  // Too long: the name on a line of its own, indented like the line the
  // last item starts on - unless that line is the `uses` line itself (a
  // one-line clause), where one step past `uses` is the only sensible guess.
  LLastItem := NIL_NODE;
  LItem := ATree.Nodes[AClause].FirstChild;
  while LItem <> NIL_NODE do
  begin
    if ATree.Nodes[LItem].Kind = nkUsesItem then
      LLastItem := LItem;
    LItem := ATree.Nodes[LItem].NextSibling;
  end;
  LIndent := LeadingBlanks(MainLineText(ATree, LUsesLine)) + AIndent;
  if (LLastItem <> NIL_NODE) and
     MainTokenPos(ATree, ATree.NodeLeftmostVis(LLastItem), False,
       LItemLine, LItemCol) and (LItemLine <> LUsesLine) then
    LIndent := LeadingBlanks(MainLineText(ATree, LItemLine));
  Result.Text := ',' + ABreak + LIndent + AUnitName;
end;

{ A new clause right after AKeywordVis: a blank line, `uses`, the name. }
function NewClauseAfter(const ATree: TPasTree; AKeywordVis: Integer;
  const AUnitName, AIndent, ABreak: string): TLspUseUnitAnswer;
var
  LLine, LCol: Integer;
  LBase: string;
begin
  Result := Default(TLspUseUnitAnswer);
  if not MainTokenPos(ATree, AKeywordVis, True, LLine, LCol) then
    Exit(Refused('the section header is in an include file'));
  LBase := LeadingBlanks(MainLineText(ATree, LLine));
  Result.Line := LLine;
  Result.Col := LCol;
  Result.Text := ABreak + ABreak + LBase + 'uses' + ABreak + LBase + AIndent
    + AUnitName + ';';
end;

function UseUnitEdit(const ATree: TPasTree; const AText, AUnitName: string;
  AImplementation: Boolean; const AIndent: string;
  ARightMargin: Integer): TLspUseUnitAnswer;
var
  LInfo: TLspUsesInfo;
  LItem: TLspUsesItem;
  LRoot, LSec, LClause, LVis: Integer;
  LBreak, LSection, LKeyword: string;
begin
  LInfo := ReadUsesInfo(ATree);
  if Trim(AUnitName) = '' then
    Exit(Refused('no unit name'));
  if LInfo.Kind = '' then
    Exit(Refused('not a unit, program or library'));
  if LInfo.Kind = 'package' then
    Exit(Refused('a package has requires/contains, not a uses clause'));
  if SameText(LInfo.SelfName, AUnitName) then
    Exit(Refused(AUnitName + ' is this file itself'));
  for LItem in LInfo.Items do
    if SameUnitName(LItem.Name, AUnitName) then
      Exit(Refused(Format('%s is already in the %s uses clause',
        [LItem.Name, LItem.Section])));

  LBreak := LineBreakOf(AText);
  LRoot := 0;
  if LInfo.Kind = 'unit' then
  begin
    if AImplementation then
    begin
      LSection := 'implementation';
      LSec := ChildOfKind(ATree, LRoot, nkImplementationSec);
    end
    else
    begin
      LSection := 'interface';
      LSec := ChildOfKind(ATree, LRoot, nkInterfaceSec);
    end;
    if LSec = NIL_NODE then
      Exit(Refused('the unit has no ' + LSection + ' section'));
    LClause := ChildOfKind(ATree, LSec, nkUsesClause);
    if LClause <> NIL_NODE then
      Result := AppendToClause(ATree, LClause, AUnitName, AIndent, LBreak,
        ARightMargin)
    else
    begin
      LVis := ATree.Nodes[LSec].FirstToken;
      LKeyword := RawSpan(ATree, LVis, LVis);
      if not SameText(LKeyword, LSection) then
        Exit(Refused('the ' + LSection + ' keyword is not where the parser '
          + 'expected it'));
      Result := NewClauseAfter(ATree, LVis, AUnitName, AIndent, LBreak);
    end;
  end
  else
  begin
    LSection := 'program';
    LClause := ChildOfKind(ATree, LRoot, nkUsesClause);
    if LClause <> NIL_NODE then
      Result := AppendToClause(ATree, LClause, AUnitName, AIndent, LBreak,
        ARightMargin)
    else
    begin
      // After the header's `;` - `program X;` or `program X(Input, Output);`.
      if ATree.Nodes[LRoot].FirstChild = NIL_NODE then
        Exit(Refused('the ' + LInfo.Kind + ' has no name'));
      LVis := ATree.Nodes[ATree.Nodes[LRoot].FirstChild].LastToken + 1;
      while (LVis <= High(ATree.Source.Visible)) and
            (RawSpan(ATree, LVis, LVis) <> ';') and
            (LVis < ATree.Nodes[ATree.Nodes[LRoot].FirstChild].LastToken + 64) do
        Inc(LVis);
      if RawSpan(ATree, LVis, LVis) <> ';' then
        Exit(Refused('the ' + LInfo.Kind + ' header has no closing ";"'));
      Result := NewClauseAfter(ATree, LVis, AUnitName, AIndent, LBreak);
    end;
  end;
  if Result.Text <> '' then
  begin
    Result.Section := LSection;
    Result.Provider := cProvider;
  end;
end;

end.
