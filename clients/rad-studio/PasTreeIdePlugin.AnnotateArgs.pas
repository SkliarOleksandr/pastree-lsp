unit PasTreeIdePlugin.AnnotateArgs;

(*
  "Annotate Arguments...": the parameter names of the call under the caret,
  written into the call as brace comments - `{AFileName:} S, {var} {AMode:} M`.
  The server decides everything about WHAT is written (PasLsp.AnnotateArgs -
  which call, which overload, which arguments, what is already there); this
  unit is the dialog call, the buffer edit and the report, and the local-menu
  item lives in PasTreeIdePlugin.Wizard beside Rename.

  ONE ITEM, ONE DIALOG (PasTreeIdePlugin.AnnotateArgsForm): every argument /
  only the anonymous ones / only the one at the caret, `{var}`/`{out}` marks
  on or off, one argument per line or the layout left alone (Alex,
  2026-09-14). The menu gate (findAllAt's `annotate`) says whether the caret
  was in the list or on the name, which is what makes "the argument at the
  caret" available; the item is hidden when the caret is in no call at all.

  THE EDITS ARE APPLIED as class completion and prototype sync apply theirs:
  every position resolved against the buffer BEFORE the writer opens, then
  one undoable writer walking forward - CopyTo, DeleteTo where the range has
  an end, Insert - so the whole call is one undo step and the text lands as
  the server spelled it, with no editor auto-indent in the way (see
  ApplyClassComplete for the history). A plain annotation is an insertion;
  the one-argument-per-line layout REPLACES the whitespace in front of each
  argument. The caret stays where it was.

  WHAT REACHES THE BUILD TAB: only what the user must know - a request that
  failed, a buffer that moved while the server answered, and a refusal
  (an ambiguous overload set, an intrinsic, a call that did not resolve),
  because the user clicked a menu item and nothing visibly happened. "Already
  annotated" is worth a line too, for the same reason. The routine outcome -
  edits written - goes to the log only.
*)

interface

uses
  ToolsAPI;

/// <summary>
/// Asks what to annotate (PasTreeIdePlugin.AnnotateArgsForm), then annotates
/// the call at AView's caret. AGateScope is the menu gate's verdict for the
/// caret - 'one' (inside the argument list), 'all' (on the name) or '' when
/// the gate could not say - and decides whether the dialog offers "the
/// argument at the caret". Asynchronous after the dialog: the edit lands on
/// a later main-thread turn, and is dropped if the buffer changed in between.
/// </summary>
procedure ExecuteAnnotateArgs(const AView: IOTAEditView;
  const AGateScope: string);

procedure InitializeAnnotateArgs;
procedure FinalizeAnnotateArgs;

implementation

uses
  System.SysUtils,
  System.Classes,
  Vcl.Menus,
  PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.LspSession,
  PasTreeIdePlugin.AnnotateArgsForm;

const
  // How long the key may wait for the caret's reading - the menu's budget.
  cKeyGateBudgetMs = 250;

type
  TPasAnnotateArgsBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure AnnotateProc(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

var
  // The request's callback can fire while the package is unloading, and by
  // then nothing it touches is safe to touch - class completion's guard.
  GAlive: Boolean = False;
  GKeyboardServices: IOTAKeyboardServices;
  GBindingIndex: Integer = -1;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ The insertions, applied. Offsets FIRST, then the writer - the view maps
  row/col against the buffer as it is, and every offset must describe the
  one snapshot the server answered about (ApplyClassComplete has the live
  failure this rule comes from). The server sends the edits ascending, which
  is the only order a writer can take. }
procedure ApplyAnnotateEdits(const AView: IOTAEditView;
  const AAnswer: TLspAnnotateArgs);
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
    // A range reading backwards would delete forever, and an edit before the
    // previous one would fail the writer mid-call, leaving half the names in
    // - refuse the whole answer either way.
    if (LEnds[LIdx] < LStarts[LIdx]) or
       ((LIdx > 0) and (LStarts[LIdx] < LEnds[LIdx - 1])) then
      Exit;
  end;
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AAnswer.Edits) do
    begin
      // A plain annotation has End = Start and DeleteTo is a no-op; the
      // one-argument-per-line layout replaces the whitespace in front.
      LWriter.CopyTo(LStarts[LIdx]);
      if LEnds[LIdx] > LStarts[LIdx] then
        LWriter.DeleteTo(LEnds[LIdx]);
      LWriter.Insert(UTF8String(AAnswer.Edits[LIdx].Text));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  AView.Paint;
end;

procedure ExecuteAnnotateArgs(const AView: IOTAEditView;
  const AGateScope: string);
