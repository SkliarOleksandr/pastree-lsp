unit PasTreeIdePlugin.CaretWatch;

{
  WHERE THE CARET RESTS - read once it has stopped, and handed to the
  outline (PasTreeIdePlugin.Outline's OutlineCaretMoved), which selects the
  node of the declaration the caret is in.

  THE CARET. RAD Studio 13 reports every caret move
  (INTACodeEditorEvents.EditorSetCaretPos); 12 and 11.3 have no such event,
  but a caret move repaints the editor (the current-line band, the brace
  match), so BeginPaint stands in for it there - and on 13 as well, which
  costs nothing. Either only restarts a short timer: the position is read
  when the caret has rested, so holding an arrow key selects nothing until
  it stops, and a repaint that moved nothing finds the caret where it was.

  (0.81.0 also tinted the occurrences of the identifier under the caret
  from here. RAD Studio's editor does that itself, and well - withdrawn
  before it shipped, 2026-11-03.)

  MAIN THREAD throughout: editor events and the timer run there.
}

interface

procedure InitializeCaretWatch;
procedure FinalizeCaretWatch;

implementation

uses
  System.SysUtils,
  Vcl.Controls,
  Vcl.ExtCtrls,
  ToolsAPI,
  ToolsAPI.Editor,
  PasTreeIdePlugin.LspSession,     // LspLogDetail
  PasTreeIdePlugin.LspDocuments,   // IsPascalSourceFile
  PasTreeIdePlugin.Outline;        // OutlineCaretMoved

const
  // How long the caret must rest before it is read.
  cCaretRestMs = 250;

type
  TCaretNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
  public
    constructor Create;
    procedure HandleBeginPaint(const AEditor: TWinControl;
      const AForceFullRepaint: Boolean);
    {$IF Declared(TEditorCaretPosEvent)}
    procedure HandleCaretPos(const AEditor: TWinControl; X, Y: Integer);
    {$IFEND}
  end;

  TCaretTimer = class
  public
    Timer: TTimer;
    procedure Fired(Sender: TObject);
  end;

var
  GNotifier: INTACodeEditorEvents;
  GNotifierIndex: Integer = -1;
  GCaret: TCaretTimer;
  // Where the caret was last read: a rest at the same place does nothing.
  GLastFile: string;
  GLastRow, GLastCol: Integer;

procedure CaretRested;
var
  LServices: IOTAEditorServices;
  LView: IOTAEditView;
  LPath: string;
  LRow, LCol: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LView := LServices.TopView;
  if (LView = nil) or (LView.Buffer = nil) then
    Exit;
  LPath := LView.Buffer.FileName;
  LRow := LView.Buffer.EditPosition.Row;
  LCol := LView.Buffer.EditPosition.Column;
  if SameText(LPath, GLastFile) and (LRow = GLastRow) and (LCol = GLastCol) then
    Exit;
  GLastFile := LPath;
  GLastRow := LRow;
  GLastCol := LCol;
  if IsPascalSourceFile(LPath) then
    OutlineCaretMoved(LPath, LRow, LCol);
end;

procedure CaretMaybeMoved;
begin
  if GCaret = nil then
    Exit;
  GCaret.Timer.Enabled := False;
  GCaret.Timer.Enabled := True;
end;

{ TCaretTimer }

procedure TCaretTimer.Fired(Sender: TObject);
begin
  Timer.Enabled := False;
  try
    CaretRested;
  except
    on E: Exception do
      LspLogDetail('caret: reading it failed: ' + E.ClassName + ': '
        + E.Message);
  end;
end;

{ TCaretNotifier }

constructor TCaretNotifier.Create;
begin
  inherited Create;
  OnEditorBeginPaint := HandleBeginPaint;
  {$IF Declared(TEditorCaretPosEvent)}
  OnEditorSetCaretPos := HandleCaretPos;
  {$IFEND}
end;

function TCaretNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevBeginEndPaintEvents, cevWindowEvents];
end;

procedure TCaretNotifier.HandleBeginPaint(const AEditor: TWinControl;
  const AForceFullRepaint: Boolean);
begin
  CaretMaybeMoved;
end;

{$IF Declared(TEditorCaretPosEvent)}
procedure TCaretNotifier.HandleCaretPos(const AEditor: TWinControl;
  X, Y: Integer);
begin
  CaretMaybeMoved;
end;
{$IFEND}

procedure InitializeCaretWatch;
var
  LServices: INTACodeEditorServices;
begin
  if GNotifierIndex >= 0 then
    Exit;
  if not Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    Exit;
  GCaret := TCaretTimer.Create;
  GCaret.Timer := TTimer.Create(nil);
  GCaret.Timer.Enabled := False;
  GCaret.Timer.Interval := cCaretRestMs;
  GCaret.Timer.OnTimer := GCaret.Fired;
  GNotifier := TCaretNotifier.Create;
  GNotifierIndex := LServices.AddEditorEventsNotifier(GNotifier);
  if GNotifierIndex < 0 then
    GNotifier := nil;
end;

procedure FinalizeCaretWatch;
var
  LServices: INTACodeEditorServices;
begin
  if (GNotifierIndex >= 0) and
     Supports(BorlandIDEServices, INTACodeEditorServices, LServices) then
    LServices.RemoveEditorEventsNotifier(GNotifierIndex);
  GNotifierIndex := -1;
  GNotifier := nil;
  if GCaret <> nil then
  begin
    GCaret.Timer.Free;
    FreeAndNil(GCaret);
  end;
end;

end.
