unit PasLsp.UnusedUnits;

(*
  Removing `uses` entries: the text edits behind the RAD Studio client's
  Unused Units results (Find All > Unused Units, Unused Units in the
  Project, Units Nobody Uses) - which entries to remove is PasTree's
  (PasTree.Sema.Lint); how the clause reads afterwards is this unit's.

  ONE EDIT PER CLAUSE, the whole clause from `uses` to its `;` replaced by
  what is left of it - never one edit per entry. Two entries removed from
  one clause share the commas between them, and edits that each fix up
  their own neighbour's comma overlap; one rewrite of the clause cannot.

  THE REWRITE KEEPS THE LAYOUT. The clause is cut into the text before the
  first entry, one piece per entry (the entry and whatever follows it up to
  its comma - a `{Form1}` comment of a .dpr, an `in '...'` path) and the
  separator in front of each entry (the comma, the line break, the
  indentation). What is left is joined from the kept entries' pieces with
  the separator that stood in front of each kept entry, so a removed entry
  takes its own line with it and no blank line is left behind:

      uses                 uses
        A,          ->       A,
        B,                   C;
        C;

  A clause whose every entry goes is removed whole, with its own line - and
  with a blank line around it when that would leave two blank lines in a
  row.

  A DIRECTIVE IS NEVER DROPPED. Before 0.62.1 any `{$` in a clause refused
  every entry of it - on AVImark (2026-10-06) that was every row of the
  Unused Units tab, `{$IFDEF}`s in `uses` being the norm there. What is
  dropped is now checked instead: the layout cut above when it holds no
  directive, else each removed entry goes with a comma of its own next to
  it - the one after it (`B{$ENDIF},` cannot, `B,` can), or the one before
  it (`A{$IFDEF X}, B{$ENDIF}` loses `, B` and reads `A{$IFDEF X}{$ENDIF}`)
  - and only the entry, its comma and blanks, never a directive, go. A
  conditional left empty stays: it is harmless, and what to do with it is
  the user's.

  REFUSED, and said so per entry rather than guessed at: an entry no comma
  can be taken with without a directive (`A{$IFDEF X}, B{$ENDIF}` removing
  A), a clause every visible entry of which goes while it holds a directive
  (an entry under another define keeps it alive), a clause in an $I include
  (not the file the edit is for), and a clause whose last token is not its
  `;` (the parser repaired it - the user is typing in it).

  A pure function of the tree and its text, like PasLsp.UseUnit.
*)

interface

uses
  PasTree.Ast;

type
  { One clause rewrite, in 1-based PasTree coordinates of the main file:
    [Line:Col, EndLine:EndCol) replaced by NewText. OldText is the text that
    range holds now - what a client verifies before applying, and what
    Revert puts back. }
  TLspUsesRemoval = record
    Line, Col, EndLine, EndCol: Integer;
    OldText, NewText: string;
  end;

  { Why the entry with name node NameNode cannot be removed by an edit. }
  TLspUsesRefusal = record
    NameNode: Integer;
    Reason: string;
  end;

{ The edits that remove the `uses` entries whose name nodes are ANameNodes
  (TPasUsesRef.NameNode), one per clause touched. An entry whose clause
  cannot be rewritten gets no edit and a row in ARefused. }
function UsesRemovalEdits(const ATree: TPasTree;
  const ANameNodes: TArray<Integer>;
  out ARefused: TArray<TLspUsesRefusal>): TArray<TLspUsesRemoval>;