var
  LFileName: string;
  LRow, LCol, LLenAtRequest: Integer;
  LPos: IOTAEditPosition;
  LOptions: TLspAnnotateOptions;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  LPos := AView.Buffer.EditPosition;
  if not Assigned(LPos) then
    Exit;
  LRow := LPos.Row;
  LCol := LPos.Column;
  LFileName := AView.Buffer.FileName;
  // THE DIALOG FIRST, the request after: the buffer length is taken once the
  // user has answered, so typing while the dialog is up (it is modal, so
  // that cannot happen, but the order costs nothing) does not fail the gate
  // below. "Current argument" is offered only when the gate saw the caret in
  // the list; when the gate could not say ('') it is offered too and the
  // server refuses if it does not apply.
  if not ExecuteAnnotateArgsDialog(AGateScope <> 'all', LOptions) then
    Exit;
  LLenAtRequest := BufferByteLength(AView);
  LspLogToServer(Format('annotateArgs: asking %s(%d,%d) mode=%s byRef=%s '
    + 'multiline=%s', [ExtractFileName(LFileName), LRow, LCol, LOptions.Mode,
    BoolToStr(LOptions.MarkByRef, True),
    BoolToStr(LOptions.OneArgPerLine, True)]));
  LspAnnotateArgs(LFileName, LRow, LCol, LOptions,
    procedure(ASuccess: Boolean; const AAnswer: TLspAnnotateArgs;
      const AError: string)
    begin
      if not GAlive then
        Exit;
      if not ASuccess then
      begin
        LogDiagnostic('Annotate arguments: ' + AError);
        Exit;
      end;
      if Length(AAnswer.Edits) = 0 then
      begin
        // A click that did nothing must say why - every refusal names
        // itself, and "already annotated" is an answer too.
        LogDiagnostic('Annotate arguments: ' + AAnswer.Provider);
        Exit;
      end;
      { The buffer must still be the one the server answered about: these
        insertions land at offsets computed from a snapshot, and a keystroke
        in between puts every name one character off. }
      if (LLenAtRequest < 0) or (BufferByteLength(AView) <> LLenAtRequest) then
      begin
        LogDiagnostic('Annotate arguments: the buffer changed while the '
          + 'server was answering - nothing was written. Try again.');
        Exit;
      end;
      ApplyAnnotateEdits(AView, AAnswer);
      LspLogToServer(Format('annotateArgs: %d edit(s) written for %s (%s)',
        [Length(AAnswer.Edits), AAnswer.Routine, AAnswer.Scope]));
    end);
end;

{ TPasAnnotateArgsBinding - Ctrl+Shift+A, the keyboard way to the same
  dialog (Alex, 2026-09-14). btPartial, like every binding of this package:
  it layers over the user's keymap and shows on Key Mappings. The menu gate
  is not at hand here - the menu was never opened - so the caret's reading is
  asked for directly, with the menu's own budget; past it the dialog offers
  "at the caret" anyway and the server refuses if it does not apply. }

function TPasAnnotateArgsBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TPasAnnotateArgsBinding.GetDisplayName: string;
begin
  Result := 'PasTree: annotate arguments (Ctrl+Shift+A)';
end;

function TPasAnnotateArgsBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.AnnotateArgsBinding';
end;

procedure TPasAnnotateArgsBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([ShortCut(Ord('A'), [ssCtrl, ssShift])],
    AnnotateProc, nil);
end;

procedure TPasAnnotateArgsBinding.AnnotateProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
  LGate: TLspFindAllGate;
  LScope: string;
begin
  // krHandled once recognised - Rename's reason: krUnhandled would hand the
  // key to the IDE, and a position ours declines would do something else.
  ABindingResult := krHandled;
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LView := AContext.EditBuffer.TopView;
  if not Assigned(LView) or not Assigned(LView.Buffer) then
    Exit;
  LScope := '';
  LGate := LspFindAllAt(LView.Buffer.FileName,
    LView.Buffer.EditPosition.Row, LView.Buffer.EditPosition.Column,
    cKeyGateBudgetMs);
  if LGate.Known then
  begin
    LScope := LGate.Annotate;
    if LScope = '' then
    begin
      LogDiagnostic('Annotate arguments: the caret is not in a call');
      Exit;
    end;
  end;
  ExecuteAnnotateArgs(LView, LScope);
end;

procedure InitializeAnnotateArgs;
begin
  GAlive := True;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices,
    GKeyboardServices) then
    Exit;
  GBindingIndex := GKeyboardServices.AddKeyboardBinding(
    TPasAnnotateArgsBinding.Create);
end;

procedure FinalizeAnnotateArgs;
begin
  GAlive := False;
  if (GBindingIndex >= 0) and Assigned(GKeyboardServices) then
    GKeyboardServices.RemoveKeyboardBinding(GBindingIndex);
  GBindingIndex := -1;
  GKeyboardServices := nil;
end;

end.
