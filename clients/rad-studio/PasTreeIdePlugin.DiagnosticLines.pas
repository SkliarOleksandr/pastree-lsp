unit PasTreeIdePlugin.DiagnosticLines;

{
  WHERE A DIAGNOSTIC'S LINE IS NOW - the last publishDiagnostics carried
  onto the lines the editor holds while the next one is on its way.

  A publishDiagnostics names rows of the text the server analyzed. Typing
  moves the text under it: a line inserted above an error pushed the error
  down, and until the next answer landed (the typing pause, then the
  analysis) the squiggle, the gutter mark and the scroll bar mark stayed on
  the old row - under the wrong code.

  The editor already knows where every line went: IOTAEditLineTracker, the
  buffer's own list of lines that it moves as the user edits (the IDE keeps
  breakpoints on their lines with it). Each publishDiagnostics registers its
  distinct rows there (TrackDiagnosticLines, from ErrorPaint's listener),
  and each EditorViewModified reads back where they are now
  (DiagnosticLinesViewModified, from IdleSync's notifier). The painters ask
  LiveDiagnostics instead of the cache, and get the same diagnostics with
  their rows moved - or without the ones whose line was deleted.

  NO IOTA REFERENCE IS KEPT. A held IOTASourceEditor made the IDE's own
  close of a tab an access violation (Rename's Revert, 2026-09-27), so the
  buffer is looked up by name each time and the tracker is never stored. Our
  entries are told apart from everyone else's by their Data: addresses
  inside a block this unit allocated, unique in the process for as long as
  the block lives. A buffer that closes takes its tracker and our entries
  with it; the next publish for the file starts over.

  LINES, NOT COLUMNS. Typing inside a line still slides its squiggle until
  the next answer - the tracker follows lines only, and the semantic
  colouring's character-level answer (PasTreeIdePlugin.TokenShift) needs the
  base text, which the diagnostics cache does not keep.

  Registered against the buffer as it is WHEN THE ANSWER ARRIVES: lines
  typed between the sync the analysis read and its answer are not known to
  have moved. The next answer, a typing pause later, puts them right.

  MAIN THREAD throughout: the listener, the notifier and the paint events
  all run there.
}

interface

uses
  ToolsAPI,
  PasTreeIdePlugin.LspSession;   // TLspDiagnostic, LspTryGetDiagnostics

/// <summary>
/// The diagnostics for APath (LspTryGetDiagnostics), each row where its line
/// stands now in the editor; one whose line was deleted is left out. The
/// cache's own answer when nothing tracked has moved.
/// </summary>
function LiveDiagnostics(const APath: string;
  out ADiags: TArray<TLspDiagnostic>): Boolean;

/// <summary>
/// A publishDiagnostics for APath has landed: its rows replace ours in the
/// buffer's line tracker. Nothing is tracked when no buffer holds the file.
/// </summary>
procedure TrackDiagnosticLines(const APath: string);

/// <summary>
/// The buffer of AView was edited: read where our lines are now. True when
/// one of them moved or went - the caller repaints.
/// </summary>
function DiagnosticLinesViewModified(const AView: IOTAEditView): Boolean;

/// <summary>Our entries off every open buffer, the blocks freed.</summary>
procedure FinalizeDiagnosticLines;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TTrackedFile = class
  public
    // The diagnostics array the rows were taken from - the cache's own
    // reference, so a newer answer that was not tracked is told apart.
    Source: Pointer;
    // One byte per row: Block + I is row I's Data in the tracker.
    Block: PByte;
    Rows: TArray<Integer>;      // distinct rows, ascending
    Added: TArray<Boolean>;     // given to the tracker (in the buffer's range)
    Now: TArray<Integer>;       // where each stands now; 0 = deleted
    Moved: Boolean;             // some Now[I] <> Rows[I]
    Live: TArray<TLspDiagnostic>;   // LiveDiagnostics' answer, built once
    LiveBuilt: Boolean;
    destructor Destroy; override;
    function IndexOfData(AData: IntPtr): Integer;
    function IndexOfRow(ARow: Integer): Integer;
  end;

var
  // By LowerCase(path), the session cache's key.
  GFiles: TObjectDictionary<string, TTrackedFile>;

destructor TTrackedFile.Destroy;
begin
  FreeMem(Block);
  inherited;
end;

function TTrackedFile.IndexOfData(AData: IntPtr): Integer;
begin
  if (Block = nil) or (NativeUInt(AData) < NativeUInt(Block)) or
     (NativeUInt(AData) >= NativeUInt(Block) + NativeUInt(Length(Rows))) then
    Exit(-1);
  Result := NativeUInt(AData) - NativeUInt(Block);
end;

function TTrackedFile.IndexOfRow(ARow: Integer): Integer;
var
  LLo, LHi, LMid: Integer;
begin
  LLo := 0;
  LHi := High(Rows);
  while LLo <= LHi do
  begin
    LMid := (LLo + LHi) div 2;
    if Rows[LMid] = ARow then
      Exit(LMid);
    if Rows[LMid] < ARow then
      LLo := LMid + 1
    else
      LHi := LMid - 1;
  end;
  Result := -1;
end;

function FindBuffer(const APath: string): IOTAEditBuffer;
var
  LServices: IOTAEditorServices;
  LIterator: IOTAEditBufferIterator;
  I: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) or
     not LServices.GetEditBufferIterator(LIterator) then
    Exit;
  for I := 0 to LIterator.Count - 1 do
    if SameText(LIterator.EditBuffers[I].FileName, APath) then
      Exit(LIterator.EditBuffers[I]);
end;

procedure RemoveEntries(const ABuffer: IOTAEditBuffer; AFile: TTrackedFile);
var
  LTracker: IOTAEditLineTracker;
  I: Integer;
begin
  if ABuffer = nil then
    Exit;
  LTracker := ABuffer.GetEditLineTracker;
  if LTracker = nil then
    Exit;
  for I := LTracker.Count - 1 downto 0 do
    if AFile.IndexOfData(LTracker.Data[I]) >= 0 then
      LTracker.Delete(I);
end;

procedure TrackDiagnosticLines(const APath: string);
var
  LKey: string;
  LDiags: TArray<TLspDiagnostic>;
  LBuffer: IOTAEditBuffer;
  LTracker: IOTAEditLineTracker;
  LOld, LFile: TTrackedFile;
  LRows: TList<Integer>;
  LLines, I: Integer;
begin
  LKey := LowerCase(APath);
  try
    LBuffer := FindBuffer(APath);
    if (GFiles <> nil) and GFiles.TryGetValue(LKey, LOld) then
    begin
      RemoveEntries(LBuffer, LOld);
      GFiles.Remove(LKey);   // frees LOld
    end;
    if (LBuffer = nil) or not LspTryGetDiagnostics(APath, LDiags) or
       (LDiags = nil) then
      Exit;
    LTracker := LBuffer.GetEditLineTracker;
    if LTracker = nil then
      Exit;

    LRows := TList<Integer>.Create;
    try
      for I := 0 to High(LDiags) do
        if (LDiags[I].Row > 0) and not LRows.Contains(LDiags[I].Row) then
          LRows.Add(LDiags[I].Row);
      LRows.Sort;
      LFile := TTrackedFile.Create;
      LFile.Rows := LRows.ToArray;
    finally
      LRows.Free;
    end;
    if GFiles = nil then
      GFiles := TObjectDictionary<string, TTrackedFile>.Create([doOwnsValues]);
    GFiles.Add(LKey, LFile);
    LFile.Source := Pointer(LDiags);
    LFile.Block := AllocMem(Length(LFile.Rows));
    LFile.Now := Copy(LFile.Rows);
    SetLength(LFile.Added, Length(LFile.Rows));
    LLines := LBuffer.GetLinesInBuffer;
    for I := 0 to High(LFile.Rows) do
      // A row past the end - the buffer shrank since the analysis read it -
      // is not the tracker's to place; it stays where it was said to be.
      if LFile.Rows[I] <= LLines then
      begin
        LTracker.AddLine(LFile.Rows[I], IntPtr(LFile.Block + I));
        LFile.Added[I] := True;
      end;
  except
    on E: Exception do
      LspLogDetail('diagnostic lines: tracking ' + ExtractFileName(APath)
        + ' failed: ' + E.ClassName + ': ' + E.Message);
  end;
end;

function DiagnosticLinesViewModified(const AView: IOTAEditView): Boolean;
var
  LBuffer: IOTAEditBuffer;
  LTracker: IOTAEditLineTracker;
  LFile: TTrackedFile;
  LSeen: TArray<Boolean>;
  I, LIdx, LLine: Integer;
begin
  Result := False;
  if (GFiles = nil) or (GFiles.Count = 0) or (AView = nil) then
    Exit;
  try
    LBuffer := AView.Buffer;
    if (LBuffer = nil) or
       not GFiles.TryGetValue(LowerCase(LBuffer.FileName), LFile) then
      Exit;
    LTracker := LBuffer.GetEditLineTracker;
    if LTracker = nil then
      Exit;
    SetLength(LSeen, Length(LFile.Rows));
    for I := 0 to LTracker.Count - 1 do
    begin
      LIdx := LFile.IndexOfData(LTracker.Data[I]);
      if LIdx < 0 then
        Continue;
      LSeen[LIdx] := True;
      LLine := LTracker.LineNum[I];
      if LLine <> LFile.Now[LIdx] then
      begin
        LFile.Now[LIdx] := LLine;
        Result := True;
      end;
    end;
    // An entry the tracker no longer holds: its line was deleted.
    for LIdx := 0 to High(LFile.Rows) do
      if LFile.Added[LIdx] and not LSeen[LIdx] and (LFile.Now[LIdx] <> 0) then
      begin
        LFile.Now[LIdx] := 0;
        Result := True;
      end;
    if Result then
    begin
      LFile.Moved := False;
      for LIdx := 0 to High(LFile.Rows) do
        if LFile.Now[LIdx] <> LFile.Rows[LIdx] then
          LFile.Moved := True;
      LFile.LiveBuilt := False;
    end;
  except
    on E: Exception do
      LspLogDetail('diagnostic lines: reading the tracker failed: '
        + E.ClassName + ': ' + E.Message);
  end;
end;

function LiveDiagnostics(const APath: string;
  out ADiags: TArray<TLspDiagnostic>): Boolean;
var
  LFile: TTrackedFile;
  LLive: TList<TLspDiagnostic>;
  LDiag, LMoved: TLspDiagnostic;
  LIdx: Integer;
begin
  Result := LspTryGetDiagnostics(APath, ADiags);
  if not Result or (GFiles = nil) or
     not GFiles.TryGetValue(LowerCase(APath), LFile) or not LFile.Moved or
     // A newer answer than the one tracked: its rows are the editor's own.
     (LFile.Source <> Pointer(ADiags)) then
    Exit;
  if not LFile.LiveBuilt then
  begin
    LLive := TList<TLspDiagnostic>.Create;
    try
      for LDiag in ADiags do
      begin
        LIdx := LFile.IndexOfRow(LDiag.Row);
        if LIdx < 0 then
          LLive.Add(LDiag)
        else if LFile.Now[LIdx] > 0 then
        begin
          LMoved := LDiag;
          LMoved.Row := LFile.Now[LIdx];
          LLive.Add(LMoved);
        end;
      end;
      LFile.Live := LLive.ToArray;
    finally
      LLive.Free;
    end;
    LFile.LiveBuilt := True;
  end;
  ADiags := LFile.Live;
end;

procedure FinalizeDiagnosticLines;
var
  LPair: TPair<string, TTrackedFile>;
begin
  if GFiles = nil then
    Exit;
  // The tracker would only keep numbers nobody reads, but an entry whose
  // Data points into freed memory is not ours to leave behind.
  for LPair in GFiles do
    try
      RemoveEntries(FindBuffer(LPair.Key), LPair.Value);
    except
      // Unloading: nothing to tell, nobody to tell it to.
    end;
  FreeAndNil(GFiles);
end;

end.
