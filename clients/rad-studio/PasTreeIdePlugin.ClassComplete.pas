unit PasTreeIdePlugin.ClassComplete;

{
  Class completion on Ctrl+Shift+C, ours - a REPLACEMENT for the native one,
  not an addition (clients/rad-studio/SPEC.md's live queue, item 3). The
  native one is not gated by the Insight Provider selection and works badly
  (user, 2026-08-22), and it ignores free routines declared in a unit's
  interface section; the server's pastree/classComplete answers about both.

  A KEYBOARD BINDING, not a menu item, because that is the way this feature is
  reached: nobody looks for class completion in a menu, they press the keys.
  btPartial with our own two-key... one-key binding, registered exactly like
  the decl/impl toggle in PasTreeIdePlugin.Wizard - see the reasoning there
  about krHandled.

  TWO STEPS PER PRESS. Prototype sync runs FIRST - the signature under the
  caret mirrored onto the routine's other half (PasTreeIdePlugin.SyncPrototypes,
  which also records why it is not the menu command it started as) - and then
  class completion proper. One keystroke, one settings switch, and the order
  matters: see ClassCompleteProc.

  WHY krHandled EVEN WHEN NOTHING IS GENERATED. Returning krUnhandled would
  hand Ctrl+Shift+C back to the IDE, which would then run ITS class
  completion - so a file ours declines (an unsaved buffer with no
  implementation section, a server that is not up) would silently get the
  native behaviour instead, and a user comparing the two would be unable to
  tell which one just ran. The outcome is reported instead: a failure in the
  Build tab, the routine answers ("nothing to implement", what was mirrored)
  in pastree-lsp.log, because this key is pressed too often for its ordinary
  outcomes to belong in a panel read for compiler errors.

  THE ONE EXCEPTION is the OFF SWITCH (ClassCompleteEnabled), which answers
  krUnhandled deliberately: that is what makes "off" mean the IDE's own class
  completion, with no keymap to unbind.

  APPLYING THE EDITS goes through an UNDOABLE EDIT WRITER, in ascending
  position order - see ApplyClassComplete for why the editor's own InsertText
  is the wrong tool here (auto-indent) and why ascending is the only order a
  writer allows. The caret then goes where the server said, which is the empty
  body line of the first generated routine.
}

interface

procedure InitializeClassComplete;
procedure FinalizeClassComplete;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Vcl.Menus,
  ToolsAPI,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.Settings,
  PasTreeIdePlugin.SyncPrototypes;

type
  TPasClassCompleteBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure ClassCompleteProc(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

var
  GKeyboardServices: IOTAKeyboardServices;
  GBindingIndex: Integer = -1;
  // Same teardown guard as the Code Insight manager's: the request's callback
  // can fire while the package is unloading, and by then nothing it touches
  // is safe to touch.
  GAlive: Boolean = False;

{ THE BUILD TAB IS FOR WHAT THE USER MUST ACT ON - see the same split in
  PasTreeIdePlugin.SyncPrototypes. "Nothing to implement" is the answer to
  most presses of Ctrl+Shift+C and belongs in the log, not in the panel the
  user reads for compiler errors (user, 2026-09-01). }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ The routine outcomes: into the server's pastree-lsp.log, never the panel. }
procedure LogTrace(const AMessage: string);
begin
  LspLogToServer(AMessage);
end;

{ The answer, applied to the buffer. One place, so the ordering rule and the
  caret rule are stated once. }
procedure ApplyClassComplete(const AView: IOTAEditView;
  const AAnswer: TLspClassComplete);
var
  LIdx: Integer;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LOffsets: TArray<Integer>;
  LPos: IOTAEditPosition;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  { AN EDIT WRITER, NOT EditPosition.InsertText - and the first live run is why
    (2026-08-23). InsertText goes through the EDITOR, which applies auto-indent
    to every line it receives: the generated bodies came out with `end;`
    indented two spaces under `begin`, and each further stub two more, because
    each inserted line inherited the previous one's indent. A writer writes the
    text as given, which is the only way generated code can look like what the
    generator decided.

    A writer also cannot move BACKWARD, so the edits are applied in ASCENDING
    order - which is the order the server sends them in, for exactly this
    reason - with one CopyTo per edit walking the buffer forward. One writer
    means one undo step for the whole completion, like the native one. }
  { EVERY OFFSET FIRST, THEN THE WRITER. Row/col has to become a buffer
    offset, and only the view knows that mapping - but the view answers about
    the buffer AS IT IS. Converting inside the write loop therefore reads a
    buffer the earlier insertions have already grown: on the first live run
    over a 22 000-line unit the two accessor declarations pushed the body
    insertion two lines down, past the unit's own `end.`, and the bodies landed
    outside the unit entirely (2026-08-23). The server's positions all describe
    ONE snapshot, so they must all be resolved against that snapshot. }
  SetLength(LOffsets, Length(AAnswer.Edits));
  for LIdx := 0 to High(AAnswer.Edits) do
  begin
    LCharPos.Line := AAnswer.Edits[LIdx].Row;
    LCharPos.CharIndex := AAnswer.Edits[LIdx].Col - 1;
    LOffsets[LIdx] := AView.CharPosToPos(LCharPos);
  end;
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AAnswer.Edits) do
    begin
      LWriter.CopyTo(LOffsets[LIdx]);
      LWriter.Insert(UTF8String(AAnswer.Edits[LIdx].Text));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  if AAnswer.CaretRow > 0 then
  begin
    LPos := AView.Buffer.EditPosition;
    if Assigned(LPos) then
      LPos.Move(AAnswer.CaretRow, AAnswer.CaretCol);
  end;
  // The insertion came from a keystroke with no visible cause; repaint now
  // rather than at the next natural refresh.
  AView.Paint;
