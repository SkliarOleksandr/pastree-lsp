unit PasTreeIdePlugin.BlockClose;

{
  Block completion, the IDE half: Enter after an unclosed block opener gets
  the closer inserted on the next line. The DECISION is the server's -
  textDocument/onTypeFormatting, standard LSP, one implementation for every
  client (see PasLsp.BlockClose for the rules and the cascade reasoning) -
  and this unit only asks the question at the right moment and applies the
  answer through the editor.

  THE MOMENT IS AFTER THE ENTER, NOT INSTEAD OF IT. The keyboard binding
  claims plain Enter but ALWAYS answers krUnhandled, so the IDE performs
  its ordinary line break first - swallowing Enter would put this package
  in charge of the single most-pressed key in the editor, and the native
  break carries auto-indent, virtual caret placement and everything else
  nobody should reimplement. The actual work runs from TThread.ForceQueue:
  by the time that fires, the buffer holds the newline, FDocs.Sync inside
  the request pushes exactly that text, and the server sees what the user
  sees.

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

/// <summary>Registers the Enter binding. Call once from the wizard.</summary>
procedure InitializeBlockClose;

/// <summary>Removes the binding before the BPL unloads.</summary>
procedure FinalizeBlockClose;

implementation

uses
  System.SysUtils, System.Classes,
  Vcl.Menus,
  Winapi.Windows,
  ToolsAPI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings;

type
  TPasBlockCloseBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure EnterProc(const AContext: IOTAKeyContext; AKeyCode: TShortCut;
      var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

var
  GKeyboardServices: IOTAKeyboardServices;
  GBindingIndex: Integer = -1;
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
    // The wrong file's view is worse than none: between the keystroke and
    // this moment the user can have switched tabs.
    if Assigned(Result) and (not Assigned(Result.Buffer) or
       not SameText(Result.Buffer.FileName, AFileName)) then
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

{ TPasBlockCloseBinding }

function TPasBlockCloseBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TPasBlockCloseBinding.GetDisplayName: string;
begin
  Result := 'PasTree: block completion (Enter)';
end;

function TPasBlockCloseBinding.GetName: string;
begin
  Result := 'PasTreeIdePlugin.BlockCloseBinding';
end;

procedure TPasBlockCloseBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([ShortCut(VK_RETURN, [])], EnterProc, nil);
end;

procedure TPasBlockCloseBinding.EnterProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
var
  LFileName: string;
begin
  // ALWAYS. The IDE's Enter must run whatever happens next - see the unit
  // header. Everything below only schedules a question about the result.
  ABindingResult := krUnhandled;
  if not GAlive or not BlockCompletionEnabled or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  LFileName := AContext.EditBuffer.FileName;
  if not IsPascalSourceFile(LFileName) then
    Exit;

  TThread.ForceQueue(nil,
    procedure
    var
      LView: IOTAEditView;
      LRow, LCol: Integer;
    begin
      // Queued behind the IDE's own handling of this Enter: the buffer now
      // holds the newline and the caret sits on the fresh line.
      if not GAlive then
        Exit;
      LView := TopViewOf(LFileName);
      if not Assigned(LView) then
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
            // hundreds of times an hour and must never nag. The log line is
            // for a diagnosis that already suspects this feature.
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
    end);
end;

procedure InitializeBlockClose;
begin
  GAlive := True;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices,
    GKeyboardServices) then
    Exit;
  GBindingIndex := GKeyboardServices.AddKeyboardBinding(
    TPasBlockCloseBinding.Create);
end;

procedure FinalizeBlockClose;
begin
  GAlive := False;
  if (GBindingIndex >= 0) and Assigned(GKeyboardServices) then
    GKeyboardServices.RemoveKeyboardBinding(GBindingIndex);
  GBindingIndex := -1;
  GKeyboardServices := nil;
end;

end.