{ The same by NAME, for a tree parsed from the text as it is now (the
  client's Remove, pastree/usesRemoval): every entry of every `uses` clause
  naming one of ANames (PasLsp.UseUnit.SameUnitName - `Forms` matches
  `Vcl.Forms`). ARefused: "Name: why" per entry no edit removes; AMissing:
  the names no clause holds. }
function UsesRemovalByName(const ATree: TPasTree;
  const ANames: TArray<string>; out ARefused: TArray<string>;
  out AMissing: TArray<string>): TArray<TLspUsesRemoval>;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PasTree.Types,
  PasTree.Preprocessor,
  PasLsp.ClassComplete,
  PasLsp.UseUnit;

// The item node a name node belongs to, NIL_NODE when the tree is not the
// shape expected (name -> nkUsesItem -> nkUsesClause).
function ItemOf(const ATree: TPasTree; ANameNode: Integer): Integer;
begin
  Result := NIL_NODE;
  if (ANameNode < 0) or (ANameNode > High(ATree.Nodes)) then
    Exit;
  Result := ANameNode;
  while (Result <> NIL_NODE) and (ATree.Nodes[Result].Kind <> nkUsesItem) do
    Result := ATree.Nodes[Result].Parent;
end;

// Start offset (0-based, main file) of visible token AVis; -1 when it lies
// in an include or out of range.
function TokStart(const ATree: TPasTree; AVis: Integer): Integer;
var
  LVis: TPasVisibleToken;
begin
  Result := -1;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  if LVis.FileId = 0 then
    Result := ATree.Source.Files[0].Tokens[LVis.TokenIndex].Start;
end;

function TokEnd(const ATree: TPasTree; AVis: Integer): Integer;
var
  LVis: TPasVisibleToken;
begin
  Result := -1;
  if (AVis < 0) or (AVis > High(ATree.Source.Visible)) then
    Exit;
  LVis := ATree.Source.Visible[AVis];
  if LVis.FileId = 0 then
    Result := ATree.Source.Files[0].Tokens[LVis.TokenIndex].EndPos;
end;

function IsBlank(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

// Whether the line before the one starting at offset ALineStart (0-based,
// just past a line break) holds only blanks.
function PrevLineBlank(const AText: string; ALineStart: Integer): Boolean;
var
  LAt: Integer;
begin
  Result := False;
  LAt := ALineStart;   // AText[LAt] is the line break ending that line
  if (LAt < 1) or (AText[LAt] <> #10) then
    Exit;
  Dec(LAt);
  if (LAt >= 1) and (AText[LAt] = #13) then
    Dec(LAt);
  while (LAt >= 1) and IsBlank(AText[LAt]) do
    Dec(LAt);
  Result := (LAt = 0) or (AText[LAt] = #10);
end;

// AEnd (0-based, at a line start) moved past the line there when it holds
// only blanks; AEnd itself otherwise.
function BlankLineEnd(const AText: string; AEnd: Integer): Integer;
begin
  Result := AEnd;
  while (Result < Length(AText)) and IsBlank(AText[Result + 1]) do
    Inc(Result);
  if (Result < Length(AText)) and (AText[Result + 1] = #13) then
    Inc(Result);
  if (Result < Length(AText)) and (AText[Result + 1] = #10) then
    Exit(Result + 1);
  Result := AEnd;
end;

// Whether AText[AFrom, ATo) (0-based) holds a compiler directive.
function HasDirective(const AText: string; AFrom, ATo: Integer): Boolean;
var
  LSpan: string;
begin
  LSpan := Copy(AText, AFrom + 1, ATo - AFrom);
  Result := (Pos('{$', LSpan) > 0) or (Pos('(*$', LSpan) > 0);
end;

type
  // A 0-based [Start, Stop) of the clause's text that a removal drops.
  TDropRange = record
    Start, Stop: Integer;
  end;

// One clause: AItems its items in order, ARemove which of them go. Offsets
// are 0-based into AText. False with AReason when it cannot be rewritten.
function RewriteClause(const ATree: TPasTree; AClause: Integer;
  const AItems: TArray<Integer>; const ARemove: TArray<Boolean>;
  out AEdit: TLspUsesRemoval; out AReason: string): Boolean;
var
  LText, LOut: string;
  LStart, LEnd, LIdx, LRunEnd, LAt, LFrom: Integer;
  LS, LE, LC: TArray<Integer>;   // item start; item end; its comma (or `;`)
  LAll: Boolean;
  LLine, LCol: Integer;
  LFile: TPasTokenStream;
  LDrops: TArray<TDropRange>;

  procedure Drop(AFrom, ATo: Integer);
  var
    LRange: TDropRange;
  begin
    LRange.Start := AFrom;
    LRange.Stop := ATo;
    LDrops := LDrops + [LRange];
  end;

  // Item AItem with the comma after it: from its start through that comma
  // and the blanks behind it - its whole line when nothing else is on it.
  function FollowingSpan(AItem: Integer): TDropRange;
  var
    LLineStart: Integer;
  begin
    Result.Start := LS[AItem];
    Result.Stop := LC[AItem] + 1;
    while (Result.Stop < Length(LText)) and IsBlank(LText[Result.Stop + 1]) do
      Inc(Result.Stop);
    LLineStart := Result.Start;
    while (LLineStart > 0) and IsBlank(LText[LLineStart]) do
      Dec(LLineStart);
    if ((LLineStart = 0) or (LText[LLineStart] = #10)) and
       (Result.Stop < Length(LText)) and
       CharInSet(LText[Result.Stop + 1], [#13, #10]) then
    begin
      Result.Start := LLineStart;
      if LText[Result.Stop + 1] = #13 then
        Inc(Result.Stop);
      if (Result.Stop < Length(LText)) and (LText[Result.Stop + 1] = #10) then
        Inc(Result.Stop);
    end;
  end;

  // Item AItem with the comma before it: from that comma to the item's end.
  function PrecedingSpan(AItem: Integer): TDropRange;
  begin
    Result.Start := LC[AItem - 1];
    Result.Stop := LE[AItem];
  end;

  // Items AFrom..ATo of one run, each with a comma of its own next to it -
  // the one after it first - and no span dropping a directive. ACommaFree:
  // the comma before AFrom is still there to take. Depth-first; the spans
  // of a full assignment go to LDrops.
  function AssignCommas(AFrom, ATo: Integer; ACommaFree: Boolean): Boolean;
  var
    LSpan: TDropRange;
    LKeep: Integer;
  begin
    if AFrom > ATo then
      Exit(True);
    LKeep := Length(LDrops);
    if AFrom < High(AItems) then
    begin
      LSpan := FollowingSpan(AFrom);
      if not HasDirective(LText, LSpan.Start, LSpan.Stop) then
      begin
        Drop(LSpan.Start, LSpan.Stop);
        if AssignCommas(AFrom + 1, ATo, False) then
          Exit(True);
        SetLength(LDrops, LKeep);
      end;
    end;
    if ACommaFree and (AFrom > 0) then
    begin
      LSpan := PrecedingSpan(AFrom);
      if not HasDirective(LText, LSpan.Start, LSpan.Stop) then
      begin
        Drop(LSpan.Start, LSpan.Stop);
        if AssignCommas(AFrom + 1, ATo, True) then
          Exit(True);
        SetLength(LDrops, LKeep);
      end;
    end;
    Result := False;
  end;

begin
  Result := False;
  AEdit := Default(TLspUsesRemoval);
  AReason := '';
  LFile := ATree.Source.Files[0];
  LText := LFile.Source;
  LStart := TokStart(ATree, ATree.Nodes[AClause].FirstToken);
  LEnd := TokEnd(ATree, ATree.Nodes[AClause].LastToken);
  if (LStart < 0) or (LEnd < 0) then
  begin
    AReason := 'the uses clause is in an include file';
    Exit;
  end;
  if Copy(LText, LEnd, 1) <> ';' then
  begin
    AReason := 'the uses clause has no closing `;` yet';
    Exit;
  end;
  SetLength(LS, Length(AItems));
  SetLength(LE, Length(AItems));
  SetLength(LC, Length(AItems));
  LAll := True;
  for LIdx := 0 to High(AItems) do
  begin
    LS[LIdx] := TokStart(ATree, ATree.NodeLeftmostVis(AItems[LIdx]));
    LE[LIdx] := TokEnd(ATree, ATree.Nodes[AItems[LIdx]].LastToken);
    // The token after the item: its comma, or the clause's `;`.
    LC[LIdx] := TokStart(ATree, ATree.Nodes[AItems[LIdx]].LastToken + 1);
    if (LS[LIdx] < 0) or (LE[LIdx] < LS[LIdx]) or (LC[LIdx] < LE[LIdx]) then
    begin
      AReason := 'the uses clause is in an include file';
      Exit;
    end;
    LAll := LAll and ARemove[LIdx];
  end;

  if LAll then
  begin
    // Every entry visible here goes - but a directive means the clause holds
    // more than that (an entry under another define), and it cannot go
    // whole.
    if HasDirective(LText, LStart, LEnd) then
    begin
      AReason := 'every entry the compiler sees goes, and the clause holds a ' +
        'compiler directive - remove it by hand';
      Exit;
    end;
    // The whole clause, with its own line when it has one to itself.
    LOut := '';
    while (LStart > 0) and IsBlank(LText[LStart]) do
      Dec(LStart);
    if (LStart > 0) and not CharInSet(LText[LStart], [#10, #13]) then
      LStart := TokStart(ATree, ATree.Nodes[AClause].FirstToken)
    else
    begin
      // At a line start: take the trailing blanks and one line break too.
      while (LEnd < Length(LText)) and IsBlank(LText[LEnd + 1]) do
        Inc(LEnd);
      if (LEnd < Length(LText)) and (LText[LEnd + 1] = #13) then
        Inc(LEnd);
      if (LEnd < Length(LText)) and (LText[LEnd + 1] = #10) then
        Inc(LEnd);
      // A blank line on both sides would become two in a row: take the one
      // after.
      if PrevLineBlank(LText, LStart) then
        LEnd := BlankLineEnd(LText, LEnd);
    end;
  end
  else
  begin
    // Run by run of removed items (kept items between them): the layout
    // drop when it holds no directive, else a comma of its own per item.
    LDrops := nil;
    LIdx := 0;
    while LIdx <= High(AItems) do
    begin
      if not ARemove[LIdx] then
      begin
        Inc(LIdx);
        Continue;
      end;
      LRunEnd := LIdx;
      while (LRunEnd < High(AItems)) and ARemove[LRunEnd + 1] do
        Inc(LRunEnd);
      if LRunEnd < High(AItems) then
      begin
        // A kept item follows: the run goes with the separator in front of
        // it (its line), the kept item keeps the separator in front of it.
        if LIdx = 0 then
          LFrom := LS[0]
        else
          LFrom := LC[LIdx - 1];
        LAt := LC[LRunEnd];
        if LIdx = 0 then
          LAt := LS[LRunEnd + 1];
      end
      else
      begin
        // The run ends the clause: the comma of the kept item before it goes,
        // and the blanks and line breaks between that item and its comma.
        LFrom := LC[LIdx - 1];
        while (LFrom > LE[LIdx - 1]) and (LText[LFrom] <= ' ') do
          Dec(LFrom);
        LAt := LC[LRunEnd];
      end;
      if not HasDirective(LText, LFrom, LAt) then
        Drop(LFrom, LAt)
      else if not AssignCommas(LIdx, LRunEnd, LIdx > 0) then
      begin
        AReason := 'a compiler directive stands between the entry and the ' +
          'comma it would take with it - remove it by hand';
        Exit;
      end;
      LIdx := LRunEnd + 1;
    end;
    // The text with the drops left out; they come in order and never
    // overlap (runs are apart by a kept item, a run's spans by its commas).
    LOut := '';
    LAt := LStart;
    for var LRange in LDrops do
    begin
      LOut := LOut + Copy(LText, LAt + 1, LRange.Start - LAt);
      LAt := LRange.Stop;
    end;
    LOut := LOut + Copy(LText, LAt + 1, LEnd - LAt);
  end;

  LFile.OffsetToLineCol(LStart, AEdit.Line, AEdit.Col);
  LFile.OffsetToLineCol(LEnd, LLine, LCol);
  AEdit.EndLine := LLine;
  AEdit.EndCol := LCol;
  AEdit.OldText := Copy(LText, LStart + 1, LEnd - LStart);
  AEdit.NewText := LOut;
  Result := True;
end;

function UsesRemovalEdits(const ATree: TPasTree;
  const ANameNodes: TArray<Integer>;
  out ARefused: TArray<TLspUsesRefusal>): TArray<TLspUsesRemoval>;
var
  LByClause: TDictionary<Integer, TList<Integer>>;   // clause -> items going
  LItem, LClause, LChild: Integer;
  LItems: TArray<Integer>;
  LRemove: TArray<Boolean>;
  LEdit: TLspUsesRemoval;
  LReason: string;
  LRefusal: TLspUsesRefusal;
  LNameOf: TDictionary<Integer, Integer>;   // item -> name node asked for
begin
  Result := nil;
  ARefused := nil;
  LByClause := TObjectDictionary<Integer, TList<Integer>>.Create([doOwnsValues]);
  LNameOf := TDictionary<Integer, Integer>.Create;
  try
    for var LName in ANameNodes do
    begin
      LItem := ItemOf(ATree, LName);
      if LItem <> NIL_NODE then
        LClause := ATree.Nodes[LItem].Parent
      else
        LClause := NIL_NODE;
      if (LClause = NIL_NODE) or
         (ATree.Nodes[LClause].Kind <> nkUsesClause) then
      begin
        LRefusal.NameNode := LName;
        LRefusal.Reason := 'not an entry of a uses clause';
        ARefused := ARefused + [LRefusal];
        Continue;
      end;
      if not LByClause.ContainsKey(LClause) then
        LByClause.Add(LClause, TList<Integer>.Create);
      LByClause[LClause].Add(LItem);
      LNameOf.AddOrSetValue(LItem, LName);
    end;
    for var LPair in LByClause do
    begin
      LClause := LPair.Key;
      LItems := nil;
      LRemove := nil;
      LChild := ATree.Nodes[LClause].FirstChild;
      while LChild <> NIL_NODE do
      begin
        if ATree.Nodes[LChild].Kind = nkUsesItem then
        begin
          LItems := LItems + [LChild];
          LRemove := LRemove + [LPair.Value.Contains(LChild)];
        end;
        LChild := ATree.Nodes[LChild].NextSibling;
      end;
      if (LItems <> nil) and
         RewriteClause(ATree, LClause, LItems, LRemove, LEdit, LReason) then
        Result := Result + [LEdit]
      else
        for LItem in LPair.Value do
        begin
          LRefusal.NameNode := LNameOf[LItem];
          LRefusal.Reason := LReason;
          ARefused := ARefused + [LRefusal];
        end;
    end;
  finally
    LNameOf.Free;
    LByClause.Free;
  end;
end;

// The dotted name under a name node, as written, comments dropped.
function EntryName(const ATree: TPasTree; ANode: Integer): string;
var
  LFirst, LLast: Integer;
  LPart: string;
begin
  Result := '';
  if not ATree.NodeVisRange(ANode, LFirst, LLast) then
    Exit;
  for var LIdx := LFirst to LLast do
  begin
    LPart := Trim(RawSpan(ATree, LIdx, LIdx));
    if (LPart = '') or (LPart[1] = '{') or LPart.StartsWith('(*') or
       LPart.StartsWith('//') then
      Continue;
    Result := Result + LPart;
  end;
end;

function UsesRemovalByName(const ATree: TPasTree;
  const ANames: TArray<string>; out ARefused: TArray<string>;
  out AMissing: TArray<string>): TArray<TLspUsesRemoval>;
var
  LNodes: TArray<Integer>;
  LNameOfNode: TDictionary<Integer, string>;
  LFound: TArray<Boolean>;
  LName: Integer;
  LText: string;
  LRefused: TArray<TLspUsesRefusal>;
begin
  ARefused := nil;
  AMissing := nil;
  LNodes := nil;
  SetLength(LFound, Length(ANames));
  LNameOfNode := TDictionary<Integer, string>.Create;
  try
    for var LItem := 0 to High(ATree.Nodes) do
    begin
      if (ATree.Nodes[LItem].Kind <> nkUsesItem) or
         (ATree.Nodes[LItem].Parent = NIL_NODE) or
         (ATree.Nodes[ATree.Nodes[LItem].Parent].Kind <> nkUsesClause) then
        Continue;
      LName := ATree.Nodes[LItem].FirstChild;
      if LName = NIL_NODE then
        Continue;
      LText := EntryName(ATree, LName);
      for var LIdx := 0 to High(ANames) do
        if (LText <> '') and SameUnitName(ANames[LIdx], LText) then
        begin
          LFound[LIdx] := True;
          LNodes := LNodes + [LName];
          LNameOfNode.AddOrSetValue(LName, LText);
          Break;
        end;
    end;
    Result := UsesRemovalEdits(ATree, LNodes, LRefused);
    for var LR in LRefused do
      ARefused := ARefused + [LNameOfNode[LR.NameNode] + ': ' + LR.Reason];
    for var LIdx := 0 to High(ANames) do
      if not LFound[LIdx] then
        AMissing := AMissing + [ANames[LIdx]];
  finally
    LNameOfNode.Free;
  end;
end;

end.
