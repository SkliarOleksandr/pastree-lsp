unit PasTreeIdePlugin.SyncPrototypes;

{
  Prototype sync: the signature under the caret, mirrored onto the routine's
  other half. The server decides what "mirrored" means (PasLsp.SyncPrototypes
  has the rules and the refusals); this unit is the buffer edit and the report.

  PART OF CLASS COMPLETION, NOT A COMMAND OF ITS OWN. Ctrl+Shift+C runs this
  first and then class completion proper (PasTreeIdePlugin.ClassComplete), and
  the two are the same thought from either end: class completion writes the
  body a declaration is missing, this keeps an existing pair in step. One
  gesture, one settings switch, nothing new to discover.

  IT USED TO BE THE IDE'S OWN "Sync Prototypes" MENU ITEM, and the three
  attempts to make that work are worth recording so nobody spends the day
  again:

  1. Hide the native (broken) command and put ours next to it. The native
     command is not in INTAServices.ActionList at all on RAD Studio 13 - that
     list is what the ToolsAPI hands out for THIRD-PARTY items - so this found
     nothing to hide.
  2. Find it by walking the component tree / VCL's PopupList and hide the
     TMenuItem. This worked, and took the IDE down with it: a heap-corrupting
     access violation in vcl370.bpl, surfacing later somewhere unrelated (a
     `clr.dll` frame, and `TThread.CheckSynchronize` failing with "No
     synchronizable method found" in the LSP transport's reader thread).
  3. Repoint that item's OnClick at ours, re-applying it from the parent
     TPopupMenu's OnPopup so it could not be undone. Same crash.

  The reason all three fail is in ToolsAPI.pas itself, on
  INTAEditorLocalMenu.RegisterActionList: "The local menu will be created each
  time it is used". The editor's local menu is REBUILT FROM SCRATCH on every
  open; the TMenuItem found by walking components belongs to one showing of
  it, and holding a pointer to that across the next one is a use-after-free.
  There is no ToolsAPI call to enumerate or replace another package's
  registered actions, so "fix the IDE's own item" has no safe implementation -
  not for want of finding the right API, but because the object is not stable
  between two clicks.

  THE EDIT IS A REPLACEMENT, so applying it is not class completion's
  insert-only walk: CopyTo the start, DeleteTo the end, Insert the new text -
  one undoable writer, one undo step. Ascending order is still the rule (a
  writer cannot move backward), and the server sends at most one edit anyway.
}

interface

uses
  System.SysUtils,
  ToolsAPI;

/// <summary>
/// Mirrors the signature at AView's caret onto the routine's other half, then
/// calls AOnDone - ALWAYS, whether anything was mirrored or not, so a caller
/// can chain the next step onto it (class completion does exactly that).
/// Asynchronous: AOnDone runs on a later main-thread turn, after the buffer
/// edit if there was one, so the next step sees the mirrored text.
///
/// The outcomes worth a word land in the Build tab; the ordinary non-events
/// (already in step, the caret in no routine) stay silent - see the callback.
/// </summary>
procedure SyncPrototypesAtCaret(const AView: IOTAEditView;
  const AOnDone: TProc);

procedure InitializeSyncPrototypes;
procedure FinalizeSyncPrototypes;

implementation

uses
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.LspSession;

var
  // Same teardown guard as class completion's: the request's callback can
  // fire while the package is unloading, and by then nothing it touches is
  // safe to touch.
  GAlive: Boolean = False;

{ THE BUILD TAB IS FOR WHAT THE USER MUST ACT ON, and nothing else. Ctrl+Shift+C
  is pressed constantly and prototype sync runs on every press, so its ordinary
  outcomes are the definition of noise in a panel the user reads for compiler
  errors (user, 2026-09-01). Those go to LogTrace instead - the server's own
  pastree-lsp.log, beside the project, where the whole sequence of a session
  can be read back. What stays here: a request that FAILED, and an answer
  dropped because the buffer moved - both mean the keystroke did not do what
  it looked like it did. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ The routine outcomes: into the log, never into the panel. A no-op when no
  server is up, which is correct - there is nothing to report about a feature
  that could not have run. }
procedure LogTrace(const AMessage: string);
begin
  LspLogToServer(AMessage);
end;

{ The answer, applied to the buffer.

  A REPLACEMENT, so the writer walks: CopyTo the start of the old header,
  DeleteTo its end, Insert the new one. Every offset is resolved BEFORE the
  writer opens, for the reason ApplyClassComplete records at length - the view
  answers about the buffer as it is, and a conversion made after an earlier
  edit describes a buffer that has already moved. }
procedure ApplySyncEdits(const AView: IOTAEditView;
  const AAnswer: TLspSyncPrototypes);
var
  LIdx: Integer;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LStarts, LEnds: TArray<Integer>;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  SetLength(LStarts, Length(AAnswer.Edits));
  SetLength(LEnds, Length(AAnswer.Edits));
  for LIdx := 0 to High(AAnswer.Edits) do
  begin
    LCharPos.Line := AAnswer.Edits[LIdx].Row;
    LCharPos.CharIndex := AAnswer.Edits[LIdx].Col - 1;
    LStarts[LIdx] := AView.CharPosToPos(LCharPos);
    LCharPos.Line := AAnswer.Edits[LIdx].EndRow;
    LCharPos.CharIndex := AAnswer.Edits[LIdx].EndCol - 1;
    LEnds[LIdx] := AView.CharPosToPos(LCharPos);
    // A range that reads backwards would delete forever; drop the whole
    // answer rather than write part of it.
    if LEnds[LIdx] < LStarts[LIdx] then
      Exit;
  end;
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AAnswer.Edits) do
    begin
      LWriter.CopyTo(LStarts[LIdx]);
      LWriter.DeleteTo(LEnds[LIdx]);
      LWriter.Insert(UTF8String(AAnswer.Edits[LIdx].Text));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  // The change is elsewhere in the file than the caret - often off screen -
  // so a repaint now rather than at the next natural refresh is the only way
  // the user sees that anything happened.
  AView.Paint;
