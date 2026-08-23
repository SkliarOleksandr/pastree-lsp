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

  WHY krHandled EVEN WHEN NOTHING IS GENERATED. Returning krUnhandled would
  hand Ctrl+Shift+C back to the IDE, which would then run ITS class
  completion - so a file ours declines (an unsaved buffer with no
  implementation section, a server that is not up) would silently get the
  native behaviour instead, and a user comparing the two would be unable to
  tell which one just ran. The answer always comes back through the Build tab
  instead, including "nothing to implement".

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
  PasTreeIdePlugin.LspSession;

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

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ The answer, applied to the buffer. One place, so the ordering rule and the
  caret rule are stated once. }
procedure ApplyClassComplete(const AView: IOTAEditView;
  const AAnswer: TLspClassComplete);
var
  LIdx: Integer;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
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
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AAnswer.Edits) do
    begin
      // Row/col to a buffer offset: the writer measures in characters from the
      // start of the buffer, and the view is what knows the mapping.
      LCharPos.Line := AAnswer.Edits[LIdx].Row;
      LCharPos.CharIndex := AAnswer.Edits[LIdx].Col - 1;
      LWriter.CopyTo(AView.CharPosToPos(LCharPos));
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

procedure TPasClassCompleteBinding.ClassCompleteProc(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
  LFileName: string;
begin
  ABindingResult := krHandled;   // see the unit header
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) then
    Exit;
  LFileName := AContext.EditBuffer.FileName;
  LspClassComplete(LFileName,
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
        LogDiagnostic('class completion: nothing to implement (' +
          AAnswer.Provider + ')');
        Exit;
      end;
      ApplyClassComplete(LView, AAnswer);
      LogDiagnostic('class completion: implemented ' + AAnswer.Names);
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
  LogDiagnostic('class completion bound to Ctrl+Shift+C');
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