end;

{ TPasClassCompleteBinding }

function TPasClassCompleteBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TPasClassCompleteBinding.GetDisplayName: string;
begin
  // The Key Mappings page is where someone goes to find out why Ctrl+Shift+C
  // stopped behaving the way it used to, so it says so here.
  Result := 'PasTree: class completion (Ctrl+Shift+C)';
end;

function TPasClassCompleteBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.ClassCompleteBinding';
end;

procedure TPasClassCompleteBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([ShortCut(Ord('C'), [ssCtrl, ssShift])],
    ClassCompleteProc, nil);
end;

{ Class completion proper - everything after the prototype sync that now runs
  in front of it. Split out of the key handler so the chaining below reads as
  the two steps it is. }
procedure RunClassComplete(const AView: IOTAEditView;
  const AFileName: string);
var
  LLenAtRequest: Integer;
begin
  // THE SNAPSHOT THIS ANSWER WILL DESCRIBE, measured now - see the gate in the
  // callback and BufferByteLength for why one integer is the right measure.
  // Measured HERE rather than before the sync step: if the sync rewrote a
  // header, the buffer it left behind is the one this answer describes.
  LLenAtRequest := BufferByteLength(AView);
  LspClassComplete(AFileName,
    procedure(ASuccess: Boolean; const AAnswer: TLspClassComplete;
      const AError: string)
    begin
      if not GAlive then
        Exit;
      if not ASuccess then
      begin
        LogDiagnostic('class completion failed: ' + AError);
        Exit;
      end;
      if Length(AAnswer.Edits) = 0 then
      begin
        // Not a failure: everything declared is implemented. Said out loud,
        // because a keystroke that does nothing silently reads as broken.
        LogTrace('class completion: nothing to implement (' +
          AAnswer.Provider + ')');
        Exit;
      end;
      { THE BUFFER MUST STILL BE THE ONE THE SERVER ANSWERED ABOUT. Rename
        verifies every site before it writes; BlockClose at least checks the
        caret row; this applied its answer with no check at all, and that is
        not a theoretical gap on a cold project: pastree/classComplete waits
        out the whole analysis (seconds - the wait Find References got a
        progress dialog for), Ctrl+Shift+C shows nothing while it does, and the
        natural thing to do is keep typing. Every row/col the server sent then
        gets resolved against a buffer that has moved, and the bodies land at
        shifted offsets - the same "outside the unit entirely" failure
        ApplyClassComplete's own comment dates to 2026-08-23, which the
        precomputed offsets fixed only for the shifts this code causes itself,
        not for the user's.

        Said out loud rather than dropped silently: a keystroke that does
        nothing reads as broken, which is the rule the empty-answer case above
        already follows. }
      if (LLenAtRequest < 0) or (BufferByteLength(AView) <> LLenAtRequest) then
      begin
        LogDiagnostic('class completion: the buffer changed while the server'
          + ' was answering - nothing was inserted. Press Ctrl+Shift+C again.');
        Exit;
      end;
      ApplyClassComplete(AView, AAnswer);
      LogTrace('class completion: implemented ' + AAnswer.Names);
    end);
end;

procedure TPasClassCompleteBinding.ClassCompleteProc(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
  LFileName: string;
begin
  { THE OFF SWITCH, and the ONE path here that answers krUnhandled - which is
    precisely what makes "off" mean "the IDE's own class completion", with no
    keymap to unbind and nothing to restore. It has to come before the
    unconditional krHandled below, whose whole point (see the unit header) is
    that a case OURS declines must not silently fall through to the native
    implementation this replaces. Gating the whole keystroke also gates the
    prototype sync in front of it: one key, one switch. }
  if not ClassCompleteEnabled then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;   // see the unit header
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) then
    Exit;
  LFileName := AContext.EditBuffer.FileName;
  { TWO STEPS, IN THIS ORDER, and the order is the point.

    Prototype sync first: it REWRITES an existing header, and doing that after
    class completion had inserted bodies would mean applying a range computed
    against the buffer as it was before those insertions - the same stale-
    offset failure ApplyClassComplete's own comment dates to 2026-08-23.
    Sequenced rather than fired together for exactly that reason: the sync's
    callback is what starts class completion, so the second request is built
    from the text the first one left.

    The two never collide over the same routine, either: sync only ever
    touches a pair that HAS both halves, and class completion only ever writes
    a body for a declaration that has none. }
  SyncPrototypesAtCaret(LView,
    procedure
    begin
      if not GAlive then
        Exit;
      RunClassComplete(LView, LFileName);
    end);
end;

procedure InitializeClassComplete;
begin
  GAlive := True;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices,
    GKeyboardServices) then
    Exit;
  GBindingIndex := GKeyboardServices.AddKeyboardBinding(
    TPasClassCompleteBinding.Create);
  // Not announced - a binding that worked is not news; see the same reasoning
  // in InitializeCodeInsight.
end;

procedure FinalizeClassComplete;
begin
  GAlive := False;
  if (GBindingIndex >= 0) and Assigned(GKeyboardServices) then
    GKeyboardServices.RemoveKeyboardBinding(GBindingIndex);
  GBindingIndex := -1;
  GKeyboardServices := nil;
end;

end.