end;

procedure SyncPrototypesAtCaret(const AView: IOTAEditView;
  const AOnDone: TProc);
var
  LFileName: string;
  LRow, LCol, LLenAtRequest: Integer;
  LPos: IOTAEditPosition;

{ AOnDone MUST RUN ON EVERY PATH - it is the second half of the user's
  keystroke, not a success callback. A path that forgets it turns Ctrl+Shift+C
  into a key that does nothing whenever prototype sync happened to decline.
  Spelled out at each exit rather than wrapped in a local Done procedure: a
  nested procedure cannot be captured by the anonymous method below (E2555). }
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
  begin
    if Assigned(AOnDone) then
      AOnDone;
    Exit;
  end;
  LPos := AView.Buffer.EditPosition;
  if not Assigned(LPos) then
  begin
    if Assigned(AOnDone) then
      AOnDone;
    Exit;
  end;
  LRow := LPos.Row;
  LCol := LPos.Column;
  LFileName := AView.Buffer.FileName;
  // The snapshot this answer will describe - see the gate in the callback.
  LLenAtRequest := BufferByteLength(AView);
  LspSyncPrototypes(LFileName, LRow, LCol,
    procedure(ASuccess: Boolean; const AAnswer: TLspSyncPrototypes;
      const AError: string)
    begin
      if not GAlive then
        Exit;   // the package is unloading; the chain dies with it
      if not ASuccess then
      begin
        LogDiagnostic('sync prototypes failed: ' + AError);
        if Assigned(AOnDone) then
          AOnDone;
        Exit;
      end;
      if Length(AAnswer.Edits) = 0 then
      begin
        { SILENT ON THE ORDINARY NON-EVENTS, unlike the standalone command
          this used to be. As a step inside Ctrl+Shift+C it runs on every
          press, and "already in step" or "the caret is not in a routine" is
          the answer nearly every time - a line per press for that is noise in
          the panel class completion is about to write its own line to. The
          one refusal that means the user asked for something and did NOT get
          it - an ambiguous overload set - still speaks up. }
        if AAnswer.Provider.Contains('overloads named') then
          LogDiagnostic('sync prototypes: ' + AAnswer.Provider)
        else
          LogTrace('sync prototypes: ' + AAnswer.Provider);
        if Assigned(AOnDone) then
          AOnDone;
        Exit;
      end;
      { THE BUFFER MUST STILL BE THE ONE THE SERVER ANSWERED ABOUT, and this
        matters more here than for class completion: those edits INSERT at a
        stale offset, these DELETE a range at one. A range resolved against a
        buffer the user has typed into since covers different characters than
        the header it was computed for. }
      if (LLenAtRequest < 0) or (BufferByteLength(AView) <> LLenAtRequest) then
      begin
        LogDiagnostic('sync prototypes: the buffer changed while the server '
          + 'was answering - nothing was rewritten. Press Ctrl+Shift+C again.');
        if Assigned(AOnDone) then
          AOnDone;
        Exit;
      end;
      ApplySyncEdits(AView, AAnswer);
      LogTrace('sync prototypes: ' + AAnswer.Provider);
      if Assigned(AOnDone) then
        AOnDone;
    end);
end;

procedure InitializeSyncPrototypes;
begin
  GAlive := True;
end;

procedure FinalizeSyncPrototypes;
begin
  GAlive := False;
end;

end.
