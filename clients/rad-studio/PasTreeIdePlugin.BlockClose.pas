unit PasTreeIdePlugin.BlockClose;

{
  Block completion, the IDE half: Enter after an unclosed block opener gets
  the closer inserted on the next line. The DECISION is the server's -
  textDocument/onTypeFormatting, standard LSP, one implementation for every
  client (see PasLsp.BlockClose for the rules and the cascade reasoning) -
  and this unit only asks the question at the right moment and applies the
  answer through the editor.

  THE MOMENT IS AFTER THE ENTER, NOT INSTEAD OF IT - and the hook is an
  EDITOR EVENTS OBSERVER (INTACodeEditorEvents.EditorKeyUp, via
  TNTACodeEditorNotifier like ErrorPaint), NOT a keyboard binding. The
  first build used an IOTAKeyboardBinding on plain Enter answering
  krUnhandled, on the assumption the key would fall through to the editor.
  It does not: the first live run had Enter DEAD IN THE WHOLE EDITOR - no
  line break anywhere (user, 2026-08-31) - because a binding CLAIMS its
  keys and krUnhandled only offers them to other bindings/keymaps, not
  back to the editor's default processing. An observer cannot swallow
  anything by construction (Handled is left alone), and by key-UP time the
  editor has long inserted the line break - so the buffer already holds
  what the user sees, no deferral needed; FDocs.Sync inside the request
  pushes exactly that text.

  STALENESS IS HANDLED AT ANSWER TIME, the same way Rename verifies before
  writing: the answer is applied only if the caret is still on the row the
  question was asked about, in the same file. The user typing on regardless
  costs them nothing - the answer is dropped, not misapplied.

  Switchable off in Tools > PasTree > Settings (BlockCompletionEnabled),
  checked at keystroke time so the change takes effect immediately. Off
  means not even the request is sent. If the IDE's own block completion is
  enabled in Editor Options, the two would both insert - ours is the one
  with the off switch, and the hint in the settings dialog says so.
}

interface

/// <summary>Registers the editor key observer. Call once from the wizard.</summary>
procedure InitializeBlockClose;

/// <summary>Removes the observer before the BPL unloads.</summary>
procedure FinalizeBlockClose;

implementation

uses
  System.SysUtils, System.Classes,
  Vcl.Controls,
  Winapi.Windows,
  ToolsAPI, ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings;

type
  TPasBlockCloseNotifier = class(TNTACodeEditorNotifier)
  private
    procedure HandleKeyUp(const AEditor: TWinControl; AKey: Word;
      AShift: TShiftState; var AHandled: Boolean);
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
  end;

var
  GNotifier: INTACodeEditorEvents;
  GNotifierIndex: Integer = -1;
  GAlive: Boolean = False;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function TopViewOf(const AFileName: string): IOTAEditView;
var
  LEditorServices: IOTAEditorServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
  begin
    Result := LEditorServices.TopView;
    if Assigned(Result) and not Assigned(Result.Buffer) then
      Result := nil;
    // The wrong file's view is worse than none: between the keystroke and
    // this moment the user can have switched tabs. '' means "whichever is
    // on top" - the key-up reads the file from the view it gets.
    if Assigned(Result) and (AFileName <> '') and
       not SameText(Result.Buffer.FileName, AFileName) then
      Result := nil;
  end;
end;

{ The writer, not EditPosition.InsertText, for ApplyClassComplete's reason:
  InsertText goes through the editor and the editor auto-indents every line
  it receives - the closer would inherit the caret's indent instead of
  keeping the opener's, which is the whole point of the server computing it.
  One writer, one undo step. }
procedure ApplyEdits(const AView: IOTAEditView;
  const AEdits: TArray<TLspTextEdit>);
var
  LIdx: Integer;
  LWriter: IOTAEditWriter;
  LCharPos: TOTACharPos;
  LOffsets: TArray<Integer>;
begin
  if not Assigned(AView) or not Assigned(AView.Buffer) then
    Exit;
  SetLength(LOffsets, Length(AEdits));
  for LIdx := 0 to High(AEdits) do
  begin
    LCharPos.Line := AEdits[LIdx].Row;
    LCharPos.CharIndex := AEdits[LIdx].Col - 1;
    LOffsets[LIdx] := AView.CharPosToPos(LCharPos);
  end;
  LWriter := AView.Buffer.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := 0 to High(AEdits) do
    begin
      LWriter.CopyTo(LOffsets[LIdx]);
      LWriter.Insert(UTF8String(AEdits[LIdx].Text));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
end;

{ TPasBlockCloseNotifier }

constructor TPasBlockCloseNotifier.Create;
begin
  inherited Create;
  // The base class dispatches through event properties, not virtuals -
  // AllowedEvents is the only override, the handler rides the property
  // (same shape as TPasErrorPaintNotifier).
  OnEditorKeyUp := HandleKeyUp;
end;

function TPasBlockCloseNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevKeyboardEvents];
end;

procedure TPasBlockCloseNotifier.HandleKeyUp(const AEditor: TWinControl;
  AKey: Word; AShift: TShiftState; var AHandled: Boolean);
var
  LView: IOTAEditView;
  LFileName: string;
  LRow, LCol: Integer;
begin
  // AHandled is never touched: this is an observer, and the key-up has
  // nothing left to handle anyway - the editor broke the line on key-down.
  if (AKey <> VK_RETURN) or (AShift * [ssCtrl, ssAlt] <> []) then
    Exit;
  if not GAlive or not BlockCompletionEnabled then
    Exit;
  LView := TopViewOf('');
  if not Assigned(LView) or not Assigned(LView.Buffer) then
    Exit;
  LFileName := LView.Buffer.FileName;
  if not IsPascalSourceFile(LFileName) then
    Exit;
  LRow := LView.Buffer.EditPosition.Row;
  LCol := LView.Buffer.EditPosition.Column;
  LspOnTypeFormatting(LFileName, LRow, LCol,
    procedure(ASuccess: Boolean; const AEdits: TArray<TLspTextEdit>;
      const AError: string)
    var
      LNowView: IOTAEditView;
    begin
      if not GAlive then
        Exit;
      if not ASuccess then
      begin
        // The ordinary no-server case stays quiet - Enter is pressed
        // hundreds of times an hour and must never nag.
        Exit;
      end;
      if Length(AEdits) = 0 then
        Exit;
      // Verify, then write - the same discipline as Rename: the answer
      // describes the buffer as it was asked; apply it only if the
      // caret still sits where the question was asked from.
      LNowView := TopViewOf(LFileName);
      if not Assigned(LNowView) or
         (LNowView.Buffer.EditPosition.Row <> LRow) then
        Exit;
      ApplyEdits(LNowView, AEdits);
    end);
end;

procedure InitializeBlockClose;
var
  LServices: INTACodeEditorServices;
begin
  GAlive := True;
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  GNotifier := TPasBlockCloseNotifier.Create;
  GNotifierIndex := LServices.AddEditorEventsNotifier(GNotifier);
  if GNotifierIndex < 0 then
    GNotifier := nil;   // refcount frees it
end;

procedure FinalizeBlockClose;
var
  LServices: INTACodeEditorServices;
begin
  GAlive := False;
  if GNotifierIndex < 0 then
    Exit;
  if Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
end;

end.
