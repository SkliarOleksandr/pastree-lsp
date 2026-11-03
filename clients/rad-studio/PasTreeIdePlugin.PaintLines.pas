unit PasTreeIdePlugin.PaintLines;

{
  WHICH LINE A PAINT EVENT IS FOR - below a folded block, not the one the
  paint context names.

  INTACodeEditorPaintContext carries EditorLineNum (documented as the
  visible line) and LogicalLineNum (the line of code), plus LineState. Below
  a folded block - a $REGION, a type, a method - they are wrong in one
  consistent way (the probes of 2026-11-03, a collapsed 3-line $REGION):
  EditorLineNum holds the LOGICAL line, and LogicalLineNum and LineState map
  that number through the folds a second time. The run "Index: Integer;" on
  line 55 came with EditorLineNum 55, LogicalLineNum 57 and the state of
  line 57; INTACodeEditorState.LineState[EditorLineNum] answered 57 as well.
  Every type colour below the fold was the line two rows down's, at its
  columns, and every squiggle and gutter glyph sat two rows up. Above the
  first fold both numbers agree and the context is right.

  A mouse position is not affected: PointToCharacterPos gives a visible line
  LineState maps correctly, which is why Ctrl+Click and the hover tooltip
  were right under the same fold.

  So the logical line is EditorLineNum, and its state is looked up among the
  visible lines (LineStateOfLogical). A text run is also checked against the
  line's text (PaintedRow): what the IDE hands a painter is not documented
  to behave, and the run itself cannot be wrong about where it stands.

  MAIN THREAD only, as the paint events are.
}

interface

uses
  ToolsAPI.Editor;

/// <summary>
/// The state of the line a paint event is for: the context's own above the
/// first fold, else the line whose LogicalLineNum is the context's
/// EditorLineNum. nil when it cannot be found.
/// </summary>
function PaintedLineState(
  const AContext: INTACodeEditorPaintContext): INTACodeEditorLineState;

/// <summary>
/// The logical row a text run (AText at column AColNum) is painted on, and
/// its line state when the state's text was confirmed to hold the run (nil
/// otherwise). 0 = not known: paint nothing. Unconfirmed - a folded line's
/// "..." box, a tab-indented line whose columns are not characters - the
/// context's row is trusted only above the first fold.
/// </summary>
function PaintedRow(const AContext: INTACodeEditorPaintContext;
  AColNum: Integer; const AText: string;
  out ALine: INTACodeEditorLineState): Integer;

implementation

var
  // Lines hidden above the last line found: tried first, so a line below a
  // fold costs one LineState call rather than a walk.
  GFoldHint: Integer;

{ The state of logical line ALogical, nil when it is hidden or not found.
  INTACodeEditorState.LineState is indexed by the VISIBLE line, and answers
  only for the lines in the window: any other gives LogicalLineNum -1 (and
  the first line's text), above the window and below it alike - so no
  binary search over the file (it never found the lines just under the
  fold). A fold above hides lines, never adds them, so the visible line is
  at or above ALogical: walked upward from there until the logical number
  drops below ALogical or the walk leaves the window. }
function LineStateOfLogical(const AState: INTACodeEditorState;
  ALogical: Integer): INTACodeEditorLineState;
var
  LVisible, LNum: Integer;
  LInWindow: Boolean;
  LLine: INTACodeEditorLineState;
begin
  Result := nil;
  if (GFoldHint > 0) and (ALogical - GFoldHint >= 1) then
  begin
    LLine := AState.LineState[ALogical - GFoldHint];
    if Assigned(LLine) and (LLine.LogicalLineNum = ALogical) then
      Exit(LLine);
  end;
  LInWindow := False;
  LVisible := ALogical;
  while LVisible >= 1 do
  begin
    LLine := AState.LineState[LVisible];
    if LLine = nil then
      Exit;
    LNum := LLine.LogicalLineNum;
    if LNum = ALogical then
    begin
      GFoldHint := ALogical - LVisible;
      Exit(LLine);
    end;
    if LNum >= 0 then
    begin
      if LNum < ALogical then
        Exit;   // hidden in a fold
      LInWindow := True;
    end
    else if LInWindow then
      Exit;     // walked out of the top of the window
    Dec(LVisible);
  end;
end;

function PaintedLineState(
  const AContext: INTACodeEditorPaintContext): INTACodeEditorLineState;
var
  LState: INTACodeEditorState;
begin
  if AContext.EditorLineNum = AContext.LogicalLineNum then
    // Nothing folded above: the common case, no lookup.
    Exit(AContext.LineState);
  Result := nil;
  LState := AContext.EditorState;
  if Assigned(LState) then
    Result := LineStateOfLogical(LState, AContext.EditorLineNum);
end;

function PaintedRow(const AContext: INTACodeEditorPaintContext;
  AColNum: Integer; const AText: string;
  out ALine: INTACodeEditorLineState): Integer;
begin
  ALine := PaintedLineState(AContext);
  if Assigned(ALine) and
     (Copy(ALine.Text, AColNum, Length(AText)) = AText) then
    Exit(ALine.LogicalLineNum);
  ALine := nil;
  if AContext.EditorLineNum = AContext.LogicalLineNum then
    Result := AContext.LogicalLineNum
  else
    Result := 0;
end;

end.
